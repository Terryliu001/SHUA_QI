import 'dart:math' as math;

import 'package:shuaqi/domain/ink/ink_doc.dart';

/// 手绘图形吸附（纯 Dart，2026-10-26 用户第 6 条）。
///
/// ## 为什么自己做
/// 依赖白名单里没有图形识别库；而"直线 / 矩形 / 圆 / 三角形 / 平行四边形"
/// 本质上是几十行几何。这里采用**模板粗分类 + 几何拟合 + 残差拒识**：
/// 1. 先按端点距离/闭合度判断"线"还是"闭合图形"；
/// 2. 闭合图形先试椭圆拟合（圆/椭圆），再用 RDP 简化出 3/4 个角点；
/// 3. 每个候选都算"原笔迹到理想形状的平均距离"，超过阈值**不吸附**。
///
/// 判定宁可保守：用户继续移动就能取消；误吸比不吸更烦人。
enum SnapShape {
  line,
  rectangle,
  square,
  ellipse,
  circle,
  triangle,
  rightTriangle,
  isoscelesTriangle,
  parallelogram,
}

extension SnapShapeLabel on SnapShape {
  String get label => switch (this) {
    SnapShape.line => '直线',
    SnapShape.rectangle => '矩形',
    SnapShape.square => '正方形',
    SnapShape.ellipse => '椭圆',
    SnapShape.circle => '圆',
    SnapShape.triangle => '三角形',
    SnapShape.rightTriangle => '直角三角形',
    SnapShape.isoscelesTriangle => '等腰三角形',
    SnapShape.parallelogram => '平行四边形',
  };
}

class ShapeSnap {
  const ShapeSnap({
    required this.shape,
    required this.points,
    required this.confidence,
    required this.bounds,
  });

  final SnapShape shape;

  /// 理想形状的采样点（页面 pt），直接用于生成一笔。
  final List<InkPoint> points;

  final double confidence;

  /// 理想形状的包围盒（用于预览标签定位）。
  final InkRect bounds;

  String get label => shape.label;
}

/// 识别一条手绘笔迹；返回 null = 不吸附（保持原笔迹）。
///
/// 参数都是页面坐标 pt。`minSize` 防止把"小勾/小点"吸成图形。
ShapeSnap? recognizeShape(
  List<InkPoint> raw, {
  double minSize = 28,
}) {
  if (raw.length < 6) {
    return null;
  }
  final List<InkPoint> points = _dedupe(raw);
  if (points.length < 6) {
    return null;
  }
  final double pathLength = _pathLength(points);
  if (pathLength < minSize) {
    return null;
  }
  final InkRect bounds = InkRect.fromPoints(points);
  final double diagonal = math.sqrt(
    bounds.width * bounds.width + bounds.height * bounds.height,
  );
  if (diagonal < minSize) {
    return null;
  }

  final double endGap = _dist(points.first, points.last);
  final bool looksClosed = endGap < math.max(diagonal * 0.28, pathLength * 0.12);

  // 1) 直线：端点分得开，且所有点离拟合直线都很近。
  if (!looksClosed) {
    final ShapeSnap? line = _fitLine(points, pathLength, diagonal);
    if (line != null && line.confidence >= 0.72) {
      return line;
    }
  }

  if (!looksClosed) {
    return null;
  }

  // 2) 椭圆 / 圆：先试，避免把圆简化成"三角形"。
  final ShapeSnap? ellipse = _fitEllipse(points, diagonal);
  if (ellipse != null && ellipse.confidence >= 0.74) {
    return ellipse;
  }

  // 3) 多边形：RDP 简化出角点。
  final List<InkPoint> simple = _rdp(points, math.max(2.0, diagonal * 0.045));
  final List<InkPoint> corners = _dropClosing(simple);
  if (corners.length == 3) {
    return _fitTriangle(corners, points, diagonal);
  }
  if (corners.length == 4) {
    return _fitQuad(corners, points, diagonal);
  }
  return null;
}

// ── 直线 ─────────────────────────────────────────────────────────────

ShapeSnap? _fitLine(
  List<InkPoint> points,
  double pathLength,
  double diagonal,
) {
  final InkPoint first = points.first;
  final InkPoint last = points.last;
  final double endDistance = _dist(first, last);
  if (endDistance < diagonal * 0.45 || pathLength / endDistance > 1.25) {
    return null;
  }
  // 主轴（PCA）→ 投影端点。
  final double mx = points.fold<double>(0, (double s, InkPoint p) => s + p.x) /
      points.length;
  final double my = points.fold<double>(0, (double s, InkPoint p) => s + p.y) /
      points.length;
  double sxx = 0;
  double sxy = 0;
  double syy = 0;
  for (final InkPoint p in points) {
    final double dx = p.x - mx;
    final double dy = p.y - my;
    sxx += dx * dx;
    sxy += dx * dy;
    syy += dy * dy;
  }
  final double theta = 0.5 * math.atan2(2 * sxy, sxx - syy);
  final double ux = math.cos(theta);
  final double uy = math.sin(theta);
  double minT = double.infinity;
  double maxT = -double.infinity;
  double residual = 0;
  for (final InkPoint p in points) {
    final double dx = p.x - mx;
    final double dy = p.y - my;
    final double t = dx * ux + dy * uy;
    minT = math.min(minT, t);
    maxT = math.max(maxT, t);
    residual += (dx * -uy + dy * ux).abs();
  }
  residual /= points.length;
  if (residual > math.max(2.2, diagonal * 0.035)) {
    return null;
  }
  final InkPoint a = InkPoint(
    x: mx + ux * minT,
    y: my + uy * minT,
    pressure: _avgPressure(points),
  );
  final InkPoint b = InkPoint(
    x: mx + ux * maxT,
    y: my + uy * maxT,
    pressure: _avgPressure(points),
  );
  final List<InkPoint> ideal = <InkPoint>[
    a,
    InkPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2, pressure: a.pressure),
    b,
  ];
  return ShapeSnap(
    shape: SnapShape.line,
    points: ideal,
    confidence: (1 - residual / math.max(2.2, diagonal * 0.035)).clamp(0, 1),
    bounds: InkRect.fromPoints(ideal),
  );
}

// ── 椭圆 ─────────────────────────────────────────────────────────────

ShapeSnap? _fitEllipse(List<InkPoint> points, double diagonal) {
  final double mx = points.fold<double>(0, (double s, InkPoint p) => s + p.x) /
      points.length;
  final double my = points.fold<double>(0, (double s, InkPoint p) => s + p.y) /
      points.length;
  double sxx = 0;
  double sxy = 0;
  double syy = 0;
  for (final InkPoint p in points) {
    final double dx = p.x - mx;
    final double dy = p.y - my;
    sxx += dx * dx;
    sxy += dx * dy;
    syy += dy * dy;
  }
  final double theta = 0.5 * math.atan2(2 * sxy, sxx - syy);
  final double ux = math.cos(theta);
  final double uy = math.sin(theta);
  final double vx = -uy;
  final double vy = ux;
  double maxU = 0;
  double maxV = 0;
  for (final InkPoint p in points) {
    final double dx = p.x - mx;
    final double dy = p.y - my;
    maxU = math.max(maxU, (dx * ux + dy * uy).abs());
    maxV = math.max(maxV, (dx * vx + dy * vy).abs());
  }
  if (maxU <= 0 || maxV <= 0) {
    return null;
  }
  final double a = maxU;
  final double b = maxV;
  final double ratio = math.min(a, b) / math.max(a, b);
  if (ratio < 0.22 || math.max(a, b) < diagonal * 0.24) {
    return null;
  }
  double error = 0;
  for (final InkPoint p in points) {
    final double dx = p.x - mx;
    final double dy = p.y - my;
    final double u = (dx * ux + dy * uy) / a;
    final double v = (dx * vx + dy * vy) / b;
    error += (math.sqrt(u * u + v * v) - 1).abs();
  }
  error /= points.length;
  if (error > 0.13) {
    return null;
  }
  final List<InkPoint> ideal = <InkPoint>[];
  const int samples = 64;
  for (int i = 0; i <= samples; i += 1) {
    final double t = i / samples * math.pi * 2;
    final double u = math.cos(t) * a;
    final double v = math.sin(t) * b;
    ideal.add(
      InkPoint(
        x: mx + ux * u + vx * v,
        y: my + uy * u + vy * v,
        pressure: _avgPressure(points),
        t: i * 4,
      ),
    );
  }
  final bool circle = (a - b).abs() / math.max(a, b) < 0.16;
  return ShapeSnap(
    shape: circle ? SnapShape.circle : SnapShape.ellipse,
    points: ideal,
    confidence: (1 - error / 0.13).clamp(0, 1),
    bounds: InkRect.fromPoints(ideal),
  );
}

// ── 三角形 ───────────────────────────────────────────────────────────

ShapeSnap? _fitTriangle(
  List<InkPoint> corners,
  List<InkPoint> raw,
  double diagonal,
) {
  final List<InkPoint> ideal = <InkPoint>[
    ...corners,
    InkPoint(
      x: corners.first.x,
      y: corners.first.y,
      pressure: corners.first.pressure,
    ),
  ];
  final double residual = _polygonResidual(raw, ideal);
  if (residual > math.max(3.0, diagonal * 0.05)) {
    return null;
  }
  final double a = _dist(corners[0], corners[1]);
  final double b = _dist(corners[1], corners[2]);
  final double c = _dist(corners[2], corners[0]);
  final double minSide = math.min(a, math.min(b, c));
  final double maxSide = math.max(a, math.max(b, c));
  if (minSide < diagonal * 0.12 || maxSide <= 0) {
    return null;
  }
  final bool right = _isRightAngle(corners[0], corners[1], corners[2]) ||
      _isRightAngle(corners[1], corners[2], corners[0]) ||
      _isRightAngle(corners[2], corners[0], corners[1]);
  final bool isosceles =
      _near(a, b) || _near(b, c) || _near(c, a);
  final SnapShape shape = right
      ? SnapShape.rightTriangle
      : isosceles
      ? SnapShape.isoscelesTriangle
      : SnapShape.triangle;
  return ShapeSnap(
    shape: shape,
    points: ideal,
    confidence: (1 - residual / math.max(3.0, diagonal * 0.05)).clamp(0, 1),
    bounds: InkRect.fromPoints(ideal),
  );
}

// ── 四边形 ───────────────────────────────────────────────────────────

ShapeSnap? _fitQuad(
  List<InkPoint> corners,
  List<InkPoint> raw,
  double diagonal,
) {
  // 先按平行四边形拟合：对边方向取平均。
  final _Vec u = _Vec(
    (corners[1].x - corners[0].x + corners[2].x - corners[3].x) / 2,
    (corners[1].y - corners[0].y + corners[2].y - corners[3].y) / 2,
  );
  final _Vec v = _Vec(
    (corners[3].x - corners[0].x + corners[2].x - corners[1].x) / 2,
    (corners[3].y - corners[0].y + corners[2].y - corners[1].y) / 2,
  );
  if (u.length < diagonal * 0.1 || v.length < diagonal * 0.1) {
    return null;
  }
  final double angle = _angleBetween(u, v);
  final bool rectangle = (angle - math.pi / 2).abs() < 0.22;
  if (!rectangle && (angle < 0.38 || angle > math.pi - 0.38)) {
    return null;
  }
  final List<InkPoint> ideal;
  if (rectangle) {
    // 用 PCA 轴做真正的矩形（正交），避免手绘四边不闭合留下斜边。
    final _RectFit fit = _fitRect(raw);
    if (fit.width < diagonal * 0.12 || fit.height < diagonal * 0.12) {
      return null;
    }
    ideal = <InkPoint>[
      InkPoint(x: fit.x(0, 0), y: fit.y(0, 0), pressure: _avgPressure(raw)),
      InkPoint(x: fit.x(1, 0), y: fit.y(1, 0), pressure: _avgPressure(raw)),
      InkPoint(x: fit.x(1, 1), y: fit.y(1, 1), pressure: _avgPressure(raw)),
      InkPoint(x: fit.x(0, 1), y: fit.y(0, 1), pressure: _avgPressure(raw)),
      InkPoint(x: fit.x(0, 0), y: fit.y(0, 0), pressure: _avgPressure(raw)),
    ];
    final double residual = _polygonResidual(raw, ideal);
    if (residual > math.max(3.0, diagonal * 0.05)) {
      return null;
    }
    final bool square = (fit.width - fit.height).abs() /
            math.max(fit.width, fit.height) <
        0.16;
    return ShapeSnap(
      shape: square ? SnapShape.square : SnapShape.rectangle,
      points: ideal,
      confidence: (1 - residual / math.max(3.0, diagonal * 0.05)).clamp(0, 1),
      bounds: InkRect.fromPoints(ideal),
    );
  }

  final InkPoint p0 = corners[0];
  final List<InkPoint> parallelogram = <InkPoint>[
    InkPoint(x: p0.x, y: p0.y, pressure: p0.pressure),
    InkPoint(x: p0.x + u.dx, y: p0.y + u.dy, pressure: p0.pressure),
    InkPoint(
      x: p0.x + u.dx + v.dx,
      y: p0.y + u.dy + v.dy,
      pressure: p0.pressure,
    ),
    InkPoint(x: p0.x + v.dx, y: p0.y + v.dy, pressure: p0.pressure),
    InkPoint(x: p0.x, y: p0.y, pressure: p0.pressure),
  ];
  final double residual = _polygonResidual(raw, parallelogram);
  if (residual > math.max(3.5, diagonal * 0.06)) {
    return null;
  }
  return ShapeSnap(
    shape: SnapShape.parallelogram,
    points: parallelogram,
    confidence: (1 - residual / math.max(3.5, diagonal * 0.06)).clamp(0, 1),
    bounds: InkRect.fromPoints(parallelogram),
  );
}

class _RectFit {
  const _RectFit({
    required this.cx,
    required this.cy,
    required this.ux,
    required this.uy,
    required this.vx,
    required this.vy,
    required this.width,
    required this.height,
  });

  final double cx;
  final double cy;
  final double ux;
  final double uy;
  final double vx;
  final double vy;
  final double width;
  final double height;

  double x(int i, int j) =>
      cx + ux * width * (i - 0.5) + vx * height * (j - 0.5);
  double y(int i, int j) =>
      cy + uy * width * (i - 0.5) + vy * height * (j - 0.5);
}

_RectFit _fitRect(List<InkPoint> points) {
  final double mx = points.fold<double>(0, (double s, InkPoint p) => s + p.x) /
      points.length;
  final double my = points.fold<double>(0, (double s, InkPoint p) => s + p.y) /
      points.length;

  // 最小面积外接矩形：逐度搜索方向。
  //
  // 为什么不能只用 PCA：正方形/近正方形的两条主轴是**对角线**，
  // 在 PCA 轴上取包围盒会得到旋转 45° 的更大正方形，原笔迹到它的残差很大，
  // 结果正方形反而识别不出来（2026-10-26 单测抓到）。
  _RectFit? best;
  double bestArea = double.infinity;
  for (int degree = 0; degree < 90; degree += 1) {
    final double theta = degree * math.pi / 180;
    final double ux = math.cos(theta);
    final double uy = math.sin(theta);
    final double vx = -uy;
    final double vy = ux;
    double minU = double.infinity;
    double maxU = -double.infinity;
    double minV = double.infinity;
    double maxV = -double.infinity;
    for (final InkPoint p in points) {
      final double dx = p.x - mx;
      final double dy = p.y - my;
      final double u = dx * ux + dy * uy;
      final double v = dx * vx + dy * vy;
      minU = math.min(minU, u);
      maxU = math.max(maxU, u);
      minV = math.min(minV, v);
      maxV = math.max(maxV, v);
    }
    final double width = maxU - minU;
    final double height = maxV - minV;
    final double area = width * height;
    if (area < bestArea) {
      bestArea = area;
      best = _RectFit(
        cx: mx + ux * (minU + maxU) / 2 + vx * (minV + maxV) / 2,
        cy: my + uy * (minU + maxU) / 2 + vy * (minV + maxV) / 2,
        ux: ux,
        uy: uy,
        vx: vx,
        vy: vy,
        width: width,
        height: height,
      );
    }
  }
  return best!;
}

// ── 几何工具 ─────────────────────────────────────────────────────────

List<InkPoint> _dedupe(List<InkPoint> raw) {
  final List<InkPoint> out = <InkPoint>[];
  for (final InkPoint p in raw) {
    if (out.isEmpty || _dist(out.last, p) > 0.35) {
      out.add(p);
    }
  }
  return out;
}

double _pathLength(List<InkPoint> points) {
  double sum = 0;
  for (int i = 1; i < points.length; i += 1) {
    sum += _dist(points[i - 1], points[i]);
  }
  return sum;
}

List<InkPoint> _rdp(List<InkPoint> points, double epsilon) {
  if (points.length < 3) {
    return points;
  }
  int index = -1;
  double maxDist = 0;
  final InkPoint a = points.first;
  final InkPoint b = points.last;
  for (int i = 1; i < points.length - 1; i += 1) {
    final double d = _pointSegmentDistance(points[i], a, b);
    if (d > maxDist) {
      maxDist = d;
      index = i;
    }
  }
  if (maxDist > epsilon && index > 0) {
    final List<InkPoint> left = _rdp(points.sublist(0, index + 1), epsilon);
    final List<InkPoint> right = _rdp(points.sublist(index), epsilon);
    return <InkPoint>[...left.sublist(0, left.length - 1), ...right];
  }
  return <InkPoint>[a, b];
}

List<InkPoint> _dropClosing(List<InkPoint> points) {
  if (points.length > 1 && _dist(points.first, points.last) < 0.6) {
    return points.sublist(0, points.length - 1);
  }
  return points;
}

double _polygonResidual(List<InkPoint> raw, List<InkPoint> polygon) {
  double sum = 0;
  for (final InkPoint p in raw) {
    double best = double.infinity;
    for (int i = 1; i < polygon.length; i += 1) {
      best = math.min(best, _pointSegmentDistance(p, polygon[i - 1], polygon[i]));
    }
    sum += best;
  }
  return sum / raw.length;
}

double _pointSegmentDistance(InkPoint p, InkPoint a, InkPoint b) {
  final double dx = b.x - a.x;
  final double dy = b.y - a.y;
  final double len2 = dx * dx + dy * dy;
  if (len2 <= 1e-9) {
    return _dist(p, a);
  }
  final double t =
      (((p.x - a.x) * dx + (p.y - a.y) * dy) / len2).clamp(0.0, 1.0);
  return math.sqrt(
    math.pow(p.x - (a.x + dx * t), 2) + math.pow(p.y - (a.y + dy * t), 2),
  );
}

double _dist(InkPoint a, InkPoint b) =>
    math.sqrt(math.pow(a.x - b.x, 2) + math.pow(a.y - b.y, 2));

double _avgPressure(List<InkPoint> points) =>
    points.fold<double>(0, (double s, InkPoint p) => s + p.pressure) /
    points.length;

bool _near(double a, double b) =>
    (a - b).abs() / math.max(a, b) < 0.12;

bool _isRightAngle(InkPoint a, InkPoint b, InkPoint c) {
  final _Vec ba = _Vec(a.x - b.x, a.y - b.y);
  final _Vec bc = _Vec(c.x - b.x, c.y - b.y);
  if (ba.length <= 0 || bc.length <= 0) {
    return false;
  }
  final double cos =
      (ba.dx * bc.dx + ba.dy * bc.dy) / (ba.length * bc.length);
  return cos.abs() < 0.16;
}

double _angleBetween(_Vec a, _Vec b) {
  final double cos =
      (a.dx * b.dx + a.dy * b.dy) / (a.length * b.length);
  return math.acos(cos.clamp(-1.0, 1.0));
}

class _Vec {
  const _Vec(this.dx, this.dy);

  final double dx;
  final double dy;

  double get length => math.sqrt(dx * dx + dy * dy);
}
