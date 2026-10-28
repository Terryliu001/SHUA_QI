import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:shuaqi/app/backup/backup_library.dart';
import 'package:shuaqi/app/backup/backup_service.dart';
import 'package:shuaqi/app/storage/storage_error.dart';
import 'package:shuaqi/domain/app/backup_file.dart';
import 'package:shuaqi/domain/app/backup_manifest.dart';
import 'package:shuaqi/domain/app/backup_naming.dart';
import 'package:shuaqi/domain/app/cache_report.dart';
import 'package:shuaqi/state/settings_providers.dart';
import 'package:shuaqi/ui/settings/export_backup_dialog.dart';
import 'package:shuaqi/ui/theme/tokens.dart';

/// 与保存图片、导出 PDF 同一条通道（另加备份 zip 与重启两个方法）。
const MethodChannel _mediaChannel = MethodChannel('com.shuaqi.shuaqi/media');

/// 导出整机备份：先命名弹窗，再打包，落「下载/SHUAQI」。
///
/// 2026-10-28 v0.1.3：与「从备份恢复」一样先弹窗；允许改名字；重名自动加 `-2`。
/// 返回 true = 已成功落盘。
Future<bool> exportBackup(BuildContext context, WidgetRef ref) async {
  final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
  final BackupService service = ref.read(backupServiceProvider);
  final BackupLibrary library = ref.read(backupLibraryProvider);
  BackupCounts counts;
  List<BackupFileInfo> existing = const <BackupFileInfo>[];
  try {
    counts = await service.readCounts();
    existing = await library.list();
  } on Object catch (error) {
    messenger.showSnackBar(
      SnackBar(
        content: Text(storageAwareMessage('读取备份信息', error)),
        behavior: SnackBarBehavior.floating,
      ),
    );
    return false;
  }
  if (!context.mounted) {
    return false;
  }
  final String? base = await showExportBackupDialog(
    context,
    counts: counts,
    defaultName: defaultBackupBaseName(DateTime.now()),
    existingNames: <String>{for (final BackupFileInfo f in existing) f.name},
  );
  if (base == null || !context.mounted) {
    return false;
  }

  Object? result;
  try {
    result = await showDialog<Object?>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) =>
          _BackupProgressDialog(task: service.createBackup(name: base)),
    );
  } on Object catch (error) {
    result = error;
  }
  if (result is! BackupFile) {
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          storageAwareMessage(
            '导出备份',
            result ?? const BackupException('打包没有完成'),
          ),
        ),
        behavior: SnackBarBehavior.floating,
      ),
    );
    return false;
  }
  final BackupFile file = result;
  try {
    await ref
        .read(mediaStoreChannelProvider)
        .saveFile(path: file.path, name: file.name);
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          '已导出到「下载/SHUAQI/${file.name}」（${formatBytes(file.sizeBytes)}）',
        ),
        behavior: SnackBarBehavior.floating,
      ),
    );
    return true;
  } on Object catch (error) {
    messenger.showSnackBar(
      SnackBar(
        content: Text(storageAwareMessage('保存备份', error)),
        behavior: SnackBarBehavior.floating,
      ),
    );
    return false;
  } finally {
    // 临时文件用完即删（备份本体已经在下载目录里了）。
    final File temp = File(file.path);
    if (temp.existsSync()) {
      await temp.delete();
    }
  }
}

/// 从备份恢复：先列出「下载/SHUAQI」里的备份，也可以从文件选择。
Future<void> restoreBackup(BuildContext context, WidgetRef ref) async {
  final BackupFileInfo? info = await _pickBackup(context, ref);
  if (info == null || !context.mounted) {
    return;
  }
  await restoreBackupFromInfo(context, ref, info);
}

/// 用一份指定备份恢复（存储占用页的「恢复」也走这里）。
Future<void> restoreBackupFromInfo(
  BuildContext context,
  WidgetRef ref,
  BackupFileInfo info,
) async {
  final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
  final BackupService service = ref.read(backupServiceProvider);
  final BackupLibrary library = ref.read(backupLibraryProvider);
  String? path = info.path;
  bool imported = false;
  try {
    if (info.uri.isNotEmpty) {
      path = await library.importToCache(info);
      imported = true;
    }
    if (path == null || path.isEmpty) {
      throw const BackupException('找不到这份备份文件');
    }
    final BackupManifest manifest = await service.readManifest(path);
    if (!context.mounted) {
      return;
    }
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('用这份备份覆盖当前数据？'),
        content: Text(
          '备份文件：${info.name}\n'
          '备份时间：${manifest.createdText}\n'
          '包含：${manifest.workbooks} 份试卷 · ${manifest.favorites} 道收藏 · '
          '${manifest.records} 条作答记录\n\n'
          '恢复会替换本机现在的全部数据（卷、笔迹、收藏、记录）。'
          '替换前的内容会先留底一份，出问题可以找回。',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('覆盖恢复'),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) {
      return;
    }
    final RestoreResult result = await service.restore(path, manifest);
    if (!context.mounted) {
      return;
    }
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('恢复完成，需要重启'),
        content: Text(
          '数据已经换好了。\n'
          '重启后生效（否则进程里还握着旧的数据库）。\n\n'
          '替换前的内容留底在：\n${result.stashPath}',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('稍后重启'),
          ),
          FilledButton(
            onPressed: () async {
              try {
                await _mediaChannel.invokeMethod<bool>('restartApp');
              } on Object {
                if (context.mounted) {
                  Navigator.of(context).pop();
                }
              }
            },
            child: const Text('立即重启'),
          ),
        ],
      ),
    );
  } on BackupException catch (error) {
    messenger.showSnackBar(
      SnackBar(
        content: Text(error.message),
        behavior: SnackBarBehavior.floating,
      ),
    );
  } on Object catch (error) {
    messenger.showSnackBar(
      SnackBar(
        content: Text(storageAwareMessage('恢复', error)),
        behavior: SnackBarBehavior.floating,
      ),
    );
  } finally {
    if (imported && path != null) {
      final File temp = File(path);
      if (temp.existsSync()) {
        await temp.delete();
      }
    }
  }
}

/// 重命名一份备份。
Future<bool> renameBackupFile(
  BuildContext context,
  WidgetRef ref,
  BackupFileInfo info,
) async {
  final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
  final TextEditingController controller = TextEditingController(
    text: backupBaseNameOf(info.name),
  );
  String? error;
  final String? base = await showDialog<String>(
    context: context,
    builder: (BuildContext context) => StatefulBuilder(
      builder: (BuildContext context, StateSetter setState) => AlertDialog(
        title: const Text('重命名备份'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(
            labelText: '文件名',
            suffixText: '.zip',
            errorText: error,
            border: const OutlineInputBorder(),
          ),
          onChanged: (_) {
            if (error != null) {
              setState(() => error = null);
            }
          },
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              final String value = sanitizeBackupBaseName(controller.text);
              if (!isValidBackupBaseName(value)) {
                setState(() => error = '文件名不能为空，也不能只有符号');
                return;
              }
              Navigator.of(context).pop(value);
            },
            child: const Text('保存'),
          ),
        ],
      ),
    ),
  );
  controller.dispose();
  if (base == null || !context.mounted) {
    return false;
  }
  try {
    await ref.read(backupLibraryProvider).rename(info, base);
    messenger.showSnackBar(
      SnackBar(
        content: Text('已重命名为 ${ensureZipName(base)}'),
        behavior: SnackBarBehavior.floating,
      ),
    );
    return true;
  } on Object catch (error) {
    messenger.showSnackBar(
      SnackBar(
        content: Text(storageAwareMessage('重命名备份', error)),
        behavior: SnackBarBehavior.floating,
      ),
    );
    return false;
  }
}

/// 删除一份备份。
Future<bool> deleteBackupFile(
  BuildContext context,
  WidgetRef ref,
  BackupFileInfo info,
) async {
  final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
  final bool? ok = await showDialog<bool>(
    context: context,
    builder: (BuildContext context) => AlertDialog(
      title: const Text('删除这份备份？'),
      content: Text(
        '${info.name}\n${formatBytes(info.sizeBytes)}\n\n'
        '删除后无法从应用内恢复；如果这是唯一一份，请先确认不再需要。',
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('删除'),
        ),
      ],
    ),
  );
  if (ok != true || !context.mounted) {
    return false;
  }
  try {
    await ref.read(backupLibraryProvider).delete(info);
    messenger.showSnackBar(
      SnackBar(
        content: Text('已删除 ${info.name}'),
        behavior: SnackBarBehavior.floating,
      ),
    );
    return true;
  } on Object catch (error) {
    messenger.showSnackBar(
      SnackBar(
        content: Text(storageAwareMessage('删除备份', error)),
        behavior: SnackBarBehavior.floating,
      ),
    );
    return false;
  }
}

Future<BackupFileInfo?> _pickBackup(BuildContext context, WidgetRef ref) async {
  List<BackupFileInfo> list = const <BackupFileInfo>[];
  try {
    list = await ref.read(backupLibraryProvider).list();
  } on Object {
    list = const <BackupFileInfo>[];
  }
  if (!context.mounted) {
    return null;
  }
  bool pickFile = false;
  final BackupFileInfo? selected = await showDialog<BackupFileInfo?>(
    context: context,
    builder: (BuildContext context) => AlertDialog(
      title: const Text('从备份恢复'),
      content: SizedBox(
        width: 560,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 420),
          child: list.isEmpty
              ? const Text(
                  '「下载/SHUAQI」里还没有本应用创建的备份。\n'
                  '可以先用「导出备份」生成一份，或从文件选择。',
                )
              : ListView(
                  shrinkWrap: true,
                  children: <Widget>[
                    for (final BackupFileInfo info in list)
                      ListTile(
                        leading: Icon(
                          info.isBeforeUpdate
                              ? Icons.history
                              : Icons.archive_outlined,
                        ),
                        title: Text(
                          info.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          '${_dateText(info.modifiedAt)} · '
                          '${formatBytes(info.sizeBytes)}'
                          '${info.isBeforeUpdate ? ' · 更新前备份' : ''}',
                        ),
                        onTap: () => Navigator.of(context).pop(info),
                      ),
                  ],
                ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () {
            pickFile = true;
            Navigator.of(context).pop();
          },
          child: const Text('从文件选择'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
      ],
    ),
  );
  if (selected != null) {
    return selected;
  }
  if (!pickFile || !context.mounted) {
    return null;
  }
  List<PlatformFile> picked = const <PlatformFile>[];
  try {
    picked = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: <String>['zip'],
    );
  } on Object catch (error) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('打不开文件选择器：$error'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
    return null;
  }
  if (picked.isEmpty) {
    return null;
  }
  final String? path = picked.first.path;
  if (path == null || path.isEmpty) {
    return null;
  }
  final File file = File(path);
  return BackupFileInfo(
    path: path,
    name: p.basename(path),
    sizeBytes: file.existsSync() ? file.lengthSync() : 0,
    modifiedAt: file.existsSync()
        ? file.statSync().modified.millisecondsSinceEpoch
        : 0,
  );
}

String _dateText(int millis) {
  final DateTime date = DateTime.fromMillisecondsSinceEpoch(millis);
  String two(int value) => value.toString().padLeft(2, '0');
  return '${date.year}-${two(date.month)}-${two(date.day)} '
      '${two(date.hour)}:${two(date.minute)}';
}

class _BackupProgressDialog extends StatefulWidget {
  const _BackupProgressDialog({required this.task});

  final Future<BackupFile> task;

  @override
  State<_BackupProgressDialog> createState() => _BackupProgressDialogState();
}

class _BackupProgressDialogState extends State<_BackupProgressDialog> {
  @override
  void initState() {
    super.initState();
    unawaited(
      widget.task.then<void>(
        (BackupFile file) {
          if (mounted) {
            Navigator.of(context).pop(file);
          }
        },
        onError: (Object error) {
          if (mounted) {
            Navigator.of(context).pop(error);
          }
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return PopScope(
      canPop: false,
      child: AlertDialog(
        content: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2.4),
            ),
            const SizedBox(width: ShqSpace.md),
            Flexible(
              child: Text(
                '正在打包…大量笔迹时可能需要几十秒。',
                style: theme.textTheme.bodyMedium,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
