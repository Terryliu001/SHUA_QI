import 'package:flutter_test/flutter_test.dart';
import 'package:shuaqi/domain/ink/ink_doc.dart';
import 'package:shuaqi/domain/ink/undo_stack.dart';

/// T2.3 撤销栈与命令的纯函数测试（不碰 Flutter / Riverpod / IO）。
///
/// 重点保三件事：
/// 1. **可逆**：每条命令 revert 后与原 doc 完全一致（含 z 序）；
/// 2. **有界**：深度 50，超出丢最老的，绝不无限增长；
/// 3. **重做分支会作废**：新编辑之后不能再"重做"回旧分支。
InkStroke stroke(String uid, {double x = 0}) => InkStroke(
  uid: uid,
  points: <InkPoint>[
    InkPoint(x: x, y: 0),
    InkPoint(x: x + 10, y: 10),
  ],
);

InkDoc docOf(List<String> uids) {
  InkDoc doc = InkDoc.empty;
  for (int i = 0; i < uids.length; i++) {
    doc = doc.append(stroke(uids[i], x: i * 20));
  }
  return doc;
}

List<String> uidsOf(InkDoc doc) =>
    doc.strokes.map((InkStroke s) => s.uid).toList(growable: false);

void main() {
  group('命令可逆', () {
    test('AddStroke：apply 加一笔，revert 撤掉（revision 单调递增）', () {
      final InkStroke s = stroke('a');
      final InkDoc before = docOf(<String>['x']);
      final InkDoc added = AddStroke(s).apply(before);
      expect(uidsOf(added), <String>['x', 'a']);
      expect(added.revision, before.revision + 1);
      final InkDoc reverted = AddStroke(s).revert(added);
      expect(uidsOf(reverted), <String>['x']);
      expect(reverted.revision, added.revision + 1);
    });

    test('RemoveStrokes：删中间一笔，撤销回到原位（z 序不变）', () {
      final InkDoc before = docOf(<String>['a', 'b', 'c']);
      final InkStroke b = before.strokes[1];
      final RemoveStrokes cmd = RemoveStrokes(<RemovedStroke>[
        (index: 1, stroke: b),
      ]);
      final InkDoc removed = cmd.apply(before);
      expect(uidsOf(removed), <String>['a', 'c']);
      final InkDoc back = cmd.revert(removed);
      expect(uidsOf(back), <String>['a', 'b', 'c'], reason: '必须插回原索引，不能塞末尾');
    });

    test('RemoveStrokes：一次删首尾两笔，撤销后顺序仍然正确', () {
      final InkDoc before = docOf(<String>['a', 'b', 'c', 'd']);
      final RemoveStrokes cmd = RemoveStrokes(<RemovedStroke>[
        (index: 0, stroke: before.strokes[0]),
        (index: 2, stroke: before.strokes[2]),
      ]);
      final InkDoc removed = cmd.apply(before);
      expect(uidsOf(removed), <String>['b', 'd']);
      expect(uidsOf(cmd.revert(removed)), <String>['a', 'b', 'c', 'd']);
    });

    test('ClearPage：清空整页，撤销恢复全部', () {
      final InkDoc before = docOf(<String>['a', 'b', 'c']);
      final ClearPage cmd = ClearPage(<RemovedStroke>[
        for (int i = 0; i < before.strokes.length; i++)
          (index: i, stroke: before.strokes[i]),
      ]);
      final InkDoc cleared = cmd.apply(before);
      expect(cleared.strokeCount, 0);
      expect(uidsOf(cmd.revert(cleared)), <String>['a', 'b', 'c']);
    });

    test('空 doc 上的 ClearPage 不无中生有（revision 也不动）', () {
      const InkDoc empty = InkDoc.empty;
      final InkDoc cleared = const ClearPage(<RemovedStroke>[]).apply(empty);
      expect(identical(cleared, empty), isTrue);
    });
  });

  group('栈行为', () {
    test('空栈取不到命令（不抛）', () {
      final UndoStack stack = UndoStack();
      expect(stack.canUndo, isFalse);
      expect(stack.canRedo, isFalse);
      expect(stack.takeUndo(), isNull);
      expect(stack.takeRedo(), isNull);
    });

    test('撤销后出现重做分支；新编辑立刻作废重做', () {
      final UndoStack stack = UndoStack();
      stack.push(AddStroke(stroke('a')));
      stack.push(AddStroke(stroke('b')));
      expect(stack.undoDepth, 2);
      final InkCommand? undone = stack.takeUndo();
      expect(undone, isNotNull);
      expect(stack.canRedo, isTrue);
      // 新编辑
      stack.push(AddStroke(stroke('c')));
      expect(stack.canRedo, isFalse, reason: '新编辑后旧的重做分支必须作废');
      expect(stack.undoDepth, 2);
    });

    test('深度上限 50：超出丢最老的，撤销 50 次后到底', () {
      final UndoStack stack = UndoStack();
      for (int i = 0; i < 55; i++) {
        stack.push(AddStroke(stroke('s$i')));
      }
      expect(stack.undoDepth, UndoStack.defaultMaxDepth);
      int undone = 0;
      while (stack.takeUndo() != null) {
        undone++;
      }
      expect(undone, UndoStack.defaultMaxDepth);
      expect(stack.canUndo, isFalse);
    });

    test('clear() 把两边都清干净（重新载入时用）', () {
      final UndoStack stack = UndoStack();
      stack.push(AddStroke(stroke('a')));
      stack.takeUndo();
      expect(stack.canRedo, isTrue);
      stack.clear();
      expect(stack.canUndo, isFalse);
      expect(stack.canRedo, isFalse);
    });
  });
}
