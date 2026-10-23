import 'package:shuaqi/domain/ink/ink_doc.dart';

/// 笔宽映射（纯 Dart，可单测）：压感 + **0..100 的可调粗细** → 线宽（pt）。
///
/// ## 为什么从"三档"改成"0..100"
/// 2026-10-23 用户要求"笔粗细多级可调"。三档（细/中/粗）选项太少，
/// 写小字和画框需要的手感差得远；而 0..100 的整数正好塞进 1 字节，
/// SIF 一个 stroke 只多 1 字节，与"三档枚举"的代价一样。
///
/// ## 映射（`brushWidth` 0 = 最细，100 = 最粗，50 = 默认）
/// | 笔 | 基础宽度 |
/// |---|---|
/// | 钢笔 | `0.8 → 5.2pt`，再乘压感系数 `0.55 + 0.65·p`（轻 55%、重 120%） |
/// | 圆珠笔 | `1.0 → 4.0pt` 等宽 |
/// | 荧光笔 | `6 → 36pt` 等宽 |
///
/// 钢笔保留压感：粗细档定的是"这支笔有多重"，压力定的是"这一下按多重"。
/// 两者相乘，得到"同一支笔能提按"的自然手感（不是只有粗细两档的死线）。
///
/// ## 为什么不直接用连续宽度画
/// Canvas 只有"整条 Path 一个 strokeWidth"。要一笔内粗细连续变化，只有两条路：
/// ① 每段一次 drawLine（正在写的这一笔几百段，可以；已提交的几万段，不行）；
/// ② 把宽度**量化成有限档**，每档一条 Path（已提交只画 N 条 Path）。
/// 早先的做法是路 ① 画活笔、路 ② 画死笔，于是抬笔瞬间整笔宽度跳到档位中心——
/// 用户看到的就是"抬笔粗细突变"。现在两条路统一走量化档，且共用同一个
/// `InkRibbon`（`ui/reader/ink_ribbon.dart`），抬笔前后**像素级一致**。
abstract final class InkWidth {
  /// 钢笔基础宽度区间（pt），`brushWidth` 0..100 线性插值。
  static const double penBaseMin = 0.8;
  static const double penBaseMax = 5.2;

  /// 圆珠笔等宽区间。
  static const double ballpointMin = 1.0;
  static const double ballpointMax = 4.0;

  /// 荧光笔等宽区间。
  static const double highlighterMin = 6;
  static const double highlighterMax = 36;

  /// 压感系数：轻按 55%，重按 120%（相对基础宽度）。
  static const double pressureFloor = 0.55;
  static const double pressureSpan = 0.65;

  /// 无压感输入（鼠标 / 触摸）与"落笔第一帧压力读数缺失"时的中性压力。
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

  /// 线宽量化档数。最宽笔（荧光笔 36pt）被切成 24 档 → 1.5pt 一档，
  /// 钢笔最细档 0.8–0.96pt 时同样是 24 档（0.007pt 一档）——
  /// 量化按"这一笔的实际区间"归一，不是全局固定步长。
  static const int levels = 24;

  static double _t(int brushWidth) =>
      brushWidth.clamp(InkStroke.brushWidthMin, InkStroke.brushWidthMax) /
      InkStroke.brushWidthMax;

  /// 该笔刷在该粗细下的**基础宽度**（不含压感）。
  ///
  /// UI 的"大小参考圈"用的就是它（钢笔取中性压力时的大小）。
  static double baseOf(InkStrokeStyle style, int brushWidth) {
    final double t = _t(brushWidth);
    switch (style) {
      case InkStrokeStyle.pen:
        return penBaseMin + (penBaseMax - penBaseMin) * t;
      case InkStrokeStyle.ballpoint:
        return ballpointMin + (ballpointMax - ballpointMin) * t;
      case InkStrokeStyle.highlighter:
        return highlighterMin + (highlighterMax - highlighterMin) * t;
    }
  }

  /// [style] 在压力 [pressure]（0..1）与粗细 [brushWidth]（0..100）下的线宽（pt）。
  static double forStroke(
    InkStrokeStyle style,
    double pressure, [
    int brushWidth = InkStroke.defaultBrushWidth,
  ]) {
    final double base = baseOf(style, brushWidth);
    if (style != InkStrokeStyle.pen) {
      return base; // 等宽笔刷不响应压感
    }
    final double p = (pressure <= 0 || pressure >= 0.999)
        ? neutralPressure
        : pressure;
    return base * (pressureFloor + pressureSpan * p);
  }

  /// 该笔刷在该粗细下的线宽区间（等宽笔刷 min == max）。
  ///
  /// 用于量化档位：区间归一后切成 [levels] 档。
  static (double, double) rangeOf(
    InkStrokeStyle style, [
    int brushWidth = InkStroke.defaultBrushWidth,
  ]) {
    final double base = baseOf(style, brushWidth);
    if (style != InkStrokeStyle.pen) {
      return (base, base);
    }
    return (
      base * (pressureFloor + pressureSpan * 0.02),
      base * (pressureFloor + pressureSpan * 0.98),
    );
  }

  /// 宽度 → 档位（0..[levels]-1）。等宽笔刷恒为 0（整笔一条 Path）。
  static int levelOf(
    InkStrokeStyle style,
    double width, [
    int brushWidth = InkStroke.defaultBrushWidth,
  ]) {
    final (double min, double max) = rangeOf(style, brushWidth);
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
    int brushWidth = InkStroke.defaultBrushWidth,
  ]) {
    final (double min, double max) = rangeOf(style, brushWidth);
    if (max <= min) {
      return min;
    }
    final int clamped = level.clamp(0, levels - 1);
    return min + (max - min) * clamped / (levels - 1);
  }

  /// 无压感输入（压力恒 0 或恒 1）时的宽度：中性压力下的宽度。
  static double midWidth(
    InkStrokeStyle style, [
    int brushWidth = InkStroke.defaultBrushWidth,
  ]) => forStroke(style, neutralPressure, brushWidth);

  /// 校验/收敛粗细（越界夹到 0..100）。
  static int clampBrushWidth(int value) =>
      value.clamp(InkStroke.brushWidthMin, InkStroke.brushWidthMax);
}
