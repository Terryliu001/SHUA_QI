import 'package:flutter/material.dart';
import 'package:shuaqi/domain/reader/reader_prefs.dart';
import 'package:shuaqi/ui/theme/tokens.dart';

/// 显示设置底部浮层（T1.6）：纸感 + 强度。
///
/// 设计取向（设计哲学：谷歌的灵动 + iOS 的优雅简练）：
/// - 顶部小圆拖拽把手、24dp 圆角、发丝线分隔，不堆阴影；
/// - 色块选中态用 `AnimatedContainer` 100ms 收拢描边，即时反馈；
/// - 深色模式整块置灰并给一句说明，而不是让用户点了没反应。
Future<void> showPaperStyleSheet(
  BuildContext context, {
  required ReaderPrefs prefs,
  required ValueChanged<ReaderPrefs> onChanged,
}) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    builder: (BuildContext context) =>
        _PaperStyleSheet(initial: prefs, onChanged: onChanged),
  );
}

class _PaperStyleSheet extends StatefulWidget {
  const _PaperStyleSheet({required this.initial, required this.onChanged});

  final ReaderPrefs initial;
  final ValueChanged<ReaderPrefs> onChanged;

  @override
  State<_PaperStyleSheet> createState() => _PaperStyleSheetState();
}

class _PaperStyleSheetState extends State<_PaperStyleSheet> {
  late ReaderPrefs _prefs = widget.initial;

  void _update(ReaderPrefs next) {
    setState(() => _prefs = next);
    widget.onChanged(next);
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final bool isDark = theme.brightness == Brightness.dark;

    return SafeArea(
      child: Container(
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHigh,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        ),
        padding: const EdgeInsets.fromLTRB(
          ShqSpace.xl,
          ShqSpace.sm,
          ShqSpace.xl,
          ShqSpace.lg,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Center(
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: scheme.outlineVariant,
                  borderRadius: BorderRadius.circular(ShqRadius.pill),
                ),
              ),
            ),
            const SizedBox(height: ShqSpace.lg),
            Text('显示', style: theme.textTheme.titleMedium),
            const SizedBox(height: ShqSpace.lg),
            Text('纸感', style: theme.textTheme.labelLarge),
            const SizedBox(height: ShqSpace.md),
            _swatches(theme, scheme, isDark),
            const SizedBox(height: ShqSpace.xl),
            _intensity(theme, scheme, isDark),
            if (isDark) ...<Widget>[
              const SizedBox(height: ShqSpace.lg),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(ShqSpace.md),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerLow,
                  borderRadius: BorderRadius.circular(ShqRadius.md),
                ),
                child: Row(
                  children: <Widget>[
                    Icon(
                      Icons.dark_mode_outlined,
                      size: 18,
                      color: scheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: ShqSpace.sm),
                    Expanded(
                      child: Text(
                        '深色模式下已停用纸感，避免纸色与暗底叠成脏色',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _swatches(ThemeData theme, ColorScheme scheme, bool isDark) {
    const List<(PaperStyle, String)> items = <(PaperStyle, String)>[
      (PaperStyle.original, '原图'),
      (PaperStyle.warm, '暖白'),
      (PaperStyle.ivory, '象牙'),
      (PaperStyle.gray, '浅灰'),
      (PaperStyle.green, '护眼'),
    ];
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: <Widget>[
        for (final (PaperStyle style, String label) in items)
          _Swatch(
            style: style,
            label: label,
            selected: _prefs.style == style,
            enabled: !isDark,
            scheme: scheme,
            onTap: () => _update(_prefs.copyWith(style: style)),
          ),
      ],
    );
  }

  Widget _intensity(ThemeData theme, ColorScheme scheme, bool isDark) {
    final bool enabled = !isDark && _prefs.style != PaperStyle.original;
    return Row(
      children: <Widget>[
        Icon(
          Icons.wb_sunny_outlined,
          size: 18,
          color: enabled ? scheme.onSurfaceVariant : scheme.outlineVariant,
        ),
        Expanded(
          child: Slider(
            value: _prefs.intensity.toDouble(),
            onChanged: enabled
                ? (double v) => _update(_prefs.copyWith(intensity: v.round()))
                : null,
          ),
        ),
        SizedBox(
          width: 40,
          child: Text(
            '${_prefs.intensity}%',
            textAlign: TextAlign.end,
            style: theme.textTheme.labelLarge?.copyWith(
              color: enabled ? scheme.onSurface : scheme.outlineVariant,
            ),
          ),
        ),
      ],
    );
  }
}

class _Swatch extends StatelessWidget {
  const _Swatch({
    required this.style,
    required this.label,
    required this.selected,
    required this.enabled,
    required this.scheme,
    required this.onTap,
  });

  final PaperStyle style;
  final String label;
  final bool selected;
  final bool enabled;
  final ColorScheme scheme;
  final VoidCallback onTap;

  Color get _fill => switch (style) {
    PaperStyle.original => Colors.white,
    PaperStyle.warm => ShqPaper.warm,
    PaperStyle.ivory => ShqPaper.ivory,
    PaperStyle.gray => ShqPaper.gray,
    PaperStyle.green => ShqPaper.green,
  };

  @override
  Widget build(BuildContext context) {
    final double opacity = enabled ? 1 : 0.35;
    return Opacity(
      opacity: opacity,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: enabled ? onTap : null,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            AnimatedContainer(
              duration: ShqMotion.instant,
              curve: Curves.easeOutCubic,
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: _fill,
                shape: BoxShape.circle,
                border: Border.all(
                  color: selected
                      ? scheme.primary
                      : (style == PaperStyle.original
                          ? scheme.outline
                          : scheme.outlineVariant),
                  width: selected ? 2 : 1,
                ),
              ),
              child: selected
                  ? Icon(
                      Icons.check,
                      size: 20,
                      color: style == PaperStyle.original
                          ? scheme.primary
                          : Colors.black54,
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
      ),
    );
  }
}
