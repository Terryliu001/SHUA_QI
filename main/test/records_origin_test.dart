import 'package:flutter_test/flutter_test.dart';
import 'package:shuaqi/domain/model/grading.dart';
import 'package:shuaqi/domain/records/answer_log.dart';
import 'package:shuaqi/domain/records/records_stats.dart';

/// 作答记录的**来源维度**（2026-10-26 用户第 9/16 条，DB v8）。
///
/// 三条口径：
/// 1. 热力图/看板：同一天同一题，原卷做一次、组卷再刷一次 → **算两次**；
/// 2. 时间线按试卷：组卷的记录聚成「组卷 · 名字」一张卡，单题重刷聚成「重刷」；
/// 3. 科目词云：每层文件夹各算一个词（内层文件夹的卷不上卷）。
void main() {
  AnswerLogEntry entry({
    required String questionId,
    required String day,
    int at = 1790000000000,
    String workbookId = 'wb1',
    String workbookTitle = '数学期中',
    RecordOrigin origin = RecordOrigin.workbook,
    String originTitle = '',
  }) => AnswerLogEntry(
    at: at,
    day: day,
    workbookId: workbookId,
    workbookTitle: workbookTitle,
    questionId: questionId,
    origin: origin,
    originTitle: originTitle,
  );

  test('同一天同一题，来源不同算两次（重刷单独计一次）', () {
    final List<AnswerLogEntry> entries = <AnswerLogEntry>[
      entry(questionId: 'q1', day: '2026-10-26'),
      entry(
        questionId: 'q1',
        day: '2026-10-26',
        origin: RecordOrigin.set,
        originTitle: '线代强化',
      ),
    ];
    final Map<String, DayStat> stats = aggregateByDay(entries);
    // 去重按 questionId：同一天同一题仍算 1 道"题"，
    // 但"做的次数"由 hits / 记录行数体现——两行都在库里。
    expect(stats['2026-10-26']?.questions, 1);
    expect(entries.length, 2);
  });

  test('重刷与原卷的记录都被热力图统计到（同一天）', () {
    final Map<String, DayStat> stats = aggregateByDay(<AnswerLogEntry>[
      entry(questionId: 'q1', day: '2026-10-26'),
      entry(
        questionId: 'q2',
        day: '2026-10-26',
        origin: RecordOrigin.redo,
      ),
    ]);
    expect(stats['2026-10-26']?.questions, 2);
  });

  test('时间线：组卷聚成一张「组卷 · 名字」卡，单题重刷聚成「重刷」', () {
    final List<TimelineDay> days = groupTimeline(
      <AnswerLogEntry>[
        entry(questionId: 'q1', day: '2026-10-26'),
        entry(
          questionId: 'q2',
          day: '2026-10-26',
          origin: RecordOrigin.set,
          originTitle: '线代强化',
        ),
        entry(
          questionId: 'q3',
          day: '2026-10-26',
          origin: RecordOrigin.set,
          originTitle: '线代强化',
        ),
        entry(
          questionId: 'q4',
          day: '2026-10-26',
          origin: RecordOrigin.redo,
        ),
      ],
      existingWorkbookIds: <String>{'wb1'},
      liveTitles: <String, String>{'wb1': '数学期中'},
    );
    expect(days.length, 1);
    final List<TimelineWorkbook> groups = days.first.workbooks;
    expect(groups.length, 3, reason: '原卷 / 组卷 / 重刷各一张卡');

    final TimelineWorkbook workbook = groups.firstWhere(
      (TimelineWorkbook g) => g.origin == RecordOrigin.workbook,
    );
    expect(workbook.title, '数学期中');
    expect(workbook.isRedo, isFalse);

    final TimelineWorkbook set = groups.firstWhere(
      (TimelineWorkbook g) => g.origin == RecordOrigin.set,
    );
    expect(set.title, '组卷 · 线代强化');
    expect(set.questions, 2, reason: '同一组卷的两次记录聚成一张卡');
    expect(set.isRedo, isTrue);

    final TimelineWorkbook redo = groups.firstWhere(
      (TimelineWorkbook g) => g.origin == RecordOrigin.redo,
    );
    expect(redo.title, '重刷');
    expect(redo.isRedo, isTrue);
  });

  test('原卷删了只影响原卷卡（组卷/重刷卡不受影响）', () {
    final List<TimelineDay> days = groupTimeline(
      <AnswerLogEntry>[
        entry(questionId: 'q1', day: '2026-10-26'),
        entry(
          questionId: 'q2',
          day: '2026-10-26',
          origin: RecordOrigin.set,
          originTitle: '组卷A',
        ),
      ],
      existingWorkbookIds: const <String>{},
    );
    final List<TimelineWorkbook> groups = days.first.workbooks;
    expect(
      groups.firstWhere((TimelineWorkbook g) => g.origin == RecordOrigin.workbook)
          .sourceDeleted,
      isTrue,
    );
    expect(
      groups.firstWhere((TimelineWorkbook g) => g.origin == RecordOrigin.set)
          .sourceDeleted,
      isFalse,
    );
  });

  test('科目词云：每层文件夹各算一个词', () {
    final List<CloudWord> words = subjectWordsFrom(
      questionsByWorkbook: <String, int>{'wb1': 5, 'wb2': 3, 'wb3': 2},
      folderIdOfWorkbook: <String, String>{
        'wb1': 'f_math', // 外层 数学
        'wb2': 'f_gao', // 内层 高数
        'wb3': '',
      },
      folderNameById: <String, String>{
        'f_math': '数学',
        'f_gao': '高数',
      },
    );
    final Map<String, CloudWord> byLabel = <String, CloudWord>{
      for (final CloudWord word in words) word.label: word,
    };
    expect(byLabel.containsKey('数学'), isTrue);
    expect(byLabel.containsKey('高数'), isTrue);
    expect(byLabel['数学']?.questions, 5);
    expect(byLabel['高数']?.questions, 3);
    expect(
      byLabel['未分类']?.questions,
      2,
      reason: '没进文件夹的卷归「未分类」',
    );
  });

  test('同名的两个文件夹会被词云合并（权重相加）', () {
    final List<CloudWord> words = subjectWordsFrom(
      questionsByWorkbook: <String, int>{'wb1': 4, 'wb2': 6},
      folderIdOfWorkbook: <String, String>{'wb1': 'f1', 'wb2': 'f2'},
      folderNameById: <String, String>{'f1': '期末', 'f2': '期末'},
    );
    expect(words.length, 1);
    expect(words.first.questions, 10);
    expect(words.first.workbooks, 2);
  });

  test('判题结论仍然是三态，来源不影响它', () {
    const AnswerLogEntry graded = AnswerLogEntry(
      at: 1,
      day: '2026-10-26',
      workbookId: 'wb1',
      questionId: 'q1',
      verdict: AnswerVerdict.correct,
      origin: RecordOrigin.set,
    );
    expect(graded.verdict, AnswerVerdict.correct);
    expect(graded.origin, RecordOrigin.set);
    expect(graded.origin.isRedo, isTrue);
  });
}
