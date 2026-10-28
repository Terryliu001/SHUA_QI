import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shuaqi/app/favorite/favorite_store.dart';
import 'package:shuaqi/app/import/import_workbook.dart';
import 'package:shuaqi/app/records/record_backfill.dart';
import 'package:shuaqi/app/records/record_service.dart';
import 'package:shuaqi/domain/model/workbook.dart';
import 'package:shuaqi/infra/db/app_database.dart';
import 'package:shuaqi/infra/db/dao/workbook_dao.dart';
import 'package:shuaqi/infra/vault/layout_store.dart';
import 'package:shuaqi/infra/vault/vault.dart';

/// 应用启动时装配好的依赖（规格 T1.1 的 `bootstrap`）。
///
/// 用一个普通类持有，再由 `ProviderScope(overrides:)` 注入 ——
/// 不引 `get_it`（§9 禁止），Riverpod 已经能做同样的事。
class AppDependencies {
  const AppDependencies({
    required this.db,
    required this.vault,
    required this.supportPath,
    required this.isFreshInstall,
  });

  final AppDatabase db;
  final Vault vault;

  /// 应用私有根目录（`getApplicationSupportDirectory()`）。
  ///
  /// 2026-10-26 起需要它：备份 zip 的临时文件、恢复时的解包目录与留底目录
  /// 都放在这儿（不能放 vault 里——那会被"缓存清理"扫到）。
  final String supportPath;

  /// 本次启动前数据库文件是否还不存在（= 全新安装）。
  ///
  /// 只给「首次启动用户须知」用：老用户升级不重复打扰。
  final bool isFreshInstall;
}

/// 打开数据库与 Vault，返回依赖。
///
/// **放在 App 私有目录**（`getApplicationSupportDirectory`）而不是 cache：
/// - cache 会被系统在低存储时清掉，用户的卷和笔迹不能放那里；
/// - 也不放外部存储：那需要存储权限，而 §5.3 的设计是零权限。
Future<AppDependencies> bootstrap() async {
  final Directory support = await getApplicationSupportDirectory();
  final Vault vault = await Vault.open(p.join(support.path, 'vault'));
  final String dbPath = p.join(support.path, 'shuaqi.db');
  // 先看库文件在不在，再 open（open 会创建它）。用于判断"全新安装"。
  final bool isFreshInstall = !File(dbPath).existsSync();
  final AppDatabase db = await AppDatabase.open(dbPath);

  // 启动时清一次孤儿：上次导入在"写完文件、落库前"被杀会留下空目录
  await sweepOrphans(db: db, vault: vault);

  // 自愈：收藏不设外键，卷被删（尤其旧的批量删除漏标）后收藏会误以为
  // "原卷还在"。这里按 workbook 表实际存在与否补一次 source_deleted。
  try {
    await db.raw.rawUpdate(
      'UPDATE favorite SET source_deleted = 1 '
      'WHERE source_deleted = 0 '
      'AND workbook_id NOT IN (SELECT id FROM workbook)',
    );
  } on Object {
    // 自愈失败不影响启动；收藏夹仍可手动取消。
  }

  // 旧收藏迁移（幂等，失败不阻断启动）：把各卷 `favorites.v1.json` 迁进 favorite 表。
  try {
    final List<Workbook> workbooks = await WorkbookDao(db.raw)
        .listByRecent(limit: 100000);
    await FavoriteStore(
      db: db,
      vault: vault,
      layout: LayoutStore(vault),
    ).migrateLegacy(workbooks);
  } on Object {
    // 迁移失败不能挡住启动；收藏夹页兜底再迁一次也不迟。
  }

  // 作答记录回填（一次性，阶段 9）：事件表 v7 才建，用户的既有作答在文件里，
  // 不回填的话记录页第一天是空的。标记写在回填成功后，失败下次再试。
  try {
    await backfillAnswerLog(
      db: db,
      vault: vault,
      layout: LayoutStore(vault),
      records: RecordService(db: db),
    );
  } on Object {
    // 回填是旁路，失败不影响阅读与书写。
  }

  return AppDependencies(
    db: db,
    vault: vault,
    supportPath: support.path,
    isFreshInstall: isFreshInstall,
  );
}
