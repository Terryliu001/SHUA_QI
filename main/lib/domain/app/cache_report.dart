/// 存储占用统计的**纯数据与纯函数**（不碰 IO，宿主可单测）。
///
/// 为什么要把"哪一类能清"写成数据：
/// 1. 清理是**危险动作**，能不能删必须集中在一处定义，不能由 UI 各自判断；
/// 2. 用户要看得懂：每一类都要有一句"这是什么、删了会怎样"；
/// 3. 统计口径（哪些算缓存、哪些算用户数据）以后改，只改这个文件。
library;

/// 占用的分类。顺序 = 设置页里的展示顺序（用户数据在前，缓存在后）。
enum CacheCategory {
  /// 导入的 PDF 原卷。**不可清**：删了整卷就没了。
  sourcePdf('试卷原文件', '导入的 PDF 本体，删了整卷就没了', clearable: false),

  /// 页面位图缓存（缩略图）。**可清**：下次打开会自动重画。
  thumbnails('缩略图', '书架与缩略图抽屉用的小图，清了会自动重画', clearable: true),

  /// 切题结果 / 判题 / 答案 / 排列顺序等 JSON。**不可清**：用户产物。
  layout('切题与判题数据', '题目框、判题结论、答案、排序都在这里', clearable: false),

  /// 作答原图（PDF 裁切 + 笔迹合成）。**可清**：按需重新生成。
  answerCrops('作答原图裁切', '喂给 AI 和导出的合成图，清了会按需重做', clearable: true),

  /// 手写笔迹（SIF）。**不可清**：这是用户的字。
  ink('手写笔迹', '你在卷面与答题卡上写的每一笔', clearable: false),

  /// 收藏快照（题面图 / 作答图 / 对话）。**不可清**：原卷删了它是唯一证据。
  favorites('收藏快照', '收藏题的题面与作答图，原卷删了也靠它', clearable: false),

  /// 个人空间（头像 / 封面）。**不可清**。
  profile('个人空间', '头像与封面原图', clearable: false),

  /// 用户反馈草稿。**不可清**：用户亲手写的东西不是缓存。
  feedback('反馈草稿', '还没发出去的反馈（含附图）', clearable: false),

  /// SQLite 库与 -wal/-shm。**不可清**。
  database('数据库', '题目索引、收藏、作答记录', clearable: false),

  /// 中断写入留下的 `.tmp`。**可清**：原子写的残余，没有任何价值。
  temp('临时文件', '写入中断留下的半截文件，可以放心清', clearable: true);

  const CacheCategory(this.label, this.hint, {required this.clearable});

  final String label;
  final String hint;

  /// true = 「清理缓存」会删掉它。
  final bool clearable;
}

/// 一类占用的统计结果。
class CacheEntry {
  const CacheEntry({
    required this.category,
    required this.bytes,
    required this.files,
  });

  final CacheCategory category;
  final int bytes;
  final int files;

  bool get isEmpty => bytes <= 0 && files <= 0;
}

/// 一次扫描的结果。
class CacheReport {
  const CacheReport(this.entries);

  const CacheReport.empty() : entries = const <CacheEntry>[];

  /// 按 [CacheCategory.values] 的顺序。
  final List<CacheEntry> entries;

  int get totalBytes =>
      entries.fold<int>(0, (int sum, CacheEntry e) => sum + e.bytes);

  int get totalFiles =>
      entries.fold<int>(0, (int sum, CacheEntry e) => sum + e.files);

  /// 「清理缓存」能释放的字节数（只算 clearable 的）。
  int get clearableBytes => entries
      .where((CacheEntry e) => e.category.clearable)
      .fold<int>(0, (int sum, CacheEntry e) => sum + e.bytes);

  int get clearableFiles => entries
      .where((CacheEntry e) => e.category.clearable)
      .fold<int>(0, (int sum, CacheEntry e) => sum + e.files);

  bool get hasClearable => clearableBytes > 0 || clearableFiles > 0;

  CacheEntry entryOf(CacheCategory category) {
    for (final CacheEntry entry in entries) {
      if (entry.category == category) {
        return entry;
      }
    }
    return CacheEntry(category: category, bytes: 0, files: 0);
  }
}

/// 字节数的中文可读写法。
///
/// 口径：`< 1000 B` 显示整数 B；其余按 1024 进，保留一位小数；
/// 到 GB 就停（本产品不会有 TB 级数据）。刻意不用 `KB/MB` 之外的写法，
/// 免得用户看到 `12.3 MiB` 还要换算。
String formatBytes(int bytes) {
  if (bytes <= 0) {
    return '0 B';
  }
  if (bytes < 1000) {
    return '$bytes B';
  }
  const double kb = 1024;
  final double v = bytes.toDouble();
  if (v < kb * kb) {
    return '${(v / kb).toStringAsFixed(1)} KB';
  }
  if (v < kb * kb * kb) {
    return '${(v / (kb * kb)).toStringAsFixed(1)} MB';
  }
  return '${(v / (kb * kb * kb)).toStringAsFixed(2)} GB';
}

/// 清理结果的文案口径（UI 直接用，避免两处各写一句）。
String cacheClearedMessage({required int bytes, required int files}) {
  if (bytes <= 0 && files <= 0) {
    return '没有可清理的缓存';
  }
  return '已清理 ${formatBytes(bytes)}（$files 个文件）';
}
