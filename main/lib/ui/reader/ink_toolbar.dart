import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shuaqi/domain/ink/ink_doc.dart';
import 'package:shuaqi/state/ink_tool_provider.dart';
import 'package:shuaqi/ui/theme/tokens.dart';

/// 笔刷工具栏（T2.2）：钢笔 / 圆珠笔 / 荧光笔。
///
/// ## 为什么是文字而不是图标
/// "钢笔"和"圆珠笔"在 Material 图标里没有可区分的字形（都是铅笔），
/// 用户只能靠试。三个中文短词一次说清，比一对近似图标加 tooltip 诚实。
///
/// ## 交互（设计哲学：灵动 + 克制）
/// - 选中态 100ms 内变（[ShqMotion.instant]），有状态层（InkWell）不要动画大礼包；
/// - 只换 `selected` 的底色与字色，不做位移/缩放——工具栏是工具，不是玩具；
/// - 尺寸按 48dp 触控目标，笔尖点它不会误落墨（按钮吃掉指针，墨迹层收不到）。
///
/// ## 它改什么、不改什么
/// 只改**之后**画的新笔（见 [inkToolProvider]）。已落笔的笔迹保留自己的笔刷，
/// 因为笔迹是事实：换一支笔不该把过去写的东西重画一遍。
class InkToolbar extends ConsumerWidget {
  const InkToolbar({super.key});

  /// 展示顺序是"从细到粗"：钢笔（压感）→ 圆珠笔（等宽细）→ 荧光笔（宽）。
  static const List<_BrushItem> _items = <_BrushItem>[
    _BrushItem(InkStrokeStyle.pen, '钢笔'),
    _BrushItem(InkStrokeStyle.ballpoint, '圆珠笔'),
    _BrushItem(InkStrokeStyle.highlighter, '荧光笔'),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final InkStrokeStyle selected = ref.watch(inkToolProvider);
    final ColorScheme scheme = Theme.of(context).colorScheme;

    return Material(
      color: scheme.surfaceContainerHigh.withValues(alpha: 0.96),
      elevation: 3,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(ShqRadius.pill),
        side: BorderSide(color: scheme.outlineVariant, width: 1),
      ),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(ShqSpace.xs),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            for (final _BrushItem item in _items)
              _BrushSegment(
                label: item.label,
                selected: item.style == selected,
                onTap: () => ref.read(inkToolProvider.notifier).select(item.style),
              ),
          ],
        ),
      ),
    );
  }
}

class _BrushItem {
  const _BrushItem(this.style, this.label);

  final InkStrokeStyle style;
  final String label;
}

class _BrushSegment extends StatelessWidget {
  const _BrushSegment({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;

    return Semantics(
      button: true,
      selected: selected,
      label: label,
      child: InkWell(
        onTap: onTap,
        customBorder: const StadiumBorder(),
        child: AnimatedContainer(
          duration: ShqMotion.instant,
          curve: Curves.easeOutCubic,
          padding: const EdgeInsets.symmetric(
            horizontal: ShqSpace.md,
            vertical: ShqSpace.sm + 2,
          ),
          decoration: BoxDecoration(
            color: selected ? scheme.secondaryContainer : Colors.transparent,
            borderRadius: BorderRadius.circular(ShqRadius.pill),
          ),
          child: Text(
            label,
            style: theme.textTheme.bodySmall?.copyWith(
              fontSize: ShqType.bodySmall,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
              color: selected
                  ? scheme.onSecondaryContainer
                  : scheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }
}
