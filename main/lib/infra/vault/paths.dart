/// Vault 里所有路径的**唯一拼装入口**（规格 T1.3）。
///
/// 规则：
/// 1. 除本文件外，任何地方都不许手写 `workbooks/xxx/yyy` 这种字符串。
/// 2. 这里全部是**相对路径**（相对 Vault 根）。绝对路径只在 [Vault] 里拼一次。
/// 3. 路径是数据契约：改了老用户的文件就找不到，等同于丢数据。
library;

abstract final class VaultPaths {
  static const String workbooksRoot = 'workbooks';

  static String workbookDir(String workbookId) => '$workbooksRoot/$workbookId';

  /// 原卷。导出与"原图查看"都读它，任何时候不许被滤镜污染。
  static String sourcePdf(String workbookId) =>
      '${workbookDir(workbookId)}/source.pdf';

  /// 复制中的临时文件。写它 → fsync → rename 成 [sourcePdf]，避免半个文件。
  static String sourcePdfTemp(String workbookId) =>
      '${workbookDir(workbookId)}/source.pdf.tmp';

  /// 人可读的冗余元数据。**以数据库为准**，这个只是给文件管理器看的。
  static String metaJson(String workbookId) => '${workbookDir(workbookId)}/meta.json';

  static String thumbDir(String workbookId) => '${workbookDir(workbookId)}/thumb';

  /// 缩略图。**0-based 页码，补零到 3 位**，保证目录里按文件名排序 = 按页序。
  static String thumb(String workbookId, int pageIndex) =>
      '${thumbDir(workbookId)}/${thumbName(pageIndex)}';

  static String thumbName(int pageIndex) => 'p${pageIndex.toString().padLeft(3, '0')}.png';

  /// 切题结果（L0–L2 的缓存）。T3.x 写入。
  static String layoutDir(String workbookId) => '${workbookDir(workbookId)}/layout';

  static String layoutFile(String workbookId) => '${layoutDir(workbookId)}/regions.json';

  /// 一次作答的全部产物。`sessionId` 而不是 `seq`：二刷的目录必须唯一。
  static String sessionDir(String workbookId, String sessionId) =>
      '${workbookDir(workbookId)}/sessions/$sessionId';

  /// 笔迹（SIF）。T2.4 写入。
  static String inkDir(String workbookId, String sessionId) =>
      '${sessionDir(workbookId, sessionId)}/ink';

  static String inkFile(String workbookId, String sessionId, int pageIndex) =>
      '${inkDir(workbookId, sessionId)}/p${pageIndex.toString().padLeft(3, '0')}.sif';

  /// 交卷快照与分析产物。T5.x 写入。
  static String exportDir(String workbookId) => '${workbookDir(workbookId)}/exports';

  /// 从相对路径反推 workbook id（孤儿清理要用）。
  /// `workbooks/<id>/...` → `<id>`；不匹配返回 null。
  static String? workbookIdOf(String relativePath) {
    final List<String> parts = relativePath.split('/');
    if (parts.length < 2 || parts.first != workbooksRoot) {
      return null;
    }
    final String id = parts[1];
    return id.isEmpty ? null : id;
  }
}
