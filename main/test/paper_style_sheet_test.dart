import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shuaqi/domain/reader/reader_prefs.dart';
import 'package:shuaqi/ui/reader/paper_style_sheet.dart';
import 'package:shuaqi/ui/theme/app_theme.dart';

/// 「显示」浮层的回归测试（2026-10-24）。
///
/// 事故根因：`Slider` 没写 `max: 100`，默认 0..1，而强度是 0..100 ——
/// 打开浮层的那一刻断言就炸，表现为"有弹窗但报错、什么都设不了"。
/// 这里同时覆盖：滑块范围、选夜读能回调、深色主题下不抛异常。
void main() {
  Future<List<ReaderPrefs>> pumpSheet(
    WidgetTester tester, {
    ThemeData? theme,
  }) async {
    final List<ReaderPrefs> changes = <ReaderPrefs>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: theme ?? ShqTheme.light(),
        home: Builder(
          builder: (BuildContext context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => showPaperStyleSheet(
                  context,
                  prefs: ReaderPrefs.defaults,
                  onChanged: changes.add,
                ),
                child: const Text('打开显示'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开显示'));
    await tester.pumpAndSettle();
    return changes;
  }

  testWidgets('强度滑块是 0..100，默认 55，不再触发断言', (WidgetTester tester) async {
    await pumpSheet(tester);
    expect(tester.takeException(), isNull);
    final Slider slider = tester.widget<Slider>(find.byType(Slider));
    expect(slider.min, 0);
    expect(slider.max, 100);
    expect(slider.value, ReaderPrefs.defaults.intensity.toDouble());
  });

  testWidgets('选夜读会回调，浮层不报错', (WidgetTester tester) async {
    final List<ReaderPrefs> changes = await pumpSheet(tester);
    await tester.tap(find.text('夜读'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(changes.last.style, PaperStyle.night);
  });

  testWidgets('深色主题下同样可用', (WidgetTester tester) async {
    await pumpSheet(tester, theme: ShqTheme.dark());
    expect(tester.takeException(), isNull);
    expect(find.text('暖白'), findsOneWidget);
  });
}
