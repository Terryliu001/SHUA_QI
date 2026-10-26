import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shuaqi/domain/model/workbook.dart';
import 'package:shuaqi/infra/vault/vault.dart';
import 'package:shuaqi/state/app_providers.dart';
import 'package:shuaqi/ui/bookshelf/bookshelf_page.dart';
import 'package:shuaqi/ui/theme/app_theme.dart';

/// 大图卡片最窄一档的布局回归（2026-10-24）。
///
/// 现象：卡片调到「小」时，元信息行（页数 + 日期）与文件夹/标签 chip 会横向
/// 溢出，被裁成半个字。这里用真实书架 + 真实网格在最窄档渲染，让 Flutter
/// 自己报 RenderFlex overflow —— 只断言"没有异常"就够，不锁死像素。
void main() {
  /// 不用 `pumpAndSettle`：书架里有加载态/浮层动画时它可能一直等下去。
  /// 这里只推进固定的几帧，验证布局是否溢出与卡片是否真的建出来。
  Future<void> advance(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  testWidgets('大图卡片最窄一档：长标题 / 文件夹 / 标签都不溢出', (WidgetTester tester) async {
    // `testWidgets` 跑在 FakeAsync 里，真实文件 IO 必须走 runAsync，
    // 否则 createTemp 的 Future 永远不完成（第一次写这个测试就踩到了）。
    final Directory root = Directory.systemTemp.createTempSync('shq_shelf_');
    final Vault vault = (await tester.runAsync(() => Vault.open(root.path)))!;
    addTearDown(() {
      if (root.existsSync()) {
        root.deleteSync(recursive: true);
      }
    });

    final List<Workbook> items = <Workbook>[
      for (int i = 0; i < 8; i++)
        Workbook(
          id: 'wb_$i',
          title: i.isEven ? '2025-2026 第一学期 数学分析（上）期中试卷 超长标题' : '第 $i 套练习卷',
          sha1: 'sha_$i',
          pageCount: 4 + i,
          pageSize: 'A4',
          sourcePath: 'workbooks/wb_$i/source.pdf',
          createdAt: 1000 + i,
          openedAt: 2000 + i,
          folder: i.isEven ? '数学分析期中复习资料' : '',
          tags: <String>['期中', '错题'],
        ),
    ];

    tester.view.physicalSize = const Size(848 * 3, 1200 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          vaultProvider.overrideWithValue(vault),
          bookshelfProvider.overrideWith((Ref ref) async => items),
        ],
        child: MaterialApp(
          theme: ShqTheme.light(),
          home: const BookshelfPage(),
        ),
      ),
    );
    await advance(tester);
    expect(tester.takeException(), isNull);
    expect(find.text('全部'), findsOneWidget);

    // 切到大图，再把卡片调到最小。
    await tester.tap(find.byTooltip('视图'));
    await advance(tester);
    // Text 本身不参与命中，弹窗菜单项在它外面；点它的中心即可，别让
    // "would not hit test" 的测试警告掩盖真正的失败。
    await tester.tap(find.text('大图'), warnIfMissed: false);
    await advance(tester);
    expect(find.byType(GridView), findsOneWidget);

    await tester.tap(find.byTooltip('视图'));
    await advance(tester);
    await tester.tap(find.text('卡片大小…'));
    await advance(tester);

    await tester.drag(find.byType(Slider), const Offset(-600, 0));
    await advance(tester);
    expect(tester.widget<Slider>(find.byType(Slider)).value, 0);
    expect(tester.takeException(), isNull);

    // 收起浮层，让书架在最窄档完整重建一次。
    await tester.tapAt(const Offset(20, 20));
    await advance(tester);
    expect(tester.takeException(), isNull);
    expect(find.textContaining('数学分析'), findsWidgets);
    // 确认真的在最窄一档：卡片实际宽度应低于 150（150 是网格的 extent 上限）。
    final Size card = tester.getSize(find.byType(Card).first);
    expect(card.width, lessThan(150));
  }, timeout: const Timeout(Duration(minutes: 2)));
}
