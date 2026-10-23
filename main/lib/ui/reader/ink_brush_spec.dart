import 'package:flutter/material.dart';
import 'package:shuaqi/domain/ink/ink_doc.dart';
import 'package:shuaqi/domain/ink/ink_palette.dart';

/// 一笔的**绘制规格**：样式 + 颜色 + 粗细 + 混合模式，全部解析完的值。
///
/// ## 为什么要有这个类（T2.3 留下的活笔/死笔分裂 bug 的根治）
/// 之前"正在写的这一笔"和"已提交的笔"各自拼一次绘制参数：
/// - 已提交层（`CommittedInkCache`）知道荧光笔要 `multiply` + 荧光色；
/// - 活动层（`InkLayer._ribbonFor`）只传了 `InkRibbon(style, color)`，
///   `blendMode` 用默认的 `srcOver`、颜色用的是**墨色**。
/// 于是荧光笔落笔的瞬间画出来是**不透明的深色**，抬笔后才变成半透明荧光
/// （用户报的"落笔是黑色，之后才渲染成荧光"）。
///
/// 修法不是补一个参数，而是**只留一条构造路径**：两边都用 [InkBrushSpec.of]
/// 解析同一个 spec。以后再也不会出现"两层参数不一致"。
@immutable
class InkBrushSpec {
  const InkBrushSpec({
    required this.style,
    required this.colorIndex,
    required this.brushWidth,
    required this.color,
    required this.blendMode,
  });

  /// 从笔迹/工具设置解析出绘制规格。
  ///
  /// [darkPaper] 决定取色表（夜读纸用同色相提亮版）。
  ///
  /// ## 荧光笔为什么不用 multiply（2026-10-23 真机实测改的）
  /// 设计上"荧光笔 = 乘算"最像真马克笔（压住文字但不变灰）。但墨迹层现在是
  /// **自己的合成层**（RepaintBoundary，滚动性能需要），层内背景是**透明的**，
  /// 而 `multiply` / `screen` 这类"依赖目标像素"的混合模式在透明背景上
  /// 算不出可见结果 —— 实测：荧光笔一笔画完，屏幕上一个像素都没变
  /// （像素扫描 0 个黄色像素，日志显示 360 个点已提交、已绘制）。
  ///
  /// 所以改成**半透明 + srcOver**：视觉上就是一道透光色带，下方文字仍然清楚
  /// （REQ-03 要的是"文字可读"，不是"必须乘算"），而且不依赖合成层背景，
  /// 亮纸暗纸表现一致。
  factory InkBrushSpec.of({
    required InkStrokeStyle style,
    required int colorIndex,
    required int brushWidth,
    required bool darkPaper,
  }) {
    return InkBrushSpec(
      style: style,
      colorIndex: InkPalette.clampIndex(style, colorIndex),
      brushWidth: brushWidth.clamp(
        InkStroke.brushWidthMin,
        InkStroke.brushWidthMax,
      ),
      color: Color(
        InkPalette.argb(
          style: style,
          index: colorIndex,
          darkPaper: darkPaper,
        ),
      ),
      blendMode: BlendMode.srcOver,
    );
  }

  final InkStrokeStyle style;
  final int colorIndex;
  final int brushWidth;
  final Color color;
  final BlendMode blendMode;

  bool get isHighlighter => style == InkStrokeStyle.highlighter;

  /// 绘制顺序权重：荧光笔垫底（否则会给下方已写的字再乘一次色），
  /// 然后钢笔、圆珠笔。
  int get _styleRank => switch (style) {
    InkStrokeStyle.highlighter => 0,
    InkStrokeStyle.pen => 1,
    InkStrokeStyle.ballpoint => 2,
  };

  /// 稳定的绘制顺序（同 rank 内按粗细、颜色排，保证每次重绘结果一致）。
  static int compare(InkBrushSpec a, InkBrushSpec b) {
    final int byStyle = a._styleRank.compareTo(b._styleRank);
    if (byStyle != 0) {
      return byStyle;
    }
    final int byWidth = a.brushWidth.compareTo(b.brushWidth);
    if (byWidth != 0) {
      return byWidth;
    }
    return a.colorIndex.compareTo(b.colorIndex);
  }

  @override
  bool operator ==(Object other) =>
      other is InkBrushSpec &&
      other.style == style &&
      other.colorIndex == colorIndex &&
      other.brushWidth == brushWidth &&
      other.color == color &&
      other.blendMode == blendMode;

  @override
  int get hashCode =>
      Object.hash(style, colorIndex, brushWidth, color, blendMode);

  @override
  String toString() =>
      'InkBrushSpec(${style.name}#$colorIndex×$brushWidth $blendMode)';
}
