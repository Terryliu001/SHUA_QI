import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shuaqi/app/import/import_workbook.dart';
import 'package:shuaqi/domain/model/workbook.dart';
import 'package:shuaqi/infra/vault/paths.dart';
import 'package:shuaqi/state/app_providers.dart';
import 'package:shuaqi/ui/router.dart';
import 'package:shuaqi/ui/theme/tokens.dart';

/// 书架（T1.4）。当前做到"能导入、能看见导入的卷、能点开"，
/// 搜索 / 长按菜单 / 下拉刷新 / 3 列网格留给 T1.4 的剩余部分。
class BookshelfPage extends ConsumerStatefulWidget {
  const BookshelfPage({super.key});

  @override
  ConsumerState<BookshelfPage> createState() => _BookshelfPageState();
}

class _BookshelfPageState extends ConsumerState<BookshelfPage> {
  bool _importing = false;
  String _stage = '';

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

  @override
  Widget build(BuildContext context) {
    final AsyncValue<List<Workbook>> books = ref.watch(bookshelfProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('书架'),
        actions: <Widget>[
          IconButton(
            tooltip: '刷新',
            onPressed: () => ref.invalidate(bookshelfProvider),
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
        data: (List<Workbook> items) =>
            items.isEmpty ? _EmptyView(onImport: _pickAndImport) : _list(items),
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
          padding: const EdgeInsets.fromLTRB(
            ShqSpace.md,
            ShqSpace.md,
            ShqSpace.md,
            96,
          ),
          itemCount: items.length,
          separatorBuilder: (BuildContext context, int index) =>
              const SizedBox(height: ShqSpace.sm),
          itemBuilder: (BuildContext context, int index) =>
              _WorkbookTile(workbook: items[index]),
        ),
      ),
    );
  }
}

class _WorkbookTile extends ConsumerWidget {
  const _WorkbookTile({required this.workbook});

  final Workbook workbook;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ThemeData theme = Theme.of(context);
    // 缩略图不存在由 errorBuilder 兜底，不用 existsSync 探测（避免 build 里做 IO）
    final File thumb = ref
        .watch(vaultProvider)
        .file(VaultPaths.thumb(workbook.id, 0));

    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => unawaited(
          Navigator.of(context).pushNamed(
            AppRoutes.reader,
            arguments: ReaderRouteArgs(workbookId: workbook.id),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(ShqSpace.md),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              _Thumb(file: thumb),
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
                    if (workbook.layoutStatus == 'missing')
                      Text(
                        '文件缺失',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: ShqPalette.wrong,
                        ),
                      ),
                  ],
                ),
              ),
            ],
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
    final ThemeData theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(ShqSpace.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              Icons.library_books_outlined,
              size: 56,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: ShqSpace.md),
            Text('还没有导入任何卷子', style: theme.textTheme.titleLarge),
            const SizedBox(height: ShqSpace.sm),
            Text(
              '把第一份真题 PDF 导进来，就能开始刷了',
              style: theme.textTheme.bodyMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: ShqSpace.lg),
            FilledButton.icon(
              onPressed: () => unawaited(onImport()),
              icon: const Icon(Icons.file_open_outlined),
              label: const Text('导入 PDF'),
            ),
          ],
        ),
      ),
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
