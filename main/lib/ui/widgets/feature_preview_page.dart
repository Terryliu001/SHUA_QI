import 'package:flutter/material.dart';
import 'package:shuaqi/ui/theme/tokens.dart';
import 'package:shuaqi/ui/widgets/soft_icon.dart';

/// 一条"将来会有什么"的说明。
class FeaturePreviewItem {
  const FeaturePreviewItem({
    required this.icon,
    required this.title,
    required this.description,
  });

  final IconData icon;
  final String title;
  final String description;
}

/// 功能预览页：**诚实的未完成态**。
///
/// 记录 / 错题本在 T7 才真正落地。与其放一张空白的 "没有数据"，不如说清：
/// 这里将来会出现什么、为什么值得等、现在能先去哪儿。页面里没有任何可点的
/// 假入口——唯一的动作是"去书架"，它是真的。
class FeaturePreviewPage extends StatelessWidget {
  const FeaturePreviewPage({
    super.key,
    required this.appBarTitle,
    required this.icon,
    required this.headline,
    required this.message,
    required this.items,
    required this.onGoBookshelf,
    this.badge = '规划中',
  });

  final String appBarTitle;
  final IconData icon;
  final String headline;
  final String message;
  final List<FeaturePreviewItem> items;
  final VoidCallback onGoBookshelf;
  final String badge;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(title: Text(appBarTitle)),
      body: SafeArea(
        top: false,
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(
              ShqSpace.xl,
              ShqSpace.xl,
              ShqSpace.xl,
              ShqSpace.xxl,
            ),
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                maxWidth: ShqLayout.maxNarrativeWidth,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  SoftIcon(
                    icon: icon,
                    size: 88,
                    iconSize: 36,
                    circle: true,
                    background: scheme.secondaryContainer.withValues(
                      alpha: 0.55,
                    ),
                    color: scheme.onSecondaryContainer,
                  ),
                  const SizedBox(height: ShqSpace.lg),
                  _Badge(text: badge),
                  const SizedBox(height: ShqSpace.md),
                  Text(headline, style: theme.textTheme.headlineSmall),
                  const SizedBox(height: ShqSpace.sm),
                  Text(
                    message,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: ShqSpace.xl),
                  Card(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        for (int i = 0; i < items.length; i++) ...<Widget>[
                          if (i > 0)
                            Divider(
                              height: 1,
                              thickness: 1,
                              indent: ShqSpace.lg,
                              endIndent: ShqSpace.lg,
                              color: scheme.outlineVariant,
                            ),
                          _ItemRow(item: items[i]),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: ShqSpace.xl),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: onGoBookshelf,
                      icon: const Icon(Icons.auto_stories_outlined, size: 18),
                      label: const Text('去书架'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: ShqSpace.sm, vertical: 3),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(ShqRadius.pill),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Text(
        text,
        style: Theme.of(context).textTheme.labelSmall
            ?.copyWith(color: scheme.onSurfaceVariant, letterSpacing: 0.4),
      ),
    );
  }
}

class _ItemRow extends StatelessWidget {
  const _ItemRow({required this.item});

  final FeaturePreviewItem item;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: ShqSpace.lg,
        vertical: ShqSpace.md,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SoftIcon(icon: item.icon, size: 36, iconSize: 18),
          const SizedBox(width: ShqSpace.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(item.title, style: theme.textTheme.titleSmall),
                const SizedBox(height: 2),
                Text(
                  item.description,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
