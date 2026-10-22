import 'package:shuaqi/domain/model/workbook.dart';

/// 书架标题搜索过滤（纯函数，可单测）。
///
/// 语义刻意保持简单：**标题包含即命中，忽略大小写与首尾空白**。
/// 不做拼音/多字段——书架上限 50 卷（`listByRecent` 的 limit），
/// 客户端一次过滤的成本是零，简单规则不会猜错用户意图。
///
/// 空 query（或全空白）视为"没有搜索"，原样返回全部。
List<Workbook> filterByQuery(List<Workbook> workbooks, String query) {
  final String needle = query.trim().toLowerCase();
  if (needle.isEmpty) {
    return workbooks;
  }
  return workbooks
      .where((Workbook wb) => wb.title.toLowerCase().contains(needle))
      .toList(growable: false);
}
