import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shuaqi/ui/theme/tokens.dart';

/// 全局错误兜底（T1.1「错误边界」）。
///
/// 分三层，缺一层就会有"白屏但没有日志"的黑洞：
/// 1. [FlutterError.onError] —— build / layout / paint 期同步异常；
/// 2. `platformDispatcher.onError` —— 未捕获的异步异常（`Future` 忘了 catch）；
/// 3. [ErrorWidget.builder] —— 某个子树已经炸了时，**只替换那一块**，不让整页变红屏。
///
/// 只在 release 替换 ErrorWidget：debug 下保留 Flutter 原生的红屏，
/// 不然开发时会因为"看不到真实堆栈"而多花时间。
void installErrorHandlers() {
  FlutterError.onError = (FlutterErrorDetails details) {
    FlutterError.presentError(details);
    debugPrint('[shuaqi][flutter-error] ${details.exceptionAsString()}');
  };

  WidgetsBinding.instance.platformDispatcher.onError = (
    Object error,
    StackTrace stack,
  ) {
    // 返回 true 表示"已处理"，避免整个 isolate 被拉起来终止。
    debugPrint('[shuaqi][async-error] $error');
    return true;
  };

  if (kReleaseMode) {
    ErrorWidget.builder = (FlutterErrorDetails details) =>
        CrashFallback(message: details.exceptionAsString());
  }
}

/// 出错时的替身界面。
///
/// 刻意只用最原始的 widget（不依赖 [Theme]、不依赖 [Material]）：
/// 如果炸的是 MaterialApp 自身，任何依赖它的组件都会二次崩溃。
class CrashFallback extends StatelessWidget {
  const CrashFallback({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.ltr,
      child: ColoredBox(
        color: ShqPalette.ink,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(ShqSpace.xl),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                const Text(
                  '这一块没能显示出来',
                  textDirection: TextDirection.ltr,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: ShqType.title,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: ShqSpace.sm),
                const Text(
                  '回到书架重新打开这一卷即可；已经画下的笔迹不受影响。',
                  textDirection: TextDirection.ltr,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.white70,
                    fontSize: ShqType.bodySmall,
                  ),
                ),
                if (kDebugMode) ...<Widget>[
                  const SizedBox(height: ShqSpace.md),
                  Text(
                    message,
                    textDirection: TextDirection.ltr,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.white38,
                      fontSize: ShqType.caption,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
