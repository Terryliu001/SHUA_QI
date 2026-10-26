import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shuaqi/app/app_info.dart';
import 'package:shuaqi/app/backup/backup_service.dart';
import 'package:shuaqi/app/feedback/local_feedback_gateway.dart';
import 'package:shuaqi/app/storage/cache_service.dart';
import 'package:shuaqi/domain/feedback/feedback.dart';
import 'package:shuaqi/state/app_providers.dart';

/// 设置页用到的三个服务（缓存统计 / 备份恢复 / 反馈通道）。
///
/// 放在 `state/` 而不是各页面自己 new：它们都要读 `appDependenciesProvider`
/// （Vault / DB），页面里 new 会让"用哪一份依赖"变得不可查。
final Provider<CacheService> cacheServiceProvider = Provider<CacheService>((
  Ref ref,
) {
  final deps = ref.watch(appDependenciesProvider);
  return CacheService(vault: deps.vault, dbPath: deps.db.path);
});

final Provider<BackupService> backupServiceProvider = Provider<BackupService>((
  Ref ref,
) {
  final deps = ref.watch(appDependenciesProvider);
  return BackupService(
    db: deps.db,
    vault: deps.vault,
    supportPath: deps.supportPath,
    appVersion: AppInfo.version,
  );
});

/// 反馈通道。**当前实现是本机暂存**（`LocalFeedbackGateway`）：
/// 界面、校验、图片选择全是真的，只是"发送"这一步还没接通后端。
/// 接通后只换这里的实现，界面与表单模型都不用动。
final Provider<FeedbackGateway> feedbackGatewayProvider =
    Provider<FeedbackGateway>((Ref ref) {
      return LocalFeedbackGateway(vault: ref.watch(vaultProvider));
    });
