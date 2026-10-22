import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:shuaqi/domain/model/wb_page.dart';
import 'package:shuaqi/ui/reader/page_image_cache.dart';
import 'package:shuaqi/ui/reader/page_layer.dart';
import 'package:shuaqi/ui/theme/tokens.dart';

/// 连续滚动模式：**固定布局 + 单一变换矩阵**。
///
/// ## 为什么是第三版（前两版都有结构性问题）
///
/// 前两版都在 `onScaleUpdate` 里改"页宽/页位置"然后让 Flutter 重排：
/// - 第一版：改 ListView 的 item 宽度 → 每帧重排 + 每帧请求新尺寸位图（位图风暴）；
/// - 第二版：改 `Positioned` 的 `top/height` → 每帧重排，分数尺寸在**缩小**过程中误差累积，
///   页与页的边界会错开、互相叠压 —— 这就是"图层混乱"。
///
/// 这一版把两件事彻底分开：
/// - **布局（内容坐标系）永远不变**：页在 `baseWidth` 下排一次版，坐标固定；
/// - **视觉只由一个 `Matrix4` 决定**：`translate(offset) × scale`。
///
/// 因为缩放不参与布局，所以：页与页不可能错位；纯 GPU 变换，跟手；
/// `PageLayer` 宽度恒定，缩放过程中**不会**重新请求位图。
///
/// ## 焦点缩放
/// ```text
/// focalContent = (focalScreen - offset) / scale      // 手势开始
/// offset'      = focalScreen - focalContent * scale' // 每一步
/// ```
/// 该内容点恒钉在焦点屏幕上 → "在哪里放大就放大哪里"。
///
/// ## 位图清晰度
/// 显示是拉伸的，位图按 `baseWidth × dpr × qualityScale` 出图。
/// `qualityScale` 手势中**冻结**，停手 250ms 才升级一次。
/// 单页位图宽度上限 4096px（≈1.9 倍清晰度），更高倍率会略软；
/// 真正的高倍清晰要靠分块渲染（T1.5.1，未做）。
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
  static const int _maxBitmapWidth = 4096;
  static const Duration _qualityDelay = Duration(milliseconds: 250);

  late final Ticker _ticker;
  Timer? _qualityTimer;

  /// 内容坐标系（永不随缩放改变）
  double _baseWidth = 0;
  List<double> _tops = const <double>[];
  List<double> _heights = const <double>[];
  double _contentH = 0;
  Size _viewport = Size.zero;
  double _dpr = 2;

  /// 屏幕坐标 = 内容坐标 × _scale + _offset
  double _scale = 1;
  double _qualityScale = 1;
  Offset _offset = Offset.zero;
  int _bitmapWidth = 0;

  int _current = 0;
  bool _initialized = false;

  double _startScale = 1;
  Offset _focalContent = Offset.zero;

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

  // ── 布局：只在 baseWidth 变化时算一次 ──────────────────────────────────

  void _layout(double baseWidth) {
    if (baseWidth == _baseWidth && _tops.isNotEmpty) {
      return;
    }
    _baseWidth = baseWidth;
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
    _contentH = math.max(0, y - _gap * 2);
  }

  Offset _clampOffset(Offset offset, double scale) {
    final double scaledW = _baseWidth * scale;
    final double scaledH = _contentH * scale;
    final double x = scaledW <= _viewport.width
        ? (_viewport.width - scaledW) / 2
        : offset.dx.clamp(_viewport.width - scaledW, 0);
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
    _current = widget.initialPage.clamp(0, _tops.length - 1);
    _offset = _clampOffset(Offset(0, -_tops[_current] * _scale), _scale);
  }

  void _recomputeBitmapWidth() {
    _bitmapWidth = (_baseWidth * _dpr * _qualityScale)
        .round()
        .clamp(1, _maxBitmapWidth);
  }

  // ── 手势 ────────────────────────────────────────────────────────────────

  void _onScaleStart(ScaleStartDetails details) {
    _ticker.stop();
    _velocity = Offset.zero;
    _qualityTimer?.cancel();
    _startScale = _scale;
    _focalContent = (details.localFocalPoint - _offset) / _scale;
  }

  void _onScaleUpdate(ScaleUpdateDetails details) {
    final double scale = (_startScale * details.scale).clamp(
      _minScale,
      _maxScale,
    );
    final Offset offset = details.localFocalPoint - _focalContent * scale;
    // 只改矩阵参数，布局一个字节都不动 —— 不会有页错位
    setState(() {
      _scale = scale;
      _offset = _clampOffset(offset, scale);
    });
  }

  void _onScaleEnd(ScaleEndDetails details) {
    _qualityTimer?.cancel();
    _qualityTimer = Timer(_qualityDelay, () {
      if (!mounted) {
        return;
      }
      setState(() {
        _qualityScale = _scale;
        _recomputeBitmapWidth();
      });
    });
    widget.onZoomChanged?.call(_scale);

    final Offset velocity = details.velocity.pixelsPerSecond;
    if (velocity.distance > 60) {
      _velocity = velocity;
      _lastTick = Duration.zero;
      _ticker.start();
    } else {
      _reportCurrentPage();
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
    final Offset next = _offset + _velocity * dt;
    _velocity = _velocity * math.pow(0.0025, dt).toDouble();
    final Offset clamped = _clampOffset(next, _scale);
    final bool hitEdge =
        (clamped.dx - next.dx).abs() > 0.5 || (clamped.dy - next.dy).abs() > 0.5;
    setState(() {
      _offset = clamped;
    });
    if (_velocity.distance < 40 || hitEdge) {
      _velocity = Offset.zero;
      _ticker.stop();
      _reportCurrentPage();
    }
  }

  void _reportCurrentPage() {
    if (_tops.isEmpty || _viewport.isEmpty) {
      return;
    }
    final double centerY = (-_offset.dy + _viewport.height / 2) / _scale;
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

  /// 供 AppBar 档位菜单：以视口中心为焦点缩放。
  void setScale(double value) {
    final double next = value.clamp(_minScale, _maxScale);
    final Offset center = Offset(_viewport.width / 2, _viewport.height / 2);
    final Offset focalContent = (center - _offset) / _scale;
    setState(() {
      _scale = next;
      _offset = _clampOffset(center - focalContent * next, next);
      _qualityScale = next;
      _recomputeBitmapWidth();
    });
    _reportCurrentPage();
    widget.onZoomChanged?.call(next);
  }

  /// 供缩略图抽屉跳页：该页顶部对齐视口顶部。
  void jumpTo(int index) {
    if (index < 0 || index >= _tops.length || !_initialized) {
      return;
    }
    setState(() {
      _current = index;
      _offset = _clampOffset(Offset(0, -_tops[index] * _scale), _scale);
    });
    widget.onPageChanged(index);
  }

  @override
  Widget build(BuildContext context) {
    _dpr = MediaQuery.devicePixelRatioOf(context);
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        _viewport = Size(constraints.maxWidth, constraints.maxHeight);
        final double baseWidth = math.min(
          constraints.maxWidth - ShqSpace.sm * 2,
          ShqLayout.maxReadingWidth,
        );
        _layout(baseWidth);
        _initPosition();
        if (_bitmapWidth <= 0) {
          _recomputeBitmapWidth();
        }

        // 可见区间（内容坐标）
        final double visibleTop = -_offset.dy / _scale;
        final double visibleBottom =
            visibleTop + constraints.maxHeight / _scale;

        final List<Widget> pageWidgets = <Widget>[];
        for (int i = 0; i < _tops.length; i++) {
          if (_tops[i] > visibleBottom) {
            break;
          }
          if (_tops[i] + _heights[i] < visibleTop) {
            continue;
          }
          pageWidgets.add(
            Positioned(
              left: 0,
              top: _tops[i],
              width: baseWidth,
              height: _heights[i],
              child: PageLayer(
                cache: widget.cache,
                page: widget.pages[i],
                width: baseWidth,
                qualityWidth: _bitmapWidth,
              ),
            ),
          );
        }

        // 内容坐标固定；屏幕位置完全由外层矩阵决定
        final Widget content = SizedBox(
          width: baseWidth,
          height: _contentH,
          child: Stack(clipBehavior: Clip.none, children: pageWidgets),
        );

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onScaleStart: _onScaleStart,
          onScaleUpdate: _onScaleUpdate,
          onScaleEnd: _onScaleEnd,
          child: ClipRect(
            child: Transform(
              alignment: Alignment.topLeft,
              transform: Matrix4.identity()
                ..translateByDouble(_offset.dx, _offset.dy, 0, 1)
                ..scaleByDouble(_scale, _scale, 1, 1),
              child: content,
            ),
          ),
        );
      },
    );
  }
}
