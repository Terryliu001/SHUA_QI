import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:shuaqi/domain/app/cache_report.dart';
import 'package:shuaqi/infra/vault/vault.dart';

/// 存储占用的扫描与缓存清理（IO 层）。
///
/// ## 三条铁律
/// 1. **只删明确的缓存**：缩略图、作答原图裁切、写入中断留下的 `.tmp`。
///    笔迹、切题、收藏、个人空间、反馈草稿一律不碰——它们是用户的东西，
///    不是"重新生成得出来"的缓存。
/// 2. **`.bak` 不删**：SIF/JSON 的上一版备份是磁盘损坏时的唯一退路，
///    占的空间很小，删它等于拿安全性换几十 KB。
/// 3. **删完不猜**：返回实际释放的字节与文件数，UI 直接显示，
///    不出现"已清理"但其实一个字节都没动的情况。
class CacheService {
  CacheService({required this.vault, required this.dbPath});

  final Vault vault;

  /// `AppDatabase.path`。库文件与 `-wal/-shm` 一起算进「数据库」。
  final String dbPath;

  static const String _workbooksRoot = 'workbooks';
  static const String _favoritesRoot = 'favorites';
  static const String _profileRoot = 'profile';
  static const String _feedbackRoot = 'feedback';

  /// 扫描全部占用。**不缓存结果**：用户随时可能导入/删除，宁可每次重扫。
  Future<CacheReport> scan() async {
    final Map<CacheCategory, int> bytes = <CacheCategory, int>{
      for (final CacheCategory category in CacheCategory.values) category: 0,
    };
    final Map<CacheCategory, int> files = <CacheCategory, int>{
      for (final CacheCategory category in CacheCategory.values) category: 0,
    };

    void addFile(CacheCategory category, int size) {
      bytes[category] = (bytes[category] ?? 0) + size;
      files[category] = (files[category] ?? 0) + 1;
    }

    // 1) 每卷目录：原卷 / 缩略图 / layout / 作答原图 / 笔迹 / 临时文件。
    final Directory workbooks = vault.dir(_workbooksRoot);
    if (workbooks.existsSync()) {
      await for (final FileSystemEntity entity in workbooks.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entity is! File) {
          continue;
        }
        final int size = await _sizeOf(entity);
        if (size <= 0) {
          continue;
        }
        final String path = _posix(entity.path);
        if (path.endsWith('.tmp')) {
          addFile(CacheCategory.temp, size);
          continue;
        }
        if (p.basename(path) == 'source.pdf') {
          addFile(CacheCategory.sourcePdf, size);
          continue;
        }
        if (path.contains('/thumb/')) {
          addFile(CacheCategory.thumbnails, size);
          continue;
        }
        if (path.contains('/layout/answer_crops/')) {
          addFile(CacheCategory.answerCrops, size);
          continue;
        }
        if (path.contains('/layout/')) {
          addFile(CacheCategory.layout, size);
          continue;
        }
        if (path.contains('/sessions/')) {
          addFile(CacheCategory.ink, size);
          continue;
        }
        // 其他（meta.json 等）：算进"切题与判题数据"，它同样是用户产物的索引。
        addFile(CacheCategory.layout, size);
      }
    }

    // 2) 顶层目录：收藏 / 个人空间 / 反馈。
    await _addTree(_favoritesRoot, CacheCategory.favorites, addFile);
    await _addTree(_profileRoot, CacheCategory.profile, addFile);
    await _addTree(_feedbackRoot, CacheCategory.feedback, addFile);

    // 3) 数据库（含 WAL 与 SHM）。
    for (final String suffix in const <String>['', '-wal', '-shm']) {
      final File file = File('$dbPath$suffix');
      if (file.existsSync()) {
        addFile(CacheCategory.database, await _sizeOf(file));
      }
    }

    return CacheReport(<CacheEntry>[
      for (final CacheCategory category in CacheCategory.values)
        CacheEntry(
          category: category,
          bytes: bytes[category] ?? 0,
          files: files[category] ?? 0,
        ),
    ]);
  }

  /// 清理缓存。返回真正释放的量。
  ///
  /// 顺序：先量体积，再删，最后返回量出来的值——**不按"应该能删多少"报数**。
  Future<CacheClearResult> clear() async {
    int freedBytes = 0;
    int freedFiles = 0;

    Future<void> dropDirectory(Directory dir) async {
      if (!dir.existsSync()) {
        return;
      }
      await for (final FileSystemEntity entity in dir.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entity is File) {
          freedBytes += await _sizeOf(entity);
          freedFiles += 1;
        }
      }
      await dir.delete(recursive: true);
    }

    final Directory workbooks = vault.dir(_workbooksRoot);
    if (workbooks.existsSync()) {
      await for (final FileSystemEntity entity in workbooks.list(
        followLinks: false,
      )) {
        if (entity is! Directory) {
          continue;
        }
        await dropDirectory(Directory(p.join(entity.path, 'thumb')));
        await dropDirectory(Directory(p.join(entity.path, 'layout', 'answer_crops')));
        // 卷目录里可能躺着中断写入的 .tmp（原子写的半成品）。
        await _dropTempFiles(Directory(entity.path), dropFile: (File file) async {
          freedBytes += await _sizeOf(file);
          freedFiles += 1;
          await file.delete();
        });
      }
    }
    // 收藏 / 个人空间 / 反馈里同样可能有 .tmp（writeAtomically 中断）。
    for (final String root in const <String>[
      _favoritesRoot,
      _profileRoot,
      _feedbackRoot,
    ]) {
      await _dropTempFiles(vault.dir(root), dropFile: (File file) async {
        freedBytes += await _sizeOf(file);
        freedFiles += 1;
        await file.delete();
      });
    }

    return CacheClearResult(bytes: freedBytes, files: freedFiles);
  }

  Future<void> _addTree(
    String root,
    CacheCategory category,
    void Function(CacheCategory, int) addFile,
  ) async {
    final Directory dir = vault.dir(root);
    if (!dir.existsSync()) {
      return;
    }
    await for (final FileSystemEntity entity in dir.list(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is! File) {
        continue;
      }
      final int size = await _sizeOf(entity);
      if (size <= 0) {
        continue;
      }
      // 任何目录下中断写入的 .tmp 都算「临时文件」，不算进所属分类。
      addFile(
        entity.path.endsWith('.tmp') ? CacheCategory.temp : category,
        size,
      );
    }
  }

  /// 删掉一棵目录下所有 `.tmp`（不碰别的文件）。
  Future<void> _dropTempFiles(
    Directory dir, {
    required Future<void> Function(File file) dropFile,
  }) async {
    if (!dir.existsSync()) {
      return;
    }
    await for (final FileSystemEntity entity in dir.list(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is File && entity.path.endsWith('.tmp')) {
        await dropFile(entity);
      }
    }
  }

  static Future<int> _sizeOf(File file) async {
    try {
      return file.statSync().size;
    } on Object {
      return 0;
    }
  }

  static String _posix(String path) => path.replaceAll('\\', '/');
}

/// 清理结果。
class CacheClearResult {
  const CacheClearResult({required this.bytes, required this.files});

  const CacheClearResult.none() : bytes = 0, files = 0;

  final int bytes;
  final int files;
}
