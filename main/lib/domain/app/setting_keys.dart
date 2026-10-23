/// App 级 setting 键名（§5.3A 之外的键，键名同样是稳定契约，改名等于丢用户数据）。
///
/// 与 [ReaderSettingKeys]（reader.* 前缀，阅读偏好专用）分开：
/// 一个是"这一卷怎么读"，一个是"这个 app 怎么打扮"。
abstract final class AppSettingKeys {
  /// 主题模式：`system` / `light` / `dark`（对应 Material 的 ThemeMode.name）。
  /// 缺失 = 跟随系统。
  static const String themeMode = 'app.theme_mode';

  /// 上次用的工具：`pen` / `ballpoint` / `highlighter` / `eraser`（对应 InkTool.name）。
  /// 缺失 = 钢笔。只影响**之后**落下的笔，不改已落笔的（T2.2/T2.3）。
  /// 旧版本只存过前三者，读取时未知值一律回落钢笔，不需要数据迁移。
  ///
  /// 2026-10-23 起值格式变为 `tool:color:width;...`（见 `InkBrush.encodeAll`），
  /// 每支笔分别记住颜色与粗细；旧格式会被识别成"只有工具"并回落默认色/粗细。
  static const String inkBrush = 'ink.default_brush';

  /// 笔刷工具条形态：`true` = 固定到顶栏下方；其余 = 右下角圆形浮钮（默认）。
  static const String inkToolbarPinned = 'ink.toolbar_pinned';
}
