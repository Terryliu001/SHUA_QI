import 'package:flutter/services.dart';
import 'package:shuaqi/domain/app/backup_file.dart';

/// 与 Android 原生 `com.shuaqi.shuaqi/media` 通道的薄封装。
///
/// 0.1.3 新增备份文件管理：
/// - `listBackups`：列出「下载/SHUAQI」里本应用创建的 `SHUAQI_backup*.zip`；
/// - `renameBackup` / `deleteBackup`：按 MediaStore URI（Android 10+）或路径操作；
/// - `importBackupToCache`：把选中的备份复制到应用缓存，交给 `BackupService.restore`；
/// - `openUrl`：打开 GitHub Releases 等外链（不新增 url_launcher 依赖）。
class MediaStoreChannel {
  const MediaStoreChannel();

  static const MethodChannel _channel = MethodChannel(
    'com.shuaqi.shuaqi/media',
  );

  Future<List<BackupFileInfo>> listBackups() async {
    try {
      final List<Object?>? raw = await _channel.invokeMethod<List<Object?>>(
        'listBackups',
      );
      if (raw == null) {
        return const <BackupFileInfo>[];
      }
      final List<BackupFileInfo> out = <BackupFileInfo>[];
      for (final Object? item in raw) {
        if (item is Map) {
          out.add(BackupFileInfo.fromJson(item.cast<String, Object?>()));
        }
      }
      out.sort((BackupFileInfo a, BackupFileInfo b) {
        // 更新前备份置顶，其余按时间倒序。
        if (a.isBeforeUpdate != b.isBeforeUpdate) {
          return a.isBeforeUpdate ? -1 : 1;
        }
        return b.modifiedAt.compareTo(a.modifiedAt);
      });
      return out;
    } on MissingPluginException {
      return const <BackupFileInfo>[];
    } on PlatformException {
      return const <BackupFileInfo>[];
    }
  }

  Future<void> renameBackup(BackupFileInfo info, String newName) async {
    await _channel.invokeMethod<bool>('renameBackup', <String, Object?>{
      'uri': info.uri,
      'path': info.path,
      'name': newName,
    });
  }

  Future<void> deleteBackup(BackupFileInfo info) async {
    await _channel.invokeMethod<bool>('deleteBackup', <String, Object?>{
      'uri': info.uri,
      'path': info.path,
    });
  }

  /// 复制到应用缓存，返回可交给 `BackupService.restore` 的本地路径。
  Future<String?> importBackupToCache(BackupFileInfo info) {
    return _channel.invokeMethod<String>(
      'importBackupToCache',
      <String, Object?>{'uri': info.uri, 'path': info.path, 'name': info.name},
    );
  }

  Future<void> openUrl(String url) async {
    await _channel.invokeMethod<bool>('openUrl', <String, Object?>{'url': url});
  }

  /// 把已存在的本地文件流式复制到「下载/SHUAQI」（备份 zip 用）。
  Future<String?> saveFile({
    required String path,
    required String name,
    String mime = 'application/zip',
  }) {
    return _channel.invokeMethod<String>('saveFile', <String, Object?>{
      'path': path,
      'name': name,
      'mime': mime,
    });
  }

  /// 是否已允许本应用安装 APK（Android 8+ 的「安装未知应用」）。
  Future<bool> canInstallApk() async {
    try {
      return await _channel.invokeMethod<bool>('canInstallApk') ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  /// 拉起系统安装器。失败会抛 PlatformException（签名/版本/权限原因）。
  Future<bool> installApk(String path) async {
    return await _channel.invokeMethod<bool>('installApk', <String, Object?>{
          'path': path,
        }) ??
        false;
  }

  Future<void> openUnknownSourcesSettings() async {
    await _channel.invokeMethod<bool>('openUnknownSourcesSettings');
  }
}
