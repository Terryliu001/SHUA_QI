import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:shuaqi/domain/ink/ink_doc.dart';
import 'package:shuaqi/domain/ink/ink_width.dart';
import 'package:shuaqi/ui/reader/ink_brush_spec.dart';

/// 一条（或一批）笔画的**可变线宽几何**：把折线按量化宽度档拆成有限条 `ui.Path`。
///
/// ## 为什么有这个类（T2.2 返工的核心）
/// 用户报的两个症状其实是同一件事：
/// - **落笔粗细不对**：Android 的 DOWN 事件压力读数常常是 0（或直接 1.0），
///   一上来按 0 映射就是发丝，下一帧真实压力到了又跳到 3pt；
/// - **抬笔后粗细突变**：活笔逐段 `drawLine`（压感连续），死笔按"平均压感归 3 档"
///   重画，两者天生对不上 —— 一抬笔整笔换了个粗细。
///
/// 解法是让"正在写"和"写完"**走同一个几何构造器**：宽度量化到 [InkWidth.levels]
/// 档（最宽档 0.18pt 一档），每档一条 Path。活笔逐点 append（O(1)/点），
/// 死笔整笔重放（抬笔时一次，O(n)），两次结果逐像素相同，抬笔因此不可能跳变。
///
/// ## 为什么参数只有一个 [InkBrushSpec]
/// 2026-10-23 修的"荧光笔落笔先画成黑色"就是**两层各拼一半参数**造成的：
/// 已提交层知道荧光笔要 multiply + 荧光色，活动层只传了 style 和墨色。
/// 现在颜色/混合/粗细全部来自同一个不可变 spec（[InkBrushSpec]），
/// 想不一致都没有机会。
///
/// ## 为什么每档一条 Path 而不是每段一次 drawLine
/// 一页写满 ≈ 5000 笔 × 60 点 = 30 万段。每段一次 `drawLine` 是 30 万次绘制调用，
/// 整层重绘必卡；每档一条 Path 只有 24 次 `drawPath`，顶点数不变但调用数下来了。
///
/// ## 同档内为什么能连续
/// 相邻段的宽度差小于一档时落进同一条 Path，代码用 `moveTo` 只在**换档处**开口，
/// 同档内是连续折线：既不会有密集的子路径接缝，也不会在每段端头重复画圆帽。
class InkRibbon {
  InkRibbon(this.spec);

  final InkBrushSpec spec;

  InkStrokeStyle get style => spec.style;

  /// 墨色由 spec 决定（含亮纸/暗纸的两套取色），这里不再单独可变。
  Color get color => spec.color;

  final List<ui.Path> _paths = List<ui.Path>.generate(
    InkWidth.levels,
    (_) => ui.Path(),
  );

  /// 哪些档位真的被写入过几何。
  ///
  /// **不能用 `path.getBounds().isEmpty` 判断**（2026-10-23 实测的坑）：
  /// 一条完美的水平/垂直线包围盒高度/宽度为 0，`Rect.isEmpty` 为 true，
  /// 于是整笔被跳过——用户看到的是"横着写不出墨、斜着才行"。
  /// 另外 `getBounds()` 是 O(点数)，每次重绘对 24 条 Path 各调一次，
  /// 写满一页时是纯粹的热路径浪费；一个 bool 就够。
  final List<bool> _levelUsed = List<bool>.filled(InkWidth.levels, false);

  final Map<int, Paint> _paints = <int, Paint>{};

  int _strokeCount = 0;
  bool _hasGeometry = false;

  // ── 流式状态（只对"当前这一笔"有效）──────────────────────────────
  InkPoint? _prev;
  double _lastWidth = 0;

  /// 本笔第一个采样点的原始宽度（未做 taperIn）。单点笔画画点时用它。
  double _firstWidth = 0;
  int _pointCount = 0;
  int _openLevel = -1;

  /// 已经 append 进来的笔画数。用于判断"抬笔后的笔迹是否已经落到死笔层"。
  int get strokeCount => _strokeCount;

  /// 有没有画得出来的东西（单点也算）。
  bool get hasGeometry => _hasGeometry;

  double get _midWidth =>
      InkWidth.forStroke(style, InkWidth.neutralPressure, spec.widthLevel);

  /// 开一笔。**活笔与死笔都从这里开始**，这是抬笔不跳变的技术保证。
  void beginStroke() {
    _prev = null;
    _lastWidth = _midWidth;
    _firstWidth = _midWidth;
    _pointCount = 0;
    _openLevel = -1;
  }

  /// 追加一个采样点。
  ///
  /// 落笔路径上只做：压力平滑（一次乘加）、档位换算（一次除法）、
  /// `lineTo`（一次 C++ 调用）。没有分配、没有 await、没有 IO（INV-01）。
  void addPoint(InkPoint point) {
    final InkPoint? prev = _prev;
    if (prev == null) {
      // 起笔：**不画点**。真机 DOWN 事件的压力读数系统性偏高，
      // 直接按它画圆点就是用户看到的"起笔圆斑"。这里从 55% 宽度起笔，
      // 让 EMA 在头 3 个采样点（≈13ms）内收敛到真实压力——
      // 肉眼是"笔尖入纸"的自然渐细，不是圆斑。
      final double raw = InkWidth.forStroke(
        style,
        point.pressure,
        spec.widthLevel,
      );
      _firstWidth = raw;
      _lastWidth = raw * InkWidth.taperIn;
      _prev = point;
      _pointCount = 1;
      return;
    }

    _pointCount++;
    final double raw = InkWidth.forStroke(
      style,
      point.pressure,
      spec.widthLevel,
    );
    final double width =
        _lastWidth + (raw - _lastWidth) * InkWidth.pressureSmoothing;
    // 段宽取两端均值：既不会比起点粗、也不会比终点细。
    final int level = InkWidth.levelOf(
      style,
      (_lastWidth + width) / 2,
      spec.widthLevel,
    );
    final ui.Path path = _paths[level];
    if (level != _openLevel) {
      path.moveTo(prev.x, prev.y);
      _openLevel = level;
    }
    path.lineTo(point.x, point.y);
    _levelUsed[level] = true;
    _hasGeometry = true;
    _prev = point;
    _lastWidth = width;
  }

  /// 收笔：结束当前子路径，下一笔重新开口。
  ///
  /// 整笔只有 1 个点（点一下）→ 按原始起笔宽度补一个圆点：
  /// 选择题打钩打点是合法输入，"点"必须是一个看得见的点而不是空笔。
  void endStroke() {
    final InkPoint? only = _prev;
    if (_pointCount == 1 && only != null) {
      _dot(only, _firstWidth);
    }
    _strokeCount++;
    _prev = null;
    _openLevel = -1;
    _pointCount = 0;
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
    final int level = InkWidth.levelOf(style, width, spec.widthLevel);
    _paths[level].addOval(
      ui.Rect.fromCircle(
        center: ui.Offset(center.x, center.y),
        radius: InkWidth.widthOfLevel(style, level, spec.widthLevel) / 2,
      ),
    );
    _levelUsed[level] = true;
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
      if (!_levelUsed[level]) {
        continue;
      }
      canvas.drawPath(_paths[level], _paintFor(level));
    }
  }

  Paint _paintFor(int level) {
    return _paints.putIfAbsent(
      level,
      () => Paint()
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..isAntiAlias = true
        // 颜色/混合都来自 spec。**别忘了 color**：Paint 默认是不透明纯黑，
        // 2026-10-23 重构时漏了这行，结果整层笔迹画成黑色（像素取样 (0,0,0) 抓到的）。
        ..color = spec.color
        ..blendMode = spec.blendMode
        ..strokeWidth = InkWidth.widthOfLevel(style, level, spec.widthLevel),
    );
  }

  /// 单测用：某一档是否真的被写入过几何（水平线包围盒为空，不能用 bounds 判断）。
  @visibleForTesting
  bool isLevelUsed(int level) => _levelUsed[level];

  /// 单测用：取某一档的 Paint，验证"颜色/混合/宽度真的落到了绘制参数上"。
  ///
  /// 存在的理由很具体：2026-10-23 重构时漏了 `paint.color`，Paint 默认不透明纯黑，
  /// 于是**所有颜色都画成黑**。这种 bug 从几何断言里看不出来，只能看 Paint 本身。
  @visibleForTesting
  Paint paintForLevel(int level) => _paintFor(level);

  void clear() {
    for (final ui.Path path in _paths) {
      path.reset();
    }
    for (int i = 0; i < _levelUsed.length; i++) {
      _levelUsed[i] = false;
    }
    _strokeCount = 0;
    _hasGeometry = false;
    _prev = null;
    _firstWidth = 0;
    _pointCount = 0;
    _openLevel = -1;
  }
}
