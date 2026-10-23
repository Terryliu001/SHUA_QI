import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shuaqi/ui/theme/app_theme.dart';
import 'package:shuaqi/ui/widgets/empty_state.dart';
import 'package:shuaqi/ui/widgets/feature_preview_page.dart';

/// 设计收尾后的两个公共页在**窄屏 + 两套主题**下都不能溢出。
///
/// 这类测试比截图便宜：它抓的是 RenderFlex overflow / 布局异常，
/// 也就是"手机上看起来坏了"最常见的一类问题。
void main() {
  Future<void> pumpPhone(
    WidgetTester tester,
    Widget child, {
    ThemeData? theme,
  }) async {
    tester.view.physicalSize = const Size(360 * 3, 800 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(theme: theme ?? ShqTheme.light(), home: child),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('功能预览页：窄屏浅色不溢出', (WidgetTester tester) async {
    await pumpPhone(
      tester,
      FeaturePreviewPage(
        appBarTitle: '记录',
        icon: Icons.assignment_outlined,
        headline: '每一次作答，都留得住',
        message: '交卷之后，这里会有时间线、得分与回看入口。',
        items: const <FeaturePreviewItem>[
          FeaturePreviewItem(
            icon: Icons.timeline,
            title: '作答时间线',
            description: '哪天、哪一卷、做了多久，按卷子归档',
          ),
        ],
        onGoBookshelf: () {},
      ),
    );
    expect(tester.takeException(), isNull);
    expect(find.text('去书架'), findsOneWidget);
  });

  testWidgets('功能预览页：窄屏深色不溢出', (WidgetTester tester) async {
    await pumpPhone(
      tester,
      FeaturePreviewPage(
        appBarTitle: '错题本',
        icon: Icons.grade_outlined,
        headline: '错题不是判决，是待复核',
        message: '标记为存疑或做错的题会收进这里，随时回看原卷与当时的笔迹。',
        items: const <FeaturePreviewItem>[
          FeaturePreviewItem(
            icon: Icons.fact_check_outlined,
            title: '待复核题',
            description: '判为存疑或做错的题自动收进来，不预设结论',
          ),
        ],
        onGoBookshelf: () {},
      ),
      theme: ShqTheme.dark(),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('空态：动作图标跟随动作，不再固定成书本', (WidgetTester tester) async {
    await pumpPhone(
      tester,
      Scaffold(
        body: EmptyState(
          icon: Icons.search_off_outlined,
          title: '这里没有卷子',
          message: '换个词试试',
          actionLabel: '清除筛选',
          actionIcon: Icons.filter_alt_off_outlined,
          onAction: () {},
        ),
      ),
    );
    expect(find.byIcon(Icons.filter_alt_off_outlined), findsOneWidget);
    expect(find.byIcon(Icons.auto_stories_outlined), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
