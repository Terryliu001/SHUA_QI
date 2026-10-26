import 'package:flutter/material.dart';

import 'package:shuaqi/domain/model/shelf_folder.dart';
import 'package:shuaqi/domain/model/workbook.dart';
import 'package:shuaqi/domain/model/workbook_search.dart';
import 'package:shuaqi/ui/theme/hex_color.dart';
import 'package:shuaqi/ui/theme/tokens.dart';
import 'package:shuaqi/ui/widgets/empty_state.dart';
import 'package:shuaqi/ui/widgets/pressable.dart';

// ── 树形视图（2026-10-24 用户第 9 条；同日补"长按拖动改归属"）────────

/// 一层的缩进量（dp）。18 是"看得清层级但又不吃掉半屏"的值：
/// 8 分不清，24 在 6 层之后就没地方写字了。
double _treeIndent(int depth) => 12.0 + depth * 18.0;

/// 树里拖动时的载荷：一卷，或一个文件夹。
///
/// 只有 id 与名字——落库的事（写 `workbook.folder_id` / `folder.parent_id`）
/// 由外层回调做，树自己不碰数据库。
@immutable
class ShelfTreeDrag {
  const ShelfTreeDrag({
    required this.id,
    required this.label,
    required this.isFolder,
    this.parentId = '',
    this.subtreeIds = const <String>{},
  });

  final String id;
  final String label;
  final bool isFolder;

  /// 拖的是文件夹时的原父级（用来判断"已经在里面了"）。
  final String parentId;

  /// 拖的是文件夹时：它和它所有子孙的 id。用来挡掉"把文件夹拖进它自己里"。
  final Set<String> subtreeIds;
}

/// Obsidian 式单栏树：只有文件夹层级 + 一行一个 PDF 文件名。
///
/// 为什么不做成"每个节点都能预览内容"：预览在列表 / 大图两种视图里已经有了，
/// 树视图专治"文件夹多起来以后找不到东西"——所以末端只到文件夹，
/// PDF 只用一行文件名（点一下直接打开），一屏能装下几十个节点。
class ShelfTree extends StatelessWidget {
  const ShelfTree({
    super.key,
    required this.folders,
    required this.expanded,
    required this.workbooks,
    required this.query,
    required this.selectedFolderId,
    required this.selecting,
    required this.selectedIds,
    required this.onToggleExpand,
    required this.onOpenWorkbook,
    required this.onWorkbookMenu,
    required this.onToggleSelected,
    required this.onFolderMenu,
    required this.onOpenFolder,
    required this.onNewFolder,
    this.onClearQuery,
    this.onMoveWorkbook,
    this.onMoveFolder,
  });

  final List<ShelfFolder> folders;
  final Set<String> expanded;

  /// 全部卷（未过滤）：过滤与排序在树里按"文件名升序"重做。
  final List<Workbook> workbooks;
  final String query;
  final String? selectedFolderId;

  final bool selecting;
  final Set<String> selectedIds;

  final ValueChanged<String> onToggleExpand;
  final ValueChanged<Workbook> onOpenWorkbook;
  final ValueChanged<Workbook> onWorkbookMenu;
  final ValueChanged<String> onToggleSelected;
  final ValueChanged<ShelfFolder> onFolderMenu;

  /// 「在列表里查看」：树里的文件夹 → 列表视图的当前文件夹。
  final ValueChanged<String> onOpenFolder;

  /// 新建顶层文件夹：树视图里没有横向的文件夹条，入口必须自己带一个，
  /// 否则"想归个类"的用户会被卡住。往某个文件夹里建，走长按菜单。
  final VoidCallback onNewFolder;

  /// 搜索没结果时的「清除搜索」；null = 不给动作。
  final VoidCallback? onClearQuery;

  /// 把一卷拖进 [folderId]（'' = 未分类 / 顶层）。
  final void Function(Workbook workbook, String folderId)? onMoveWorkbook;

  /// 把一个文件夹拖进 [parentId]（'' = 顶层）。**不含**它的新名字——只改归属。
  final void Function(String folderId, String parentId)? onMoveFolder;

  @override
  Widget build(BuildContext context) {
    final bool searching = query.trim().isNotEmpty;
    // 拖动是可选能力：两个回调都 null 时，行的长按退回"打开菜单"。
    final bool canDrag = onMoveWorkbook != null || onMoveFolder != null;
    final List<Workbook> scoped = sortWorkbooks(
      filterByQuery(workbooks, query),
      BookshelfSort.title,
    );

    // 搜索时只保留"含有匹配卷"的那几条链：几十个空文件夹会淹没真正的结果。
    final Set<String> keep = searching
        ? <String>{
            for (final Workbook wb in scoped)
              for (final ShelfFolder folder in folderPath(folders, wb.folderId))
                folder.id,
          }
        : <String>{for (final ShelfFolder folder in folders) folder.id};

    int countIn(String folderId) {
      if (folderId.isEmpty) {
        return scoped.where((Workbook wb) => wb.folderId.isEmpty).length;
      }
      final Set<String> ids = folderSubtreeIds(folders, folderId);
      return scoped.where((Workbook wb) => ids.contains(wb.folderId)).length;
    }

    Workbook? findWorkbook(String id) {
      for (final Workbook wb in workbooks) {
        if (wb.id == id) {
          return wb;
        }
      }
      return null;
    }

    /// 能不能落在 [targetId] 上。三条硬规则：不能落到自己身上、
    /// 不能落进自己的子孙（否则树会断成环）、已经在里面就不动。
    bool accepts(ShelfTreeDrag data, String targetId) {
      if (!data.isFolder) {
        return true;
      }
      if (data.id == targetId) {
        return false;
      }
      if (data.subtreeIds.contains(targetId)) {
        return false;
      }
      return data.parentId != targetId;
    }

    void drop(ShelfTreeDrag data, String targetId) {
      if (data.isFolder) {
        onMoveFolder?.call(data.id, targetId);
        return;
      }
      final Workbook? wb = findWorkbook(data.id);
      if (wb != null) {
        onMoveWorkbook?.call(wb, targetId);
      }
    }

  /// 把一个行变成"可拖出 + 可落入"的组合。
  ///
  /// **每个落点自带 `StatefulBuilder`**：下落高亮是 `DragTarget` 自己的
  /// builder 参数（`candidate`），但那一层的重建由框架负责；我们在
  /// `onMove` 里额外置一个本地标记，让"手指进入范围"就亮，
  /// 而不是等数据命中判定完成——真机上后者会晚半拍。
  Widget wrapDroppable(Widget child, String targetId) {
    return StatefulBuilder(
      builder: (BuildContext context, StateSetter setRowState) {
        bool hot = false;
        return DragTarget<ShelfTreeDrag>(
          onWillAcceptWithDetails: (DragTargetDetails<ShelfTreeDrag> details) =>
              accepts(details.data, targetId),
          onMove: (DragTargetDetails<ShelfTreeDrag> details) {
            if (!hot) {
              setRowState(() => hot = true);
            }
          },
          onLeave: (ShelfTreeDrag? _) {
            if (hot) {
              setRowState(() => hot = false);
            }
          },
          onAcceptWithDetails: (DragTargetDetails<ShelfTreeDrag> details) {
            setRowState(() => hot = false);
            drop(details.data, targetId);
          },
          builder: (
            BuildContext context,
            List<ShelfTreeDrag?> candidate,
            List<Object?> rejected,
          ) => _DropHighlight(
            active: hot || candidate.isNotEmpty,
            child: child,
          ),
        );
      },
    );
  }

    final List<Widget> rows = <Widget>[];

    void addFiles(String folderId, int depth) {
      for (final Workbook wb in scoped) {
        if (wb.folderId != folderId) {
          continue;
        }
        Widget row = _TreeFileRow(
          workbook: wb,
          indent: _treeIndent(depth),
          selecting: selecting,
          selected: selectedIds.contains(wb.id),
          // 长按被拖动接管之后，菜单必须有别的入口，否则功能就消失了。
          showMenu: canDrag,
          onMenu: () => onWorkbookMenu(wb),
          onTap: () => selecting ? onToggleSelected(wb.id) : onOpenWorkbook(wb),
          onLongPress: canDrag || selecting
              ? null
              : () => onWorkbookMenu(wb),
        );
        if (canDrag && !selecting) {
          row = LongPressDraggable<ShelfTreeDrag>(
            data: ShelfTreeDrag(id: wb.id, label: wb.title, isFolder: false),
            feedback: _DragFeedback(
              label: wb.title,
              icon: Icons.picture_as_pdf_outlined,
            ),
            childWhenDragging: Opacity(opacity: 0.4, child: row),
            child: row,
          );
        }
        rows.add(row);
      }
    }

    // 先自己的卷、再子文件夹：点开一个文件夹，它的卷就在名字下面，
    // 不会被一条很长的子树推到屏幕外。
    void walk(String parentId, int depth) {
      for (final ShelfFolder folder in childFolders(folders, parentId)) {
        if (!keep.contains(folder.id)) {
          continue;
        }
        final bool open = expanded.contains(folder.id) || searching;
        Widget row = _TreeFolderRow(
          name: folder.name,
          depth: depth,
          expanded: open,
          count: countIn(folder.id),
          color: folder.color.isEmpty ? null : shqHexColor(folder.color),
          selected: selectedFolderId == folder.id,
          showMenu: canDrag,
          onMenu: () => onFolderMenu(folder),
          onTap: () => onToggleExpand(folder.id),
          onLongPress: canDrag ? null : () => onFolderMenu(folder),
          onOpen: () => onOpenFolder(folder.id),
        );
        if (canDrag && onMoveFolder != null) {
          row = LongPressDraggable<ShelfTreeDrag>(
            data: ShelfTreeDrag(
              id: folder.id,
              label: folder.name,
              isFolder: true,
              parentId: folder.parentId,
              subtreeIds: folderSubtreeIds(folders, folder.id),
            ),
            feedback: _DragFeedback(
              label: folder.name,
              icon: Icons.folder_outlined,
            ),
            childWhenDragging: Opacity(opacity: 0.4, child: row),
            child: row,
          );
        }
        rows.add(canDrag ? wrapDroppable(row, folder.id) : row);
        if (open) {
          addFiles(folder.id, depth + 1);
          walk(folder.id, depth + 1);
        }
      }
    }

    if (!searching) {
      rows.add(
        _TreeActionRow(
          icon: Icons.create_new_folder_outlined,
          label: '新建文件夹',
          onTap: onNewFolder,
        ),
      );
    }

    final int unfiled = countIn('');
    // 能拖动时「未分类」恒显示：它是唯一的"拖回顶层"落点，
    // 一本未分类的卷都没有时把它藏掉，用户就没法把东西拖出来了。
    if (unfiled > 0 || canDrag) {
      final bool open = expanded.contains('') || searching;
      final Widget row = _TreeFolderRow(
        name: '未分类',
        depth: 0,
        expanded: open,
        count: unfiled,
        icon: Icons.inbox_outlined,
        selected: selectedFolderId == '',
        onTap: () => onToggleExpand(''),
        onOpen: () => onOpenFolder(''),
      );
      rows.add(canDrag ? wrapDroppable(row, '') : row);
      if (open) {
        addFiles('', 1);
      }
    }
    walk('', 0);

    if (rows.isEmpty) {
      return EmptyState(
        icon: Icons.search_off_outlined,
        title: '没有匹配「$query」的卷子',
        message: '换个词试试，或退出搜索看整棵树',
        actionLabel: onClearQuery == null ? null : '清除搜索',
        actionIcon: Icons.filter_alt_off_outlined,
        onAction: onClearQuery,
      );
    }

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: ShqLayout.maxReadingWidth),
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(
            ShqSpace.md,
            ShqSpace.sm,
            ShqSpace.md,
            96,
          ),
          children: rows,
        ),
      ),
    );
  }
}

/// 树里的动作行（目前只有「新建文件夹」）。
///
/// 和文件夹行同构（同样的缩进基线与圆角），只是左边没有展开箭头——
/// 它是"动作"不是"节点"，视觉上要能一眼分开。
class _TreeActionRow extends StatelessWidget {
  const _TreeActionRow({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    return Padding(
      padding: EdgeInsets.only(left: _treeIndent(0)),
      child: Pressable(
        onTap: onTap,
        scale: 0.99,
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: ShqSpace.sm,
            vertical: 7,
          ),
          decoration: BoxDecoration(
            border: Border.all(color: scheme.outlineVariant),
            borderRadius: BorderRadius.circular(ShqRadius.sm),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(icon, size: 16, color: scheme.primary),
              const SizedBox(width: ShqSpace.sm),
              Text(
                label,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: scheme.primary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 树里的文件夹行：展开箭头 + 文件夹图标（带色）+ 名字 + 卷数 + 「在列表里查看」。
class _TreeFolderRow extends StatelessWidget {
  const _TreeFolderRow({
    required this.name,
    required this.depth,
    required this.expanded,
    required this.count,
    required this.onTap,
    required this.onOpen,
    this.onLongPress,
    this.color,
    this.icon = Icons.folder_outlined,
    this.selected = false,
    this.showMenu = false,
    this.onMenu,
  });

  final String name;
  final int depth;
  final bool expanded;
  final int count;
  final VoidCallback onTap;
  final VoidCallback onOpen;
  final VoidCallback? onLongPress;
  final Color? color;
  final IconData icon;
  final bool selected;

  /// 行尾多给一个「更多操作」按钮：长按被拖动占用时，菜单得有别的入口。
  final bool showMenu;
  final VoidCallback? onMenu;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final Color tint = color ?? scheme.primary;
    return Padding(
      padding: EdgeInsets.only(left: _treeIndent(depth)),
      child: Pressable(
        onTap: onTap,
        onLongPress: onLongPress,
        scale: 0.99,
        child: AnimatedContainer(
          duration: ShqMotion.base,
          curve: ShqMotion.curveEmphasized,
          padding: const EdgeInsets.symmetric(horizontal: ShqSpace.sm, vertical: 6),
          decoration: BoxDecoration(
            color: selected ? tint.withValues(alpha: 0.14) : null,
            borderRadius: BorderRadius.circular(ShqRadius.sm),
            border: selected
                ? Border.all(color: tint.withValues(alpha: 0.45))
                : null,
          ),
          child: Row(
            children: <Widget>[
              Icon(
                expanded ? Icons.expand_more : Icons.chevron_right,
                size: 18,
                color: scheme.outline,
              ),
              Icon(icon, size: 18, color: tint),
              const SizedBox(width: ShqSpace.sm),
              Expanded(
                child: Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: selected ? tint : null,
                  ),
                ),
              ),
              if (count > 0)
                Padding(
                  padding: const EdgeInsets.only(left: ShqSpace.xs),
                  child: Text(
                    '$count',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.outline,
                    ),
                  ),
                ),
              IconButton(
                tooltip: '在列表里查看',
                onPressed: onOpen,
                padding: EdgeInsets.zero,
                visualDensity: VisualDensity.compact,
                // `padded` 会给 48×48 的点击区，在 32 宽的位置里被裁成半个图标
                // （真机 2120×3000 上第一版就是这样）。shrinkWrap 让点击区=实际尺寸。
                style: IconButton.styleFrom(
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  minimumSize: const Size(30, 30),
                ),
                constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
                icon: Icon(
                  Icons.playlist_play,
                  size: 18,
                  color: scheme.outline,
                ),
              ),
              if (showMenu)
                IconButton(
                  tooltip: '更多操作',
                  onPressed: onMenu,
                  padding: EdgeInsets.zero,
                  visualDensity: VisualDensity.compact,
                  style: IconButton.styleFrom(
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    minimumSize: const Size(30, 30),
                  ),
                  constraints: const BoxConstraints(
                    minWidth: 30,
                    minHeight: 30,
                  ),
                  icon: Icon(
                    Icons.more_vert,
                    size: 18,
                    color: scheme.outline,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// PDF 在树里只占一行：文件名 + 页数，点一下直接打开，长按出菜单。
class _TreeFileRow extends StatelessWidget {
  const _TreeFileRow({
    required this.workbook,
    required this.indent,
    required this.onTap,
    required this.onLongPress,
    this.selecting = false,
    this.selected = false,
    this.showMenu = false,
    this.onMenu,
  });

  final Workbook workbook;
  final double indent;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final bool selecting;
  final bool selected;

  /// 行尾「更多操作」：长按被拖动占用时的菜单入口。
  final bool showMenu;
  final VoidCallback? onMenu;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    return Padding(
      padding: EdgeInsets.only(left: indent),
      child: Pressable(
        onTap: onTap,
        onLongPress: onLongPress,
        scale: 0.99,
        child: Container(
          decoration: BoxDecoration(
            color: selected
                ? scheme.primaryContainer.withValues(alpha: 0.22)
                : null,
            borderRadius: BorderRadius.circular(ShqRadius.sm),
          ),
          padding: const EdgeInsets.symmetric(
            horizontal: ShqSpace.sm,
            vertical: 7,
          ),
          child: Row(
            children: <Widget>[
              if (selecting) ...<Widget>[
                Icon(
                  selected ? Icons.check_circle : Icons.radio_button_unchecked,
                  size: 18,
                  color: selected ? scheme.primary : scheme.outline,
                ),
                const SizedBox(width: ShqSpace.sm),
              ],
              Icon(
                Icons.picture_as_pdf_outlined,
                size: 16,
                color: scheme.outline,
              ),
              const SizedBox(width: ShqSpace.sm),
              Expanded(
                child: Text(
                  workbook.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium,
                ),
              ),
              const SizedBox(width: ShqSpace.xs),
              Text(
                '${workbook.pageCount} 页',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: scheme.outline,
                ),
              ),
              if (showMenu)
                IconButton(
                  tooltip: '更多操作',
                  onPressed: onMenu,
                  padding: EdgeInsets.zero,
                  visualDensity: VisualDensity.compact,
                  style: IconButton.styleFrom(
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    minimumSize: const Size(30, 30),
                  ),
                  constraints: const BoxConstraints(
                    minWidth: 30,
                    minHeight: 30,
                  ),
                  icon: Icon(
                    Icons.more_vert,
                    size: 18,
                    color: scheme.outline,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 拖动时跟着手指走的那枚浮起小条。
///
/// 只画"你正拿着什么"——它要能被手指看见又不能盖住落点，所以做得比行还窄。
class _DragFeedback extends StatelessWidget {
  const _DragFeedback({required this.label, required this.icon});

  final String label;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    return Material(
      color: Colors.transparent,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: ShqSpace.sm, vertical: 6),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(ShqRadius.sm),
          border: Border.all(color: scheme.primary.withValues(alpha: 0.6)),
          boxShadow: <BoxShadow>[
            BoxShadow(
              color: scheme.shadow.withValues(alpha: 0.28),
              blurRadius: 10,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(icon, size: 16, color: scheme.primary),
            const SizedBox(width: ShqSpace.xs),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 220),
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: scheme.onSurface,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 落点高亮：拖动经过某个文件夹时把整行染一下。
///
/// 只描边 + 极浅底色，不位移不放大——树是靠缩进读层级的，
/// 一动整行的位置关系就乱了。
class _DropHighlight extends StatelessWidget {
  const _DropHighlight({required this.active, required this.child});

  final bool active;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return AnimatedContainer(
      duration: ShqMotion.base,
      curve: ShqMotion.curveStandard,
      decoration: BoxDecoration(
        color: active ? scheme.primary.withValues(alpha: 0.14) : null,
        borderRadius: BorderRadius.circular(ShqRadius.sm),
        border: active
            ? Border.all(color: scheme.primary.withValues(alpha: 0.55))
            : null,
      ),
      child: child,
    );
  }
}
