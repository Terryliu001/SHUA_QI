import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shuaqi/state/theme_mode_provider.dart';
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
      initialRoute: AppRoutes.shell,
      onGenerateRoute: AppRoutes.onGenerateRoute,
    );
  }
}
