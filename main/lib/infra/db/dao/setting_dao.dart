import 'package:sqflite/sqflite.dart';

/// `setting` 表的读写（§5.3A：键值设置，键名是稳定契约）。
///
/// 键名一律用 [ReaderSettingKeys]（`lib/domain/reader/reader_prefs.dart`），
/// 别在这里手写 `'reader.default_mode'` 之类字符串。
class SettingDao {
  const SettingDao(this._db);

  final DatabaseExecutor _db;

  Future<String?> get(String key) async {
    final List<Map<String, Object?>> rows = await _db.query(
      'setting',
      columns: const <String>['v'],
      where: 'k = ?',
      whereArgs: <Object?>[key],
      limit: 1,
    );
    if (rows.isEmpty) {
      return null;
    }
    return rows.first['v'] as String?;
  }

  Future<void> put(String key, String value) async {
    await _db.insert('setting', <String, Object?>{'k': key, 'v': value},
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> remove(String key) async {
    await _db.delete('setting', where: 'k = ?', whereArgs: <Object?>[key]);
  }
}
