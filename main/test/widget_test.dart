import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shuaqi/ui/app.dart';

void main() {
  testWidgets('骨架能启动，书架可见', (WidgetTester tester) async {
    await tester.pumpWidget(const ProviderScope(child: ShuaqiApp()));
    await tester.pumpAndSettle();

    expect(find.text('书架'), findsOneWidget);
    expect(find.text('刷起 SHUAQI'), findsOneWidget);
  });

  testWidgets('路由可用：能从书架进入阅读器', (WidgetTester tester) async {
    await tester.pumpWidget(const ProviderScope(child: ShuaqiApp()));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(FilledButton));
    await tester.pumpAndSettle();

    // 浅色主题下，纸感按设置生效（默认 original，所以这里不会出现"已自动退回"那句话）
    expect(find.textContaining('阅读器 · wb_demo'), findsOneWidget);
    expect(find.textContaining('纸 original'), findsOneWidget);
    expect(find.textContaining('已自动退回'), findsNothing);
  });
}
