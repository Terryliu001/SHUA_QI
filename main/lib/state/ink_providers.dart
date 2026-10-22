import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shuaqi/domain/ink/ink_doc.dart';
import 'package:shuaqi/domain/ink/ink_store.dart';
import 'package:shuaqi/domain/ink/undo_stack.dart';
import 'package:shuaqi/infra/ink/memory_ink_store.dart';

/// 笔迹存储（T2.1 内存实现；T2.4 换 SIF 时只改这一行）。
final Provider<InkStore> inkStoreProvider = Provider<InkStore>((Ref ref) {
  return MemoryInkStore();
});

/// 一页笔迹的定位键。做成值对象而不是 `'$sessionId#$pageIndex'` 字符串：
/// family 的 arg 直接当 Map 键用，字符串拼接要小心分隔符碰撞，
/// 值对象靠结构相等，编译期就能发现漏字段。
class InkPageKey {
  const InkPageKey(this.sessionId, this.pageIndex);

  final String sessionId;
  final int pageIndex;

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is InkPageKey &&
            other.sessionId == sessionId &&
            other.pageIndex == pageIndex;
  }

  @override
  int get hashCode => Object.hash(sessionId, pageIndex);

  @override
  String toString() => 'InkPageKey($sessionId#$pageIndex)';
}

/// 一页的编辑态：笔迹 + 撤销/重做是否可用。
///
/// 为什么把 canUndo/canRedo 和 doc 放在同一个 state：
/// 工具栏要按"这一页还有没有可撤销的"实时变色，若拆成两个 provider，
/// 每次抬笔/擦除都要两处通知，容易出现"按钮亮了但按下去没反应"。
class InkEditState {
  const InkEditState({
    required this.doc,
    this.canUndo = false,
    this.canRedo = false,
  });

  final InkDoc doc;
  final bool canUndo;
  final bool canRedo;

  InkEditState copyWith({InkDoc? doc, bool? canUndo, bool? canRedo}) {
    return InkEditState(
      doc: doc ?? this.doc,
      canUndo: canUndo ?? this.canUndo,
      canRedo: canRedo ?? this.canRedo,
    );
  }
}

/// 一页的笔迹状态（Notifier + family）。
///
/// 三条设计约束：
/// 1. **加载是异步的，但 UI 不能等**：`build()` 先返回空 doc（这一页还没读过就是空的，
///    合法初始态），加载完静默替换并清空撤销历史（历史对不上新基线）。
/// 2. **提交先改内存再落盘**：抬笔到上屏之间只有"点追加 + 通知"，落盘走异步（INV-01/INV-02）。
///    revision 以落盘返回为准回填——W4 的识别调度要拿它做版本校验。
/// 3. **所有改变笔画集合的操作都过 [UndoStack]**：抬笔、擦除、撤销、重做。
///    这样"撤销只动 stroke 列表、靠 revision 让识别失效"（INV-02）在实现层就是唯一的路径。
final NotifierProvider<InkEditController, InkEditState> Function(InkPageKey)
inkEditProvider =
    NotifierProvider.family<InkEditController, InkEditState, InkPageKey>(
      InkEditController.new,
    );

/// 只要笔迹本身的派生入口（绘制层用）。
///
/// 单独给一个 provider 是为了让"画布只关心笔画"这件事成立：
/// 撤销按钮变色不会把墨迹层重建一遍。
final Provider<InkDoc> Function(InkPageKey) inkDocProvider =
    Provider.family<InkDoc, InkPageKey>((Ref ref, InkPageKey key) {
      return ref.watch(inkEditProvider(key).select((InkEditState s) => s.doc));
    });

class InkEditController extends Notifier<InkEditState> {
  InkEditController(this._key);

  final InkPageKey _key;

  final UndoStack _history = UndoStack();

  /// 本次擦除拖动里已经删掉的笔画（抬笔时合成一条命令）。
  final List<RemovedStroke> _pendingErase = <RemovedStroke>[];

  /// 本次擦除拖动**开始那一刻**的 doc。
  ///
  /// 为什么要它：擦除是边划边删，删完一次之后 doc 的下标全变了。
  /// 撤销要按"原始 z 序"插回去，所以每条记录的索引必须取自同一个基线 doc
  /// ——否则（按当前 doc 取）会复原成 [b, a, c] 这种错序（单测钉住了这个坑）。
  InkDoc? _eraseBaseline;

  /// 落盘代次：每次开始保存 +1。保存完成时如果代次没变（期间没有新编辑），
  /// 才把磁盘返回的 revision 回填到 state——否则会被旧保存覆盖新状态。
  int _saveGeneration = 0;

  @override
  InkEditState build() {
    unawaited(_load());
    return const InkEditState(doc: InkDoc.empty);
  }

  InkDoc get doc => state.doc;

  Future<void> _load() async {
    final InkDoc loaded = await ref
        .read(inkStoreProvider)
        .load(_key.sessionId, _key.pageIndex);
    if (!ref.mounted) {
      return;
    }
    // 竞态保护（T2.3 加固）：加载是异步的，用户可能在它返回之前就写了字。
    // 那时磁盘上那份旧内容**不能**覆盖内存——否则刚写的笔会凭空消失。
    // T2.4 换成真实文件 IO 后这个窗口会从"一个微任务"变成"十几毫秒"，必须挡。
    if (_history.canUndo || state.doc.strokeCount > 0) {
      return;
    }
    // 磁盘来的 doc 是新的基线：旧历史（如果有）对不上，直接清掉。
    _history.clear();
    _pendingErase.clear();
    _eraseBaseline = null;
    state = InkEditState(doc: loaded);
  }

  // ── 书写 ─────────────────────────────────────────────────────────

  /// 抬笔提交一笔。返回新 revision（内存版本）。
  Future<int> commit(InkStroke stroke) async {
    _applyCommand(AddStroke(stroke));
    return state.doc.revision;
  }

  // ── 擦除（T2.3）───────────────────────────────────────────────────

  /// 擦除命中 [strokes] 的笔画：**立即**从 doc 移除（用户要立刻看到它消失），
  /// 但先攒着不进撤销栈——一次拖动抬笔时只算一步撤销。
  void eraseStrokes(List<InkStroke> strokes) {
    if (strokes.isEmpty) {
      return;
    }
    final InkDoc current = state.doc;
    // 基线只在本次拖动的第一次擦除时取一次；之后所有索引都相对它。
    final InkDoc baseline = _eraseBaseline ??= current;
    final List<RemovedStroke> removed = <RemovedStroke>[];
    for (final InkStroke stroke in strokes) {
      // 已经不在了（同一笔被重复命中）：不能重复记，否则撤销会插出两份。
      if (current.indexOfUid(stroke.uid) < 0) {
        continue;
      }
      final int index = baseline.indexOfUid(stroke.uid);
      removed.add((
        index: index >= 0 ? index : current.indexOfUid(stroke.uid),
        stroke: stroke,
      ));
    }
    if (removed.isEmpty) {
      return;
    }
    _pendingErase.addAll(removed);
    state = state.copyWith(
      doc: current.withoutUids(<String>{
        for (final RemovedStroke item in removed) item.stroke.uid,
      }),
      canRedo: false,
    );
  }

  /// 擦除结束（抬笔）：把整次拖动合成一条 `RemoveStrokes` 进撤销栈。
  void endErase() {
    if (_pendingErase.isEmpty) {
      _eraseBaseline = null;
      return;
    }
    _history.push(RemoveStrokes(List<RemovedStroke>.of(_pendingErase)));
    _pendingErase.clear();
    _eraseBaseline = null;
    state = state.copyWith(
      canUndo: _history.canUndo,
      canRedo: _history.canRedo,
    );
    unawaited(_save());
  }

  /// 放弃进行中的擦除（笔被 cancel / 页面被换掉）：已删的仍然算数，
  /// 但同样要收尾成一步撤销，否则用户"按了撤销却跳到更早的状态"。
  void cancelErase() => endErase();

  // ── 撤销 / 重做（T2.3）───────────────────────────────────────────

  /// 撤销一步。没有可撤销的返回 false（UI 据此不再弹提示）。
  bool undo() {
    // 擦除划到一半就按了撤销：先把这次拖动收尾成一步，
    // 否则那几笔被删了却不在历史里，用户"撤销恢复不了"（真失数据）。
    _settlePendingErase();
    final InkCommand? command = _history.takeUndo();
    if (command == null) {
      return false;
    }
    state = state.copyWith(
      doc: command.revert(state.doc),
      canUndo: _history.canUndo,
      canRedo: _history.canRedo,
    );
    unawaited(_save());
    return true;
  }

  /// 重做一步。
  bool redo() {
    _settlePendingErase();
    final InkCommand? command = _history.takeRedo();
    if (command == null) {
      return false;
    }
    state = state.copyWith(
      doc: command.apply(state.doc),
      canUndo: _history.canUndo,
      canRedo: _history.canRedo,
    );
    unawaited(_save());
    return true;
  }

  /// 清空本页（T3.5 检查面板用；命令已可撤销）。
  void clearPage() {
    final InkDoc doc = state.doc;
    if (doc.isEmpty) {
      return;
    }
    final List<RemovedStroke> removed = <RemovedStroke>[
      for (int i = 0; i < doc.strokes.length; i++)
        (index: i, stroke: doc.strokes[i]),
    ];
    _applyCommand(ClearPage(removed));
  }

  // ── 内部 ─────────────────────────────────────────────────────────

  void _applyCommand(InkCommand command) {
    _settlePendingErase();
    final InkDoc next = command.apply(state.doc);
    _history.push(command);
    state = InkEditState(
      doc: next,
      canUndo: _history.canUndo,
      canRedo: _history.canRedo,
    );
    unawaited(_save());
  }

  /// 把进行中的擦除收成一步撤销（没有就什么也不做）。
  void _settlePendingErase() {
    if (_pendingErase.isNotEmpty) {
      _history.push(RemoveStrokes(List<RemovedStroke>.of(_pendingErase)));
      _pendingErase.clear();
    }
    _eraseBaseline = null;
  }

  Future<void> _save() async {
    final int generation = ++_saveGeneration;
    final InkDoc snapshot = state.doc;
    final int revision = await ref
        .read(inkStoreProvider)
        .save(_key.sessionId, _key.pageIndex, snapshot);
    if (!ref.mounted || generation != _saveGeneration) {
      // 期间又有新编辑：那次保存会带回更新的版本号，这次不回填
      return;
    }
    // 只回填版本号，不动笔画集合，也不动撤销历史。
    state = state.copyWith(doc: state.doc.copyWith(revision: revision));
  }
}
