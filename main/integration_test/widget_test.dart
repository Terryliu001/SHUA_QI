import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shuaqi/domain/model/workbook.dart';
import 'package:shuaqi/state/app_providers.dart';
import 'package:shuaqi/ui/app.dart';
import 'package:shuaqi/ui/bookshelf/bookshelf_page.dart';
import 'package:shuaqi/ui/router.dart';

void main() {
  // 注意：书架会读 bookshelfProvider，而它默认要 appDependenciesProvider（真数据库）。
  // 宿主机测试不建库，所以这里直接把 bookshelfProvider 覆盖成空列表。
  testWidgets('书架空态可见', (WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          bookshelfProvider.overrideWith((Ref ref) async => <Workbook>[]),
        ],
        child: const ShuaqiApp(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('书架'), findsOneWidget);
    expect(find.text('还没有导入任何卷子'), findsOneWidget);
    expect(find.text('导入 PDF'), findsWidgets);
  });

  test('路由表：reader 能生成路由，未知路径返回 null', () {
    final Route<dynamic>? reader = AppRoutes.onGenerateRoute(
      const RouteSettings(
        name: AppRoutes.reader,
        arguments: ReaderRouteArgs(workbookId: 'wb_demo'),
      ),
    );
    expect(reader, isNotNull);
    expect(reader, isA<MaterialPageRoute<void>>());

    final Route<dynamic>? shell = AppRoutes.onGenerateRoute(
      const RouteSettings(name: AppRoutes.shell),
    );
    expect(shell, isNotNull);

    // 未知路由必须返回 null，让 Navigator 抛标准错误，而不是静默吞掉
    expect(AppRoutes.onGenerateRoute(const RouteSettings(name: '/nope')), isNull);
  });

  group('formatRelativeTime', () {
    final DateTime now = DateTime(2026, 10, 22, 12);

    test('一分钟内显示「刚刚」', () {
      final int at = now
          .subtract(const Duration(seconds: 30))
          .millisecondsSinceEpoch;
      expect(formatRelativeTime(at, now: now), '刚刚');
    });

    test('分钟 / 小时 / 天 三档', () {
      expect(
        formatRelativeTime(
          now.subtract(const Duration(minutes: 5)).millisecondsSinceEpoch,
          now: now,
        ),
        '5 分钟前',
      );
      expect(
        formatRelativeTime(
          now.subtract(const Duration(hours: 3)).millisecondsSinceEpoch,
          now: now,
        ),
        '3 小时前',
      );
      expect(
        formatRelativeTime(
          now.subtract(const Duration(days: 2)).millisecondsSinceEpoch,
          now: now,
        ),
        '2 天前',
      );
    });

    test('超过 30 天显示日期', () {
      final DateTime old = DateTime(2026, 1, 5, 9);
      expect(
        formatRelativeTime(old.millisecondsSinceEpoch, now: now),
        '2026-01-05',
      );
    });
  });
}
