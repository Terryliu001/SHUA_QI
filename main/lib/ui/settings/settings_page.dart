import 'dart:async';

import 'package:flutter/foundation.dart' show kReleaseMode;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shuaqi/app/app_info.dart';
import 'package:shuaqi/domain/reader/paper_tint.dart';
import 'package:shuaqi/domain/reader/reader_prefs.dart';
import 'package:shuaqi/state/ink_tool_provider.dart';
import 'package:shuaqi/state/reader_prefs_providers.dart';
import 'package:shuaqi/state/theme_mode_provider.dart';
import 'package:shuaqi/ui/reader/debug_hud.dart';
import 'package:shuaqi/ui/theme/tokens.dart';
import 'package:shuaqi/ui/widgets/pressable.dart';
import 'package:shuaqi/ui/widgets/soft_icon.dart';

/// 设置页（T6.1 的先行子集：外观 + 阅读默认先做真功能，AI/存储留置灰说明）。
///
/// 设计纪律（项目一贯原则）：**能点但没反应是假功能**。所以这一页只有两种块：
/// 1. 真实生效的（主题模式、阅读默认）——写了立刻落 `setting` 表；
/// 2. 明确置灰 + 一句话说明的（AI 配置、存储统计）——告诉用户它在路线图的哪儿。
///
/// ## 2026-10-23 设计收尾（v3）
/// - **每行有图标 + 说明**：设置不是一串开关，而是一份"这个应用怎么工作"的清单；
/// - 分组标题与卡片同一条竖线（16dp），标题降为 onSurfaceVariant；
/// - 行与行之间用**发丝线**分隔（缩进 64dp 对齐文字），不再靠间距硬撑；
/// - 主题 / 默认模式改成**整宽分段选择器**（图标 + 文字），比 Material 默认的
///   紧凑 segmented button 更适合平板；
/// - 纸感增加**真实预览块**：选什么纸、什么强度，直接看到"一页纸"。
class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key});

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  /// 用户在本页改过的阅读默认。null = 还没改过，用库里加载的值。
  /// 不自动同步回库——写由交互触发，见 [_writeDefaults]。
  ReaderPrefs? _draft;

  Future<void> _writeDefaults(ReaderPrefs next) async {
    setState(() => _draft = next);
    await ref.read(readerPrefsStoreProvider).saveDefaults(next);
    ref.invalidate(readerDefaultsProvider);
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ThemeMode themeMode = ref.watch(themeModeProvider);
    final ReaderPrefs defaults =
        _draft ??
        ref
            .watch(readerDefaultsProvider)
            .maybeWhen<ReaderPrefs?>(
              data: (ReaderPrefs value) => value,
              orElse: () => null,
            ) ??
        ReaderPrefs.defaults;

    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: ShqLayout.maxFormWidth),
          child: ListView(
            padding: const EdgeInsets.only(bottom: ShqSpace.xxl),
            children: <Widget>[
              _Section(
                title: '外观',
                children: <Widget>[
                  _Block(
                    icon: Icons.brightness_6_outlined,
                    title: '主题',
                    subtitle: '深色只影响界面骨架，不影响卷面配色',
                    child: _ChoiceGroup<ThemeMode>(
                      options: const <_Choice<ThemeMode>>[
                        _Choice<ThemeMode>(
                          value: ThemeMode.system,
                          label: '跟随系统',
                          icon: Icons.brightness_auto_outlined,
                        ),
                        _Choice<ThemeMode>(
                          value: ThemeMode.light,
                          label: '浅色',
                          icon: Icons.light_mode_outlined,
                        ),
                        _Choice<ThemeMode>(
                          value: ThemeMode.dark,
                          label: '深色',
                          icon: Icons.dark_mode_outlined,
                        ),
                      ],
                      selected: themeMode,
                      onSelected: (ThemeMode mode) => unawaited(
                        ref.read(themeModeProvider.notifier).set(mode),
                      ),
                    ),
                  ),
                  const _Hairline(),
                  const _Note(
                    '卷面配色在「阅读默认」里单独选：原图 = 白底黑字，夜读 = 黑底白字。'
                    '两者互不影响，深色界面下也能看白底黑字的卷子。',
                  ),
                ],
              ),
              _Section(
                title: '阅读默认',
                children: <Widget>[
                  _Block(
                    icon: Icons.menu_book_outlined,
                    title: '默认模式',
                    subtitle: '新打开的卷子用哪种翻页方式',
                    child: _ChoiceGroup<ViewMode>(
                      options: const <_Choice<ViewMode>>[
                        _Choice<ViewMode>(
                          value: ViewMode.paged,
                          label: '分页',
                          icon: Icons.auto_stories_outlined,
                        ),
                        _Choice<ViewMode>(
                          value: ViewMode.scroll,
                          label: '连续滚动',
                          icon: Icons.view_day_outlined,
                        ),
                      ],
                      selected: defaults.mode,
                      onSelected: (ViewMode mode) =>
                          _writeDefaults(defaults.copyWith(mode: mode)),
                    ),
                  ),
                  const _Hairline(),
                  _Block(
                    icon: Icons.palette_outlined,
                    title: '默认纸感',
                    subtitle: '纸色、夜读与强度只作用在卷面背景',
                    child: _PaperPicker(
                      style: defaults.style,
                      intensity: defaults.intensity,
                      onStyle: (PaperStyle style) =>
                          _writeDefaults(defaults.copyWith(style: style)),
                    ),
                  ),
                  const _Hairline(),
                  _Block(
                    icon: Icons.tonality_outlined,
                    title: '默认强度',
                    subtitle: '数值越高纸色越浓；原图与夜读不参与',
                    child: _IntensitySlider(
                      style: defaults.style,
                      value: defaults.intensity,
                      onChanged: (int intensity) => _writeDefaults(
                        defaults.copyWith(intensity: intensity),
                      ),
                    ),
                  ),
                  const _Note('只影响之后新打开的卷；正在读的卷以阅读器内「显示」浮层为准。'),
                ],
              ),
              _Section(
                title: '书写',
                children: <Widget>[
                  _SettingsRow(
                    icon: Icons.draw_outlined,
                    title: '工具条固定在顶栏',
                    subtitle: '关闭 = 右下角圆形浮钮（点开才是面板，阅读区最干净）',
                    trailing: Switch(
                      value: ref.watch(inkToolbarPinnedProvider),
                      onChanged: (bool pinned) => unawaited(
                        ref.read(inkToolbarPinnedProvider.notifier).set(pinned),
                      ),
                    ),
                  ),
                  const _Hairline(),
                  const _Note('笔的颜色与粗细在阅读器里的工具面板中选；每支笔分别记住。'),
                ],
              ),
              const _Section(
                title: 'AI 分析',
                children: <Widget>[
                  _SettingsRow(
                    icon: Icons.key_outlined,
                    title: 'BYOK 配置',
                    subtitle: '接入任意 OpenAI 兼容端点，密钥只存在本机',
                    locked: true,
                    trailingLabel: 'T6.1',
                  ),
                ],
              ),
              const _Section(
                title: '存储与备份',
                children: <Widget>[
                  _SettingsRow(
                    icon: Icons.storage_outlined,
                    title: '空间统计与归档',
                    subtitle: '分类占用 + 归档清理 + zip 备份',
                    locked: true,
                    trailingLabel: 'T7.5',
                  ),
                ],
              ),
              // 只有 debug / profile 构建才会出现（release 里连入口都没有）。
              if (!kReleaseMode)
                _Section(
                  title: '开发',
                  children: <Widget>[
                    _SettingsRow(
                      icon: Icons.speed_outlined,
                      title: '性能 HUD',
                      subtitle: '阅读器左上角显示帧耗时 / 笔画数 / 位图占用',
                      trailing: Switch(
                        value: ref.watch(debugHudProvider),
                        onChanged: (bool _) =>
                            ref.read(debugHudProvider.notifier).toggle(),
                      ),
                    ),
                  ],
                ),
              const _Section(title: '关于', children: <Widget>[_AboutCard()]),
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  ShqLayout.gutter,
                  ShqSpace.lg,
                  ShqLayout.gutter,
                  0,
                ),
                child: Text(
                  '刷起 SHUAQI · 以笔为核的刷题工作台\n'
                  '卷子是你的，笔迹是你的，数据只留在本机。',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.outline,
                    height: 1.6,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── 分组与行 ─────────────────────────────────────────────────────────

/// 设置分组：标题 + 一张圆角卡片。分隔靠卡片内发丝线，不靠阴影。
class _Section extends StatelessWidget {
  const _Section({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(
            ShqLayout.gutter,
            ShqSpace.xl,
            ShqLayout.gutter,
            ShqSpace.sm,
          ),
          child: Text(
            title,
            style: theme.textTheme.labelMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.8,
            ),
          ),
        ),
        Card(
          margin: const EdgeInsets.symmetric(horizontal: ShqLayout.gutter),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: children,
          ),
        ),
      ],
    );
  }
}

/// 行间发丝线：缩进 64dp，正好从文字左边缘开始（图标 36 + 间距 12 + 边距 16）。
class _Hairline extends StatelessWidget {
  const _Hairline();

  @override
  Widget build(BuildContext context) {
    return Divider(
      height: 1,
      thickness: 1,
      indent: 64,
      endIndent: ShqLayout.gutter,
      color: Theme.of(context).colorScheme.outlineVariant,
    );
  }
}

/// 带图标的一行设置（开关 / 置灰入口 / 可点动作）。
class _SettingsRow extends StatelessWidget {
  const _SettingsRow({
    required this.icon,
    required this.title,
    this.subtitle,
    this.trailing,
    this.locked = false,
    this.trailingLabel,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget? trailing;

  /// 置灰 + 锁形角标：功能还没做，别给假入口。
  final bool locked;
  final String? trailingLabel;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final Color titleColor = locked ? scheme.outline : scheme.onSurface;
    final Color iconColor = locked
        ? scheme.outlineVariant
        : scheme.onSurfaceVariant;

    final Widget row = Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: ShqLayout.gutter,
        vertical: ShqSpace.md,
      ),
      child: Row(
        children: <Widget>[
          SoftIcon(icon: icon, size: 36, iconSize: 18, color: iconColor),
          const SizedBox(width: ShqSpace.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  title,
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: titleColor,
                  ),
                ),
                if (subtitle != null) ...<Widget>[
                  const SizedBox(height: 2),
                  Text(
                    subtitle!,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (trailing != null) ...<Widget>[
            const SizedBox(width: ShqSpace.sm),
            trailing!,
          ],
          if (locked) ...<Widget>[
            const SizedBox(width: ShqSpace.sm),
            _Tag(text: trailingLabel ?? '未开放'),
            const SizedBox(width: ShqSpace.xs),
            Icon(Icons.lock_outline, size: 16, color: scheme.outlineVariant),
          ],
        ],
      ),
    );

    return row;
  }
}

/// 带图标与说明的**整块**设置（下面是控件，不是开关）。
class _Block extends StatelessWidget {
  const _Block({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.child,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        ShqLayout.gutter,
        ShqSpace.md,
        ShqLayout.gutter,
        ShqSpace.lg,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              SoftIcon(icon: icon, size: 36, iconSize: 18),
              const SizedBox(width: ShqSpace.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(title, style: theme.textTheme.titleSmall),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: ShqSpace.md),
          child,
        ],
      ),
    );
  }
}

/// 分组内的一行说明文字。
class _Note extends StatelessWidget {
  const _Note(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        ShqLayout.gutter,
        ShqSpace.sm,
        ShqLayout.gutter,
        ShqSpace.md,
      ),
      child: Text(
        text,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
          height: 1.55,
        ),
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  const _Tag({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(ShqRadius.pill),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Text(
        text,
        style: Theme.of(context).textTheme.labelSmall
            ?.copyWith(color: scheme.onSurfaceVariant, letterSpacing: 0.2),
      ),
    );
  }
}

// ── 选择器 ───────────────────────────────────────────────────────────

class _Choice<T> {
  const _Choice({required this.value, required this.label, required this.icon});

  final T value;
  final String label;
  final IconData icon;
}

/// 整宽分段选择器（2–3 项）。比 Material 默认的紧凑分段按钮更适合触屏。
class _ChoiceGroup<T> extends StatelessWidget {
  const _ChoiceGroup({
    required this.options,
    required this.selected,
    required this.onSelected,
  });

  final List<_Choice<T>> options;
  final T selected;
  final ValueChanged<T> onSelected;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final ThemeData theme = Theme.of(context);
    return Row(
      children: <Widget>[
        for (int i = 0; i < options.length; i++) ...<Widget>[
          if (i > 0) const SizedBox(width: ShqSpace.sm),
          Expanded(
            child: Pressable(
              onTap: () => onSelected(options[i].value),
              scale: 0.96,
              haptic: true,
              child: AnimatedContainer(
                duration: ShqMotion.fast,
                curve: ShqMotion.curveStandard,
                padding: const EdgeInsets.symmetric(vertical: ShqSpace.md),
                decoration: BoxDecoration(
                  color: options[i].value == selected
                      ? scheme.secondaryContainer
                      : scheme.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(ShqRadius.md),
                  border: Border.all(
                    color: options[i].value == selected
                        ? scheme.primary.withValues(alpha: 0.35)
                        : scheme.outlineVariant,
                  ),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Icon(
                      options[i].icon,
                      size: 20,
                      color: options[i].value == selected
                          ? scheme.onSecondaryContainer
                          : scheme.onSurfaceVariant,
                    ),
                    const SizedBox(height: ShqSpace.xs),
                    Text(
                      options[i].label,
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: options[i].value == selected
                            ? scheme.onSecondaryContainer
                            : scheme.onSurfaceVariant,
                        fontWeight: options[i].value == selected
                            ? FontWeight.w600
                            : FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

// ── 纸感预览 ─────────────────────────────────────────────────────────

/// 纸感选择：**真实预览块** + 六个色块。
class _PaperPicker extends StatelessWidget {
  const _PaperPicker({
    required this.style,
    required this.intensity,
    required this.onStyle,
  });

  final PaperStyle style;
  final int intensity;
  final ValueChanged<PaperStyle> onStyle;

  static const List<(PaperStyle, String)> _items = <(PaperStyle, String)>[
    (PaperStyle.original, '原图'),
    (PaperStyle.warm, '暖白'),
    (PaperStyle.ivory, '象牙'),
    (PaperStyle.gray, '浅灰'),
    (PaperStyle.green, '护眼'),
    (PaperStyle.night, '夜读'),
  ];

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    return Column(
      children: <Widget>[
        _PaperPreview(style: style, intensity: intensity),
        const SizedBox(height: ShqSpace.md),
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          spacing: ShqSpace.sm,
          runSpacing: ShqSpace.sm,
          children: <Widget>[
            for (final (PaperStyle item, String label) in _items)
              SizedBox(
                width: 44,
                child: _PaperSwatch(
                  style: item,
                  label: label,
                  intensity: intensity,
                  selected: style == item,
                  onTap: () => onStyle(item),
                ),
              ),
          ],
        ),
        const SizedBox(height: ShqSpace.xs),
        Align(
          alignment: Alignment.centerLeft,
          child: Text(
            '当前：${_labelOf(style)}',
            style: theme.textTheme.labelSmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }

  static String _labelOf(PaperStyle style) {
    for (final (PaperStyle item, String label) in _items) {
      if (item == style) {
        return label;
      }
    }
    return '';
  }
}

/// 一页"样子"的预览：纸色 + 一行标题 + 两行正文 + 一个 Aa。
///
/// 它不是装饰：用户在这里看到的纸色与阅读器里的乘法染纸同口径
/// （强度 100 = 白纸完全变成纸色，夜间是两端色映射）。
class _PaperPreview extends StatelessWidget {
  const _PaperPreview({required this.style, required this.intensity});

  final PaperStyle style;
  final int intensity;

  Color get _fill {
    if (style.isDarkPaper) {
      return ShqNight.paper;
    }
    final int? rgb = PaperRgb.of(style);
    if (rgb == null) {
      return ShqPaper.base;
    }
    return Color.lerp(ShqPaper.base, Color(rgb), intensity / 100)!;
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Color ink = style.isDarkPaper ? ShqNight.ink : ShqPalette.ink;
    return Container(
      height: 104,
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(
        ShqSpace.lg,
        ShqSpace.md,
        ShqSpace.lg,
        ShqSpace.md,
      ),
      decoration: BoxDecoration(
        color: _fill,
        borderRadius: BorderRadius.circular(ShqRadius.md),
        border: Border.all(
          color: style.isDarkPaper ? ShqNight.pageEdge : scheme.outlineVariant,
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                Text(
                  '数学期中卷 · 第 1 页',
                  style: const TextStyle(
                    fontSize: ShqType.caption,
                    fontWeight: FontWeight.w600,
                    color: ShqPalette.ink,
                    height: 1.3,
                  ).copyWith(color: ink.withValues(alpha: 0.85)),
                ),
                const SizedBox(height: 5),
                Text(
                  '1. 已知函数 f(x) = x² − 2x + 3，求它在区间 [0, 3] 上的最值。',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    height: 1.5,
                    color: ink.withValues(alpha: 0.72),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: ShqSpace.lg),
          Text(
            'Aa',
            style: TextStyle(
              fontSize: 26,
              fontWeight: FontWeight.w600,
              color: ink.withValues(alpha: 0.5),
              height: 1,
            ),
          ),
        ],
      ),
    );
  }
}

class _PaperSwatch extends StatelessWidget {
  const _PaperSwatch({
    required this.style,
    required this.label,
    required this.intensity,
    required this.selected,
    required this.onTap,
  });

  final PaperStyle style;
  final String label;
  final int intensity;
  final bool selected;
  final VoidCallback onTap;

  Color get _fill {
    if (style.isDarkPaper) {
      return ShqNight.paper;
    }
    final int? rgb = PaperRgb.of(style);
    if (rgb == null) {
      return ShqPaper.base;
    }
    return Color.lerp(ShqPaper.base, Color(rgb), intensity / 100)!;
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Pressable(
      onTap: onTap,
      scale: 0.9,
      haptic: true,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          AnimatedContainer(
            duration: ShqMotion.fast,
            curve: ShqMotion.curveStandard,
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: _fill,
              shape: BoxShape.circle,
              border: Border.all(
                color: selected ? scheme.primary : scheme.outlineVariant,
                width: selected ? 2 : 1,
              ),
            ),
            child: selected
                ? Icon(
                    Icons.check,
                    size: 17,
                    color: style.isDarkPaper ? ShqNight.ink : scheme.primary,
                  )
                : null,
          ),
          const SizedBox(height: ShqSpace.xs),
          Text(
            label,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: selected ? scheme.primary : scheme.onSurfaceVariant,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
            ),
          ),
        ],
      ),
    );
  }
}

/// 默认强度。原图时置灰——没有纸色可染，滑它没有意义（真交互原则）。
class _IntensitySlider extends StatelessWidget {
  const _IntensitySlider({
    required this.style,
    required this.value,
    required this.onChanged,
  });

  final PaperStyle style;
  final int value;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    // 原图没有纸色可染；夜读是两端色映射（暗纸端 + 亮墨端），强度不参与。
    final bool enabled = style != PaperStyle.original && !style.isDarkPaper;
    return Row(
      children: <Widget>[
        Icon(
          Icons.wb_sunny_outlined,
          size: 18,
          color: enabled ? scheme.onSurfaceVariant : scheme.outlineVariant,
        ),
        Expanded(
          child: Slider(
            value: value.toDouble(),
            max: 100,
            divisions: 20,
            label: '$value%',
            onChanged: enabled ? (double v) => onChanged(v.round()) : null,
          ),
        ),
        Container(
          width: 48,
          padding: const EdgeInsets.symmetric(vertical: 4),
          decoration: BoxDecoration(
            color: enabled ? scheme.surfaceContainerHigh : Colors.transparent,
            borderRadius: BorderRadius.circular(ShqRadius.pill),
            border: Border.all(
              color: enabled ? scheme.outlineVariant : Colors.transparent,
            ),
          ),
          child: Text(
            '$value%',
            textAlign: TextAlign.center,
            style: theme.textTheme.labelMedium?.copyWith(
              color: enabled ? scheme.onSurface : scheme.outline,
            ),
          ),
        ),
      ],
    );
  }
}

// ── 关于 ─────────────────────────────────────────────────────────────

class _AboutCard extends StatelessWidget {
  const _AboutCard();

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.all(ShqLayout.gutter),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Container(
            width: 52,
            height: 52,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: scheme.primaryContainer,
              borderRadius: BorderRadius.circular(ShqRadius.md),
            ),
            child: Text(
              '刷',
              style: theme.textTheme.titleLarge?.copyWith(
                color: scheme.onPrimaryContainer,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(width: ShqSpace.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(AppInfo.name, style: theme.textTheme.titleMedium),
                const SizedBox(height: 2),
                Text(
                  AppInfo.tagline,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: ShqSpace.xs),
                const _Tag(text: '版本 ${AppInfo.version} · 开发中'),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
