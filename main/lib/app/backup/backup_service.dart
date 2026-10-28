import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;
import 'package:shuaqi/domain/app/backup_manifest.dart';
import 'package:shuaqi/domain/app/backup_naming.dart';
import 'package:shuaqi/infra/db/app_database.dart';
import 'package:shuaqi/infra/db/migrations.dart';
import 'package:shuaqi/infra/vault/vault.dart';

/// 整机备份 / 恢复（2026-10-26 用户第 4 条：把「存储与备份」做成真的）。
///
/// ## 备份里有什么
/// ```
/// manifest.json   版本 / 库版本 / 时间 / 卷数 / 收藏数 / 记录数
/// shuaqi.db       数据库（做题索引、收藏、作答记录）
/// vault/…         整个 Vault：原卷、笔迹、切题、个人空间、反馈草稿
/// ```
/// 不含：无（vault 全量包含缩略图；若备份本身是在清缓存后导出的，
/// 恢复后书架会按需重建缩略图）。
///
/// ## 为什么先 checkpoint
/// SQLite 开了 WAL，最新的写入可能还在 `-wal` 里。备份前
/// `PRAGMA wal_checkpoint(TRUNCATE)` 把 WAL 并回主库，**只拷一个文件**就是完整数据。
/// （Android 8 的 SQLite 3.19 没有 `VACUUM INTO`，这条路走不通。）
///
/// ## 恢复为什么需要重启
/// 恢复要把库文件整file换掉；进程里已有的数据库句柄指向旧 inode，
/// 不重启就会出现"读到的还是旧数据"。所以恢复流程是：
/// 校验 → 解到临时目录 → **把当前数据整体挪到留底目录** → 换入新数据 →
/// 交给原生侧重启 Activity。留底目录保留，出问题用户还能找回。
class BackupService {
  BackupService({
    required this.db,
    required this.vault,
    required this.supportPath,
    required this.appVersion,
  });

  final AppDatabase db;
  final Vault vault;

  /// 应用私有根目录（`AppDependencies.supportPath`）。临时 zip 与留底都放这儿。
  final String supportPath;

  final String appVersion;

  /// 备份产物的临时路径目录。
  Directory get _workDir => Directory(p.join(supportPath, 'backup_work'));

  Directory get _stashRoot => Directory(p.join(supportPath, 'restore_stash'));

  /// 生成备份 zip，返回文件路径（调用方负责把它交给系统保存并删除）。
  ///
  /// [name] 是**不含 `.zip`** 的基名（用户可改）；不传时用默认时间名。
  Future<BackupFile> createBackup({String? name}) async {
    final Directory work = _workDir;
    if (work.existsSync()) {
      await work.delete(recursive: true);
    }
    await work.create(recursive: true);

    // 1) 把 WAL 并回主库，保证单文件即完整数据。
    try {
      await db.raw.execute('PRAGMA wal_checkpoint(TRUNCATE)');
    } on Object {
      // checkpoint 失败不阻断：退化成"可能漏掉最近几秒写入"，比直接不给备份好。
    }

    // 2) 统计（manifest 里的数字，用来在恢复前让用户确认"是不是这份"）。
    final BackupCounts counts = await readCounts();

    final DateTime now = DateTime.now();
    final String base = name == null
        ? defaultBackupBaseName(now)
        : sanitizeBackupBaseName(name);
    final String safeBase = base.isEmpty ? defaultBackupBaseName(now) : base;
    final String zipName = ensureZipName(safeBase);
    final String zipPath = p.join(work.path, zipName);

    final ZipFileEncoder encoder = ZipFileEncoder();
    encoder.create(zipPath);

    final Map<String, Object?> manifest = <String, Object?>{
      'app_version': appVersion,
      'db_version': kDatabaseVersion,
      'created_at': now.millisecondsSinceEpoch,
      'created_at_text': _readable(now),
      'workbooks': counts.workbooks,
      'favorites': counts.favorites,
      'records': counts.records,
    };
    encoder.addArchiveFile(
      ArchiveFile.string('manifest.json', jsonEncode(manifest)),
    );

    final File dbFile = File(db.path);
    if (dbFile.existsSync()) {
      await encoder.addFile(dbFile, 'shuaqi.db');
    }

    // 3) Vault 全量（跳过 .tmp：那是半截文件）。
    await _addDirectory(
      encoder,
      vault.root,
      'vault',
      skip: (File file) => file.path.endsWith('.tmp'),
    );

    await encoder.close();

    return BackupFile(
      path: zipPath,
      name: zipName,
      sizeBytes: File(zipPath).lengthSync(),
      manifest: BackupManifest.fromJson(manifest),
    );
  }

  /// 导出对话框用的统计（不生成 zip）。
  Future<BackupCounts> readCounts() async {
    return BackupCounts(
      workbooks: await _count('workbook'),
      favorites: await _count('favorite'),
      records: await _count('answer_log'),
    );
  }

  /// 只读 manifest（不整包解压）。
  Future<BackupManifest> readManifest(String zipPath) async {
    final InputFileStream input = InputFileStream(zipPath);
    try {
      final Archive archive = ZipDecoder().decodeStream(input);
      final ArchiveFile? entry = archive.find('manifest.json');
      if (entry == null) {
        throw const BackupException('这个 zip 里没有 manifest.json，不是本应用的备份');
      }
      final List<int>? bytes = entry.readBytes();
      if (bytes == null) {
        throw const BackupException('备份信息读不出来，文件可能损坏');
      }
      final Object? decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is! Map) {
        throw const BackupException('备份信息格式不对');
      }
      return BackupManifest.fromJson(decoded.cast<String, Object?>());
    } on BackupException {
      rethrow;
    } on Object catch (error) {
      throw BackupException('这个文件读不出来（$error），换一个备份试试');
    } finally {
      await input.close();
    }
  }

  /// 恢复。**调用前必须先让用户确认覆盖**。
  ///
  /// 成功后返回 [RestoreResult.needRestart] = true：调用方负责触发重启。
  Future<RestoreResult> restore(String zipPath, BackupManifest manifest) async {
    if (!manifest.canRestoreOn(kDatabaseVersion)) {
      throw BackupException(
        '这份备份来自更新的版本（库 v${manifest.dbVersion}，本机 v$kDatabaseVersion），'
        '请先升级应用再恢复',
      );
    }

    final Directory staging = Directory(p.join(supportPath, 'restore_staging'));
    if (staging.existsSync()) {
      await staging.delete(recursive: true);
    }
    await staging.create(recursive: true);

    // 1) 解包（整体读入再解码：安装包级别的大小，且有 512MB 上限兜底）。
    final int zipSize = File(zipPath).lengthSync();
    if (zipSize > 512 * 1024 * 1024) {
      throw const BackupException('备份文件超过 512MB，暂不支持恢复这么大的包');
    }
    final Archive archive = ZipDecoder().decodeBytes(
      await File(zipPath).readAsBytes(),
    );
    await extractArchiveToDisk(archive, staging.path);

    final File newDb = File(p.join(staging.path, 'shuaqi.db'));
    final Directory newVault = Directory(p.join(staging.path, 'vault'));
    if (!newDb.existsSync()) {
      throw const BackupException('备份里没有数据库文件，无法恢复');
    }

    // 2) 留底：当前库与 Vault 整体挪走（不删，出问题还能手工找回）。
    final Directory stash = Directory(
      p.join(_stashRoot.path, _stamp(DateTime.now())),
    );
    await stash.create(recursive: true);

    await db.close();
    try {
      await _moveInto(File(db.path), File(p.join(stash.path, 'shuaqi.db')));
      for (final String suffix in const <String>['-wal', '-shm']) {
        final File side = File('${db.path}$suffix');
        if (side.existsSync()) {
          await _moveInto(side, File(p.join(stash.path, 'shuaqi.db$suffix')));
        }
      }
      if (vault.root.existsSync()) {
        await _moveInto(vault.root, Directory(p.join(stash.path, 'vault')));
      }

      // 3) 换入新数据。
      await newDb.copy(db.path);
      if (newVault.existsSync()) {
        await _copyDirectory(newVault, vault.root);
      }
    } on Object catch (error) {
      // 换入失败：尽力回滚（把留底挪回去），然后如实报错。
      try {
        await _rollback(stash);
      } on Object {
        // 回滚也失败——只能让用户看到留底路径。
      }
      throw BackupException('恢复失败（$error）。原始数据已留在：${stash.path}');
    } finally {
      if (staging.existsSync()) {
        await staging.delete(recursive: true);
      }
    }

    return RestoreResult(
      needRestart: true,
      stashPath: stash.path,
      manifest: manifest,
    );
  }

  Future<void> _rollback(Directory stash) async {
    final File stashedDb = File(p.join(stash.path, 'shuaqi.db'));
    if (stashedDb.existsSync()) {
      await stashedDb.copy(db.path);
    }
    final Directory stashedVault = Directory(p.join(stash.path, 'vault'));
    if (stashedVault.existsSync()) {
      if (vault.root.existsSync()) {
        await vault.root.delete(recursive: true);
      }
      await _copyDirectory(stashedVault, vault.root);
    }
  }

  Future<int> _count(String table) async {
    try {
      final List<Map<String, Object?>> rows = await db.raw.rawQuery(
        'SELECT COUNT(*) AS c FROM $table',
      );
      return (rows.first['c'] as num?)?.toInt() ?? 0;
    } on Object {
      return 0;
    }
  }

  static Future<void> _addDirectory(
    ZipFileEncoder encoder,
    Directory dir,
    String prefix, {
    required bool Function(File file) skip,
  }) async {
    if (!dir.existsSync()) {
      return;
    }
    await for (final FileSystemEntity entity in dir.list(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is! File || skip(entity)) {
        continue;
      }
      final String rel = p.relative(entity.path, from: dir.path);
      final String name = '$prefix/${rel.replaceAll('\\', '/')}';
      await encoder.addFile(entity, name);
    }
  }

  static Future<void> _moveInto(
    FileSystemEntity source,
    FileSystemEntity target,
  ) async {
    if (source is File) {
      await (target as File).parent.create(recursive: true);
    } else if (source is Directory) {
      await (target as Directory).parent.create(recursive: true);
    }
    await source.rename(target.path);
  }

  static Future<void> _copyDirectory(Directory source, Directory target) async {
    await target.create(recursive: true);
    await for (final FileSystemEntity entity in source.list(
      recursive: true,
      followLinks: false,
    )) {
      final String rel = p.relative(entity.path, from: source.path);
      final String dest = p.join(target.path, rel);
      if (entity is Directory) {
        await Directory(dest).create(recursive: true);
      } else if (entity is File) {
        await File(dest).parent.create(recursive: true);
        await entity.copy(dest);
      }
    }
  }

  static String _stamp(DateTime at) =>
      '${at.year}${_two(at.month)}${_two(at.day)}-${_two(at.hour)}${_two(at.minute)}';

  static String _two(int value) => value.toString().padLeft(2, '0');

  static String _readable(DateTime at) =>
      '${at.year}-${_two(at.month)}-${_two(at.day)} ${_two(at.hour)}:${_two(at.minute)}';
}

/// 生成好的备份文件。
class BackupFile {
  const BackupFile({
    required this.path,
    required this.name,
    required this.sizeBytes,
    required this.manifest,
  });

  final String path;
  final String name;
  final int sizeBytes;
  final BackupManifest manifest;
}

/// 导出前展示的备份内容统计。
class BackupCounts {
  const BackupCounts({
    required this.workbooks,
    required this.favorites,
    required this.records,
  });

  final int workbooks;
  final int favorites;
  final int records;

  bool get isEmpty => workbooks == 0 && favorites == 0 && records == 0;

  String get summary => '$workbooks 份试卷 · $favorites 道收藏 · $records 条作答记录';
}

/// 恢复结果。
class RestoreResult {
  const RestoreResult({
    required this.needRestart,
    required this.stashPath,
    required this.manifest,
  });

  final bool needRestart;

  /// 恢复前的数据留底目录（出问题能找回）。
  final String stashPath;

  final BackupManifest manifest;
}

/// 备份/恢复的可预期失败（文案直接给用户看）。
class BackupException implements Exception {
  const BackupException(this.message);

  final String message;

  @override
  String toString() => 'BackupException: $message';
}
