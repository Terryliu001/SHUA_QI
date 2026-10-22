import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shuaqi/app/import/import_workbook.dart';
import 'package:shuaqi/infra/db/app_database.dart';
import 'package:shuaqi/infra/vault/vault.dart';

/// 应用启动时装配好的依赖（规格 T1.1 的 `bootstrap`）。
///
/// 用一个普通类持有，再由 `ProviderScope(overrides:)` 注入 ——
/// 不引 `get_it`（§9 禁止），Riverpod 已经能做同样的事。
class AppDependencies {
  const AppDependencies({required this.db, required this.vault});

  final AppDatabase db;
  final Vault vault;
}

/// 打开数据库与 Vault，返回依赖。
///
/// **放在 App 私有目录**（`getApplicationSupportDirectory`）而不是 cache：
/// - cache 会被系统在低存储时清掉，用户的卷和笔迹不能放那里；
/// - 也不放外部存储：那需要存储权限，而 §5.3 的设计是零权限。
Future<AppDependencies> bootstrap() async {
  final Directory support = await getApplicationSupportDirectory();
  final Vault vault = await Vault.open(p.join(support.path, 'vault'));
  final AppDatabase db = await AppDatabase.open(
    p.join(support.path, 'shuaqi.db'),
  );

  // 启动时清一次孤儿：上次导入在"写完文件、落库前"被杀会留下空目录
  await sweepOrphans(db: db, vault: vault);

  return AppDependencies(db: db, vault: vault);
}
