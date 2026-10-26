import 'package:flutter/material.dart';
import 'package:shuaqi/domain/model/shelf_folder.dart';
import 'package:shuaqi/domain/model/workbook.dart';
import 'package:shuaqi/ui/theme/tokens.dart';
import 'package:shuaqi/ui/widgets/pressable.dart';

/// **子文件夹卡片**（2026-10-26 用户第 10 条）。
///
/// ## 为什么要有它
/// 树形视图里能看到层级，但大图/列表视图里"点开外层文件夹后"只剩一排卷子，
/// 里面的子文件夹**完全看不见**——用户以为那个文件夹是空的。
/// 顶部那排文件夹 chip 只能平铺同级、且没有"里面有多少卷"的信息，
/// 所以这里给内容区加一组**文件夹卡**：名字 + 卷数 + 子文件夹数，点进去。
///
/// ## 两种形态
/// - **大图视图**：横向滚动的一排卡（和卷子卡同一套语言：圆角、发丝边、图标）；
/// - **列表视图**：整行一条（和列表里的卷子行一致）。
///
/// 两种形态都只出现于"当前文件夹有子文件夹"且"不在搜索/多选"时——
/// 搜索时混进文件夹卡会干扰结果，多选时它们不是可选对象。
class FolderCards extends StatelessWidget {
  const FolderCards({
    super.key,
    required this.folders,
    required this.workbooks,
    required this.onOpen,
    this.grid = true,
  });

  /// 当前层级的子文件夹。
  final List<ShelfFolder> folders;

  /// 全部卷（用来数每个文件夹里有多少卷）。
  final List<Workbook> workbooks;

  final ValueChanged<String> onOpen;

  /// true = 大图视图的横排卡片；false = 列表视图的整行。
  final bool grid;

  int _booksOf(String folderId) =>
      workbooks.where((Workbook w) => w.folderId == folderId).length;

  int _subsOf(String folderId) =>
      folders.where((ShelfFolder f) => f.parentId == folderId).length;

  @override
  Widget build(BuildContext context) {
    if (folders.isEmpty) {
      return const SizedBox.shrink();
    }
    if (grid) {
      return SizedBox(
        height: 104,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: ShqLayout.gutter),
          itemCount: folders.length,
          separatorBuilder: (BuildContext context, int index) =>
              const SizedBox(width: ShqSpace.sm),
          itemBuilder: (BuildContext context, int index) {
            final ShelfFolder folder = folders[index];
            return _FolderCard(
              folder: folder,
              books: _booksOf(folder.id),
              subs: _subsOf(folder.id),
              onTap: () => onOpen(folder.id),
            );
          },
        ),
      );
    }
    return Column(
      children: <Widget>[
        for (int i = 0; i < folders.length; i += 1) ...<Widget>[
          if (i > 0) const Divider(height: 1, thickness: 1),
          _FolderRow(
            folder: folders[i],
            books: _booksOf(folders[i].id),
            subs: _subsOf(folders[i].id),
            onTap: () => onOpen(folders[i].id),
          ),
        ],
      ],
    );
  }
}

/// 大图视图里的文件夹卡。
class _FolderCard extends StatelessWidget {
  const _FolderCard({
    required this.folder,
    required this.books,
    required this.subs,
    required this.onTap,
  });

  final ShelfFolder folder;
  final int books;
  final int subs;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    return Pressable(
      onTap: onTap,
      scale: 0.97,
      haptic: true,
      child: Container(
        width: 150,
        padding: const EdgeInsets.all(ShqSpace.md),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(ShqRadius.md),
          border: Border.all(color: scheme.outlineVariant),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(
                  Icons.folder_outlined,
                  size: 20,
                  color: scheme.primary,
                ),
                const Spacer(),
                if (subs > 0)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 1,
                    ),
                    decoration: BoxDecoration(
                      color: scheme.primary.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(ShqRadius.pill),
                    ),
                    child: Text(
                      '含 $subs 个子文件夹',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: scheme.primary,
                        fontSize: 9.5,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: ShqSpace.sm),
            Text(
              folder.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              books == 0 ? '空文件夹' : '$books 卷',
              style: theme.textTheme.labelSmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 列表视图里的文件夹行。
class _FolderRow extends StatelessWidget {
  const _FolderRow({
    required this.folder,
    required this.books,
    required this.subs,
    required this.onTap,
  });

  final ShelfFolder folder;
  final int books;
  final int subs;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: ShqLayout.gutter,
          vertical: ShqSpace.md,
        ),
        child: Row(
          children: <Widget>[
            Icon(Icons.folder_outlined, size: 20, color: scheme.primary),
            const SizedBox(width: ShqSpace.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    folder.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    <String>[
                      books == 0 ? '空文件夹' : '$books 卷',
                      if (subs > 0) '$subs 个子文件夹',
                    ].join(' · '),
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right, size: 20, color: scheme.outline),
          ],
        ),
      ),
    );
  }
}
