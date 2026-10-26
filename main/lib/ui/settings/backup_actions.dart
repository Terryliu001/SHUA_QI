import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shuaqi/app/backup/backup_service.dart';
import 'package:shuaqi/domain/app/backup_manifest.dart';
import 'package:shuaqi/domain/app/cache_report.dart';
import 'package:shuaqi/state/settings_providers.dart';
/// 与保存图片、导出 PDF 同一条通道（另加备份 zip 与重启两个方法）。
const MethodChannel _mediaChannel = MethodChannel('com.shuaqi.shuaqi/media');

/// 导出整机备份：库 + Vault 一起打进 zip，落到「下载/SHUAQI」。
///
/// 为什么不把字节读进内存再走通道：备份可能上百 MB。原生侧提供
/// `saveFile`（按路径流式复制），Dart 这边只传路径。
Future<void> exportBackup(BuildContext context, WidgetRef ref) async {
  final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
  final BackupService service = ref.read(backupServiceProvider);
  try {
    final BackupFile file = await service.createBackup();
    try {
      await _mediaChannel.invokeMethod<String>('saveFile', <String, Object>{
        'path': file.path,
        'name': file.name,
        'mime': 'application/zip',
      });
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            '已导出到「下载/SHUAQI/${file.name}」'
            '（${formatBytes(file.sizeBytes)}）',
          ),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } finally {
      // 临时文件用完即删（备份本体已经在下载目录里了）。
      final File temp = File(file.path);
      if (temp.existsSync()) {
        await temp.delete();
      }
    }
  } on Object catch (error) {
    messenger.showSnackBar(
      SnackBar(
        content: Text('导出失败：$error'),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }
}

/// 从备份恢复。
///
/// 三道闸：① 必须是本应用导出的 zip（有 manifest）；② 库版本不能比本机新；
/// ③ 明确告知"会覆盖当前所有数据"并要用户确认。恢复完必须重启。
Future<void> restoreBackup(BuildContext context, WidgetRef ref) async {
  final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
  List<PlatformFile> picked = const <PlatformFile>[];
  try {
    picked = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: <String>['zip'],
    );
  } on Object catch (error) {
    messenger.showSnackBar(
      SnackBar(
        content: Text('打不开文件选择器：$error'),
        behavior: SnackBarBehavior.floating,
      ),
    );
    return;
  }
  if (picked.isEmpty || !context.mounted) {
    return;
  }
  final String? path = picked.first.path;
  if (path == null || path.isEmpty) {
    return;
  }
  final BackupService service = ref.read(backupServiceProvider);
  BackupManifest manifest;
  try {
    manifest = await service.readManifest(path);
  } on BackupException catch (error) {
    messenger.showSnackBar(
      SnackBar(
        content: Text(error.message),
        behavior: SnackBarBehavior.floating,
      ),
    );
    return;
  }

  if (!context.mounted) {
    return;
  }
  final bool? ok = await showDialog<bool>(
    context: context,
    builder: (BuildContext context) => AlertDialog(
      title: const Text('用这份备份覆盖当前数据？'),
      content: Text(
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

  try {
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
                // 重启失败就让用户手动杀进程：至少把话说清楚。
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
        content: Text('恢复失败：$error'),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }
}
