import 'package:flutter/material.dart';
import 'package:shuaqi/ui/theme/tokens.dart';
import 'package:shuaqi/ui/widgets/pressable.dart';

/// 顶栏 / 工具栏的动作按钮：**图标 +（可选）功能文字**。
///
/// ## 为什么要有文字形态
/// 纯图标顶栏对"熟手"最快，对"第一次用"的人全靠猜。2026-10-26 用户要求
/// 提供一个可手动切换的**文字模式**：图标旁边写上「保存」「题目」「答题卡」
/// 这类两三个字的说明。UI 布局不动（还是同一个位置、同一个图标），
/// 只是多了一行字——所以它是**渐进增强**，不改变既有设计语言。
///
/// ## 宽度是硬约束
/// 带文字的按钮宽度约为纯图标的 1.6 倍，8 个动作排下来会吃掉 200dp 以上。
/// 所以调用方必须先问 [labelsFitWidth]：放不下就退回纯图标，
/// **不能靠溢出条或压缩标题来兜底**（AppBar 的 actions 压不动标题）。
class LabeledAction extends StatelessWidget {
  const LabeledAction({
    super.key,
    required this.icon,
    required this.label,
    this.onPressed,
    this.selected = false,
    this.selectedIcon,
    this.showLabel = false,
    this.compact = false,
    this.tooltip,
  });

  final IconData icon;

  /// 功能文字（1–4 字）。[showLabel] 为 false 时只当无障碍标签用。
  final String label;

  final VoidCallback? onPressed;
  final bool selected;
  final IconData? selectedIcon;

  /// 是否显示文字。false = 纯图标（既有形态）。
  final bool showLabel;

  /// 紧凑形态：纯图标时按钮更窄（窄屏顶栏用）。
  final bool compact;

  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    if (!showLabel) {
      return IconButton(
        tooltip: tooltip ?? label,
        onPressed: onPressed,
        isSelected: selected,
        selectedIcon: selectedIcon == null ? null : Icon(selectedIcon),
        icon: Icon(icon),
        iconSize: compact ? 20 : 22,
        padding: compact ? EdgeInsets.zero : null,
        constraints: compact
            ? const BoxConstraints.tightFor(width: 40, height: 48)
            : null,
      );
    }
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final IconData glyph = selected && selectedIcon != null ? selectedIcon! : icon;
    final Color color = selected ? scheme.primary : scheme.onSurfaceVariant;
    return Tooltip(
      message: tooltip ?? label,
      child: Pressable(
        onTap: onPressed,
        scale: 0.94,
        haptic: true,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: ShqSpace.sm,
            vertical: ShqSpace.xs,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(glyph, size: 19, color: color),
              const SizedBox(width: 3),
              Text(
                label,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: color,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  height: 1.1,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 菜单型动作的**标签部分**（给 `PopupMenuButton` 当 child 用）。
///
/// 为什么单独一个类：`PopupMenuButton` 自己处理点击，child 只能是"长什么样"，
/// 不能是可点的按钮。所以这里只画图标 + 文字，不带手势。
class LabeledActionLabel extends StatelessWidget {
  const LabeledActionLabel({
    super.key,
    required this.icon,
    required this.label,
    this.showLabel = false,
    this.selected = false,
  });

  final IconData icon;
  final String label;
  final bool showLabel;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final Color color = selected ? scheme.primary : scheme.onSurfaceVariant;
    if (!showLabel) {
      return Icon(icon, size: 22, color: color);
    }
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: ShqSpace.sm,
        vertical: ShqSpace.xs,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(icon, size: 19, color: color),
          const SizedBox(width: 3),
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: color,
              fontWeight: FontWeight.w500,
              height: 1.1,
            ),
          ),
        ],
      ),
    );
  }
}

/// 带文字的动作大概占多宽（逻辑像素）。
///
/// 18dp 图标 + 3dp 间距 + 最多 4 个字（11px 字，约 44dp）+ 两侧 16dp 内边距
/// ≈ 81dp；这里取 84 留一点余量，**宁可估宽也别溢出**。
const double kLabeledActionWidth = 84;

/// 纯图标动作大概占多宽。
const double kIconActionWidth = 48;

/// 给标题与缩放胶囊预留的位置（逻辑像素）。
const double kTopBarReservedWidth = 240;

/// 当前宽度能不能放下 [actionCount] 个带文字的动作。
///
/// 纯函数，方便单测钉住"文字模式不会把顶栏挤爆"。
bool labelsFitWidth({
  required double width,
  required int actionCount,
  double perAction = kLabeledActionWidth,
  double reserved = kTopBarReservedWidth,
}) => width - reserved >= actionCount * perAction;
