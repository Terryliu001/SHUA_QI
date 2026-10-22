import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shuaqi/app/bootstrap.dart';
import 'package:shuaqi/app/reader/reader_prefs_store.dart';
import 'package:shuaqi/domain/reader/reader_prefs.dart';
import 'package:shuaqi/infra/db/dao/setting_dao.dart';
import 'package:shuaqi/state/app_providers.dart';

/// 阅读偏好的读写入口（T1.6）。
///
/// 读走 [readerPrefsProvider]（按卷 `family`），写走 store 的 `save`，
/// 由 UI 层做 500ms 防抖。键名与落盘结构见 §5.3A / [ReaderPrefsStore]。

final Provider<ReaderPrefsStore> readerPrefsStoreProvider =
    Provider<ReaderPrefsStore>((Ref ref) {
      final AppDependencies deps = ref.watch(appDependenciesProvider);
      return ReaderPrefsStore(SettingDao(deps.db.raw));
    });

/// 某一卷的阅读偏好（mode / style / intensity）。
/// 首次打开会先回落全局默认（当前就是 `ReaderPrefs.defaults`）。
final FutureProvider<ReaderPrefs> Function(String) readerPrefsProvider =
    FutureProvider.family<ReaderPrefs, String>((Ref ref, String workbookId) {
      return ref.watch(readerPrefsStoreProvider).load(workbookId);
    });
