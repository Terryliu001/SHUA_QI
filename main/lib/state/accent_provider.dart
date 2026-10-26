import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shuaqi/domain/app/accent.dart';
import 'package:shuaqi/domain/app/setting_keys.dart';
import 'package:shuaqi/infra/db/dao/setting_dao.dart';
import 'package:shuaqi/state/app_providers.dart';

/// 色系（强调色）的持久化入口，和 [themeModeProvider] 对称。
///
/// 为什么不并进主题 provider：主题是"深浅 + 色系"两个正交维度，
/// 合成一个枚举会变成 `lightBlue / darkBlue / lightTeal …` 的笛卡尔积，
/// 加一个色系要写两遍。
///
/// 默认 [ShqAccent.azure]：与 2026-10-24 定稿的观感一致，老用户升级后
/// 界面不该有任何变化。
final NotifierProvider<AccentController, ShqAccent> accentProvider =
    NotifierProvider<AccentController, ShqAccent>(AccentController.new);

class AccentController extends Notifier<ShqAccent> {
  late final SettingDao _dao;

  @override
  ShqAccent build() {
    _dao = SettingDao(ref.watch(appDependenciesProvider).db.raw);
    unawaited(_load());
    return ShqAccent.azure;
  }

  Future<void> _load() async {
    state = ShqAccentCodec.decode(await _dao.get(AppSettingKeys.uiAccent));
  }

  /// 切换色系：先改内存（`MaterialApp` 的 `AnimatedTheme` 会自己补一段
  /// 200ms 的颜色过渡），再落盘。落盘失败不回滚——一条外观偏好丢了，
  /// 下次启动回到靛蓝，可接受。
  Future<void> set(ShqAccent accent) async {
    if (accent == state) {
      return;
    }
    state = accent;
    await _dao.put(AppSettingKeys.uiAccent, ShqAccentCodec.encode(accent));
  }
}
