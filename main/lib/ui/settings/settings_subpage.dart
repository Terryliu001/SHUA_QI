import 'package:flutter/material.dart';
import 'package:shuaqi/ui/theme/tokens.dart';

/// 设置页的**二级页面**（关于下的三个入口）。
///
/// ## 为什么不用 `Navigator.push` 开新路由
/// 设置页活在外壳（`AppShell`）的 `IndexedStack` 里，左侧 `NavigationRail`
/// 是外壳的一部分。push 一个全屏路由会把导航栏一起盖住，用户会以为"退出去了"。
/// 所以二级页面是**设置页内部的一层**：滑进来、盖住内容区、左导航照旧。
///
/// 代价：不参与路由栈。系统返回键由设置页的 `PopScope` 拦一次
/// （有二级页时先回设置，而不是退出应用）。
enum SettingsSubPage {
  releaseNotes('版本说明'),
  userNotice('用户须知'),
  feedback('用户反馈');

  const SettingsSubPage(this.title);

  final String title;
}

/// 二级页的骨架：返回条 + 可滚动正文。
///
/// 返回键是**文字 + 图标**而不是纯图标：这一层的出口必须一眼可见
/// （用户是被"点进来"的，不是被导航过来的）。
class SettingsSubPageScaffold extends StatelessWidget {
  const SettingsSubPageScaffold({
    super.key,
    required this.page,
    required this.subtitle,
    required this.onClose,
    required this.child,
    this.actions = const <Widget>[],
  });

  final SettingsSubPage page;
  final String subtitle;
  final VoidCallback onClose;
  final Widget child;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    return ColoredBox(
      color: theme.scaffoldBackgroundColor,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(
              ShqSpace.sm,
              ShqSpace.sm,
              ShqSpace.md,
              ShqSpace.sm,
            ),
            child: Row(
              children: <Widget>[
                TextButton.icon(
                  onPressed: onClose,
                  icon: const Icon(Icons.arrow_back, size: 18),
                  label: const Text('设置'),
                  style: TextButton.styleFrom(
                    foregroundColor: scheme.onSurfaceVariant,
                    padding: const EdgeInsets.symmetric(
                      horizontal: ShqSpace.sm,
                    ),
                    minimumSize: const Size(0, 36),
                    visualDensity: VisualDensity.compact,
                  ),
                ),
                const SizedBox(width: ShqSpace.xs),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        page.title,
                        style: theme.textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                ...actions,
              ],
            ),
          ),
          Divider(height: 1, thickness: 1, color: scheme.outlineVariant),
          Expanded(child: child),
        ],
      ),
    );
  }
}

/// 二级页正文的统一版心与内边距（与设置页一致，切换时不跳动）。
class SettingsSubPageBody extends StatelessWidget {
  const SettingsSubPageBody({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: ShqLayout.maxFormWidth),
        child: ListView(
          padding: const EdgeInsets.only(
            left: ShqLayout.gutter,
            right: ShqLayout.gutter,
            top: ShqSpace.md,
            bottom: ShqSpace.xxl,
          ),
          children: children,
        ),
      ),
    );
  }
}

/// 二级页里的小节标题（与设置页分组标题同一套字）。
class SubPageSectionTitle extends StatelessWidget {
  const SubPageSectionTitle({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, ShqSpace.xl, 0, ShqSpace.sm),
      child: Text(
        text,
        style: theme.textTheme.labelMedium?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.8,
        ),
      ),
    );
  }
}

/// 一条带圆点的说明（用户须知 / 版本说明共用）。
class SubPageBullet extends StatelessWidget {
  const SubPageBullet(this.text, {super.key, this.color});

  final String text;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: ShqSpace.sm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.only(top: 7, right: ShqSpace.sm),
            child: Container(
              width: 4,
              height: 4,
              decoration: BoxDecoration(
                color: color ?? scheme.outline,
                shape: BoxShape.circle,
              ),
            ),
          ),
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurface,
                height: 1.7,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
