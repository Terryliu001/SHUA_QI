/// 可撤销的笔迹编辑（T2.3）。纯 Dart、无 IO、无 Flutter。
///
/// ## 为什么是"命令"而不是"快照"
/// 规格写死的一条：撤销栈里存**命令**，不存 `InkDoc` 整页快照。
/// 一页 5000 笔按 50 步算就是 25 万次对象引用（追加历史状态会把内存顶爆）。
/// 命令只记"动了哪几笔"，一次撤销/重做是 O(笔画数) 的列表操作。
///
/// ## 撤销不许碰识别结果
/// 命令只改 [InkDoc.strokes]，每次操作都让 `revision + 1`；
/// W4 的识别结果靠 revision 失效（INV-02），不是被撤销"回滚"。
///
/// ## 为什么命令都自带"原索引"
/// 删除必须可逆到**原来的 z 序**：荧光笔垫底、墨迹按落笔顺序叠放，
/// 撤销后若把笔画塞到末尾，视觉上看起来一样，导出与将来的图层操作会乱。
/// 所以在删除发生的那一刻就把 `(index, stroke)` 记进命令里 ——
/// 这也是擦除"边划边删、抬笔只入栈一次"能成立的前提。
library;

import 'package:shuaqi/domain/ink/ink_doc.dart';

/// 被删掉的笔画 + 它当时的下标。
typedef RemovedStroke = ({int index, InkStroke stroke});

/// 一条笔迹编辑命令。`apply` / `revert` 都不修改入参（InkDoc 不可变）。
sealed class InkCommand {
  const InkCommand();

  /// 正向执行，返回新的 [InkDoc]。
  InkDoc apply(InkDoc doc);

  /// 反向执行（撤销），返回新的 [InkDoc]。
  InkDoc revert(InkDoc doc);

  /// 调试/日志用的一句话（不含用户内容，可以安全打日志）。
  String get debugLabel;
}

/// 落一笔（抬笔时提交）。
class AddStroke extends InkCommand {
  const AddStroke(this.stroke);

  final InkStroke stroke;

  @override
  InkDoc apply(InkDoc doc) => doc.append(stroke);

  @override
  InkDoc revert(InkDoc doc) => doc.withoutUids(<String>{stroke.uid});

  @override
  String get debugLabel => 'add';
}

/// 删掉一笔或多笔。擦除拖过几笔就装几笔，**一次拖动 = 一条命令**。
class RemoveStrokes extends InkCommand {
  const RemoveStrokes(this.removed);

  final List<RemovedStroke> removed;

  @override
  InkDoc apply(InkDoc doc) => doc.withoutUids(<String>{
    for (final RemovedStroke item in removed) item.stroke.uid,
  });

  @override
  InkDoc revert(InkDoc doc) => doc.insertAll(removed);

  @override
  String get debugLabel => 'remove ×${removed.length}';
}

/// 清空整页（T3.5 检查面板会用；命令先落地并有单测）。
///
/// 必须带上"清空前那一页的笔画"——否则撤销无从恢复。
/// 规格里的 `ClearPage` 没有字段，但一个不可逆的清空命令是没法进撤销栈的，
/// 这里按可逆性补上参数（有意偏离，已记入日志 024）。
class ClearPage extends InkCommand {
  const ClearPage(this.removed);

  final List<RemovedStroke> removed;

  @override
  InkDoc apply(InkDoc doc) =>
      doc.isEmpty ? doc : doc.withStrokes(const <InkStroke>[]);

  @override
  InkDoc revert(InkDoc doc) => doc.insertAll(removed);

  @override
  String get debugLabel => 'clear ×${removed.length}';
}

/// 撤销/重做历史（规格 T2.3：命令栈，深度 50 步）。
///
/// 只做三件事：记命令、报 canUndo/canRedo、弹出命令。
/// **doc 由调用方持有**（`InkEditController`）——这样"落盘回填 revision"
/// 这类外部更新不会把历史搅乱。
class UndoStack {
  UndoStack({this.maxDepth = defaultMaxDepth});

  /// 规格 T2.3：≥50 步不崩。
  static const int defaultMaxDepth = 50;

  final int maxDepth;

  final List<InkCommand> _undo = <InkCommand>[];
  final List<InkCommand> _redo = <InkCommand>[];

  bool get canUndo => _undo.isNotEmpty;

  bool get canRedo => _redo.isNotEmpty;

  int get undoDepth => _undo.length;

  int get redoDepth => _redo.length;

  /// 记录一条编辑（**只记历史，不改 doc**）。
  ///
  /// 两种用法都走它：
  /// - 先 `doc = cmd.apply(doc)` 再 `push(cmd)`（抬笔、清空）；
  /// - 边划边删时先改 doc，抬笔才把整次拖动合成一条命令 `push`（擦除）。
  void push(InkCommand command) {
    _undo.add(command);
    // 超出深度：丢最老的那条（用户按不到那么多步，内存必须有上界）。
    while (_undo.length > maxDepth) {
      _undo.removeAt(0);
    }
    // 新的编辑发生后，原来的"重做"分支已经作废。
    _redo.clear();
  }

  /// 弹出的命令由调用方 revert 并写回 doc。
  InkCommand? takeUndo() {
    if (_undo.isEmpty) {
      return null;
    }
    final InkCommand command = _undo.removeLast();
    _redo.add(command);
    return command;
  }

  /// 弹出的命令由调用方 apply 并写回 doc。
  InkCommand? takeRedo() {
    if (_redo.isEmpty) {
      return null;
    }
    final InkCommand command = _redo.removeLast();
    _undo.add(command);
    return command;
  }

  /// 清空历史（重新从磁盘载入时用：历史对不上新的基线）。
  void clear() {
    _undo.clear();
    _redo.clear();
  }
}
