import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shuaqi/domain/app/setting_keys.dart';
import 'package:shuaqi/domain/ink/ink_brush.dart';
import 'package:shuaqi/domain/ink/ink_tool.dart';
import 'package:shuaqi/infra/db/dao/setting_dao.dart';
import 'package:shuaqi/state/app_providers.dart';

/// 当前笔（工具 + 颜色 + 粗细）。T2.2/T2.3 → 2026-10-23 起可配色、可调粗细。
///
/// 语义（写死在这里，避免以后各页各自解释）：
/// - 只影响**之后**落下的笔；已落笔的保留自己的 style/color/width（笔迹是事实）；
/// - 全局唯一一份，不分卷：刷题时换一支笔，不该因为切到另一份卷子又忘掉；
/// - **每支笔分别记住自己的颜色与粗细**：钢笔用黑·中、荧光笔用黄·粗，
///   来回切换不该每次都要重选；
/// - 落盘 `setting` 键 [AppSettingKeys.inkBrush]，读失败/非法值一律回落
///   钢笔 + 墨黑 + 中档。
///
/// 注意：**不要在 provider getter 里做 IO**（INV-01 的同类规则）。
/// 载入是 `build()` 里发起的一次异步任务，失败静默——笔读不出来不该阻断书写。
final NotifierProvider<InkToolController, InkBrush> inkToolProvider =
    NotifierProvider<InkToolController, InkBrush>(InkToolController.new);

class InkToolController extends Notifier<InkBrush> {
  bool _loaded = false;

  /// 每支笔各自的颜色/粗细（切换工具时用它恢复）。
  final Map<InkTool, InkBrush> _memory = <InkTool, InkBrush>{};

  /// 上次选中的工具：落盘时一并记住，重启后回到同一支笔。
  InkTool _current = InkTool.pen;

  @override
  InkBrush build() {
    if (!_loaded) {
      _loaded = true;
      unawaited(_restore());
    }
    return const InkBrush();
  }

  /// 选中一个工具。同步改状态（UI 立即高亮），落盘异步。
  void selectTool(InkTool tool) {
    if (state.tool == tool) {
      return;
    }
    _memory[state.tool] = state;
    final InkBrush next = (_memory[tool] ?? state).withTool(tool);
    state = next;
    _current = tool;
    unawaited(_persist());
  }

  /// 选颜色（越界由 [InkBrush.copyWith] 收敛到该工具的颜色数量内）。
  void selectColor(int colorIndex) {
    if (state.colorIndex == colorIndex) {
      return;
    }
    state = state.copyWith(colorIndex: colorIndex);
    _memory[state.tool] = state;
    unawaited(_persist());
  }

  /// 选粗细（0..2）。
  void selectWidth(int widthLevel) {
    if (state.widthLevel == widthLevel) {
      return;
    }
    state = state.copyWith(widthLevel: widthLevel);
    _memory[state.tool] = state;
    unawaited(_persist());
  }

  /// 纸的明暗变了：只影响色块预览（不落盘、不影响已落笔的笔）。
  void setDarkPaper(bool darkPaper) {
    if (state.darkPaper == darkPaper) {
      return;
    }
    state = state.copyWith(darkPaper: darkPaper);
  }

  Future<void> _restore() async {
    try {
      final SettingDao dao = SettingDao(ref.read(appDependenciesProvider).db.raw);
      final String? raw = await dao.get(AppSettingKeys.inkBrush);
      if (!ref.mounted || raw == null) {
        return;
      }
      final Map<InkTool, InkBrush> parsed = InkBrush.decodeAll(raw);
      if (parsed.isEmpty) {
        // 旧格式（"pen" / "ballpoint" / "highlighter"）→ 只恢复工具，颜色粗细用默认。
        final InkTool legacy = InkTool.byName(raw);
        if (legacy != state.tool) {
          state = state.copyWith(tool: legacy);
        }
        return;
      }
      _memory.addAll(parsed);
      // 恢复"上次选中的那支笔"：取它自己的颜色/粗细（解码时已收敛合法）。
      final InkBrush last = parsed[_current] ?? parsed.values.first;
      state = last.copyWith(darkPaper: state.darkPaper);
      _current = last.tool;
    } on Object {
      // 读设置失败 → 保持默认笔。工具是最不重要的状态，绝不值得抛给用户。
    }
  }

  Future<void> _persist() async {
    try {
      final SettingDao dao = SettingDao(ref.read(appDependenciesProvider).db.raw);
      // 顺序固定：选中项放最后，解析回来时它就是"上次用的那支"。
      final List<InkTool> ordered = <InkTool>[
        for (final InkTool tool in InkTool.values)
          if (tool != _current) tool,
        _current,
      ];
      final List<InkBrush> all = <InkBrush>[
        for (final InkTool tool in ordered)
          _memory[tool] ?? const InkBrush().withTool(tool),
      ];
      await dao.put(AppSettingKeys.inkBrush, InkBrush.encodeAll(all));
    } on Object {
      // 写失败只影响"下次启动的默认笔"，不影响本次书写。
    }
  }
}

/// 工具条形态：false = 右下角圆形浮钮（默认），true = 固定到顶栏下方。
///
/// 用户 2026-10-23 拍板"两套都要，设置里可切"：
/// - 浮钮：不占顶栏、阅读区最大；但展开要点一下。
/// - 顶栏：所有工具一屏可见、零展开；代价是顶栏多占 48dp。
final NotifierProvider<InkToolbarModeController, bool> inkToolbarPinnedProvider =
    NotifierProvider<InkToolbarModeController, bool>(
      InkToolbarModeController.new,
    );

class InkToolbarModeController extends Notifier<bool> {
  late final SettingDao _dao;

  @override
  bool build() {
    _dao = SettingDao(ref.watch(appDependenciesProvider).db.raw);
    unawaited(_load());
    return false;
  }

  Future<void> _load() async {
    try {
      final String? raw = await _dao.get(AppSettingKeys.inkToolbarPinned);
      if (!ref.mounted) {
        return;
      }
      state = raw == 'true';
    } on Object {
      // 读失败保持浮钮（默认形态）。
    }
  }

  Future<void> set(bool pinned) async {
    if (state == pinned) {
      return;
    }
    state = pinned;
    try {
      await _dao.put(AppSettingKeys.inkToolbarPinned, pinned ? 'true' : 'false');
    } on Object {
      // 写失败只影响下次启动的形态。
    }
  }
}
