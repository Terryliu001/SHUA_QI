import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shuaqi/domain/reader/reader_prefs.dart';
import 'package:shuaqi/ui/theme/app_theme.dart';
import 'package:shuaqi/ui/widgets/paper_effect.dart';

/// `PaperEffect` 的 widget 测试（宿主机可跑：它的 import 链不碰 pdfrx）。
///
/// 断言的粒度：**哪个分支生效**（有没有滤镜 / 有没有噪点），不解析矩阵数值——
/// 矩阵正确性由 `paper_tint_test.dart`（浅色乘法）与 `night_tint_test.dart`
/// （深色 duotone）在纯函数层覆盖。
///
/// 查找范围限定在 `PaperEffect` 子树内，避免 MaterialApp 内部件干扰。
void main() {
  Future<void> pump(
    WidgetTester tester,
    PaperStyle style,
    ThemeData theme,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: theme,
        home: Scaffold(
          body: Center(
            child: PaperEffect(
              style: style,
              intensity: 55,
              child: const SizedBox(width: 10, height: 10),
            ),
          ),
        ),
      ),
    );
  }

  Finder withinEffect(WidgetTester tester) =>
      find.descendant(of: find.byType(PaperEffect), matching: find.byType(Opacity));

  testWidgets('浅色 + original：零处理，没有任何滤镜层', (WidgetTester tester) async {
    await pump(tester, PaperStyle.original, ShqTheme.light());
    expect(
      find.descendant(
        of: find.byType(PaperEffect),
        matching: find.byType(ColorFiltered),
      ),
      findsNothing,
    );
    expect(withinEffect(tester), findsNothing); // 也没有噪点
  });

  testWidgets('浅色 + warm：乘法滤镜 + 噪点纹理', (WidgetTester tester) async {
    await pump(tester, PaperStyle.warm, ShqTheme.light());
    expect(
      find.descendant(
        of: find.byType(PaperEffect),
        matching: find.byType(ColorFiltered),
      ),
      findsOneWidget,
    );
    expect(withinEffect(tester), findsOneWidget);
  });

  testWidgets('深色：无论存的什么纸感，都套夜读 duotone 且不叠噪点', (
    WidgetTester tester,
  ) async {
    await pump(tester, PaperStyle.warm, ShqTheme.dark());
    expect(
      find.descendant(
        of: find.byType(PaperEffect),
        matching: find.byType(ColorFiltered),
      ),
      findsOneWidget,
    );
    expect(withinEffect(tester), findsNothing);
  });

  testWidgets('深色 + original：同样走夜读（遮罩是深色默认，不是纸感选项）', (
    WidgetTester tester,
  ) async {
    await pump(tester, PaperStyle.original, ShqTheme.dark());
    expect(
      find.descendant(
        of: find.byType(PaperEffect),
        matching: find.byType(ColorFiltered),
      ),
      findsOneWidget,
    );
  });
}
