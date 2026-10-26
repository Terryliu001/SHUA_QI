import 'package:flutter/material.dart';
import 'package:shuaqi/domain/reader/reader_prefs.dart';
import 'package:shuaqi/ui/theme/tokens.dart';

/// 显示设置底部浮层（T1.6）：纸感 + 强度。
///
/// 设计取向（设计哲学：谷歌的灵动 + iOS 的优雅简练）：
/// - 顶部小圆拖拽把手、24dp 圆角、发丝线分隔，不堆阴影；
/// - 色块选中态用 `AnimatedContainer` 100ms 收拢描边，即时反馈；
/// - **纸样式与 App 主题正交**（2026-10-22 拍板）：深色界面下同样能选
///   「原图」看白底黑字，浅色界面下同样能选「夜读」看黑底白字。
///   所以这里不再有"深色模式整块置灰"的分支。
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

    return SafeArea(
      child: Container(
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHigh,
          borderRadius: const BorderRadius.vertical(
            top: Radius.circular(ShqRadius.xl),
          ),
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
            _swatches(theme, scheme),
            const SizedBox(height: ShqSpace.xl),
            _intensity(theme, scheme),
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
                    Icons.format_color_text,
                    size: 18,
                    color: scheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: ShqSpace.sm),
                  Expanded(
                    child: Text(
                      '纸感只决定卷面配色：原图 = 白底黑字，夜读 = 黑底白字。'
                      '它和 App 主题互不影响，深色界面下也能看白底黑字。',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _swatches(ThemeData theme, ColorScheme scheme) {
    const List<(PaperStyle, String)> items = <(PaperStyle, String)>[
      (PaperStyle.original, '原图'),
      (PaperStyle.warm, '暖白'),
      (PaperStyle.ivory, '象牙'),
      (PaperStyle.gray, '浅灰'),
      (PaperStyle.green, '护眼'),
      (PaperStyle.night, '夜读'),
    ];
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: <Widget>[
        for (final (PaperStyle style, String label) in items)
          _Swatch(
            style: style,
            label: label,
            selected: _prefs.style == style,
            scheme: scheme,
            onTap: () => _update(_prefs.copyWith(style: style)),
          ),
      ],
    );
  }

  Widget _intensity(ThemeData theme, ColorScheme scheme) {
    // 原图没有纸色可染；夜读是两端色映射，强度不参与。
    final bool enabled =
        _prefs.style != PaperStyle.original && !_prefs.style.isDarkPaper;
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
            // 必须显式给 max：Slider 默认范围是 0..1，而强度是 0..100。
            // 缺这一行会让 55 这样的正常值直接违反断言 —— 一打开「显示」浮层
            // 就报错、整块设置点不动（2026-10-24 用户报的"暗色/其他形式无法设置"）。
            min: 0,
            max: 100,
            divisions: 20,
            label: '${_prefs.intensity}%',
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
    required this.scheme,
    required this.onTap,
  });

  final PaperStyle style;
  final String label;
  final bool selected;
  final ColorScheme scheme;
  final VoidCallback onTap;

  Color get _fill => switch (style) {
    PaperStyle.original => ShqPaper.base,
    PaperStyle.warm => ShqPaper.warm,
    PaperStyle.ivory => ShqPaper.ivory,
    PaperStyle.gray => ShqPaper.gray,
    PaperStyle.green => ShqPaper.green,
    PaperStyle.night => ShqNight.paper,
  };

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
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
                // 夜读色块本身是近黑，选中描边要更醒目一点，否则看不出被选中。
                width: selected ? (style.isDarkPaper ? 3 : 2) : 1,
              ),
            ),
            child: selected
                ? Icon(
                    Icons.check,
                    size: 20,
                    // 勾要压在色块上看清楚：亮纸用深墨，暗纸用暖白墨。
                    color: style == PaperStyle.original
                        ? scheme.primary
                        : (style.isDarkPaper ? ShqNight.ink : ShqPalette.ink),
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
