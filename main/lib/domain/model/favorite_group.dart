/// 收藏夹的分组与检索（纯函数，可单测）。
///
/// 收藏列表默认「按更新时间倒序」（`listByUpdatedAt`），这里在**已排好序**的
/// 输入上做分组，保证组内、组间顺序都可复现：遍历时首次遇到某组，就是它
/// 「最新更新的那道题」，于是组序 = 首次出现顺序，组内保持原倒序。
library;

import 'package:shuaqi/domain/model/favorite.dart';

/// 一个分组。
class FavoriteGroup {
  const FavoriteGroup({
    required this.key,
    required this.title,
    required this.items,
  });

  /// 分组键：`groupByWorkbook` 用 workbookId；`groupByKnowledge` 用知识点标签名。
  final String key;

  /// 组头显示名。
  final String title;

  final List<Favorite> items;
}

/// 无知识点标签的「未归纳」组键（`groupByKnowledge` 用）。
const String kUnfiledGroupKey = '__unfiled__';

const String kUnfiledGroupTitle = '未归纳';

/// 按卷分组。输入已按 updatedAt 倒序；组序 = 首次出现顺序（即组内最新题的顺序）。
List<FavoriteGroup> groupByWorkbook(List<Favorite> favorites) {
  final Map<String, List<Favorite>> buckets = <String, List<Favorite>>{};
  for (final Favorite favorite in favorites) {
    buckets
        .putIfAbsent(favorite.workbookId, () => <Favorite>[])
        .add(favorite);
  }
  return <FavoriteGroup>[
    for (final Favorite first in favorites)
      if (buckets.containsKey(first.workbookId))
        _take(buckets, first.workbookId, first.workbookTitle),
  ];
}

/// 按知识点分组。
///
/// - 一题**多标签时在每个标签组都出现**（检索不漏）；
/// - 无标签的题归「未归纳」组，固定排最后；
/// - 标签组序 = 首次出现顺序（即该标签最新那道题的顺序）。
List<FavoriteGroup> groupByKnowledge(List<Favorite> favorites) {
  final Map<String, List<Favorite>> buckets = <String, List<Favorite>>{};
  final List<Favorite> unfiled = <Favorite>[];
  for (final Favorite favorite in favorites) {
    if (favorite.knowledgeTags.isEmpty) {
      unfiled.add(favorite);
      continue;
    }
    for (final String tag in favorite.knowledgeTags) {
      buckets.putIfAbsent(tag, () => <Favorite>[]).add(favorite);
    }
  }
  final List<FavoriteGroup> groups = <FavoriteGroup>[];
  for (final Favorite favorite in favorites) {
    for (final String tag in favorite.knowledgeTags) {
      if (buckets.containsKey(tag)) {
        groups.add(_take(buckets, tag, tag));
      }
    }
  }
  if (unfiled.isNotEmpty) {
    groups.add(
      FavoriteGroup(key: kUnfiledGroupKey, title: kUnfiledGroupTitle, items: unfiled),
    );
  }
  return groups;
}

/// 搜索：匹配题号 / 卷名 / 题干 / 知识点（不区分大小写、忽略首尾空白）。
List<Favorite> searchFavorites(List<Favorite> favorites, String query) {
  final String q = query.trim().toLowerCase();
  if (q.isEmpty) {
    return favorites;
  }
  return <Favorite>[
    for (final Favorite favorite in favorites)
      if (_matches(favorite, q)) favorite,
  ];
}

bool _matches(Favorite favorite, String q) {
  if (favorite.label.toLowerCase().contains(q)) {
    return true;
  }
  if (favorite.workbookTitle.toLowerCase().contains(q)) {
    return true;
  }
  if (favorite.stemText.toLowerCase().contains(q)) {
    return true;
  }
  return favorite.knowledgeTags.any(
    (String tag) => tag.toLowerCase().contains(q),
  );
}

/// 按标签筛选（收藏夹「按知识点」视图的横滑标签条用）。
///
/// - [tag] 为 null：不过滤；
/// - [tag] == [kUnfiledGroupKey]：只保留无标签的题；
/// - 其它：只保留含该标签的题。
List<Favorite> filterByTag(List<Favorite> favorites, String? tag) {
  if (tag == null) {
    return favorites;
  }
  if (tag == kUnfiledGroupKey) {
    return <Favorite>[
      for (final Favorite favorite in favorites)
        if (favorite.knowledgeTags.isEmpty) favorite,
    ];
  }
  return <Favorite>[
    for (final Favorite favorite in favorites)
      if (favorite.knowledgeTags.contains(tag)) favorite,
  ];
}

/// 全部去重的知识点标签，按首次出现顺序（标签条按它排）。
List<String> distinctKnowledgeTags(List<Favorite> favorites) {
  final Set<String> seen = <String>{};
  final List<String> out = <String>[];
  for (final Favorite favorite in favorites) {
    for (final String tag in favorite.knowledgeTags) {
      if (seen.add(tag)) {
        out.add(tag);
      }
    }
  }
  return out;
}

/// 是否有「未归纳」（无标签）的题。
bool hasUnfiled(List<Favorite> favorites) =>
    favorites.any((Favorite f) => f.knowledgeTags.isEmpty);

/// 取出并移除某个桶，避免同一组被产出两次。
FavoriteGroup _take(
  Map<String, List<Favorite>> buckets,
  String key,
  String title,
) {
  final List<Favorite> items = buckets.remove(key)!;
  return FavoriteGroup(key: key, title: title, items: items);
}
