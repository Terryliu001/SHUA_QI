import 'package:shuaqi/domain/app/backup_file.dart';
import 'package:shuaqi/domain/app/backup_naming.dart';
import 'package:shuaqi/infra/platform/media_store_channel.dart';

/// 备份文件的查看/重命名/删除/导入（0.1.3）。
///
/// 只管「下载/SHUAQI」里本应用创建的 `SHUAQI_*.zip`；恢复动作仍由
/// `BackupService` 负责（这里只把文件取到本地路径）。
class BackupLibrary {
  const BackupLibrary(this.channel);

  final MediaStoreChannel channel;

  Future<List<BackupFileInfo>> list() => channel.listBackups();

  Future<void> rename(BackupFileInfo info, String baseName) {
    final String safe = sanitizeBackupBaseName(baseName);
    if (safe.isEmpty) {
      throw const FormatException('备份名不能为空');
    }
    return channel.renameBackup(info, ensureZipName(safe));
  }

  Future<void> delete(BackupFileInfo info) => channel.deleteBackup(info);

  Future<String?> importToCache(BackupFileInfo info) =>
      channel.importBackupToCache(info);
}
