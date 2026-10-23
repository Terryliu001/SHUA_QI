import 'package:shuaqi/domain/model/workbook.dart';

/// 书架搜索过滤（纯函数，可单测）。
///
/// 语义刻意保持简单：**标题 / 标签 / 文件夹名 任一包含即命中，忽略大小写与首尾空白**。
/// 不做拼音、不做分词——书架上限几十卷（`listByRecent` 的 limit），
/// 客户端一次过滤的成本是零，简单规则不会猜错用户意图。
///
/// 空 query（或全空白）视为"没有搜索"，原样返回全部。
List<Workbook> filterByQuery(List<Workbook> workbooks, String query) {
  final String needle = query.trim().toLowerCase();
  if (needle.isEmpty) {
    return workbooks;
  }
  return workbooks
      .where(
        (Workbook wb) =>
            wb.title.toLowerCase().contains(needle) ||
            wb.folder.toLowerCase().contains(needle) ||
            wb.tags.any(
              (String tag) => tag.toLowerCase().contains(needle),
            ),
      )
      .toList(growable: false);
}

/// 按文件夹筛选。[folder] 为 null = 全部；空串 = 未分类。
List<Workbook> filterByFolder(List<Workbook> workbooks, String? folder) {
  if (folder == null) {
    return workbooks;
  }
  return workbooks
      .where((Workbook wb) => wb.folder == folder)
      .toList(growable: false);
}

/// 按标签筛选（多选 = 同时具备）。空列表 = 不筛。
List<Workbook> filterByTags(List<Workbook> workbooks, List<String> tags) {
  if (tags.isEmpty) {
    return workbooks;
  }
  return workbooks
      .where(
        (Workbook wb) => tags.every((String t) => wb.tags.contains(t)),
      )
      .toList(growable: false);
}

/// 书架上出现过的文件夹名（去重、按名称排序，不含"未分类"）。
List<String> foldersOf(List<Workbook> workbooks) {
  final Set<String> names = <String>{
    for (final Workbook wb in workbooks)
      if (wb.folder.isNotEmpty) wb.folder,
  };
  final List<String> sorted = names.toList()..sort();
  return sorted;
}

/// 书架上出现过的标签（去重、按出现次数降序，次数相同按名称）。
List<String> tagsOf(List<Workbook> workbooks) {
  final Map<String, int> count = <String, int>{};
  for (final Workbook wb in workbooks) {
    for (final String tag in wb.tags) {
      count[tag] = (count[tag] ?? 0) + 1;
    }
  }
  final List<String> sorted = count.keys.toList()
    ..sort((String a, String b) {
      final int byCount = (count[b] ?? 0).compareTo(count[a] ?? 0);
      return byCount != 0 ? byCount : a.compareTo(b);
    });
  return sorted;
}
