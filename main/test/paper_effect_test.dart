import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shuaqi/domain/reader/reader_prefs.dart';
import 'package:shuaqi/ui/theme/app_theme.dart';
import 'package:shuaqi/ui/widgets/paper_effect.dart';

/// `PaperEffect` 的 widget 测试（宿主机可跑：它的 import 链不碰 pdfrx）。
///
/// 断言的粒度：**哪个分支生效**（有没有滤镜 / 有没有噪点），不解析矩阵数值——
/// 矩阵正确性由 `paper_tint_test.dart`（乘法）与 `night_tint_test.dart`
/// （夜读 duotone）在纯函数层覆盖。
///
/// 2026-10-22 变更：卷面配色不再跟随 App 主题。下面第二组用例（"深色主题 +
/// 原图 = 零处理"）就是那次拍板的定点锁定——旧实现会让深色主题把 PDF 涂成夜读。
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

  Finder filter(WidgetTester tester) => find.descendant(
    of: find.byType(PaperEffect),
    matching: find.byType(ColorFiltered),
  );

  Finder noise(WidgetTester tester) => find.descendant(
    of: find.byType(PaperEffect),
    matching: find.byType(Opacity),
  );

  group('浅色主题', () {
    testWidgets('original：零处理，没有任何滤镜层', (WidgetTester tester) async {
      await pump(tester, PaperStyle.original, ShqTheme.light());
      expect(filter(tester), findsNothing);
      expect(noise(tester), findsNothing);
    });

    testWidgets('warm：乘法滤镜 + 噪点纹理', (WidgetTester tester) async {
      await pump(tester, PaperStyle.warm, ShqTheme.light());
      expect(filter(tester), findsOneWidget);
      expect(noise(tester), findsOneWidget);
    });

    testWidgets('night：duotone 反色 + 不叠噪点', (WidgetTester tester) async {
      await pump(tester, PaperStyle.night, ShqTheme.light());
      expect(filter(tester), findsOneWidget);
      expect(noise(tester), findsNothing);
    });
  });

  group('深色主题（只影响界面，不该改卷面）', () {
    testWidgets('original：仍是白底黑字，零处理', (WidgetTester tester) async {
      await pump(tester, PaperStyle.original, ShqTheme.dark());
      expect(
        filter(tester),
        findsNothing,
        reason: '深色主题把 PDF 涂成夜读是 2026-10-22 修掉的设计错误',
      );
      expect(noise(tester), findsNothing);
    });

    testWidgets('warm：纸感照常生效（不再让位给夜读）', (WidgetTester tester) async {
      await pump(tester, PaperStyle.warm, ShqTheme.dark());
      expect(filter(tester), findsOneWidget);
      expect(noise(tester), findsOneWidget);
    });

    testWidgets('night：夜读照旧', (WidgetTester tester) async {
      await pump(tester, PaperStyle.night, ShqTheme.dark());
      expect(filter(tester), findsOneWidget);
      expect(noise(tester), findsNothing);
    });
  });
}
