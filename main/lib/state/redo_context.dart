import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 「这次重刷是从哪儿进来的」——重刷页写，作答记录读。
///
/// ## 为什么需要它
/// 用户要求（2026-10-26 第 9/16 条）：
/// - 重刷的记录要能在时间线里**单独看见**（不直接展开重刷答题卡）；
/// - **在组卷里重刷**的，要标出组卷名与时间。
///
/// 而"落笔"发生在 `state/ink_providers.dart` 的笔迹控制器里——它只知道
/// `fav:<favoriteId>` 这个 session，**不知道**用户是从单题入口还是组卷进来的。
/// 所以由重刷页把上下文写进这里，打点时再读。
///
/// 值为 null = 不在重刷页（正常阅读/答题卡），打点按原卷口径走。
class RedoContext {
  const RedoContext({required this.title, this.setId});

  /// 这次重刷的标题（组卷名，或「重刷」）。
  final String title;

  /// 组卷 id；null = 单题重刷。
  final String? setId;

  bool get isSet => (setId ?? '').isNotEmpty;
}

/// 当前的重刷上下文。由 [FavoriteRedoPage] 在进入时写、退出时清。
final NotifierProvider<RedoContextController, RedoContext?>
redoContextProvider =
    NotifierProvider<RedoContextController, RedoContext?>(
      RedoContextController.new,
    );

class RedoContextController extends Notifier<RedoContext?> {
  @override
  RedoContext? build() => null;

  void enter(RedoContext context) => state = context;

  void leave() => state = null;
}
