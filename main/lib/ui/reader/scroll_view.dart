import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:shuaqi/domain/model/wb_page.dart';
import 'package:shuaqi/domain/reader/reader_prefs.dart';
import 'package:shuaqi/ui/reader/page_image_cache.dart';
import 'package:shuaqi/ui/reader/page_layer.dart';
import 'package:shuaqi/ui/theme/tokens.dart';

/// 连续滚动模式（第四版）：**铺满视口的画布 + 单一变换矩阵**。
///
/// ## 第三版为什么会「显示不完整 + 放大后出现黑边框」
///
/// 第三版的链路是 `ClipRect → Transform → SizedBox(内容宽)`，问题在于
/// **`ClipRect` 与 `Transform` 的尺寸都只有"内容宽"**（`min(视口-16, 880)`），
/// 而外层 `Column` 又按 `crossAxisAlignment.center` 把它居中了一次：
///
/// ```text
/// 视口 1200 宽
/// ├─ 布局盒 880 宽（被 Column 居中 → 左边距 160）
/// │    ├─ 内容再按 (1200-880)/2 = 160 平移 → 纸面从 320 开始
/// │    └─ ClipRect 只认 880 宽 → 纸面在 1040 处被硬切掉
/// ```
///
/// 结果：100% 时右侧 160pt 的页面内容被裁掉（"显示不完整"）；
/// 放大后整个画面被锁在这个 880 宽的"窗口"里，窗口外露出底色（"黑边框"）。
/// 换句话说，**裁剪边界错成了内容边界，而内容坐标又被重复平移了一次**。
///
/// ## 第四版的三条硬规则
///
/// 1. **自身撑满视口**：`SizedBox(viewport)` 包住整条链，裁剪边界 = 视口边界；
/// 2. **1 倍 = fit-width**：内容宽 = 视口宽，任何倍率下都不会出现左右黑边；
/// 3. **缩放只改矩阵，不改布局**：页在 `_baseWidth` 下排一次版，坐标终身不变
///    （第三版这条是对的，保留 —— 它是"页与页不错位"的结构性保证）。
///
/// ```text
/// 屏幕坐标 = 内容坐标 × scale + offset
/// focalContent = (focalScreen - offset) / scale      // 手势开始
/// offset'      = focalScreen - focalContent * scale' // 每一步
/// ```
///
/// ## 清晰度与内存
/// 显示靠 GPU 拉伸已解码的位图；`_qualityScale` 在捏合过程中**冻结**，
/// 停手 [_qualityDelay] 后才按档位升级一次（见 [_qualityBuckets]）。
/// 这样一次捏合只会触发 0~1 次重渲染，而不是每帧一张新位图。
class ScrollReaderView extends StatefulWidget {
  const ScrollReaderView({
    super.key,
    required this.pages,
    required this.cache,
    required this.initialPage,
    required this.onPageChanged,
    this.onZoomChanged,
    this.style = PaperStyle.original,
    this.intensity = ReaderPrefs.defaultIntensity,
  });

  final List<WbPage> pages;
  final PageImageCache cache;
  final int initialPage;
  final ValueChanged<int> onPageChanged;
  final ValueChanged<double>? onZoomChanged;
  final PaperStyle style;
  final int intensity;

  @override
  State<ScrollReaderView> createState() => ScrollReaderViewState();
}

class ScrollReaderViewState extends State<ScrollReaderView>
    with SingleTickerProviderStateMixin {
  /// 页间距。规格 §6.9.1：连续滚动页间距 8dp。
  static const double _pageGap = ShqSpace.sm;

  static const double _minScale = 1;
  static const double _maxScale = 4;

  /// 单页位图像素宽上限。再往上就该走分块渲染（T1.5.1，未做）。
  static const int _maxBitmapWidthPx = 4096;

  /// 清晰度档位：捏合停手后取 `>= scale` 的最小档，避免每次微小变化都重渲染。
  /// 相邻档比值 ≤1.25，肉眼看不出差别。
  static const List<double> _qualityBuckets = <double>[
    1,
    1.25,
    1.5,
    2,
    2.5,
    3,
    3.5,
    4,
  ];

  static const Duration _qualityDelay = Duration(milliseconds: 220);

  late final Ticker _ticker;
  Timer? _qualityTimer;

  // ── 内容坐标系（只在视口尺寸变化时重算，缩放不动它）───────────────
  double _baseWidth = 0;
  List<double> _tops = const <double>[];
  List<double> _heights = const <double>[];
  double _contentH = 0;

  Size _viewport = Size.zero;
  double _dpr = 2;

  // ── 屏幕坐标系（唯一可变的两个量）────────────────────────────────
  double _scale = 1;
  double _qualityScale = 1;
  int _bitmapWidthPx = 0;
  Offset _offset = Offset.zero;

  int _current = 0;
  bool _anchored = false;
  String _prefetched = '';

  // ── 手势中间量 ───────────────────────────────────────────────────
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
  void didUpdateWidget(covariant ScrollReaderView oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 换了一卷（或页数变了）：布局与锚点全部作废
    if (!identical(oldWidget.pages, widget.pages)) {
      _tops = const <double>[];
      _heights = const <double>[];
      _baseWidth = 0;
      _contentH = 0;
      _anchored = false;
      _prefetched = '';
    }
  }

  @override
  void dispose() {
    _qualityTimer?.cancel();
    _ticker.dispose();
    super.dispose();
  }

  // ── 布局 ─────────────────────────────────────────────────────────

  /// 内容坐标系的唯一构造点。
  ///
  /// 重排时**保留页内阅读位置**：记下当前页 + 页内比例，重排后把同一个内容点
  /// 还原到原来的屏幕位置。旋转屏幕、换窗口尺寸都靠它（否则会跳页）。
  void _ensureLayout(Size viewport) {
    final double baseWidth = viewport.width;
    if (baseWidth == _baseWidth && _tops.isNotEmpty) {
      _viewport = viewport;
      return;
    }

    double ratio = 0;
    if (_anchored && _tops.isNotEmpty && _current < _heights.length) {
      final double pageTop = _tops[_current];
      final double pageH = _heights[_current];
      if (pageH > 0) {
        final double visibleTop = -_offset.dy / _scale;
        ratio = ((visibleTop - pageTop) / pageH).clamp(0.0, 1.0);
      }
    }

    _baseWidth = baseWidth;
    final List<double> tops = <double>[];
    final List<double> heights = <double>[];
    double y = 0;
    for (int i = 0; i < widget.pages.length; i++) {
      final WbPage page = widget.pages[i];
      final double height = page.width <= 0 || page.height <= 0
          ? baseWidth
          : baseWidth * page.height / page.width;
      tops.add(y);
      heights.add(height);
      y += height + (i == widget.pages.length - 1 ? 0 : _pageGap);
    }
    _tops = tops;
    _heights = heights;
    _contentH = y;
    _viewport = viewport;
    _recomputeBitmapWidth();

    if (_anchored && _tops.isNotEmpty) {
      final int index = _current.clamp(0, _tops.length - 1);
      _offset = _clampOffset(
        Offset(_offset.dx, -(_tops[index] + ratio * _heights[index]) * _scale),
        _scale,
      );
    }
  }

  /// 首次定位：让 `initialPage` 的页顶对齐视口顶。
  void _anchorOnce() {
    if (_anchored || _tops.isEmpty) {
      return;
    }
    _anchored = true;
    _current = widget.initialPage.clamp(0, _tops.length - 1);
    _offset = _clampOffset(Offset(0, -_tops[_current] * _scale), _scale);
  }

  /// 夹紧平移量。**1 倍 = fit-width**，所以横向永远正好铺满，不会露黑边。
  Offset _clampOffset(Offset offset, double scale) {
    final double w = _baseWidth * scale;
    final double h = _contentH * scale;
    final double x = w <= _viewport.width
        ? (_viewport.width - w) / 2
        : offset.dx.clamp(_viewport.width - w, 0);
    final double y = h <= _viewport.height
        ? 0
        : offset.dy.clamp(_viewport.height - h, 0);
    return Offset(x, y);
  }

  void _recomputeBitmapWidth() {
    final double bucket = _bucketOf(_qualityScale);
    _bitmapWidthPx = (_baseWidth * _dpr * bucket)
        .round()
        .clamp(1, _maxBitmapWidthPx);
  }

  static double _bucketOf(double scale) {
    for (final double bucket in _qualityBuckets) {
      if (scale <= bucket + 0.01) {
        return bucket;
      }
    }
    return _qualityBuckets.last;
  }

  // ── 手势 ─────────────────────────────────────────────────────────

  void _onScaleStart(ScaleStartDetails details) {
    _ticker.stop();
    _velocity = Offset.zero;
    _qualityTimer?.cancel();
    _startScale = _scale;
    // 焦点换算到内容坐标后，整段手势都让这个内容点钉在原来的屏幕位置
    _focalContent = (details.localFocalPoint - _offset) / _scale;
  }

  void _onScaleUpdate(ScaleUpdateDetails details) {
    final double scale = (_startScale * details.scale).clamp(
      _minScale,
      _maxScale,
    );
    final Offset offset = details.localFocalPoint - _focalContent * scale;
    setState(() {
      _scale = scale;
      _offset = _clampOffset(offset, scale);
    });
  }

  void _onScaleEnd(ScaleEndDetails details) {
    widget.onZoomChanged?.call(_scale);
    _scheduleQualityUpgrade();

    final Offset velocity = details.velocity.pixelsPerSecond;
    if (velocity.distance > 60) {
      _velocity = velocity;
      _lastTick = Duration.zero;
      _ticker.start();
    } else {
      _reportCurrentPage();
      _prefetchNeighbours();
    }
  }

  /// 停手 220ms 后升级位图清晰度（捏合过程中不升级，避免位图风暴）。
  void _scheduleQualityUpgrade() {
    _qualityTimer?.cancel();
    _qualityTimer = Timer(_qualityDelay, () {
      if (!mounted) {
        return;
      }
      final double bucket = _bucketOf(_scale);
      if (bucket == _qualityScale) {
        _prefetchNeighbours();
        return;
      }
      setState(() {
        _qualityScale = bucket;
        _recomputeBitmapWidth();
      });
      _prefetchNeighbours();
    });
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

  /// 主可见页 = 与视口**重叠高度最大**的那一页。
  ///
  /// 不用 `offset / pageHeight` 推：A4/A3 混排时会直接推错（规格 §6.9.2）。
  void _reportCurrentPage() {
    if (_tops.isEmpty || _viewport.isEmpty) {
      return;
    }
    final double visibleTop = -_offset.dy / _scale;
    final double visibleBottom = visibleTop + _viewport.height / _scale;
    int best = _current;
    double bestOverlap = -1;
    for (int i = 0; i < _tops.length; i++) {
      final double top = math.max(_tops[i], visibleTop);
      final double bottom = math.min(_tops[i] + _heights[i], visibleBottom);
      final double overlap = bottom - top;
      if (overlap > bestOverlap) {
        bestOverlap = overlap;
        best = i;
      }
    }
    if (best != _current) {
      _current = best;
      widget.onPageChanged(best);
    }
  }

  /// 预热当前页前后各一页的位图（**只加热缓存、不持有图片**）。
  void _prefetchNeighbours() {
    if (_bitmapWidthPx <= 0) {
      return;
    }
    final String token = '$_current/$_bitmapWidthPx';
    if (token == _prefetched) {
      return;
    }
    _prefetched = token;
    // 只预热下一页：上一页在往回滚时现渲染（12ms）也来得及，
    // 预热两页会让 200MB 缓存被两张 50MB 的整页位图挤爆。
    final int next = _current + 1;
    if (next < widget.pages.length) {
      widget.cache.prefetch(next, _bitmapWidthPx);
    }
  }

  // ── 对外接口（AppBar 档位 / 缩略图跳页）──────────────────────────

  double get zoom => _scale;

  /// 以视口中心为焦点缩放到 [value]（AppBar 档位菜单）。
  void setScale(double value) {
    final double next = value.clamp(_minScale, _maxScale);
    final Offset center = Offset(_viewport.width / 2, _viewport.height / 2);
    final Offset focalContent = (center - _offset) / _scale;
    _qualityTimer?.cancel();
    setState(() {
      _scale = next;
      _offset = _clampOffset(center - focalContent * next, next);
      _qualityScale = _bucketOf(next);
      _recomputeBitmapWidth();
    });
    _reportCurrentPage();
    _prefetchNeighbours();
    widget.onZoomChanged?.call(next);
  }

  /// 跳到第 [index] 页：页顶对齐视口顶。
  void jumpTo(int index) {
    if (index < 0 || index >= _tops.length || !_anchored) {
      return;
    }
    setState(() {
      _current = index;
      _offset = _clampOffset(Offset(_offset.dx, -_tops[index] * _scale), _scale);
    });
    _prefetched = '';
    _prefetchNeighbours();
    widget.onPageChanged(index);
  }

  // ── 渲染 ─────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    _dpr = MediaQuery.devicePixelRatioOf(context);
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final Size viewport = Size(constraints.maxWidth, constraints.maxHeight);
        _ensureLayout(viewport);
        _anchorOnce();

        final double visibleTop = -_offset.dy / _scale;
        final double visibleBottom = visibleTop + viewport.height / _scale;

        final List<Widget> pageWidgets = <Widget>[];
        for (int i = 0; i < _tops.length; i++) {
          if (_tops[i] >= visibleBottom) {
            break;
          }
          if (_tops[i] + _heights[i] <= visibleTop) {
            continue;
          }
          pageWidgets.add(
            Positioned(
              left: 0,
              top: _tops[i],
              width: _baseWidth,
              height: _heights[i],
              child: PageLayer(
                cache: widget.cache,
                page: widget.pages[i],
                width: _baseWidth,
                qualityWidth: _bitmapWidthPx,
                style: widget.style,
                intensity: widget.intensity,
              ),
            ),
          );
        }

        // 内容坐标固定；屏幕位置只由外层矩阵决定
        final Widget content = SizedBox(
          width: _baseWidth,
          height: _contentH,
          child: Stack(clipBehavior: Clip.none, children: pageWidgets),
        );

        // 关键：外层必须**撑满视口**。
        // 否则 LayoutBuilder 的尺寸会收缩到内容宽，ClipRect 就只裁这条窄带 ——
        // 那正是第三版"右侧被切掉 + 放大后黑边框"的根因。
        return SizedBox(
          width: viewport.width,
          height: viewport.height,
          child: GestureDetector(
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
          ),
        );
      },
    );
  }
}
