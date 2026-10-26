/// 一次**批量**导入的结果汇总（纯函数，可单测）。
///
/// 2026-10-24：首页「导入 PDF」支持一次选多份之后，一次导入不再只有
/// "成功 / 失败"两种结局——还有"这份已经在书架上了"（sha1 命中）。
/// 三种结局必须一起说清楚，否则用户选了 5 份、只看到一句"导入完成"，
/// 根本不知道另外几份去哪了。
library;

/// 一份导入成功的卷（用于给用户看"导进来的是什么"）。
class ImportedWorkbook {
  const ImportedWorkbook({
    required this.title,
    required this.pageCount,
    required this.thumbCount,
  });

  final String title;
  final int pageCount;
  final int thumbCount;
}

/// 一次批量导入的结果。
class ImportBatchResult {
  const ImportBatchResult({
    required this.imported,
    required this.deduplicated,
    required this.failures,
  });

  /// 真正导入成功的卷。
  final List<ImportedWorkbook> imported;

  /// sha1 命中、已经在书架上的卷（**没有**产生新文件）。
  final List<String> deduplicated;

  /// 失败明细，每条形如 `文件名：原因`。
  final List<String> failures;

  /// 本次一共处理了多少份。
  int get total => imported.length + deduplicated.length + failures.length;
}

/// 汇总最多列出几条失败明细。
///
/// 选 20 份、20 份全错时，把 20 条原因全塞进 SnackBar 会把提示条撑成
/// 一面墙，反而看不到。列出前 3 条 + 一个"另有 N 份"就够了——
/// 用户要细节可以逐个单独导入，那时的报错是完整的。
const int kImportFailurePreview = 3;

/// 把批量导入结果说成一句人话。
///
/// 口径：
/// - 一份都没选 → 「没有导入任何文件」（不该发生，当作兜底）；
/// - 全成功 → 「导入 3 份。」；
/// - 有重复 → 「导入 2 份 · 1 份已存在」（重复**不是错误**，它只是没新增）；
/// - 有失败 → 追加失败明细（最多 [kImportFailurePreview] 条）。
String importSummaryMessage(ImportBatchResult result) {
  if (result.total == 0) {
    return '没有导入任何文件';
  }
  final List<String> parts = <String>[];
  if (result.imported.isNotEmpty) {
    parts.add('导入 ${result.imported.length} 份');
  }
  if (result.deduplicated.isNotEmpty) {
    parts.add('${result.deduplicated.length} 份已存在');
  }
  if (result.failures.isNotEmpty) {
    parts.add('${result.failures.length} 份失败');
  }
  final String head = '${parts.join(' · ')}。';
  if (result.failures.isEmpty) {
    return head;
  }
  final List<String> shown = result.failures
      .take(kImportFailurePreview)
      .toList();
  final int rest = result.failures.length - shown.length;
  final List<String> lines = <String>[
    for (final String failure in shown) '· $failure',
    if (rest > 0) '· 另有 $rest 份失败',
  ];
  return '$head\n${lines.join('\n')}';
}
