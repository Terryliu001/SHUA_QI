import 'package:shuaqi/domain/model/favorite.dart';
import 'package:shuaqi/domain/model/grading.dart';
import 'package:sqflite/sqflite.dart';

/// `favorite` / `favorite_set` / `favorite_set_item` 三张表的读写（T8.1）。
///
/// 收藏是**跨卷**、**独立于原卷**的数据：不 join 卷/题表（它们会被 CASCADE 删掉），
/// 列表直接读本表，快照文件由 `app/favorite/favorite_store.dart` 配合 Vault 读写。
class FavoriteDao {
  const FavoriteDao(this._db);

  /// 可以是 [Database]，也可以是 [Transaction]。
  final DatabaseExecutor _db;

  // ---- favorite ----

  Future<void> insert(Favorite favorite) async {
    await _db.insert(
      'favorite',
      favorite.toRow(),
      conflictAlgorithm: ConflictAlgorithm.abort,
    );
  }

  Future<int> delete(String id) async {
    return _db.delete('favorite', where: 'id = ?', whereArgs: <Object?>[id]);
  }

  /// 全部收藏，按「最近更新」倒序（收藏夹默认形态）。
  Future<List<Favorite>> listByUpdatedAt({int limit = 500}) async {
    final List<Map<String, Object?>> rows = await _db.query(
      'favorite',
      orderBy: 'updated_at DESC',
      limit: limit,
    );
    return rows.map(Favorite.fromRow).toList(growable: false);
  }

  /// 某条收藏（看题页打开用）。
  Future<Favorite?> byId(String id) async {
    final List<Map<String, Object?>> rows = await _db.query(
      'favorite',
      where: 'id = ?',
      whereArgs: <Object?>[id],
      limit: 1,
    );
    return rows.isEmpty ? null : Favorite.fromRow(rows.first);
  }

  /// 某卷的收藏（收藏夹「按试卷」点开后那一页用），按最近更新倒序。
  Future<List<Favorite>> listByWorkbook(String workbookId, {int limit = 500}) async {
    final List<Map<String, Object?>> rows = await _db.query(
      'favorite',
      where: 'workbook_id = ?',
      whereArgs: <Object?>[workbookId],
      orderBy: 'updated_at DESC',
      limit: limit,
    );
    return rows.map(Favorite.fromRow).toList(growable: false);
  }

  /// 卷改名后同步快照上的卷名（卡片与看题页标题立即跟上）。
  Future<int> updateWorkbookTitle(
    String workbookId,
    String title, {
    required int at,
  }) async {
    return _db.update(
      'favorite',
      <String, Object?>{'workbook_title': title, 'updated_at': at},
      where: 'workbook_id = ?',
      whereArgs: <Object?>[workbookId],
    );
  }

  /// 某源题是否已收藏（toggle / isFavorite 用）。返回收藏 id，没收藏为 null。
  Future<String?> idByQuestionId(String questionId) async {
    final List<Map<String, Object?>> rows = await _db.query(
      'favorite',
      columns: <String>['id'],
      where: 'question_id = ?',
      whereArgs: <Object?>[questionId],
      limit: 1,
    );
    if (rows.isEmpty) {
      return null;
    }
    return rows.first['id'] as String?;
  }

  Future<void> updateTags(
    String id,
    List<String> tags, {
    required int at,
  }) async {
    await _db.update(
      'favorite',
      <String, Object?>{
        'knowledge_tags': KnowledgeTags.encode(tags),
        'updated_at': at,
      },
      where: 'id = ?',
      whereArgs: <Object?>[id],
    );
  }

  Future<void> updateVerdict(
    String id,
    AnswerVerdict verdict, {
    required int at,
  }) async {
    await _db.update(
      'favorite',
      <String, Object?>{
        'verdict': verdict.name,
        'updated_at': at,
      },
      where: 'id = ?',
      whereArgs: <Object?>[id],
    );
  }

  /// 某卷的收藏数（删卷时的「会保留 N 题」提示用）。
  Future<int> countByWorkbook(String workbookId) async {
    final List<Map<String, Object?>> rows = await _db.rawQuery(
      'SELECT COUNT(*) AS c FROM favorite WHERE workbook_id = ?',
      <Object?>[workbookId],
    );
    return (rows.first['c'] as num?)?.toInt() ?? 0;
  }

  /// 来源卷删除后：标记该卷所有收藏为「来源已删」，看题页据此走快照兜底。
  Future<void> markSourceDeleted(String workbookId, {required int at}) async {
    await _db.rawUpdate(
      'UPDATE favorite SET source_deleted = 1, updated_at = ? '
      'WHERE workbook_id = ? AND source_deleted = 0',
      <Object?>[at, workbookId],
    );
  }

  // ---- favorite_set / favorite_set_item ----

  Future<void> insertSet(FavoriteSet set) async {
    await _db.insert(
      'favorite_set',
      set.toRow(),
      conflictAlgorithm: ConflictAlgorithm.abort,
    );
  }

  /// 全部组卷 + 成员数，按最近更新倒序。
  ///
  /// 用子查询而不是在 Dart 里逐个 count：卷数量是十几个级，但列表页一帧内
  /// 发 N 次查询会让首帧变慢（书架踩过同样的坑）。
  Future<List<FavoriteSet>> listSets() async {
    final List<Map<String, Object?>> rows = await _db.rawQuery(
      'SELECT s.id, s.name, s.created_at, s.updated_at, '
      '(SELECT COUNT(*) FROM favorite_set_item i WHERE i.set_id = s.id) '
      'AS item_count '
      'FROM favorite_set s ORDER BY s.updated_at DESC',
    );
    return rows.map(FavoriteSet.fromRow).toList(growable: false);
  }

  Future<FavoriteSet?> setById(String id) async {
    final List<Map<String, Object?>> rows = await _db.rawQuery(
      'SELECT s.id, s.name, s.created_at, s.updated_at, '
      '(SELECT COUNT(*) FROM favorite_set_item i WHERE i.set_id = s.id) '
      'AS item_count '
      'FROM favorite_set s WHERE s.id = ? LIMIT 1',
      <Object?>[id],
    );
    return rows.isEmpty ? null : FavoriteSet.fromRow(rows.first);
  }

  Future<int> deleteSet(String id) async {
    return _db.delete('favorite_set', where: 'id = ?', whereArgs: <Object?>[id]);
  }

  /// 成员变化后把组卷顶到列表前面（updated_at 是组卷的排序依据）。
  Future<void> touchSet(String id, {required int at}) async {
    await _db.update(
      'favorite_set',
      <String, Object?>{'updated_at': at},
      where: 'id = ?',
      whereArgs: <Object?>[id],
    );
  }

  /// 下一个 sort 值（当前最大 + 1；空卷为 0）。
  Future<int> nextSetSort(String setId) async {
    final List<Map<String, Object?>> rows = await _db.rawQuery(
      'SELECT MAX(sort) AS m FROM favorite_set_item WHERE set_id = ?',
      <Object?>[setId],
    );
    final int? max = (rows.first['m'] as num?)?.toInt();
    return max == null ? 0 : max + 1;
  }

  /// 按 id 批量取收藏（组卷成员用）。**顺序由调用方决定**，这里只查。
  Future<List<Favorite>> byIds(Iterable<String> ids) async {
    final List<String> list = <String>[
      for (final String id in ids)
        if (id.isNotEmpty) id,
    ];
    if (list.isEmpty) {
      return const <Favorite>[];
    }
    final List<Map<String, Object?>> rows = await _db.query(
      'favorite',
      where: 'id IN (${List<String>.filled(list.length, '?').join(',')})',
      whereArgs: list,
    );
    return rows.map(Favorite.fromRow).toList(growable: false);
  }

  /// 一条收藏当前属于哪些组卷（长按菜单显示"已在 N 个组卷"用）。
  Future<List<String>> setIdsOf(String favoriteId) async {
    final List<Map<String, Object?>> rows = await _db.query(
      'favorite_set_item',
      columns: <String>['set_id'],
      where: 'favorite_id = ?',
      whereArgs: <Object?>[favoriteId],
    );
    return rows
        .map((Map<String, Object?> row) => row['set_id']! as String)
        .toList(growable: false);
  }

  Future<void> renameSet(String id, String name, {required int at}) async {
    await _db.update(
      'favorite_set',
      <String, Object?>{'name': name, 'updated_at': at},
      where: 'id = ?',
      whereArgs: <Object?>[id],
    );
  }

  /// 组卷的有序成员（favorite id，按 sort 升序）。
  Future<List<String>> setItemIds(String setId) async {
    final List<Map<String, Object?>> rows = await _db.query(
      'favorite_set_item',
      columns: <String>['favorite_id'],
      where: 'set_id = ?',
      whereArgs: <Object?>[setId],
      orderBy: 'sort ASC',
    );
    return rows
        .map((Map<String, Object?> row) => row['favorite_id']! as String)
        .toList(growable: false);
  }

  Future<void> addSetItem(
    String setId,
    String favoriteId,
    int sort,
  ) async {
    await _db.insert(
      'favorite_set_item',
      <String, Object?>{
        'set_id': setId,
        'favorite_id': favoriteId,
        'sort': sort,
      },
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  Future<int> removeSetItem(String setId, String favoriteId) async {
    return _db.delete(
      'favorite_set_item',
      where: 'set_id = ? AND favorite_id = ?',
      whereArgs: <Object?>[setId, favoriteId],
    );
  }

  /// 拖动排序后写回某条成员的 sort（T8.4：长按拖动调整题目顺序）。
  Future<void> updateSetItemSort(
    String setId,
    String favoriteId,
    int sort,
  ) async {
    await _db.update(
      'favorite_set_item',
      <String, Object?>{'sort': sort},
      where: 'set_id = ? AND favorite_id = ?',
      whereArgs: <Object?>[setId, favoriteId],
    );
  }
}
