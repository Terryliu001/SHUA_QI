import 'package:shuaqi/domain/model/grading.dart';
import 'package:shuaqi/domain/records/answer_log.dart';
import 'package:shuaqi/domain/records/records_stats.dart';
import 'package:sqflite/sqflite.dart';

/// `answer_log`（v7）的读写：作答记录。
///
/// 三条口径（写在这里，调用方不用再猜）：
/// 1. **一天一题一行**：唯一索引 `(question_id, day)`。热力图与时间线数的是
///    "今天做了几道题"，不是"今天点了多少次保存"；动作次数累加在 `hits`。
/// 2. **不 join 卷/题表**：卷删了记录仍在（快照字段兜底），列表只读本表。
/// 3. **判题只改结论、不改时间**：三色手改会把历史行的 `verdict` 一起刷新
///    （否则时间线里的色带与判题结果对不上），但 `at` 保持"作答发生的时间"。
class AnswerLogDao {
  const AnswerLogDao(this._db);

  /// 一律传 `Database`（DAO 内部要 upsert 式的"插不进去就更新"）。
  final DatabaseExecutor _db;

  /// 记一笔。已存在（同题同天）则刷新动作/结论并把 `hits` +1。
  ///
  /// 为什么不用 `ON CONFLICT DO UPDATE`：Android 8 的 SQLite 是 3.19，
  /// upsert 语法要 3.24+。minSdk 是 26，所以用"insert 冲突忽略 → update"
  /// （唯一索引保证只会落在其中一条分支上），比开事务轻。
  Future<void> touch(AnswerLogEntry entry) async {
    // ⚠️ 不能用 `insert(conflictAlgorithm: ignore)` 的返回值判断"是新插入还是冲突"：
    // sqflite 的 insert 返回的是 `last_insert_rowid()`，冲突时不会清零，
    // 仍会返回上一行的 id（2026-10-25 真机踩到：判题结论被静默丢掉）。
    // 所以老老实实先查后写；唯一索引兜住并发（插入撞了就走更新）。
    final List<Map<String, Object?>> rows = await _exists(entry);
    if (rows.isEmpty) {
      try {
        await _db.insert('answer_log', entry.toRow());
        return;
      } on DatabaseException {
        // 并发插入：落到下面的更新分支。
      }
    }
    await _db.rawUpdate(
      'UPDATE answer_log SET at = ?, source = ?, '
      // 落笔不该把已经判好的结论冲回 none：只有带来结论的动作才改 verdict。
      "verdict = CASE WHEN ? = 'none' THEN verdict ELSE ? END, "
      'workbook_id = ?, workbook_title = ?, label = ?, kind = ?, '
      'page_index = ?, origin_title = ?, attempt_id = ?, hits = hits + 1 '
      'WHERE question_id = ? AND day = ? AND origin = ? AND attempt_id = ?',
      <Object?>[
        entry.at,
        entry.source.name,
        entry.verdict.name,
        entry.verdict.name,
        entry.workbookId,
        entry.workbookTitle,
        entry.label,
        entry.kind,
        entry.pageIndex,
        entry.originTitle,
        entry.attemptId,
        entry.questionId,
        entry.day,
        entry.origin.name,
        entry.attemptId,
      ],
    );
  }

  /// 回填专用：不存在才插；存在则把 `at` 往"更晚的那次"推、把结论补上。
  ///
  /// 为什么和 [touch] 分开：回填会为同一题同一天扫到多个证据
  /// （SIF 的 mtime、作答框的 updated_at、判题的 at），它们不是"用户又做了一遍"，
  /// 不能把 `hits` 累加，只能取最完整的一条。
  Future<void> seed(AnswerLogEntry entry) async {
    final List<Map<String, Object?>> rows = await _exists(entry);
    if (rows.isEmpty) {
      try {
        await _db.insert('answer_log', entry.toRow());
        return;
      } on DatabaseException {
        // 并发插入：落到更新分支。
      }
    }
    await _db.rawUpdate(
      'UPDATE answer_log SET '
      'at = CASE WHEN at < ? THEN ? ELSE at END, '
      "verdict = CASE WHEN verdict = 'none' THEN ? ELSE verdict END, "
      'workbook_title = ?, label = ?, kind = ?, page_index = ? '
      'WHERE question_id = ? AND day = ? AND origin = ? AND attempt_id = ?',
      <Object?>[
        entry.at,
        entry.at,
        entry.verdict.name,
        entry.workbookTitle,
        entry.label,
        entry.kind,
        entry.pageIndex,
        entry.questionId,
        entry.day,
        entry.origin.name,
        entry.attemptId,
      ],
    );
  }

  Future<List<Map<String, Object?>>> _exists(AnswerLogEntry entry) {
    return _db.query(
      'answer_log',
      columns: const <String>['id'],
      // v9：唯一索引是 (question_id, day, origin, attempt_id)——
      // 同一天同一题，每一次重刷 attempt 是独立一行。
      where: 'question_id = ? AND day = ? AND origin = ? AND attempt_id = ?',
      whereArgs: <Object?>[
        entry.questionId,
        entry.day,
        entry.origin.name,
        entry.attemptId,
      ],
      limit: 1,
    );
  }

  /// 丢弃一次重刷：删掉这个 attempt 写下的全部记录。
  ///
  /// 用于"退出时选择不保存"——笔迹与纸张目录会由 `RedoAttemptStore` 删除，
  /// 这里把已经旁路写入的记录行也清掉，避免时间线留下幽灵。
  Future<int> deleteAttempt(String attemptId) async {
    if (attemptId.trim().isEmpty) {
      return 0;
    }
    return _db.delete(
      'answer_log',
      where: 'attempt_id = ?',
      whereArgs: <Object?>[attemptId],
    );
  }

  /// 判题结论变了：把这道题**所有历史行**的 verdict 一起刷新。  ///
  /// 时间线里的色带读的是本表，不跟着改的话会出现"卡片写判错、
  /// 打开原卷却是判对"的分裂。
  Future<int> syncVerdict(String questionId, AnswerVerdict verdict) async {
    return _db.update(
      'answer_log',
      <String, Object?>{'verdict': verdict.name},
      where: 'question_id = ?',
      whereArgs: <Object?>[questionId],
    );
  }

  /// 卷改名了：同步快照里的卷名（活库读不到时才用快照，见 `groupTimeline`）。
  Future<int> syncWorkbookTitle(String workbookId, String title) async {
    return _db.update(
      'answer_log',
      <String, Object?>{'workbook_title': title},
      where: 'workbook_id = ?',
      whereArgs: <Object?>[workbookId],
    );
  }

  /// 明细，按时间倒序。时间线用。
  Future<List<AnswerLogEntry>> list({
    String? sinceDay,
    int limit = 400,
    int offset = 0,
  }) async {
    final List<Map<String, Object?>> rows = await _db.query(
      'answer_log',
      where: sinceDay == null ? null : 'day >= ?',
      whereArgs: sinceDay == null ? null : <Object?>[sinceDay],
      orderBy: 'at DESC',
      limit: limit,
      offset: offset,
    );
    return rows.map(AnswerLogEntry.fromRow).toList(growable: false);
  }

  /// 全量明细（首页统计用：一天一题一行，一年重度使用也就万级）。
  Future<List<AnswerLogEntry>> listAll({String? sinceDay}) async {
    return list(sinceDay: sinceDay, limit: 1000000);
  }

  /// 按天聚合：题数 + 卷数。热力图与连续打卡只看这一条查询。
  Future<Map<String, DayStat>> dayStats({String? sinceDay}) async {
    final List<Map<String, Object?>> rows = await _db.rawQuery(
      'SELECT day, COUNT(*) AS q, COUNT(DISTINCT workbook_id) AS w '
      'FROM answer_log ${sinceDay == null ? '' : 'WHERE day >= ?'} '
      'GROUP BY day',
      sinceDay == null ? null : <Object?>[sinceDay],
    );
    return <String, DayStat>{
      for (final Map<String, Object?> row in rows)
        (row['day'] as String? ?? ''): DayStat(
          questions: (row['q'] as num?)?.toInt() ?? 0,
          workbooks: (row['w'] as num?)?.toInt() ?? 0,
        ),
    };
  }

  /// 按卷聚合的题数（词云按科目汇总前的中间量）。
  Future<Map<String, int>> questionsByWorkbook({String? sinceDay}) async {
    final List<Map<String, Object?>> rows = await _db.rawQuery(
      'SELECT workbook_id, COUNT(*) AS q FROM answer_log '
      '${sinceDay == null ? '' : 'WHERE day >= ?'} GROUP BY workbook_id',
      sinceDay == null ? null : <Object?>[sinceDay],
    );
    return <String, int>{
      for (final Map<String, Object?> row in rows)
        (row['workbook_id'] as String? ?? ''): (row['q'] as num?)?.toInt() ?? 0,
    };
  }

  /// 按题型聚合的题数（词云第二维度）。
  Future<Map<String, int>> questionsByKind({String? sinceDay}) async {
    final List<Map<String, Object?>> rows = await _db.rawQuery(
      'SELECT kind, COUNT(*) AS q FROM answer_log '
      '${sinceDay == null ? '' : 'WHERE day >= ?'} GROUP BY kind',
      sinceDay == null ? null : <Object?>[sinceDay],
    );
    return <String, int>{
      for (final Map<String, Object?> row in rows)
        (row['kind'] as String? ?? 'unknown'): (row['q'] as num?)?.toInt() ?? 0,
    };
  }

  /// 总题数（有记录以来的累计）。设置页/看板用。
  Future<int> totalQuestions() async {
    final List<Map<String, Object?>> rows = await _db.rawQuery(
      'SELECT COUNT(*) AS q FROM answer_log',
    );
    return (rows.first['q'] as num?)?.toInt() ?? 0;
  }

  /// 一共有几天有记录（累计天数，不是连续天数）。
  Future<int> activeDays() async {
    final List<Map<String, Object?>> rows = await _db.rawQuery(
      'SELECT COUNT(DISTINCT day) AS d FROM answer_log',
    );
    return (rows.first['d'] as num?)?.toInt() ?? 0;
  }

  /// 累计做过几卷（有记录的卷数，不看卷是否还在）。
  Future<int> totalWorkbooks() async {
    final List<Map<String, Object?>> rows = await _db.rawQuery(
      'SELECT COUNT(DISTINCT workbook_id) AS w FROM answer_log',
    );
    return (rows.first['w'] as num?)?.toInt() ?? 0;
  }
}
