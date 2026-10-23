import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shuaqi/domain/ink/ink_doc.dart';
import 'package:shuaqi/domain/ink/undo_stack.dart';
import 'package:shuaqi/state/ink_providers.dart';

/// T2.3 编辑控制器（抬笔 / 擦除 / 撤销 / 重做）的集成测试。
///
/// 走真实 provider（内存 store，不碰 DB / 文件），验证的是**用户能感知的行为**：
/// 一次擦除拖动只算一步撤销、撤销后能重做、新编辑作废旧的重做分支。
InkStroke stroke(String uid, {double x = 0}) => InkStroke(
  uid: uid,
  points: <InkPoint>[
    InkPoint(x: x, y: 0),
    InkPoint(x: x + 10, y: 10),
  ],
);

List<String> uids(ProviderContainer container, InkPageKey key) => container
    .read(inkDocProvider(key))
    .strokes
    .map((InkStroke s) => s.uid)
    .toList(growable: false);

void main() {
  const InkPageKey key = InkPageKey('session-1', 0);

  ProviderContainer newContainer() => ProviderContainer.test();

  test('抬笔可撤销、撤销可重做', () async {
    final ProviderContainer container = newContainer();
    addTearDown(container.dispose);
    final InkEditController ctrl = container.read(
      inkEditProvider(key).notifier,
    );

    await ctrl.commit(stroke('a'));
    expect(uids(container, key), <String>['a']);
    final InkEditState afterCommit = container.read(inkEditProvider(key));
    expect(afterCommit.canUndo, isTrue);
    expect(afterCommit.canRedo, isFalse);

    expect(ctrl.undo(), isTrue);
    expect(uids(container, key), isEmpty);
    expect(container.read(inkEditProvider(key)).canRedo, isTrue);

    expect(ctrl.redo(), isTrue);
    expect(uids(container, key), <String>['a']);
  });

  test('一次擦除拖动（整笔擦掉两笔）= 一步撤销，恢复后顺序正确', () async {
    final ProviderContainer container = newContainer();
    addTearDown(container.dispose);
    final InkEditController ctrl = container.read(
      inkEditProvider(key).notifier,
    );
    for (final String uid in <String>['a', 'b', 'c']) {
      await ctrl.commit(stroke(uid));
    }

    final InkDoc doc = container.read(inkDocProvider(key));
    // 整笔擦掉 = 碎片为空
    ctrl.applyErasePatches(<ErasePatch>[
      (index: 0, original: doc.strokes[0], fragments: const <InkStroke>[]),
      (index: 2, original: doc.strokes[2], fragments: const <InkStroke>[]),
    ]);
    expect(uids(container, key), <String>['b'], reason: '边划边擦：立刻消失');
    final InkDoc afterFirst = container.read(inkDocProvider(key));
    ctrl.applyErasePatches(<ErasePatch>[
      (index: 0, original: afterFirst.strokes[0], fragments: const <InkStroke>[]),
    ]);
    expect(uids(container, key), isEmpty);
    ctrl.endErase();

    // 一次撤销把这一整次拖动恢复（不是删一笔按一次）；
    // 三次抬笔还在栈里，所以撤销完擦除后还能继续撤。
    expect(ctrl.undo(), isTrue);
    expect(uids(container, key), <String>['a', 'b', 'c'], reason: 'z 序也要恢复');
    expect(container.read(inkEditProvider(key)).canUndo, isTrue);
    expect(container.read(inkEditProvider(key)).canRedo, isTrue);
    // 再撤 3 次把三次抬笔撤掉
    for (int i = 0; i < 3; i++) {
      expect(ctrl.undo(), isTrue);
    }
    expect(uids(container, key), isEmpty);
    expect(container.read(inkEditProvider(key)).canUndo, isFalse);
  });

  test('局部擦除：一笔切成两笔，撤销换回原笔（uid 也回来）', () async {
    final ProviderContainer container = newContainer();
    addTearDown(container.dispose);
    final InkEditController ctrl = container.read(
      inkEditProvider(key).notifier,
    );
    await ctrl.commit(stroke('a'));
    final InkStroke original = container.read(inkDocProvider(key)).strokes.single;

    final List<InkStroke> fragments = <InkStroke>[
      InkStroke(uid: 'a1', points: original.points.sublist(0, 1)),
      InkStroke(
        uid: 'a2',
        points: original.points.sublist(1),
        style: original.style,
        colorIndex: original.colorIndex,
        widthLevel: original.widthLevel,
      ),
    ];
    ctrl.applyErasePatches(<ErasePatch>[
      (index: 0, original: original, fragments: fragments),
    ]);
    expect(uids(container, key), <String>['a1', 'a2']);
    ctrl.endErase();

    expect(ctrl.undo(), isTrue);
    expect(uids(container, key), <String>['a'], reason: '碎片要换回原笔，不是留着碎片');
    expect(ctrl.redo(), isTrue);
    expect(uids(container, key), <String>['a1', 'a2']);
  });

  test('结构性改动会推进 epoch（绘制层据此整体重建）', () async {
    final ProviderContainer container = newContainer();
    addTearDown(container.dispose);
    final InkEditController ctrl = container.read(
      inkEditProvider(key).notifier,
    );
    await ctrl.commit(stroke('a'));
    final int afterAppend = container.read(inkEditProvider(key)).epoch;
    // 纯追加不动 epoch
    await ctrl.commit(stroke('b'));
    expect(
      container.read(inkEditProvider(key)).epoch,
      afterAppend,
      reason: '抬笔是纯追加，绘制层可以走增量',
    );
    // 擦除会动
    final InkDoc doc = container.read(inkDocProvider(key));
    ctrl.applyErasePatches(<ErasePatch>[
      (index: 0, original: doc.strokes.first, fragments: const <InkStroke>[]),
    ]);
    expect(
      container.read(inkEditProvider(key)).epoch,
      greaterThan(afterAppend),
    );
    // 撤销也会动
    final int afterErase = container.read(inkEditProvider(key)).epoch;
    ctrl.endErase();
    ctrl.undo();
    expect(
      container.read(inkEditProvider(key)).epoch,
      greaterThan(afterErase),
    );
  });

  test('新编辑清空重做分支', () async {
    final ProviderContainer container = newContainer();
    addTearDown(container.dispose);
    final InkEditController ctrl = container.read(
      inkEditProvider(key).notifier,
    );
    await ctrl.commit(stroke('a'));
    ctrl.undo();
    expect(container.read(inkEditProvider(key)).canRedo, isTrue);

    await ctrl.commit(stroke('b'));
    expect(container.read(inkEditProvider(key)).canRedo, isFalse);
    expect(uids(container, key), <String>['b']);
  });

  test('撤销 50 步以内不崩，且步数有上限', () async {
    final ProviderContainer container = newContainer();
    addTearDown(container.dispose);
    final InkEditController ctrl = container.read(
      inkEditProvider(key).notifier,
    );
    for (int i = 0; i < 60; i++) {
      await ctrl.commit(stroke('s$i'));
    }
    expect(container.read(inkDocProvider(key)).strokeCount, 60);

    int undone = 0;
    while (ctrl.undo()) {
      undone++;
    }
    expect(undone, 50, reason: '深度上限 50（规格 T2.3）');
    // 最老的 10 步已经在栈外：剩 10 笔删不掉
    expect(container.read(inkDocProvider(key)).strokeCount, 10);
    expect(container.read(inkEditProvider(key)).canUndo, isFalse);
  });

  test('清空整页可撤销', () async {
    final ProviderContainer container = newContainer();
    addTearDown(container.dispose);
    final InkEditController ctrl = container.read(
      inkEditProvider(key).notifier,
    );
    for (final String uid in <String>['a', 'b']) {
      await ctrl.commit(stroke(uid));
    }
    ctrl.clearPage();
    expect(uids(container, key), isEmpty);
    expect(ctrl.undo(), isTrue);
    expect(uids(container, key), <String>['a', 'b']);
  });

  test('任何改变笔画集合的操作都让 revision 递增（识别靠它失效）', () async {
    final ProviderContainer container = newContainer();
    addTearDown(container.dispose);
    final InkEditController ctrl = container.read(
      inkEditProvider(key).notifier,
    );
    await ctrl.commit(stroke('a'));
    final int afterCommit = container.read(inkDocProvider(key)).revision;
    ctrl.undo();
    final int afterUndo = container.read(inkDocProvider(key)).revision;
    ctrl.redo();
    final int afterRedo = container.read(inkDocProvider(key)).revision;
    expect(afterUndo, greaterThan(afterCommit));
    expect(afterRedo, greaterThan(afterUndo));
  });

  test('异步加载晚于首次落笔时，不覆盖刚写的笔（竞态加固）', () async {
    final ProviderContainer container = newContainer();
    addTearDown(container.dispose);
    final InkEditController ctrl = container.read(
      inkEditProvider(key).notifier,
    );
    // 不给 _load 完成的机会：立刻写一笔
    await ctrl.commit(stroke('a'));
    // 让 load 的 Future 跑完
    await Future<void>.delayed(Duration.zero);
    expect(uids(container, key), <String>['a'], reason: '磁盘旧内容不许盖掉内存新笔');
  });

  test('撤销后落盘内容跟着回退（内存 store 也算数）', () async {
    final ProviderContainer container = newContainer();
    addTearDown(container.dispose);
    final InkEditController ctrl = container.read(
      inkEditProvider(key).notifier,
    );
    await ctrl.commit(stroke('a'));
    ctrl.undo();
    // _save 是 unawaited 的，等它跑完
    await Future<void>.delayed(Duration.zero);
    final InkDoc saved = await container
        .read(inkStoreProvider)
        .load(key.sessionId, key.pageIndex);
    expect(saved.strokeCount, 0);
  });
}
