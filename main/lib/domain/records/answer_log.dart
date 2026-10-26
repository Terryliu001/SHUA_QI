/// 一条「作答记录」（纯 Dart）。
///
/// ## 为什么单独建表，而不是从 `session` / `grading` 反推
/// 试过，反推不出来：
/// - `session` 每卷只有一条 draft（一次打开一条，重开不会新增），拿不到"哪天做了几题"；
/// - `grading.v1.json` 的 `at` 是**整批改卷**的时间戳（一键改卷会给几十道题写同一个毫秒），
///   把它当"作答时间"会造出"一天做 40 题"的假数据；
/// - `answer_sheet.v1.json` 的 `updated_at` 只覆盖"调过作答框/识别过"的题。
///
/// 所以记录必须是**事件**：谁在哪个时刻、对哪道题、因为什么动作被记了一笔。
///
/// ## 为什么字段是快照，而不是外键
/// 与收藏夹同一条理由（054）：`question` / `workbook` 会随卷 CASCADE 删除，
/// 而"我 10 月 24 日做过 5 道题"这件事不该因为删卷而消失。所以本表**不设外键**，
/// 卷名/题号/题型都在写入那一刻抄一份；显示时优先用活库里的最新值（卷改名能同步），
/// 卷没了才回落到快照，并标「原卷已删」。
library;

import 'package:shuaqi/domain/ink/ink_session_id.dart';
import 'package:shuaqi/domain/model/grading.dart';
import 'package:shuaqi/domain/records/record_time.dart';

/// 触发记录的动作。同一天同一题只有一行，`source` 记**最近一次**动作。
///
/// 为什么要分这么细：用户口径是"保存、有笔迹更新、判题都算"，
/// 但热力图/时间线数的是**题目数**，不是动作数——动作次数记在 [AnswerLogEntry.hits]。
enum RecordSource {
  /// 答题卡里落笔（500ms 防抖落盘或离开该题时触发）。
  ink,

  /// 主动点「保存」。
  save,

  /// 判题出结论（三色手改 / 一键改卷 / AI 判）。
  grade,

  /// 收藏重刷页落笔。
  redo,

  /// 收藏这道题（顺带把"练过"记下来）。
  favorite,

  /// 历史数据回填（一次性）。
  backfill;

  static RecordSource decode(String? raw) {
    for (final RecordSource value in values) {
      if (value.name == raw) {
        return value;
      }
    }
    return ink;
  }

  /// 卡片上的角标文案（短，不占视觉）。
  String get label => switch (this) {
    RecordSource.ink => '作答',
    RecordSource.save => '保存',
    RecordSource.grade => '判题',
    RecordSource.redo => '重刷',
    RecordSource.favorite => '收藏',
    RecordSource.backfill => '记录',
  };
}

/// 这笔记录发生在**哪种场景**（2026-10-26，DB v8 新增列 `origin`）。
///
/// 为什么和 [RecordSource] 分开两个维度：
/// - [RecordSource] 记"因为什么动作"（落笔 / 保存 / 判题 / 重刷）；
/// - [RecordOrigin] 记"在哪儿做的"（原卷 / 组卷 / 单题重刷）。
///
/// 用户口径："重刷的记录要考虑多次重刷…组卷中重刷的可以标记下组卷名与时间"，
/// 所以"在哪儿做的"必须能单独查——同一道题当天在原卷做一次、在组卷再刷一次，
/// 记成**两行**（唯一索引含 origin）。
enum RecordOrigin {
  /// 在原卷里做的（答题卡、页内书写）。
  workbook,

  /// 在**组卷**里重刷（origin_title = 组卷名）。
  set,

  /// 单题重刷（收藏夹里点「重刷」）。
  redo;

  static RecordOrigin decode(String? raw) {
    for (final RecordOrigin value in values) {
      if (value.name == raw) {
        return value;
      }
    }
    return workbook;
  }

  /// 时间线卡片上的角标。
  String get label => switch (this) {
    RecordOrigin.workbook => '原卷',
    RecordOrigin.set => '组卷',
    RecordOrigin.redo => '重刷',
  };

  /// 这条记录是不是"又刷了一遍"（时间线里默认折叠的那类）。
  bool get isRedo => this != RecordOrigin.workbook;
}

/// 一条作答记录。
class AnswerLogEntry {
  const AnswerLogEntry({
    this.id,
    required this.at,
    required this.day,
    required this.workbookId,
    required this.questionId,
    this.workbookTitle = '',
    this.label = '',
    this.kind = 'unknown',
    this.pageIndex = 0,
    this.source = RecordSource.ink,
    this.verdict = AnswerVerdict.none,
    this.hits = 1,
    this.origin = RecordOrigin.workbook,
    this.originTitle = '',
  });

  factory AnswerLogEntry.fromRow(Map<String, Object?> row) => AnswerLogEntry(
    id: (row['id'] as num?)?.toInt(),
    at: (row['at']! as num).toInt(),
    day: (row['day'] as String?) ?? '',
    workbookId: (row['workbook_id'] as String?) ?? '',
    workbookTitle: (row['workbook_title'] as String?) ?? '',
    questionId: (row['question_id'] as String?) ?? '',
    label: (row['label'] as String?) ?? '',
    kind: (row['kind'] as String?) ?? 'unknown',
    pageIndex: (row['page_index'] as num?)?.toInt() ?? 0,
    source: RecordSource.decode(row['source'] as String?),
    verdict: AnswerVerdict.decode(row['verdict'] as String?),
    hits: (row['hits'] as num?)?.toInt() ?? 1,
    origin: RecordOrigin.decode(row['origin'] as String?),
    originTitle: (row['origin_title'] as String?) ?? '',
  );

  /// 自增主键；插入前为 null。
  final int? id;

  /// UTC 毫秒（最近一次动作）。
  final int at;

  /// **本地**日期 key `yyyy-MM-dd`。热力图/时间线按它分桶，
  /// 不按 UTC 分桶——否则晚上 8 点以后做的题会掉到第二天。
  final String day;

  final String workbookId;
  final String questionId;

  /// 卷名快照（卷删后仍能显示；卷在时优先用活库的名字）。
  final String workbookTitle;

  /// 题号原文快照（`12.` `（3）`）。
  final String label;

  /// `choice` / `judge` / `blank` / `essay` / `unknown`。
  final String kind;

  /// 题面所在页（0-based），回原卷定位时的兜底。
  final int pageIndex;

  /// 最近一次触发动作。
  final RecordSource source;

  /// 最近一次判定（写记录时的快照；判题变化时由 DAO 同步刷新）。
  final AnswerVerdict verdict;

  /// 同一天这道题被记了几次（笔迹保存 + 判题 = 2）。
  final int hits;

  /// 在哪儿做的（v8 新增）。默认 `workbook` = 原卷。
  final RecordOrigin origin;

  /// 组卷名（只有 [RecordOrigin.set] 有值）。
  final String originTitle;

  /// 这道题被记过的时间（本地）。
  DateTime get localTime => DateTime.fromMillisecondsSinceEpoch(at);

  AnswerLogEntry copyWith({
    int? at,
    String? day,
    String? workbookTitle,
    String? label,
    String? kind,
    int? pageIndex,
    RecordSource? source,
    AnswerVerdict? verdict,
    int? hits,
    RecordOrigin? origin,
    String? originTitle,
  }) => AnswerLogEntry(
    id: id,
    at: at ?? this.at,
    day: day ?? this.day,
    workbookId: workbookId,
    questionId: questionId,
    workbookTitle: workbookTitle ?? this.workbookTitle,
    label: label ?? this.label,
    kind: kind ?? this.kind,
    pageIndex: pageIndex ?? this.pageIndex,
    source: source ?? this.source,
    verdict: verdict ?? this.verdict,
    hits: hits ?? this.hits,
    origin: origin ?? this.origin,
    originTitle: originTitle ?? this.originTitle,
  );

  /// 插入用（不含自增主键）。
  Map<String, Object?> toRow() => <String, Object?>{
    'at': at,
    'day': day,
    'workbook_id': workbookId,
    'workbook_title': workbookTitle,
    'question_id': questionId,
    'label': label,
    'kind': kind,
    'page_index': pageIndex,
    'source': source.name,
    'verdict': verdict.name,
    'hits': hits,
    'origin': origin.name,
    'origin_title': originTitle,
  };

  @override
  String toString() =>
      'AnswerLogEntry($day #$label $source ${verdict.name} x$hits)';
}

/// 这一笔算不算"某道题的作答"？返回题目 id，`null` = 不算。
///
/// 三条判定（顺序即短路顺序）：
/// 1. 没有卷 id（宿主测试里的裸编辑器）→ 不算；
/// 2. 一笔没有（清空/新画布）→ 不算；
/// 3. session 不是答题卡格式（PDF 页笔迹）→ 不算，因为页上的墨迹不归属某道题。
String? answerQuestionIdOf({
  required String sessionId,
  required String workbookId,
  required int strokeCount,
}) {
  if (workbookId.isEmpty || strokeCount <= 0) {
    return null;
  }
  return parseAnswerInkSession(sessionId)?.questionId;
}

/// 作答记录的去重键：同一天同一题、同一来源只写一次库。
///
/// 用字符串而不是元组：Riverpod/Map 的键要能打印、能进日志。
/// [origin] 进键是 DB v8 的要求：**同一天同一题，原卷做一次、组卷再刷一次，算两次**。
String answerRecordKeyOf(
  String questionId,
  int atMillis, {
  RecordOrigin origin = RecordOrigin.workbook,
}) => '$questionId|${RecordTime.dayKey(
  DateTime.fromMillisecondsSinceEpoch(atMillis),
)}|${origin.name}';
