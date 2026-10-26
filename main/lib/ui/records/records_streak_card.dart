import 'package:flutter/material.dart';
import 'package:shuaqi/domain/records/record_time.dart';
import 'package:shuaqi/domain/records/records_stats.dart';
import 'package:shuaqi/ui/theme/tokens.dart';

/// 连续打卡卡（2026-10-25 用户：参考多邻国，"把火苗点亮，文案丰富一点"）。
///
/// ## 为什么单独成卡，而不是看板里的一行数字
/// 连续天数是最需要"被看见"的一件事：断签一次就归零，所以它的价值不在数字，
/// 而在**提醒"今天还差一笔"**。塞在统计行里（"1 天 连续打卡"）等于藏起来。
///
/// ## 三种状态各有各的话
/// 0 天 / 今天没做 / 今天做了——三种状态下用户的下一步动作完全不同，
/// 所以文案不是把数字拼进同一句模板，而是分状态写：
/// - 还没开始：给一个最低门槛（"做一题"）；
/// - 有连续但今天没做：只提醒"别断"，不说教；
/// - 今天做了：给正反馈 + 下一个目标。
///
/// ## 火苗什么时候"亮"
/// 只在**今天已打卡**时点亮（实心渐变 + 光晕）；有连续但今天没做是"半亮"
/// （描边 + 暖色），完全没记录是灰色。这样"亮"这个信号始终指向今天。
class RecordsStreakCard extends StatelessWidget {
  const RecordsStreakCard({
    super.key,
    required this.streak,
    required this.todayCount,
    required this.dayStats,
    required this.today,
  });

  final int streak;
  final int todayCount;

  /// `本地日期 key → 当天统计`（画本周七个小点用）。
  final Map<String, DayStat> dayStats;
  final DateTime today;

  bool get _todayDone => todayCount > 0;

  /// 0 = 冷、1 = 半亮、2 = 亮。
  int get _flameLevel {
    if (_todayDone) {
      return 2;
    }
    return streak > 0 ? 1 : 0;
  }

  String get _headline {
    if (_todayDone) {
      return streak <= 1 ? '今天开张了' : '连续 $streak 天';
    }
    if (streak > 0) {
      return '连续 $streak 天';
    }
    return '还没点着火';
  }

  String get _subline {
    if (_todayDone) {
      if (streak <= 1) {
        return '第一笔最难，明天再来就成一条线了';
      }
      if (streak < 4) {
        return '手感正在回来，保持这个节奏';
      }
      if (streak < 8) {
        return '已经一整周的量级，别让它断在今天';
      }
      return '这个连续已经很稳了，明天见';
    }
    if (streak > 0) {
      return '今天还差一笔——做一道题就续上';
    }
    return '做一道题，火苗就点着了';
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final int level = _flameLevel;

    return Card(
      child: Padding(
        // 上下各 16：右栏（打卡 + 概览）与左栏（热力图 + 词云）下界对齐，
        // 差一点点会让两栏看着像没对齐的表格（2026-10-25 用户）。
        padding: const EdgeInsets.fromLTRB(
          ShqSpace.lg,
          ShqSpace.lg,
          ShqSpace.lg,
          ShqSpace.lg,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: <Widget>[
            _Flame(level: level),
            const SizedBox(width: ShqSpace.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: <Widget>[
                      Flexible(
                        child: Text(
                          _headline,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      if (_todayDone) ...<Widget>[
                        const SizedBox(width: ShqSpace.sm),
                        _TodayBadge(theme: theme),
                      ],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    _subline,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                      height: 1.35,
                    ),
                  ),
                  const SizedBox(height: ShqSpace.sm),
                  _WeekDots(
                    dayStats: dayStats,
                    today: today,
                    warm: level > 0,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 火苗徽标：三档视觉（冷 / 半亮 / 亮）。
class _Flame extends StatelessWidget {
  const _Flame({required this.level});

  /// 0 = 冷，1 = 半亮（描边），2 = 亮（实心 + 光晕）。
  final int level;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final bool lit = level == 2;
    final bool warm = level >= 1;
    final List<Color> gradient = lit
        ? const <Color>[Color(0xFFFFB74D), Color(0xFFF4511E)]
        : const <Color>[Color(0xFFFFCC80), Color(0xFFFB8C00)];

    return AnimatedContainer(
      duration: ShqMotion.base,
      curve: ShqMotion.curveStandard,
      width: 54,
      height: 54,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: warm
            ? LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: gradient,
              )
            : null,
        color: warm ? null : scheme.surfaceContainerHigh,
        border: Border.all(
          color: lit
              ? Colors.white.withValues(alpha: 0.55)
              : (warm
                    ? Colors.white.withValues(alpha: 0.35)
                    : scheme.outlineVariant),
          width: 1.4,
        ),
        // 光晕只在"亮"时出现：它是"今天已成"的信号，平时不该发光。
        boxShadow: lit
            ? <BoxShadow>[
                BoxShadow(
                  color: const Color(0xFFF4511E).withValues(alpha: 0.42),
                  blurRadius: 16,
                  spreadRadius: 1,
                ),
              ]
            : null,
      ),
      child: Icon(
        Icons.local_fire_department,
        size: 30,
        color: lit
            ? Colors.white
            : (warm ? Colors.white.withValues(alpha: 0.92) : scheme.outline),
      ),
    );
  }
}

class _TodayBadge extends StatelessWidget {
  const _TodayBadge({required this.theme});

  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: ShqSpace.sm, vertical: 1),
      decoration: BoxDecoration(
        color: const Color(0xFFF4511E).withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(ShqRadius.pill),
      ),
      child: Text(
        '今天已打卡',
        style: theme.textTheme.labelSmall?.copyWith(
          color: const Color(0xFFD84315),
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// 本周七天：做完的那天点亮，今天用描边标出（不管做没做）。
class _WeekDots extends StatelessWidget {
  const _WeekDots({
    required this.dayStats,
    required this.today,
    required this.warm,
  });

  final Map<String, DayStat> dayStats;
  final DateTime today;
  final bool warm;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final DateTime monday = RecordTime.mondayOf(today);
    return Row(
      children: <Widget>[
        for (int i = 0; i < 7; i += 1) ...<Widget>[
          if (i > 0) const SizedBox(width: 6),
          _dot(context, theme, scheme, RecordTime.addDays(monday, i)),
        ],
      ],
    );
  }

  Widget _dot(
    BuildContext context,
    ThemeData theme,
    ColorScheme scheme,
    DateTime day,
  ) {
    final int count = dayStats[RecordTime.dayKey(day)]?.questions ?? 0;
    final bool done = count > 0;
    final bool isToday =
        RecordTime.dayKey(day) == RecordTime.dayKey(RecordTime.dateOnly(today));
    final bool future = day.isAfter(RecordTime.dateOnly(today));

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Container(
          width: 16,
          height: 16,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: done
                ? (warm ? const Color(0xFFF4511E) : scheme.primary)
                : scheme.surfaceContainerHigh,
            border: isToday
                ? Border.all(
                    color: done
                        ? const Color(0xFFF4511E)
                        : scheme.onSurfaceVariant,
                    width: 1.4,
                  )
                : null,
          ),
          child: done
              ? const Icon(Icons.check, size: 11, color: Colors.white)
              : null,
        ),
        const SizedBox(height: 3),
        Text(
          RecordTime.weekdayNames[day.weekday - 1],
          style: theme.textTheme.labelSmall?.copyWith(
            fontSize: 9.5,
            height: 1,
            color: future ? scheme.outline : scheme.onSurfaceVariant,
            fontWeight: isToday ? FontWeight.w700 : FontWeight.w400,
          ),
        ),
      ],
    );
  }
}
