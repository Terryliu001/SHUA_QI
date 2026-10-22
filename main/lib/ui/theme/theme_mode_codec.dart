import 'package:flutter/material.dart';

/// 主题模式 ↔ setting 字符串的编解码（纯函数，可单测）。
///
/// 为什么放 `ui/theme` 而不是 `domain`：`ThemeMode` 是 Material 的枚举，
/// domain 禁止 import Flutter；而这里只有"字符串 ↔ 枚举"的映射，没有状态。
///
/// 键名在 `domain/app/setting_keys.dart`（[AppSettingKeys.themeMode]）。
abstract final class ThemeModeCodec {
  /// 解析设置值。**任何非法值回落 [ThemeMode.system]**——
  /// 与 ReaderPrefs 同一哲学：一条被手改坏的设置不该让 app 起不来。
  static ThemeMode decode(String? raw) {
    for (final ThemeMode mode in ThemeMode.values) {
      if (mode.name == raw) {
        return mode;
      }
    }
    return ThemeMode.system;
  }

  /// `ThemeMode.name` 正好就是 system / light / dark，直接可用。
  static String encode(ThemeMode mode) => mode.name;
}
