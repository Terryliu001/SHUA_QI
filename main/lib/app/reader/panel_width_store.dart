import 'package:shuaqi/domain/app/setting_keys.dart';
import 'package:shuaqi/infra/db/dao/setting_dao.dart';

/// 右侧面板宽度（全局一条）的落盘。
///
/// 存 `setting` 表而不是 Vault：这是**界面偏好**，跟卷子无关，
/// 换卷/换设备内目录都不该变。键名见 [AppSettingKeys.panelWidth]。
class PanelWidthStore {
  const PanelWidthStore(this._dao);

  final SettingDao _dao;

  /// 没存过、或者存的值坏掉 → null（上层回落默认宽度）。
  Future<double?> load() async {
    final String? raw = await _dao.get(AppSettingKeys.panelWidth);
    if (raw == null) {
      return null;
    }
    final double? value = double.tryParse(raw);
    if (value == null || value <= 0) {
      return null;
    }
    return value;
  }

  Future<void> save(double width) =>
      _dao.put(AppSettingKeys.panelWidth, width.round().toString());
}
