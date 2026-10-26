/// 可编辑的题目区域（纯 Dart）。
///
/// 它是"自动结果 + 用户修改"叠加之后的样子，也是 UI 与落库的唯一形状：
/// - [slices] 可以有多段（跨页题）；
/// - [deleted] 表示用户删掉了（**不真删**，重切后仍能按 anchor 重新对上）；
/// - [locked] 表示固定，重切时不参与自动结果覆盖（T3.4）；
/// - [userAdded] 表示这道题是用户手画的，自动结果里没有它。
///
/// ## 为什么要有 [key]
/// 用户修改要跨"重新切题"活下来，而重切后 `ordinal` 可能整体位移（多切/少切一道题），
/// 拿序号当身份一定错位。所以身份用 **anchor**：题号 + 起始页 + 起始 y。
/// 重切后按 anchor 精确匹配；匹配不上再按「同题号 + 同页 + y 差 ≤80pt」模糊匹配；
/// 还匹配不上就认为这条修改"悬空"（保留在文件里、不生效），**绝不删用户数据**。
library;

import 'dart:math' as math;

import 'package:shuaqi/domain/region/region_rect.dart';
import 'package:shuaqi/domain/region/split.dart';

/// 一道可编辑的题。
class EditedQuestion {
  const EditedQuestion({
    required this.key,
    required this.ordinal,
    required this.label,
    required this.level,
    required this.kind,
    required this.stem,
    required this.confidence,
    required this.slices,
    this.locked = false,
    this.deleted = false,
    this.userAdded = false,
    this.parentOrdinal,
  });

  /// 由自动切题结果构造。[key] 用 anchor 生成，保证同一份卷子重切后仍能对上。
  factory EditedQuestion.fromDraft(RegionDraft draft) => EditedQuestion(
    key: regionKeyOf(draft.label, draft.slices),
    ordinal: draft.ordinal,
    label: draft.label,
    level: draft.level,
    kind: draft.kind,
    stem: draft.stem,
    confidence: draft.confidence,
    slices: draft.slices,
    locked: false,
    parentOrdinal: draft.parentOrdinal,
  );

  /// 身份：`题号|起始页|起始y`。
  final String key;

  final int ordinal;
  final String label;
  final int level;
  final String kind;
  final String stem;
  final double confidence;
  final List<PageSlice> slices;
  final bool locked;
  final bool deleted;
  final bool userAdded;

  /// 所属大题的 ordinal（小题才有）。分段/合并都不会改变从属关系，
  /// 所以这里原样带过来，切题重放时 parent_id 才不会丢。
  final int? parentOrdinal;

  bool get hasRegion => slices.isNotEmpty;

  /// 起始页（没有分段时为 -1）。
  int get firstPage => slices.isEmpty ? -1 : slices.first.pageIndex;

  double get firstY => slices.isEmpty ? 0 : slices.first.rect.top;

  EditedQuestion copyWith({
    int? ordinal,
    String? label,
    int? level,
    String? kind,
    String? stem,
    double? confidence,
    List<PageSlice>? slices,
    bool? locked,
    bool? deleted,
    bool? userAdded,
    int? parentOrdinal,
  }) => EditedQuestion(
    key: key,
    ordinal: ordinal ?? this.ordinal,
    label: label ?? this.label,
    level: level ?? this.level,
    kind: kind ?? this.kind,
    stem: stem ?? this.stem,
    confidence: confidence ?? this.confidence,
    slices: slices ?? this.slices,
    locked: locked ?? this.locked,
    deleted: deleted ?? this.deleted,
    userAdded: userAdded ?? this.userAdded,
    parentOrdinal: parentOrdinal ?? this.parentOrdinal,
  );

  @override
  String toString() =>
      'EditedQuestion($key ${deleted ? 'deleted' : ''} ${locked ? 'locked' : ''} '
      '${slices.length} 段)';
}

/// 由题号与分段生成 anchor key。
String regionKeyOf(String label, List<PageSlice> slices) {
  if (slices.isEmpty) {
    return anchorKey(label, -1, 0);
  }
  return anchorKey(label, slices.first.pageIndex, slices.first.rect.top);
}

/// anchor key 的唯一构造入口（`题号|起始页|起始y`）。
///
/// UI 侧（`QuestionBundle`）与覆盖层（`EditedQuestion`）必须用同一套规则算 key，
/// 否则"选中一个框"会对不上"改这一条操作"。所以都走这里。
String anchorKey(String label, int page, double y) =>
    page < 0 ? '$label|none|0' : '$label|$page|${y.round()}';

/// 题号归一（去掉空白，避免 `12.` 与 ` 12.` 被当成两个 anchor）。
String normalizeLabel(String label) => label.replaceAll(RegExp(r'\s+'), '');

/// anchor 精确/模糊匹配用的比较键。
String anchorLabel(String key) {
  final int bar = key.indexOf('|');
  return bar < 0 ? key : key.substring(0, bar);
}

int anchorPage(String key) {
  final List<String> parts = key.split('|');
  if (parts.length < 2) {
    return -1;
  }
  return int.tryParse(parts[1]) ?? -1;
}

double anchorY(String key) {
  final List<String> parts = key.split('|');
  if (parts.length < 3) {
    return 0;
  }
  return double.tryParse(parts[2]) ?? 0;
}

/// 把矩形收进页面范围内（编辑时不允许拖出纸外）。
RegionRect clampRect(
  RegionRect rect, {
  required double pageWidth,
  required double pageHeight,
  double minSize = 12,
}) {
  final double width = rect.width.clamp(minSize, math.max(minSize, pageWidth));
  final double height = rect.height.clamp(
    minSize,
    math.max(minSize, pageHeight),
  );
  final double left = rect.left.clamp(0, math.max(0, pageWidth - width));
  final double top = rect.top.clamp(0, math.max(0, pageHeight - height));
  return RegionRect(left: left, top: top, width: width, height: height);
}
