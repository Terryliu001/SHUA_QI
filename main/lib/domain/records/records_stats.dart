/// 记录页的统计纯函数（热力档位 / 周网格 / 周期统计 / 词云权重 / 时间线分组）。
///
/// 全部是纯函数：输入是数字与值对象，输出也是——不碰 IO、不碰 Flutter。
/// 这样"档位对不对""跨月周一对不对""连续天数怎么断"都能用宿主单测钉住，
/// 而不是靠真机数格子。
library;

import 'dart:math' as math;

import 'package:shuaqi/domain/model/grading.dart';
import 'package:shuaqi/domain/records/answer_log.dart';
import 'package:shuaqi/domain/records/record_time.dart';

/// 一天的聚合（热力图点格子时的数据源）。
class DayStat {
  const DayStat({required this.questions, required this.workbooks});

  final int questions;
  final int workbooks;
}

/// 热力档位（用户口径）：无 · 1–2 · 3–5 · 6–9 · 10–15 · 16+
///
/// 0 = 那天没有记录（不是"0 题"那个档，画的是空格底色）。
int heatLevel(int count) {
  if (count <= 0) {
    return 0;
  }
  if (count <= 2) {
    return 1;
  }
  if (count <= 5) {
    return 2;
  }
  if (count <= 9) {
    return 3;
  }
  if (count <= 15) {
    return 4;
  }
  return 5;
}

/// 档位说明（图例 / 无障碍语义都用同一份文案）。
String heatLevelLabel(int level) => switch (level) {
  0 => '没有记录',
  1 => '1–2 题',
  2 => '3–5 题',
  3 => '6–9 题',
  4 => '10–15 题',
  _ => '16 题以上',
};

/// 热力图的一格。
class HeatCell {
  const HeatCell({
    required this.day,
    required this.count,
    required this.level,
    required this.future,
  });

  final DateTime day;
  final int count;

  /// 0..5，见 [heatLevel]。
  final int level;

  /// 晚于今天（网格右端要对齐到本周日，未来格子不画）。
  final bool future;
}

/// 热力图的一列 = 一周（周一 → 周日）。
class HeatWeek {
  const HeatWeek(this.days);

  final List<HeatCell> days;

  /// 这一列是否跨月（画月份标签用）：首日所在月与上一列不同即视为新月。
  DateTime get firstDay => days.first.day;
}

/// 生成 [weeks] 周的网格，**右端对齐到本周**（今天所在周），周一起。
///
/// 为什么右端对齐本周而不是"最后一天是今天"：GitHub 的网格是整列整列的，
/// 右端截到周中会让最后一列只有一两格，看起来像渲染残缺。
List<HeatWeek> buildHeatWeeks({
  required DateTime today,
  required Map<String, DayStat> stats,
  int weeks = 26,
}) {
  final DateTime end = RecordTime.mondayOf(today);
  final DateTime start = RecordTime.addDays(end, -(weeks - 1) * 7);
  final DateTime todayOnly = RecordTime.dateOnly(today);

  final List<HeatWeek> out = <HeatWeek>[];
  for (int w = 0; w < weeks; w += 1) {
    final List<HeatCell> days = <HeatCell>[];
    for (int d = 0; d < 7; d += 1) {
      final DateTime day = RecordTime.addDays(start, w * 7 + d);
      final bool future = day.isAfter(todayOnly);
      final int count = future ? 0 : (stats[RecordTime.dayKey(day)]?.questions ?? 0);
      days.add(
        HeatCell(
          day: day,
          count: count,
          level: future ? 0 : heatLevel(count),
          future: future,
        ),
      );
    }
    out.add(HeatWeek(days));
  }
  return out;
}

/// 连续打卡天数。
///
/// 口径：从今天往回数，今天没有记录时**从昨天起算**（今天还没开始刷不算断签）；
/// 一旦遇到空天就停。这样早上打开 App 看到的是"昨天为止的连续天数"，不会被清零。
int currentStreak(Map<String, DayStat> stats, {required DateTime today}) {
  DateTime cursor = RecordTime.dateOnly(today);
  if ((stats[RecordTime.dayKey(cursor)]?.questions ?? 0) <= 0) {
    cursor = RecordTime.addDays(cursor, -1);
  }
  int streak = 0;
  while ((stats[RecordTime.dayKey(cursor)]?.questions ?? 0) > 0) {
    streak += 1;
    cursor = RecordTime.addDays(cursor, -1);
  }
  return streak;
}

/// 一段时间内的作答统计。
class PeriodStats {
  const PeriodStats({
    this.questions = 0,
    this.workbooks = 0,
    this.days = 0,
    this.correct = 0,
    this.wrong = 0,
    this.pending = 0,
    this.none = 0,
  });

  /// 做过的题数（同题多次只算一道）。
  final int questions;

  /// 涉及的卷数。
  final int workbooks;

  /// 有记录的天数。
  final int days;

  final int correct;
  final int wrong;
  final int pending;
  final int none;

  bool get isEmpty => questions == 0;

  /// 已判题里的正确率；没判过任何题时为 null（不显示 0%，那是误导）。
  double? get accuracy {
    final int judged = correct + wrong;
    if (judged == 0) {
      return null;
    }
    return correct / judged;
  }

  /// 判定分布（画条用），长度归一。
  List<double> get verdictFractions {
    final int total = correct + wrong + pending + none;
    if (total == 0) {
      return const <double>[0, 0, 0, 0];
    }
    return <double>[
      correct / total,
      wrong / total,
      pending / total,
      none / total,
    ];
  }
}

/// 按 [from]~[to]（含）的本地日期过滤并统计。
///
/// 入参可以是全量记录：记录量级是"天 × 题"，一年重度使用也就万级，
/// 在主 isolate 上过滤一次是毫秒级；换来的是**一条口径**（不用同时维护 SQL 聚合与纯函数两份）。
PeriodStats summarize(
  Iterable<AnswerLogEntry> entries, {
  required DateTime from,
  required DateTime to,
}) {
  final DateTime fromDay = RecordTime.dateOnly(from);
  final DateTime toDay = RecordTime.dateOnly(to);
  final Set<String> questions = <String>{};
  final Set<String> workbooks = <String>{};
  final Set<String> days = <String>{};
  int correct = 0;
  int wrong = 0;
  int pending = 0;
  int none = 0;

  for (final AnswerLogEntry entry in entries) {
    final DateTime day = RecordTime.parseDayKey(entry.day);
    if (day.isBefore(fromDay) || day.isAfter(toDay)) {
      continue;
    }
    questions.add(entry.questionId);
    workbooks.add(entry.workbookId);
    days.add(entry.day);
    switch (entry.verdict) {
      case AnswerVerdict.correct:
        correct += 1;
      case AnswerVerdict.wrong:
        wrong += 1;
      case AnswerVerdict.pending:
        pending += 1;
      case AnswerVerdict.none:
        none += 1;
    }
  }

  return PeriodStats(
    questions: questions.length,
    workbooks: workbooks.length,
    days: days.length,
    correct: correct,
    wrong: wrong,
    pending: pending,
    none: none,
  );
}

/// 把明细折成「按天」的聚合（热力图 / 连续天数用）。
///
/// 顺带修掉一个坑：同一天同一题本来就只有一行，但历史回填可能带进重复，
/// 这里按 `(questionId)` 在一天内去重，保证"19 题"是真的 19 道题。
Map<String, DayStat> aggregateByDay(Iterable<AnswerLogEntry> entries) {
  final Map<String, Set<String>> questionsByDay = <String, Set<String>>{};
  final Map<String, Set<String>> workbooksByDay = <String, Set<String>>{};
  for (final AnswerLogEntry entry in entries) {
    questionsByDay.putIfAbsent(entry.day, () => <String>{}).add(entry.questionId);
    workbooksByDay.putIfAbsent(entry.day, () => <String>{}).add(entry.workbookId);
  }
  return <String, DayStat>{
    for (final MapEntry<String, Set<String>> e in questionsByDay.entries)
      e.key: DayStat(
        questions: e.value.length,
        workbooks: workbooksByDay[e.key]?.length ?? 0,
      ),
  };
}

// ── 词云 ────────────────────────────────────────────────────────────────

/// 词云的一格输入（按某个维度聚合后的原始计数）。
class CloudBucket {
  const CloudBucket({
    required this.label,
    this.questions = 0,
    this.workbooks = 0,
  });

  final String label;
  final int questions;
  final int workbooks;
}

/// 词云的一个词。
class CloudWord {
  const CloudWord({
    required this.label,
    required this.questions,
    required this.workbooks,
    required this.weight,
  });

  final String label;
  final int questions;
  final int workbooks;

  /// 权重 = 题数 × [kQuestionWeight] + 卷数 × [kWorkbookWeight]。
  final double weight;

  /// `12 题 · 2 卷`
  String get detail => '$questions 题 · $workbooks 卷';
}

/// 题数权重（一道题算一份）。
const double kQuestionWeight = 1;

/// 卷数权重（一整套卷的分量远大于一道题，取 3 倍）。
///
/// 为什么不是"卷数 × 卷内题数"：那等于让长卷碾压一切，词云会只剩一个词。
/// 3 倍的效果是：一卷做了 5 题（5+3=8）比同卷 3 题（3+3=6）重，
/// 而 3 道散落在 3 卷的题（3+9=12）比单卷 8 题更"广"。
const double kWorkbookWeight = 3;

/// 合并同名词并按权重倒序。
///
/// 排序是**确定性**的：权重相同按题数、再按名字，词云布局才不会每次刷新都跳。
List<CloudWord> buildCloudWords(Iterable<CloudBucket> buckets) {
  final Map<String, CloudBucket> merged = <String, CloudBucket>{};
  for (final CloudBucket bucket in buckets) {
    final String label = bucket.label.trim();
    if (label.isEmpty) {
      continue;
    }
    final CloudBucket prev = merged[label] ?? const CloudBucket(label: '');
    merged[label] = CloudBucket(
      label: label,
      questions: prev.questions + bucket.questions,
      workbooks: prev.workbooks + bucket.workbooks,
    );
  }
  final List<CloudWord> words = <CloudWord>[
    for (final CloudBucket bucket in merged.values)
      CloudWord(
        label: bucket.label,
        questions: bucket.questions,
        workbooks: bucket.workbooks,
        weight: bucket.questions * kQuestionWeight +
            bucket.workbooks * kWorkbookWeight,
      ),
  ];
  words.sort((CloudWord a, CloudWord b) {
    final int byWeight = b.weight.compareTo(a.weight);
    if (byWeight != 0) {
      return byWeight;
    }
    final int byQuestions = b.questions.compareTo(a.questions);
    if (byQuestions != 0) {
      return byQuestions;
    }
    return a.label.compareTo(b.label);
  });
  return words;
}

/// 词的字号：按 `sqrt(weight / maxWeight)` 归一，最小 [min]，最大 [max]。
///
/// 用开方而不是线性：线性会让第一名之外全是"小字"，词云变成一个大词 +
/// 一堆看不清的尾巴；开方把中间档拉开，视觉重心更均匀。
double cloudFontSize(
  double weight, {
  required double maxWeight,
  double min = 12,
  double max = 30,
}) {
  if (maxWeight <= 0 || weight <= 0) {
    return min;
  }
  final double t = math.sqrt((weight / maxWeight).clamp(0.0, 1.0));
  return min + (max - min) * t;
}

/// 按**科目（文件夹）**汇总题数 → 词云。
///
/// 口径（用户 2026-10-26 拍板）：**每层文件夹各算一个词**。
/// 内层文件夹（数学 → 高数）里的卷算在「高数」名下，不上卷到「数学」；
/// 这样词云里能看出"高数比线代做得多"。
///
/// [folderIdOfWorkbook] 是 `workbookId → folderId`；[folderNameById] 是
/// `folderId → 文件夹名`。找不到文件夹的卷归「未分类」。
List<CloudWord> subjectWordsFrom({
  required Map<String, int> questionsByWorkbook,
  required Map<String, String> folderIdOfWorkbook,
  required Map<String, String> folderNameById,
}) {
  final Map<String, CloudBucket> buckets = <String, CloudBucket>{};
  for (final MapEntry<String, int> entry in questionsByWorkbook.entries) {
    final String folderId = folderIdOfWorkbook[entry.key] ?? '';
    final String label = folderNameById[folderId] ?? '未分类';
    final CloudBucket prev = buckets[label] ?? CloudBucket(label: label);
    buckets[label] = CloudBucket(
      label: label,
      questions: prev.questions + entry.value,
      workbooks: prev.workbooks + 1,
    );
  }
  return buildCloudWords(buckets.values);
}

// ── 时间线 ──────────────────────────────────────────────────────────────

/// 时间线里「一组记录」的分组。
///
/// 2026-10-26（用户第 9/16 条）：分组不再只按卷，而是按**来源**：
/// - `workbook`：在原卷里做的（一张卷一张卡）；
/// - `set`：在**组卷**里重刷的（按组卷名分组，卡上标「组卷 · 名字」）；
/// - `redo`：单题重刷（当天所有单题重刷归一张「重刷」卡，默认折叠）。
class TimelineWorkbook {
  const TimelineWorkbook({
    required this.workbookId,
    required this.title,
    required this.entries,
    required this.sourceDeleted,
    this.origin = RecordOrigin.workbook,
    this.originTitle = '',
    this.attemptId = '',
  });

  /// 分组键（内部用）：原卷是卷 id，组卷是 `set:<名>`，单题重刷是 `redo`；
  /// v9 起带 attempt 的组用 `a:<attemptId>`，同一天多次重刷各一张卡。
  final String workbookId;

  /// 显示名（活库优先，卷删了用快照）。
  final String title;

  final List<AnswerLogEntry> entries;

  /// 原卷是否已删除（卡片置灰 + 「原卷已删」）。
  final bool sourceDeleted;

  /// 这一组是在哪儿做的。
  final RecordOrigin origin;

  /// 组卷名（只有 [RecordOrigin.set] 有值）。
  final String originTitle;

  /// 这一次重刷的 attempt（v9）；空 = 原卷 / 旧版重刷。
  final String attemptId;

  /// 是不是"又刷了一遍"的组（时间线里默认折叠）。
  bool get isRedo => origin.isRedo;

  bool get hasAttempt => attemptId.isNotEmpty;

  int get questions => entries.length;

  DateTime get firstAt =>
      DateTime.fromMillisecondsSinceEpoch(entries.last.at);

  DateTime get lastAt => DateTime.fromMillisecondsSinceEpoch(entries.first.at);

  int countOf(AnswerVerdict verdict) =>
      entries.where((AnswerLogEntry e) => e.verdict == verdict).length;
}

/// 时间线里「一天」的分组。
class TimelineDay {
  const TimelineDay({
    required this.day,
    required this.workbooks,
    required this.questions,
  });

  final DateTime day;
  final List<TimelineWorkbook> workbooks;
  final int questions;

  int get workbookCount => workbooks.length;

  int countOf(AnswerVerdict verdict) => workbooks.fold<int>(
    0,
    (int sum, TimelineWorkbook wb) => sum + wb.countOf(verdict),
  );
}

/// 按「天 → 卷」分组。入参应已按 `at` 倒序（DAO 的 order by）。
///
/// [existingWorkbookIds] 用来判断"原卷还在不在"：不在就标 [sourceDeleted]，
/// 卡片不再提供"回原卷"（与收藏夹 058 的口径一致）。
List<TimelineDay> groupTimeline(
  List<AnswerLogEntry> entries, {
  required Set<String> existingWorkbookIds,
  Map<String, String> liveTitles = const <String, String>{},
}) {
  final Map<String, List<AnswerLogEntry>> byDay = <String, List<AnswerLogEntry>>{};
  for (final AnswerLogEntry entry in entries) {
    byDay.putIfAbsent(entry.day, () => <AnswerLogEntry>[]).add(entry);
  }

  final List<String> days = byDay.keys.toList()..sort((String a, String b) => b.compareTo(a));
  final List<TimelineDay> out = <TimelineDay>[];
  for (final String day in days) {
    final List<AnswerLogEntry> dayEntries = byDay[day]!;
    final Map<String, List<AnswerLogEntry>> byWorkbook = <String, List<AnswerLogEntry>>{};
    final Map<String, AnswerLogEntry> firstOf = <String, AnswerLogEntry>{};
    final List<String> order = <String>[];
    for (final AnswerLogEntry entry in dayEntries) {
      final String key = _groupKeyOf(entry);
      final List<AnswerLogEntry>? bucket = byWorkbook[key];
      if (bucket == null) {
        byWorkbook[key] = <AnswerLogEntry>[entry];
        firstOf[key] = entry;
        order.add(key);
      } else {
        bucket.add(entry);
      }
    }
    final List<TimelineWorkbook> workbooks = <TimelineWorkbook>[];
    for (final String key in order) {
      final List<AnswerLogEntry> items = byWorkbook[key]!
        ..sort((AnswerLogEntry a, AnswerLogEntry b) => b.at.compareTo(a.at));
      final AnswerLogEntry first = firstOf[key]!;
      final String snapshot = first.workbookTitle;
      final String live = liveTitles[first.workbookId] ?? '';
      workbooks.add(
        TimelineWorkbook(
          workbookId: key,
          title: switch (first.origin) {
            RecordOrigin.set => '组卷 · ${first.originTitle.isEmpty ? '未命名组卷' : first.originTitle}',
            RecordOrigin.redo => '重刷',
            RecordOrigin.workbook => live.isNotEmpty
                ? live
                : (snapshot.isEmpty ? '未命名试卷' : snapshot),
          },
          entries: items,
          sourceDeleted: first.origin == RecordOrigin.workbook &&
              !existingWorkbookIds.contains(first.workbookId),
          origin: first.origin,
          originTitle: first.originTitle,
          attemptId: first.attemptId,
        ),
      );
    }
    out.add(
      TimelineDay(
        day: RecordTime.parseDayKey(day),
        workbooks: workbooks,
        questions: dayEntries.length,
      ),
    );
  }
  return out;
}

/// 一条记录属于哪一组。
///
/// - 原卷：按卷 id 分（回到第一卷就还是那张卷卡）；
/// - 组卷 / 单题重刷：v9 起优先按 `attemptId` 分，**同一天刷两次是两张卡**；
///   旧数据 attemptId 为空时退回原来的「组卷名 / 重刷」聚合。
String _groupKeyOf(AnswerLogEntry entry) {
  if (entry.attemptId.isNotEmpty) {
    return 'a:${entry.attemptId}';
  }
  return switch (entry.origin) {
    RecordOrigin.set => 'set:${entry.originTitle}',
    RecordOrigin.redo => 'redo',
    RecordOrigin.workbook => 'w:${entry.workbookId}',
  };
}
