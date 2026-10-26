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
            wb.tags.any((String tag) => tag.toLowerCase().contains(needle)),
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

/// 「选择文件加入文件夹」的候选集合（2026-10-24 用户要求）。
///
/// 和「导入 PDF」是两件事：导入把外部 PDF 变成新卷；这里只从**已经导入**的
/// 卷里挑，把它们挂到当前文件夹，避免用户为了归档再走一遍文件选择器。
///
/// 排序刻意是「未分类优先」：新卷导入后默认未分类，用户点进文件夹最想收的
/// 就是这些卷；已经在别的文件夹里的卷排后面，按最近使用排。
List<Workbook> addableToFolder(List<Workbook> workbooks, String folder) {
  final List<Workbook> out = workbooks
      .where((Workbook wb) => wb.folder != folder)
      .toList();
  out.sort((Workbook a, Workbook b) {
    if (a.isUnfiled != b.isUnfiled) {
      return a.isUnfiled ? -1 : 1;
    }
    final int byTime = b.sortTime.compareTo(a.sortTime);
    return byTime != 0 ? byTime : a.title.compareTo(b.title);
  });
  return out;
}

/// 按标签筛选（多选 = 同时具备）。空列表 = 不筛。
List<Workbook> filterByTags(List<Workbook> workbooks, List<String> tags) {
  if (tags.isEmpty) {
    return workbooks;
  }
  return workbooks
      .where((Workbook wb) => tags.every((String t) => wb.tags.contains(t)))
      .toList(growable: false);
}

/// 书架上出现过的文件夹名（去重、按名称排序，不含"未分类"）。
List<String> foldersOf(List<Workbook> workbooks) {
  return mergeFolders(workbooks, const <String>[]);
}

/// 文件夹全集 = 卷子里出现过的 + **手动新建的空文件夹**。
///
/// 2026-10-23 用户要求"文件夹要能手动新建"：空文件夹没有卷子可挂，
/// 不能只从 `workbook.folder` 推导，所以书架另存一份手动列表（设置表 JSON）。
/// 合并时去空、去重、排序；文件夹名仍是唯一标识。
List<String> mergeFolders(List<Workbook> workbooks, Iterable<String> extra) {
  final Set<String> names = <String>{
    for (final Workbook wb in workbooks)
      if (wb.folder.trim().isNotEmpty) wb.folder.trim(),
    for (final String name in extra)
      if (name.trim().isNotEmpty) name.trim(),
  };
  final List<String> sorted = names.toList()..sort();
  return sorted;
}

/// 书架排序（成熟书架的三个最常用口径）。
enum BookshelfSort {
  /// 最近打开/导入优先。
  recent,

  /// 标题升序（忽略大小写）。
  title,

  /// 页数从多到少。
  pages,
}

/// 稳定排序：同值时回落到最近时间，再回落到标题，保证结果可复现。
List<Workbook> sortWorkbooks(List<Workbook> workbooks, BookshelfSort sort) {
  final List<Workbook> sorted = List<Workbook>.of(workbooks);
  int byRecent(Workbook a, Workbook b) {
    final int c = b.sortTime.compareTo(a.sortTime);
    return c != 0 ? c : a.title.compareTo(b.title);
  }

  sorted.sort((Workbook a, Workbook b) {
    switch (sort) {
      case BookshelfSort.recent:
        return byRecent(a, b);
      case BookshelfSort.title:
        final int c = a.title.toLowerCase().compareTo(b.title.toLowerCase());
        return c != 0 ? c : byRecent(a, b);
      case BookshelfSort.pages:
        final int c = b.pageCount.compareTo(a.pageCount);
        return c != 0 ? c : byRecent(a, b);
    }
  });
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
