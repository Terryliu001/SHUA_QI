import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shuaqi/state/shell_providers.dart';
import 'package:shuaqi/ui/bookshelf/bookshelf_page.dart';
import 'package:shuaqi/ui/favorites/favorites_page.dart';
import 'package:shuaqi/ui/records/records_page.dart';
import 'package:shuaqi/ui/settings/settings_page.dart';
import 'package:shuaqi/ui/theme/tokens.dart';

/// 应用外壳：四个主 tab + 自适应导航。
///
/// ## 为什么宽屏用侧边 rail、窄屏用底部 bar（M3 自适应）
/// 本产品主战场是平板（横屏 1200 / 竖屏 848 逻辑宽）：底部 bar 在平板上
/// 要么被拉得离谱，要么够不着；侧边 rail 是 Material 对中大屏的官方答案。
/// 阈值 600 逻辑宽——平板任何方向都走 rail，手机走底部 bar。
///
/// ## 为什么用 IndexedStack 而不是切页即重建
/// 书架的滚动位置、导入中的状态，切到设置再回来不该丢；
/// 但离屏页面的 build 仍会执行（只是不显示），所以每个 tab 都必须
/// 自己是"轻"的（列表页本来就是懒构建）。
///
/// 阅读器**不走 tab**：它是全屏 push 路由（`AppRoutes.reader`），
/// 从书架卡片进入、返回时回到原 tab——刷题是主流程，不该被 tab 框架包住。
class AppShell extends ConsumerStatefulWidget {
  const AppShell({super.key});

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell> {
  /// 页面只构造一次（IndexedStack 保活）。回调用 late final 绑到当前 State，
  /// 保证"去书架"类跳转永远打到最新的 setState。
  late final List<Widget> _pages = <Widget>[
    const BookshelfPage(),
    RecordsPage(onGoBookshelf: () => _select(kBookshelfTab)),
    FavoritesPage(onGoBookshelf: () => _select(kBookshelfTab)),
    const SettingsPage(),
  ];

  void _select(int index) {
    ref.read(shellTabProvider.notifier).select(index);
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool wide = MediaQuery.sizeOf(context).width >= 600;
    final int index = ref.watch(shellTabProvider);

    final List<_ShellDestination> destinations = <_ShellDestination>[
      const _ShellDestination(
        icon: Icons.auto_stories_outlined,
        selectedIcon: Icons.auto_stories,
        label: '书架',
      ),
      const _ShellDestination(
        icon: Icons.assignment_outlined,
        selectedIcon: Icons.assignment,
        label: '记录',
      ),
      const _ShellDestination(
        icon: Icons.bookmarks_outlined,
        selectedIcon: Icons.bookmarks,
        label: '收藏夹',
      ),
      const _ShellDestination(
        icon: Icons.settings_outlined,
        selectedIcon: Icons.settings,
        label: '设置',
      ),
    ];

    if (wide) {
      return Scaffold(
        body: Row(
          children: <Widget>[
            NavigationRail(
              selectedIndex: index,
              onDestinationSelected: _select,
              labelType: NavigationRailLabelType.all,
              // 顶部是产品徽标：一个"刷"字方块。比纯文字名更像产品，
              // 也不占导航的视觉重量（放大字号会跟 tab 抢注意力）。
              leading: Padding(
                padding: const EdgeInsets.only(top: ShqSpace.lg),
                child: Tooltip(
                  message: '刷起 SHUAQI',
                  child: Container(
                    width: 40,
                    height: 40,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primaryContainer,
                      borderRadius: BorderRadius.circular(ShqRadius.md),
                    ),
                    child: Text(
                      '刷',
                      style: theme.textTheme.titleMedium?.copyWith(
                        color: theme.colorScheme.onPrimaryContainer,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
              ),
              destinations: <NavigationRailDestination>[
                for (final _ShellDestination d in destinations)
                  NavigationRailDestination(
                    icon: Icon(d.icon),
                    selectedIcon: Icon(d.selectedIcon),
                    label: Text(d.label),
                  ),
              ],
            ),
            VerticalDivider(
              width: 1,
              thickness: 1,
              color: theme.colorScheme.outlineVariant,
            ),
            Expanded(
              child: IndexedStack(index: index, children: _pages),
            ),
          ],
        ),
      );
    }

    return Scaffold(
      body: IndexedStack(index: index, children: _pages),
      // 底部导航加一根发丝线：它不是"浮"在内容上的，而是与内容的分界。
      bottomNavigationBar: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(
            top: BorderSide(color: theme.colorScheme.outlineVariant),
          ),
        ),
        child: NavigationBar(
          selectedIndex: index,
          onDestinationSelected: _select,
          destinations: <Widget>[
            for (final _ShellDestination d in destinations)
              NavigationDestination(
                icon: Icon(d.icon),
                selectedIcon: Icon(d.selectedIcon),
                label: d.label,
              ),
          ],
        ),
      ),
    );
  }
}

class _ShellDestination {
  const _ShellDestination({
    required this.icon,
    required this.selectedIcon,
    required this.label,
  });

  final IconData icon;
  final IconData selectedIcon;
  final String label;
}
