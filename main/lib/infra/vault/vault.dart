import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:shuaqi/infra/vault/paths.dart';

/// Vault：应用私有目录下的文件仓库（规格 T1.3）。
///
/// 只做"文件系统层面正确"的事：建目录、原子写、复制、删除、枚举。
/// **不认识数据库、不认识 PDF**——"先写文件还是先写库"的编排在 `app/import`。
///
/// 三条硬规矩：
/// 1. **原子写**：先写 `.tmp` 再 rename。rename 在同一文件系统上是原子的，
///    中途被杀进程只会留下 `.tmp`，不会留下"半个 source.pdf"。
/// 2. **不覆盖**：目标存在时抛异常，而不是静默覆盖——覆盖等于丢用户的卷。
/// 3. **删除只删单卷目录**，绝不 `delete(recursive: true)` 整个 Vault。
class Vault {
  Vault._(this.root);

  /// 打开（必要时创建）Vault 根目录。
  ///
  /// 生产环境由 `bootstrap` 用 `getApplicationSupportDirectory()` 传入；
  /// 测试可以传临时目录。
  static Future<Vault> open(String rootPath) async {
    final Directory dir = Directory(rootPath);
    await dir.create(recursive: true);
    return Vault._(dir);
  }

  final Directory root;

  String get rootPath => root.path;

  /// 相对路径 → 绝对 File。**路径拼装全在 [VaultPaths]，这里只做一次 join**。
  File file(String relativePath) => File(p.join(root.path, relativePath));

  Directory dir(String relativePath) => Directory(p.join(root.path, relativePath));

  bool exists(String relativePath) => file(relativePath).existsSync();

  Future<void> ensureDir(String relativePath) async {
    await dir(relativePath).create(recursive: true);
  }

  /// 原子写字节。适合 meta.json、缩略图这类小文件。
  Future<File> writeAtomically(String relativePath, List<int> bytes) async {
    final File target = file(relativePath);
    await target.parent.create(recursive: true);
    final File temp = File('${target.path}.tmp');
    await temp.writeAsBytes(bytes, flush: true);
    return temp.rename(target.path);
  }

  /// 把外部文件"收编"进 Vault：流式复制到 `.tmp`，再 rename。
  ///
  /// **流式**是必须的：20MB 的卷用 `readAsBytes` 会瞬间吃掉 20MB 堆内存，
  /// 而导入过程本身还要渲染缩略图。
  Future<File> adoptFile(String relativePath, File source) async {
    final File target = file(relativePath);
    if (target.existsSync()) {
      throw VaultException('目标已存在，拒绝覆盖：${target.path}');
    }
    await target.parent.create(recursive: true);
    final File temp = File('${target.path}.tmp');

    final IOSink sink = temp.openWrite();
    try {
      await sink.addStream(source.openRead());
    } finally {
      await sink.flush();
      await sink.close();
    }
    return temp.rename(target.path);
  }

  /// 删除一卷的全部产物（目录整棵）。
  Future<void> deleteWorkbook(String workbookId) async {
    final Directory dir = this.dir(VaultPaths.workbookDir(workbookId));
    if (dir.existsSync()) {
      await dir.delete(recursive: true);
    }
  }

  /// 删除一条收藏的全部快照文件（目录整棵）。
  Future<void> deleteFavoriteDir(String favoriteId) async {
    final Directory dir = this.dir(VaultPaths.favoriteDir(favoriteId));
    if (dir.existsSync()) {
      await dir.delete(recursive: true);
    }
  }

  /// 磁盘上现有的卷 id 列表（孤儿清理用）。
  Future<List<String>> workbookIdsOnDisk() async {
    final Directory root = dir(VaultPaths.workbooksRoot);
    if (!root.existsSync()) {
      return const <String>[];
    }
    final List<String> ids = <String>[];
    await for (final FileSystemEntity entity in root.list()) {
      if (entity is Directory) {
        ids.add(p.basename(entity.path));
      }
    }
    ids.sort();
    return ids;
  }
}

/// Vault 层面的可预期错误（不是编程错误，是要给用户看的提示）。
class VaultException implements Exception {
  const VaultException(this.message);

  final String message;

  @override
  String toString() => 'VaultException: $message';
}
