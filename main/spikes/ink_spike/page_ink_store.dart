import 'dart:ui';

import 'stroke_model.dart';

/// 一页的**已提交**笔迹缓存：按压力分 3 档，各维护一条 `Path`。
///
/// 为什么这么做：
/// - 若每帧把全部笔画重建成 Path，成本是 O(笔画×点数)，写到第 3 分钟必卡——这正是 T0.2 要避免的假数据。
/// - Path 是可变的，抬笔时只往对应档位 append 一条线，成本 O(本笔点数)；
///   之后这一层只在"有新笔提交"时重绘一次。
/// - 代价：已提交的笔画用档位固定线宽，压感细节只在"正在写的那一笔"上体现。
///   spike 阶段这个取舍够用；产品化再做按段变宽（T2.2）。
class PageInkStore {
  static const List<double> _bucketWidths = <double>[1.6, 2.6, 4.2];

  static final List<Paint> _paints = <Paint>[
    for (final double width in _bucketWidths)
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..isAntiAlias = true
        ..color = const Color(0xFF1A1A1A)
        ..strokeWidth = width,
  ];

  final List<Path> _paths = <Path>[Path(), Path(), Path()];

  int revision = 0;
  int strokeCount = 0;
  int pointCount = 0;

  /// 估算内存（字节）。40B/点 = 3 个 double + 1 个 int + 对象与 List 开销的粗估。
  /// 这是**估算**，T0.2 的真实内存要看 DevTools 的 Memory 面板。
  int get estimatedBytes => pointCount * 40;

  void appendStroke(SpikeStroke stroke) {
    final List<SpikePoint> points = stroke.points;
    if (points.isEmpty) {
      return;
    }
    final int bucket = _bucketOf(stroke);
    final Path path = _paths[bucket];
    final SpikePoint first = points.first;
    if (points.length == 1) {
      final double radius = _bucketWidths[bucket] / 2;
      path.addOval(
        Rect.fromCircle(center: Offset(first.x, first.y), radius: radius),
      );
    } else {
      path.moveTo(first.x, first.y);
      for (int i = 1; i < points.length; i++) {
        path.lineTo(points[i].x, points[i].y);
      }
    }
    revision++;
    strokeCount++;
    pointCount += points.length;
  }

  void draw(Canvas canvas) {
    for (int i = 0; i < _paths.length; i++) {
      if (_paths[i].getBounds().isEmpty) {
        continue;
      }
      canvas.drawPath(_paths[i], _paints[i]);
    }
  }

  void clear() {
    for (final Path path in _paths) {
      path.reset();
    }
    revision++;
    strokeCount = 0;
    pointCount = 0;
  }

  static int _bucketOf(SpikeStroke stroke) {
    double sum = 0;
    int counted = 0;
    for (final SpikePoint point in stroke.points) {
      // 鼠标/触摸的 pressure 恒为 1.0，会把整页都画成粗线；这里直接按"无压感"处理。
      if (point.pressure > 0 && point.pressure < 0.999) {
        sum += point.pressure;
        counted++;
      }
    }
    if (counted == 0) {
      return 1;
    }
    final double avg = sum / counted;
    if (avg < 0.34) {
      return 0;
    }
    if (avg < 0.67) {
      return 1;
    }
    return 2;
  }
}
