/// 卷（规格 §5.2 `workbook` 表）。
///
/// 纯 Dart 值对象：不 import Flutter，也不认识 sqflite 的 Database。
/// `fromRow` / `toRow` 用的是 §5.3 的约定——列名 snake_case，时间是 UTC 毫秒整数。
library;

/// `workbook.layout_status` 的取值。切题流水线完成后由 `app/region` 改写。
abstract final class LayoutStatus {
  /// 还没跑过切题。
  static const String none = 'none';

  /// 自动切题完成（L0–L2）。
  static const String auto = 'auto';

  /// 用户手工修正过（有 corrections.json）。
  static const String manual = 'manual';
}

class Workbook {
  const Workbook({
    required this.id,
    required this.title,
    required this.sha1,
    required this.pageCount,
    required this.pageSize,
    required this.sourcePath,
    required this.createdAt,
    this.openedAt,
    this.lastSessionId,
    this.layoutStatus = LayoutStatus.none,
  });

  factory Workbook.fromRow(Map<String, Object?> row) {
    return Workbook(
      id: row['id']! as String,
      title: row['title']! as String,
      sha1: row['sha1']! as String,
      pageCount: (row['page_count']! as num).toInt(),
      pageSize: row['page_size']! as String,
      sourcePath: row['source_path']! as String,
      createdAt: (row['created_at']! as num).toInt(),
      openedAt: (row['opened_at'] as num?)?.toInt(),
      lastSessionId: row['last_session_id'] as String?,
      layoutStatus: (row['layout_status'] as String?) ?? LayoutStatus.none,
    );
  }

  final String id;
  final String title;

  /// 文件内容指纹，`UNIQUE`。重复导入靠它拦。
  final String sha1;

  final int pageCount;

  /// 摘要字符串，不是逐页尺寸。逐页尺寸在 `wb_page.w/h`（混合 A4/A3 时两者会不一致）。
  final String pageSize;

  final String sourcePath;

  /// UTC 毫秒。
  final int createdAt;

  /// 最近一次打开时间，UTC 毫秒。`null` 表示从没打开过。
  final int? openedAt;

  final String? lastSessionId;

  final String layoutStatus;

  Map<String, Object?> toRow() => <String, Object?>{
    'id': id,
    'title': title,
    'sha1': sha1,
    'page_count': pageCount,
    'page_size': pageSize,
    'source_path': sourcePath,
    'created_at': createdAt,
    'opened_at': openedAt,
    'last_session_id': lastSessionId,
    'layout_status': layoutStatus,
  };

  /// 书架排序用的时间：打开过就按打开时间，否则按导入时间。
  int get sortTime => openedAt ?? createdAt;

  Workbook copyWith({
    String? title,
    int? openedAt,
    String? lastSessionId,
    String? layoutStatus,
  }) {
    return Workbook(
      id: id,
      title: title ?? this.title,
      sha1: sha1,
      pageCount: pageCount,
      pageSize: pageSize,
      sourcePath: sourcePath,
      createdAt: createdAt,
      openedAt: openedAt ?? this.openedAt,
      lastSessionId: lastSessionId ?? this.lastSessionId,
      layoutStatus: layoutStatus ?? this.layoutStatus,
    );
  }

  @override
  String toString() => 'Workbook($id, "$title", $pageCount 页)';
}
