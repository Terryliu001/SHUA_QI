/// 切题置信度与三色分级（纯 Dart，可单测）。
///
/// 公式与权重照抄规格 T3.2：
/// ```text
/// conf = 0.45
///      + 0.20 * boundaryScore   // 下一题号是否同栏、间距是否合理
///      + 0.15 * styleScore      // 字号/字体与相邻题一致
///      + 0.10 * orderScore      // 题号连续（允许 1 个跳号）
///      + 0.10 * textScore       // 题干长度 > 8 字
///      - 0.20（来源为 OCR / 版面推断）
/// ```
///
/// 三个分数都是 0..1 的**连续**值，不是"是/否"——"间距略大"应该只扣一点，
/// 否则一个阈值就把 0.80 拽到 0.55，黄色框满天飞。
library;

/// 三色分级。
enum RegionGrade {
  /// ≥0.80：可以直接用。
  green,

  /// 0.55–0.80：建议扫一眼。
  yellow,

  /// <0.55：基本不可信，需要人改。
  red;

  static RegionGrade of(double confidence) {
    if (confidence >= greenThreshold) {
      return RegionGrade.green;
    }
    if (confidence >= yellowThreshold) {
      return RegionGrade.yellow;
    }
    return RegionGrade.red;
  }
}

const double greenThreshold = 0.80;
const double yellowThreshold = 0.55;

/// 置信度输入。每个字段都对应规格公式里的一项。
class ConfidenceSignals {
  const ConfidenceSignals({
    required this.boundary,
    required this.style,
    required this.order,
    required this.text,
    this.fromOcr = false,
  });

  /// 0..1。下一题号在同栏、且间距落在合理范围时接近 1。
  final double boundary;

  /// 0..1。字号与前一题一致时接近 1。
  final double style;

  /// 0..1。题号连续时 1，跳 1 个号 0.5，更多 0。
  final double order;

  /// 0..1。题干长度的饱和函数（>8 字记满）。
  final double text;

  /// 来源是 OCR（扫描件）或纯版面推断：整体 −0.20。
  final bool fromOcr;
}

double regionConfidence(ConfidenceSignals signals) {
  double value =
      0.45 +
      0.20 * _clamp01(signals.boundary) +
      0.15 * _clamp01(signals.style) +
      0.10 * _clamp01(signals.order) +
      0.10 * _clamp01(signals.text);
  if (signals.fromOcr) {
    value -= 0.20;
  }
  return _clamp01(value);
}

/// 相邻题号连续性 → orderScore。
///
/// 允许**一个**跳号：试卷里"第 3 题"被编辑删掉但题号没改，是常见情况。
double orderScore({required int? current, required int? previous}) {
  if (current == null || previous == null) {
    return 0.5;
  }
  final int delta = current - previous;
  if (delta == 1) {
    return 1;
  }
  if (delta == 2) {
    return 0.5;
  }
  return delta > 0 ? 0.2 : 0.0;
}

/// 题干长度 → textScore。8 字以上记满，线性过渡到 0（空题干）。
double textScore(String stem) {
  final int length = stem.trim().length;
  if (length <= 0) {
    return 0;
  }
  if (length >= 8) {
    return 1;
  }
  return length / 8;
}

/// 字号一致性 → styleScore。
///
/// 与**同层级字号中位数**比较（不是相邻那一行：噪声会互相放大）。
/// 下限是 0.4 而不是 0：字号本身就是近似值（pdfrx 不给 fontSize，多行公式对象还会
/// 把行撑高 2–3 倍），拿它一票否决一道几何上完全正确的框，是过度惩罚。
double styleScore({
  required double fontSize,
  required double previousFontSize,
}) {
  if (fontSize <= 0 || previousFontSize <= 0) {
    return 0.5;
  }
  final double diff = (fontSize - previousFontSize).abs() / previousFontSize;
  if (diff <= 0.02) {
    return 1;
  }
  if (diff <= 0.15) {
    return 1 - (diff - 0.02) / 0.13 * 0.3;
  }
  if (diff >= 0.45) {
    return 0.4;
  }
  return 0.7 - (diff - 0.15) / 0.30 * 0.3;
}

/// 题末到下一题号之间的留白 → boundaryScore。
///
/// 合理区间：**0–3 倍行高**（0 表示紧贴下一题，常见于密排卷；≥3 倍行高说明中间
/// 可能漏掉了内容或跨了栏）。超过 [maxGapRatio] 线性衰减到 0.3，不直接归零——
/// "留白大"通常是"这里有图或空白作答区"，题还是对的。
double boundaryScore({
  required double gap,
  required double fontSize,
  required bool sameColumn,
  required bool hasNext,
}) {
  if (!hasNext) {
    // 最后一题：没有下界可比，给中性分（不是错，只是无法验证）。
    return 0.6;
  }
  if (!sameColumn) {
    return 0.4;
  }
  if (fontSize <= 0) {
    return 0.7;
  }
  // 负 gap 不是"留白异常"：那是上下标/公式碎片落到了下一题题号行之后的数据假象。
  // 当成 0 处理（紧贴），否则每道含公式的题都会被扣成黄框。
  final double ratio = gap / fontSize;
  if (ratio < 0) {
    return 1;
  }
  if (ratio <= 3) {
    return 1;
  }
  final double extra = (ratio - 3) / 6;
  return extra >= 0.7 ? 0.3 : 1 - extra;
}

double _clamp01(double value) {
  if (value.isNaN) {
    return 0;
  }
  if (value < 0) {
    return 0;
  }
  if (value > 1) {
    return 1;
  }
  return value;
}
