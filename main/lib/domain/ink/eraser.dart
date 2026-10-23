import 'dart:math' as math;

import 'package:shuaqi/domain/ink/ink_doc.dart';

/// 橡皮的几何：**局部擦除**（只擦掉划过的部分）+ 三档大小。纯 Dart，可单测。
///
/// ## 为什么是"切笔画"而不是"删整笔"
/// 用户 2026-10-23 明确要求：擦到哪删到哪。做法是把一笔折线按"落在橡皮圆内"
/// 的区间切成若干段，**保留的段拆成新笔画**（各给新 uid），被覆盖的段丢掉：
///
/// ```text
/// 原笔 ────────────────  （一条长横）
/// 擦         ●●            （橡皮划过一个点）
/// 结果 ──────      ──────  （两段，uid 是新的）
/// ```
///
/// ## 为什么不是位图橡皮
/// 位图橡皮（擦出透明洞）会毁掉矢量结构：导出 PDF 只能贴图、识别拿不到完整笔画、
/// SIF 无法增量保存。这里从结构上保证"只能产出笔画"——返回类型就是 `InkStroke` 列表。
///
/// ## 圆盘而不是"胶囊"
/// 橡皮拖动路径本身是一条折线（胶囊），但把路径按 ≤ 半径的间距采样成一串**圆盘**后，
/// 每个圆盘与线段的交集都有**精确解**（二次方程），比做胶囊-线段求交简单且准。
/// 采样步长取 `min(radius, 4pt)`：既不会把路径切得过密，也保证不漏擦。
abstract final class Eraser {
  /// 橡皮半径区间（pt）：粗细 0 → 4pt，100 → 28pt。
  ///
  /// 12pt（≈ 33% 档）是规格 T2.3 的值，也是"擦得动但不误伤"的折中：
  /// A4 页宽 595pt，12pt ≈ 2% 页宽。2026-10-23 用户要求"大小多级可调"，
  /// 于是从 3 档枚举改成 0..100 连续档（UI 上是滑条 + 大小参考圈）。
  static const double minRadius = 4;
  static const double maxRadius = 28;

  /// 兼容旧调用（默认中档 ≈ 12pt）。
  static const double defaultRadius = 12;

  /// 粗细 0..100 → 橡皮半径（pt）。
  static double radiusOfWidth(int brushWidth) {
    final double t =
        brushWidth.clamp(InkStroke.brushWidthMin, InkStroke.brushWidthMax) /
        InkStroke.brushWidthMax;
    return minRadius + (maxRadius - minRadius) * t;
  }

  // ── 局部擦除（主入口）──────────────────────────────────────────────

  /// 把 [stroke] 按橡皮路径 [eraserPath] 切开，返回**保留的碎片**。
  ///
  /// 返回 null = 这一笔完全没被擦到（调用方据此跳过，避免无谓的重建）。
  /// 返回空列表 = 整笔被擦光。
  ///
  /// [newUid] 由调用方提供（domain 不持有 id 生成器，保持可测与无隐式随机源）。
  static List<InkStroke>? carve({
    required InkStroke stroke,
    required List<InkPoint> eraserPath,
    required double radius,
    required String Function() newUid,
  }) {
    final List<InkPoint> points = stroke.points;
    if (points.isEmpty) {
      return null;
    }
    final List<InkPoint> discs = _densifyPath(eraserPath, radius);
    if (discs.isEmpty) {
      return null;
    }

    // 单点笔画（点一下）：要么整体在圆内，要么不动。
    if (points.length == 1) {
      final InkPoint only = points.first;
      for (final InkPoint disc in discs) {
        if (_dist(only, disc) <= radius) {
          return <InkStroke>[];
        }
      }
      return null;
    }

    final List<InkStroke>? result = _cutAlong(
      stroke: stroke,
      discs: discs,
      radius: radius,
      newUid: newUid,
    );
    return result;
  }

  /// 切分主循环：逐段求"被覆盖的 t 区间"，把没被覆盖的部分攒成新笔画。
  static List<InkStroke>? _cutAlong({
    required InkStroke stroke,
    required List<InkPoint> discs,
    required double radius,
    required String Function() newUid,
  }) {
    final List<InkPoint> points = stroke.points;
    final List<List<InkPoint>> runs = <List<InkPoint>>[];
    List<InkPoint> current = <InkPoint>[points.first];
    bool erased = false;

    for (int i = 1; i < points.length; i++) {
      final InkPoint a = points[i - 1];
      final InkPoint b = points[i];
      if (current.isEmpty) {
        current = <InkPoint>[a];
      }
      final List<(double, double)> covered = _coveredIntervals(a, b, discs, radius);
      if (covered.isEmpty) {
        current.add(b);
        continue;
      }
      erased = true;
      double cursor = 0;
      for (final (double t0, double t1) in covered) {
        if (t0 > cursor + _eps) {
          // 先关掉 [cursor, t0] 这一段（如果够长）
          final InkPoint start = _lerp(a, b, cursor);
          final InkPoint end = _lerp(a, b, t0);
          if (current.isEmpty) {
            current.add(start);
          } else if (!_samePoint(current.last, start)) {
            current.add(start);
          }
          current.add(end);
          if (current.length >= 2) {
            runs.add(current);
          }
          current = <InkPoint>[];
        } else if (current.length >= 2) {
          // 覆盖从段首就开始：把手上这段收尾
          current.add(_lerp(a, b, cursor));
          runs.add(current);
          current = <InkPoint>[];
        } else {
          current = <InkPoint>[];
        }
        cursor = math.max(cursor, t1);
      }
      if (cursor < 1 - _eps) {
        // 段尾还有没被覆盖的部分
        current = <InkPoint>[_lerp(a, b, cursor), b];
      }
    }
    if (current.length >= 2) {
      runs.add(current);
    }
    if (!erased) {
      return null;
    }
    return <InkStroke>[
      for (final List<InkPoint> run in runs)
        InkStroke(
          uid: newUid(),
          points: run,
          style: stroke.style,
          // 碎片继承原笔的笔刷/颜色/粗细：擦掉一半不该让另一半换色变粗。
          colorIndex: stroke.colorIndex,
          brushWidth: stroke.brushWidth,
        ),
    ];
  }

  /// 线段 a→b 上被圆盘覆盖的 t 区间（已排序合并）。
  static List<(double, double)> _coveredIntervals(
    InkPoint a,
    InkPoint b,
    List<InkPoint> discs,
    double radius,
  ) {
    final List<(double, double)> raw = <(double, double)>[];
    for (final InkPoint disc in discs) {
      final (double, double)? iv = _discInterval(a, b, disc, radius);
      if (iv != null) {
        raw.add(iv);
      }
    }
    if (raw.isEmpty) {
      return const <(double, double)>[];
    }
    raw.sort(((double, double) x, (double, double) y) => x.$1.compareTo(y.$1));
    final List<(double, double)> merged = <(double, double)>[raw.first];
    for (int i = 1; i < raw.length; i++) {
      final (double, double) last = merged.last;
      final (double, double) next = raw[i];
      if (next.$1 <= last.$2 + _eps) {
        merged[merged.length - 1] = (last.$1, math.max(last.$2, next.$2));
      } else {
        merged.add(next);
      }
    }
    return merged;
  }

  /// 线段 a→b 与圆盘（圆心 c，半径 r）相交的参数区间；不相交返回 null。
  ///
  /// 解 `|a + t(b-a) - c|² ≤ r²`：`At² + Bt + C ≤ 0`（A≥0），取根之间的区间，
  /// 再与 [0,1] 求交。这是精确解，没有采样误差。
  static (double, double)? _discInterval(
    InkPoint a,
    InkPoint b,
    InkPoint c,
    double r,
  ) {
    final double dx = b.x - a.x;
    final double dy = b.y - a.y;
    final double fx = a.x - c.x;
    final double fy = a.y - c.y;
    final double aa = dx * dx + dy * dy;
    final double cc = fx * fx + fy * fy - r * r;
    if (aa <= 1e-12) {
      // 退化线段：整段就是一个点
      return cc <= 0 ? (0.0, 1.0) : null;
    }
    final double bb = 2 * (fx * dx + fy * dy);
    final double disc = bb * bb - 4 * aa * cc;
    if (disc < 0) {
      return null;
    }
    final double sqrtDisc = math.sqrt(disc);
    double t0 = (-bb - sqrtDisc) / (2 * aa);
    double t1 = (-bb + sqrtDisc) / (2 * aa);
    t0 = t0.clamp(0.0, 1.0);
    t1 = t1.clamp(0.0, 1.0);
    if (t1 - t0 <= _eps) {
      return null;
    }
    return (t0, t1);
  }

  /// 把橡皮路径采样成圆盘：步长 ≤ min(radius, 4pt)，单点时就是它自己。
  static List<InkPoint> _densifyPath(List<InkPoint> path, double radius) {
    if (path.isEmpty) {
      return const <InkPoint>[];
    }
    final double step = math.min(radius, 4);
    if (path.length == 1 || step <= 0) {
      return path;
    }
    final List<InkPoint> out = <InkPoint>[path.first];
    for (int i = 1; i < path.length; i++) {
      final InkPoint a = path[i - 1];
      final InkPoint b = path[i];
      final double len = _dist(a, b);
      final int n = math.max(1, (len / step).ceil());
      for (int k = 1; k <= n; k++) {
        out.add(_lerpPoint(a, b, k / n));
      }
    }
    return out;
  }

  /// 便宜的"可能碰到"预筛：只比包围盒，不做精确几何。
  ///
  /// 为什么必须有：局部擦除要**逐笔**调用 [carve]，而一页可能有 5000 笔。
  /// 每个 move 事件都全量求交会直接卡死；先过一遍包围盒，
  /// 真正进入几何计算的通常只有 1–3 笔。
  static bool mayTouch(
    InkStroke stroke,
    InkPoint? from,
    InkPoint to, {
    required double radius,
  }) {
    if (stroke.points.isEmpty) {
      return false;
    }
    final double left =
        math.min(from?.x ?? to.x, to.x) - radius;
    final double right =
        math.max(from?.x ?? to.x, to.x) + radius;
    final double top = math.min(from?.y ?? to.y, to.y) - radius;
    final double bottom = math.max(from?.y ?? to.y, to.y) + radius;
    final InkRect box = stroke.bounds;
    return !(box.right < left ||
        box.left > right ||
        box.bottom < top ||
        box.top > bottom);
  }

  // ── 旧接口（保留：整笔判定、橡皮覆盖预览、快速命中测试）───────────

  /// 单点（笔尖落下的那一下）是否命中 [stroke]。
  static bool hitsPoint(
    InkStroke stroke,
    InkPoint at, {
    double radius = defaultRadius,
  }) {
    if (stroke.points.isEmpty) {
      return false;
    }
    if (!_boxNear(stroke.bounds, at.x, at.y, radius)) {
      return false;
    }
    if (stroke.points.length == 1) {
      return _dist(stroke.points.first, at) <= radius;
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

  /// 橡皮从 [from] 划到 [to] 的这一段是否命中 [stroke]（"划过即删"的快速判定）。
  static bool hitsSegment(
    InkStroke stroke,
    InkPoint from,
    InkPoint to, {
    double radius = defaultRadius,
  }) {
    if (stroke.points.isEmpty) {
      return false;
    }
    final double left = math.min(from.x, to.x) - radius;
    final double right = math.max(from.x, to.x) + radius;
    final double top = math.min(from.y, to.y) - radius;
    final double bottom = math.max(from.y, to.y) + radius;
    final InkRect box = stroke.bounds;
    if (box.right < left ||
        box.left > right ||
        box.bottom < top ||
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

  /// 一页里"被橡皮碰到"的笔画（**不再用于删除**，只用于候选筛选/高亮预览）。
  static List<InkStroke> strokesHit(
    List<InkStroke> strokes,
    InkPoint? from,
    InkPoint to, {
    double radius = defaultRadius,
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

  static const double _eps = 1e-9;

  static double _dist(InkPoint a, InkPoint b) {
    final double dx = a.x - b.x;
    final double dy = a.y - b.y;
    return math.sqrt(dx * dx + dy * dy);
  }

  static bool _samePoint(InkPoint a, InkPoint b) => _dist(a, b) <= 1e-6;

  static InkPoint _lerp(InkPoint a, InkPoint b, double t) {
    if (t <= 0) {
      return a;
    }
    if (t >= 1) {
      return b;
    }
    return InkPoint(
      x: a.x + (b.x - a.x) * t,
      y: a.y + (b.y - a.y) * t,
      pressure: a.pressure + (b.pressure - a.pressure) * t,
      t: a.t + ((b.t - a.t) * t).round(),
    );
  }

  static InkPoint _lerpPoint(InkPoint a, InkPoint b, double t) => _lerp(a, b, t);

  static bool _boxNear(InkRect box, double x, double y, double radius) {
    return x >= box.left - radius &&
        x <= box.right + radius &&
        y >= box.top - radius &&
        y <= box.bottom + radius;
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
    double cross((double, double) o, (double, double) p, (double, double) q) =>
        (p.$1 - o.$1) * (q.$2 - o.$2) - (p.$2 - o.$2) * (q.$1 - o.$1);
    final double d1 = cross(b0, b1, a0);
    final double d2 = cross(b0, b1, a1);
    final double d3 = cross(a0, a1, b0);
    final double d4 = cross(a0, a1, b1);
    return ((d1 > 0 && d2 < 0) || (d1 < 0 && d2 > 0)) &&
        ((d3 > 0 && d4 < 0) || (d3 < 0 && d4 > 0));
  }
}
