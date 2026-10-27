import 'package:flutter/material.dart';

/// 对题目框的**显式操作**（2026-10-23 用户拍板：点中框就应该能改它）。
///
/// 拖动与缩放是手势，不在这里；这里只列"点一下就能执行"的动作。
/// 它们同时出现在三个入口：贴框的浮动条、右侧面板的选中条目、长按菜单。
/// 三个入口共用一个枚举，是为了**文案与图标只有一份**——否则同一个功能
/// 在三处出现三种叫法，用户会以为它们是三件不同的事。
enum RegionAction {
  /// 从框中切开（上下两道题）。
  split,

  /// 并入上一题。
  merge,

  /// 延伸到下一页（跨页题补一段）。
  extend,

  /// 锁定 / 解锁：锁定后重新切题不会覆盖它。
  lock,

  /// 改题号（扫描件认不出数字时，用户手填）。
  rename,

  /// 删除这个框。
  delete,

  /// 把这一块**认作题目**（2026-10-24 用户第 10 条；2026-10-27 修正语义）。
  ///
  /// 两种入口，语义不同：
  /// - 虚线框（level 1 = "不确定/容器"）：**就地确认** —— 题号、面板位置、
  ///   题目 id 都不变，只把虚线变实线（`ConfirmQuestionCorrection`）；
  /// - 实线题：在本题下方**插入一道新题**（题号接在现有最大号之后），
  ///   用于"切题把两道题并成一条"时从中间加一道回去。
  ///
  /// 2026-10-27 之前的实现把第一种也做成了"新建 + 删掉原框"，
  /// 于是题号被改掉、面板位置也变了 —— 已被用户指出并修正。
  addQuestion,
}

/// 贴框浮动条上的动作：题号（改名）、并入上题、删除。
///
/// 2026-10-23 用户反馈后加"并入上题"：扫描件把解析步骤 `(1)(2)` 切成独立题时，
/// 一键并回题干是最高频的修复动作；其余动作仍在长按菜单里。
const List<RegionAction> kRegionBarActions = <RegionAction>[
  RegionAction.merge,
  RegionAction.rename,
  RegionAction.delete,
];

extension RegionActionSpec on RegionAction {
  String get label => switch (this) {
    RegionAction.split => '切开',
    RegionAction.merge => '并入上题',
    RegionAction.extend => '跨页',
    RegionAction.lock => '锁定',
    RegionAction.rename => '改题号',
    RegionAction.delete => '删除',
    RegionAction.addQuestion => '加题',
  };

  /// 长按菜单用的完整说法（浮动条上空间小，用短标签）。
  String get menuLabel => switch (this) {
    RegionAction.split => '从框中切开',
    RegionAction.merge => '并入上一题',
    RegionAction.extend => '延伸到下一页',
    RegionAction.lock => '锁定',
    RegionAction.rename => '改题号',
    RegionAction.delete => '删除这个框',
    RegionAction.addQuestion => '把这一块加为题目',
  };

  IconData get icon => switch (this) {
    RegionAction.split => Icons.content_cut,
    RegionAction.merge => Icons.merge_type,
    RegionAction.extend => Icons.vertical_align_bottom,
    RegionAction.lock => Icons.lock_outline,
    RegionAction.rename => Icons.edit_outlined,
    RegionAction.delete => Icons.delete_outline,
    RegionAction.addQuestion => Icons.add_box_outlined,
  };

  bool get destructive => this == RegionAction.delete;
}

/// 锁定是一个开关：框已锁时文案/图标要变成"解锁"。
/// **锁定**之后这道题还允许做什么（2026-10-26 用户第 18 条）。
///
/// 锁定原来的语义只是"重新切题不覆盖它"，用户以为锁了框就不能动。
/// 现在门禁做实：只剩「解锁」与「改题号」——改题号不动框，所以放行；
/// 拖框 / 切开 / 并入 / 跨页 / 加题 / 删除全部要解锁才能做。
///
/// 抽成函数是为了能单测（页面里的私有方法测不到）。
Set<RegionAction> allowedActionsWhenLocked() => <RegionAction>{
  RegionAction.lock,
  RegionAction.rename,
};

String regionActionLabel(RegionAction action, {required bool locked}) =>
    action == RegionAction.lock && locked ? '解锁' : action.label;

IconData regionActionIcon(RegionAction action, {required bool locked}) =>
    action == RegionAction.lock && locked ? Icons.lock_open : action.icon;
