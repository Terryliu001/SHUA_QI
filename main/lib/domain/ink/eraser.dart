import 'dart:math' as math;

import 'package:shuaqi/domain/ink/ink_doc.dart';

/// 笔画级橡皮的几何判定（T2.3）。纯 Dart，可单测。
///
/// ## 为什么只做"笔画级"橡皮
/// 位图橡皮（擦出透明洞）会破坏矢量结构：导出 PDF 只能贴图、识别拿不到完整笔画、
/// SIF 也无法增量保存。规格把这条写成了硬约束，这里用类型（只返回"删哪些笔"）
/// 从结构上保证没人能写成位图擦除。
///
/// ## 判定顺序（便宜的先做）
/// 1. **包围盒预筛**：`bounds` 外扩 [radius] 后不相交 → 直接 false。
///    一页 5000 笔时这一步把 99% 的笔画挡在几何计算之外。
/// 2. **点到线段距离**：采样点之间的真实形状是折线，不能只看采样点本身
///    （稀疏采样的一笔，笔尖从两点之间划过也必须命中）。
/// 3. **段到段距离**：橡皮是"划线"而不是"点"，一次 move 事件可能跨过一整笔，
///    所以拿"橡皮这一段"和"笔画的每一段"求最近距离。
abstract final class Eraser {
  /// 命中半径（页面坐标 pt）。规格 T2.3：笔尖 12pt 内命中即删。
  ///
  /// 12pt 是"擦得动但不误伤"的折中：A4 页宽 595pt，12pt ≈ 2% 页宽；
  /// 再小就要反复蹭，再大轻碰一下会带走相邻行。
  static const double radiusPt = 12;

  /// 单点（笔尖落下的那一下）是否命中 [stroke]。
  static bool hitsPoint(
    InkStroke stroke,
    InkPoint at, {
    double radius = radiusPt,
  }) {
    if (stroke.points.isEmpty) {
      return false;
    }
    if (!_boxNear(stroke.bounds, at.x, at.y, radius)) {
      return false;
    }
    if (stroke.points.length == 1) {
      return _pointDistance(stroke.points.first, at.x, at.y) <= radius;
    }
    for (int i = 1; i < stroke.points.length; i++) {
      final InkPoint a = stroke.points[i - 1];
      final InkPoint b = stroke.points[i];
      if (_pointToSegment(at.x, at.y, a.x, a.y, b.x, b.y) <= radius) {
        return true;
      }
    }
    return false;
  }

  /// 橡皮从 [from] 划到 [to] 的这一段是否命中 [stroke]（"划过即删"）。
  ///
  /// [from] 为 null 表示这是落笔的那一下（等价于 [hitsPoint]）。
  static bool hitsSegment(
    InkStroke stroke,
    InkPoint from,
    InkPoint to, {
    double radius = radiusPt,
  }) {
    if (stroke.points.isEmpty) {
      return false;
    }
    // 预筛用整段的包围盒，而不是两端点：斜划的中间也可能压到笔画。
    final double left = math.min(from.x, to.x) - radius;
    final double right = math.max(from.x, to.x) + radius;
    final double top = math.min(from.y, to.y) - radius;
    final double bottom = math.max(from.y, to.y) + radius;
    final InkRect box = stroke.bounds;
    if (box.right < left || box.left > right || box.bottom < top ||
        box.top > bottom) {
      return false;
    }
    if (stroke.points.length == 1) {
      final InkPoint p = stroke.points.first;
      return _pointToSegment(p.x, p.y, from.x, from.y, to.x, to.y) <= radius;
    }
    for (int i = 1; i < stroke.points.length; i++) {
      final InkPoint a = stroke.points[i - 1];
      final InkPoint b = stroke.points[i];
      if (_segmentDistance(
            (from.x, from.y),
            (to.x, to.y),
            (a.x, a.y),
            (b.x, b.y),
          ) <=
          radius) {
        return true;
      }
    }
    return false;
  }

  /// 一页里该被这次擦除删掉的笔画（保持原顺序）。
  ///
  /// [from] 为 null 表示"点一下"。
  static List<InkStroke> strokesHit(
    List<InkStroke> strokes,
    InkPoint? from,
    InkPoint to, {
    double radius = radiusPt,
  }) {
    final List<InkStroke> hit = <InkStroke>[];
    for (final InkStroke stroke in strokes) {
      final bool isHit = from == null
          ? hitsPoint(stroke, to, radius: radius)
          : hitsSegment(stroke, from, to, radius: radius);
      if (isHit) {
        hit.add(stroke);
      }
    }
    return hit;
  }

  // ── 几何基元 ─────────────────────────────────────────────────────

  static bool _boxNear(InkRect box, double x, double y, double radius) {
    return x >= box.left - radius &&
        x <= box.right + radius &&
        y >= box.top - radius &&
        y <= box.bottom + radius;
  }

  static double _pointDistance(InkPoint p, double x, double y) {
    final double dx = p.x - x;
    final double dy = p.y - y;
    return math.sqrt(dx * dx + dy * dy);
  }

  /// 点到线段的距离。退化线段（两端重合）退化为点距。
  static double _pointToSegment(
    double px,
    double py,
    double ax,
    double ay,
    double bx,
    double by,
  ) {
    final double abx = bx - ax;
    final double aby = by - ay;
    final double lengthSq = abx * abx + aby * aby;
    if (lengthSq <= 1e-12) {
      final double dx = px - ax;
      final double dy = py - ay;
      return math.sqrt(dx * dx + dy * dy);
    }
    double t = ((px - ax) * abx + (py - ay) * aby) / lengthSq;
    t = t.clamp(0.0, 1.0);
    final double cx = ax + abx * t;
    final double cy = ay + aby * t;
    final double dx = px - cx;
    final double dy = py - cy;
    return math.sqrt(dx * dx + dy * dy);
  }

  /// 两条线段的最近距离（相交则为 0）。
  ///
  /// 标准做法：先判相交，否则取"四个端点到对方线段"的最小值。
  /// 对橡皮判定来说这就够了 —— 两段平行且中间有空隙时，端点距离就是最近距离。
  static double _segmentDistance(
    (double, double) a0,
    (double, double) a1,
    (double, double) b0,
    (double, double) b1,
  ) {
    if (_segmentsIntersect(a0, a1, b0, b1)) {
      return 0;
    }
    return math.min(
      math.min(
        _pointToSegment(a0.$1, a0.$2, b0.$1, b0.$2, b1.$1, b1.$2),
        _pointToSegment(a1.$1, a1.$2, b0.$1, b0.$2, b1.$1, b1.$2),
      ),
      math.min(
        _pointToSegment(b0.$1, b0.$2, a0.$1, a0.$2, a1.$1, a1.$2),
        _pointToSegment(b1.$1, b1.$2, a0.$1, a0.$2, a1.$1, a1.$2),
      ),
    );
  }

  static bool _segmentsIntersect(
    (double, double) a0,
    (double, double) a1,
    (double, double) b0,
    (double, double) b1,
  ) {
    double cross(
      (double, double) o,
      (double, double) p,
      (double, double) q,
    ) =>
        (p.$1 - o.$1) * (q.$2 - o.$2) - (p.$2 - o.$2) * (q.$1 - o.$1);
    final double d1 = cross(b0, b1, a0);
    final double d2 = cross(b0, b1, a1);
    final double d3 = cross(a0, a1, b0);
    final double d4 = cross(a0, a1, b1);
    return ((d1 > 0 && d2 < 0) || (d1 < 0 && d2 > 0)) &&
        ((d3 > 0 && d4 < 0) || (d3 < 0 && d4 > 0));
  }
}
