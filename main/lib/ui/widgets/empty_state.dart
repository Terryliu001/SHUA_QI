import 'package:flutter/material.dart';
import 'package:shuaqi/ui/theme/tokens.dart';

/// 空态占位（书架 / 记录 / 错题共用）。
///
/// 设计取向（2026-10-23 设计升级 v2）：**软圆底 + 线性图标**，
/// 图标落在一层极淡的圆形色块上（ColorOS / M3 都在用），
/// 让"空"看起来是有意的留白，而不是渲染失败。
/// 仍然是：一句标题 + 一句解释 + 一个主动作；不堆插画、不用警告色。
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.message,
    this.actionLabel,
    this.actionIcon = Icons.auto_stories_outlined,
    this.onAction,
  });

  final IconData icon;
  final String title;
  final String? message;

  /// 主动作（如"去书架"）。null 表示这个空态没有下一步，只告知。
  final String? actionLabel;

  /// 动作图标跟着动作走（"去书架"用书，"清除筛选"用筛子）。
  final IconData actionIcon;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(
          maxWidth: ShqLayout.maxNarrativeWidth,
        ),
        child: Padding(
          padding: const EdgeInsets.all(ShqSpace.xl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Container(
                width: 96,
                height: 96,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: scheme.surfaceContainerHigh,
                  border: Border.all(color: scheme.outlineVariant),
                ),
                child: Icon(icon, size: 40, color: scheme.onSurfaceVariant),
              ),
              const SizedBox(height: ShqSpace.lg),
              Text(
                title,
                style: theme.textTheme.titleLarge,
                textAlign: TextAlign.center,
              ),
              if (message != null) ...<Widget>[
                const SizedBox(height: ShqSpace.xs),
                Text(
                  message!,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                  textAlign: TextAlign.center,
                ),
              ],
              if (actionLabel != null && onAction != null) ...<Widget>[
                const SizedBox(height: ShqSpace.lg),
                FilledButton.icon(
                  onPressed: onAction,
                  icon: Icon(actionIcon, size: 18),
                  label: Text(actionLabel!),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
