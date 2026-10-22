import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shuaqi/domain/app/setting_keys.dart';
import 'package:shuaqi/domain/ink/ink_tool.dart';
import 'package:shuaqi/infra/db/dao/setting_dao.dart';
import 'package:shuaqi/state/app_providers.dart';

/// 当前工具（T2.2 三支笔 + T2.3 橡皮）。
///
/// 语义（写死在这里，避免以后各页各自解释）：
/// - 只影响**之后**落下的笔；已落笔的笔保留自己的 style（笔迹是事实，不许被工具改动）；
/// - 全局唯一一份，不分卷：刷题时换一支笔，不该因为切换到另一份卷子又忘掉；
/// - 落盘 `setting` 键 [AppSettingKeys.inkBrush]，读失败/取值非法一律回落钢笔。
///
/// 注意：**不要在 provider getter 里做 IO**（INV-01 的同类规则）。
/// 载入是 `build()` 里发起的一次异步任务，失败静默——工具读不出来不该阻断书写。
final NotifierProvider<InkToolController, InkTool> inkToolProvider =
    NotifierProvider<InkToolController, InkTool>(InkToolController.new);

class InkToolController extends Notifier<InkTool> {
  bool _loaded = false;

  @override
  InkTool build() {
    if (!_loaded) {
      _loaded = true;
      unawaited(_restore());
    }
    return InkTool.pen;
  }

  /// 选中一个工具。同步改状态（UI 立即高亮），落盘异步。
  void select(InkTool tool) {
    if (state == tool) {
      return;
    }
    state = tool;
    unawaited(_persist(tool));
  }

  Future<void> _restore() async {
    try {
      final SettingDao dao = SettingDao(ref.read(appDependenciesProvider).db.raw);
      final String? raw = await dao.get(AppSettingKeys.inkBrush);
      if (!ref.mounted || raw == null) {
        return;
      }
      // 旧版本只存过 pen/ballpoint/highlighter，byName 对未知值回落钢笔，无需迁移。
      final InkTool parsed = InkTool.byName(raw);
      if (parsed == state) {
        return;
      }
      state = parsed;
    } on Object {
      // 读设置失败 → 保持钢笔。工具是最不重要的状态，绝不值得抛给用户。
    }
  }

  Future<void> _persist(InkTool tool) async {
    try {
      final SettingDao dao = SettingDao(ref.read(appDependenciesProvider).db.raw);
      await dao.put(AppSettingKeys.inkBrush, tool.name);
    } on Object {
      // 写失败只影响"下次启动的默认工具"，不影响本次书写。
    }
  }
}
