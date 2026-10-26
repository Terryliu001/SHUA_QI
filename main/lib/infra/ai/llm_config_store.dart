import 'package:shuaqi/domain/ai/llm_config.dart';
import 'package:shuaqi/domain/app/setting_keys.dart';
import 'package:shuaqi/infra/db/dao/setting_dao.dart';

/// LLM 配置的读写编排。
///
/// 当前把 Key 也存在 `setting` 表（App 私有目录，零新增依赖）。
/// 为什么可以接受：
/// - 不进日志、不进导出/备份（本轮还没有导出）、不上报；
/// - 设置页回显时只给末 4 位，输入框留空表示"不修改"；
/// - 将来换 Keystore 时只改 [load]/[save] 里的 `aiApiKey` 读写，调用方不动。
///
/// 换安全存储时要做的迁移：读旧键 → 写 Keystore → 删除旧键。
class LlmConfigStore {
  const LlmConfigStore(this._dao);

  final SettingDao _dao;

  Future<LlmConfig> load() async {
    final String? baseUrl = await _dao.get(AppSettingKeys.aiBaseUrl);
    final String? apiKey = await _dao.get(AppSettingKeys.aiApiKey);
    final String? model = await _dao.get(AppSettingKeys.aiModel);
    final String? allow = await _dao.get(AppSettingKeys.aiAllowImages);
    final String? timeout = await _dao.get(AppSettingKeys.aiTimeoutSeconds);
    final int? seconds = timeout == null ? null : int.tryParse(timeout);
    return LlmConfig(
      baseUrl: baseUrl ?? '',
      apiKey: apiKey ?? '',
      model: model ?? '',
      allowImages: allow == null ? true : allow == '1',
      timeout: Duration(
        seconds: (seconds ?? LlmConfig.defaultTimeout.inSeconds).clamp(5, 300),
      ),
    ).normalized();
  }

  Future<void> save(LlmConfig config) async {
    final LlmConfig value = config.normalized();
    await _dao.put(AppSettingKeys.aiBaseUrl, value.baseUrl);
    await _dao.put(AppSettingKeys.aiApiKey, value.apiKey);
    await _dao.put(AppSettingKeys.aiModel, value.model);
    await _dao.put(AppSettingKeys.aiAllowImages, value.allowImages ? '1' : '0');
    await _dao.put(
      AppSettingKeys.aiTimeoutSeconds,
      '${value.timeout.inSeconds}',
    );
  }

  /// 清空全部 AI 配置（含 Key）。设置页"清除配置"用。
  Future<void> clear() async {
    for (final String key in <String>[
      AppSettingKeys.aiBaseUrl,
      AppSettingKeys.aiApiKey,
      AppSettingKeys.aiModel,
      AppSettingKeys.aiAllowImages,
      AppSettingKeys.aiTimeoutSeconds,
    ]) {
      await _dao.remove(key);
    }
  }
}
