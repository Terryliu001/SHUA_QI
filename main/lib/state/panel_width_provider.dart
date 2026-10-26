import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shuaqi/app/bootstrap.dart';
import 'package:shuaqi/app/reader/panel_width_store.dart';
import 'package:shuaqi/infra/db/dao/setting_dao.dart';
import 'package:shuaqi/state/app_providers.dart';

/// 右侧面板宽度的全局状态（2026-10-24 用户要求：可左右拖，最大 1/2 屏，跨卷记住）。
///
/// - `null` = 还没读到偏好 → 调用方用 [PanelMetrics.defaultFor] 兜底；
/// - 拖动过程用 [preview]，**不落盘**（每帧写 DB 毫无意义）；
/// - 松手用 [commit]，写状态 + 异步落盘一次；
/// - 收敛（min/max）不在这里做：屏幕宽度只有 UI 知道，见 `PanelMetrics.clampWidth`。
final Provider<PanelWidthStore> panelWidthStoreProvider =
    Provider<PanelWidthStore>((Ref ref) {
      final AppDependencies deps = ref.watch(appDependenciesProvider);
      return PanelWidthStore(SettingDao(deps.db.raw));
    });

final NotifierProvider<PanelWidthController, double?> panelWidthProvider =
    NotifierProvider<PanelWidthController, double?>(PanelWidthController.new);

class PanelWidthController extends Notifier<double?> {
  bool _loaded = false;

  @override
  double? build() {
    if (!_loaded) {
      _loaded = true;
      unawaited(_restore());
    }
    return null;
  }

  /// 拖动中：只改内存状态，让面板即时跟随。
  void preview(double width) {
    state = width;
  }

  /// 松手：记住它。写盘失败不影响本次使用（下次回落默认宽度）。
  void commit(double width) {
    state = width;
    unawaited(_persist(width));
  }

  Future<void> _restore() async {
    try {
      final double? stored = await ref.read(panelWidthStoreProvider).load();
      if (stored != null) {
        state = stored;
      }
    } on Object {
      // 读不到就用默认宽度，不打扰用户。
    }
  }

  Future<void> _persist(double width) async {
    try {
      await ref.read(panelWidthStoreProvider).save(width);
    } on Object {
      // 同上：界面偏好写不进去不值得报错。
    }
  }
}
