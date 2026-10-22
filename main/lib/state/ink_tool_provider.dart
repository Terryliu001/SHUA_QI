import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shuaqi/domain/app/setting_keys.dart';
import 'package:shuaqi/domain/ink/ink_doc.dart';
import 'package:shuaqi/infra/db/dao/setting_dao.dart';
import 'package:shuaqi/state/app_providers.dart';

/// 当前笔刷（T2.2）。
///
/// 语义（写死在这里，避免以后各页各自解释）：
/// - 只影响**之后**画的新笔；已落笔的笔保留自己的 style（笔迹是事实，不许被工具改动）；
/// - 全局唯一一份，不分卷：刷题时换一支笔，不该因为切换到另一份卷子又忘掉；
/// - 落盘 `setting` 键 [AppSettingKeys.inkBrush]，读失败/取值非法一律回落钢笔。
///
/// 注意：**不要在 provider getter 里做 IO**（INV-01 的同类规则）。
/// 载入是 `build()` 里发起的一次异步任务，失败静默——笔刷读不出来不该阻断书写。
final NotifierProvider<InkToolController, InkStrokeStyle> inkToolProvider =
    NotifierProvider<InkToolController, InkStrokeStyle>(
      InkToolController.new,
    );

class InkToolController extends Notifier<InkStrokeStyle> {
  bool _loaded = false;

  @override
  InkStrokeStyle build() {
    if (!_loaded) {
      _loaded = true;
      unawaited(_restore());
    }
    return InkStrokeStyle.pen;
  }

  /// 选中一支笔。同步改状态（UI 立即高亮），落盘异步。
  void select(InkStrokeStyle style) {
    if (state == style) {
      return;
    }
    state = style;
    unawaited(_persist(style));
  }

  Future<void> _restore() async {
    try {
      final SettingDao dao = SettingDao(ref.read(appDependenciesProvider).db.raw);
      final String? raw = await dao.get(AppSettingKeys.inkBrush);
      final InkStrokeStyle? parsed = _byName(raw);
      if (!ref.mounted || parsed == null || parsed == state) {
        return;
      }
      state = parsed;
    } on Object {
      // 读设置失败 → 保持钢笔。笔刷是最不重要的状态，绝不值得抛给用户。
    }
  }

  Future<void> _persist(InkStrokeStyle style) async {
    try {
      final SettingDao dao = SettingDao(ref.read(appDependenciesProvider).db.raw);
      await dao.put(AppSettingKeys.inkBrush, style.name);
    } on Object {
      // 写失败只影响"下次启动的默认笔刷"，不影响本次书写。
    }
  }

  static InkStrokeStyle? _byName(String? raw) {
    if (raw == null) {
      return null;
    }
    for (final InkStrokeStyle style in InkStrokeStyle.values) {
      if (style.name == raw) {
        return style;
      }
    }
    return null;
  }
}
