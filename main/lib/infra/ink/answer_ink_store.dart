import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:shuaqi/domain/answer/answer_paper.dart';
import 'package:shuaqi/domain/ink/ink_doc.dart';
import 'package:shuaqi/domain/ink/ink_scale.dart';
import 'package:shuaqi/domain/ink/ink_store.dart';
import 'package:shuaqi/domain/ink/sif_codec.dart';
import 'package:shuaqi/infra/vault/paths.dart';
import 'package:shuaqi/infra/vault/vault.dart';

/// 答题卡手写笔迹的 SIF 存储（每题每张一份，和 PDF 页笔迹分开）。
///
/// 为什么复用 SIF 而不是新格式：
/// - 笔迹层、撤销、橡皮、压感、编码器全部现成；
/// - 公式/符号识别阶段仍可用同一套 `InkStroke` 输入；
/// - 答题卡是空白画布，不需要 `wb_page` / `ink_state`，所以这里只读写文件。
///
/// 2026-10-24 两处扩展（用户第 1 条）：
/// 1. **多张**：文件名带页码（`<qid>.sif` / `<qid>_p1.sif`……），
///    `InkPageKey.pageIndex` 第一次真正生效；
/// 2. **纸张可换**：编码用当前纸张尺寸；读旧文件时按文件头尺寸与新尺寸
///    等比缩放（`scaleInkDoc`），换纸张不会让旧笔迹挤到左上角。
class AnswerInkStore implements InkStore {
  AnswerInkStore({
    required this.vault,
    required this.workbookId,
    required this.sessionId,
    required this.questionId,
  });

  final Vault vault;
  final String workbookId;
  final String sessionId;
  final String questionId;

  /// 纸张配置的进程内缓存（按卷）。改配置时由调用方 [invalidatePaperCache]。
  static final Map<String, AnswerPaperData> _paperCache =
      <String, AnswerPaperData>{};

  static void invalidatePaperCache(String workbookId) {
    _paperCache.remove(workbookId);
  }

  @override
  Future<InkDoc> load(String sessionId, int pageIndex) async {
    final AnswerPaper paper = await _paper();
    final String relative = VaultPaths.answerInk(
      workbookId,
      this.sessionId,
      questionId,
      pageIndex,
    );
    final File primary = vault.file(relative);
    final _Read read = await _read(primary);
    if (read.doc != null) {
      return _fit(read, paper);
    }
    // 主文件坏了/不存在：尝试 .bak；恢复成功就把备份写回主文件。
    final File backup = vault.file(
      VaultPaths.answerInkBackup(
        workbookId,
        this.sessionId,
        questionId,
        pageIndex,
      ),
    );
    final _Read fallback = await _read(backup);
    if (fallback.doc != null) {
      try {
        await vault.writeAtomically(relative, fallback.bytes!);
      } on Object {
        // 恢复失败不影响本次读取；下一次 save 会重新建立主文件。
      }
      return _fit(fallback, paper);
    }
    return InkDoc.empty;
  }

  @override
  Future<int> save(String sessionId, int pageIndex, InkDoc doc) async {
    final AnswerPaper paper = await _paper();
    final Uint8List bytes = await _encode(doc, paper);
    final String relative = VaultPaths.answerInk(
      workbookId,
      this.sessionId,
      questionId,
      pageIndex,
    );
    final File target = vault.file(relative);
    final File backup = vault.file(
      VaultPaths.answerInkBackup(
        workbookId,
        this.sessionId,
        questionId,
        pageIndex,
      ),
    );
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
    // SIF 本身不存 revision；内存里的 revision 由 InkEditController 维护。
    return doc.revision + 1;
  }

  /// 读当前纸张配置；坏文件/缺失一律回落默认（1000×600 横）。
  Future<AnswerPaper> _paper() async {
    AnswerPaperData data = _paperCache[workbookId] ?? AnswerPaperData.empty;
    if (!_paperCache.containsKey(workbookId)) {
      try {
        final File file = vault.file(VaultPaths.layoutAnswerPaper(workbookId));
        if (file.existsSync()) {
          final Object? decoded = jsonDecode(await file.readAsString());
          if (decoded is Map) {
            data = AnswerPaperData.fromJson(
              decoded.cast<String, Object?>(),
            );
          }
        }
      } on Object {
        data = AnswerPaperData.empty;
      }
      _paperCache[workbookId] = data;
    }
    return data.forQuestion(questionId);
  }

  /// 旧文件的尺寸与新纸张不同 → 按比例搬过去。
  InkDoc _fit(_Read read, AnswerPaper paper) {
    final InkDoc doc = read.doc!;
    final SifPageSize? size = read.size;
    if (size == null) {
      return doc;
    }
    return scaleInkDoc(
      doc,
      fromWidth: size.width,
      fromHeight: size.height,
      toWidth: paper.widthPt,
      toHeight: paper.heightPt,
    );
  }

  Future<Uint8List> _encode(InkDoc doc, AnswerPaper paper) async {
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
