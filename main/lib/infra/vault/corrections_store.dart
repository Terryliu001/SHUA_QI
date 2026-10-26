import 'dart:convert';
import 'dart:io';

import 'package:shuaqi/domain/region/correction.dart';
import 'package:shuaqi/infra/vault/paths.dart';
import 'package:shuaqi/infra/vault/vault.dart';

/// 用户覆盖层 `layout/corrections.json` 的读写（T3.4）。
///
/// 只做"读一份 / 写一份 / 清掉"，**不做防抖**——防抖是调用方（编辑控制器）的事，
/// 藏在这里会让"退出前必须 flush"这类边界漏出来（和 `ReaderPrefsStore` 同一口径）。
///
/// 读失败（文件坏/版本新）一律退化成空覆盖层：宁可这一次显示自动结果，
/// 也不能让用户打不开卷子。**不清文件**——数据留着，下次或许能救回来。
class CorrectionsStore {
  const CorrectionsStore(this._vault);

  final Vault _vault;

  Future<CorrectionLog> load(String workbookId) async {
    final Map<String, Object?>? json = await readRaw(workbookId);
    if (json == null) {
      return CorrectionLog.empty;
    }
    return CorrectionLog.fromJson(json);
  }

  Future<Map<String, Object?>?> readRaw(String workbookId) async {
    final String path = VaultPaths.layoutCorrections(workbookId);
    if (!_vault.exists(path)) {
      return null;
    }
    try {
      final String raw = await _vault.file(path).readAsString();
      final Object? decoded = jsonDecode(raw);
      return decoded is Map<String, Object?> ? decoded : null;
    } on FormatException {
      return null;
    } on FileSystemException {
      return null;
    }
  }

  Future<void> save(String workbookId, CorrectionLog log) async {
    final List<int> bytes = utf8.encode(jsonEncode(log.toJson(workbookId)));
    await _vault.writeAtomically(
      VaultPaths.layoutCorrections(workbookId),
      bytes,
    );
  }

  /// 清空（"放弃我的修改"）。删文件而不是写空数组：
  /// 文件不在 = 从没改过，`layout_status` 才能干净地回到 auto。
  Future<void> clear(String workbookId) async {
    final File file = _vault.file(VaultPaths.layoutCorrections(workbookId));
    if (file.existsSync()) {
      await file.delete();
    }
  }

  bool hasSync(String workbookId) =>
      _vault.exists(VaultPaths.layoutCorrections(workbookId));
}
