import 'package:shuaqi/domain/model/session.dart';
import 'package:shuaqi/domain/util/ulid.dart';
import 'package:sqflite/sqflite.dart';

/// `session` 表的读写。
///
/// 会话是"一次作答"的载体：同一卷可以有 seq=1、seq=2 两条独立记录（REQ-11 二刷）。
/// 状态机迁移（§5.5）只允许单向：draft → submitted → archived。
class SessionDao {
  const SessionDao(this._db);

  final DatabaseExecutor _db;

  /// 新建一次 draft 会话，`seq` 自动取该卷的下一个序号。
  ///
  /// [now] 是 UTC 毫秒，由调用方给，方便测试。
  Future<Session> createDraft(String workbookId, {required int now}) async {
    final List<Map<String, Object?>> rows = await _db.rawQuery(
      'SELECT COALESCE(MAX(seq), 0) + 1 AS next FROM session WHERE workbook_id = ?',
      <Object?>[workbookId],
    );
    final int seq = (rows.first['next'] as num?)?.toInt() ?? 1;
    final Session session = Session(
      id: Ulid.next(),
      workbookId: workbookId,
      seq: seq,
      state: SessionState.draft,
      startedAt: now,
    );
    await _db.insert('session', session.toRow());
    return session;
  }

  /// 该卷最新的会话（seq 最大的那条），书架"继续刷"用。
  Future<Session?> latestForWorkbook(String workbookId) async {
    final List<Map<String, Object?>> rows = await _db.query(
      'session',
      where: 'workbook_id = ?',
      whereArgs: <Object?>[workbookId],
      orderBy: 'seq DESC',
      limit: 1,
    );
    if (rows.isEmpty) {
      return null;
    }
    return Session.fromRow(rows.first);
  }

  Future<Session?> byId(String id) async {
    final List<Map<String, Object?>> rows = await _db.query(
      'session',
      where: 'id = ?',
      whereArgs: <Object?>[id],
      limit: 1,
    );
    if (rows.isEmpty) {
      return null;
    }
    return Session.fromRow(rows.first);
  }

  /// 记住最后停留的页（0-based）。T1.5 的进度防抖 500ms 后调用。
  Future<void> updateLastPage(String sessionId, int page) async {
    await _db.update(
      'session',
      <String, Object?>{'last_page': page},
      where: 'id = ?',
      whereArgs: <Object?>[sessionId],
    );
  }

  /// draft → submitted。已交卷的会话不会被再次改写（返回值 0 说明状态不对）。
  Future<int> markSubmitted(String sessionId, {required int at}) async {
    return _db.update(
      'session',
      <String, Object?>{'state': SessionState.submitted.name, 'submitted_at': at},
      where: 'id = ? AND state = ?',
      whereArgs: <Object?>[sessionId, SessionState.draft.name],
    );
  }

  /// submitted → archived。归档清理在 T7.5 做，这里只改状态。
  Future<int> archive(String sessionId) async {
    return _db.update(
      'session',
      <String, Object?>{'state': SessionState.archived.name},
      where: 'id = ? AND state = ?',
      whereArgs: <Object?>[sessionId, SessionState.submitted.name],
    );
  }
}
