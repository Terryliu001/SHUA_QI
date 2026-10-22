import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shuaqi/ui/theme/theme_mode_codec.dart';

/// 主题模式编解码（纯函数，宿主机秒级）。
///
/// 覆盖点：三个合法值、null / 空串 / 非法值都回落 system
/// （坏设置不能让 app 起不来，与 ReaderPrefs 同一哲学）。
void main() {
  test('合法值解析', () {
    expect(ThemeModeCodec.decode('system'), ThemeMode.system);
    expect(ThemeModeCodec.decode('light'), ThemeMode.light);
    expect(ThemeModeCodec.decode('dark'), ThemeMode.dark);
  });

  test('null 回落 system（键还没写过）', () {
    expect(ThemeModeCodec.decode(null), ThemeMode.system);
  });

  test('空串 / 非法值回落 system（设置被手改坏也不能崩）', () {
    expect(ThemeModeCodec.decode(''), ThemeMode.system);
    expect(ThemeModeCodec.decode('DARK'), ThemeMode.system); // 大小写敏感
    expect(ThemeModeCodec.decode('sepia'), ThemeMode.system);
  });

  test('encode 与 decode 互逆', () {
    for (final ThemeMode mode in ThemeMode.values) {
      expect(ThemeModeCodec.decode(ThemeModeCodec.encode(mode)), mode);
    }
  });
}
