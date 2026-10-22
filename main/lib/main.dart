import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shuaqi/ui/app.dart';
import 'package:shuaqi/ui/errors/error_handling.dart';

/// 应用入口。
///
/// 顺序有讲究：先 `ensureInitialized`（之后才能用 platformDispatcher / 插件），
/// 再装错误兜底（越早越好，否则启动期异常没人接），最后才 runApp。
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  installErrorHandlers();
  runApp(const ProviderScope(child: ShuaqiApp()));
}
