import 'package:shuaqi/domain/reader/reader_prefs.dart';
import 'package:shuaqi/infra/db/dao/setting_dao.dart';

/// 阅读偏好的读写编排（T1.6 接线，设置页 T6.1 之后补全局默认的写入口）。
///
/// 2026-10-24 第二轮（用户第 6 条）**改掉了"按卷记忆"**：
/// 以前每次切换分页/滚动、手势、纸样式都写 `reader.view.<workbookId>`，
/// 打开同一份卷会回到上次的样子、换一份卷又是另一套——这和"阅读器是同一个工具"
/// 的设计理念相悖。现在：
///
/// - 只有**一份全局偏好**（`reader.default_*` 四条），所有卷共用；
/// - 旧的 `reader.view.<id>` 不再读取（用户选的"直接忽略"），也不删除
///   （留着不影响任何逻辑，删了反而多一次迁移风险）。
///
/// 防抖仍在 UI 层（每次交互攒 500ms 再写），store 里不藏 Timer。
class ReaderPrefsStore {
  ReaderPrefsStore(this._dao);

  final SettingDao _dao;

  /// 读全局偏好。参数保留只是为了不动调用方签名，**不再读单卷覆盖**。
  Future<ReaderPrefs> load(String workbookId) => loadDefaults();

  /// 全局默认（`reader.default_*`）。缺失逐键回落 [ReaderPrefs.defaults]。
  Future<ReaderPrefs> loadDefaults() async {
    final String? mode = await _dao.get(ReaderSettingKeys.defaultMode);
    final String? style = await _dao.get(ReaderSettingKeys.defaultPaperStyle);
    final String? intensity = await _dao.get(
      ReaderSettingKeys.defaultIntensity,
    );
    final String? hand = await _dao.get(ReaderSettingKeys.defaultHand);
    final int? parsedIntensity = intensity == null
        ? null
        : int.tryParse(intensity);
    return ReaderPrefs.fromJson(<String, Object?>{
      'mode': ?mode,
      'style': ?style,
      'intensity': ?parsedIntensity,
      'hand': hand == null ? null : hand == '1',
    });
  }

  /// 写回全局偏好（阅读器里任何一次切换都会走到这里）。
  Future<void> save(String workbookId, ReaderPrefs prefs) =>
      saveDefaults(prefs);

  /// 写全局默认（设置页 / 阅读器共用同一条）。
  Future<void> saveDefaults(ReaderPrefs prefs) async {
    final ReaderPrefs clamped = prefs.clamp();
    await _dao.put(ReaderSettingKeys.defaultMode, clamped.mode.name);
    await _dao.put(ReaderSettingKeys.defaultPaperStyle, clamped.style.name);
    await _dao.put(ReaderSettingKeys.defaultIntensity, '${clamped.intensity}');
    await _dao.put(ReaderSettingKeys.defaultHand, clamped.handTool ? '1' : '0');
  }
}
