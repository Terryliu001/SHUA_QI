import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:shuaqi/domain/model/wb_page.dart';
import 'package:shuaqi/ui/reader/page_image_cache.dart';
import 'package:shuaqi/ui/reader/page_layer.dart';
import 'package:shuaqi/ui/theme/tokens.dart';

/// 连续滚动模式：**可缩放画布**（不是 ScrollView）。
///
/// ## 为什么要推倒重来
///
/// 前两版都在"ListView 里塞缩放"，无论用 `InteractiveViewer` 还是自己数指针，
/// 本质都是"改布局宽 → 重排 → 校正滚动偏移"。这条路有三个人为的天花板：
/// 1. 每帧重排 + `jumpTo` 校正 → 视觉比手指慢半拍（用户反馈的"不跟手"）；
/// 2. 缩放不能围绕双指焦点（布局是自上而下重算的，没有"焦点"概念）；
/// 3. 位图宽度随布局变 → 缓存被反复冲刷。
///
/// 成熟 PDF 阅读器的做法是**把滚动画布化**：
/// - 内容按 `baseWidth` 排一次版，位置固定不动；
/// - 屏幕位置 = 内容坐标 × `scale` + `offset`（一个 2D 仿射变换，纯 GPU）；
/// - 单指拖动改 `offset`，双指改 `scale` 并用同一个公式锁住焦点；
/// - 只渲染与视口相交的页（懒加载靠"可见区间计算"，不靠 Sliver）。
///
/// 因为不再有 `Scrollable`，手势竞技场里没有别的竞争者，
/// 可以直接用 `GestureDetector.onScale*`——单指平移与双指缩放天然统一。
///
/// ## 位图分辨率
/// `_qualityScale` 决定位图宽度，缩放过程中**冻结**，停手 250ms 才升级，
/// 避免每帧请求新尺寸位图（一次捏合 60 帧 ≈ 60 张 12–50MB）。期间靠 GPU 拉伸，视觉稳定。
class ScrollReaderView extends StatefulWidget {
  const ScrollReaderView({
    super.key,
    required this.pages,
    required this.cache,
    required this.initialPage,
    required this.onPageChanged,
    this.onZoomChanged,
  });

  final List<WbPage> pages;
  final PageImageCache cache;
  final int initialPage;
  final ValueChanged<int> onPageChanged;
  final ValueChanged<double>? onZoomChanged;

  @override
  State<ScrollReaderView> createState() => ScrollReaderViewState();
}

class ScrollReaderViewState extends State<ScrollReaderView>
    with SingleTickerProviderStateMixin {
  static const double _gap = 8;
  static const double _minScale = 1;
  static const double _maxScale = 4;

  /// 位图升级延迟：手指停下这么久之后才换高分辨率图
  static const Duration _qualityDelay = Duration(milliseconds: 250);

  late final Ticker _ticker;
  Timer? _qualityTimer;

  /// 内容坐标系下的页顶/页高（baseWidth 排版，一次算好不再变）
  List<double> _tops = const <double>[];
  List<double> _heights = const <double>[];
  double _contentW = 0;
  double _contentH = 0;
  Size _viewport = Size.zero;

  double _scale = 1;
  double _qualityScale = 1;

  /// 屏幕坐标 = 内容坐标 × _scale + _offset
  Offset _offset = Offset.zero;

  int _current = 0;
  bool _initialized = false;

  // 手势基准
  double _startScale = 1;
  Offset _focalContent = Offset.zero;

  // 惯性
  Offset _velocity = Offset.zero;
  Duration _lastTick = Duration.zero;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick);
  }

  @override
  void dispose() {
    _qualityTimer?.cancel();
    _ticker.dispose();
    super.dispose();
  }

  // ── 布局（只算一次）────────────────────────────────────────────────────

  void _layout(double baseWidth) {
    if (baseWidth == _contentW && _tops.isNotEmpty) {
      return;
    }
    _contentW = baseWidth;
    final List<double> tops = <double>[];
    final List<double> heights = <double>[];
    double y = 0;
    for (final WbPage page in widget.pages) {
      final double height = page.width <= 0
          ? baseWidth
          : baseWidth * page.height / page.width;
      tops.add(y);
      heights.add(height);
      y += height + _gap * 2;
    }
    _tops = tops;
    _heights = heights;
    _contentH = y;
  }

  Offset _clampOffset(Offset offset, double scale) {
    final double scaledW = _contentW * scale;
    final double scaledH = _contentH * scale;
    // 横向：内容比视口窄时居中（否则会紧贴左边，看起来像没排版）
    final double x = scaledW <= _viewport.width
        ? (_viewport.width - scaledW) / 2
        : offset.dx.clamp(_viewport.width - scaledW, 0);
    // 纵向：内容比视口矮时顶部对齐
    final double y = scaledH <= _viewport.height
        ? 0
        : offset.dy.clamp(_viewport.height - scaledH, 0);
    return Offset(x, y);
  }

  void _initPosition() {
    if (_initialized || _tops.isEmpty) {
      return;
    }
    _initialized = true;
    final int page = widget.initialPage.clamp(0, _tops.length - 1);
    _current = page;
    // 该页顶部对齐视口顶部
    _offset = _clampOffset(Offset(-_gap, -_tops[page] + _gap), _scale);
  }

  // ── 手势：单指平移 + 双指焦点缩放（同一个公式）─────────────────────────

  void _onScaleStart(ScaleStartDetails details) {
    _ticker.stop();
    _velocity = Offset.zero;
    _qualityTimer?.cancel();
    _startScale = _scale;
    // 焦点落在内容坐标系里的哪一点——缩放时这一点必须钉在屏幕上不动
    _focalContent = (details.localFocalPoint - _offset) / _scale;
  }

  void _onScaleUpdate(ScaleUpdateDetails details) {
    final double scale = (_startScale * details.scale).clamp(
      _minScale,
      _maxScale,
    );
    // 由"焦点内容点"反解 offset：focalScreen = focalContent * scale + offset
    final Offset offset = details.localFocalPoint - _focalContent * scale;
    setState(() {
      _scale = scale;
      _offset = _clampOffset(offset, scale);
      _updateCurrentPage();
    });
  }

  void _onScaleEnd(ScaleEndDetails details) {
    // 停手：延迟升级位图，并允许惯性
    _qualityTimer?.cancel();
    _qualityTimer = Timer(_qualityDelay, () {
      if (!mounted) {
        return;
      }
      setState(() {
        _qualityScale = _scale;
      });
    });
    widget.onZoomChanged?.call(_scale);

    final Offset velocity = details.velocity.pixelsPerSecond;
    if (velocity.distance > 60) {
      _velocity = velocity;
      _lastTick = Duration.zero;
      _ticker.start();
    }
  }

  void _onTick(Duration elapsed) {
    if (_lastTick == Duration.zero) {
      _lastTick = elapsed;
      return;
    }
    final double dt = (elapsed - _lastTick).inMicroseconds / 1e6;
    _lastTick = elapsed;
    if (dt <= 0) {
      return;
    }
    // 简单指数衰减：与平台惯性的手感接近，且实现只有几行
    final Offset next = _offset + _velocity * dt;
    _velocity *= math.pow(0.0025, dt).toDouble();
    final Offset clamped = _clampOffset(next, _scale);
    final bool hitEdge = clamped != next;
    setState(() {
      _offset = clamped;
      _updateCurrentPage();
    });
    if (_velocity.distance < 40 || hitEdge) {
      _velocity = Offset.zero;
      _ticker.stop();
    }
  }

  void _updateCurrentPage() {
    if (_tops.isEmpty) {
      return;
    }
    final double centerY =
        (-_offset.dy + _viewport.height / 2) / _scale;
    int page = 0;
    for (int i = 0; i < _tops.length; i++) {
      if (centerY >= _tops[i]) {
        page = i;
      } else {
        break;
      }
    }
    if (page != _current) {
      _current = page;
      widget.onPageChanged(page);
    }
  }

  /// 供 AppBar 的档位菜单调用：以视口中心为焦点缩放到指定倍率。
  void setScale(double value) {
    final double next = value.clamp(_minScale, _maxScale);
    final Offset center = Offset(_viewport.width / 2, _viewport.height / 2);
    final Offset focalContent = (center - _offset) / _scale;
    setState(() {
      _scale = next;
      _offset = _clampOffset(center - focalContent * next, next);
      // 菜单是离散操作，直接升级位图（不需要等 250ms）
      _qualityScale = next;
      _updateCurrentPage();
    });
    widget.onZoomChanged?.call(next);
  }

  /// 供缩略图抽屉跳页：该页顶部对齐视口顶部。
  void jumpTo(int index) {
    if (index < 0 || index >= _tops.length || !_initialized) {
      return;
    }
    setState(() {
      _current = index;
      _offset = _clampOffset(Offset(-_gap, -_tops[index] + _gap), _scale);
    });
    widget.onPageChanged(index);
  }

  @override
  Widget build(BuildContext context) {
    final double dpr = MediaQuery.devicePixelRatioOf(context);
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        _viewport = Size(constraints.maxWidth, constraints.maxHeight);
        final double baseWidth = math.min(
          constraints.maxWidth - ShqSpace.sm * 2,
          ShqLayout.maxReadingWidth,
        );
        _layout(baseWidth);
        _initPosition();

        // 可见区间（内容坐标）
        final double visibleTop = -_offset.dy / _scale;
        final double visibleBottom =
            visibleTop + constraints.maxHeight / _scale;

        final int qualityWidth =
            (_contentW * dpr * _qualityScale).round().clamp(1, 20000);

        final List<Widget> layers = <Widget>[];
        for (int i = 0; i < _tops.length; i++) {
          if (_tops[i] > visibleBottom) {
            break;
          }
          if (_tops[i] + _heights[i] < visibleTop) {
            continue;
          }
          layers.add(
            Positioned(
              left: _offset.dx,
              top: _tops[i] * _scale + _offset.dy,
              width: _contentW * _scale,
              height: _heights[i] * _scale,
              child: PageLayer(
                cache: widget.cache,
                page: widget.pages[i],
                width: _contentW * _scale,
                qualityWidth: qualityWidth,
              ),
            ),
          );
        }

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onScaleStart: _onScaleStart,
          onScaleUpdate: _onScaleUpdate,
          onScaleEnd: _onScaleEnd,
          child: ClipRect(
            child: Stack(clipBehavior: Clip.none, children: layers),
          ),
        );
      },
    );
  }
}
