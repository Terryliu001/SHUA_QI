import 'package:flutter/material.dart';
import 'package:shuaqi/domain/records/records_overview.dart';
import 'package:shuaqi/domain/records/records_stats.dart';
import 'package:shuaqi/ui/theme/tokens.dart';
import 'package:shuaqi/ui/widgets/pressable.dart';

/// 记录页右侧「数据看板」。
///
/// 口径（与 `PeriodStats` 一致，避免两处各说一套）：
/// - **题数**：这段时间内不同题目的数量（同题多刷只算一道）；
/// - **卷数**：涉及的卷数；
/// - **正确率**：只统计**已判**的题（对 / 对+错），没判过就是空档而不是 0%。
///
/// 底部是作答时间线入口——它不是"另一个按钮"，而是这张看板的下一层：
/// 看板说"多少"，时间线回答"是哪几张卷、哪几道题"。
class RecordsStatsBoard extends StatefulWidget {
  const RecordsStatsBoard({
    super.key,
    required this.overview,
    required this.onOpenTimeline,
  });

  final RecordsOverview overview;
  final VoidCallback onOpenTimeline;

  @override
  State<RecordsStatsBoard> createState() => _RecordsStatsBoardState();
}

class _RecordsStatsBoardState extends State<RecordsStatsBoard> {
  bool _monthly = false;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final PeriodStats stats = _monthly ? widget.overview.month : widget.overview.week;
    final String range = _monthly ? '近 30 天' : '近 7 天';

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          ShqSpace.lg,
          ShqSpace.lg,
          ShqSpace.lg,
          ShqSpace.md,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              children: <Widget>[
                Text(
                  '作答概览',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(width: ShqSpace.sm),
                Text(
                  range,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const Spacer(),
                _RangeToggle(
                  monthly: _monthly,
                  onChanged: (bool value) => setState(() => _monthly = value),
                ),
              ],
            ),
            const SizedBox(height: ShqSpace.lg),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: <Widget>[
                Expanded(
                  child: _BigNumber(
                    value: '${stats.questions}',
                    unit: '题',
                    label: '做过',
                  ),
                ),
                Expanded(
                  child: _BigNumber(
                    value: '${stats.workbooks}',
                    unit: '卷',
                    label: '涉及',
                  ),
                ),
                Expanded(
                  child: _BigNumber(
                    value: stats.accuracy == null
                        ? '—'
                        : '${(stats.accuracy! * 100).round()}',
                    unit: stats.accuracy == null ? '' : '%',
                    label: '正确率',
                    muted: stats.accuracy == null,
                  ),
                ),
              ],
            ),
            const SizedBox(height: ShqSpace.lg),
            _VerdictBar(stats: stats),
            const SizedBox(height: ShqSpace.md),
            Divider(height: 1, color: scheme.outlineVariant),
            const SizedBox(height: ShqSpace.md),
            // 连续打卡已单独成卡（2026-10-25 用户：火苗要立起来），
            // 这里只留"累计"——同一个数字出现两遍会让人怀疑哪一个是准的。
            Row(
              children: <Widget>[
                _MiniStat(
                  icon: Icons.inventory_2_outlined,
                  value: '${widget.overview.totalQuestions}',
                  unit: '题',
                  label: '累计',
                ),
                const SizedBox(width: ShqSpace.lg),
                Container(width: 1, height: 30, color: scheme.outlineVariant),
                const SizedBox(width: ShqSpace.lg),
                _MiniStat(
                  icon: Icons.event_available_outlined,
                  value: '${widget.overview.activeDays}',
                  unit: '天',
                  label: '有记录',
                ),
                const SizedBox(width: ShqSpace.lg),
                _MiniStat(
                  icon: Icons.auto_stories_outlined,
                  value: '${widget.overview.totalWorkbooks}',
                  unit: '卷',
                  label: '做过',
                ),
              ],
            ),
            const SizedBox(height: ShqSpace.md),
            _TimelineEntry(
              overview: widget.overview,
              onTap: widget.onOpenTimeline,
            ),
          ],
        ),
      ),
    );
  }
}

class _RangeToggle extends StatelessWidget {
  const _RangeToggle({required this.monthly, required this.onChanged});

  final bool monthly;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(ShqRadius.pill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          _pill(context, '7 天', !monthly, () => onChanged(false)),
          _pill(context, '30 天', monthly, () => onChanged(true)),
        ],
      ),
    );
  }

  Widget _pill(BuildContext context, String label, bool active, VoidCallback onTap) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: ShqMotion.instant,
        curve: ShqMotion.curveStandard,
        padding: const EdgeInsets.symmetric(horizontal: ShqSpace.md, vertical: 4),
        decoration: BoxDecoration(
          color: active ? scheme.surface : Colors.transparent,
          borderRadius: BorderRadius.circular(ShqRadius.pill),
        ),
        child: Text(
          label,
          style: theme.textTheme.labelSmall?.copyWith(
            color: active ? scheme.onSurface : scheme.onSurfaceVariant,
            fontWeight: active ? FontWeight.w600 : FontWeight.w500,
          ),
        ),
      ),
    );
  }
}

class _BigNumber extends StatelessWidget {
  const _BigNumber({
    required this.value,
    required this.unit,
    required this.label,
    this.muted = false,
  });

  final String value;
  final String unit;
  final String label;
  final bool muted;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: <Widget>[
            Text(
              value,
              style: theme.textTheme.headlineMedium?.copyWith(
                fontWeight: FontWeight.w600,
                color: muted ? scheme.outline : scheme.onSurface,
                fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
              ),
            ),
            if (unit.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(left: 2),
                child: Text(
                  unit,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 2),
        Text(
          label,
          style: theme.textTheme.labelSmall?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

/// 判定分布条：对 / 错 / 待判 / 未判。
///
/// 用一条 8dp 的横条而不是饼图/环图：看的是"比例"，一条线的长短比角度好读，
/// 也占更少的高度（右侧栏要放得下三个数字 + 打卡 + 入口）。
class _VerdictBar extends StatelessWidget {
  const _VerdictBar({required this.stats});

  final PeriodStats stats;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final List<double> fractions = stats.verdictFractions;
    final List<Color> colors = <Color>[
      ShqPalette.correct,
      ShqPalette.wrong,
      ShqPalette.unclear,
      scheme.surfaceContainerHighest,
    ];
    final bool empty = stats.correct + stats.wrong + stats.pending + stats.none == 0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        ClipRRect(
          borderRadius: BorderRadius.circular(ShqRadius.pill),
          child: SizedBox(
            height: 8,
            child: empty
                ? ColoredBox(color: scheme.surfaceContainerHighest)
                : Row(
                    children: <Widget>[
                      for (int i = 0; i < 4; i += 1)
                        if (fractions[i] > 0)
                          Expanded(
                            flex: (fractions[i] * 1000).round().clamp(1, 1000),
                            child: ColoredBox(color: colors[i]),
                          ),
                    ],
                  ),
          ),
        ),
        const SizedBox(height: ShqSpace.sm),
        Row(
          children: <Widget>[
            _legend(theme, ShqPalette.correct, '对', stats.correct),
            const SizedBox(width: ShqSpace.md),
            _legend(theme, ShqPalette.wrong, '错', stats.wrong),
            const SizedBox(width: ShqSpace.md),
            _legend(theme, ShqPalette.unclear, '待判', stats.pending),
            const SizedBox(width: ShqSpace.md),
            _legend(theme, scheme.outline, '未判', stats.none),
          ],
        ),
      ],
    );
  }

  Widget _legend(ThemeData theme, Color color, String label, int count) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Container(
          width: 7,
          height: 7,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 4),
        Text(
          '$label $count',
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

class _MiniStat extends StatelessWidget {
  const _MiniStat({
    required this.icon,
    required this.value,
    required this.unit,
    required this.label,
  });

  final IconData icon;
  final String value;
  final String unit;
  final String label;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Icon(icon, size: 17, color: scheme.onSurfaceVariant),
        const SizedBox(width: 6),
        Text(
          value,
          style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
        ),
        Text(
          unit,
          style: theme.textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
        ),
        const SizedBox(width: 6),
        Text(
          label,
          style: theme.textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
        ),
      ],
    );
  }
}

/// 时间线入口：整块可点，右侧带一句"最近一条"摘要。
class _TimelineEntry extends StatelessWidget {
  const _TimelineEntry({required this.overview, required this.onTap});

  final RecordsOverview overview;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final int today = overview.todayCount(_todayKey(overview));
    return Pressable(
      onTap: onTap,
      scale: 0.995,
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: ShqSpace.md,
          vertical: ShqSpace.sm,
        ),
        decoration: BoxDecoration(
          color: scheme.primaryContainer.withValues(alpha: 0.42),
          borderRadius: BorderRadius.circular(ShqRadius.md),
        ),
        child: Row(
          children: <Widget>[
            Icon(Icons.timeline, size: 18, color: scheme.onPrimaryContainer),
            const SizedBox(width: ShqSpace.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(
                    '作答时间线',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: scheme.onPrimaryContainer,
                    ),
                  ),
                  const SizedBox(height: 1),
                  Text(
                    today > 0 ? '今天已做 $today 题' : '按天回看做过哪些卷与题',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.onPrimaryContainer.withValues(alpha: 0.78),
                    ),
                  ),
                ],
              ),
            ),
            Icon(
              Icons.chevron_right,
              size: 20,
              color: scheme.onPrimaryContainer.withValues(alpha: 0.8),
            ),
          ],
        ),
      ),
    );
  }
}

String _todayKey(RecordsOverview overview) {
  final DateTime now = overview.generatedAt;
  final String m = now.month.toString().padLeft(2, '0');
  final String d = now.day.toString().padLeft(2, '0');
  return '${now.year}-$m-$d';
}
