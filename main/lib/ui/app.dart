import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shuaqi/domain/app/accent.dart';
import 'package:shuaqi/domain/app/backup_file.dart';
import 'package:shuaqi/domain/app/setting_keys.dart';
import 'package:shuaqi/infra/db/dao/setting_dao.dart';
import 'package:shuaqi/state/accent_provider.dart';
import 'package:shuaqi/state/app_providers.dart';
import 'package:shuaqi/state/settings_providers.dart';
import 'package:shuaqi/state/theme_mode_provider.dart';
import 'package:shuaqi/state/update_providers.dart';
import 'package:shuaqi/ui/router.dart';
import 'package:shuaqi/ui/settings/backup_actions.dart';
import 'package:shuaqi/ui/settings/notice_dialog.dart';
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

  /// 首次启动用户须知只检查一次（同一次进程内不重复弹）。
  bool _noticeChecked = false;
  bool _restoreChecked = false;

  Timer? _updateTimer;

  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_maybeShowNotice());
      unawaited(_retryFeedback());
      unawaited(_maybeOfferUpdateRestore());
      _startUpdateChecks();
    });
  }

  @override
  void dispose() {
    _updateTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_retryFeedback());
      // 回前台时如果距上次检查超过 6 小时，静默查一次更新。
      unawaited(ref.read(updateProvider.notifier).checkIfDue());
    }
  }

  /// 启动 3 秒后查一次（避开启动高峰），之后每 24 小时一次。
  ///
  /// 不做常驻后台服务：应用不在前台时不检查，避免耗电与额外依赖。
  void _startUpdateChecks() {
    unawaited(
      Future<void>.delayed(const Duration(seconds: 3), () {
        if (mounted) {
          unawaited(ref.read(updateProvider.notifier).checkIfDue());
        }
      }),
    );
    _updateTimer?.cancel();
    _updateTimer = Timer.periodic(const Duration(hours: 24), (_) {
      if (mounted) {
        unawaited(ref.read(updateProvider.notifier).checkIfDue(force: true));
      }
    });
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

  /// 全新安装且未确认过 → 开屏弹「用户须知」；确认后才写标记。
  ///
  /// 老用户升级（库文件已存在）不弹；这也是 `isFreshInstall` 存在的唯一用途。
  Future<void> _maybeShowNotice() async {
    if (_noticeChecked) {
      return;
    }
    _noticeChecked = true;
    try {
      final deps = ref.read(appDependenciesProvider);
      if (!deps.isFreshInstall) {
        return;
      }
      final SettingDao dao = SettingDao(deps.db.raw);
      if (await dao.get(AppSettingKeys.noticeAccepted) == '1') {
        return;
      }
      if (!mounted) {
        return;
      }
      final BuildContext? ctx = _navigatorKey.currentContext;
      if (ctx == null || !ctx.mounted) {
        return;
      }
      final bool accepted = await showUserNoticeDialog(ctx);
      if (!mounted) {
        return;
      }
      if (accepted) {
        await dao.put(AppSettingKeys.noticeAccepted, '1');
      } else {
        // 用户明确不确认：退出应用；下次打开会再次提示。
        await SystemNavigator.pop();
      }
    } on Object {
      // 弹出失败不能挡住启动；下次启动再试。
    }
  }

  /// 更新后如果本机一条试卷都没有、但存在「更新前备份」，提示恢复。
  ///
  /// 正常覆盖安装不会触发（workbook > 0）；这是数据真丢了时的兜底。
  /// 不自动覆盖：先问用户，恢复仍走「覆盖恢复」二次确认。
  Future<void> _maybeOfferUpdateRestore() async {
    if (_restoreChecked) {
      return;
    }
    _restoreChecked = true;
    try {
      final deps = ref.read(appDependenciesProvider);
      final SettingDao dao = SettingDao(deps.db.raw);
      final String name =
          await dao.get(AppSettingKeys.updateLastBackupName) ?? '';
      if (name.isEmpty || !mounted) {
        return;
      }
      final List<Map<String, Object?>> rows = await deps.db.raw.rawQuery(
        'SELECT COUNT(*) AS c FROM workbook',
      );
      final int count = (rows.first['c'] as num?)?.toInt() ?? 0;
      if (count > 0 || !mounted) {
        return;
      }
      final BuildContext? ctx = _navigatorKey.currentContext;
      if (ctx == null || !ctx.mounted) {
        return;
      }
      final bool? go = await showDialog<bool>(
        context: ctx,
        builder: (BuildContext context) => AlertDialog(
          title: const Text('更新后发现本机没有试卷'),
          content: Text(
            '找到一份更新前备份：\n$name\n\n'
            '如果更新后数据不对，可以从这份备份恢复。恢复会先留底当前数据，'
            '再替换并重启。要现在恢复吗？',
            style: Theme.of(context).textTheme.bodyMedium
                ?.copyWith(height: 1.6),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('稍后'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('去恢复'),
            ),
          ],
        ),
      );
      if (go != true || !mounted) {
        return;
      }
      final List<BackupFileInfo> list = await ref
          .read(backupLibraryProvider)
          .list();
      if (!ctx.mounted) {
        return;
      }
      for (final BackupFileInfo info in list) {
        if (info.name == name) {
          await restoreBackupFromInfo(ctx, ref, info);
          return;
        }
      }
    } on Object {
      // 恢复提示失败不影响使用；用户仍可在设置里手动恢复。
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeMode mode = ref.watch(themeModeProvider);
    final ShqAccent accent = ref.watch(accentProvider);

    return MaterialApp(
      title: '刷起 SHUAQI',
      debugShowCheckedModeBanner: false,
      navigatorKey: _navigatorKey,
      theme: ShqTheme.light(accent),
      darkTheme: ShqTheme.dark(accent),
      themeMode: mode,
      initialRoute: AppRoutes.shell,
      onGenerateRoute: AppRoutes.onGenerateRoute,
    );
  }
}
