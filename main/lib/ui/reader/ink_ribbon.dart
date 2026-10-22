import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:shuaqi/domain/ink/ink_doc.dart';
import 'package:shuaqi/domain/ink/ink_width.dart';

/// 一条（或一批）笔画的**可变线宽几何**：把折线按量化宽度档拆成有限条 `ui.Path`。
///
/// ## 为什么有这个类（T2.2 返工的核心）
/// 用户报的两个症状其实是同一件事：
/// - **落笔粗细不对**：Android 的 DOWN 事件压力读数常常是 0（或直接 1.0），
///   一上来按 0 映射就是发丝，下一帧真实压力到了又跳到 3pt；
/// - **抬笔后粗细突变**：活笔逐段 `drawLine`（压感连续），死笔按"平均压感归 3 档"
///   重画（1.6 / 2.6 / 4.2），两者天生对不上 —— 一抬笔整笔换了个粗细。
///
/// 解法是让"正在写"和"写完"**走同一个几何构造器**：宽度量化到 [InkWidth.levels]
/// 档（钢笔 0.148pt 一档），每档一条 Path。活笔逐点 append（O(1)/点），
/// 死笔整笔重放（抬笔时一次，O(n)），两次结果逐像素相同，抬笔因此不可能跳变。
///
/// ## 为什么每档一条 Path 而不是每段一次 drawLine
/// 一页写满 ≈ 5000 笔 × 60 点 = 30 万段。每段一次 `drawLine` 是 30 万次绘制调用，
/// 整层重绘必卡；每档一条 Path 只有 24 次 `drawPath`，顶点数不变但调用数下来了。
///
/// ## 同档内为什么能连续
/// 相邻段的宽度差小于一档时落进同一条 Path，代码用 `moveTo` 只在**换档处**开口，
/// 同档内是连续折线：既不会有密集的子路径接缝，也不会在每段端头重复画圆帽。
class InkRibbon {
  InkRibbon({
    required this.style,
    required this.color,
    this.blendMode = BlendMode.srcOver,
  });

  final InkStrokeStyle style;

  /// 墨色。会随明暗主题变化，所以不是 final 构造参数（每次 draw 前同步）。
  Color color;

  /// 荧光笔必须乘算（下方文字可读，REQ-03）。
  final BlendMode blendMode;

  final List<ui.Path> _paths = List<ui.Path>.generate(
    InkWidth.levels,
    (_) => ui.Path(),
  );
  final Map<int, Paint> _paints = <int, Paint>{};

  int _strokeCount = 0;
  bool _hasGeometry = false;

  // ── 流式状态（只对"当前这一笔"有效）──────────────────────────────
  InkPoint? _prev;
  double _lastWidth = InkWidth.penMid;
  int _openLevel = -1;

  /// 已经 append 进来的笔画数。用于判断"抬笔后的笔迹是否已经落到死笔层"。
  int get strokeCount => _strokeCount;

  /// 有没有画得出来的东西（单点也算）。
  bool get hasGeometry => _hasGeometry;

  /// 开一笔。**活笔与死笔都从这里开始**，这是抬笔不跳变的技术保证。
  void beginStroke() {
    _prev = null;
    _lastWidth = InkWidth.penMid;
    _openLevel = -1;
  }

  /// 追加一个采样点。
  ///
  /// 落笔路径上只做：压力平滑（一次乘加）、档位换算（一次除法）、
  /// `lineTo`（一次 C++ 调用）。没有分配、没有 await、没有 IO（INV-01）。
  void addPoint(InkPoint point) {
    final InkPoint? prev = _prev;
    if (prev == null) {
      // 起笔：先按当前压力画一个圆点。笔尖落在纸上本来就会留一个点，
      // 顺带解决"起笔是针尖、一帧后突然变粗"的观感。
      final double width = InkWidth.forStroke(style, point.pressure);
      _lastWidth = width;
      _dot(point, width);
      _prev = point;
      return;
    }

    final double raw = InkWidth.forStroke(style, point.pressure);
    final double width =
        _lastWidth + (raw - _lastWidth) * InkWidth.pressureSmoothing;
    // 段宽取两端均值：既不会比起点粗、也不会比终点细。
    final int level = InkWidth.levelOf(style, (_lastWidth + width) / 2);
    final ui.Path path = _paths[level];
    if (level != _openLevel) {
      path.moveTo(prev.x, prev.y);
      _openLevel = level;
    }
    path.lineTo(point.x, point.y);
    _hasGeometry = true;
    _prev = point;
    _lastWidth = width;
  }

  /// 收笔：结束当前子路径，下一笔重新开口。
  void endStroke() {
    _strokeCount++;
    _prev = null;
    _openLevel = -1;
  }

  /// 整笔一次性 append（已提交笔迹走这条）。与流式逐点调用结果完全一致。
  void addStroke(InkStroke stroke) {
    beginStroke();
    for (final InkPoint point in stroke.points) {
      addPoint(point);
    }
    endStroke();
  }

  void _dot(InkPoint center, double width) {
    final int level = InkWidth.levelOf(style, width);
    _paths[level].addOval(
      ui.Rect.fromCircle(
        center: ui.Offset(center.x, center.y),
        radius: InkWidth.widthOfLevel(style, level) / 2,
      ),
    );
    _hasGeometry = true;
  }

  /// 各档 Path 的包围盒。诊断 / 单测用（比对"流式 vs 整笔"是否同一份几何），
  /// 运行时热路径不调它。
  List<ui.Rect> levelBounds() => _paths
      .map((ui.Path path) => path.getBounds())
      .toList(growable: false);

  void draw(ui.Canvas canvas) {
    if (!_hasGeometry) {
      return;
    }
    for (int level = 0; level < _paths.length; level++) {
      final ui.Path path = _paths[level];
      if (path.getBounds().isEmpty) {
        continue;
      }
      canvas.drawPath(path, _paintFor(level));
    }
  }

  Paint _paintFor(int level) {
    final Paint paint = _paints.putIfAbsent(
      level,
      () => Paint()
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..isAntiAlias = true
        ..blendMode = blendMode
        ..strokeWidth = InkWidth.widthOfLevel(style, level),
    );
    // 主题切换（浅色墨 / 夜读暖白墨）只改颜色，不重建 Path。
    if (paint.color != color) {
      paint.color = color;
    }
    return paint;
  }

  void clear() {
    for (final ui.Path path in _paths) {
      path.reset();
    }
    _strokeCount = 0;
    _hasGeometry = false;
    _prev = null;
    _openLevel = -1;
  }
}
