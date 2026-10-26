import 'package:sqflite/sqflite.dart';

import 'migrations.dart';

/// 数据库入口（规格 §5.2）。
///
/// 只做三件事：开库、跑迁移、把事务交出去。**不含任何业务规则**——
/// 业务规则属于 DAO 的调用方（`app/`），因为"什么算重复导入"不是数据库的事。
///
/// 关键约定：
/// 1. `PRAGMA foreign_keys = ON` 在 [OpenDatabaseOptions.onConfigure] 里做——
///    SQLite 不允许在事务内改这个 pragma，off `onCreate`/`onUpgrade` 都不行。
/// 2. 迁移只走 [kMigrations]，不许在 onCreate 里另写一份 DDL。
/// 3. 时间一律 UTC 毫秒，转换只在 UI 层做。
class AppDatabase {
  AppDatabase._(this._db, this.path);

  /// 打开（必要时创建/升级）数据库。
  ///
  /// [targetVersion] 只给测试用：把库停在某个旧版本，才能验证"升级不丢数据"。
  /// [factory] 也是测试用（桌面跑 sqflite 需要 ffi 实现）。
  static Future<AppDatabase> open(
    String path, {
    int? targetVersion,
    DatabaseFactory? factory,
  }) async {
    final DatabaseFactory dbFactory = factory ?? databaseFactory;
    final int version = targetVersion ?? kDatabaseVersion;

    final Database db = await dbFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: version,
        onConfigure: _configure,
        onCreate: _create,
        onUpgrade: _upgrade,
      ),
    );
    return AppDatabase._(db, path);
  }

  final Database _db;

  /// 数据库文件的绝对路径。
  ///
  /// 2026-10-26 起需要它做两件事：① 设置页的「缓存统计」要把库体积算进去；
  /// ② 导出备份要把库文件和 Vault 一起打进 zip。之前只有 `raw`，取不到路径。
  final String path;

  /// 底层句柄。DAO 构造要用它，业务代码不要直接碰。
  Database get raw => _db;

  /// 在一个事务里跑 [action]。异常会自动回滚。
  ///
  /// 导入流程（T1.3）必须把"写 workbook + 写 wb_page"放在同一个事务里，
  /// 否则中途崩溃会留下"有卷没有页"的半截数据。
  Future<T> tx<T>(Future<T> Function(Transaction txn) action) {
    return _db.transaction<T>(action);
  }

  Future<void> close() => _db.close();

  static Future<void> _configure(Database db) async {
    // 级联删除全靠它。少了这句，DELETE workbook 不会带走 wb_page / session。
    await db.execute('PRAGMA foreign_keys = ON');
  }

  static Future<void> _create(Database db, int version) async {
    for (final String statement in statementsBetween(
      fromVersion: 0,
      toVersion: version,
    )) {
      await db.execute(statement);
    }
  }

  static Future<void> _upgrade(
    Database db,
    int oldVersion,
    int newVersion,
  ) async {
    for (final String statement in statementsBetween(
      fromVersion: oldVersion,
      toVersion: newVersion,
    )) {
      await db.execute(statement);
    }
  }
}
