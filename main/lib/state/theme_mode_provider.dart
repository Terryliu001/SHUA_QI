import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shuaqi/domain/app/setting_keys.dart';
import 'package:shuaqi/infra/db/dao/setting_dao.dart';
import 'package:shuaqi/state/app_providers.dart';
import 'package:shuaqi/ui/theme/theme_mode_codec.dart';

/// 主题模式的持久化入口（T6.1 设置页的第一块真实功能）。
///
/// 从 `ui/app.dart` 挪来 `state/`：它原来恒返回 `ThemeMode.system`，
/// 现在要读/写 setting 表，与 readerPrefs 对称。`ThemeMode` 虽是 Material
/// 概念，但"用户选的主题"是应用状态，不是某个页面的私有状态。
///
/// 用 `Notifier`（Riverpod 3 已移除 StateNotifier）：初值同步给 UI
/// （不能闪一下 system 再跳），加载是异步的——`build()` 返回 system，
/// 加载完静默替换。
final NotifierProvider<ThemeModeController, ThemeMode> themeModeProvider =
    NotifierProvider<ThemeModeController, ThemeMode>(ThemeModeController.new);

class ThemeModeController extends Notifier<ThemeMode> {
  late final SettingDao _dao;

  @override
  ThemeMode build() {
    // 依赖在 build 里取（watch 只允许在这里），之后的方法用同一份
    _dao = SettingDao(ref.watch(appDependenciesProvider).db.raw);
    unawaited(_load());
    return ThemeMode.system;
  }

  Future<void> _load() async {
    state = ThemeModeCodec.decode(await _dao.get(AppSettingKeys.themeMode));
  }

  /// 切换主题。先改内存（UI 立即响应），再落盘；落盘失败不回滚
  /// （一条主题设置丢了下次重启恢复 system，可接受）。
  Future<void> set(ThemeMode mode) async {
    if (mode == state) {
      return;
    }
    state = mode;
    await _dao.put(AppSettingKeys.themeMode, ThemeModeCodec.encode(mode));
  }
}
