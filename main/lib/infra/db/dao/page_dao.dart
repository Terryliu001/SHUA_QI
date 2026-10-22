import 'package:shuaqi/domain/model/wb_page.dart';
import 'package:sqflite/sqflite.dart';

/// `wb_page` 表的读写。
class PageDao {
  const PageDao(this._db);

  final DatabaseExecutor _db;

  /// 批量插入。导入时一次性把整卷的页都写进去，放在调用方的事务里。
  Future<void> insertMany(List<WbPage> pages) async {
    if (pages.isEmpty) {
      return;
    }
    final Batch batch = _db.batch();
    for (final WbPage page in pages) {
      batch.insert('wb_page', page.toRow());
    }
    await batch.commit(noResult: true);
  }

  /// 按页序取回。`idx` 是 0-based。
  Future<List<WbPage>> pagesOf(String workbookId) async {
    final List<Map<String, Object?>> rows = await _db.query(
      'wb_page',
      where: 'workbook_id = ?',
      whereArgs: <Object?>[workbookId],
      orderBy: 'idx ASC',
    );
    return rows.map(WbPage.fromRow).toList(growable: false);
  }

  Future<WbPage?> byIndex(String workbookId, int index) async {
    final List<Map<String, Object?>> rows = await _db.query(
      'wb_page',
      where: 'workbook_id = ? AND idx = ?',
      whereArgs: <Object?>[workbookId, index],
      limit: 1,
    );
    if (rows.isEmpty) {
      return null;
    }
    return WbPage.fromRow(rows.first);
  }

  Future<int> countOf(String workbookId) async {
    final List<Map<String, Object?>> rows = await _db.rawQuery(
      'SELECT COUNT(*) AS c FROM wb_page WHERE workbook_id = ?',
      <Object?>[workbookId],
    );
    return (rows.first['c'] as num?)?.toInt() ?? 0;
  }
}
