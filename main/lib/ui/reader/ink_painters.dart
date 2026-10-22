import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:shuaqi/domain/ink/ink_doc.dart';
import 'package:shuaqi/domain/ink/ink_width.dart';
import 'package:shuaqi/ui/theme/tokens.dart';

/// 已提交笔迹的增量绘制缓存（挂在 InkLayer 的 State 上，跨 painter 实例存活）。
///
/// ## 为什么需要"档位 + 共享 Path"而不是每笔一条 Path
/// T0.2 spike 的教训：每帧把全部笔画重建成 Path 是 O(笔画×点数)，
/// 写到第 3 分钟必卡。正确做法是抬笔时只往对应档位的共享 Path
/// append 一条线（O(本笔点数)），整层只在"有新笔"时重绘一次，
/// 每次重绘只有 3+1 次 drawPath。
///
/// ## 代价（T2.2 的已知取舍）
/// 已提交笔画用档位固定线宽（轻/中/重三档），压感细节只在
/// "正在写的那一笔"（ActiveStrokePainter）上逐段体现。
/// 视觉上可接受：停下来看旧笔迹时，人眼对单笔内的粗细渐变并不敏感。
class CommittedInkCache {
  /// 三档线宽（pt）。与 InkWidth.penMin/Mid/Max 对齐。
  static const List<double> _bucketWidths = <double>[1.6, 2.6, 4.2];

  final List<ui.Path> _paths = <ui.Path>[
    ui.Path(),
    ui.Path(),
    ui.Path(),
  ];

  /// 荧光笔单独一条：乘算混合 + 半透明，不能和普通墨迹混在一个 Path。
  final ui.Path _highlighterPath = ui.Path();

  int _paintedStrokeCount = 0;

  /// 与新 [InkDoc] 同步：只 append 新增的笔画。
  ///
  /// 依赖 InkDoc 不可变且只追加（T2.3 橡皮会改语义，届时先 [clear]）。
  /// strokeCount 变少（清空/擦除）时整体重建。
  void sync(InkDoc doc) {
    if (doc.strokeCount < _paintedStrokeCount) {
      clear();
    }
    for (int i = _paintedStrokeCount; i < doc.strokes.length; i++) {
      _append(doc.strokes[i]);
    }
    _paintedStrokeCount = doc.strokeCount;
  }

  void _append(InkStroke stroke) {
    if (stroke.points.isEmpty) {
      return;
    }
    final bool highlighter = stroke.style == InkStrokeStyle.highlighter;
    final ui.Path path = highlighter ? _highlighterPath : _paths[_bucketOf(stroke)];
    final ui.Offset first = ui.Offset(
      stroke.points.first.x,
      stroke.points.first.y,
    );
    if (stroke.points.length == 1) {
      // 点一下是一个点：按该档位半径画圆，不是零长线段（看不见）
      final double radius =
          (highlighter ? InkWidth.highlighter : _bucketWidths[_bucketOf(stroke)]) /
          2;
      path.addOval(ui.Rect.fromCircle(center: first, radius: radius));
      return;
    }
    path.moveTo(first.dx, first.dy);
    for (int i = 1; i < stroke.points.length; i++) {
      final InkPoint p = stroke.points[i];
      path.lineTo(p.x, p.y);
    }
  }

  void draw(ui.Canvas canvas, {required Color inkColor, required Color highlighterColor}) {
    for (int i = 0; i < _paths.length; i++) {
      if (_paths[i].getBounds().isEmpty) {
        continue;
      }
      canvas.drawPath(
        _paths[i],
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round
          ..isAntiAlias = true
          ..color = inkColor
          ..strokeWidth = _bucketWidths[i],
      );
    }
    if (!_highlighterPath.getBounds().isEmpty) {
      canvas.drawPath(
        _highlighterPath,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round
          ..isAntiAlias = true
          ..color = highlighterColor
          ..strokeWidth = InkWidth.highlighter
          ..blendMode = BlendMode.multiply,
      );
    }
  }

  void clear() {
    for (final ui.Path path in _paths) {
      path.reset();
    }
    _highlighterPath.reset();
    _paintedStrokeCount = 0;
  }

  /// 一笔归到哪个档位：按平均压感（与 T0.2 spike 同口径）。
  /// 无压感输入（恒 0/1）归中档。
  static int _bucketOf(InkStroke stroke) {
    double sum = 0;
    int counted = 0;
    for (final InkPoint point in stroke.points) {
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

/// 已提交层。只在"有新笔提交"时重绘（widget 带着新 InkDoc 重建）。
///
/// 注意 [shouldRepaint] 必须比较 doc 身份：InkDoc 不可变，每次 commit
/// 都是新实例；缓存（[CommittedInkCache]）是跨 painter 存活的对象，
/// 不比较 doc 会把新 append 的笔画吞掉（painter 不重绘 → 看不见）。
class CommittedInkPainter extends CustomPainter {
  CommittedInkPainter({
    required this.cache,
    required this.doc,
    required this.scale,
    required this.inkColor,
    required this.highlighterColor,
  });

  final CommittedInkCache cache;
  final InkDoc doc;

  /// 内容坐标（pt）→ 本地逻辑像素的倍率：`displayWidth / pageWidthPt`。
  final double scale;
  final Color inkColor;
  final Color highlighterColor;

  @override
  void paint(Canvas canvas, Size size) {
    if (scale <= 0) {
      return;
    }
    canvas.save();
    canvas.scale(scale);
    cache.draw(canvas, inkColor: inkColor, highlighterColor: highlighterColor);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant CommittedInkPainter oldDelegate) {
    return oldDelegate.doc != doc ||
        oldDelegate.scale != scale ||
        oldDelegate.inkColor != inkColor ||
        oldDelegate.highlighterColor != highlighterColor;
  }
}

/// 正在写的这一笔。逐段变宽（压感细节只在这层体现），
/// 由 ValueNotifier 驱动——落笔每帧只通知这一层。
class ActiveStrokePainter extends CustomPainter {
  ActiveStrokePainter({
    required this.points,
    required this.style,
    required this.scale,
    required this.color,
    required Listenable repaint,
  }) : super(repaint: repaint);

  final List<InkPoint> points;
  final InkStrokeStyle style;
  final double scale;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (points.isEmpty || scale <= 0) {
      return;
    }
    canvas.save();
    canvas.scale(scale);

    if (points.length == 1) {
      final InkPoint only = points.first;
      canvas.drawCircle(
        Offset(only.x, only.y),
        InkWidth.forStroke(style, only.pressure) / 2,
        Paint()..color = color,
      );
      canvas.restore();
      return;
    }

    final Paint paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..isAntiAlias = true
      ..color = color;
    for (int i = 1; i < points.length; i++) {
      final InkPoint a = points[i - 1];
      final InkPoint b = points[i];
      paint.strokeWidth = InkWidth.forStroke(style, b.pressure);
      canvas.drawLine(Offset(a.x, a.y), Offset(b.x, b.y), paint);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant ActiveStrokePainter oldDelegate) {
    return oldDelegate.points != points ||
        oldDelegate.style != style ||
        oldDelegate.scale != scale ||
        oldDelegate.color != color;
  }
}

/// 墨色按明暗环境取（设计哲学：暗色墨色与夜读纸同源，都是暖白）。
Color inkColorOf(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark
    ? ShqNight.ink
    : ShqPalette.ink;
