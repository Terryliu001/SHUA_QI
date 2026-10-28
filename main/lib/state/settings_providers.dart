import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shuaqi/app/app_info.dart';
import 'package:shuaqi/app/backup/backup_library.dart';
import 'package:shuaqi/app/backup/backup_service.dart';
import 'package:shuaqi/app/feedback/feedback_config.dart';
import 'package:shuaqi/app/feedback/feedback_outbox.dart';
import 'package:shuaqi/app/feedback/github_feedback_gateway.dart';
import 'package:shuaqi/app/feedback/http_feedback_gateway.dart';
import 'package:shuaqi/app/storage/cache_service.dart';
import 'package:shuaqi/domain/feedback/feedback.dart';
import 'package:shuaqi/infra/platform/media_store_channel.dart';
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

/// 原生媒体库通道（备份文件列表/重命名/删除/导入、打开外链）。
final Provider<MediaStoreChannel> mediaStoreChannelProvider =
    Provider<MediaStoreChannel>((Ref ref) => const MediaStoreChannel());

/// 备份文件管理（下载目录里本应用创建的 zip）。
final Provider<BackupLibrary> backupLibraryProvider = Provider<BackupLibrary>(
  (Ref ref) => BackupLibrary(ref.watch(mediaStoreChannelProvider)),
);

/// 编译期反馈通道配置（`--dart-define=...`）。
final Provider<FeedbackRemoteConfig> feedbackRemoteConfigProvider =
    Provider<FeedbackRemoteConfig>(
      (Ref ref) => FeedbackRemoteConfig.fromEnvironment(),
    );

/// 远端通道实现；null = 没配（只落本机草稿箱，界面明说没发出去）。
///
/// 优先级：GitHub 私有仓库 > 自建 HTTP 端点。两者都不配时不返回
/// [LocalFeedbackGateway] 之类的"假网关"——本地落盘由 [FeedbackOutbox] 负责，
/// 不再多一层会写重复草稿的实现。
final Provider<FeedbackGateway?> feedbackRemoteGatewayProvider =
    Provider<FeedbackGateway?>((Ref ref) {
      final FeedbackRemoteConfig config = ref.watch(
        feedbackRemoteConfigProvider,
      );
      if (config.hasGitHub) {
        return GitHubFeedbackGateway(
          token: config.githubToken,
          owner: config.githubOwner,
          repo: config.githubRepo,
          branch: config.githubBranch,
        );
      }
      if (config.hasEndpoint) {
        return HttpFeedbackGateway(endpoint: config.endpoint);
      }
      return null;
    });

/// 反馈草稿箱 + 发送队列（唯一入口：UI 只跟它打交道）。
final Provider<FeedbackOutbox> feedbackOutboxProvider =
    Provider<FeedbackOutbox>(
      (Ref ref) => FeedbackOutbox(
        vault: ref.watch(vaultProvider),
        remote: ref.watch(feedbackRemoteGatewayProvider),
      ),
    );
