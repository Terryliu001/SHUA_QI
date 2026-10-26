import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:shuaqi/app/favorite/favorite_redo_paper_store.dart';
import 'package:shuaqi/domain/answer/answer_paper.dart';
import 'package:shuaqi/domain/ink/ink_doc.dart';
import 'package:shuaqi/domain/ink/ink_scale.dart';
import 'package:shuaqi/domain/ink/ink_store.dart';
import 'package:shuaqi/domain/ink/sif_codec.dart';
import 'package:shuaqi/infra/vault/paths.dart';
import 'package:shuaqi/infra/vault/vault.dart';

/// 收藏题「二刷」的笔迹存储（T8.3b）。
///
/// 为什么单独一套：
/// - 二刷是**收藏夹里重写一遍**，不能覆盖收藏时定格的 `answer.png`（那是第一次作答的证据）；
/// - 原卷可能已删，不能落到 `workbooks/<id>/sessions/...` 里；
/// - 所以按收藏 id 存 `favorites/<id>/ink/pN.sif`，和快照同生共死。
///
/// 纸张（尺寸/方向/纸样式/张数）是**每道收藏一份**（`favorites/<id>/paper.json`）：
/// 换尺寸时按 `scaleInkDoc` 把旧笔迹等比搬过去，不会挤到左上角；
/// `pageIndex` 就是第几张纸，每张一份 SIF。
class FavoriteRedoInkStore implements InkStore {
  FavoriteRedoInkStore({
    required this.vault,
    required this.favoriteId,
    this.attemptId,
  }) : _papers = FavoriteRedoPaperStore(vault);

  final Vault vault;
  final String favoriteId;

  /// 这一次重刷的 attempt；null/空 = 旧版共享笔迹（兼容旧调用点）。
  final String? attemptId;

  final FavoriteRedoPaperStore _papers;

  AnswerPaper? _paper;

  /// 纸张配置（进程内缓存；换纸张后由调用方 invalidate 本 store）。
  Future<AnswerPaper> _paperOf() async {
    return _paper ??= await _papers.load(favoriteId, attemptId: attemptId);
  }

  String _inkPath(int pageIndex) {
    final String id = (attemptId ?? '').trim();
    return id.isEmpty
        ? VaultPaths.favoriteInkSif(favoriteId, pageIndex)
        : VaultPaths.favoriteRedoInkSif(favoriteId, id, pageIndex);
  }

  String _backupPath(int pageIndex) {
    final String id = (attemptId ?? '').trim();
    return id.isEmpty
        ? VaultPaths.favoriteInkSifBackup(favoriteId, pageIndex)
        : VaultPaths.favoriteRedoInkSifBackup(favoriteId, id, pageIndex);
  }

  @override
  Future<InkDoc> load(String sessionId, int pageIndex) async {
    final String relative = _inkPath(pageIndex);
    final _Read read = await _read(vault.file(relative));
    if (read.doc != null) {
      return _fit(read);
    }
    final String backup = _backupPath(pageIndex);
    final _Read fallback = await _read(vault.file(backup));
    if (fallback.doc != null) {
      try {
        await vault.writeAtomically(relative, fallback.bytes!);
      } on Object {
        // 恢复失败不影响本次读取；下一次 save 会重建主文件。
      }
      return _fit(fallback);
    }
    return InkDoc.empty;
  }

  @override
  Future<int> save(String sessionId, int pageIndex, InkDoc doc) async {
    final Uint8List bytes = await _encode(doc);
    final String relative = _inkPath(pageIndex);
    final File target = vault.file(relative);
    final File backup = vault.file(_backupPath(pageIndex));
    await target.parent.create(recursive: true);
    if (target.existsSync()) {
      if (backup.existsSync()) {
        backup.deleteSync();
      }
      target.renameSync(backup.path);
    }
    try {
      await vault.writeAtomically(relative, bytes);
    } on Object {
      // 新文件没写成：把旧版还回去，宁可保留上一版也不让这一题消失。
      if (!target.existsSync() && backup.existsSync()) {
        backup.renameSync(target.path);
      }
      rethrow;
    }
    return doc.revision + 1;
  }

  Future<InkDoc> _fit(_Read read) async {
    final InkDoc doc = read.doc!;
    final SifPageSize? size = read.size;
    if (size == null) {
      return doc;
    }
    final AnswerPaper paper = await _paperOf();
    return scaleInkDoc(
      doc,
      fromWidth: size.width,
      fromHeight: size.height,
      toWidth: paper.widthPt,
      toHeight: paper.heightPt,
    );
  }

  Future<Uint8List> _encode(InkDoc doc) async {
    final AnswerPaper paper = await _paperOf();
    final SifPageSize size = SifPageSize(paper.widthPt, paper.heightPt);
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

  Future<_Read> _read(File file) async {
    if (!file.existsSync()) {
      return const _Read.missing();
    }
    try {
      final Uint8List bytes = await file.readAsBytes();
      final InkDoc doc = await _decode(bytes);
      return _Read(doc, bytes, SifCodec.readPageSize(bytes));
    } on Object {
      return const _Read.missing();
    }
  }
}

class _Read {
  const _Read(this.doc, this.bytes, this.size);

  const _Read.missing() : doc = null, bytes = null, size = null;

  final InkDoc? doc;
  final Uint8List? bytes;
  final SifPageSize? size;
}
