import 'package:shuaqi/domain/ink/ink_doc.dart';

/// 笔宽映射（纯 Dart，可单测）：压感 → 线宽（pt）。
///
/// 数值来源：T0.2 spike 在 OPPO OPD2601 上的实测区间（钢笔 1.2–4.6pt
/// 在 400dpi 屏上轻重分明且不糊）。压力恒值（鼠标 / 无压感设备）时
/// 取区间中值，避免整页糊成粗线或细到看不见。
///
/// 荧光笔是**等宽乘算**：宽度固定、颜色半透明，交给 painter 用
/// BlendMode.multiply 合成——下方文字必须可读（REQ-03）。
///
/// ## 为什么不直接用连续宽度（T2.2 的返工）
/// Canvas 只有"整条 Path 一个 strokeWidth"。要一笔内粗细连续变化，只有两条路：
/// ① 每段一次 drawLine（正在写的这一笔几百段，可以；已提交的几万段，不行）；
/// ② 把宽度**量化成有限档**，每档一条 Path（已提交只画 N 条 Path）。
/// 早先的做法是路 ① 画活笔、路 ② 画死笔，于是抬笔瞬间整笔宽度跳到档位中心——
/// 用户看到的就是"抬笔粗细突变"。现在两条路统一走量化档，且共用同一个
/// `InkRibbon`（`ui/reader/ink_ribbon.dart`），抬笔前后**像素级一致**。
abstract final class InkWidth {
  /// 钢笔：压感驱动，轻 1.2pt / 重 4.6pt。
  static const double penMin = 1.2;
  static const double penMax = 4.6;

  /// 圆珠笔：等宽，略细于钢笔中值。
  static const double ballpoint = 1.8;

  /// 荧光笔：等宽、宽。
  static const double highlighter = 14;

  /// 无压感输入（鼠标 / 触摸）与"落笔第一帧压力读数缺失"时的中性压力。
  /// 0.5 → 钢笔正好取区间中值（本文件 [penMid]）。
  static const double neutralPressure = 0.5;

  /// 压感平滑系数（EMA 新值权重）。
  ///
  /// 手写笔采样 217–240Hz，但**压力读数在落笔前两三帧会跳到 0 或满值**
  /// （Android 的 DOWN 事件尤其常见），直接映射就是"起笔突然粗/细"。
  /// 0.45 相当于约 3 个采样点的过渡（≈13ms）：肉眼看是自然的提按，不是跳变。
  static const double pressureSmoothing = 0.45;

  /// 线宽量化档数。钢笔区间被切成 24 档 → 0.148pt 一档，
  /// 在 400dpi（2.5dppx）下不到半个像素，肉眼不可辨；
  /// 换来的是"已提交笔迹只需 24 条 Path"而不是每段一次 drawLine。
  static const int levels = 24;

  /// 无压感输入（压力恒 0 或恒 1）时的钢笔宽度：区间中值。
  static double get penMid => (penMin + penMax) / 2;

  /// [style] 在压力 [pressure]（0..1）下的线宽（pt）。
  static double forStroke(InkStrokeStyle style, double pressure) {
    switch (style) {
      case InkStrokeStyle.pen:
        return _penWidth(pressure);
      case InkStrokeStyle.ballpoint:
        return ballpoint;
      case InkStrokeStyle.highlighter:
        return highlighter;
    }
  }

  /// 该笔刷的线宽区间（等宽笔刷 min == max）。
  static (double, double) rangeOf(InkStrokeStyle style) {
    switch (style) {
      case InkStrokeStyle.pen:
        return (penMin, penMax);
      case InkStrokeStyle.ballpoint:
        return (ballpoint, ballpoint);
      case InkStrokeStyle.highlighter:
        return (highlighter, highlighter);
    }
  }

  /// 宽度 → 档位（0..[levels]-1）。等宽笔刷恒为 0（整笔一条 Path）。
  static int levelOf(InkStrokeStyle style, double width) {
    final (double min, double max) = rangeOf(style);
    if (max <= min) {
      return 0;
    }
    final double t = (width - min) / (max - min);
    return (t * (levels - 1)).round().clamp(0, levels - 1);
  }

  /// 档位 → 该档代表宽度（pt）。**绘制唯一取宽处**：活笔与死笔都从这里取。
  static double widthOfLevel(InkStrokeStyle style, int level) {
    final (double min, double max) = rangeOf(style);
    if (max <= min) {
      return min;
    }
    final int clamped = level.clamp(0, levels - 1);
    return min + (max - min) * clamped / (levels - 1);
  }

  static double _penWidth(double pressure) {
    // 无压感设备统一填 0.5（InkPoint 契约），这里把 0/1 的边界值也归到中值：
    // 鼠标事件 pressure 恒 1.0，不特判就会整笔最粗。
    if (pressure <= 0 || pressure >= 0.999) {
      return penMid;
    }
    return penMin + (penMax - penMin) * pressure;
  }
}
