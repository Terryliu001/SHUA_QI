import 'package:shuaqi/domain/ink/ink_doc.dart';

/// 笔宽映射（纯 Dart，可单测）：压感 → 线宽（pt）。
///
/// 数值来源：T0.2 spike 在 OPPO OPD2601 上的实测区间（钢笔 1.2–4.6pt
/// 在 400dpi 屏上轻重分明且不糊）。压力恒值（鼠标 / 无压感设备）时
/// 取区间中值，避免整页糊成粗线或细到看不见。
///
/// 荧光笔是**等宽乘算**：宽度固定、颜色半透明，交给 painter 用
/// BlendMode.multiply 合成——下方文字必须可读（REQ-03）。
abstract final class InkWidth {
  /// 钢笔：压感驱动，轻 1.2pt / 重 4.6pt。
  static const double penMin = 1.2;
  static const double penMax = 4.6;

  /// 圆珠笔：等宽，略细于钢笔中值。
  static const double ballpoint = 1.8;

  /// 荧光笔：等宽、宽。
  static const double highlighter = 14;

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

  static double _penWidth(double pressure) {
    // 无压感设备统一填 0.5（InkPoint 契约），这里把 0/1 的边界值也归到中值：
    // 鼠标事件 pressure 恒 1.0，不特判就会整笔最粗。
    if (pressure <= 0 || pressure >= 0.999) {
      return penMid;
    }
    return penMin + (penMax - penMin) * pressure;
  }
}
