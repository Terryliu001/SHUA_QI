import 'dart:convert';

import 'package:shuaqi/domain/reader/reader_prefs.dart';
import 'package:shuaqi/infra/db/dao/setting_dao.dart';

/// 阅读偏好的读写编排（T1.6 接线）。
///
/// 落盘约定（§5.3A）：
/// - 单卷偏好写 `reader.view.<workbookId>`（一条 JSON），缺失则回落全局默认；
/// - 全局默认是 `reader.default_mode` / `reader.default_paper_style` /
///   `reader.default_intensity` 三条，目前只读不写（写入口等设置页 T6.1）。
///
/// 这里只管"读进来 / 写出去"，不做防抖——防抖是 UI 的事（每次交互攒 500ms 再写），
/// 否则在 store 里藏 Timer 会让单测变难、也让"退出前必须 flush"这类边界漏出来。
class ReaderPrefsStore {
  ReaderPrefsStore(this._dao);

  final SettingDao _dao;

  Future<ReaderPrefs> load(String workbookId) async {
    final String? rawView = await _dao.get(ReaderSettingKeys.viewOf(workbookId));
    final Map<String, Object?> view = _decode(rawView);
    if (view.isNotEmpty) {
      return ReaderPrefs.fromJson(view);
    }
    // 无单卷覆盖 → 逐键回落全局默认，任何缺失都用 ReaderPrefs 的默认值兜底
    return ReaderPrefs.fromJson(<String, Object?>{
      if (await _dao.get(ReaderSettingKeys.defaultMode) case final String mode)
        'mode': mode,
      if (await _dao.get(ReaderSettingKeys.defaultPaperStyle)
          case final String style)
        'style': style,
      if (await _dao.get(ReaderSettingKeys.defaultIntensity)
          case final String intensity)
        'intensity': intensity,
    });
  }

  Future<void> save(String workbookId, ReaderPrefs prefs) async {
    await _dao.put(
      ReaderSettingKeys.viewOf(workbookId),
      jsonEncode(prefs.toJson()),
    );
  }

  /// 解析单卷偏好 JSON。非法 JSON / 非对象 → 空表（回落默认），绝不抛。
  Map<String, Object?> _decode(String? raw) {
    if (raw == null || raw.isEmpty) {
      return const <String, Object?>{};
    }
    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is Map<String, Object?>) {
        return decoded;
      }
      return const <String, Object?>{};
    } on FormatException {
      return const <String, Object?>{};
    }
  }
}
