import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shuaqi/domain/reader/reader_prefs.dart';
import 'package:shuaqi/ui/reader/reader_top_actions.dart';
import 'package:shuaqi/ui/theme/app_theme.dart';

/// 阅读器顶栏动作区（2026-10-24 抽出）。
///
/// ## 为什么要单独测
///
/// 顶栏动作会**互相抢空间**：`AppBar` 的 actions 先按自身宽度排，
/// 标题是唯一可压缩的那个，压不下去。实测（360dp 手机竖屏）：
///
/// - 6 个动作 + 缩放胶囊：刚好不溢出；
/// - 7 个动作（加「保存」）：**溢出 33px**。
///
/// 所以"加一个按钮"必须连带决定**窄屏下谁让路**，并用测试钉住，
/// 否则以后再加一个按钮就会在手机上炸出黄黑条。
void main() {
  List<Widget> actions({
    required double width,
    ViewMode mode = ViewMode.paged,
    bool canUndo = true,
    bool canRedo = true,
    bool handTool = false,
    bool panelOpen = false,
    bool hasThumbnails = true,
    void Function()? onSave,
    void Function()? onOpenDisplay,
  }) {
    return buildReaderTopActions(
      width: width,
      canUndo: canUndo,
      canRedo: canRedo,
      onUndo: () {},
      onRedo: () {},
      onSave: onSave ?? () {},
      handTool: handTool,
      onToggleHandTool: () {},
      mode: mode,
      onToggleMode: () {},
      scrollZoom: 0.86,
      onZoomSelected: (_) {},
      onOpenDisplay: onOpenDisplay ?? () {},
      panelOpen: panelOpen,
      onTogglePanel: () {},
      onOpenThumbnails: () {},
      hasThumbnails: hasThumbnails,
      onOpenAnswerSheet: () {},
    );
  }

  Future<void> pumpBar(
    WidgetTester tester, {
    required double width,
    ViewMode mode = ViewMode.paged,
    void Function()? onSave,
  }) async {
    tester.view.physicalSize = Size(width * 3, 800 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: ShqTheme.light(),
        home: Scaffold(
          appBar: AppBar(
            title: const Text('2024 届高三数学一模试卷'),
            actions: actions(width: width, mode: mode, onSave: onSave),
          ),
          body: const SizedBox.shrink(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('「保存」在顶栏且可点', (WidgetTester tester) async {
    bool saved = false;
    await pumpBar(tester, width: 848, onSave: () => saved = true);

    expect(find.byIcon(Icons.save_outlined), findsOneWidget);
    // tooltip 也要对：图标本身不告诉你这是"保存答题情况"。
    final IconButton button = tester.widget<IconButton>(
      find.ancestor(
        of: find.byIcon(Icons.save_outlined),
        matching: find.byType(IconButton),
      ),
    );
    expect(button.tooltip, '保存答题情况');

    await tester.tap(find.byIcon(Icons.save_outlined));
    expect(saved, isTrue);
  });

  testWidgets('窄屏（360dp）加保存后不溢出', (WidgetTester tester) async {
    // 这是本文件存在的理由：不收动作就会溢出 33px。
    await pumpBar(tester, width: 360);
    expect(tester.takeException(), isNull);
  });

  testWidgets('窄屏（360dp）滚动模式 + 缩放胶囊也不溢出', (WidgetTester tester) async {
    await pumpBar(tester, width: 360, mode: ViewMode.scroll);
    expect(tester.takeException(), isNull);
  });

  testWidgets('平板（848dp）不溢出', (WidgetTester tester) async {
    await pumpBar(tester, width: 848, mode: ViewMode.scroll);
    expect(tester.takeException(), isNull);
  });

  testWidgets('宽屏：「显示设置」留在顶栏', (WidgetTester tester) async {
    await pumpBar(tester, width: 848);
    expect(find.byIcon(Icons.palette_outlined), findsOneWidget);
  });

  testWidgets('题目区域 / 缩略图 / 答题卡都直接出现在顶栏', (
    WidgetTester tester,
  ) async {
    await pumpBar(tester, width: 848);
    expect(find.byIcon(Icons.crop_free), findsOneWidget);
    expect(find.byIcon(Icons.grid_view_outlined), findsOneWidget);
    expect(find.byIcon(Icons.assignment_outlined), findsOneWidget);
  });

  testWidgets('窄屏：三个入口仍在顶栏，低频动作收进「更多」', (
    WidgetTester tester,
  ) async {
    await pumpBar(tester, width: 360);
    // 用户要求这三个入口不藏。
    expect(find.byIcon(Icons.crop_free), findsOneWidget);
    expect(find.byIcon(Icons.grid_view_outlined), findsOneWidget);
    expect(find.byIcon(Icons.assignment_outlined), findsOneWidget);
    // 显示设置收进菜单。
    expect(find.byIcon(Icons.palette_outlined), findsNothing);
    await tester.tap(find.byIcon(Icons.more_horiz));
    await tester.pumpAndSettle();
    expect(find.text('显示设置'), findsOneWidget);
    expect(find.text('切换到手势模式'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('撤销/重做不可用时是灰的（不是消失）', (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ShqTheme.light(),
        home: Scaffold(
          appBar: AppBar(
            title: const Text('卷'),
            actions: actions(width: 848, canUndo: false, canRedo: false),
          ),
          body: const SizedBox.shrink(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final IconButton undo = tester.widget<IconButton>(
      find.ancestor(
        of: find.byIcon(Icons.undo),
        matching: find.byType(IconButton),
      ),
    );
    expect(undo.onPressed, isNull);
    expect(find.byIcon(Icons.undo), findsOneWidget);
  });
}
