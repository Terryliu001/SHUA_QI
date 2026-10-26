import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 主 tab 的下标（外壳与应用内页面共用的契约）。
///
/// 为什么要放进 provider：记录页需要知道"自己被切到前台"，才能刷新统计
/// （`IndexedStack` 保活，切 tab 不会重建页面）。把下标硬编码在页面里
/// 会让加 tab 时静默错位。
const int kBookshelfTab = 0;
const int kRecordsTab = 1;
const int kFavoritesTab = 2;
const int kSettingsTab = 3;

final NotifierProvider<ShellTabController, int> shellTabProvider =
    NotifierProvider<ShellTabController, int>(ShellTabController.new);

class ShellTabController extends Notifier<int> {
  @override
  int build() => kBookshelfTab;

  void select(int index) {
    if (state == index) {
      return;
    }
    state = index;
  }
}
