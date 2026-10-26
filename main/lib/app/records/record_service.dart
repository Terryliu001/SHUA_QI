import 'package:flutter/foundation.dart';
import 'package:shuaqi/domain/model/grading.dart';
import 'package:shuaqi/domain/records/answer_log.dart';
import 'package:shuaqi/domain/records/record_time.dart';
import 'package:shuaqi/infra/db/app_database.dart';
import 'package:shuaqi/infra/db/dao/answer_log_dao.dart';

/// 作答记录的写入契约。
///
/// 抽接口是为了让"落笔即记录"这条链路能被单测钉住：宿主测试里没有 sqflite，
/// 用假实现替换 `recordServiceProvider`，就能验证"写了字才记、同题同天只记一次"。
abstract interface class AnswerRecorder {
  Future<void> touch({
    required String workbookId,
    required String questionId,
    RecordSource source = RecordSource.ink,
    AnswerVerdict verdict = AnswerVerdict.none,
    int? at,
    String? workbookTitle,
    RecordOrigin origin = RecordOrigin.workbook,
    String? originTitle,
    String attemptId = '',
    String favoriteId = '',
  });

  Future<void> syncVerdict({
    required String workbookId,
    required String questionId,
    required AnswerVerdict verdict,
  });

  Future<void> seed({
    required String workbookId,
    required String questionId,
    required int at,
    RecordSource source = RecordSource.backfill,
    AnswerVerdict verdict = AnswerVerdict.none,
  });

  Future<void> renameWorkbook(String workbookId, String title);

  void forgetWorkbook(String workbookId);
}

/// 作答记录的写入口（阶段 9）。
///
/// ## 为什么是"服务"而不是在每个页面里写 SQL
/// 打点位置有 4 处（答题卡、判题、收藏、重刷），每处都只该说一句
/// "这题答过了 / 这题判了"，不该各自去查卷名题号、算本地日期、处理并发。
/// 这里把这些收敛成 [touch] 与 [syncVerdict]。
///
/// ## 失败绝不冒泡
/// 记录是**旁路**：写不进去不能影响用户落笔和判题。所有异常吞掉并 debugPrint。
class RecordService implements AnswerRecorder {
  RecordService({
    required this.db,
    this.onChanged,
    this.now,
  });

  final AppDatabase db;

  /// 记录变动通知（state 层接到 revision notifier，记录页据此刷新）。
  final void Function()? onChanged;

  /// 测试注入用；null = 系统时钟。
  final DateTime Function()? now;

  /// 卷名缓存（卷改名时由 [forgetWorkbook] 失效）。
  final Map<String, String> _titles = <String, String>{};

  /// 题目元信息缓存：`questionId → (label, kind, pageIndex)`。
  final Map<String, ({String label, String kind, int pageIndex})> _questions =
      <String, ({String label, String kind, int pageIndex})>{};

  /// 记一笔"这题做过 / 判过"。
  ///
  /// [at] 缺省用当前时间；回填时传入文件里的真实时间。
  @override
  Future<void> touch({
    required String workbookId,
    required String questionId,
    RecordSource source = RecordSource.ink,
    AnswerVerdict verdict = AnswerVerdict.none,
    int? at,
    String? workbookTitle,
    RecordOrigin origin = RecordOrigin.workbook,
    String? originTitle,
    String attemptId = '',
    String favoriteId = '',
  }) async {
    if (workbookId.isEmpty || questionId.isEmpty) {
      return;
    }
    try {
      final int stamp = at ?? (now?.call() ?? DateTime.now()).millisecondsSinceEpoch;
      final DateTime local = DateTime.fromMillisecondsSinceEpoch(stamp);
      final ({String label, String kind, int pageIndex}) meta =
          await _questionMeta(questionId);
      final AnswerLogEntry entry = AnswerLogEntry(
        at: stamp,
        day: RecordTime.dayKey(local),
        workbookId: workbookId,
        workbookTitle:
            workbookTitle ?? await _workbookTitle(workbookId),
        questionId: questionId,
        label: meta.label,
        kind: meta.kind,
        pageIndex: meta.pageIndex,
        source: source,
        verdict: verdict,
        origin: origin,
        originTitle: originTitle ?? '',
        attemptId: attemptId,
        favoriteId: favoriteId,
      );
      await AnswerLogDao(db.raw).touch(entry);
      onChanged?.call();
    } on Object catch (error) {
      debugPrint('作答记录写入失败（忽略）：$error');
    }
  }

  /// 判题结论同步：把这道题的历史记录一起改色。
  @override
  Future<void> syncVerdict({
    required String workbookId,
    required String questionId,
    required AnswerVerdict verdict,
  }) async {
    if (questionId.isEmpty) {
      return;
    }
    try {
      await AnswerLogDao(db.raw).syncVerdict(questionId, verdict);
      onChanged?.call();
    } on Object catch (error) {
      debugPrint('判题结论同步失败（忽略）：$error');
    }
  }

  /// 历史回填专用：只在缺失时写入，已有则"取更晚的时间 + 更完整的结论"。
  /// 不累加 `hits`（回填不是"又做了一遍"）。
  @override
  Future<void> seed({
    required String workbookId,
    required String questionId,
    required int at,
    RecordSource source = RecordSource.backfill,
    AnswerVerdict verdict = AnswerVerdict.none,
  }) async {
    if (workbookId.isEmpty || questionId.isEmpty || at <= 0) {
      return;
    }
    try {
      final DateTime local = DateTime.fromMillisecondsSinceEpoch(at);
      final ({String label, String kind, int pageIndex}) meta =
          await _questionMeta(questionId);
      await AnswerLogDao(db.raw).seed(
        AnswerLogEntry(
          at: at,
          day: RecordTime.dayKey(local),
          workbookId: workbookId,
          workbookTitle: await _workbookTitle(workbookId),
          questionId: questionId,
          label: meta.label,
          kind: meta.kind,
          pageIndex: meta.pageIndex,
          source: source,
          verdict: verdict,
        ),
      );
    } on Object catch (error) {
      debugPrint('作答记录回填失败（忽略）：$error');
    }
  }

  /// 卷改名后调用：快照里的旧卷名一起换掉（活库读不到时才用快照）。
  @override
  Future<void> renameWorkbook(String workbookId, String title) async {
    if (workbookId.isEmpty) {
      return;
    }
    _titles[workbookId] = title;
    try {
      await AnswerLogDao(db.raw).syncWorkbookTitle(workbookId, title);
      onChanged?.call();
    } on Object catch (error) {
      debugPrint('卷名同步失败（忽略）：$error');
    }
  }

  /// 卷被删除：清掉缓存即可，**记录本身保留**（这正是独立记录的意义）。
  @override
  void forgetWorkbook(String workbookId) => _titles.remove(workbookId);

  Future<String> _workbookTitle(String workbookId) async {
    final String? cached = _titles[workbookId];
    if (cached != null) {
      return cached;
    }
    String title = '';
    try {
      final List<Map<String, Object?>> rows = await db.raw.query(
        'workbook',
        columns: <String>['title'],
        where: 'id = ?',
        whereArgs: <Object?>[workbookId],
        limit: 1,
      );
      if (rows.isNotEmpty) {
        title = (rows.first['title'] as String?) ?? '';
      }
    } on Object {
      title = '';
    }
    _titles[workbookId] = title;
    return title;
  }

  Future<({String label, String kind, int pageIndex})> _questionMeta(
    String questionId,
  ) async {
    final ({String label, String kind, int pageIndex})? cached =
        _questions[questionId];
    if (cached != null) {
      return cached;
    }
    String label = '';
    String kind = 'unknown';
    int pageIndex = 0;
    try {
      final List<Map<String, Object?>> rows = await db.raw.query(
        'question',
        columns: <String>['label', 'kind', 'ordinal'],
        where: 'id = ?',
        whereArgs: <Object?>[questionId],
        limit: 1,
      );
      if (rows.isNotEmpty) {
        label = (rows.first['label'] as String?) ?? '';
        kind = (rows.first['kind'] as String?) ?? 'unknown';
        if (label.isEmpty) {
          label = '${(rows.first['ordinal'] as num?)?.toInt() ?? 0}';
        }
      }
      final List<Map<String, Object?>> pageRows = await db.raw.rawQuery(
        'SELECT p.idx AS idx FROM question_region r '
        'JOIN wb_page p ON p.id = r.page_id '
        'WHERE r.question_id = ? ORDER BY p.idx ASC LIMIT 1',
        <Object?>[questionId],
      );
      if (pageRows.isNotEmpty) {
        pageIndex = (pageRows.first['idx'] as num?)?.toInt() ?? 0;
      }
    } on Object {
      // 题被重切掉了：保持空标签，记录仍成立。
    }
    final ({String label, String kind, int pageIndex}) meta = (
      label: label,
      kind: kind,
      pageIndex: pageIndex,
    );
    _questions[questionId] = meta;
    return meta;
  }
}
