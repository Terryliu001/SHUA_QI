import 'dart:convert';
import 'dart:io';

import 'package:shuaqi/domain/answer/answer_paper.dart';
import 'package:shuaqi/domain/model/redo_attempt.dart';
import 'package:shuaqi/infra/vault/paths.dart';
import 'package:shuaqi/infra/vault/vault.dart';

/// 重刷 attempt 的文件读写（`favorites/<id>/redo/<attemptId>/`）。
///
/// 旧版只有一份 `favorites/<id>/ink/pN.sif` + `paper.json`；首次打开时
/// 自动迁移成一个 `legacy-<时间>` attempt，不丢已有重刷笔迹。
class RedoAttemptStore {
  const RedoAttemptStore(this._vault);

  final Vault _vault;

  Future<List<RedoAttempt>> list(String favoriteId) async {
    await _migrateLegacy(favoriteId);
    final Directory root = _vault.dir(
      '${VaultPaths.favoriteDir(favoriteId)}/redo',
    );
    if (!root.existsSync()) {
      return const <RedoAttempt>[];
    }
    final List<RedoAttempt> out = <RedoAttempt>[];
    await for (final FileSystemEntity entity in root.list()) {
      if (entity is! Directory) {
        continue;
      }
      final String attemptId = entity.path.split(Platform.pathSeparator).last;
      final RedoAttempt? attempt = await load(favoriteId, attemptId);
      if (attempt != null) {
        out.add(attempt);
      }
    }
    out.sort((RedoAttempt a, RedoAttempt b) => b.updatedAt.compareTo(a.updatedAt));
    return out;
  }

  Future<RedoAttempt?> load(String favoriteId, String attemptId) async {
    try {
      final File file = _vault.file(
        VaultPaths.favoriteRedoMeta(favoriteId, attemptId),
      );
      if (!file.existsSync()) {
        return null;
      }
      final Object? decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) {
        return null;
      }
      final RedoAttempt attempt = RedoAttempt.fromJson(
        decoded.cast<String, Object?>(),
      );
      if (attempt.id.isEmpty || attempt.favoriteId != favoriteId) {
        return null;
      }
      return attempt;
    } on Object {
      return null;
    }
  }

  Future<RedoAttempt> create({
    required String favoriteId,
    required String attemptId,
    required DateTime now,
    String setId = '',
    String setTitle = '',
    AnswerPaper paper = AnswerPaper.defaults,
  }) async {
    final RedoAttempt attempt = RedoAttempt(
      id: attemptId,
      favoriteId: favoriteId,
      createdAt: now.millisecondsSinceEpoch,
      updatedAt: now.millisecondsSinceEpoch,
      setId: setId,
      setTitle: setTitle,
      saved: false,
      paperPages: paper.pages,
      paperSummary: paper.summary,
    );
    await saveMeta(attempt);
    await savePaper(favoriteId, attemptId, paper);
    return attempt;
  }

  Future<void> saveMeta(RedoAttempt attempt) async {
    await _vault.writeAtomically(
      VaultPaths.favoriteRedoMeta(attempt.favoriteId, attempt.id),
      utf8.encode(jsonEncode(attempt.toJson())),
    );
  }

  Future<AnswerPaper> loadPaper(String favoriteId, String attemptId) async {
    try {
      final File file = _vault.file(
        VaultPaths.favoriteRedoPaperOf(favoriteId, attemptId),
      );
      if (!file.existsSync()) {
        return AnswerPaper.defaults;
      }
      final Object? decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) {
        return AnswerPaper.defaults;
      }
      return AnswerPaper.fromJson(decoded.cast<String, Object?>());
    } on Object {
      return AnswerPaper.defaults;
    }
  }

  Future<void> savePaper(
    String favoriteId,
    String attemptId,
    AnswerPaper paper,
  ) async {
    await _vault.writeAtomically(
      VaultPaths.favoriteRedoPaperOf(favoriteId, attemptId),
      utf8.encode(jsonEncode(paper.toJson())),
    );
  }

  Future<void> delete(String favoriteId, String attemptId) async {
    final Directory dir = _vault.dir(
      VaultPaths.favoriteRedoAttemptDir(favoriteId, attemptId),
    );
    if (dir.existsSync()) {
      await dir.delete(recursive: true);
    }
  }

  /// 旧版单份重刷 → 一个 legacy attempt。幂等：已有 attempt 就跳过。
  Future<void> _migrateLegacy(String favoriteId) async {
    final Directory root = _vault.dir(
      '${VaultPaths.favoriteDir(favoriteId)}/redo',
    );
    if (root.existsSync()) {
      final bool hasAttempt = await root
          .list()
          .any((FileSystemEntity entity) => entity is Directory);
      if (hasAttempt) {
        return;
      }
    }
    final File legacyInk = _vault.file(VaultPaths.favoriteInkSif(favoriteId, 0));
    if (!legacyInk.existsSync()) {
      return;
    }
    final int stamp = legacyInk.statSync().modified.millisecondsSinceEpoch;
    final String attemptId = 'legacy-$stamp';
    final Directory target = _vault.dir(
      VaultPaths.favoriteRedoAttemptDir(favoriteId, attemptId),
    );
    await target.create(recursive: true);

    // 旧版最多 9 张纸（与 AnswerPaper.maxPages 一致）。
    for (int i = 0; i < 9; i += 1) {
      final File source = _vault.file(VaultPaths.favoriteInkSif(favoriteId, i));
      if (!source.existsSync()) {
        continue;
      }
      await _vault.writeAtomically(
        VaultPaths.favoriteRedoInkSif(favoriteId, attemptId, i),
        await source.readAsBytes(),
      );
      final File backup = _vault.file(
        VaultPaths.favoriteInkSifBackup(favoriteId, i),
      );
      if (backup.existsSync()) {
        await _vault.writeAtomically(
          VaultPaths.favoriteRedoInkSifBackup(favoriteId, attemptId, i),
          await backup.readAsBytes(),
        );
      }
    }

    AnswerPaper paper = AnswerPaper.defaults;
    try {
      final File oldPaper = _vault.file(VaultPaths.favoriteRedoPaper(favoriteId));
      if (oldPaper.existsSync()) {
        final Object? decoded = jsonDecode(await oldPaper.readAsString());
        if (decoded is Map) {
          paper = AnswerPaper.fromJson(decoded.cast<String, Object?>());
        }
      }
    } on Object {
      // 旧纸张坏了就用默认值；笔迹仍然保留。
    }

    final RedoAttempt attempt = RedoAttempt(
      id: attemptId,
      favoriteId: favoriteId,
      createdAt: stamp,
      updatedAt: stamp,
      saved: true,
      paperPages: paper.pages,
      paperSummary: paper.summary,
    );
    await saveMeta(attempt);
    await savePaper(favoriteId, attemptId, paper);
  }
}
