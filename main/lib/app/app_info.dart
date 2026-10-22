/// App 身份信息（设置页「关于」用）。
///
/// [version] 与 `pubspec.yaml` 的 `version:` 保持一致（`0.1.0+1` 的 `+1` 是
/// buildNumber，给 Android versionCode 用，界面不显示）。**没有引
/// package_info_plus**（不在白名单）——一个常量 + 一条注释比一个插件便宜。
abstract final class AppInfo {
  static const String name = '刷起 SHUAQI';

  /// 改版本时同步改 `pubspec.yaml` 的 `version:`（见文件头注释）。
  static const String version = '0.1.0';

  static const String tagline = '导入一份 PDF 试卷，就能像在纸上一样写';
}
