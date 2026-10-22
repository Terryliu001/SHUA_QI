import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shuaqi/domain/reader/reader_prefs.dart';

/// 订阅状态的集中出口（`lib/state/`）。
///
/// 约定：这里只放**跨页面共享**的状态与用例入口。页面私有的临时状态留在页面里，
/// 不要为了"统一"把所有 `setState` 都搬进 Provider。
///
/// 命名：`xxxProvider`；派生状态用 `xxxProvider` + `Provider` 组合，不要造 setter。

/// 当前阅读偏好。
///
/// 现在恒为默认值——真正的读写要等 `setting` 表（T1.2）与阅读器设置（T1.6）。
/// **故意不做成本地内存开关**：那会让"切了样式但重启就没了"变成隐藏 bug。
final Provider<ReaderPrefs> readerPrefsProvider = Provider<ReaderPrefs>(
  (Ref ref) => ReaderPrefs.defaults,
);
