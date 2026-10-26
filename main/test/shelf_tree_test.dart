import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shuaqi/domain/model/shelf_folder.dart';
import 'package:shuaqi/domain/model/workbook.dart';
import 'package:shuaqi/ui/bookshelf/shelf_tree.dart';
import 'package:shuaqi/ui/theme/app_theme.dart';

Workbook _wb(String id, String title, {String folderId = ''}) => Workbook(
  id: id,
  title: title,
  sha1: id,
  pageCount: 4,
  pageSize: 'A4',
  sourcePath: '/tmp/$id.pdf',
  createdAt: 1000,
  openedAt: 1000,
  folderId: folderId,
  tags: const <String>[],
);

/// 树视图的回归（2026-10-24 用户第 9 条）。
///
/// 只验"结构对不对"：谁能被看到、点谁触发什么回调。像素不锁。
void main() {
  final List<ShelfFolder> folders = <ShelfFolder>[
    const ShelfFolder(id: 'a', name: '数学'),
    const ShelfFolder(id: 'b', name: '期中', parentId: 'a'),
    const ShelfFolder(id: 'c', name: '英语'),
  ];
  final List<Workbook> items = <Workbook>[
    _wb('w1', '卷一', folderId: 'a'),
    _wb('w2', '卷二', folderId: 'b'),
    _wb('w3', '卷三', folderId: 'c'),
    _wb('w4', '散卷'),
  ];

  int newFolderCount = 0;

  Widget buildTree({
    Set<String> expanded = const <String>{},
    String query = '',
    void Function(String)? onToggled,
    void Function(Workbook)? onOpened,
    void Function(Workbook, String)? onMoveWorkbook,
    void Function(String, String)? onMoveFolder,
    void Function(Workbook)? onWorkbookMenu,
  }) {
    return MaterialApp(
      theme: ShqTheme.light(),
      home: Scaffold(
        body: ShelfTree(
          folders: folders,
          expanded: expanded,
          workbooks: items,
          query: query,
          selectedFolderId: null,
          selecting: false,
          selectedIds: const <String>{},
          onToggleExpand: onToggled ?? (String _) {},
          onOpenWorkbook: (Workbook wb) => onOpened?.call(wb),
          onWorkbookMenu: (Workbook wb) => onWorkbookMenu?.call(wb),
          onToggleSelected: (String _) {},
          onFolderMenu: (ShelfFolder _) {},
          onOpenFolder: (String _) {},
          onNewFolder: () => newFolderCount += 1,
          onClearQuery: () {},
          onMoveWorkbook: onMoveWorkbook,
          onMoveFolder: onMoveFolder,
        ),
      ),
    );
  }

  /// 长按 → 拖到 [target] 上松手。
  ///
  /// [LongPressDraggable] 要等满长按延迟才接管指针，所以必须先
  /// `pump` 过 [kLongPressTimeout]，再给它一小段位移把拖动真正启动。
  Future<void> dragTo(WidgetTester tester, Finder from, Finder target) async {
    final Offset start = tester.getCenter(from);
    final TestGesture gesture = await tester.startGesture(start);
    await tester.pump(kLongPressTimeout);
    // 30 > kTouchSlop(18)：MultiDragPointerState 要位移超过 slop 才真正起拖。
    await gesture.moveTo(start + const Offset(0, 30));
    await tester.pump();
    await gesture.moveTo(tester.getCenter(target));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
  }

  testWidgets('展开的文件夹列出自己的卷，没展开的不列', (WidgetTester tester) async {
    await tester.pumpWidget(buildTree(expanded: <String>{'a'}));

    expect(find.text('数学'), findsOneWidget);
    expect(find.text('期中'), findsOneWidget);
    expect(find.text('英语'), findsOneWidget);
    // a 展开了 → 卷一可见；b 没展开 → 卷二看不见。
    expect(find.text('卷一'), findsOneWidget);
    expect(find.text('卷二'), findsNothing);
    expect(find.text('卷三'), findsNothing);
  });

  testWidgets('点文件夹行 = 切换展开（不是打开卷子）', (WidgetTester tester) async {
    final List<String> toggled = <String>[];
    await tester.pumpWidget(
      buildTree(
        // 期中是数学的子文件夹，得先把数学展开才看得到它。
        expanded: <String>{'a'},
        onToggled: (String id) => toggled.add(id),
      ),
    );
    await tester.tap(find.text('期中'));
    expect(toggled, <String>['b']);
  });

  testWidgets('「未分类」只在真的有散卷时出现，且默认收起', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(buildTree());
    expect(find.text('未分类'), findsOneWidget);
    expect(find.text('散卷'), findsNothing);

    await tester.pumpWidget(buildTree(expanded: <String>{''}));
    expect(find.text('散卷'), findsOneWidget);
  });

  testWidgets('搜索时只留命中的那条链，未分类与无关文件夹都消失', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(buildTree(query: '卷二'));
    // 卷二在 b（数学 / 期中）里 → 只留这条链。
    expect(find.text('数学'), findsOneWidget);
    expect(find.text('期中'), findsOneWidget);
    expect(find.text('英语'), findsNothing);
    expect(find.text('未分类'), findsNothing);
    expect(find.text('卷二'), findsOneWidget);
  });

  testWidgets('点文件名 = 打开这一卷', (WidgetTester tester) async {
    Workbook? opened;
    await tester.pumpWidget(
      buildTree(
        expanded: <String>{'a'},
        onOpened: (Workbook wb) => opened = wb,
      ),
    );
    await tester.tap(find.text('卷一'));
    expect(opened?.id, 'w1');
  });

  testWidgets('每行都有「在列表里查看」，是回到列表视图的出口', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(buildTree());
    expect(find.byTooltip('在列表里查看'), findsWidgets);
  });

  testWidgets('树里自带「新建文件夹」（列表的文件夹条在树视图是不出现的）', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(buildTree());
    await tester.tap(find.text('新建文件夹'));
    expect(newFolderCount, 1);
  });

  // ── 长按拖动改归属（2026-10-24 用户第 4 条）─────────────────────────

  testWidgets('长按把一卷拖进另一个文件夹', (WidgetTester tester) async {
    final List<String> moves = <String>[];
    await tester.pumpWidget(
      buildTree(
        expanded: <String>{'', 'c'},
        onMoveWorkbook: (Workbook wb, String folderId) =>
            moves.add('${wb.id}->$folderId'),
      ),
    );
    expect(find.text('散卷'), findsOneWidget);
    await dragTo(tester, find.text('散卷'), find.text('英语'));
    expect(moves, <String>['w4->c']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('长按把文件夹拖进另一个文件夹', (WidgetTester tester) async {
    final List<String> moves = <String>[];
    await tester.pumpWidget(
      buildTree(
        expanded: <String>{'a'},
        onMoveFolder: (String folderId, String parentId) =>
            moves.add('$folderId->$parentId'),
      ),
    );
    expect(find.text('期中'), findsOneWidget);
    await dragTo(tester, find.text('期中'), find.text('英语'));
    expect(moves, <String>['b->c']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('拖到「未分类」= 回到顶层', (WidgetTester tester) async {
    final List<String> moves = <String>[];
    await tester.pumpWidget(
      buildTree(
        expanded: <String>{'a'},
        onMoveWorkbook: (Workbook wb, String folderId) =>
            moves.add('${wb.id}->$folderId'),
      ),
    );
    await dragTo(tester, find.text('卷一'), find.text('未分类'));
    expect(moves, <String>['w1->']);
  });

  testWidgets('文件夹拖到自己身上 / 自己的子孙里不生效', (
    WidgetTester tester,
  ) async {
    final List<String> moves = <String>[];
    await tester.pumpWidget(
      buildTree(
        expanded: <String>{'a'},
        onMoveFolder: (String folderId, String parentId) =>
            moves.add('$folderId->$parentId'),
      ),
    );
    // 数学(a) 拖到 期中(b)：b 是 a 的子孙 → 会成环，必须挡掉。
    await dragTo(tester, find.text('数学'), find.text('期中'));
    expect(moves, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('没接拖动回调时，长按仍是菜单，也不多出按钮', (
    WidgetTester tester,
  ) async {
    Workbook? menuOf;
    await tester.pumpWidget(
      buildTree(
        expanded: <String>{''},
        onWorkbookMenu: (Workbook wb) => menuOf = wb,
      ),
    );
    expect(find.byTooltip('更多操作'), findsNothing);
    await tester.longPress(find.text('散卷'));
    await tester.pumpAndSettle();
    expect(menuOf?.id, 'w4');
  });

  testWidgets('接了拖动回调后，菜单改由行尾按钮承担', (WidgetTester tester) async {
    Workbook? menuOf;
    await tester.pumpWidget(
      buildTree(
        expanded: <String>{''},
        onMoveWorkbook: (Workbook workbook, String folderId) {},
        onWorkbookMenu: (Workbook wb) => menuOf = wb,
      ),
    );
    expect(find.byTooltip('更多操作'), findsWidgets);
    await tester.tap(find.byTooltip('更多操作').first);
    await tester.pumpAndSettle();
    expect(menuOf?.id, 'w4');
  });
}
