import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shuaqi/domain/ink/ink_tool.dart';
import 'package:shuaqi/state/ink_providers.dart';
import 'package:shuaqi/state/ink_tool_provider.dart';
import 'package:shuaqi/ui/theme/tokens.dart';

/// 笔刷工具栏（T2.2 三支笔 + T2.3 橡皮与撤销/重做）。
///
/// ## 为什么是文字而不是图标
/// "钢笔"和"圆珠笔"在 Material 图标里没有可区分的字形（都是铅笔），
/// 用户只能靠试。中文短词一次说清，比一对近似图标加 tooltip 诚实。
/// 橡皮与撤销/重做是**动作明确**的符号（橡皮擦 / 回转箭头），所以用图标。
///
/// ## 交互（设计哲学：灵动 + 克制）
/// - 选中态 100ms 内变（[ShqMotion.instant]），不做位移/缩放——工具栏是工具，不是玩具；
/// - 尺寸按 48dp 触控目标，笔尖点它不会误落墨（按钮吃掉指针，墨迹层收不到）；
/// - 撤销/重做按**当前页**取状态：这一页没东西可撤销时按钮是灰的（不装假功能）。
///
/// ## 它改什么、不改什么
/// 只改**之后**落下的笔（见 [inkToolProvider]）。已落笔的笔迹保留自己的笔刷，
/// 因为笔迹是事实：换一支笔不该把过去写的东西重画一遍。
class InkToolbar extends ConsumerWidget {
  const InkToolbar({super.key, required this.pageKey});

  /// 撤销/重做作用在哪一页。阅读器把"当前页"传进来——
  /// 撤销是**按页**的：滚到第 3 页时按撤销，撤的是第 3 页的笔，不会动别的页。
  final InkPageKey pageKey;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final InkTool selected = ref.watch(inkToolProvider);
    final bool canUndo = ref.watch(
      inkEditProvider(pageKey).select((InkEditState s) => s.canUndo),
    );
    final bool canRedo = ref.watch(
      inkEditProvider(pageKey).select((InkEditState s) => s.canRedo),
    );
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
            for (final InkTool tool in InkTool.values)
              _Segment(
                label: tool.label,
                selected: tool == selected,
                onTap: () => ref.read(inkToolProvider.notifier).select(tool),
              ),
            const SizedBox(width: ShqSpace.xs),
            SizedBox(
              height: 28,
              child: VerticalDivider(
                width: 1,
                thickness: 1,
                color: scheme.outlineVariant,
              ),
            ),
            const SizedBox(width: ShqSpace.xs),
            _IconAction(
              icon: Icons.undo,
              label: '撤销',
              enabled: canUndo,
              onTap: () => ref.read(inkEditProvider(pageKey).notifier).undo(),
            ),
            _IconAction(
              icon: Icons.redo,
              label: '重做',
              enabled: canRedo,
              onTap: () => ref.read(inkEditProvider(pageKey).notifier).redo(),
            ),
          ],
        ),
      ),
    );
  }
}

class _Segment extends StatelessWidget {
  const _Segment({
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

class _IconAction extends StatelessWidget {
  const _IconAction({
    required this.icon,
    required this.label,
    required this.enabled,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      enabled: enabled,
      label: label,
      child: InkResponse(
        onTap: enabled ? onTap : null,
        radius: 24,
        child: SizedBox(
          // 48dp 触控目标：笔尖点不中、手指点得准
          width: ShqLayout.minTouchTarget,
          height: ShqLayout.minTouchTarget,
          child: Icon(
            icon,
            size: 20,
            color: enabled ? scheme.onSurface : scheme.outlineVariant,
          ),
        ),
      ),
    );
  }
}
