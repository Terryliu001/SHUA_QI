import 'package:flutter/material.dart';
import 'package:shuaqi/domain/reader/reader_prefs.dart';
import 'package:shuaqi/ui/theme/tokens.dart';
import 'package:shuaqi/ui/widgets/labeled_action.dart';

/// 阅读器顶栏的动作区（2026-10-24 抽出）。
///
/// ## 为什么抽出来
///
/// 顶栏动作**会互相抢空间**：`AppBar` 的 actions 是按整条栏的宽度排的，
/// 标题是唯一可压缩的那个。实测（360dp 手机竖屏）：
///
/// - 现状 6 个动作 + 缩放胶囊：刚好不溢出；
/// - 加第 7 个动作（保存）：**溢出 33px** —— 标题被挤到 0 宽还是溢出，
///   因为 actions 是先按自身宽度排的，标题压不下去。
///
/// 所以"加一个按钮"不是加一行代码，而是要连带决定**窄屏下谁让路**。
/// 这段逻辑必须能被单测锁住，所以抽成独立文件（而不是留在
/// `reader_page.dart` 里靠肉眼保证）。
///
/// ## 窄屏策略（2026-10-24 第二轮）
///
/// 用户要求「题目区域 / 缩略图 / 答题卡」都直接放在顶栏，不再藏进「更多」。
/// 平板宽度足够；窄屏（< [kReaderCompactWidth]）则：
/// - **保留**撤销/重做/保存、题目区域、缩略图、答题卡、更多；
/// - 手势模式、阅读形态、显示设置收进「更多」；
/// - 图标按钮用 40dp 紧凑宽度（仍是 Material 的最小可点尺寸附近）。
///
/// 这样窄屏不会溢出，同时用户明确要的三个入口永远一眼可达。
const double kReaderCompactWidth = 600;

/// 便捷入口：按给定状态生成顶栏动作列表。
///
/// `AppBar.actions` 要的是扁平 `List<Widget>`，所以这里返回列表而不是
/// 一个包装 widget（包一层 `Row` 会改变图标之间的间距）。
List<Widget> buildReaderTopActions({
  required double width,
  bool showLabels = false,
  required bool canUndo,
  required bool canRedo,
  required VoidCallback onUndo,
  required VoidCallback onRedo,
  required VoidCallback onSave,
  required bool handTool,
  required VoidCallback onToggleHandTool,
  required ViewMode mode,
  required VoidCallback onToggleMode,
  required double scrollZoom,
  required ValueChanged<double> onZoomSelected,
  required VoidCallback onOpenDisplay,
  required bool panelOpen,
  required VoidCallback onTogglePanel,
  required VoidCallback onOpenThumbnails,
  required bool hasThumbnails,
  required VoidCallback onOpenAnswerSheet,
}) {
  return ReaderTopActions(
    width: width,
    showLabels: showLabels,
    canUndo: canUndo,
    canRedo: canRedo,
    onUndo: onUndo,
    onRedo: onRedo,
    onSave: onSave,
    handTool: handTool,
    onToggleHandTool: onToggleHandTool,
    mode: mode,
    onToggleMode: onToggleMode,
    scrollZoom: scrollZoom,
    onZoomSelected: onZoomSelected,
    onOpenDisplay: onOpenDisplay,
    panelOpen: panelOpen,
    onTogglePanel: onTogglePanel,
    onOpenThumbnails: onOpenThumbnails,
    hasThumbnails: hasThumbnails,
    onOpenAnswerSheet: onOpenAnswerSheet,
  ).build();
}

/// 顶栏动作区所需的状态与回调。
class ReaderTopActions {
  const ReaderTopActions({
    required this.width,
    required this.showLabels,
    required this.canUndo,
    required this.canRedo,
    required this.onUndo,
    required this.onRedo,
    required this.onSave,
    required this.handTool,
    required this.onToggleHandTool,
    required this.mode,
    required this.onToggleMode,
    required this.scrollZoom,
    required this.onZoomSelected,
    required this.onOpenDisplay,
    required this.panelOpen,
    required this.onTogglePanel,
    required this.onOpenThumbnails,
    required this.hasThumbnails,
    required this.onOpenAnswerSheet,
  });

  /// 可用宽度（逻辑像素）。用来决定窄屏下要不要收动作。
  final double width;

  /// **文字模式**：动作图标旁显示功能文字（2026-10-26 用户第 15 条）。
  ///
  /// 放不下时调用方不要传 true——顶栏的 actions 压不动标题，
  /// 溢出只会出黄黑条。这里只负责"给不给文字"，放不放得下由 [labelsFitWidth] 决定。
  final bool showLabels;

  final bool canUndo;
  final bool canRedo;
  final VoidCallback onUndo;
  final VoidCallback onRedo;

  /// 「保存」= 把当前答题情况（笔迹 + 进度 + 切题改动）立刻落盘。
  final VoidCallback onSave;

  /// 手势模式是否开着（开 = 手指只平移缩放，笔仍然书写）。
  final bool handTool;
  final VoidCallback onToggleHandTool;

  final ViewMode mode;
  final VoidCallback onToggleMode;

  /// 连续滚动模式的当前倍率（只在该模式下显示）。
  final double scrollZoom;
  final ValueChanged<double> onZoomSelected;

  final VoidCallback onOpenDisplay;

  final bool panelOpen;
  final VoidCallback onTogglePanel;

  final VoidCallback onOpenThumbnails;
  final bool hasThumbnails;

  /// 「答题卡」：先确认切题，再逐题作答。
  final VoidCallback onOpenAnswerSheet;

  /// 窄屏：低频繁动作收进「更多」，给三个常驻入口腾位置。
  bool get compact => width < kReaderCompactWidth;

  /// 顶栏动作（顺序 = 用户看到的顺序）。
  List<Widget> build() {
    return <Widget>[
      // 撤销/重做放在顶栏：高频动作，必须一次点击可达，不藏进工具面板。
      _TopBarIcon(
        compact: compact,
        label: '撤销',
        showLabel: showLabels,
        tooltip: '撤销',
        onPressed: canUndo ? onUndo : null,
        icon: Icons.undo,
      ),
      _TopBarIcon(
        compact: compact,
        label: '重做',
        showLabel: showLabels,
        tooltip: '重做',
        onPressed: canRedo ? onRedo : null,
        icon: Icons.redo,
      ),
      // 「保存」与撤销/重做同属"对当前这份卷的改动"，所以放在这一组里。
      // 用户 2026-10-24 明确要求它在顶栏（= 保存现在的答题情况，即笔迹）。
      _TopBarIcon(
        compact: compact,
        label: '保存',
        showLabel: showLabels,
        tooltip: '保存答题情况',
        onPressed: onSave,
        icon: Icons.save_outlined,
      ),
      const ReaderActionDivider(),
      // 宽屏保留手势/形态/显示；窄屏收进「更多」，见文件头说明。
      if (!compact)
        _TopBarIcon(
          compact: false,
          label: '手势',
          showLabel: showLabels,
          tooltip: handTool
              ? '手势模式：手指平移缩放，笔书写'
              : '书写模式：手指和笔都能写',
          isSelected: handTool,
          selectedIcon: Icons.pan_tool_alt,
          icon: Icons.pan_tool_alt_outlined,
          onPressed: onToggleHandTool,
        ),
      if (!compact && mode == ViewMode.scroll)
        ReaderZoomPill(value: scrollZoom, onSelected: onZoomSelected),
      if (!compact)
        _TopBarIcon(
          compact: false,
          label: '形态',
          showLabel: showLabels,
          tooltip: mode == ViewMode.paged ? '切换到连续滚动' : '切换到分页',
          onPressed: onToggleMode,
          icon: mode == ViewMode.paged
              ? Icons.auto_stories_outlined
              : Icons.view_day_outlined,
        ),
      // 用户 2026-10-24 第二轮：题目区域 / 缩略图 / 答题卡常驻顶栏。
      _TopBarIcon(
        compact: compact,
        label: '题目',
        showLabel: showLabels,
        tooltip: panelOpen ? '收起题目区域' : '题目区域',
        isSelected: panelOpen,
        selectedIcon: Icons.crop_free,
        icon: Icons.crop_free,
        onPressed: onTogglePanel,
      ),
      _TopBarIcon(
        compact: compact,
        label: '缩略',
        showLabel: showLabels,
        tooltip: '缩略图',
        onPressed: hasThumbnails ? onOpenThumbnails : null,
        icon: Icons.grid_view_outlined,
      ),
      _TopBarIcon(
        compact: compact,
        label: '答题卡',
        showLabel: showLabels,
        tooltip: '答题卡',
        onPressed: onOpenAnswerSheet,
        icon: Icons.assignment_outlined,
      ),
      if (!compact)
        _TopBarIcon(
          compact: false,
          label: '显示',
          showLabel: showLabels,
          tooltip: '显示设置',
          onPressed: onOpenDisplay,
          icon: Icons.palette_outlined,
        ),
      if (compact)
        PopupMenuButton<String>(
          tooltip: '更多',
          icon: const Icon(Icons.more_horiz),
          onSelected: _onMenuSelected,
          itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
            PopupMenuItem<String>(
              value: 'hand',
              child: ReaderMenuItem(
                icon: Icons.pan_tool_alt_outlined,
                label: handTool ? '切换到书写模式' : '切换到手势模式',
              ),
            ),
            PopupMenuItem<String>(
              value: 'mode',
              child: ReaderMenuItem(
                icon: mode == ViewMode.paged
                    ? Icons.view_day_outlined
                    : Icons.auto_stories_outlined,
                label: mode == ViewMode.paged ? '切换到连续滚动' : '切换到分页',
              ),
            ),
            const PopupMenuItem<String>(
              value: 'display',
              child: ReaderMenuItem(
                icon: Icons.palette_outlined,
                label: '显示设置',
              ),
            ),
          ],
        ),
    ];
  }

  void _onMenuSelected(String value) {
    switch (value) {
      case 'hand':
        onToggleHandTool();
      case 'mode':
        onToggleMode();
      case 'display':
        onOpenDisplay();
    }
  }
}

/// 顶栏动作按钮。窄屏用 40dp 紧凑宽度；其余交给 IconButton 的默认触控尺寸。
///
/// 40 而不是更小：Material 推荐 48dp，但手机横屏/竖屏的顶栏要同时放 7 个入口，
/// 40 是"仍能稳定点中"和"不把标题挤没"之间最稳的折中；平板仍是 48。
class _TopBarIcon extends StatelessWidget {
  const _TopBarIcon({
    required this.compact,
    required this.label,
    required this.tooltip,
    required this.onPressed,
    required this.icon,
    this.showLabel = false,
    this.selectedIcon,
    this.isSelected = false,
  });

  final bool compact;

  /// 功能文字（文字模式时显示在图标旁）。
  final String label;

  final String tooltip;
  final VoidCallback? onPressed;
  final IconData icon;
  final bool showLabel;
  final IconData? selectedIcon;
  final bool isSelected;

  @override
  Widget build(BuildContext context) {
    return LabeledAction(
      icon: icon,
      label: label,
      tooltip: tooltip,
      onPressed: onPressed,
      selected: isSelected,
      selectedIcon: selectedIcon,
      showLabel: showLabel,
      compact: compact,
    );
  }
}

/// 顶栏里的分组细线：把"文档动作（撤销/重做/保存）"与"视图动作"分开。
class ReaderActionDivider extends StatelessWidget {
  const ReaderActionDivider({super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: ShqSpace.xs),
      child: Center(
        child: Container(
          width: 1,
          height: 22,
          color: Theme.of(context).colorScheme.outlineVariant,
        ),
      ),
    );
  }
}

/// 连续滚动模式的缩放胶囊：**当前倍率本身就是按钮**。
///
/// 之前是"图标 + 文字"直接塞在 actions 里，宽度大、和图标不成一组。
/// 现在做成一颗有底色的胶囊，倍率一眼可见，点开是档位菜单。
class ReaderZoomPill extends StatelessWidget {
  const ReaderZoomPill({
    super.key,
    required this.value,
    required this.onSelected,
  });

  final double value;
  final ValueChanged<double> onSelected;

  static const List<double> _steps = <double>[0.6, 0.86, 1, 1.5, 2, 3];

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    // 窄屏（手机竖屏）只露图标：4 个顶栏动作 + 百分比会把标题挤没。
    final bool compact = MediaQuery.sizeOf(context).width < kReaderCompactWidth;
    return PopupMenuButton<double>(
      tooltip: '缩放 ${(value * 100).round()}%',
      initialValue: value,
      onSelected: onSelected,
      itemBuilder: (BuildContext context) => <PopupMenuEntry<double>>[
        for (final double zoom in _steps)
          PopupMenuItem<double>(
            value: zoom,
            child: Row(
              children: <Widget>[
                SizedBox(
                  width: 22,
                  child: (zoom - value).abs() < 0.01
                      ? Icon(Icons.check, size: 16, color: scheme.primary)
                      : null,
                ),
                Text('${(zoom * 100).round()}%'),
              ],
            ),
          ),
      ],
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: ShqSpace.xxs),
        padding: const EdgeInsets.symmetric(
          horizontal: ShqSpace.sm,
          vertical: 5,
        ),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(ShqRadius.pill),
          border: Border.all(color: scheme.outlineVariant),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.zoom_in, size: 15, color: scheme.onSurfaceVariant),
            if (!compact) ...<Widget>[
              const SizedBox(width: 4),
              Text(
                '${(value * 100).round()}%',
                style: theme.textTheme.labelMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 更多菜单里的一行（图标 + 文字）。
class ReaderMenuItem extends StatelessWidget {
  const ReaderMenuItem({super.key, required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Row(
      children: <Widget>[
        Icon(icon, size: 19, color: scheme.onSurfaceVariant),
        const SizedBox(width: ShqSpace.md),
        Text(label),
      ],
    );
  }
}
