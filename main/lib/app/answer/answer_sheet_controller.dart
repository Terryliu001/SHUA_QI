import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shuaqi/domain/model/answer_sheet.dart';
import 'package:shuaqi/domain/model/question.dart';
import 'package:shuaqi/domain/region/region_rect.dart';
import 'package:shuaqi/infra/vault/layout_store.dart';

/// 作答框 / 作答识别结果的控制器（每卷一个）。
///
/// 与 `RegionEditController` 的分工：
/// - 题目区域由切题 + 覆盖层负责；
/// - 本控制器只负责"每道题的作答框、作答原图、OCR 文本"，
///   以 `questionId` 为键，不参与切题重算，所以重切题时不会丢。
///
/// 为什么用 `ValueNotifier` 而不是 Riverpod 的 AsyncNotifier：
/// 阅读器已经在 build 里做了大量派生，作答框变化只影响面板/叠加层；
/// 用 ValueNotifier 让这两个局部监听，避免整页重建（与现有 RegionEditController 同构）。
class AnswerSheetController {
  AnswerSheetController({required this.workbookId, required this.store});

  final String workbookId;
  final LayoutStore store;

  final ValueNotifier<AnswerSheetData> data = ValueNotifier<AnswerSheetData>(
    AnswerSheetData.empty,
  );

  bool _loaded = false;
  Future<void> _writeQueue = Future<void>.value();
  bool _dirty = false;

  Future<void> load() async {
    if (_loaded) {
      return;
    }
    _loaded = true;
    try {
      final AnswerSheetData loaded = AnswerSheetData.fromJson(
        await store.readAnswerSheet(workbookId),
      );
      // 如果在加载期间用户已经改了（极短的窗口），不拿磁盘旧值覆盖内存新值。
      if (data.value.isEmpty) {
        data.value = loaded;
      }
    } on Object {
      // 坏 JSON 当"没有作答框"：面板回落到默认整题，不打断阅读。
    }
  }

  AnswerSheetEntry entryFor(QuestionBundle bundle) =>
      data.value.regionFor(bundle);

  /// 落一次作答框调整（拖动/缩放/恢复整题）。
  Future<void> updateRect(
    QuestionBundle bundle, {
    required int pageIndex,
    required RegionRect rect,
    AnswerRegionSource source = AnswerRegionSource.manual,
  }) async {
    if (rect.isEmpty) {
      return;
    }
    final AnswerSheetEntry current = entryFor(bundle);
    final AnswerSheetEntry next = current.copyWith(
      pageIndex: pageIndex,
      rect: rect,
      regionSource: source,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
      // 框变了：旧 OCR 文字不再对应新框。清掉指纹，展开/改卷时会自动重识别。
      inkSig: '',
    );
    data.value = data.value.withEntry(next);
    _dirty = true;
    await _persist();
  }

  /// 回到"整题区域"，保留已有 OCR 文本/原图。
  Future<void> reset(QuestionBundle bundle) async {
    final AnswerSheetEntry current = entryFor(bundle);
    if (current.ocrText.isEmpty &&
        current.cropPath == null &&
        !current.manuallyAdjusted) {
      data.value = data.value.without(bundle.question.id);
      _dirty = true;
      await _persist();
      return;
    }
    final AnswerSheetEntry base = AnswerSheetEntry.defaultFor(bundle);
    final AnswerSheetEntry next = base.copyWith(
      ocrText: current.ocrText,
      ocrConfidence: current.ocrConfidence,
      ocrEngine: current.ocrEngine,
      cropPath: current.cropPath,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
      // 框回到整题：旧文字/指纹都属于旧框，下次展开会自动重识别。
      inkSig: '',
    );
    data.value = data.value.withEntry(next);
    _dirty = true;
    await _persist();
  }

  /// 本地 OCR 完成/手工修正后回写。
  ///
  /// [inkSig] 是这次识别对应的作答指纹。**识别结果为空也要写**：
  /// 否则「本来就没识别出字」的题每次展开都会重新跑识别（用户会觉得卡）。
  /// 识别失败（抛异常）不要调用本方法，留下旧指纹以便下次重试。
  Future<void> updateOcr(
    QuestionBundle bundle, {
    required String text,
    required double confidence,
    required String engine,
    String? cropPath,
    String? inkSig,
  }) async {
    final AnswerSheetEntry current = entryFor(bundle);
    final int now = DateTime.now().millisecondsSinceEpoch;
    final AnswerSheetEntry next = current.copyWith(
      ocrText: text,
      ocrConfidence: confidence,
      ocrEngine: engine,
      cropPath: cropPath,
      updatedAt: now,
      // 识别时间单独记：改作答框不会刷新它，`ocrStale` 才判得准。
      ocrAt: now,
      inkSig: inkSig,
    );
    data.value = data.value.withEntry(next);
    _dirty = true;
    await _persist();
  }

  /// 只记作答原图路径（OCR 引擎尚未接入时也要先留存）。
  Future<void> updateCrop(
    QuestionBundle bundle, {
    required String cropPath,
  }) async {
    final AnswerSheetEntry current = entryFor(bundle);
    final AnswerSheetEntry next = current.copyWith(
      cropPath: cropPath,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );
    data.value = data.value.withEntry(next);
    _dirty = true;
    await _persist();
  }

  /// 清理已经不在当前切题结果里的作答条目（用户删题/重切后）。
  ///
  /// 只清元数据，不改 PDF/笔迹；避免 `answer_sheet.v1.json` 长期堆积幽灵题。
  Future<void> prune(Set<String> keepQuestionIds) async {
    if (keepQuestionIds.isEmpty) {
      return;
    }
    final List<String> stale = <String>[
      for (final String id in data.value.entries.keys)
        if (!keepQuestionIds.contains(id)) id,
    ];
    if (stale.isEmpty) {
      return;
    }
    AnswerSheetData next = data.value;
    for (final String id in stale) {
      next = next.without(id);
    }
    data.value = next;
    _dirty = true;
    await _persist();
  }

  /// 立刻落盘（退出阅读器/生命周期）。
  Future<void> flush() async {
    if (!_dirty) {
      return;
    }
    await _persist();
  }

  Future<void> _persist() {
    final AnswerSheetData snapshot = data.value;
    final Future<void> task = _writeQueue.then((_) async {
      await store.writeAnswerSheet(workbookId, snapshot.toJson());
    });
    // 一次写失败不阻塞后续写；下次 flush 会再写当前快照。
    _writeQueue = task.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return task;
  }

  void dispose() {
    unawaited(flush());
    data.dispose();
  }
}
