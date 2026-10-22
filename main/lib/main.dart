import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:shuaqi/app/bootstrap.dart';
import 'package:shuaqi/state/app_providers.dart';
import 'package:shuaqi/ui/app.dart';
import 'package:shuaqi/ui/errors/error_handling.dart';

/// 应用入口。
///
/// 顺序有讲究：
/// 1. `ensureInitialized` —— 之后才能用 platformDispatcher / 插件；
/// 2. 装错误兜底 —— 越早越好，否则启动期异常没人接；
/// 3. `pdfrxFlutterInitialize` —— 直接调 `PdfDocument` API 之前必须调它（T0.4 踩过）；
/// 4. `bootstrap` —— 打开数据库与 Vault，并清一次孤儿目录；
/// 5. 最后才 runApp，依赖通过 `ProviderScope.overrides` 注入。
///
/// TODO(T1.1 收尾)：目前是"初始化完才 runApp"，冷启动会多等 DB 打开的时间。
/// 规格建议先 runApp 骨架屏再替换。等功能稳定后再改，避免现在引入第二套启动状态机。
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  installErrorHandlers();
  await pdfrxFlutterInitialize();
  final AppDependencies dependencies = await bootstrap();

  runApp(
    ProviderScope(
      overrides: [appDependenciesProvider.overrideWithValue(dependencies)],
      child: const ShuaqiApp(),
    ),
  );
}
