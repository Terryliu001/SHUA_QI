import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shuaqi/domain/model/question.dart';
import 'package:shuaqi/infra/vault/layout_store.dart';

/// 手动题目顺序（纯用户产物，与切题算法解耦）。
///
/// 为什么要单独存：
/// - `Question.ordinal` 是切题算法给出的文档顺序，改题号/拖框都不会改它；
/// - 用户把一道题拖到另一处，只应影响展示顺序，不应重写算法结果；
/// - 重切题后 question.id 稳定（id_keep），顺序还能继续套用；新题自动排到最后。
class QuestionOrderController {
  QuestionOrderController({required this.workbookId, required this.store});

  final String workbookId;
  final LayoutStore store;

  final ValueNotifier<List<String>> order = ValueNotifier<List<String>>(
    const <String>[],
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
      final Map<String, Object?>? json = await store.readQuestionOrder(
        workbookId,
      );
      final Object? raw = json?['order'];
      if (raw is List && order.value.isEmpty) {
        order.value = <String>[
          for (final Object? item in raw)
            if (item is String && item.isNotEmpty) item,
        ];
      }
    } on Object {
      // 坏 JSON 当无自定义顺序；不打断阅读。
    }
  }

  /// 按用户顺序排；不在 order 里的题保持原始相对顺序排在最后。
  List<QuestionBundle> apply(List<QuestionBundle> questions) {
    final List<String> ids = order.value;
    if (ids.isEmpty || questions.length < 2) {
      return questions;
    }
    final Map<String, int> rank = <String, int>{
      for (int i = 0; i < ids.length; i++) ids[i]: i,
    };
    final List<QuestionBundle> sorted = List<QuestionBundle>.of(questions);
    sorted.sort((QuestionBundle a, QuestionBundle b) {
      final int ra = rank[a.question.id] ?? 1 << 20;
      final int rb = rank[b.question.id] ?? 1 << 20;
      if (ra != rb) {
        return ra.compareTo(rb);
      }
      return a.question.ordinal.compareTo(b.question.ordinal);
    });
    return sorted;
  }

  /// [current] 是**当前展示顺序**（已 apply 过），old/new 是 ReorderableListView 的索引。
  Future<void> move(
    List<QuestionBundle> current,
    int oldIndex,
    int newIndex,
  ) async {
    if (oldIndex < 0 || oldIndex >= current.length) {
      return;
    }
    // ReorderableListView.onReorderItem 已经替我们扣除了"先移除再插入"的偏移，
    // 这里不能再 newIndex--。
    final int target = newIndex.clamp(0, current.length - 1);
    if (target == oldIndex) {
      return;
    }
    final List<String> ids = <String>[
      for (final QuestionBundle bundle in current) bundle.question.id,
    ];
    final String moved = ids.removeAt(oldIndex);
    ids.insert(target, moved);
    order.value = ids;
    _dirty = true;
    await _persist();
  }

  /// 立刻落盘。写完清 dirty，避免页面 dispose 时无意义地再写一次
  /// （测试临时目录已删时，那次延迟写会变成 PathNotFound）。
  Future<void> flush() async {
    if (!_dirty) {
      return;
    }
    _dirty = false;
    await _persist();
  }

  /// 恢复切题算法的原始顺序（清空手动顺序）。
  Future<void> reset() async {
    if (order.value.isEmpty) {
      return;
    }
    order.value = const <String>[];
    _dirty = true;
    await _persist();
  }

  /// 删掉已不存在的题 id（用户删题/重切后），避免顺序文件越积越长。
  Future<void> prune(Set<String> keepQuestionIds) async {
    if (keepQuestionIds.isEmpty || order.value.isEmpty) {
      return;
    }
    final List<String> next = <String>[
      for (final String id in order.value)
        if (keepQuestionIds.contains(id)) id,
    ];
    if (next.length == order.value.length) {
      return;
    }
    order.value = next;
    _dirty = true;
    await _persist();
  }

  Future<void> _persist() {
    final List<String> snapshot = List<String>.of(order.value);
    final Future<void> task = _writeQueue.then((_) async {
      await store.writeQuestionOrder(workbookId, <String, Object?>{
        'version': 1,
        'order': snapshot,
      });
    });
    _writeQueue = task.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return task;
  }

  void dispose() {
    unawaited(flush());
    order.dispose();
  }
}
