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
        onDelete: () => unawaited(_delete(workbook)),
      ),
    );
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
                decoration: const InputDecoration(
                  hintText: '搜索卷子',
                  border: InputBorder.none,
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
          final List<Workbook> visible = filterByQuery(items, _query);
          if (items.isEmpty) {
            return _EmptyView(onImport: _pickAndImport);
          }
          if (visible.isEmpty) {
            // 有卷但搜索无果：单独的空态，别把"导入第一份"的引导露出来
            return const EmptyState(
              icon: Icons.search_off_outlined,
              title: '没有匹配的卷子',
              message: '换个标题关键词试试',
            );
          }
          return RefreshIndicator(
            onRefresh: _refresh,
            child: _list(visible),
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
      child: Card(
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: handleTap,
          onLongPress: onLongPress,
          child: Padding(
            padding: const EdgeInsets.all(ShqSpace.md),
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
                      Text(
                        workbook.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleMedium,
                      ),
                      const SizedBox(height: ShqSpace.xs),
                      Text(
                        '${workbook.pageCount} 页 · ${formatRelativeTime(workbook.sortTime)}',
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                Icon(
                  Icons.more_vert,
                  color: theme.colorScheme.onSurfaceVariant,
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
    return ClipRRect(
      borderRadius: BorderRadius.circular(ShqRadius.sm),
      child: SizedBox(
        width: 60,
        height: 80,
        child: Image.file(
          file,
          fit: BoxFit.cover,
          errorBuilder:
              (BuildContext context, Object error, StackTrace? stackTrace) {
                return ColoredBox(
                  color: theme.colorScheme.surfaceContainerHighest,
                  child: Icon(
                    Icons.description_outlined,
                    size: 24,
                    color: theme.colorScheme.onSurfaceVariant,
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
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(ShqSpace.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text('书架读取失败', style: theme.textTheme.titleLarge),
            const SizedBox(height: ShqSpace.sm),
            Text(message, style: theme.textTheme.bodySmall),
            const SizedBox(height: ShqSpace.lg),
            OutlinedButton(onPressed: onRetry, child: const Text('重试')),
          ],
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
