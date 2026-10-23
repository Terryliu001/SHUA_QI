import 'package:shuaqi/domain/ink/ink_doc.dart';

/// 笔宽映射（纯 Dart，可单测）：压感 + 粗细档 → 线宽（pt）。
///
/// ## 三档粗细（T2.2 规格 + 2026-10-23 用户要求"能设粗细"）
/// | 笔 | 细 | 中 | 粗 |
/// |---|---|---|---|
/// | 钢笔（压感驱动） | 0.8–2.4 | 1.2–3.2 | 1.8–4.4 |
/// | 圆珠笔（等宽） | 1.6 | 2.4 | 3.2 |
/// | 荧光笔（等宽） | 12 | 18 | 24 |
///
/// 钢笔的区间是按 T0.2 真机实测微调的：中档 1.2–3.2pt 在 400dpi 屏上轻重分明
/// 又不糊；细档压到 0.8 起笔时"像铅笔"，粗档 4.4 用来写标题/画框。
///
/// ## 为什么不直接用连续宽度（T2.2 的返工）
/// Canvas 只有"整条 Path 一个 strokeWidth"。要一笔内粗细连续变化，只有两条路：
/// ① 每段一次 drawLine（正在写的这一笔几百段，可以；已提交的几万段，不行）；
/// ② 把宽度**量化成有限档**，每档一条 Path（已提交只画 N 条 Path）。
/// 早先的做法是路 ① 画活笔、路 ② 画死笔，于是抬笔瞬间整笔宽度跳到档位中心——
/// 用户看到的就是"抬笔粗细突变"。现在两条路统一走量化档，且共用同一个
/// `InkRibbon`（`ui/reader/ink_ribbon.dart`），抬笔前后**像素级一致**。
abstract final class InkWidth {
  /// 每支笔的粗细档数（与 [InkStroke.widthLevels] 一致）。
  static const int widthLevels = InkStroke.widthLevels;

  /// 钢笔三档的线宽区间（pt），下标 = widthLevel。
  static const List<(double, double)> penRanges = <(double, double)>[
    (0.8, 2.4),
    (1.2, 3.2),
    (1.8, 4.4),
  ];

  /// 圆珠笔三档（等宽，适合写公式/竖式）。
  static const List<double> ballpointWidths = <double>[1.6, 2.4, 3.2];

  /// 荧光笔三档（等宽）。
  static const List<double> highlighterWidths = <double>[12, 18, 24];

  /// 无压感输入（鼠标 / 触摸）与"落笔第一帧压力读数缺失"时的中性压力。
  /// 0.5 → 钢笔正好取区间中值。
  static const double neutralPressure = 0.5;

  /// 压感平滑系数（EMA 新值权重）。
  ///
  /// 手写笔采样 217–240Hz，但**压力读数在落笔前两三帧会跳到 0 或满值**
  /// （Android 的 DOWN 事件尤其常见），直接映射就是"起笔突然粗/细"。
  /// 0.45 相当于约 3 个采样点的过渡（≈13ms）：肉眼看是自然的提按，不是跳变。
  static const double pressureSmoothing = 0.45;

  /// 入笔宽度系数：一笔的**第一个采样点**从 `raw × 0.55` 的宽度起笔，
  /// 再由 [pressureSmoothing] 在约 3 个采样点内收敛到真实压力宽度。
  ///
  /// 为什么要压低：真机上 DOWN 事件的压力读数系统性偏高（笔尖刚接触、
  /// 压电还没稳定），直接用会把起笔画成一个"圆斑"（2026-10-22 用户反馈）。
  /// 起笔略细再快速变宽，视觉上正是笔尖入纸的自然形态；
  /// 单点（点一下）仍按原始宽度画完整圆点，见 InkRibbon.endStroke。
  static const double taperIn = 0.55;

  /// 线宽量化档数。最宽档区间被切成 24 档 → 约 0.18pt 一档，
  /// 在 400dpi（3.54dppx）下不到一个像素，肉眼不可辨；
  /// 换来的是"已提交笔迹只需 24 条 Path"而不是每段一次 drawLine。
  static const int levels = 24;

  /// 归一化档位。
  static int _clampWidthLevel(int level) => level.clamp(0, widthLevels - 1);

  /// 无压感输入（压力恒 0 或恒 1）时的钢笔宽度：档位区间中值。
  static double penMid([int widthLevel = InkStroke.defaultWidthLevel]) {
    final (double min, double max) = rangeOf(
      InkStrokeStyle.pen,
      widthLevel,
    );
    return (min + max) / 2;
  }

  /// [style] 在压力 [pressure]（0..1）下、[widthLevel] 档的线宽（pt）。
  static double forStroke(
    InkStrokeStyle style,
    double pressure, [
    int widthLevel = InkStroke.defaultWidthLevel,
  ]) {
    switch (style) {
      case InkStrokeStyle.pen:
        return _penWidth(pressure, widthLevel);
      case InkStrokeStyle.ballpoint:
        return ballpointWidths[_clampWidthLevel(widthLevel)];
      case InkStrokeStyle.highlighter:
        return highlighterWidths[_clampWidthLevel(widthLevel)];
    }
  }

  /// 该笔刷在该粗细档下的线宽区间（等宽笔刷 min == max）。
  static (double, double) rangeOf(
    InkStrokeStyle style, [
    int widthLevel = InkStroke.defaultWidthLevel,
  ]) {
    final int level = _clampWidthLevel(widthLevel);
    switch (style) {
      case InkStrokeStyle.pen:
        return penRanges[level];
      case InkStrokeStyle.ballpoint:
        return (ballpointWidths[level], ballpointWidths[level]);
      case InkStrokeStyle.highlighter:
        return (highlighterWidths[level], highlighterWidths[level]);
    }
  }

  /// 宽度 → 档位（0..[levels]-1）。等宽笔刷恒为 0（整笔一条 Path）。
  static int levelOf(
    InkStrokeStyle style,
    double width, [
    int widthLevel = InkStroke.defaultWidthLevel,
  ]) {
    final (double min, double max) = rangeOf(style, widthLevel);
    if (max <= min) {
      return 0;
    }
    final double t = (width - min) / (max - min);
    return (t * (levels - 1)).round().clamp(0, levels - 1);
  }

  /// 档位 → 该档代表宽度（pt）。**绘制唯一取宽处**：活笔与死笔都从这里取。
  static double widthOfLevel(
    InkStrokeStyle style,
    int level, [
    int widthLevel = InkStroke.defaultWidthLevel,
  ]) {
    final (double min, double max) = rangeOf(style, widthLevel);
    if (max <= min) {
      return min;
    }
    final int clamped = level.clamp(0, levels - 1);
    return min + (max - min) * clamped / (levels - 1);
  }

  /// 校验/收敛粗细档（越界回落中档）。
  static int clampWidthLevel(int level) =>
      level.clamp(0, widthLevels - 1);

  static double _penWidth(double pressure, int widthLevel) {
    final (double min, double max) = rangeOf(
      InkStrokeStyle.pen,
      widthLevel,
    );
    final double mid = (min + max) / 2;
    // 无压感设备统一填 0.5（InkPoint 契约），这里把 0/1 的边界值也归到中值：
    // 鼠标事件 pressure 恒 1.0，不特判就会整笔最粗。
    if (pressure <= 0 || pressure >= 0.999) {
      return mid;
    }
    return min + (max - min) * pressure;
  }
}
