import 'package:flutter/widgets.dart';

/// 公式渲染契约（规格 §7、§6.8）。
///
/// 实现要求（T6.7 落地）：
/// 1. 收到的 [tex] **不含定界符**，且必须已通过配对检查——未闭合的 `$…$` 绝不进这里（INV-07）。
/// 2. 渲染失败时必须返回 [fallback]（源码或裁图），**不得抛异常、不得返回空白**。
/// 3. 按 tex 字符串做 LRU 缓存（容量 200，§6.8.3），单条渲染 ≤16ms。
/// 4. 纯离线：不许 WebView，不许把公式发到任何在线服务（INV-04、禁止清单）。
abstract interface class MathView {
  Widget build(
    BuildContext context,
    String tex, {
    bool display = false,
    Widget? fallback,
  });
}
