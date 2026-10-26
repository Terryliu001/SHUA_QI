import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shuaqi/ui/theme/app_theme.dart';

/// 暗色模式下的底部提示条（SnackBar）与工具提示（2026-10-24）。
///
/// ## 为什么要有这个测试
///
/// 根因：M3 的 `inverseSurface` 在**暗色**主题里是**浅色**
/// （它按定义就是"surface 的反色"）。之前主题直接拿它当 SnackBar 底色，
/// 于是暗色界面里弹出**白底**小横条，在暖黑纸面上格外刺眼
/// （用户 2026-10-24 报"提示条都是白的"）。
///
/// 这类问题肉眼容易漏、回归容易犯，所以用**亮度断言**钉死：
/// 暗色下提示条必须是深色 + 浅字，浅色下保持深底浅字。
void main() {
  /// 相对亮度（0 = 黑，1 = 白）。用 WCAG 的公式，和人眼感受一致。
  double luminance(Color? color) {
    if (color == null) {
      return 1.0; // 没给颜色 = 透明，视为最亮（断言会失败，正是我们要的）
    }
    double channel(double v) =>
        v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
    return 0.2126 * channel(color.r) +
        0.7152 * channel(color.g) +
        0.0722 * channel(color.b);
  }

  testWidgets('暗色：提示条是深底浅字，不是白块', (WidgetTester tester) async {
    final ThemeData theme = ShqTheme.dark();
    final SnackBarThemeData bar = theme.snackBarTheme;

    // 底色必须是**深色**（亮度低）——之前是浅色（inverseSurface）。
    expect(
      luminance(bar.backgroundColor!),
      lessThan(0.2),
      reason: '暗色下 SnackBar 底色不该是浅色（inverseSurface 在暗色里是浅色）',
    );
    // 文字必须是**浅色**，否则深底深字看不见。
    expect(luminance(bar.contentTextStyle!.color!), greaterThan(0.5));

    // 真正渲染一条出来，确认主题真的落到界面上（不是只改了字段）。
    await tester.pumpWidget(
      MaterialApp(
        theme: theme,
        home: Scaffold(
          body: Builder(
            builder: (BuildContext context) => TextButton(
              onPressed: () => ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('已保存')),
              ),
              child: const Text('触发'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('触发'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    final Material barMaterial = tester.widget<Material>(
      find
          .descendant(
            of: find.byType(SnackBar),
            matching: find.byType(Material),
          )
          .first,
    );
    expect(luminance(barMaterial.color), lessThan(0.2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('暗色：工具提示也是深底浅字', (WidgetTester tester) async {
    final ThemeData theme = ShqTheme.dark();
    final TooltipThemeData tip = theme.tooltipTheme;
    final BoxDecoration decoration = tip.decoration! as BoxDecoration;
    expect(luminance(decoration.color), lessThan(0.2));
    expect(luminance(tip.textStyle!.color!), greaterThan(0.5));
  });

  testWidgets('浅色：保持深底浅字（不因这次改动变形）', (WidgetTester tester) async {
    final ThemeData theme = ShqTheme.light();
    final SnackBarThemeData bar = theme.snackBarTheme;
    expect(luminance(bar.backgroundColor!), lessThan(0.2));
    expect(luminance(bar.contentTextStyle!.color!), greaterThan(0.5));
  });
}
