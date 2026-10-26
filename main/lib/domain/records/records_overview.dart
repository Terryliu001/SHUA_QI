/// 记录页首屏要的全部数据（纯 Dart 容器）。
///
/// 一次装配、一次下发给 UI：热力图、连续天数、7/30 天看板、词云都读它。
/// 分成多个 provider 会让同一批查询跑好几遍，也让"今天"这个基准
/// 在不同控件里不一致（跨零点时会看到两个不同的"今天"）。
library;

import 'package:shuaqi/domain/records/records_stats.dart';

class RecordsOverview {
  const RecordsOverview({
    required this.generatedAt,
    required this.dayStats,
    required this.week,
    required this.month,
    required this.streak,
    required this.totalQuestions,
    required this.activeDays,
    required this.totalWorkbooks,
    required this.subjectWords,
    required this.kindWords,
  });

  static RecordsOverview empty({DateTime? now}) => RecordsOverview(
    generatedAt: now ?? DateTime.now(),
    dayStats: const <String, DayStat>{},
    week: const PeriodStats(),
    month: const PeriodStats(),
    streak: 0,
    totalQuestions: 0,
    activeDays: 0,
    totalWorkbooks: 0,
    subjectWords: const <CloudWord>[],
    kindWords: const <CloudWord>[],
  );

  /// 装配时刻（UI 用它算"今天"，避免各处各取一次 now）。
  final DateTime generatedAt;

  /// 热力图与连续天数：`本地日期 key → (题数, 卷数)`。
  final Map<String, DayStat> dayStats;

  /// 近 7 天（含今天）。
  final PeriodStats week;

  /// 近 30 天（含今天）。
  final PeriodStats month;

  final int streak;
  final int totalQuestions;
  final int activeDays;

  /// 累计涉及的卷数（有记录的卷）。
  final int totalWorkbooks;

  /// 词云：按科目（文件夹）。
  final List<CloudWord> subjectWords;

  /// 词云：按题型。
  final List<CloudWord> kindWords;

  bool get isEmpty => totalQuestions == 0;

  /// 今天做了几题。
  int todayCount(String todayKey) => dayStats[todayKey]?.questions ?? 0;
}
