import 'package:shuaqi/domain/model/shelf_folder.dart';
import 'package:shuaqi/domain/util/ulid.dart';
import 'package:sqflite/sqflite.dart';

/// `folder` / `tag` 两张表的读写（v4 起）。
///
/// 与 `workbook.folder`（旧的名字字符串）的关系：
/// v4 只加了表，没有搬数据；搬由 [migrateLegacyNames] 在启动后第一次读写时做一次，
/// 用 `setting` 打标记保证幂等。老库里的 `folder` 列继续保留（不改历史迁移），
/// 只是新逻辑不再读它。
class FolderDao {
  const FolderDao(this._db);

  final DatabaseExecutor _db;

  Future<List<ShelfFolder>> list() async {
    final List<Map<String, Object?>> rows = await _db.query(
      'folder',
      orderBy: 'sort ASC, name ASC',
    );
    return rows.map(ShelfFolder.fromRow).toList(growable: false);
  }

  Future<ShelfFolder> create({
    required String name,
    String parentId = '',
    String color = '',
  }) async {
    final ShelfFolder folder = ShelfFolder(
      id: Ulid.next(),
      name: name.trim(),
      parentId: parentId,
      color: color,
    );
    await _db.insert('folder', folder.toRow());
    return folder;
  }

  Future<void> rename(String id, String name) async {
    await _db.update(
      'folder',
      <String, Object?>{'name': name.trim()},
      where: 'id = ?',
      whereArgs: <Object?>[id],
    );
  }

  /// 改父级（树视图里拖动文件夹改归属）。
  ///
  /// **不在这里校验"会不会拖成环"**：DAO 只有 id，拿不到整棵树。
  /// 调用方（书架页）必须先用 [folderSubtreeIds] 挡掉"拖进自己的子孙"。
  Future<void> setParent(String id, String parentId) async {
    await _db.update(
      'folder',
      <String, Object?>{'parent_id': parentId},
      where: 'id = ?',
      whereArgs: <Object?>[id],
    );
  }

  Future<void> setColor(String id, String color) async {
    await _db.update(
      'folder',
      <String, Object?>{'color': color},
      where: 'id = ?',
      whereArgs: <Object?>[id],
    );
  }

  /// 删一个文件夹：**它和所有子孙里的卷上提到它的父级**，不删卷。
  Future<void> delete(String id, {required Set<String> subtreeIds}) async {
    for (final String folderId in subtreeIds) {
      await _db.update(
        'workbook',
        <String, Object?>{'folder_id': ''},
        where: 'folder_id = ?',
        whereArgs: <Object?>[folderId],
      );
    }
    await _db.delete(
      'folder',
      where: 'id IN (${List<String>.filled(subtreeIds.length, '?').join(',')})',
      whereArgs: subtreeIds.toList(growable: false),
    );
  }

  /// 把旧的"文件夹名字"一次性搬成 `folder` 行，并把卷的 `folder_id` 指过去。
  ///
  /// 幂等：先看有没有同名同级的记录，有就复用。返回是否真的做了迁移。
  Future<bool> migrateLegacyNames() async {
    final List<Map<String, Object?>> legacy = await _db.rawQuery(
      "SELECT DISTINCT folder FROM workbook WHERE folder <> ''",
    );
    if (legacy.isEmpty) {
      return false;
    }
    final List<ShelfFolder> existing = await list();
    final Map<String, String> topLevelByName = <String, String>{
      for (final ShelfFolder folder in existing)
        if (folder.isRoot) folder.name: folder.id,
    };
    for (final Map<String, Object?> row in legacy) {
      final String name = (row['folder'] as String?)?.trim() ?? '';
      if (name.isEmpty) {
        continue;
      }
      String? folderId = topLevelByName[name];
      if (folderId == null) {
        final ShelfFolder created = await create(name: name);
        folderId = created.id;
        topLevelByName[name] = folderId;
      }
      await _db.update(
        'workbook',
        <String, Object?>{'folder_id': folderId},
        where: "folder = ? AND (folder_id IS NULL OR folder_id = '')",
        whereArgs: <Object?>[name],
      );
    }
    return true;
  }
}

/// 标签的颜色（`tag` 表只有 name → color）。
///
/// 标签本身仍留在 `workbook.tags`（逗号分隔）：改名/删标签不需要级联，
/// 颜色只是"这个名字长什么样"的补充信息。
class TagDao {
  const TagDao(this._db);

  final DatabaseExecutor _db;

  Future<Map<String, String>> colors() async {
    final List<Map<String, Object?>> rows = await _db.query('tag');
    return <String, String>{
      for (final Map<String, Object?> row in rows)
        if ((row['name'] as String?)?.isNotEmpty ?? false)
          row['name'] as String: (row['color'] as String?) ?? '',
    };
  }

  Future<void> setColor(String name, String color) async {
    await _db.insert('tag', <String, Object?>{
      'name': name,
      'color': color,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// 某标签彻底不用了：删颜色记录（卷里的标签文字不动）。
  Future<void> forget(String name) async {
    await _db.delete('tag', where: 'name = ?', whereArgs: <Object?>[name]);
  }
}
