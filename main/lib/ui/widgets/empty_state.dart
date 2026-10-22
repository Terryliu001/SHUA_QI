import 'package:flutter/material.dart';
import 'package:shuaqi/ui/theme/tokens.dart';

/// 空态占位（书架 / 记录 / 错题共用）。
///
/// 设计取向（设计哲学：iOS 的优雅简练 + 低干扰）：
/// 大号**线性**图标 + 一句标题 + 一句解释 + 一个主动作；
/// 不堆插画、不用红色警告色——空态是"还没开始"，不是"出错了"。
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.message,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String title;
  final String? message;

  /// 主动作（如"去书架"）。null 表示这个空态没有下一步，只告知。
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(ShqSpace.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              icon,
              size: 56,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: ShqSpace.md),
            Text(
              title,
              style: theme.textTheme.titleLarge,
              textAlign: TextAlign.center,
            ),
            if (message != null) ...<Widget>[
              const SizedBox(height: ShqSpace.sm),
              Text(
                message!,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                textAlign: TextAlign.center,
              ),
            ],
            if (actionLabel != null && onAction != null) ...<Widget>[
              const SizedBox(height: ShqSpace.lg),
              FilledButton.icon(
                onPressed: onAction,
                icon: const Icon(Icons.auto_stories_outlined),
                label: Text(actionLabel!),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
