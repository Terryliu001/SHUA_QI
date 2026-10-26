/// 组卷成员编排的纯函数（可单测，不碰 DB / 文件）。
///
/// 「加入组卷」会遇到三种输入：已是成员、重复点选、多选批量。规则定在这里，
/// UI 只负责收集 id，DAO 只负责按 plan 的顺序写入——顺序（sort）是卷内题序，
/// 也是「连刷」的题序，必须稳定可复现。
library;

import 'package:shuaqi/domain/model/favorite.dart';

/// 追加成员时的最终顺序：已有序原样保留，新成员按 [incoming] 首次出现顺序追加。
///
/// 去重规则：同一 id 只留第一次（先到先得，位置在已有段或新段都成立）。
List<String> planSetAppend({
  required List<String> existing,
  required Iterable<String> incoming,
}) {
  final Set<String> seen = <String>{...existing};
  final List<String> out = <String>[...existing];
  for (final String id in incoming) {
    if (id.isEmpty) {
      continue;
    }
    if (seen.add(id)) {
      out.add(id);
    }
  }
  return out;
}

/// 本次真正新增的成员数（用于给用户一句诚实的反馈：只提示"新增"，不是"共"）。
int countSetAdded({
  required List<String> existing,
  required Iterable<String> incoming,
}) {
  return planSetAppend(existing: existing, incoming: incoming).length -
      existing.length;
}

/// 从组卷里移除若干成员后的顺序（不存在的 id 忽略，不会多删）。
List<String> planSetRemove({
  required List<String> existing,
  required Iterable<String> removing,
}) {
  final Set<String> drop = <String>{
    for (final String id in removing)
      if (id.isNotEmpty) id,
  };
  return <String>[
    for (final String id in existing)
      if (!drop.contains(id)) id,
  ];
}

/// 收藏夹搜索：按组卷名匹配（不区分大小写、忽略首尾空白）。
///
/// 与题目搜索分开：统一的搜索页会先列组卷、再列题目，两边的匹配口径要一致，
/// 但不该把"题目命中"混进组卷结果里。
List<FavoriteSet> searchFavoriteSets(List<FavoriteSet> sets, String query) {
  final String q = query.trim().toLowerCase();
  if (q.isEmpty) {
    return const <FavoriteSet>[];
  }
  return <FavoriteSet>[
    for (final FavoriteSet set in sets)
      if (set.displayName.toLowerCase().contains(q)) set,
  ];
}

/// 这道题是否算"上次归纳之后新增"（AI 归纳弹窗的默认勾选口径）。
///
/// [lastTagAtMs] == 0（从没归纳过）时全算新增；否则只算创建时间更晚的。
bool isNewSinceTag(int createdAtMs, int lastTagAtMs) =>
    lastTagAtMs <= 0 || createdAtMs > lastTagAtMs;

/// 连刷时的当前题号文案：`第 3 / 8 题`；空卷给 `第 0 / 0 题`。
String redoProgressLabel({required int index, required int total}) {
  final int shown = total <= 0 ? 0 : (index + 1).clamp(1, total);
  return '第 $shown / $total 题';
}

/// 组卷卡片副标题：`8 题 · 3 天前更新`。
///
/// [nowMs] 由调用方传入（UTC 毫秒），保证纯函数可测；[atMs] 为 0 时只显示题数。
String setSubtitle({
  required int itemCount,
  required int updatedAtMs,
  required int nowMs,
}) {
  final String count = '$itemCount 题';
  if (updatedAtMs <= 0) {
    return count;
  }
  return '$count · ${relativeDay(updatedAtMs, nowMs)}更新';
}

/// 相对日期：刚刚 / N 分钟前 / N 小时前 / N 天前 / N 个月前。
///
/// 只用于「更新于」这种低频信息，不需要精确到秒；超过一年退化成 N 年前。
String relativeDay(int atMs, int nowMs) {
  final int delta = nowMs - atMs;
  if (delta < 0) {
    return '刚刚';
  }
  const int minute = 60 * 1000;
  const int hour = 60 * minute;
  const int day = 24 * hour;
  if (delta < minute) {
    return '刚刚';
  }
  if (delta < hour) {
    return '${delta ~/ minute} 分钟前';
  }
  if (delta < day) {
    return '${delta ~/ hour} 小时前';
  }
  if (delta < 30 * day) {
    return '${delta ~/ day} 天前';
  }
  if (delta < 365 * day) {
    return '${delta ~/ (30 * day)} 个月前';
  }
  return '${delta ~/ (365 * day)} 年前';
}
