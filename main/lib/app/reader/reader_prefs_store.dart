import 'dart:convert';

import 'package:shuaqi/domain/reader/reader_prefs.dart';
import 'package:shuaqi/infra/db/dao/setting_dao.dart';

/// 阅读偏好的读写编排（T1.6 接线，设置页 T6.1 之后补全局默认的写入口）。
///
/// 落盘约定（§5.3A）：
/// - 单卷偏好写 `reader.view.<workbookId>`（一条 JSON），缺失则回落全局默认；
/// - 全局默认是 `reader.default_mode` / `reader.default_paper_style` /
///   `reader.default_intensity` 三条，写入口在设置页（`readerDefaultsProvider`）。
///
/// 这里只管"读进来 / 写出去"，不做防抖——防抖是 UI 的事（每次交互攒 500ms 再写），
/// 否则在 store 里藏 Timer 会让单测变难、也让"退出前必须 flush"这类边界漏出来。
class ReaderPrefsStore {
  ReaderPrefsStore(this._dao);

  final SettingDao _dao;

  Future<ReaderPrefs> load(String workbookId) async {
    final Map<String, Object?> view = _decode(
      await _dao.get(ReaderSettingKeys.viewOf(workbookId)),
    );
    if (view.isNotEmpty) {
      return ReaderPrefs.fromJson(view);
    }
    // 无单卷覆盖 → 用全局默认
    return loadDefaults();
  }

  /// 全局默认（`reader.default_*` 三条）。缺失逐键回落 [ReaderPrefs.defaults]。
  Future<ReaderPrefs> loadDefaults() async {
    final String? mode = await _dao.get(ReaderSettingKeys.defaultMode);
    final String? style = await _dao.get(ReaderSettingKeys.defaultPaperStyle);
    final String? intensity = await _dao.get(
      ReaderSettingKeys.defaultIntensity,
    );
    final int? parsedIntensity = intensity == null
        ? null
        : int.tryParse(intensity);
    return ReaderPrefs.fromJson(<String, Object?>{
      'mode': ?mode,
      'style': ?style,
      'intensity': ?parsedIntensity,
    });
  }

  Future<void> save(String workbookId, ReaderPrefs prefs) async {
    await _dao.put(
      ReaderSettingKeys.viewOf(workbookId),
      jsonEncode(prefs.toJson()),
    );
  }

  /// 写全局默认（设置页）。只影响**之后新读取**的卷——
  /// 已经在看的卷持有的是自己那份 `reader.view.<id>`，不会被打扰。
  Future<void> saveDefaults(ReaderPrefs prefs) async {
    final ReaderPrefs clamped = prefs.clamp();
    await _dao.put(ReaderSettingKeys.defaultMode, clamped.mode.name);
    await _dao.put(ReaderSettingKeys.defaultPaperStyle, clamped.style.name);
    await _dao.put(
      ReaderSettingKeys.defaultIntensity,
      '${clamped.intensity}',
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
