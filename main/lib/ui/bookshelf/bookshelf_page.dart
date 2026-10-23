import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shuaqi/app/import/import_workbook.dart';
import 'package:shuaqi/domain/model/workbook.dart';
import 'package:shuaqi/domain/model/workbook_search.dart';
import 'package:shuaqi/infra/vault/paths.dart';
import 'package:shuaqi/state/app_providers.dart';
import 'package:shuaqi/ui/bookshelf/workbook_menu_sheet.dart';
import 'package:shuaqi/ui/router.dart';
import 'package:shuaqi/ui/theme/tokens.dart';
import 'package:shuaqi/ui/widgets/empty_state.dart';
import 'package:shuaqi/ui/widgets/pressable.dart';
import 'package:shuaqi/ui/widgets/soft_icon.dart';

/// 书架（T1.4 完成态）：导入 / 列表 / 最近打开 / 长按菜单 / 搜索 /
/// 下拉刷新 / 文件损坏态。
///
/// 本页是 app 的主页（外壳第一个 tab）。"我在刷哪些卷子、刷到哪了"
/// 一眼可见；其余入口（记录 / 错题 / 设置）在侧边 rail 或底部 bar。
class BookshelfPage extends ConsumerStatefulWidget {
  const BookshelfPage({super.key});

  @override
  ConsumerState<BookshelfPage> createState() => _BookshelfPageState();
}

class _BookshelfPageState extends ConsumerState<BookshelfPage> {
  bool _importing = false;
  String _stage = '';

  // ── 搜索 ─────────────────────────────────────────────────────────
  // 客户端过滤（书架上限 50 卷，成本为零）：query 只存在本页，
  // 不做成 provider——它是这一页的私有临时状态（state/ 目录的约定）。
  bool _searching = false;
  String _query = '';

  /// 当前文件夹筛选：null = 全部；'' = 未分类；其它 = 指定文件夹。
  String? _folder;

  final TextEditingController _searchController = TextEditingController();

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _pickAndImport() async {
    if (_importing) {
      return;
    }
    List<PlatformFile> picked = const <PlatformFile>[];
    try {
      // file_picker 13 起是静态方法，直接返回 List<PlatformFile>（不再有 FilePickerResult）
      picked = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: <String>['pdf'],
      );
    } on Object catch (error) {
      _toast('打开文件选择器失败：$error');
      return;
    }
    final String? path = picked.singleOrNull?.path;
    if (path == null) {
      return; // 用户取消
    }

    setState(() {
      _importing = true;
      _stage = '准备中';
    });
    try {
      final ImportOutcome outcome = await ref
          .read(workbookImporterProvider)
          .run(
            File(path),
            onProgress: (String stage) {
              if (mounted) {
                setState(() {
                  _stage = stage;
                });
              }
            },
          );
      if (!mounted) {
        return;
      }
      if (outcome.deduped) {
        _toast('这份卷已经导入过了：${outcome.workbook.title}');
      } else {
        _toast(
          '导入完成：${outcome.workbook.title}\n'
          '${outcome.workbook.pageCount} 页 · ${outcome.thumbCount} 张缩略图',
        );
      }
      ref.invalidate(bookshelfProvider);
    } on ImportException catch (error) {
      if (mounted) {
        _toast(error.message);
      }
    } finally {
      if (mounted) {
        setState(() {
          _importing = false;
          _stage = '';
        });
      }
    }
  }

  void _toast(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 4)),
    );
  }

  // ── 长按菜单的三个动作 ────────────────────────────────────────────

  Future<void> _rename(Workbook workbook) async {
    final String? title = await showRenameDialog(
      context,
      initialTitle: workbook.title,
    );
    if (title == null || !mounted) {
      return;
    }
    await ref.read(workbookDaoProvider).rename(workbook.id, title);
    ref.invalidate(bookshelfProvider);
  }

  Future<void> _delete(Workbook workbook) async {
    final bool confirmed = await showDeleteConfirmDialog(
      context,
      title: workbook.title,
    );
    if (!confirmed || !mounted) {
      return;
    }
    // 先库后目录：库里没了，目录就算残留也会被下次启动的 sweepOrphans 收掉；
    // 反过来（目录没了、库还在）会留下一条永远打不开的幽灵记录。
    await ref.read(workbookDaoProvider).delete(workbook.id);
    await ref.read(vaultProvider).deleteWorkbook(workbook.id);
    ref.invalidate(bookshelfProvider);
    _toast('已删除《${workbook.title}》');
  }

  void _openMenu(Workbook workbook) {
    unawaited(
      showWorkbookMenu(
        context,
        workbook: workbook,
        onRename: () => unawaited(_rename(workbook)),
        onEditTags: () => unawaited(_editTags(workbook)),
        onMoveToFolder: () => unawaited(_moveToFolder(workbook)),
        onDelete: () => unawaited(_delete(workbook)),
      ),
    );
  }

  // ── 文件夹与标签（2026-10-23 书架管理）───────────────────────────────

  Future<void> _editTags(Workbook workbook) async {
    final List<String>? tags = await showTagsDialog(
      context,
      initial: workbook.tags,
    );
    if (tags == null || !mounted) {
      return;
    }
    await ref
        .read(workbookDaoProvider)
        .setTags(workbook.id, WorkbookTags.encode(tags));
    ref.invalidate(bookshelfProvider);
    if (mounted) {
      _toast(tags.isEmpty ? '已清除标签' : '标签：${tags.join(' / ')}');
    }
  }

  Future<void> _moveToFolder(Workbook workbook) async {
    final List<Workbook> items =
        ref.read(bookshelfProvider).value ?? const <Workbook>[];
    final String? folder = await showFolderPicker(
      context,
      folders: foldersOf(items),
      current: workbook.folder,
    );
    if (folder == null || !mounted || folder == workbook.folder) {
      return;
    }
    await ref.read(workbookDaoProvider).setFolder(workbook.id, folder);
    ref.invalidate(bookshelfProvider);
    if (mounted) {
      _toast(folder.isEmpty ? '已移到未分类' : '已移到「$folder」');
    }
  }

  void _selectFolder(String? folder) {
    setState(() => _folder = folder);
  }

  /// 重命名文件夹（批量改它下面所有卷的归属）。
  ///
  /// 之前 DAO 里有 `renameFolder` 但没有入口（027 的遗留项）。入口放在
  /// 文件夹 chip 的长按上：用户已经在看这个文件夹，改名是这里最自然的动作。
  Future<void> _renameFolder(String name) async {
    final String? next = await showRenameDialog(
      context,
      initialTitle: name,
      dialogTitle: '重命名文件夹',
      fieldLabel: '文件夹名',
    );
    final String trimmed = next?.trim() ?? '';
    if (trimmed.isEmpty || trimmed == name || !mounted) {
      return;
    }
    await ref.read(workbookDaoProvider).renameFolder(name, trimmed);
    ref.invalidate(bookshelfProvider);
    if (!mounted) {
      return;
    }
    setState(() {
      if (_folder == name) {
        _folder = trimmed;
      }
    });
    _toast('文件夹已重命名为「$trimmed」');
  }

  // ── 搜索 ─────────────────────────────────────────────────────────

  void _toggleSearch() {
    setState(() {
      _searching = !_searching;
      _query = '';
      _searchController.clear();
    });
  }

  // ── 下拉刷新 ─────────────────────────────────────────────────────

  Future<void> _refresh() async {
    ref.invalidate(bookshelfProvider);
    // 等新 future 真正完成，RefreshIndicator 的转圈才会在数据回来后收
    await ref.read(bookshelfProvider.future);
  }

  @override
  Widget build(BuildContext context) {
    final AsyncValue<List<Workbook>> books = ref.watch(bookshelfProvider);

    return Scaffold(
      appBar: AppBar(
        title: _searching
            ? TextField(
                controller: _searchController,
                autofocus: true,
                style: Theme.of(context).textTheme.bodyMedium,
                textInputAction: TextInputAction.search,
                decoration: InputDecoration(
                  hintText: '搜索标题 / 标签 / 文件夹',
                  isDense: true,
                  prefixIcon: const Icon(Icons.search, size: 20),
                  // 有内容才出现清除钮：空搜索框上多一个叉是噪音。
                  suffixIcon: _query.isEmpty
                      ? null
                      : IconButton(
                          tooltip: '清除',
                          icon: const Icon(Icons.close, size: 18),
                          onPressed: () {
                            _searchController.clear();
                            setState(() => _query = '');
                          },
                        ),
                  filled: true,
                  fillColor: Theme.of(context).colorScheme.surfaceContainerHigh,
                  contentPadding: const EdgeInsets.symmetric(vertical: 10),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(ShqRadius.pill),
                    borderSide: BorderSide.none,
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(ShqRadius.pill),
                    borderSide: BorderSide.none,
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(ShqRadius.pill),
                    borderSide: BorderSide(
                      color: Theme.of(context).colorScheme.primary
                          .withValues(alpha: 0.45),
                    ),
                  ),
                ),
                onChanged: (String value) => setState(() => _query = value),
              )
            : const Text('书架'),
        actions: <Widget>[
          IconButton(
            tooltip: _searching ? '退出搜索' : '搜索',
            onPressed: _toggleSearch,
            icon: Icon(_searching ? Icons.close : Icons.search),
          ),
          IconButton(
            tooltip: '刷新',
            onPressed: () => unawaited(_refresh()),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: books.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (Object error, StackTrace stack) => _ErrorView(
          message: '$error',
          onRetry: () => ref.invalidate(bookshelfProvider),
        ),
        data: (List<Workbook> items) {
          final List<String> folders = foldersOf(items);
          final List<Workbook> inFolder = filterByFolder(items, _folder);
          final List<Workbook> visible = filterByQuery(inFolder, _query);
          if (items.isEmpty) {
            return _EmptyView(onImport: _pickAndImport);
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              // 文件夹筛选条：全部 / 未分类 / 各文件夹。
              // 只要书架上有卷就显示 —— 没有它，用户不知道"移动/标签"这套功能存在。
              if (items.isNotEmpty)
                _FolderBar(
                  folders: folders,
                  selected: _folder,
                  onSelected: _selectFolder,
                  onRenameFolder: (String name) =>
                      unawaited(_renameFolder(name)),
                  unfiledCount: items.where((Workbook w) => w.isUnfiled).length,
                  total: items.length,
                ),
              Expanded(
                child: visible.isEmpty
                    ? EmptyState(
                        icon: Icons.search_off_outlined,
                        title: '这里没有卷子',
                        message: _query.isNotEmpty
                            ? '没有匹配「$_query」的卷子，换个词试试'
                            : '这个文件夹还是空的，切回「全部」看看',
                        actionLabel: '清除筛选',
                        actionIcon: Icons.filter_alt_off_outlined,
                        onAction: () => setState(() {
                          _query = '';
                          _searchController.clear();
                          _folder = null;
                        }),
                      )
                    : RefreshIndicator(
                        onRefresh: _refresh,
                        child: _list(visible),
                      ),
              ),
            ],
          );
        },
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _importing ? null : () => unawaited(_pickAndImport()),
        icon: _importing
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.add),
        label: Text(_importing ? _stage : '导入 PDF'),
      ),
    );
  }

  Widget _list(List<Workbook> items) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: ShqLayout.maxReadingWidth),
        child: ListView.separated(
          // 始终可滚动：空结果态时 RefreshIndicator 也需要一个能滚动的 child
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(
            ShqSpace.md,
            ShqSpace.md,
            ShqSpace.md,
            96,
          ),
          itemCount: items.length,
          separatorBuilder: (BuildContext context, int index) =>
              const SizedBox(height: ShqSpace.sm),
          itemBuilder: (BuildContext context, int index) => _WorkbookTile(
            workbook: items[index],
            onTap: () => _open(items[index]),
            onLongPress: () => _openMenu(items[index]),
          ),
        ),
      ),
    );
  }

  void _open(Workbook workbook) {
    unawaited(
      Navigator.of(context).pushNamed(
        AppRoutes.reader,
        arguments: ReaderRouteArgs(workbookId: workbook.id),
      ),
    );
  }
}

class _WorkbookTile extends ConsumerWidget {
  const _WorkbookTile({
    required this.workbook,
    required this.onTap,
    required this.onLongPress,
  });

  final Workbook workbook;

  /// 文件损坏时置灰 + 改弹提示，由本 widget 自己判断（健康探测见
  /// [workbookHealthProvider]）。
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ThemeData theme = Theme.of(context);
    // 缩略图不存在由 errorBuilder 兜底，不用 existsSync 探测（避免 build 里做 IO）
    final File thumb = ref
        .watch(vaultProvider)
        .file(VaultPaths.thumb(workbook.id, 0));

    // 文件损坏态：库里有记录、但 Vault 里的 PDF 没了。书架先置灰告知，
    // 而不是让用户点进去才在阅读器里撞错误。
    final AsyncValue<bool> health = ref.watch(
      workbookHealthProvider(workbook.id),
    );
    final bool broken = health.maybeWhen<bool>(
      data: (bool ok) => !ok,
      orElse: () => false,
    );

    void handleTap() {
      if (broken) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('这份卷的文件缺失了。长按可以删除它，然后重新导入。'),
            duration: Duration(seconds: 4),
          ),
        );
        return;
      }
      onTap();
    }

    return Opacity(
      opacity: broken ? 0.55 : 1,
      child: Pressable(
        onTap: handleTap,
        onLongPress: onLongPress,
        scale: 0.985,
        child: Card(
          clipBehavior: Clip.antiAlias,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              ShqSpace.md,
              ShqSpace.md,
              ShqSpace.sm,
              ShqSpace.md,
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Stack(
                  children: <Widget>[
                    _Thumb(file: thumb),
                    if (broken)
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: 0,
                        child: Container(
                          color: theme.colorScheme.error,
                          padding: const EdgeInsets.symmetric(
                            vertical: ShqSpace.xxs,
                          ),
                          child: Text(
                            '文件缺失',
                            textAlign: TextAlign.center,
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: theme.colorScheme.onError,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(width: ShqSpace.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Expanded(
                            child: Padding(
                              padding: const EdgeInsets.only(top: 2),
                              child: Text(
                                workbook.title,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.titleMedium,
                              ),
                            ),
                          ),
                          // 以前这里只是一个**没人接的** more_vert 图标。
                          // 点它没反应 = 假入口；现在它就是长按菜单的入口。
                          IconButton(
                            tooltip: '更多操作',
                            onPressed: onLongPress,
                            visualDensity: VisualDensity.compact,
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(
                              minWidth: 36,
                              minHeight: 36,
                            ),
                            icon: const Icon(Icons.more_horiz, size: 20),
                          ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Row(
                        children: <Widget>[
                          _Meta(
                            icon: Icons.description_outlined,
                            text: '${workbook.pageCount} 页',
                          ),
                          const SizedBox(width: ShqSpace.md),
                          _Meta(
                            icon: Icons.schedule,
                            text: formatRelativeTime(workbook.sortTime),
                          ),
                        ],
                      ),
                      // 文件夹 + 标签：一行小 chip，看一眼知道这卷归在哪
                      if (!workbook.isUnfiled || workbook.tags.isNotEmpty) ...[
                        const SizedBox(height: ShqSpace.sm),
                        Wrap(
                          spacing: ShqSpace.xs,
                          runSpacing: ShqSpace.xxs,
                          children: <Widget>[
                            if (!workbook.isUnfiled)
                              _Chip(
                                icon: Icons.folder_outlined,
                                label: workbook.folder,
                                emphasized: true,
                              ),
                            for (final String tag in workbook.tags)
                              _Chip(label: '#$tag'),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 卡片元信息（图标 + 一行小字）。
class _Meta extends StatelessWidget {
  const _Meta({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Icon(icon, size: 14, color: scheme.onSurfaceVariant),
        const SizedBox(width: 4),
        Text(
          text,
          style: Theme.of(context).textTheme.bodySmall
              ?.copyWith(color: scheme.onSurfaceVariant),
        ),
      ],
    );
  }
}

/// 书架卡片上的小 chip（文件夹 / 标签）。
class _Chip extends StatelessWidget {
  const _Chip({required this.label, this.icon, this.emphasized = false});

  final String label;
  final IconData? icon;
  final bool emphasized;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Color fg = emphasized ? scheme.primary : scheme.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: (emphasized ? scheme.primary : scheme.outlineVariant).withValues(
          alpha: 0.12,
        ),
        borderRadius: BorderRadius.circular(ShqRadius.sm),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (icon != null) ...<Widget>[
            Icon(icon, size: 12, color: fg),
            const SizedBox(width: 3),
          ],
          Text(
            label,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(color: fg),
          ),
        ],
      ),
    );
  }
}

/// 文件夹筛选条：一条可横向滚动的小 chip 行。
///
/// 设计取舍：不做"左侧文件夹树"——书架是平铺列表，几十卷的场景下
/// 一条横条比一棵树更省地方，也不会把有限的横向空间吃掉一半。
class _FolderBar extends StatelessWidget {
  const _FolderBar({
    required this.folders,
    required this.selected,
    required this.onSelected,
    required this.onRenameFolder,
    required this.unfiledCount,
    required this.total,
  });

  final List<String> folders;

  /// null = 全部；'' = 未分类。
  final String? selected;
  final ValueChanged<String?> onSelected;

  /// 长按文件夹 chip 触发重命名（批量改归属）。
  final ValueChanged<String> onRenameFolder;
  final int unfiledCount;

  /// 书架总卷数（用于右侧的轻量说明，替代原来的"长按卷子…"提示）。
  final int total;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: 52,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: ShqSpace.md),
        children: <Widget>[
          _FolderChip(
            label: '全部',
            icon: Icons.apps,
            selected: selected == null,
            onTap: () => onSelected(null),
          ),
          if (unfiledCount > 0)
            _FolderChip(
              label: '未分类',
              icon: Icons.inbox_outlined,
              selected: selected == '',
              onTap: () => onSelected(''),
            ),
          for (final String folder in folders)
            _FolderChip(
              label: folder,
              icon: Icons.folder_outlined,
              selected: selected == folder,
              onTap: () => onSelected(folder),
              onLongPress: () => onRenameFolder(folder),
            ),
          Padding(
            padding: const EdgeInsets.only(
              left: ShqSpace.xs,
              right: ShqSpace.md,
            ),
            child: Center(
              child: Text(
                folders.isEmpty ? '$total 卷' : '$total 卷 · 长按文件夹改名',
                style: Theme.of(context).textTheme.labelSmall
                    ?.copyWith(color: scheme.outline),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _FolderChip extends StatelessWidget {
  const _FolderChip({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
    this.onLongPress,
  });

  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(right: ShqSpace.sm),
      child: Center(
        child: Pressable(
          onTap: onTap,
          onLongPress: onLongPress,
          scale: 0.94,
          haptic: true,
          child: AnimatedContainer(
            duration: ShqMotion.base,
            curve: ShqMotion.curveEmphasized,
            padding: const EdgeInsets.symmetric(
              horizontal: ShqSpace.md,
              vertical: 6,
            ),
            decoration: BoxDecoration(
              color: selected
                  ? scheme.secondaryContainer
                  : scheme.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(ShqRadius.pill),
              border: Border.all(
                color: selected
                    ? scheme.secondaryContainer
                    : scheme.outlineVariant,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Icon(
                  icon,
                  size: 15,
                  color: selected
                      ? scheme.onSecondaryContainer
                      : scheme.onSurfaceVariant,
                ),
                const SizedBox(width: 5),
                Text(
                  label,
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: selected
                        ? scheme.onSecondaryContainer
                        : scheme.onSurfaceVariant,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Thumb extends StatelessWidget {
  const _Thumb({required this.file});

  final File file;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    return Container(
      width: 64,
      height: 88,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(ShqRadius.sm),
        border: Border.all(color: scheme.outlineVariant),
        // 极浅的投影：只让缩略图从卡片上"浮"起一点点，不抢标题。
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: Colors.black.withValues(
              alpha: scheme.brightness == Brightness.dark ? 0.35 : 0.06,
            ),
            blurRadius: 4,
            offset: const Offset(0, 1),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(ShqRadius.sm - 1),
        child: Image.file(
          file,
          fit: BoxFit.cover,
          errorBuilder:
              (BuildContext context, Object error, StackTrace? stackTrace) {
                return ColoredBox(
                  color: scheme.surfaceContainerHighest,
                  child: Icon(
                    Icons.description_outlined,
                    size: 24,
                    color: scheme.onSurfaceVariant,
                  ),
                );
              },
        ),
      ),
    );
  }
}

class _EmptyView extends StatelessWidget {
  const _EmptyView({required this.onImport});

  final Future<void> Function() onImport;

  @override
  Widget build(BuildContext context) {
    return EmptyState(
      icon: Icons.library_books_outlined,
      title: '还没有导入任何卷子',
      message: '把第一份真题 PDF 导进来，就能开始刷了',
      actionLabel: '导入 PDF',
      onAction: () => unawaited(onImport()),
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(
          maxWidth: ShqLayout.maxNarrativeWidth,
        ),
        child: Padding(
          padding: const EdgeInsets.all(ShqSpace.xl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              SoftIcon(
                icon: Icons.cloud_off_outlined,
                size: 88,
                iconSize: 36,
                circle: true,
                background: scheme.errorContainer.withValues(alpha: 0.45),
                color: scheme.onErrorContainer,
              ),
              const SizedBox(height: ShqSpace.lg),
              Text('书架读取失败', style: theme.textTheme.titleLarge),
              const SizedBox(height: ShqSpace.xs),
              Text(
                message,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: ShqSpace.lg),
              FilledButton.tonalIcon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('重试'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 相对时间。`utcMillis` 是库里存的 UTC 毫秒，显示时转本地。
String formatRelativeTime(int utcMillis, {DateTime? now}) {
  final DateTime at = DateTime.fromMillisecondsSinceEpoch(utcMillis);
  final DateTime current = now ?? DateTime.now();
  final Duration diff = current.difference(at);
  if (diff.inMinutes < 1) {
    return '刚刚';
  }
  if (diff.inHours < 1) {
    return '${diff.inMinutes} 分钟前';
  }
  if (diff.inDays < 1) {
    return '${diff.inHours} 小时前';
  }
  if (diff.inDays < 30) {
    return '${diff.inDays} 天前';
  }
  String two(int value) => value.toString().padLeft(2, '0');
  return '${at.year}-${two(at.month)}-${two(at.day)}';
}
