import 'package:shuaqi/domain/model/workbook.dart';
import 'package:sqflite/sqflite.dart';

/// `workbook` 表的读写（规格 §5.2）。
///
/// 只写本周（T1.2/T1.3/T1.4）真正用到的方法，不做"先写全以后再删"。
class WorkbookDao {
  const WorkbookDao(this._db);

  /// 可以是 [Database]，也可以是 [Transaction] —— 导入流程要把 DAO 放进事务里用。
  final DatabaseExecutor _db;

  /// 插入一卷。`sha1` 有 UNIQUE 约束，重复插入会抛 [DatabaseException]，
  /// 不做静默忽略：重复导入的判定交给调用方（先 [bySha1] 查，给用户明确提示）。
  Future<void> insert(Workbook workbook) async {
    await _db.insert(
      'workbook',
      workbook.toRow(),
      conflictAlgorithm: ConflictAlgorithm.abort,
    );
  }

  /// 书架列表。按"最近打开优先"，从没打开过的按导入时间排在后面。
  Future<List<Workbook>> listByRecent({int limit = 50}) async {
    final List<Map<String, Object?>> rows = await _db.query(
      'workbook',
      orderBy: 'COALESCE(opened_at, created_at) DESC, created_at DESC',
      limit: limit,
    );
    return rows.map(Workbook.fromRow).toList(growable: false);
  }

  Future<Workbook?> bySha1(String sha1) async {
    final List<Map<String, Object?>> rows = await _db.query(
      'workbook',
      where: 'sha1 = ?',
      whereArgs: <Object?>[sha1],
      limit: 1,
    );
    if (rows.isEmpty) {
      return null;
    }
    return Workbook.fromRow(rows.first);
  }

  Future<Workbook?> byId(String id) async {
    final List<Map<String, Object?>> rows = await _db.query(
      'workbook',
      where: 'id = ?',
      whereArgs: <Object?>[id],
      limit: 1,
    );
    if (rows.isEmpty) {
      return null;
    }
    return Workbook.fromRow(rows.first);
  }

  /// 记录"打开了"。`at` 是 UTC 毫秒。
  /// [sessionId] 为 null 时保留原值（COALESCE），避免把已有的 last_session_id 抹掉。
  Future<void> touchOpened(String id, int at, [String? sessionId]) async {
    await _db.rawUpdate(
      'UPDATE workbook SET opened_at = ?, '
      'last_session_id = COALESCE(?, last_session_id) WHERE id = ?',
      <Object?>[at, sessionId, id],
    );
  }

  Future<void> rename(String id, String title) async {
    await _db.update(
      'workbook',
      <String, Object?>{'title': title},
      where: 'id = ?',
      whereArgs: <Object?>[id],
    );
  }

  Future<void> setLayoutStatus(String id, String status) async {
    await _db.update(
      'workbook',
      <String, Object?>{'layout_status': status},
      where: 'id = ?',
      whereArgs: <Object?>[id],
    );
  }

  /// 删一卷。**子表靠外键级联清理**（依赖 `PRAGMA foreign_keys = ON`）。
  /// 返回受影响行数；0 表示 id 不存在。
  Future<int> delete(String id) async {
    return _db.delete('workbook', where: 'id = ?', whereArgs: <Object?>[id]);
  }
}
