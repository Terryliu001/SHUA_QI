/// 书架文件夹（v4 起独立成表，支持嵌套）—— 纯 Dart。
///
/// 为什么从"名字字符串"换成表（2026-10-24 第二轮用户第 8 条）：
/// 名字字符串只能表达一层，改名要批量改 `workbook.folder`，
/// 也没地方放"颜色/排序/父级"。换成 `folder` 表 + `workbook.folder_id` 之后，
/// 嵌套、改名（只改一行）、拖到别处都变成一行 SQL。
library;

/// 文件夹行。
class ShelfFolder {
  const ShelfFolder({
    required this.id,
    required this.name,
    this.parentId = '',
    this.color = '',
    this.sort = 0,
  });

  factory ShelfFolder.fromRow(Map<String, Object?> row) => ShelfFolder(
    id: (row['id'] as String?) ?? '',
    name: (row['name'] as String?) ?? '',
    parentId: (row['parent_id'] as String?) ?? '',
    color: (row['color'] as String?) ?? '',
    sort: (row['sort'] as num?)?.toInt() ?? 0,
  );

  final String id;
  final String name;

  /// 上级文件夹 id；空串 = 顶层。
  final String parentId;

  /// 自定义颜色（`#RRGGBB`）；空串 = 用主题色。
  final String color;

  final int sort;

  bool get isRoot => parentId.isEmpty;

  Map<String, Object?> toRow() => <String, Object?>{
    'id': id,
    'name': name,
    'parent_id': parentId,
    'color': color,
    'sort': sort,
  };

  ShelfFolder copyWith({
    String? name,
    String? parentId,
    String? color,
    int? sort,
  }) => ShelfFolder(
    id: id,
    name: name ?? this.name,
    parentId: parentId ?? this.parentId,
    color: color ?? this.color,
    sort: sort ?? this.sort,
  );
}

/// 树里的一个可见行（深度用于缩进）。
class ShelfFolderRow {
  const ShelfFolderRow({required this.folder, required this.depth});

  final ShelfFolder folder;
  final int depth;
}

/// 某一层的子文件夹（按 sort、name 排）。
List<ShelfFolder> childFolders(List<ShelfFolder> all, String parentId) {
  final List<ShelfFolder> out = <ShelfFolder>[
    for (final ShelfFolder folder in all)
      if (folder.parentId == parentId) folder,
  ];
  out.sort((ShelfFolder a, ShelfFolder b) {
    final int bySort = a.sort.compareTo(b.sort);
    return bySort != 0 ? bySort : a.name.compareTo(b.name);
  });
  return out;
}

/// 深度优先摊平成"可显示的行"。`expanded` 里没有的文件夹只出现自己、不展开子级。
List<ShelfFolderRow> visibleFolderRows(
  List<ShelfFolder> all,
  Set<String> expanded, {
  String parentId = '',
  int depth = 0,
}) {
  final List<ShelfFolderRow> rows = <ShelfFolderRow>[];
  for (final ShelfFolder folder in childFolders(all, parentId)) {
    rows.add(ShelfFolderRow(folder: folder, depth: depth));
    if (expanded.contains(folder.id)) {
      rows.addAll(
        visibleFolderRows(all, expanded, parentId: folder.id, depth: depth + 1),
      );
    }
  }
  return rows;
}

/// 从根到该文件夹的路径（面包屑用，含自己）。
List<ShelfFolder> folderPath(List<ShelfFolder> all, String id) {
  final Map<String, ShelfFolder> byId = <String, ShelfFolder>{
    for (final ShelfFolder folder in all) folder.id: folder,
  };
  final List<ShelfFolder> path = <ShelfFolder>[];
  String cursor = id;
  int guard = 0;
  while (cursor.isNotEmpty && guard < 64) {
    final ShelfFolder? folder = byId[cursor];
    if (folder == null) {
      break;
    }
    path.insert(0, folder);
    cursor = folder.parentId;
    guard += 1;
  }
  return path;
}

/// 某文件夹（含所有子孙）的 id 集合 —— 删文件夹时用来清子级。
Set<String> folderSubtreeIds(List<ShelfFolder> all, String rootId) {
  final Set<String> ids = <String>{rootId};
  bool grew = true;
  while (grew) {
    grew = false;
    for (final ShelfFolder folder in all) {
      if (ids.contains(folder.parentId) && ids.add(folder.id)) {
        grew = true;
      }
    }
  }
  return ids;
}
