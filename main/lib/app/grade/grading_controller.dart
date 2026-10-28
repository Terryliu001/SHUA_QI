import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shuaqi/domain/model/grading.dart';
import 'package:shuaqi/infra/vault/layout_store.dart';

/// 判题结果控制器（每卷一个）。
///
/// 与 `AnswerSheetController` 同构：`ValueNotifier` + 串行落盘。
/// 为什么要控制器而不是每次读写文件：一键改卷会一次改写几十道题的结论，
/// 面板/统计条要能立刻反映，不能等 IO。
class GradingController {
  GradingController({
    required this.workbookId,
    required this.store,
    this.onGraded,
  });

  final String workbookId;
  final LayoutStore store;

  /// 判出结论后的旁路通知（阶段 9：作答记录）。
  ///
  /// 为什么挂在这里而不是每个调用点：改卷入口有 6 个（三色手改 / 一键改卷 /
  /// AI 单题 / AI 批量 / 收藏面板 / 答题卡面板），逐处打点必然漏。
  /// 只有"真的判出了一个结论"才回调，`none` 不算（那不叫做过）。
  final void Function(String questionId, AnswerVerdict verdict)? onGraded;

  void _notify(String questionId, AnswerVerdict verdict) {
    if (verdict == AnswerVerdict.none) {
      return;
    }
    try {
      onGraded?.call(questionId, verdict);
    } on Object {
      // 旁路失败不能影响判题本身。
    }
  }

  final ValueNotifier<GradingData> data = ValueNotifier<GradingData>(
    GradingData.empty,
  );

  bool _loaded = false;
  bool _dirty = false;
  Future<void> _writeQueue = Future<void>.value();

  Future<void> load() async {
    if (_loaded) {
      return;
    }
    _loaded = true;
    try {
      final GradingData loaded = GradingData.fromJson(
        await store.readGrading(workbookId),
      );
      if (data.value.isEmpty) {
        data.value = loaded;
      }
    } on Object {
      // 坏 JSON 当"还没判过"，不影响阅读。
    }
  }

  AnswerVerdict verdictOf(String questionId) =>
      data.value.verdictOf(questionId);

  /// 用户手改：永远 source=manual，之后一键改卷不会覆盖它。
  Future<void> setManual(String questionId, AnswerVerdict verdict) async {
    final QuestionGrade grade = QuestionGrade(
      questionId: questionId,
      verdict: verdict,
      source: GradeSource.manual,
      at: DateTime.now().millisecondsSinceEpoch,
    );
    data.value = data.value.withGrade(grade);
    _dirty = true;
    _notify(questionId, verdict);
    await _persist();
  }

  /// AI 判题结果：source=ai，带上模型给的理由。
  ///
  /// 手改永远优先：用户已经把结论改成 manual 时，AI 不覆盖。
  Future<bool> applyAi(
    String questionId,
    AnswerVerdict verdict, {
    String note = '',
    GradeEvidence evidence = GradeEvidence.empty,
  }) async {
    final QuestionGrade? existing = data.value.gradeOf(questionId);
    if (existing != null && existing.manual) {
      return false;
    }
    data.value = data.value.withGrade(
      QuestionGrade(
        questionId: questionId,
        verdict: verdict,
        source: GradeSource.ai,
        at: DateTime.now().millisecondsSinceEpoch,
        note: note,
        judgedText: evidence.text,
        judgedSig: evidence.sig,
        judgedRefHash: evidence.refHash,
      ),
    );
    _dirty = true;
    _notify(questionId, verdict);
    await _persist();
    return true;
  }

  /// 一键改卷的结果：默认**只覆盖本地自动结论**，手改与 AI 结论都保留。
  ///
  /// [replaceAi] 只给「AI 判过、但本次发现答案有明显改动」的题用：
  /// 此时旧 AI 结论已不可信，允许本轮按当前 OCR 重判后覆盖。
  /// 手改（manual）仍然永远不覆盖。
  ///
  /// [evidence] / [notes] 按 questionId 带上本次判题依据（OCR 文本、作答指纹、
  /// 参考答案哈希），下次改卷才能判断「有没有大改」。
  Future<void> applyAuto(
    Map<String, AnswerVerdict> verdicts, {
    Map<String, GradeEvidence> evidence = const <String, GradeEvidence>{},
    Map<String, String> notes = const <String, String>{},
    bool replaceAi = false,
  }) async {
    GradingData next = data.value;
    final int now = DateTime.now().millisecondsSinceEpoch;
    final List<MapEntry<String, AnswerVerdict>> written =
        <MapEntry<String, AnswerVerdict>>[];
    for (final MapEntry<String, AnswerVerdict> entry in verdicts.entries) {
      final QuestionGrade? existing = next.gradeOf(entry.key);
      if (existing != null && existing.source != GradeSource.auto) {
        final bool mayReplaceAi =
            replaceAi && existing.source == GradeSource.ai;
        if (!mayReplaceAi) {
          continue;
        }
      }
      final GradeEvidence snapshot = evidence[entry.key] ?? GradeEvidence.empty;
      next = next.withGrade(
        QuestionGrade(
          questionId: entry.key,
          verdict: entry.value,
          source: GradeSource.auto,
          at: now,
          note: notes[entry.key] ?? '',
          judgedText: snapshot.text,
          judgedSig: snapshot.sig,
          judgedRefHash: snapshot.refHash,
        ),
      );
      written.add(entry);
    }
    data.value = next;
    _dirty = true;
    for (final MapEntry<String, AnswerVerdict> entry in written) {
      _notify(entry.key, entry.value);
    }
    await _persist();
  }

  Future<void> prune(Set<String> keep) async {
    if (keep.isEmpty) {
      return;
    }
    final GradingData next = data.value.retain(keep);
    if (identical(next, data.value)) {
      return;
    }
    data.value = next;
    _dirty = true;
    await _persist();
  }

  Future<void> flush() async {
    if (!_dirty) {
      return;
    }
    await _persist();
  }

  Future<void> _persist() {
    final GradingData snapshot = data.value;
    final Future<void> task = _writeQueue.then((_) async {
      await store.writeGrading(workbookId, snapshot.toJson());
    });
    _writeQueue = task.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return task;
  }

  void dispose() {
    unawaited(flush());
    data.dispose();
  }
}
