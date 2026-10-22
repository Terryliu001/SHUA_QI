import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shuaqi/ui/router.dart';
import 'package:shuaqi/ui/theme/app_theme.dart';

/// 应用根。**全项目唯一**的 MaterialApp（主题单点生效，T1.1）。
///
/// 这里只做三件事：装主题、装路由、看一个主题模式。
/// 任何业务逻辑、IO、订阅都不许出现在这里。
class ShuaqiApp extends ConsumerWidget {
  const ShuaqiApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ThemeMode mode = ref.watch(themeModeProvider);

    return MaterialApp(
      title: '刷起 SHUAQI',
      debugShowCheckedModeBanner: false,
      theme: ShqTheme.light(),
      darkTheme: ShqTheme.dark(),
      themeMode: mode,
      initialRoute: AppRoutes.bookshelf,
      onGenerateRoute: AppRoutes.onGenerateRoute,
    );
  }
}

/// 主题模式。目前恒为 `system`，且**没有 UI 能改它**——
/// 设置页与持久化属于 T6.1，现在给个可切换的开关只会制造"能点但不生效"的假功能。
///
/// 放在 `ui/` 而不是 `state/`：它返回的是 Material 的 [ThemeMode]，
/// 属于展示层概念，不该污染 `state/` 的纯状态。
final Provider<ThemeMode> themeModeProvider = Provider<ThemeMode>(
  (Ref ref) => ThemeMode.system,
);
