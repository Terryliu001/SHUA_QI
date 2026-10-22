import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shuaqi/app/app_info.dart';
import 'package:shuaqi/domain/reader/paper_tint.dart';
import 'package:shuaqi/domain/reader/reader_prefs.dart';
import 'package:shuaqi/state/reader_prefs_providers.dart';
import 'package:shuaqi/state/theme_mode_provider.dart';
import 'package:shuaqi/ui/theme/tokens.dart';

/// 设置页（T6.1 的先行子集：外观 + 阅读默认先做真功能，AI/存储留置灰说明）。
///
/// 设计纪律（项目一贯原则）：**能点但没反应是假功能**。所以这一页只有两种块：
/// 1. 真实生效的（主题模式、阅读默认）——写了立刻落 `setting` 表；
/// 2. 明确置灰 + 一句话说明的（AI 配置、存储统计）——告诉用户它在路线图的哪儿。
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
      body: ListView(
        padding: const EdgeInsets.only(bottom: ShqSpace.xl),
        children: <Widget>[
          _Section(
            title: '外观',
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  ShqSpace.lg,
                  ShqSpace.sm,
                  ShqSpace.lg,
                  ShqSpace.xs,
                ),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text('主题', style: theme.textTheme.labelLarge),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: ShqSpace.lg,
                  vertical: ShqSpace.sm,
                ),
                child: SegmentedButton<ThemeMode>(
                  segments: const <ButtonSegment<ThemeMode>>[
                    ButtonSegment<ThemeMode>(
                      value: ThemeMode.system,
                      label: Text('跟随系统'),
                    ),
                    ButtonSegment<ThemeMode>(
                      value: ThemeMode.light,
                      label: Text('浅色'),
                    ),
                    ButtonSegment<ThemeMode>(
                      value: ThemeMode.dark,
                      label: Text('深色'),
                    ),
                  ],
                  selected: <ThemeMode>{themeMode},
                  onSelectionChanged: (Set<ThemeMode> selection) {
                    unawaited(
                      ref
                          .read(themeModeProvider.notifier)
                          .set(selection.first),
                    );
                  },
                ),
              ),
              const _Note('深色只影响界面骨架（书架 / 顶栏 / 浮层）。卷面配色在「阅读默认」里单独选：'
                  '原图 = 白底黑字，夜读 = 黑底白字'),
            ],
          ),
          _Section(
            title: '阅读默认',
            children: <Widget>[
              _ModeRow(
                value: defaults.mode,
                onChanged: (ViewMode mode) =>
                    _writeDefaults(defaults.copyWith(mode: mode)),
              ),
              _StyleRow(
                value: defaults.style,
                intensity: defaults.intensity,
                onChanged: (PaperStyle style) =>
                    _writeDefaults(defaults.copyWith(style: style)),
              ),
              _IntensityRow(
                style: defaults.style,
                value: defaults.intensity,
                onChanged: (int intensity) =>
                    _writeDefaults(defaults.copyWith(intensity: intensity)),
              ),
              const _Note('只影响之后新打开的卷；正在读的卷以阅读器内「显示」浮层为准'),
            ],
          ),
          const _Section(
            title: 'AI 分析',
            children: <Widget>[
              _DisabledTile(
                icon: Icons.key_outlined,
                title: 'BYOK 配置',
                subtitle: '接入任意 OpenAI 兼容端点 · 规划在 T6.1',
              ),
            ],
          ),
          const _Section(
            title: '存储与备份',
            children: <Widget>[
              _DisabledTile(
                icon: Icons.storage_outlined,
                title: '空间统计与归档',
                subtitle: '分类占用 + 归档清理 · 规划在 T7.5',
              ),
            ],
          ),
          const _Section(
            title: '关于',
            children: <Widget>[
              ListTile(
                leading: Icon(Icons.auto_stories_outlined),
                title: Text(AppInfo.name),
                subtitle: Text('${AppInfo.tagline}\n版本 ${AppInfo.version}（开发中）'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

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
            ShqSpace.xl,
            ShqSpace.lg,
            ShqSpace.xl,
            ShqSpace.sm,
          ),
          child: Text(
            title,
            style: theme.textTheme.labelLarge?.copyWith(
              color: theme.colorScheme.primary,
            ),
          ),
        ),
        Card(
          margin: const EdgeInsets.symmetric(horizontal: ShqSpace.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: children,
          ),
        ),
      ],
    );
  }
}

/// 分组内的一行说明文字（发丝线之上的灰色小字）。
class _Note extends StatelessWidget {
  const _Note(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        ShqSpace.lg,
        ShqSpace.xs,
        ShqSpace.lg,
        ShqSpace.md,
      ),
      child: Text(
        text,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// 默认阅读模式：分页 / 连续滚动。
class _ModeRow extends StatelessWidget {
  const _ModeRow({required this.value, required this.onChanged});

  final ViewMode value;
  final ValueChanged<ViewMode> onChanged;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        ShqSpace.lg,
        ShqSpace.md,
        ShqSpace.lg,
        ShqSpace.sm,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text('默认模式', style: theme.textTheme.labelLarge),
          const SizedBox(height: ShqSpace.sm),
          SegmentedButton<ViewMode>(
            segments: const <ButtonSegment<ViewMode>>[
              ButtonSegment<ViewMode>(
                value: ViewMode.paged,
                label: Text('分页'),
              ),
              ButtonSegment<ViewMode>(
                value: ViewMode.scroll,
                label: Text('连续滚动'),
              ),
            ],
            selected: <ViewMode>{value},
            onSelectionChanged: (Set<ViewMode> selection) =>
                onChanged(selection.first),
          ),
        ],
      ),
    );
  }
}

/// 默认纸感：六个色块 + 选中勾。色块填充按当前强度混合
/// （白 → 纸色），拖动下面的滑条时这里能直接看到结果。
class _StyleRow extends StatelessWidget {
  const _StyleRow({
    required this.value,
    required this.intensity,
    required this.onChanged,
  });

  final PaperStyle value;
  final int intensity;
  final ValueChanged<PaperStyle> onChanged;

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
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        ShqSpace.lg,
        ShqSpace.md,
        ShqSpace.lg,
        ShqSpace.sm,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text('默认纸感', style: theme.textTheme.labelLarge),
          const SizedBox(height: ShqSpace.sm),
          // Wrap 而不是 Row：窄屏（手机竖屏）六个色块一行放不下，要能折行。
          Wrap(
            spacing: ShqSpace.lg,
            runSpacing: ShqSpace.md,
            children: <Widget>[
              for (final (PaperStyle style, String label) in _items)
                _StyleDot(
                  style: style,
                  label: label,
                  intensity: intensity,
                  selected: value == style,
                  onTap: () => onChanged(style),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _StyleDot extends StatelessWidget {
  const _StyleDot({
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
    // 夜读色块直接给夜读纸色：它的纸色不来自"白 × 增益"，是两端色映射的暗端。
    if (style.isDarkPaper) {
      return ShqNight.paper;
    }
    final int? rgb = PaperRgb.of(style);
    if (rgb == null) {
      return ShqPaper.base; // original：白纸原样
    }
    // 与 PaperEffect 的乘法同口径：强度 100 时白底完全变成纸色
    return Color.lerp(ShqPaper.base, Color(rgb), intensity / 100)!;
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          AnimatedContainer(
            duration: ShqMotion.instant,
            curve: Curves.easeOutCubic,
            width: 40,
            height: 40,
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
                    size: 18,
                    // 暗纸色块上用暖白勾，否则深墨勾在近黑上看不见。
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
class _IntensityRow extends StatelessWidget {
  const _IntensityRow({
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
    // 原图没有纸色可染；夜读是两端色映射（暗纸端 + 亮墨端），强度不参与。
    final bool enabled = style != PaperStyle.original && !style.isDarkPaper;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        ShqSpace.lg,
        ShqSpace.md,
        ShqSpace.lg,
        ShqSpace.md,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text('默认强度', style: theme.textTheme.labelLarge),
          Row(
            children: <Widget>[
              Icon(
                Icons.wb_sunny_outlined,
                size: 18,
                color: enabled
                    ? theme.colorScheme.onSurfaceVariant
                    : theme.colorScheme.outlineVariant,
              ),
              Expanded(
                child: Slider(
                  value: value.toDouble(),
                  max: 100,
                  divisions: 20,
                  label: '$value%',
                  onChanged: enabled
                      ? (double v) => onChanged(v.round())
                      : null,
                ),
              ),
              SizedBox(
                width: 44,
                child: Text(
                  '$value%',
                  textAlign: TextAlign.end,
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: enabled
                        ? theme.colorScheme.onSurface
                        : theme.colorScheme.outlineVariant,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 置灰的功能入口：看得见、点不动、知道它在路线图哪儿。
class _DisabledTile extends StatelessWidget {
  const _DisabledTile({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    return ListTile(
      leading: Icon(icon, color: scheme.outlineVariant),
      title: Text(
        title,
        style: theme.textTheme.bodyLarge?.copyWith(color: scheme.outline),
      ),
      subtitle: Text(
        subtitle,
        style: theme.textTheme.bodySmall?.copyWith(
          color: scheme.onSurfaceVariant,
        ),
      ),
      trailing: Icon(Icons.lock_outline, size: 18, color: scheme.outlineVariant),
    );
  }
}
