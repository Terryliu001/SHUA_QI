import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shuaqi/app/storage/cache_service.dart';
import 'package:shuaqi/domain/app/backup_file.dart';
import 'package:shuaqi/domain/app/cache_report.dart';
import 'package:shuaqi/state/bookshelf_providers.dart';
import 'package:shuaqi/state/settings_providers.dart';
import 'package:shuaqi/ui/settings/backup_actions.dart';
import 'package:shuaqi/ui/theme/tokens.dart';

/// 「缓存统计与清除」浮层（2026-10-26 用户第 4 条：把"存储与备份"换成缓存管理）。
///
/// 设计口径：
/// - **先说清楚什么是缓存**：能删的标「可清理」，不能删的写一句"删了会怎样"；
/// - **一次只做一件事**：这里只清缓存，不碰备份、删除、归档；
/// - 清完给**实际释放了多少**，不是"已清理"三个字。
Future<void> showCacheSheet(
  BuildContext context,
  WidgetRef ref, {
  bool focusBackup = false,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    backgroundColor: Theme.of(context).colorScheme.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(ShqRadius.xl)),
    ),
    builder: (BuildContext context) => _CacheSheet(focusBackup: focusBackup),
  );
}

class _CacheSheet extends ConsumerStatefulWidget {
  const _CacheSheet({this.focusBackup = false});

  /// true = 打开后直接滚到「备份文件」区（版本说明页的「管理备份文件」用）。
  final bool focusBackup;

  @override
  ConsumerState<_CacheSheet> createState() => _CacheSheetState();
}

class _CacheSheetState extends ConsumerState<_CacheSheet> {
  CacheReport? _report;
  List<BackupFileInfo>? _backups;
  bool _clearing = false;
  bool _backupBusy = false;
  String? _message;

  final GlobalKey _backupKey = GlobalKey();
  bool _focusApplied = false;

  @override
  void initState() {
    super.initState();
    unawaited(_scan());
  }

  Future<void> _scan() async {
    final CacheService service = ref.read(cacheServiceProvider);
    final CacheReport report = await service.scan();
    final List<BackupFileInfo> backups = await ref
        .read(backupLibraryProvider)
        .list();
    if (mounted) {
      setState(() {
        _report = report;
        _backups = backups;
      });
      _maybeFocusBackup();
    }
  }

  /// 从版本说明页点「管理备份文件」进来时，直接滚到备份区，不用再往下翻。
  void _maybeFocusBackup() {
    if (!widget.focusBackup || _focusApplied) {
      return;
    }
    _focusApplied = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final BuildContext? target = _backupKey.currentContext;
      if (target != null) {
        unawaited(
          Scrollable.ensureVisible(
            target,
            duration: const Duration(milliseconds: 320),
            curve: Curves.easeOutCubic,
            alignment: 0.06,
          ),
        );
      }
    });
  }

  Future<void> _reloadBackups() async {
    final List<BackupFileInfo> backups = await ref
        .read(backupLibraryProvider)
        .list();
    if (mounted) {
      setState(() => _backups = backups);
    }
  }

  Future<void> _clear() async {
    if (_clearing) {
      return;
    }
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('清理缓存？'),
        content: const Text(
          '只删可以重新生成的东西：缩略图、作答原图裁切、写入中断留下的临时文件。\n'
          '笔迹、题目框、判题、收藏、反馈草稿都不会动。',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('清理'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) {
      return;
    }
    setState(() {
      _clearing = true;
      _message = null;
    });
    final CacheService service = ref.read(cacheServiceProvider);
    final CacheClearResult result = await service.clear();
    // 内存里的图片缓存也顺手清掉（缩略图与作答原图都缓存在内存里）。
    PaintingBinding.instance.imageCache
      ..clear()
      ..clearLiveImages();
    // 缩略图被删了：让书架重新取图（缺图会走懒重建）。
    ref.read(thumbnailEpochProvider.notifier).bump();
    await _scan();
    if (!mounted) {
      return;
    }
    setState(() {
      _clearing = false;
      _message = cacheClearedMessage(bytes: result.bytes, files: result.files);
    });
  }

  Future<void> _export() async {
    if (_backupBusy) {
      return;
    }
    setState(() => _backupBusy = true);
    final bool ok = await exportBackup(context, ref);
    if (!mounted) {
      return;
    }
    setState(() => _backupBusy = false);
    if (ok) {
      await _reloadBackups();
    }
  }

  Future<void> _restore(BackupFileInfo info) async {
    await restoreBackupFromInfo(context, ref, info);
  }

  Future<void> _rename(BackupFileInfo info) async {
    final bool ok = await renameBackupFile(context, ref, info);
    if (ok) {
      await _reloadBackups();
    }
  }

  Future<void> _delete(BackupFileInfo info) async {
    final bool ok = await deleteBackupFile(context, ref, info);
    if (ok) {
      await _reloadBackups();
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final CacheReport? report = _report;
    final List<BackupFileInfo>? backups = _backups;
    final int backupBytes = backups == null
        ? 0
        : backups.fold<int>(
            0,
            (int sum, BackupFileInfo f) => sum + f.sizeBytes,
          );
    return FractionallySizedBox(
      heightFactor: 0.78,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(
              ShqSpace.lg,
              0,
              ShqSpace.lg,
              ShqSpace.sm,
            ),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text('存储占用', style: theme.textTheme.titleLarge),
                      const SizedBox(height: 2),
                      Text(
                        report == null
                            ? '正在统计…'
                            : '缓存 ${formatBytes(report.totalBytes)}'
                                  ' · 备份 ${backups == null ? '统计中…' : formatBytes(backupBytes)}',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: '重新统计',
                  onPressed: _clearing ? null : _scan,
                  icon: const Icon(Icons.refresh),
                ),
              ],
            ),
          ),
          Divider(height: 1, color: scheme.outlineVariant),
          Expanded(
            child: report == null
                ? const Center(child: CircularProgressIndicator())
                : ListView(
                    padding: const EdgeInsets.fromLTRB(
                      ShqSpace.lg,
                      ShqSpace.sm,
                      ShqSpace.lg,
                      ShqSpace.lg,
                    ),
                    children: <Widget>[
                      for (final CacheEntry entry in report.entries)
                        _CategoryRow(entry: entry),
                      const SizedBox(height: ShqSpace.sm),
                      Divider(height: 1, color: scheme.outlineVariant),
                      Padding(
                        key: _backupKey,
                        padding: const EdgeInsets.only(
                          top: ShqSpace.md,
                          bottom: ShqSpace.xs,
                        ),
                        child: Row(
                          children: <Widget>[
                            Text(
                              '备份文件',
                              style: theme.textTheme.titleSmall?.copyWith(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(width: ShqSpace.sm),
                            Text(
                              backups == null
                                  ? '正在读取…'
                                  : '${backups.length} 份 · ${formatBytes(backupBytes)}',
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (backups == null)
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: ShqSpace.md),
                          child: LinearProgressIndicator(minHeight: 2),
                        )
                      else if (backups.isEmpty)
                        Padding(
                          padding: const EdgeInsets.symmetric(
                            vertical: ShqSpace.sm,
                          ),
                          child: Text(
                            '还没有备份。更新前会自动备份，也可以点下面的「导出备份」。',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                              height: 1.5,
                            ),
                          ),
                        )
                      else
                        for (final BackupFileInfo info in backups)
                          _BackupRow(
                            info: info,
                            busy: _backupBusy,
                            onRestore: () => unawaited(_restore(info)),
                            onRename: () => unawaited(_rename(info)),
                            onDelete: () => unawaited(_delete(info)),
                          ),
                    ],
                  ),
          ),
          Divider(height: 1, color: scheme.outlineVariant),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              ShqSpace.lg,
              ShqSpace.md,
              ShqSpace.lg,
              ShqSpace.lg,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                // 清理结果放在**底部固定区**：真机验证时它藏在列表中间，
                // 清完根本看不见（用户会以为没清）。
                if (_message != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: ShqSpace.sm),
                    child: Container(
                      padding: const EdgeInsets.all(ShqSpace.sm),
                      decoration: BoxDecoration(
                        color: scheme.secondaryContainer.withValues(alpha: 0.5),
                        borderRadius: BorderRadius.circular(ShqRadius.md),
                        border: Border.all(color: scheme.outlineVariant),
                      ),
                      child: Text(
                        _message!,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurface,
                        ),
                      ),
                    ),
                  ),
                Text(
                  report == null
                      ? ''
                      : '可清理 ${formatBytes(report.clearableBytes)}',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: ShqSpace.sm),
                Wrap(
                  alignment: WrapAlignment.end,
                  spacing: ShqSpace.sm,
                  runSpacing: ShqSpace.sm,
                  children: <Widget>[
                    OutlinedButton.icon(
                      onPressed: _backupBusy ? null : _export,
                      icon: _backupBusy
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.archive_outlined, size: 18),
                      label: Text(_backupBusy ? '处理中…' : '导出备份'),
                    ),
                    FilledButton.icon(
                      onPressed:
                          report == null || !report.hasClearable || _clearing
                          ? null
                          : _clear,
                      icon: _clearing
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(
                              Icons.cleaning_services_outlined,
                              size: 18,
                            ),
                      label: Text(_clearing ? '清理中…' : '清理缓存'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _BackupRow extends StatelessWidget {
  const _BackupRow({
    required this.info,
    required this.busy,
    required this.onRestore,
    required this.onRename,
    required this.onDelete,
  });

  final BackupFileInfo info;
  final bool busy;
  final VoidCallback onRestore;
  final VoidCallback onRename;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: <Widget>[
          Icon(
            info.isBeforeUpdate ? Icons.history : Icons.archive_outlined,
            size: 18,
            color: scheme.onSurfaceVariant,
          ),
          const SizedBox(width: ShqSpace.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Flexible(
                      child: Text(
                        info.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium,
                      ),
                    ),
                    if (info.isBeforeUpdate) ...<Widget>[
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 5,
                          vertical: 1,
                        ),
                        decoration: BoxDecoration(
                          color: scheme.primary.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(ShqRadius.pill),
                        ),
                        child: Text(
                          '更新前',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: scheme.primary,
                            fontSize: 10,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 1),
                Text(
                  '${_dateText(info.modifiedAt)} · ${formatBytes(info.sizeBytes)}',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.outline,
                  ),
                ),
              ],
            ),
          ),
          PopupMenuButton<String>(
            enabled: !busy,
            tooltip: '备份操作',
            onSelected: (String value) {
              switch (value) {
                case 'restore':
                  onRestore();
                case 'rename':
                  onRename();
                case 'delete':
                  onDelete();
              }
            },
            itemBuilder: (BuildContext context) =>
                const <PopupMenuEntry<String>>[
                  PopupMenuItem<String>(
                    value: 'restore',
                    child: ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(Icons.restore),
                      title: Text('恢复'),
                    ),
                  ),
                  PopupMenuItem<String>(
                    value: 'rename',
                    child: ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(Icons.edit_outlined),
                      title: Text('重命名'),
                    ),
                  ),
                  PopupMenuItem<String>(
                    value: 'delete',
                    child: ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(Icons.delete_outline),
                      title: Text('删除'),
                    ),
                  ),
                ],
          ),
        ],
      ),
    );
  }
}

String _dateText(int millis) {
  final DateTime date = DateTime.fromMillisecondsSinceEpoch(millis);
  String two(int value) => value.toString().padLeft(2, '0');
  return '${date.year}-${two(date.month)}-${two(date.day)} '
      '${two(date.hour)}:${two(date.minute)}';
}

class _CategoryRow extends StatelessWidget {
  const _CategoryRow({required this.entry});

  final CacheEntry entry;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: ShqSpace.sm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Text(
                      entry.category.label,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (entry.category.clearable) ...<Widget>[
                      const SizedBox(width: ShqSpace.sm),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: scheme.primary.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(ShqRadius.pill),
                        ),
                        child: Text(
                          '可清理',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: scheme.primary,
                            fontSize: 10,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  entry.category.hint,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                    height: 1.5,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: ShqSpace.md),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: <Widget>[
              Text(
                formatBytes(entry.bytes),
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              Text(
                '${entry.files} 个文件',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: scheme.outline,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
