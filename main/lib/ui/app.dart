import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shuaqi/domain/app/accent.dart';
import 'package:shuaqi/state/accent_provider.dart';
import 'package:shuaqi/state/theme_mode_provider.dart';
import 'package:shuaqi/ui/router.dart';
import 'package:shuaqi/ui/theme/app_theme.dart';

/// 应用根。**全项目唯一**的 MaterialApp（主题单点生效，T1.1）。
///
/// 这里只做三件事：装主题、装路由、看"深浅 + 色系"两个外观偏好。
/// 任何业务逻辑、IO、订阅都不许出现在这里。
///
/// 换色系时 `MaterialApp` 自带的 `AnimatedTheme`（200ms）会把整套
/// `ColorScheme` 渐变过去——不用自己写动画，也不会闪一下。
class ShuaqiApp extends ConsumerWidget {
  const ShuaqiApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
