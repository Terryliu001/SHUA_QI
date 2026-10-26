import 'dart:convert';

import 'package:shuaqi/domain/answer/answer_paper.dart';
import 'package:shuaqi/infra/vault/paths.dart';
import 'package:shuaqi/infra/vault/vault.dart';

/// 收藏「重刷」的答题纸配置（`favorites/<id>/paper.json`）。
///
/// 为什么每道收藏一份、而不是全局一份：
/// - 几何题可能要 A4 竖向多张，选择题一行横线就够；
/// - 换尺寸时旧笔迹按比例搬（`FavoriteRedoInkStore`），换纸不等于丢字；
/// - 原卷删了也还在（快照目录内），重刷体验不依赖原卷。
class FavoriteRedoPaperStore {
  const FavoriteRedoPaperStore(this._vault);

  final Vault _vault;

  Future<AnswerPaper> load(String favoriteId, {String? attemptId}) async {
    try {
      final String relative = _pathOf(favoriteId, attemptId);
      if (!_vault.file(relative).existsSync()) {
        return AnswerPaper.defaults;
      }
      final Object? decoded = jsonDecode(
        await _vault.file(relative).readAsString(),
      );
      if (decoded is! Map) {
        return AnswerPaper.defaults;
      }
      return AnswerPaper.fromJson(decoded.cast<String, Object?>());
    } on Object {
      return AnswerPaper.defaults;
    }
  }

  Future<void> save(
    String favoriteId,
    AnswerPaper paper, {
    String? attemptId,
  }) async {
    await _vault.writeAtomically(
      _pathOf(favoriteId, attemptId),
      utf8.encode(jsonEncode(paper.toJson())),
    );
  }

  String _pathOf(String favoriteId, String? attemptId) {
    final String id = (attemptId ?? '').trim();
    return id.isEmpty
        ? VaultPaths.favoriteRedoPaper(favoriteId)
        : VaultPaths.favoriteRedoPaperOf(favoriteId, id);
  }
}
