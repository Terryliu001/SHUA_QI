import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shuaqi/app/ai/ai_service.dart';
import 'package:shuaqi/app/ai/chat_store.dart';
import 'package:shuaqi/app/ai/usage_service.dart';
import 'package:shuaqi/app/bootstrap.dart';
import 'package:shuaqi/domain/ai/llm_config.dart';
import 'package:shuaqi/domain/ai/usage.dart';
import 'package:shuaqi/infra/ai/llm_config_store.dart';
import 'package:shuaqi/infra/db/dao/llm_usage_dao.dart';
import 'package:shuaqi/infra/db/dao/setting_dao.dart';
import 'package:shuaqi/state/app_providers.dart';
import 'package:shuaqi/state/region_providers.dart';

/// AI 配置的读写入口。保存后 `ref.invalidate(aiConfigProvider)` 即可刷新界面。
final Provider<LlmConfigStore> llmConfigStoreProvider =
    Provider<LlmConfigStore>((Ref ref) {
      final AppDependencies deps = ref.watch(appDependenciesProvider);
      return LlmConfigStore(SettingDao(deps.db.raw));
    });

/// 当前 AI 配置（设置页与问 AI 面板共用）。
final FutureProvider<LlmConfig> aiConfigProvider = FutureProvider<LlmConfig>((
  Ref ref,
) {
  return ref.watch(llmConfigStoreProvider).load();
});

final Provider<LlmUsageDao> llmUsageDaoProvider = Provider<LlmUsageDao>((
  Ref ref,
) {
  return LlmUsageDao(ref.watch(appDependenciesProvider).db.raw);
});

final Provider<AiUsageService> aiUsageServiceProvider =
    Provider<AiUsageService>((Ref ref) {
      return AiUsageService(
        ref.watch(llmUsageDaoProvider),
        onRecorded: () => ref.invalidate(aiUsageProvider),
      );
    });

/// 设置页的用量快照；打开设置/刷新时 invalidate 即可。
final FutureProvider<AiUsageSnapshot> aiUsageProvider =
    FutureProvider<AiUsageSnapshot>((Ref ref) {
      return ref.watch(aiUsageServiceProvider).load();
    });

/// 每卷一个 AI 服务：持有连接池与客户端，配置变了下一次调用自动换客户端。
final Provider<AiService> Function(String) aiServiceProvider =
    Provider.family<AiService, String>((Ref ref, String workbookId) {
      final AiService service = AiService(
        configStore: ref.watch(llmConfigStoreProvider),
        usage: ref.watch(aiUsageServiceProvider),
      );
      ref.onDispose(service.dispose);
      return service;
    });

/// 设置页"测试连接"专用：不跟任何一卷绑定，也不进阅读器状态。
final Provider<AiService> aiDiagnosticsProvider = Provider<AiService>((
  Ref ref,
) {
  final AiService service = AiService(
    configStore: ref.watch(llmConfigStoreProvider),
    usage: ref.watch(aiUsageServiceProvider),
  );
  ref.onDispose(service.dispose);
  return service;
});

/// 每卷一个对话历史仓库（写入串行，避免两题同时回复时互相覆盖）。
final Provider<AiChatStore> Function(String) aiChatStoreProvider =
    Provider.family<AiChatStore, String>((Ref ref, String workbookId) {
      return AiChatStore(ref.watch(layoutStoreProvider));
    });
