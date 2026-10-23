import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

// ignore_for_file: avoid_slow_async_io
// 上面的 lint 建议用同步 IO；SIF 文件最大 16MB，同步读会卡 UI isolate，
// 这里刻意用异步（编码本身也在 ink-io isolate 里）。

import 'package:shuaqi/domain/ink/ink_doc.dart';
import 'package:shuaqi/domain/ink/ink_store.dart';
import 'package:shuaqi/domain/ink/sif_codec.dart';
import 'package:shuaqi/domain/model/wb_page.dart';
import 'package:shuaqi/infra/db/dao/ink_state_dao.dart';
import 'package:shuaqi/infra/db/dao/page_dao.dart';
import 'package:shuaqi/infra/vault/paths.dart';
import 'package:shuaqi/infra/vault/vault.dart';
import 'package:sqflite/sqflite.dart';

/// SIF v1 的 [InkStore] 实现（T2.4）。
///
/// 编排（文件在 `infra`，不在 domain）：
/// 1. `save`：查页尺寸 → **isolate 里 zlib 编码** → 旧文件 rename 成 `.bak`
///    → `.sif.tmp` 写入 + flush → rename 成 `.sif` → 更新 `ink_state`；
/// 2. `load`：查 `ink_state.sif_path` → 主文件解码；失败读 `.bak`；
///    两者都失败则返回空页并把 [InkLoadIssue.corrupt] 报给 UI（原文件保留）。
///
/// 同一页的 `save` 在 store 内也串行（writer 已经串行，这里是第二道保险）。
class SifInkStore implements InkStore, InkIssueReporter {
  SifInkStore({
    required this.vault,
    required this.db,
    required this.workbookId,
  });

  final Vault vault;
  final Database db;
  final String workbookId;

  /// 单文件上限：正常 5000 笔 < 400KB；16MB 已经离谱，按损坏处理。
  static const int maxSifBytes = 16 * 1024 * 1024;

  final Map<String, InkLoadIssue> _issues = <String, InkLoadIssue>{};
  final Map<String, Future<void>> _queues = <String, Future<void>>{};

  @override
  InkLoadIssue takeLoadIssue(String sessionId, int pageIndex) {
    return _issues.remove(_keyOf(sessionId, pageIndex)) ?? InkLoadIssue.none;
  }

  @override
  Future<InkDoc> load(String sessionId, int pageIndex) async {
    final PageDao pages = PageDao(db);
    final WbPage? page = await pages.byIndex(workbookId, pageIndex);
    if (page == null) {
      return InkDoc.empty;
    }
    final InkStateDao states = InkStateDao(db);
    final InkStateRow? state = await states.find(page.id, sessionId);
    final String primaryPath =
        state?.sifPath ??
        VaultPaths.inkFile(workbookId, sessionId, pageIndex);

    final _ReadResult primary = await _read(primaryPath);
    if (primary.doc != null) {
      return _withRevision(primary.doc!, state?.revision ?? 0);
    }

    final _ReadResult backup = await _read(
      VaultPaths.inkFileBackup(workbookId, sessionId, pageIndex),
    );
    if (backup.doc != null) {
      // 把备份写回主文件：下一次 save 就会以"可读的旧版"做 .bak，
      // 否则 save 会把损坏的主文件 rename 成 .bak，覆盖掉唯一的好备份。
      final Uint8List? bytes = backup.bytes;
      if (bytes != null) {
        try {
          await vault.writeAtomically(primaryPath, bytes);
        } on Object {
          // 恢复失败不影响本次阅读；只是下一次保存前仍然只有 .bak 可用。
        }
      }
      _issues[_keyOf(sessionId, pageIndex)] = InkLoadIssue.recoveredFromBackup;
      return _withRevision(backup.doc!, state?.revision ?? 0);
    }

    // 文件根本不存在 = 这一页还没写过，是正常状态；只要有一个"曾经写过"的
    // 证据（state 行 / 两个文件至少一个存在）才报损坏。
    final bool expected = state != null || primary.exists || backup.exists;
    if (expected) {
      _issues[_keyOf(sessionId, pageIndex)] = InkLoadIssue.corrupt;
    }
    return InkDoc.empty;
  }

  @override
  Future<int> save(
    String sessionId,
    int pageIndex,
    InkDoc doc,
  ) {
    final String key = _keyOf(sessionId, pageIndex);
    final Future<void> previous = _queues[key] ?? Future<void>.value();
    final Future<int> task = previous.then(
      (_) => _saveNow(sessionId, pageIndex, doc),
    );
    // 队列只记"完成"（哪怕失败），后一次保存仍然要继续。
    _queues[key] = task.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return task;
  }

  Future<int> _saveNow(
    String sessionId,
    int pageIndex,
    InkDoc doc,
  ) async {
    final WbPage? page = await PageDao(db).byIndex(workbookId, pageIndex);
    if (page == null) {
      throw StateError(
        'SIF 保存失败：卷 $workbookId 没有第 $pageIndex 页',
      );
    }
    final SifPageSize size = SifPageSize(page.width, page.height);
    final Uint8List bytes = await _encode(doc, size);

    final String relative = VaultPaths.inkFile(workbookId, sessionId, pageIndex);
    final File target = vault.file(relative);
    await target.parent.create(recursive: true);
    final File temp = vault.file(
      VaultPaths.inkFileTemp(workbookId, sessionId, pageIndex),
    );
    final File backup = vault.file(
      VaultPaths.inkFileBackup(workbookId, sessionId, pageIndex),
    );

    if (await temp.exists()) {
      await temp.delete();
    }
    // 旧版先留 .bak。即使旧文件坏了也留：它是"最后一次可读的版本"，
    // 覆盖成新内容前至少要留住它，直到新文件 rename 成功。
    if (await target.exists()) {
      if (await backup.exists()) {
        await backup.delete();
      }
      await target.rename(backup.path);
    }

    try {
      await temp.writeAsBytes(bytes, flush: true);
      await temp.rename(target.path);
    } on Object {
      // 新文件没写成：把旧版还回去，宁可保留上一版也不能让这一页消失。
      if (!await target.exists() && await backup.exists()) {
        await backup.rename(target.path);
      }
      rethrow;
    }

    final InkStateDao states = InkStateDao(db);
    final InkStateRow? existing = await states.find(page.id, sessionId);
    final int revision = (existing?.revision ?? 0) + 1;
    await states.upsert(
      pageId: page.id,
      sessionId: sessionId,
      revision: revision,
      strokeCount: doc.strokeCount,
      byteSize: bytes.length,
      sifPath: relative,
      nowUtcMillis: DateTime.now().toUtc().millisecondsSinceEpoch,
    );
    return revision;
  }

  Future<_ReadResult> _read(String relativePath) async {
    final File file = vault.file(relativePath);
    if (!await file.exists()) {
      return const _ReadResult.missing();
    }
    try {
      final int length = await file.length();
      if (length <= 0 || length > maxSifBytes) {
        return const _ReadResult.corrupt();
      }
      final Uint8List bytes = await file.readAsBytes();
      final InkDoc doc = await _decode(bytes);
      return _ReadResult.ok(doc, bytes);
    } on Object {
      return const _ReadResult.corrupt();
    }
  }

  /// 编码放到 `ink-io` isolate；isolate 起不来（极少数环境）退回同步，
  /// 但**不允许因为隔离失败而丢笔**。
  Future<Uint8List> _encode(InkDoc doc, SifPageSize size) async {
    try {
      return await Isolate.run<Uint8List>(() => SifCodec.encode(doc, size));
    } on Object {
      return SifCodec.encode(doc, size);
    }
  }

  Future<InkDoc> _decode(Uint8List bytes) async {
    try {
      return await Isolate.run<InkDoc>(() => SifCodec.decode(bytes));
    } on Object {
      return SifCodec.decode(bytes);
    }
  }

  static InkDoc _withRevision(InkDoc doc, int revision) {
    return doc.copyWith(revision: revision);
  }

  static String _keyOf(String sessionId, int pageIndex) =>
      '$sessionId#$pageIndex';
}

enum _ReadStatus { ok, missing, corrupt }

class _ReadResult {
  const _ReadResult.ok(this.doc, this.bytes) : status = _ReadStatus.ok;

  const _ReadResult.missing()
    : doc = null,
      bytes = null,
      status = _ReadStatus.missing;

  const _ReadResult.corrupt()
    : doc = null,
      bytes = null,
      status = _ReadStatus.corrupt;

  final InkDoc? doc;
  final Uint8List? bytes;
  final _ReadStatus status;

  /// 文件在磁盘上（无论能不能解码）。
  bool get exists => status != _ReadStatus.missing;
}
