import 'dart:convert';
import 'dart:io';

import 'package:shuaqi/infra/vault/paths.dart';
import 'package:shuaqi/infra/vault/vault.dart';

/// 切题产物的读写（`layout/` 目录）。
///
/// 三个文件三种身份，别混：
/// - `text.json`：L0 文本层缓存，**可删**（删了重抽一次就有）；
/// - `regions.v1.json`：L1/L2 的自动结果，**只读**，用户编辑不许改它；
/// - `corrections.json`：用户覆盖层（T3.4），重算自动结果时**必须保留**。
///
/// 全部走 [Vault.writeAtomically]：断电只会留下 `.tmp`，不会留下半个 JSON。
class LayoutStore {
  const LayoutStore(this._vault);

  final Vault _vault;

  Future<Map<String, Object?>?> readText(String workbookId) =>
      _read(VaultPaths.layoutText(workbookId));

  Future<void> writeText(String workbookId, Map<String, Object?> json) =>
      _write(VaultPaths.layoutText(workbookId), json);

  Future<Map<String, Object?>?> readRegions(String workbookId) =>
      _read(VaultPaths.layoutRegions(workbookId));

  Future<void> writeRegions(String workbookId, Map<String, Object?> json) =>
      _write(VaultPaths.layoutRegions(workbookId), json);

  Future<Map<String, Object?>?> readCorrections(String workbookId) =>
      _read(VaultPaths.layoutCorrections(workbookId));

  Future<Map<String, Object?>?> readAnswers(String workbookId) =>
      _read(VaultPaths.layoutAnswers(workbookId));

  Future<void> writeAnswers(String workbookId, Map<String, Object?> json) =>
      _write(VaultPaths.layoutAnswers(workbookId), json);

  /// AI 补出来的参考答案（用户产物，重切题不覆盖）。
  Future<Map<String, Object?>?> readAiAnswers(String workbookId) =>
      _read(VaultPaths.layoutAnswersAi(workbookId));

  Future<void> writeAiAnswers(String workbookId, Map<String, Object?> json) =>
      _write(VaultPaths.layoutAnswersAi(workbookId), json);

  /// 「问 AI」对话历史（用户产物，重切题不覆盖）。
  Future<Map<String, Object?>?> readAiChat(String workbookId) =>
      _read(VaultPaths.layoutAiChat(workbookId));

  Future<void> writeAiChat(String workbookId, Map<String, Object?> json) =>
      _write(VaultPaths.layoutAiChat(workbookId), json);

  /// 作答框 + 本地识别结果（用户产物，重切题不清）。
  Future<Map<String, Object?>?> readAnswerSheet(String workbookId) =>
      _read(VaultPaths.layoutAnswerSheet(workbookId));

  Future<void> writeAnswerSheet(String workbookId, Map<String, Object?> json) =>
      _write(VaultPaths.layoutAnswerSheet(workbookId), json);

  Future<Map<String, Object?>?> readQuestionOrder(String workbookId) =>
      _read(VaultPaths.layoutQuestionOrder(workbookId));

  Future<void> writeQuestionOrder(
    String workbookId,
    Map<String, Object?> json,
  ) => _write(VaultPaths.layoutQuestionOrder(workbookId), json);

  /// 答题卡纸张配置（全局默认 + 每题覆盖）。
  Future<Map<String, Object?>?> readAnswerPaper(String workbookId) =>
      _read(VaultPaths.layoutAnswerPaper(workbookId));

  Future<void> writeAnswerPaper(String workbookId, Map<String, Object?> json) =>
      _write(VaultPaths.layoutAnswerPaper(workbookId), json);

  /// 判题结果（用户产物：手改判的结论要留着，重算自动结果不能覆盖）。
  Future<Map<String, Object?>?> readGrading(String workbookId) =>
      _read(VaultPaths.layoutGrading(workbookId));

  Future<void> writeGrading(String workbookId, Map<String, Object?> json) =>
      _write(VaultPaths.layoutGrading(workbookId), json);

  /// 覆盖层是否存在（T3.4 起："重新切题"要保留它，面板要显示"已手改"）。
  Future<bool> hasCorrections(String workbookId) async =>
      _vault.exists(VaultPaths.layoutCorrections(workbookId));

  /// 删掉自动结果（文本层 + 区域），**保留覆盖层**。
  Future<void> clearAuto(String workbookId) async {
    for (final String path in <String>[
      VaultPaths.layoutText(workbookId),
      VaultPaths.layoutRegions(workbookId),
      VaultPaths.layoutAnswers(workbookId),
    ]) {
      final File file = _vault.file(path);
      if (file.existsSync()) {
        await file.delete();
      }
    }
  }

  /// 只是探一下缓存在不在，给"要不要跑切题"做前置判断（不读内容，不解析）。
  bool hasRegionsSync(String workbookId) =>
      _vault.exists(VaultPaths.layoutRegions(workbookId));

  Future<Map<String, Object?>?> _read(String relativePath) async {
    final File file = _vault.file(relativePath);
    if (!file.existsSync()) {
      return null;
    }
    try {
      final String raw = await file.readAsString();
      if (raw.trim().isEmpty) {
        return null;
      }
      final Object? decoded = jsonDecode(raw);
      return decoded is Map<String, Object?> ? decoded : null;
    } on FormatException {
      // 坏 JSON 当"没有缓存"：切题会重新生成，不需要吓用户。
      return null;
    } on FileSystemException {
      return null;
    }
  }

  Future<void> _write(String relativePath, Map<String, Object?> json) async {
    final List<int> bytes = utf8.encode(jsonEncode(json));
    await _vault.writeAtomically(relativePath, bytes);
  }
}
