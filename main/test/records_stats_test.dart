import 'package:flutter_test/flutter_test.dart';
import 'package:shuaqi/domain/model/grading.dart';
import 'package:shuaqi/domain/records/answer_log.dart';
import 'package:shuaqi/domain/records/record_time.dart';
import 'package:shuaqi/domain/records/records_stats.dart';

/// 记录页的统计口径。这些数字会直接显示给用户看（"今天 7 题""连续 3 天"），
/// 错一个就会被当成"App 记错了"，所以每条口径都用测试钉住。
void main() {
  group('热力档位（0-2 / 3-5 / 6-9 / 10-15 / 16+）', () {
    test('边界值', () {
      expect(heatLevel(0), 0);
      expect(heatLevel(1), 1);
      expect(heatLevel(2), 1);
      expect(heatLevel(3), 2);
      expect(heatLevel(5), 2);
      expect(heatLevel(6), 3);
      expect(heatLevel(9), 3);
      expect(heatLevel(10), 4);
      expect(heatLevel(15), 4);
      expect(heatLevel(16), 5);
      expect(heatLevel(999), 5);
    });

    test('负数/异常按无记录处理', () {
      expect(heatLevel(-3), 0);
    });
  });

  group('热力图网格', () {
    test('26 周 × 7 天，周一起，末列包含今天', () {
      final DateTime today = DateTime(2026, 10, 25); // 周日
      final List<HeatWeek> weeks = buildHeatWeeks(
        today: today,
        stats: const <String, DayStat>{},
      );
      expect(weeks.length, 26);
      for (final HeatWeek week in weeks) {
        expect(week.days.length, 7);
      }
      expect(weeks.first.days.first.day.weekday, DateTime.monday);
      expect(
        weeks.last.days.first.day,
        DateTime(2026, 10, 19),
        reason: '末列应是本周（10/19 周一）',
      );
      expect(weeks.last.days.last.day, DateTime(2026, 10, 25));
      expect(weeks.last.days.last.future, isFalse);
    });

    test('跨月的周不会被截断（月末最后一天仍在同一列）', () {
      final DateTime today = DateTime(2026, 11, 2); // 周一
      final List<HeatWeek> weeks = buildHeatWeeks(
        today: today,
        stats: const <String, DayStat>{},
      );
      final HeatWeek last = weeks.last;
      expect(last.days.first.day, DateTime(2026, 11, 2));
      // 上一列 10/26 – 11/1 横跨 10 月与 11 月，但必须是一整列。
      expect(weeks[weeks.length - 2].days.first.day, DateTime(2026, 10, 26));
      expect(weeks[weeks.length - 2].days.last.day, DateTime(2026, 11, 1));
    });

    test('未来格子标 future 且不计数', () {
      // 周三 → 本周还剩周四~周日四格是"未来"。
      final DateTime today = DateTime(2026, 10, 21);
      final List<HeatWeek> weeks = buildHeatWeeks(
        today: today,
        stats: <String, DayStat>{
          '2026-10-22': const DayStat(questions: 9, workbooks: 1),
        },
      );
      final HeatCell thursday = weeks.last.days[3]; // 10/22 周四
      expect(thursday.future, isTrue);
      expect(thursday.count, 0, reason: '未来的日子即使有脏数据也不画');
      expect(thursday.level, 0);
      expect(weeks.last.days[2].future, isFalse); // 今天（周三）
    });

    test('有记录的日子按档位着色', () {
      final DateTime today = DateTime(2026, 10, 25);
      final List<HeatWeek> weeks = buildHeatWeeks(
        today: today,
        stats: <String, DayStat>{
          '2026-10-24': const DayStat(questions: 7, workbooks: 2),
          '2026-10-23': const DayStat(questions: 1, workbooks: 1),
        },
      );
      final List<HeatCell> last = weeks.last.days;
      expect(last[5].count, 7); // 10/24 周六
      expect(last[5].level, 3);
      expect(last[4].count, 1); // 10/23 周五
      expect(last[4].level, 1);
    });
  });

  group('连续打卡', () {
    Map<String, DayStat> days(List<String> keys) => <String, DayStat>{
      for (final String key in keys) key: const DayStat(questions: 1, workbooks: 1),
    };

    test('今天与昨天都做过 → 2', () {
      expect(
        currentStreak(
          days(<String>['2026-10-25', '2026-10-24']),
          today: DateTime(2026, 10, 25),
        ),
        2,
      );
    });

    test('今天还没做、昨天做了 → 不从 0 开始（昨天的连续仍算）', () {
      expect(
        currentStreak(
          days(<String>['2026-10-24', '2026-10-23']),
          today: DateTime(2026, 10, 25),
        ),
        2,
      );
    });

    test('中间断一天就停', () {
      expect(
        currentStreak(
          days(<String>['2026-10-25', '2026-10-23', '2026-10-22']),
          today: DateTime(2026, 10, 25),
        ),
        1,
      );
    });

    test('跨月连续', () {
      expect(
        currentStreak(
          days(<String>['2026-11-01', '2026-10-31', '2026-10-30']),
          today: DateTime(2026, 11, 1),
        ),
        3,
      );
    });

    test('完全没有记录 → 0', () {
      expect(
        currentStreak(const <String, DayStat>{}, today: DateTime(2026, 10, 25)),
        0,
      );
    });
  });

  group('周期统计', () {
    AnswerLogEntry entry(
      String day,
      String question, {
      String workbook = 'wb1',
      AnswerVerdict verdict = AnswerVerdict.none,
    }) => AnswerLogEntry(
      at: DateTime(2026, 10, 25).millisecondsSinceEpoch,
      day: day,
      workbookId: workbook,
      questionId: question,
      verdict: verdict,
    );

    test('题数按题去重、卷数按卷去重，判定分桶', () {
      final PeriodStats stats = summarize(
        <AnswerLogEntry>[
          entry('2026-10-25', 'q1', verdict: AnswerVerdict.correct),
          entry('2026-10-25', 'q2', verdict: AnswerVerdict.wrong),
          entry('2026-10-24', 'q3', workbook: 'wb2'),
          entry('2026-10-20', 'q4', verdict: AnswerVerdict.pending),
          // 窗口外
          entry('2026-09-01', 'q5'),
        ],
        from: DateTime(2026, 10, 20),
        to: DateTime(2026, 10, 25),
      );
      expect(stats.questions, 4);
      expect(stats.workbooks, 2);
      expect(stats.days, 3);
      expect(stats.correct, 1);
      expect(stats.wrong, 1);
      expect(stats.pending, 1);
      expect(stats.none, 1);
      expect(stats.accuracy, 0.5);
    });

    test('没判过任何题时正确率是 null（不是 0%）', () {
      final PeriodStats stats = summarize(
        <AnswerLogEntry>[entry('2026-10-25', 'q1')],
        from: DateTime(2026, 10, 25),
        to: DateTime(2026, 10, 25),
      );
      expect(stats.accuracy, isNull);
      expect(stats.verdictFractions, <double>[0, 0, 0, 1]);
    });

    test('空数据', () {
      final PeriodStats stats = summarize(
        const <AnswerLogEntry>[],
        from: DateTime(2026, 10, 25),
        to: DateTime(2026, 10, 25),
      );
      expect(stats.isEmpty, isTrue);
      expect(stats.verdictFractions, <double>[0, 0, 0, 0]);
    });
  });

  group('按天聚合', () {
    test('同一天同题只有一条，卷数按卷去重', () {
      final Map<String, DayStat> byDay = aggregateByDay(<AnswerLogEntry>[
        const AnswerLogEntry(
          at: 1,
          day: '2026-10-25',
          workbookId: 'wb1',
          questionId: 'q1',
        ),
        const AnswerLogEntry(
          at: 2,
          day: '2026-10-25',
          workbookId: 'wb1',
          questionId: 'q1',
        ),
        const AnswerLogEntry(
          at: 3,
          day: '2026-10-25',
          workbookId: 'wb2',
          questionId: 'q2',
        ),
      ]);
      expect(byDay['2026-10-25']!.questions, 2);
      expect(byDay['2026-10-25']!.workbooks, 2);
    });
  });

  group('词云', () {
    test('权重 = 题数 × 1 + 卷数 × 3，同名词合并', () {
      final List<CloudWord> words = buildCloudWords(<CloudBucket>[
        const CloudBucket(label: '数学', questions: 5, workbooks: 1),
        const CloudBucket(label: '数学', questions: 2, workbooks: 1),
        const CloudBucket(label: '英语', questions: 3, workbooks: 3),
      ]);
      expect(words.length, 2);
      expect(words.first.label, '数学');
      expect(words.first.questions, 7);
      expect(words.first.workbooks, 2);
      expect(words.first.weight, 7 + 6);
      expect(words.last.weight, 3 + 9);
      // 数学 13 > 英语 12，排序正确。
      expect(words.first.weight, greaterThan(words.last.weight));
    });

    test('同权重按题数、再按名字排（布局稳定）', () {
      final List<CloudWord> words = buildCloudWords(<CloudBucket>[
        const CloudBucket(label: 'B', questions: 2, workbooks: 1),
        const CloudBucket(label: 'A', questions: 3, workbooks: 1),
        const CloudBucket(label: 'C', questions: 3, workbooks: 1),
      ]);
      expect(words.map((CloudWord w) => w.label).toList(), <String>['A', 'C', 'B']);
    });

    test('去空白与丢弃空名', () {
      final List<CloudWord> words = buildCloudWords(<CloudBucket>[
        const CloudBucket(label: '  物理 ', questions: 1, workbooks: 1),
        const CloudBucket(label: '   ', questions: 9, workbooks: 9),
      ]);
      expect(words.length, 1);
      expect(words.first.label, '物理');
    });

    test('字号按开方归一，落在 [min, max]', () {
      expect(cloudFontSize(0, maxWeight: 10), 12);
      expect(cloudFontSize(10, maxWeight: 10), 30);
      final double half = cloudFontSize(2.5, maxWeight: 10);
      expect(half, closeTo(12 + 18 * 0.5, 0.001));
      expect(cloudFontSize(100, maxWeight: 10), 30);
    });
  });

  group('时间线分组', () {
    AnswerLogEntry entry(
      String day,
      int at,
      String qid, {
      String workbook = 'wb1',
      String title = '线性代数',
      AnswerVerdict verdict = AnswerVerdict.none,
    }) => AnswerLogEntry(
      at: at,
      day: day,
      workbookId: workbook,
      workbookTitle: title,
      questionId: qid,
      label: qid,
      verdict: verdict,
    );

    test('按天倒序、天内按卷分组、条目按时间倒序', () {
      final List<TimelineDay> days = groupTimeline(
        <AnswerLogEntry>[
          entry('2026-10-25', 300, 'q3', workbook: 'wb2', title: '数学分析'),
          entry('2026-10-25', 200, 'q2'),
          entry('2026-10-25', 100, 'q1'),
          entry('2026-10-24', 50, 'q0'),
        ],
        existingWorkbookIds: <String>{'wb1', 'wb2'},
      );
      expect(days.length, 2);
      expect(days.first.questions, 3);
      expect(days.first.workbooks.length, 2);
      expect(days.first.workbooks.first.title, '数学分析', reason: '最新动作的卷在前');
      expect(
        days.first.workbooks.last.entries.map((AnswerLogEntry e) => e.questionId),
        <String>['q2', 'q1'],
      );
    });

    test('活库卷名优先，卷删了用快照并标记', () {
      final List<TimelineDay> days = groupTimeline(
        <AnswerLogEntry>[
          entry('2026-10-25', 100, 'q1', title: '旧卷名'),
          entry('2026-10-25', 90, 'q2', workbook: 'wb2', title: '已删的卷'),
        ],
        existingWorkbookIds: <String>{'wb1'},
        liveTitles: <String, String>{'wb1': '新卷名'},
      );
      final TimelineWorkbook first = days.first.workbooks.first;
      expect(first.title, '新卷名');
      expect(first.sourceDeleted, isFalse);
      final TimelineWorkbook second = days.first.workbooks.last;
      expect(second.sourceDeleted, isTrue);
      expect(second.title, '已删的卷');
    });

    test('判定色带按题计数', () {
      final List<TimelineDay> days = groupTimeline(
        <AnswerLogEntry>[
          entry('2026-10-25', 3, 'q1', verdict: AnswerVerdict.correct),
          entry('2026-10-25', 2, 'q2', verdict: AnswerVerdict.wrong),
          entry('2026-10-25', 1, 'q3', verdict: AnswerVerdict.pending),
        ],
        existingWorkbookIds: <String>{'wb1'},
      );
      expect(days.first.countOf(AnswerVerdict.correct), 1);
      expect(days.first.countOf(AnswerVerdict.wrong), 1);
      expect(days.first.countOf(AnswerVerdict.pending), 1);
    });
  });

  group('日期口径', () {
    test('dayKey 是本地日期，补零', () {
      expect(RecordTime.dayKey(DateTime(2026, 1, 5, 23, 59)), '2026-01-05');
      expect(RecordTime.parseDayKey('2026-01-05'), DateTime(2026, 1, 5));
      expect(RecordTime.parseDayKey('坏数据'), DateTime(1970));
    });

    test('加天数走日历（跨月/跨年正确）', () {
      expect(RecordTime.addDays(DateTime(2026, 10, 31), 1), DateTime(2026, 11, 1));
      expect(RecordTime.addDays(DateTime(2026, 1, 1), -1), DateTime(2025, 12, 31));
    });

    test('周一起算', () {
      expect(RecordTime.mondayOf(DateTime(2026, 10, 25)), DateTime(2026, 10, 19));
      expect(RecordTime.mondayOf(DateTime(2026, 10, 19)), DateTime(2026, 10, 19));
    });

    test('中文文案', () {
      expect(RecordTime.monthDayWeekday(DateTime(2026, 10, 25)), '10月25日 周日');
      expect(
        RecordTime.relativeDay(DateTime(2026, 10, 25), today: DateTime(2026, 10, 25)),
        '今天',
      );
      expect(
        RecordTime.relativeDay(DateTime(2026, 10, 24), today: DateTime(2026, 10, 25)),
        '昨天',
      );
      expect(
        RecordTime.relativeDay(DateTime(2026, 10, 23), today: DateTime(2026, 10, 25)),
        '前天',
      );
      expect(
        RecordTime.relativeDay(DateTime(2026, 10, 18), today: DateTime(2026, 10, 25)),
        '10月18日',
      );
      expect(RecordTime.clock(DateTime(2026, 10, 25, 9, 5)), '09:05');
    });
  });

  group('记录模型', () {
    test('行 ↔ 值对象往返', () {
      const AnswerLogEntry entry = AnswerLogEntry(
        at: 1792925792565,
        day: '2026-10-25',
        workbookId: 'wb1',
        workbookTitle: '线性代数',
        questionId: 'q1',
        label: '5',
        kind: 'choice',
        pageIndex: 2,
        source: RecordSource.grade,
        verdict: AnswerVerdict.wrong,
        hits: 3,
      );
      final AnswerLogEntry round = AnswerLogEntry.fromRow(
        <String, Object?>{
          'id': 7,
          ...entry.toRow(),
        },
      );
      expect(round.id, 7);
      expect(round.day, '2026-10-25');
      expect(round.source, RecordSource.grade);
      expect(round.verdict, AnswerVerdict.wrong);
      expect(round.hits, 3);
      expect(round.pageIndex, 2);
      expect(round.localTime.millisecondsSinceEpoch, entry.at);
    });

    test('动作角标文案', () {
      expect(RecordSource.ink.label, '作答');
      expect(RecordSource.grade.label, '判题');
      expect(RecordSource.decode('redo'), RecordSource.redo);
      expect(RecordSource.decode('不存在'), RecordSource.ink);
    });
  });
}
