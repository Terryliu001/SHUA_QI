import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shuaqi/app/bootstrap.dart';
import 'package:shuaqi/app/import/import_workbook.dart';
import 'package:shuaqi/domain/model/workbook.dart';
import 'package:shuaqi/infra/db/dao/workbook_dao.dart';
import 'package:shuaqi/infra/vault/vault.dart';

/// 订阅状态的集中出口（`lib/state/`）。
///
/// 约定：这里只放**跨页面共享**的状态与用例入口。页面私有的临时状态留在页面里，
/// 不要为了"统一"把所有 `setState` 都搬进 Provider。
///
/// 命名：`xxxProvider`；派生状态用 `xxxProvider` + `Provider` 组合，不要造 setter。

/// 启动时装配的依赖。**必须在 `ProviderScope(overrides:)` 里覆盖**，
/// 没覆盖就直接抛，避免出现"用了一个没初始化的数据库"这种隐蔽错误。
final Provider<AppDependencies> appDependenciesProvider =
    Provider<AppDependencies>((Ref ref) {
      throw StateError(
        'appDependenciesProvider 必须在 ProviderScope(overrides:) 里提供'
        '（见 lib/main.dart 的 bootstrap）',
      );
    });

final Provider<Vault> vaultProvider = Provider<Vault>(
  (Ref ref) => ref.watch(appDependenciesProvider).vault,
);

final Provider<WorkbookDao> workbookDaoProvider = Provider<WorkbookDao>(
  (Ref ref) => WorkbookDao(ref.watch(appDependenciesProvider).db.raw),
);

final Provider<WorkbookImporter> workbookImporterProvider =
    Provider<WorkbookImporter>((Ref ref) {
      final AppDependencies deps = ref.watch(appDependenciesProvider);
      return WorkbookImporter(db: deps.db, vault: deps.vault);
    });

/// 书架数据源。导入/删除后 `ref.invalidate(bookshelfProvider)` 即可刷新。
///
/// 用 `FutureProvider` 而不是在 `build()` 里查库：查库是异步 IO，
/// 放进 build 会让每一帧都可能触发查询（T1.4 的坑）。
final FutureProvider<List<Workbook>> bookshelfProvider =
    FutureProvider<List<Workbook>>((Ref ref) {
      return ref.watch(workbookDaoProvider).listByRecent();
    });
