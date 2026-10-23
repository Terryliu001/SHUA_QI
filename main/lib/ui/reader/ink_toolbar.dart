import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shuaqi/domain/ink/eraser.dart';
import 'package:shuaqi/domain/ink/ink_brush.dart';
import 'package:shuaqi/domain/ink/ink_palette.dart';
import 'package:shuaqi/domain/ink/ink_tool.dart';
import 'package:shuaqi/domain/ink/ink_width.dart';
import 'package:shuaqi/state/ink_tool_provider.dart';
import 'package:shuaqi/ui/reader/ink_painters.dart';
import 'package:shuaqi/ui/theme/tokens.dart';

/// 笔刷工具条（T2.2/T2.3 → 2026-10-23 重做）。
///
/// ## 两种形态（用户拍板"两套都要，设置里可切"）
/// - [InkFab]：右下角**一个圆钮**，常态只显示"当前笔 + 当前颜色"，
///   点一下向上展开面板（工具 / 颜色 / 粗细）。默认形态，最省阅读区。
/// - [InkToolStrip]：固定到顶栏下方的一条 52dp 横条，三段并排、零展开。
///
/// ## 为什么不做成原来那条长浮窗
/// 横条浮窗宽约 400dp，压在页面右下角会遮题干，而且"当前选了哪支笔"
/// 要在一排文字里找。圆形浮钮把当前状态压成一个图标 + 一个色点，
/// 展开后才铺开选项——**阅读时等于没有工具栏，要写时点一下就有**。
///
/// ## 撤销/重做不在这里
/// 它们是"文档动作"、频率高，放在顶栏（1 次点击），不藏在工具面板里。

/// 工具图标。钢笔/圆珠笔在 Material 里没有可区分字形，靠"笔尖 vs 圆头"区分，
/// 所以图标旁边**必须**带中文短名（见 [_ToolButton]）。
IconData iconOfTool(InkTool tool) => switch (tool) {
  InkTool.pen => Icons.edit_outlined,
  InkTool.ballpoint => Icons.create_outlined,
  InkTool.highlighter => Icons.border_color_outlined,
  InkTool.eraser => Icons.auto_fix_normal_outlined,
};

// ── 浮钮形态 ─────────────────────────────────────────────────────────

/// 右下角圆形浮钮：收起时是一个 56dp 圆，点开展开设置面板。
class InkFab extends ConsumerStatefulWidget {
  const InkFab({super.key, required this.darkPaper});

  /// 当前纸是暗的还是亮的（决定色块预览色）。
  final bool darkPaper;

  @override
  ConsumerState<InkFab> createState() => _InkFabState();
}

class _InkFabState extends ConsumerState<InkFab> {
  bool _open = false;

  void _toggle() => setState(() => _open = !_open);

  @override
  Widget build(BuildContext context) {
    final InkBrush brush = ref.watch(inkToolProvider);
    final ColorScheme scheme = Theme.of(context).colorScheme;
    // 橡皮没有颜色，收起态就不该显示色点。
    final Color? dot = brush.isEraser
        ? null
        : previewColorOf(
            style: brush.strokeStyle,
            colorIndex: brush.colorIndex,
            darkPaper: widget.darkPaper,
          );

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: <Widget>[
        // 展开面板：AnimatedSize 让"长出来"有 150ms 的呼吸，不做弹跳。
        AnimatedSize(
          duration: ShqMotion.fast,
          curve: Curves.easeOutCubic,
          alignment: Alignment.bottomRight,
          child: _open
              ? Padding(
                  padding: const EdgeInsets.only(bottom: ShqSpace.sm),
                  child: _ToolPanel(
                    darkPaper: widget.darkPaper,
                    onPick: (_) => setState(() {}),
                  ),
                )
              : const SizedBox.shrink(),
        ),
        Material(
          color: scheme.surfaceContainerHigh.withValues(alpha: 0.97),
          elevation: 4,
          shape: CircleBorder(
            side: BorderSide(
              color: _open ? scheme.primary : scheme.outlineVariant,
              width: _open ? 2 : 1,
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: _toggle,
            child: SizedBox(
              width: 56,
              height: 56,
              child: Stack(
                alignment: Alignment.center,
                children: <Widget>[
                  Icon(
                    _open ? Icons.close : iconOfTool(brush.tool),
                    size: 24,
                    color: scheme.onSurface,
                  ),
                  if (dot != null && !_open)
                    Positioned(
                      right: 9,
                      bottom: 9,
                      child: _ColorDot(color: dot, size: 12),
                    ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// 展开后的面板：工具 / 颜色 / 粗细竖排三段。
class _ToolPanel extends ConsumerWidget {
  const _ToolPanel({required this.darkPaper, required this.onPick});

  final bool darkPaper;

  /// 选完一项后的回调（浮钮用它刷新"当前色点"）。
  final ValueChanged<Object?> onPick;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final InkBrush brush = ref.watch(inkToolProvider);
    final InkToolController controller = ref.read(inkToolProvider.notifier);
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final bool erased = brush.isEraser;

    return Material(
      color: scheme.surfaceContainerHigh.withValues(alpha: 0.98),
      elevation: 4,
      borderRadius: BorderRadius.circular(ShqRadius.lg),
      clipBehavior: Clip.antiAlias,
      child: Container(
        padding: const EdgeInsets.all(ShqSpace.md),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(ShqRadius.lg),
          border: Border.all(color: scheme.outlineVariant),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            // 面板头：一条"钉到顶栏"的动作 —— 两种形态在阅读器里**互相可切**，
            // 不用绕去设置页（用户 2026-10-23 要求"自然一点"）。
            Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                const _SectionLabel('笔刷'),
                const SizedBox(width: ShqSpace.sm),
                _ModeSwitchButton(
                  icon: Icons.vertical_align_top,
                  label: '固定到顶栏',
                  onTap: () => ref
                      .read(inkToolbarPinnedProvider.notifier)
                      .set(true),
                ),
              ],
            ),
            const SizedBox(height: ShqSpace.xs),
            const _SectionLabel('工具'),
            const SizedBox(height: ShqSpace.xs),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                for (final InkTool tool in InkTool.values)
                  _ToolButton(
                    tool: tool,
                    selected: brush.tool == tool,
                    onTap: () {
                      controller.selectTool(tool);
                      onPick(tool);
                    },
                  ),
              ],
            ),
            if (!erased) ...<Widget>[
              const SizedBox(height: ShqSpace.md),
              const _SectionLabel('颜色'),
              const SizedBox(height: ShqSpace.xs),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  for (
                    int i = 0;
                    i < InkPalette.countFor(brush.strokeStyle);
                    i++
                  )
                    _ColorDot(
                      color: previewColorOf(
                        style: brush.strokeStyle,
                        colorIndex: i,
                        darkPaper: darkPaper,
                      ),
                      size: 26,
                      selected: brush.colorIndex == i,
                      onTap: () {
                        controller.selectColor(i);
                        onPick(i);
                      },
                    ),
                ],
              ),
              const SizedBox(height: ShqSpace.md),
              const _SectionLabel('粗细'),
              const SizedBox(height: ShqSpace.xs),
              _BrushWidthSlider(
                brush: brush,
                darkPaper: darkPaper,
                onChanged: (int value) {
                  controller.selectWidth(value);
                  onPick(value);
                },
              ),
            ],
            if (erased) ...<Widget>[
              const SizedBox(height: ShqSpace.md),
              const _SectionLabel('橡皮大小'),
              const SizedBox(height: ShqSpace.xs),
              _BrushWidthSlider(
                brush: brush,
                darkPaper: darkPaper,
                onChanged: (int value) {
                  // 橡皮大小复用 brushWidth（每支笔分别记忆自己的设置）。
                  controller.selectWidth(value);
                  onPick(value);
                },
              ),
              const SizedBox(height: ShqSpace.xs),
              Text(
                '划过即擦：只擦掉碰到的那一段，可撤销',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ── 顶栏形态 ─────────────────────────────────────────────────────────

/// 固定形态：顶栏下方的一条工具带（工具 / 颜色 / 粗细三段并排）。
///
/// 为什么放在 AppBar 的 bottom 而不是塞进 actions：actions 里再加 7 个图标
/// 会把标题挤没；颜色/粗细也需要一排色块，不是一两个图标能说清的。
class InkToolStrip extends ConsumerWidget implements PreferredSizeWidget {
  const InkToolStrip({super.key, required this.darkPaper});

  final bool darkPaper;

  @override
  Size get preferredSize => const Size.fromHeight(52);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final InkBrush brush = ref.watch(inkToolProvider);
    final InkToolController controller = ref.read(inkToolProvider.notifier);
    final ColorScheme scheme = Theme.of(context).colorScheme;

    return Container(
      height: preferredSize.height,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        border: Border(bottom: BorderSide(color: scheme.outlineVariant)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: ShqSpace.md),
      child: Row(
        children: <Widget>[
          for (final InkTool tool in InkTool.values)
            _ToolButton(
              tool: tool,
              selected: brush.tool == tool,
              onTap: () => controller.selectTool(tool),
            ),
          _Divider(color: scheme.outlineVariant),
          if (!brush.isEraser) ...<Widget>[
            for (int i = 0; i < InkPalette.countFor(brush.strokeStyle); i++)
              _ColorDot(
                color: previewColorOf(
                  style: brush.strokeStyle,
                  colorIndex: i,
                  darkPaper: darkPaper,
                ),
                size: 22,
                selected: brush.colorIndex == i,
                onTap: () => controller.selectColor(i),
              ),
            _Divider(color: scheme.outlineVariant),
            // 粗细/橡皮大小：一条紧凑滑条（多级可调），右边带当前值的参考圈。
            SizedBox(
              width: 168,
              child: _BrushWidthSlider(
                brush: brush,
                darkPaper: darkPaper,
                compact: true,
                onChanged: controller.selectWidth,
              ),
            ),
          ] else ...<Widget>[
            // 橡皮：同一位置改成"大小"滑条。
            SizedBox(
              width: 168,
              child: _BrushWidthSlider(
                brush: brush,
                darkPaper: darkPaper,
                compact: true,
                onChanged: controller.selectWidth,
              ),
            ),
          ],
          const Spacer(),
          // 反向切换：从顶栏变回右下角浮钮（同一个 provider，双向可达）。
          IconButton(
            tooltip: '改为浮窗',
            onPressed: () =>
                ref.read(inkToolbarPinnedProvider.notifier).set(false),
            icon: const Icon(Icons.picture_in_picture_alt_outlined, size: 20),
          ),
        ],
      ),
    );
  }
}

// ── 小组件 ───────────────────────────────────────────────────────────

/// 粗细 / 橡皮大小：一条 0..100 的滑条 + 右侧"实际大小"参考圈。
///
/// 为什么是连续滑条而不是三个点：用户 2026-10-23 明确要"多级可调"。
/// 参考圈直接画**真实尺寸**（钢笔按中性压力的线宽，橡皮按半径），
/// 这样在面板里就能看出"这一档写出来有多粗"，不用落笔试。
class _BrushWidthSlider extends StatelessWidget {
  const _BrushWidthSlider({
    required this.brush,
    required this.darkPaper,
    required this.onChanged,
    this.compact = false,
  });

  final InkBrush brush;
  final bool darkPaper;
  final ValueChanged<int> onChanged;
  final bool compact;

  /// 参考圈直径（dp）：按真实宽度换算，但压在 4..22dp 之间保证看得见。
  double get _dot {
    final double pt = brush.isEraser
        ? Eraser.radiusOfWidth(brush.brushWidth) * 2
        : InkWidth.baseOf(brush.strokeStyle, brush.brushWidth);
    // 1pt ≈ 1.9dp 的观感系数：面板很小，按物理尺寸画会细到看不见。
    return (pt * 1.9).clamp(4.0, compact ? 18.0 : 26.0);
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Color color = brush.isEraser
        ? scheme.onSurfaceVariant
        : previewColorOf(
            style: brush.strokeStyle,
            colorIndex: brush.colorIndex,
            darkPaper: darkPaper,
          );
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        SizedBox(
          width: compact ? 116 : 150,
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 3,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
            ),
            child: Slider(
              value: brush.brushWidth.toDouble(),
              min: 0,
              max: 100,
              onChanged: (double v) => onChanged(v.round()),
            ),
          ),
        ),
        const SizedBox(width: ShqSpace.xs),
        // 参考圈：真实大小的可视化
        SizedBox(
          width: (compact ? 18 : 26) + 4,
          height: (compact ? 18 : 26) + 4,
          child: Center(
            child: Container(
              width: _dot,
              height: _dot,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.22),
                shape: BoxShape.circle,
                border: Border.all(color: color, width: 1.4),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// 面板里的小动作按钮（"固定到顶栏"这类形态切换）。
class _ModeSwitchButton extends StatelessWidget {
  const _ModeSwitchButton({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(ShqRadius.pill),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(icon, size: 14, color: scheme.primary),
            const SizedBox(width: 4),
            Text(
              label,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: scheme.primary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Text(
      text,
      style: theme.textTheme.labelSmall?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
        letterSpacing: 0.4,
      ),
    );
  }
}

class _Divider extends StatelessWidget {
  const _Divider({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 1,
      height: 22,
      margin: const EdgeInsets.symmetric(horizontal: ShqSpace.sm),
      color: color,
    );
  }
}

/// 工具按钮：图标 + 中文短名。
class _ToolButton extends StatelessWidget {
  const _ToolButton({
    required this.tool,
    required this.selected,
    required this.onTap,
  });

  final InkTool tool;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    return Semantics(
      button: true,
      selected: selected,
      label: tool.label,
      child: InkWell(
        onTap: onTap,
        customBorder: const StadiumBorder(),
        child: AnimatedContainer(
          duration: ShqMotion.instant,
          curve: Curves.easeOutCubic,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          decoration: BoxDecoration(
            color: selected ? scheme.secondaryContainer : Colors.transparent,
            borderRadius: BorderRadius.circular(ShqRadius.pill),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(
                iconOfTool(tool),
                size: 18,
                color: selected
                    ? scheme.onSecondaryContainer
                    : scheme.onSurfaceVariant,
              ),
              const SizedBox(width: 4),
              Text(
                tool.label,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontSize: ShqType.caption,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                  color: selected
                      ? scheme.onSecondaryContainer
                      : scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 色块。选中时外面加一圈 primary 描边（色块上放勾会挡住颜色本身）。
class _ColorDot extends StatelessWidget {
  const _ColorDot({
    required this.color,
    required this.size,
    this.selected = false,
    this.onTap,
  });

  final Color color;
  final double size;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Widget dot = AnimatedContainer(
      duration: ShqMotion.instant,
      curve: Curves.easeOutCubic,
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: Border.all(
          color: selected ? scheme.primary : scheme.outlineVariant,
          width: selected ? 2.5 : 1,
        ),
      ),
    );
    if (onTap == null) {
      return dot;
    }
    return Semantics(
      button: true,
      selected: selected,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        // 触控目标补到 ~40dp：色块本身只有 22–26dp
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 6),
          child: dot,
        ),
      ),
    );
  }
}


/// 橡皮大小：三个"空心圆"表示擦除范围，选中那档填色。
///
/// 为什么不用大小实心点（像粗细那样）：橡皮是"范围"而不是"笔宽"，
