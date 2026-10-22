import 'dart:math' as math;

/// 滚动画布（连续滚动模式）的纯几何。
///
/// 为什么抽成 domain 纯函数：滚动模式第五版的"丝滑"改造把每帧的
/// 可见集 / 主可见页 / 夹紧计算从 `build` 挪进了手势与 ticker 回调
/// （每帧都跑）。这些计算必须能脱离 UI 单测，也不能碰 Flutter
/// （手势回调里拿不到 context，且 domain 禁止 import dart:ui）。
///
/// 约定：[tops] / [heights] 同长，tops 升序（布局时生成即如此）；
/// 坐标一律内容坐标（页在 `_baseWidth` 下排一次版，缩放不动它）。
abstract final class ScrollMath {
  /// 与视口 `[visibleTop, visibleBottom]` 相交的页区间 `(first, last)`；
  /// 一页都不相交时返回 null（内容被整个推走，正常不应出现）。
  ///
  /// 带 early-break：300 页的卷每次调用也只扫到视口附近的几页。
  static (int, int)? visibleRange(
    List<double> tops,
    List<double> heights,
    double visibleTop,
    double visibleBottom,
  ) {
    if (tops.isEmpty || heights.length != tops.length) {
      return null;
    }
    if (visibleBottom <= visibleTop) {
      return null;
    }
    int first = -1;
    int last = -1;
    for (int i = 0; i < tops.length; i++) {
      final double top = tops[i];
      if (top >= visibleBottom) {
        break; // 后面的页只会更低，不可能再相交
      }
      if (top + heights[i] <= visibleTop) {
        continue;
      }
      if (first < 0) {
        first = i;
      }
      last = i;
    }
    return first < 0 ? null : (first, last);
  }

  /// 主可见页 = 与视口**重叠高度最大**的那一页（规格 §6.9.2）。
  ///
  /// 不用 `offset / 页高` 推：A4/A3 混排时页高不同，直接除会推错。
  /// 空列表返回 0（调用方保证非空）。
  static int mainVisiblePage(
    List<double> tops,
    List<double> heights,
    double visibleTop,
    double visibleBottom,
  ) {
    if (tops.isEmpty) {
      return 0;
    }
    int best = 0;
    double bestOverlap = -1;
    for (int i = 0; i < tops.length; i++) {
      final double top = math.max(tops[i], visibleTop);
      final double bottom = math.min(tops[i] + heights[i], visibleBottom);
      final double overlap = bottom - top;
      if (overlap > bestOverlap) {
        bestOverlap = overlap;
        best = i;
      }
    }
    return best;
  }

  /// 平移夹紧（第四版立下的规则，不许改）。
  ///
  /// - 横向内容窄于视口 → **居中**（1 倍 = fit-width 时正好铺满，无黑边）；
  /// - 横向宽于视口 → 夹在 `[视口宽 - 内容宽, 0]`，不许推过头露背景；
  /// - 纵向内容矮于视口 → 顶端对齐（0）；否则夹在 `[视口高 - 内容高, 0]`。
  ///
  /// 返回 `(dx, dy)` 而不是 `Offset`：domain 不许 import dart:ui。
  static (double, double) clampOffset({
    required double offsetX,
    required double offsetY,
    required double scale,
    required double contentWidth,
    required double contentHeight,
    required double viewportWidth,
    required double viewportHeight,
  }) {
    final double w = contentWidth * scale;
    final double h = contentHeight * scale;
    final double x = w <= viewportWidth
        ? (viewportWidth - w) / 2
        : offsetX.clamp(viewportWidth - w, 0.0);
    final double y = h <= viewportHeight
        ? 0.0
        : offsetY.clamp(viewportHeight - h, 0.0);
    return (x, y);
  }
}
