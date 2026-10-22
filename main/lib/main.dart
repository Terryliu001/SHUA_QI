import 'package:flutter/material.dart';

void main() => runApp(const ShuaqiApp());

/// T0.1 工程基座的最小可运行壳。
///
/// 这里刻意不做任何 IO / 状态管理 / 路由 / 订阅：
/// T0.1 只验证「工程能编译、能装到平板、能起一屏」。
/// 真正的骨架（主题单点生效、路由、Riverpod、错误边界）属于 T1.1，不在这里提前实现。
class ShuaqiApp extends StatelessWidget {
  const ShuaqiApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '刷起 SHUAQI',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: const Color(0xFF1F6FEB),
        useMaterial3: true,
      ),
      home: const BasePlatePage(),
    );
  }
}

/// 工程基座自检页：只显示静态信息，无状态、无副作用。
class BasePlatePage extends StatelessWidget {
  const BasePlatePage({super.key});

  static const List<String> _checks = <String>[
    'Flutter 3.47.6 stable · Dart 3.13.5',
    'compileSdk 36 · minSdk 26 · targetSdk 36',
    'AGP 9.1.0 · Kotlin 2.4.0 · Gradle 9.3.1',
    'flutter analyze 零 issue',
  ];

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text('刷起 SHUAQI', style: theme.textTheme.displaySmall),
                  const SizedBox(height: 8),
                  Text(
                    'T0.1 工程基座 · 自检页',
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: theme.colorScheme.primary,
                    ),
                  ),
                  const SizedBox(height: 32),
                  for (final String item in _checks)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: Text('· $item', style: theme.textTheme.bodyMedium),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
