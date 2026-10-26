import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shuaqi/app/app_info.dart';
import 'package:shuaqi/app/backup/backup_service.dart';
import 'package:shuaqi/app/feedback/http_feedback_gateway.dart';
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

/// 反馈通道：配了 `FEEDBACK_ENDPOINT` 走远端；否则本机暂存并明说"未接通"。
/// 远端失败时 [HttpFeedbackGateway] 会落本机草稿，不假装成功。
final Provider<FeedbackGateway> feedbackGatewayProvider =
    Provider<FeedbackGateway>((Ref ref) {
      final String endpoint = kFeedbackEndpoint.trim();
      if (endpoint.isEmpty) {
        return LocalFeedbackGateway(vault: ref.watch(vaultProvider));
      }
      return HttpFeedbackGateway(
        endpoint: endpoint,
        vault: ref.watch(vaultProvider),
      );
    });
