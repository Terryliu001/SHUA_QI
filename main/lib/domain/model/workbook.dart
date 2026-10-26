/// 卷（规格 §5.2 `workbook` 表）。
///
/// 纯 Dart 值对象：不 import Flutter，也不认识 sqflite 的 Database。
/// `fromRow` / `toRow` 用的是 §5.3 的约定——列名 snake_case，时间是 UTC 毫秒整数。
library;

/// `workbook.layout_status` 的取值。切题流水线完成后由 `app/region` 改写。
abstract final class LayoutStatus {
  /// 还没跑过切题。
  static const String none = 'none';

  /// 文本层已抽（L0），但还没切出题目（跑了一半被取消 / 没有文本层）。
  static const String text = 'text';

  /// 自动切题完成（L0–L2）。
  static const String auto = 'auto';

  /// 用户手工修正过（有 corrections.json）。
  static const String manual = 'manual';

  /// 原卷文件丢失（启动时孤儿清理标记）。
  static const String missing = 'missing';
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
    this.folder = '',
    this.folderId = '',
    this.tags = const <String>[],
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
      folder: (row['folder'] as String?) ?? '',
      folderId: (row['folder_id'] as String?) ?? '',
      tags: WorkbookTags.decode(row['tags'] as String?),
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

  /// 文件夹名。``''`` = 未分类（老数据全部落到这里）。
  ///
  /// 为什么用"文件夹名字符串"而不是单独一张表：卷子数量是几十级的，
  /// 单层文件夹足够；名字本身就是标识，改名 = 批量 UPDATE 同一个名字，
  /// 不需要维护 id↔name 的映射。
  ///
  /// **空文件夹**没有卷子可挂，不能从这一列推导；书架另把手动新建的
  /// 空文件夹名存到 setting `bookshelf.folders`（JSON 列表）。
  final String folder;

  /// v4 起：指向 `folder` 表的主键；空串 = 未分类。
  ///
  /// 与 [folder]（旧的名字字符串）并存：老库靠 `folder` 迁移出 `folder` 行，
  /// 新逻辑只读 [folderId]，但 `toRow` 仍会写 [folder] 以免清掉旧数据。
  final String folderId;

  /// 标签（多对多，但用逗号串存）。不建关联表的原因同上：量级小、只做筛选。
  final List<String> tags;

  /// v4 起"有没有归到文件夹"要看 [folderId]：
  /// 移动只写 `folder_id`（[folder] 是旧列，留着不删但不再维护），
  /// 只看 [folder] 会让刚移动过的卷仍旧显示成"未分类"。
  bool get isUnfiled => folder.isEmpty && folderId.isEmpty;

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
    'folder': folder,
    'folder_id': folderId,
    'tags': WorkbookTags.encode(tags),
  };

  /// 书架排序用的时间：打开过就按打开时间，否则按导入时间。
  int get sortTime => openedAt ?? createdAt;

  Workbook copyWith({
    String? title,
    int? openedAt,
    String? lastSessionId,
    String? layoutStatus,
    String? folder,
    String? folderId,
    List<String>? tags,
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
      folder: folder ?? this.folder,
      folderId: folderId ?? this.folderId,
      tags: tags ?? this.tags,
    );
  }

  @override
  String toString() => 'Workbook($id, "$title", $pageCount 页)';
}

/// 标签的规范化与编解码（纯 Dart，可单测）。
///
/// 规则（写死在这里，UI 与 DAO 都只用这一份）：
/// - 逗号分隔（中英文逗号都接受），忽略首尾空白与空项；
/// - **去重**、保持输入顺序；
/// - 单个标签最长 12 字、最多 8 个 —— 书架是"筛选器"，不是知识库。
abstract final class WorkbookTags {
  static const String separator = ',';

  static const int maxCount = 8;
  static const int maxLength = 12;

  /// 把用户输入（可能是 "期中,数学 ， 计算"）拆成规范标签列表。
  static List<String> parse(String raw) {
    final List<String> out = <String>[];
    for (final String chunk in raw.split(RegExp(r'[,，、;；]'))) {
      final String t = chunk.trim();
      if (t.isEmpty || out.contains(t)) {
        continue;
      }
      out.add(t.length > maxLength ? t.substring(0, maxLength) : t);
      if (out.length >= maxCount) {
        break;
      }
    }
    return out;
  }

  static List<String> decode(String? raw) {
    if (raw == null || raw.isEmpty) {
      return const <String>[];
    }
    return raw
        .split(separator)
        .map((String s) => s.trim())
        .where((String s) => s.isNotEmpty)
        .toList(growable: false);
  }

  static String encode(List<String> tags) => tags.join(separator);

  /// 用户可见的编辑串（"期中, 数学"）。
  static String toEditable(List<String> tags) => tags.join('，');
}
