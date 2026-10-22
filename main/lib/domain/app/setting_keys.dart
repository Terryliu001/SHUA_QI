/// App 级 setting 键名（§5.3A 之外的键，键名同样是稳定契约，改名等于丢用户数据）。
///
/// 与 [ReaderSettingKeys]（reader.* 前缀，阅读偏好专用）分开：
/// 一个是"这一卷怎么读"，一个是"这个 app 怎么打扮"。
abstract final class AppSettingKeys {
  /// 主题模式：`system` / `light` / `dark`（对应 Material 的 ThemeMode.name）。
  /// 缺失 = 跟随系统。
  static const String themeMode = 'app.theme_mode';

  /// 上次用的笔刷：`pen` / `ballpoint` / `highlighter`（对应 InkStrokeStyle.name）。
  /// 缺失 = 钢笔。只影响**之后**画的笔，不改已落笔的（T2.2）。
  static const String inkBrush = 'ink.default_brush';
}
