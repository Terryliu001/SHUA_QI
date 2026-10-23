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

/// 拖动的**轴向锁定**（2026-10-23：用户反馈"上下滑动有些迟钝"）。
///
/// ## 问题
/// 人手指划过屏幕时不可能笔直：想竖着翻页，实际轨迹总有 10°–30° 的横向分量。
/// 旧实现把 x/y 两个分量**都**照单全收（并各自夹紧 / 各自橡皮筋），于是：
/// 1. 横向分量被夹紧在中间位置 → 那部分位移**凭空消失**，竖滑只走了
///    `dy`（虽然数值上是对的，但手指走过的斜线距离明显更长，主观就是"没跟手"）；
/// 2. 一旦缩放放大到内容宽于视口，斜滑会让页面**斜着漂**，竖着看的内容左右乱窜；
/// 3. 本轮加的橡皮筋在横向也生效 → 斜滑时页面会左右晃一下再弹回。
///
/// ## 规则
/// 每次手势**只认一个轴**，且**偏向竖轴**（这是阅读器，竖滑是绝对主诉求）：
/// - 先看"横向能不能动"（内容宽 ≤ 视口宽时不能动）→ 不能动就直接锁竖轴，
///   连判定都不用等；
/// - 能动时，累计位移超过 [decideDistance] 后按 `|dy| ≥ |dx|·[verticalBias]`
///   判定：竖轴的**容错区间非常宽**（偏 35° 以内都算竖）；
/// - 判定后整段手势不再改轴（避免中途跳轴导致画面顿一下）。
abstract final class DragAxisLock {
  /// 判定前的位移阈值（逻辑像素）。太小会被抖动误判，太大会有"起手迟滞"。
  /// 6dp ≈ 指尖轻微移动的量，真机上几乎察觉不到。
  static const double decideDistance = 6;

  /// 竖轴偏好：`|dy| ≥ |dx| × 0.7` 即判为竖轴（约偏 35° 以内都算竖滑）。
  static const double verticalBias = 0.7;

  /// 根据**手势累计位移**判定轴向。
  ///
  /// 返回 `true` = 竖轴；`false` = 横轴；`null` = 还没到阈值，继续等。
  /// [allowHorizontal] 为 false（内容窄于视口、横向根本推不动）时直接判竖轴。
  static bool? decide(
    double dx,
    double dy, {
    bool allowHorizontal = true,
  }) {
    if (!allowHorizontal) {
      return true;
    }
    if (dx.abs() < decideDistance && dy.abs() < decideDistance) {
      return null;
    }
    return dy.abs() >= dx.abs() * verticalBias;
  }

  /// 锁定后把位移投影到该轴上（另一轴归零）。
  ///
  /// 返回 `(dx, dy)`：锁定竖轴时 dx 为 0，锁定横轴时 dy 为 0。
  static (double, double) project(
    double dx,
    double dy, {
    required bool vertical,
  }) => vertical ? (0, dy) : (dx, 0);
}
