import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:shuaqi/domain/model/wb_page.dart';
import 'package:shuaqi/domain/model/workbook.dart';
import 'package:shuaqi/domain/util/ulid.dart';
import 'package:shuaqi/infra/db/app_database.dart';
import 'package:shuaqi/infra/db/dao/page_dao.dart';
import 'package:shuaqi/infra/db/dao/workbook_dao.dart';
import 'package:shuaqi/infra/pdf/pdfrx_source.dart';
import 'package:shuaqi/infra/vault/file_hash.dart';
import 'package:shuaqi/infra/vault/paths.dart';
import 'package:shuaqi/infra/vault/vault.dart';
import 'package:sqflite/sqflite.dart';

/// 一次导入的结果。
class ImportOutcome {
  const ImportOutcome({
    required this.workbook,
    required this.thumbCount,
    required this.deduped,
  });

  final Workbook workbook;

  /// 成功生成的缩略图数量（失败不影响导入，只影响书架观感）。
  final int thumbCount;

  /// true 表示命中 sha1 查重，**没有产生任何新文件**，直接返回已有的卷。
  final bool deduped;
}

/// 导入失败时抛它，message 可直接给用户看。
class ImportException implements Exception {
  const ImportException(this.message, [this.cause]);

  final String message;
  final Object? cause;

  @override
  String toString() => 'ImportException: $message${cause == null ? '' : ' ($cause)'}';
}

/// 导入管线（规格 T1.3）：选文件 → 指纹查重 → 复制进 Vault → 读页数页尺寸 →
/// 生成缩略图 → 落库。**原子、可重入、失败可清理**。
///
/// 执行顺序刻意是「建目录 → 写文件 → **事务落库** → 缩略图」：
/// - 目录/文件在前：数据库里出现记录时，磁盘一定已经有原卷（不会出现"点开是空的"）。
/// - 缩略图在最后：它只是观感，失败了不该让整次导入回滚。
///
/// 任何一步失败都会删掉本次创建的卷目录，保证**不会留下半截数据**。
class WorkbookImporter {
  WorkbookImporter({
    required this.db,
    required this.vault,
    this.thumbnailWidth = 240,
    this.firstPageThumbs = 3,
    this.thumbEvery = 10,
  });

  final AppDatabase db;
  final Vault vault;

  /// 缩略图宽度（px）。书架只用它，绝不拿原图缩放当封面（吃内存）。
  final int thumbnailWidth;

  /// 前几页都出缩略图（用户最常看开头）。
  final int firstPageThumbs;

  /// 之后每隔几页出一张。
  final int thumbEvery;

  /// [onProgress] 会被频繁调用，参数是给用户看的中文阶段名。
  Future<ImportOutcome> run(
    File picked, {
    void Function(String stage)? onProgress,
    DateTime? now,
  }) async {
    if (!picked.existsSync()) {
      throw ImportException('文件不存在：${picked.path}');
    }

    onProgress?.call('计算指纹');
    final String sha1Hex = await sha1OfFile(picked);

    final WorkbookDao books = WorkbookDao(db.raw);
    final Workbook? existing = await books.bySha1(sha1Hex);
    if (existing != null) {
      return ImportOutcome(workbook: existing, thumbCount: 0, deduped: true);
    }

    final String id = Ulid.next();
    final int createdAt = (now ?? DateTime.now()).toUtc().millisecondsSinceEpoch;
    final String title = _titleOf(picked);
    bool dirCreated = false;

    try {
      onProgress?.call('建立目录');
      await vault.ensureDir(VaultPaths.workbookDir(id));
      dirCreated = true;

      onProgress?.call('复制原卷');
      final File adopted = await vault.adoptFile(
        VaultPaths.sourcePdf(id),
        picked,
      );

      onProgress?.call('读取页信息');
      final PdfrxSource source = await PdfrxSource.openFile(adopted.path);
      int thumbCount = 0;
      try {
        final List<WbPage> pages = List<WbPage>.generate(
          source.pageCount,
          (int index) {
            final ui.Size size = source.pageSize(index);
            return WbPage(
              id: Ulid.next(),
              workbookId: id,
              index: index,
              width: size.width,
              height: size.height,
            );
          },
          growable: false,
        );

        final Workbook workbook = Workbook(
          id: id,
          title: title,
          sha1: sha1Hex,
          pageCount: pages.length,
          pageSize: _summaryPageSize(pages),
          sourcePath: VaultPaths.sourcePdf(id),
          createdAt: createdAt,
        );

        onProgress?.call('写元数据');
        await vault.writeAtomically(
          VaultPaths.metaJson(id),
          utf8.encode(
            jsonEncode(<String, Object?>{
              'id': id,
              'title': title,
              'sha1': sha1Hex,
              'page_count': pages.length,
              'page_size': workbook.pageSize,
              'created_at': createdAt,
              'note': '冗余副本，以数据库为准',
            }),
          ),
        );

        onProgress?.call('写入数据库');
        await db.tx((Transaction txn) async {
          await WorkbookDao(txn).insert(workbook);
          await PageDao(txn).insertMany(pages);
        });

        // 缩略图是"锦上添花"，失败不回滚整次导入
        onProgress?.call('生成缩略图');
        try {
          thumbCount = await _writeThumbs(source, id, pages.length);
        } on Object {
          thumbCount = 0;
        }

        return ImportOutcome(
          workbook: workbook,
          thumbCount: thumbCount,
          deduped: false,
        );
      } finally {
        await source.dispose();
      }
    } on Object catch (error) {
      // 回滚：删掉本次建的目录；数据库那边由事务保证没写进去
      if (dirCreated) {
        try {
          await vault.deleteWorkbook(id);
        } on Object {
          // 清理失败也不能掩盖原始错误
        }
      }
      if (error is ImportException) {
        rethrow;
      }
      throw ImportException('导入失败：$error', error);
    }
  }

  Future<int> _writeThumbs(PdfrxSource source, String id, int pageCount) async {
    await vault.ensureDir(VaultPaths.thumbDir(id));
    int written = 0;
    for (final int index in _thumbPages(pageCount)) {
      final Uint8List png = await source.renderThumb(
        index,
        widthPx: thumbnailWidth,
      );
      if (png.isEmpty) {
        continue;
      }
      await vault.writeAtomically(VaultPaths.thumb(id, index), png);
      written++;
    }
    return written;
  }

  /// 前 [firstPageThumbs] 页 + 之后每 [thumbEvery] 页一页。返回**升序去重**的页码。
  List<int> _thumbPages(int pageCount) {
    final Set<int> pages = <int>{};
    for (int i = 0; i < pageCount && i < firstPageThumbs; i++) {
      pages.add(i);
    }
    for (int i = thumbEvery; i < pageCount; i += thumbEvery) {
      pages.add(i);
    }
    if (pageCount > 0) {
      pages.add(pageCount - 1);
    }
    final List<int> sorted = pages.toList()..sort();
    return sorted;
  }

  static String _summaryPageSize(List<WbPage> pages) {
    if (pages.isEmpty) {
      return '0x0';
    }
    final WbPage first = pages.first;
    return '${first.width}x${first.height}';
  }

  static String _titleOf(File file) {
    final String name = file.uri.pathSegments.isEmpty
        ? file.path
        : file.uri.pathSegments.last;
    final int dot = name.lastIndexOf('.');
    final String stem = dot > 0 ? name.substring(0, dot) : name;
    return stem.trim().isEmpty ? '未命名试卷' : stem.trim();
  }
}

/// 启动时的孤儿清理（规格 T1.3 的坑）。
///
/// 两种情况都要处理，但**处置方式不同**：
/// - 目录有、库里没有 → 上次导入在"写完文件、落库前"崩了 → **删目录**（数据本来就不完整）；
/// - 库里有、目录没有 → 用户手动删了文件/清理工具误删 → **标记为损坏**，不删记录
///   （卷的题目、设置还可能有价值，且删除是不可逆的）。
///
/// 返回被清理的目录数与被标记损坏的卷数。
class OrphanSweepResult {
  const OrphanSweepResult({required this.removedDirs, required this.markedMissing});

  final int removedDirs;
  final int markedMissing;
}

Future<OrphanSweepResult> sweepOrphans({
  required AppDatabase db,
  required Vault vault,
}) async {
  final WorkbookDao books = WorkbookDao(db.raw);
  final List<Workbook> inDb = await books.listByRecent(limit: 100000);
  final Set<String> dbIds = inDb.map((Workbook book) => book.id).toSet();
  final List<String> diskIds = await vault.workbookIdsOnDisk();
  final Set<String> diskSet = diskIds.toSet();

  int removed = 0;
  for (final String id in diskIds) {
    if (!dbIds.contains(id)) {
      await vault.deleteWorkbook(id);
      removed++;
    }
  }

  int marked = 0;
  for (final Workbook book in inDb) {
    if (!diskSet.contains(book.id)) {
      await books.setLayoutStatus(book.id, 'missing');
      marked++;
    }
  }

  return OrphanSweepResult(removedDirs: removed, markedMissing: marked);
}
