import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shuaqi/domain/app/accent.dart';
import 'package:shuaqi/state/accent_provider.dart';
import 'package:shuaqi/state/settings_providers.dart';
import 'package:shuaqi/state/theme_mode_provider.dart';
import 'package:shuaqi/ui/router.dart';
import 'package:shuaqi/ui/theme/app_theme.dart';

/// 应用根。**全项目唯一**的 MaterialApp（主题单点生效，T1.1）。
///
/// 这里只做三件事：装主题、装路由、看"深浅 + 色系"两个外观偏好。
/// 业务逻辑、IO、订阅都不许出现在这里。
///
/// 唯一的例外是**反馈补发**（2026-10-27）：它是一个"进程级、跟页面无关"的
/// 后台动作（上次没网的反馈，回前台时补发一次），放页面里会漏掉"直接
/// 从书架进来"的情况。这里只调用一个队列方法，不碰任何 UI 状态。
class ShuaqiApp extends ConsumerStatefulWidget {
  const ShuaqiApp({super.key});

  @override
  ConsumerState<ShuaqiApp> createState() => _ShuaqiAppState();
}

class _ShuaqiAppState extends ConsumerState<ShuaqiApp>
    with WidgetsBindingObserver {
  /// 避免每次回前台都撞一次远端（失败时也至少隔 5 分钟）。
  DateTime? _lastFeedbackRetry;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_retryFeedback());
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_retryFeedback());
    }
  }

  Future<void> _retryFeedback() async {
    final DateTime now = DateTime.now();
    final DateTime? last = _lastFeedbackRetry;
    if (last != null && now.difference(last) < const Duration(minutes: 5)) {
      return;
    }
    _lastFeedbackRetry = now;
    try {
      await ref.read(feedbackOutboxProvider).retryPending(limit: 3);
    } on Object {
      // 补发失败不影响启动；用户在反馈页能看到状态并手动重试。
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeMode mode = ref.watch(themeModeProvider);
    final ShqAccent accent = ref.watch(accentProvider);

    return MaterialApp(
      title: '刷起 SHUAQI',
      debugShowCheckedModeBanner: false,
      theme: ShqTheme.light(accent),
      darkTheme: ShqTheme.dark(accent),
      themeMode: mode,
      initialRoute: AppRoutes.shell,
      onGenerateRoute: AppRoutes.onGenerateRoute,
    );
  }
}
