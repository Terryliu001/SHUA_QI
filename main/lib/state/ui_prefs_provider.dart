import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shuaqi/domain/app/setting_keys.dart';
import 'package:shuaqi/infra/db/dao/setting_dao.dart';
import 'package:shuaqi/state/app_providers.dart';

/// **文字模式**：顶栏/工具栏的图标旁显示功能文字。
///
/// 为什么是全局开关而不是每个页面各自设置：
/// 用户提这条需求时的场景是"看得懂每个图标干什么"，那是**一次性的界面密度决定**，
/// 分页面设置只会出现"阅读器有字、答题卡没字"的割裂。
///
/// 默认关：平板上顶栏本来就有 Tooltip，图标是既有设计语言的一部分。
final NotifierProvider<IconLabelsController, bool> iconLabelsProvider =
    NotifierProvider<IconLabelsController, bool>(IconLabelsController.new);

class IconLabelsController extends Notifier<bool> {
  late final SettingDao _dao;

  @override
  bool build() {
    _dao = SettingDao(ref.watch(appDependenciesProvider).db.raw);
    unawaited(_load());
    return false;
  }

  Future<void> _load() async {
    state = (await _dao.get(AppSettingKeys.uiIconLabels)) == '1';
  }

  Future<void> set(bool value) async {
    if (value == state) {
      return;
    }
    state = value;
    await _dao.put(AppSettingKeys.uiIconLabels, value ? '1' : '0');
  }
}

/// **开发者选项**是否解锁（版本号连点 8 次）。
///
/// 默认不解锁：开发者选项里有调试开关，普通用户点进去只会困惑。
/// 解锁状态落库，**不因重启消失**——否则每次想开都要连点 8 次，很蠢。
final NotifierProvider<DevOptionsController, bool> devOptionsUnlockedProvider =
    NotifierProvider<DevOptionsController, bool>(DevOptionsController.new);

class DevOptionsController extends Notifier<bool> {
  late final SettingDao _dao;

  @override
  bool build() {
    _dao = SettingDao(ref.watch(appDependenciesProvider).db.raw);
    unawaited(_load());
    return false;
  }

  Future<void> _load() async {
    state = (await _dao.get(AppSettingKeys.devOptionsUnlocked)) == '1';
  }

  Future<void> unlock() => set(true);

  Future<void> set(bool value) async {
    if (value == state) {
      return;
    }
    state = value;
    await _dao.put(AppSettingKeys.devOptionsUnlocked, value ? '1' : '0');
  }
}

/// 解锁需要连点几次（用户 2026-10-26 第 17 条：8 次）。
const int kDevUnlockTaps = 8;

/// 从第几次开始给提示（避免用户以为点坏了）。
const int kDevUnlockHintFrom = 5;
