import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart'
    show PointerDeviceKind, PointerEvent;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:shuaqi/domain/ink/ink_doc.dart';
import 'package:shuaqi/domain/model/wb_page.dart';
import 'package:shuaqi/domain/reader/reader_prefs.dart';
import 'package:shuaqi/domain/reader/scroll_math.dart';
import 'package:shuaqi/ui/reader/page_image_cache.dart';
import 'package:shuaqi/ui/reader/page_layer.dart';
import 'package:shuaqi/ui/theme/tokens.dart';

/// 连续滚动模式（第五版）：**铺满视口的画布 + 单一变换矩阵 + 矩阵与布局分层**。
///
/// [演进只记结论，细节在项目日志 013–015、017]
/// - 第三版：裁剪边界错成内容边界 → 显示不完整 + 放大黑边框（015 修复）。
/// - 第四版：三条硬规则——自身撑满视口 / 1 倍 = fit-width / 缩放只改矩阵不改布局。
///
/// ## 第五版：丝滑三改（用户报"滑动不丝滑"）
///
/// 根因（项目日志 017）：
///
/// 1. **每帧全树重建**：`onScaleUpdate` 与甩动 ticker 每帧 `setState`，
///    整个 `LayoutBuilder` 以下全部重建（Positioned × N / PageLayer × N /
///    PaperEffect 链）。平板 120Hz 的帧预算只有 8.3ms，这部分占 6–18%。
/// 2. **滚动期间零预热**：`_reportCurrentPage / _prefetchNeighbours` 只在停手后跑，
///    拖动 / 甩动时新进入视口的页现渲染。dpr 2.5 下 fit-width 位图
///    3000×4243 ≈ 51MB，200MB 缓存只装 3–4 页，不进缓存就现渲 + 现上传。
/// 3. **甩动太短**：衰减常数 0.0025（时间常数 ≈166ms），甩一下就走一点点，
///    手感发涩。
///
/// 对应三改：
///
/// 1. **相机矩阵独立成层**：`ValueNotifier<_Camera>` + `ValueListenableBuilder`
///    只包住 `Transform`；每帧只更新矩阵（renderObject 标记重绘，element 树不动，
///    引擎复用子图层只改变换）。页面列表（Positioned × N）是静态 child，
///    **只在可见集变化时**才重建。
/// 2. **滚动中按方向预热**：每帧算可见集与主可见页，向"正在去的方向"预热
///    下一页（51MB/页，只预热 1 页；停手 220ms 清晰度升级后按新宽度补一次）。
/// 3. **fling 调到 ~470ms 时间常数**（0.12），触发 60px/s、停止 50px/s、撞边即停。
///
/// 另外：`PageLayer` 加 `ValueKey(page.index)`——可见集平移时"离开的 dispose、
/// 进入的新建"，不会出现两个 PageLayer 同时换页重载的闪烁（无 key 时
/// 按索引配对就会）。
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
    this.sessionId,
    this.inkStyle = InkStrokeStyle.pen,
  });

  final List<WbPage> pages;
  final PageImageCache cache;
  final int initialPage;
  final ValueChanged<int> onPageChanged;
  final ValueChanged<double>? onZoomChanged;
  final PaperStyle style;
  final int intensity;

  /// 当前 draft 会话 id。null = 不挂墨迹层（纯阅读，比如以后的历史提交回看）。
  final String? sessionId;

  /// 当前笔刷（工具栏选中项）。
  final InkStrokeStyle inkStyle;

  @override
  State<ScrollReaderView> createState() => ScrollReaderViewState();
}

/// 相机状态。`ValueNotifier` 按引用比较，所以通知前手工判等（见 [_publishCamera]）。
class _Camera {
  const _Camera(this.offset, this.scale);

  final Offset offset;
  final double scale;
}

class ScrollReaderViewState extends State<ScrollReaderView>
    with SingleTickerProviderStateMixin {
  /// 页间距。规格 §6.9.1：连续滚动页间距 8dp。
  static const double _pageGap = ShqSpace.sm;

  static const double _minScale = 1;
  static const double _maxScale = 4;

  /// 单页位图像素宽上限。再往上就该走分块渲染（T1.5.1，未做）。
  ///
  /// 3200 而不是 4096（2026-10-22 调整）：A4 在 3200 宽时一页位图 ≈ 52MB，
  /// 视口 ±1 三页同屏 ≈ 156MB，留在 200MB 缓存与 650MB 峰值预算内。
  /// 4096 时一页 95MB，三页 285MB —— 一捏合就触发淘汰与 GC，
  /// 表现正是"多次双指放缩后滑动卡顿、页面发糊/空白"。
  /// 代价：200% 以上放大的清晰度从 1:1 降到 0.75:1（真无损要等分块渲染）。
  static const int _maxBitmapWidthPx = 3200;

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

  /// 甩动衰减：`v(t) = v0 × k^t`，k=0.12 → 时间常数 ≈470ms，接近原生滚动手感。
  static const double _flingFriction = 0.12;

  /// 触发甩动的最小速度（px/s）。
  static const double _flingMinVelocity = 60;

  /// 低于它认为已经停了（px/s）。
  static const double _flingStopVelocity = 50;

  late final Ticker _ticker;
  Timer? _qualityTimer;

  /// 矩阵层唯一数据源。手势 / ticker 每帧只改它，不 setState。
  final ValueNotifier<_Camera> _cam = ValueNotifier<_Camera>(
    const _Camera(Offset.zero, 1),
  );

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

  // ── 可见集（只在变化时重建页面列表）────────────────────────────
  int _firstVisible = 0;
  int _lastVisible = -1;

  /// 重排（转屏 / 换窗口）后需要在 build 末尾补一次页码上报。
  bool _pendingReport = false;

  // ── 手势中间量 ───────────────────────────────────────────────────
  double _startScale = 1;
  Offset _focalContent = Offset.zero;
  Offset _velocity = Offset.zero;
  Duration _lastTick = Duration.zero;

  /// 上一帧的 offset.dy，用来推断"正在去的方向"（预热用）。
  double _lastPanDy = 0;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick);
  }

  @override
  void dispose() {
    _qualityTimer?.cancel();
    _ticker.dispose();
    _cam.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant ScrollReaderView oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 换了一卷（或页数变了）：布局、锚点、相机全部作废
    if (!identical(oldWidget.pages, widget.pages)) {
      _tops = const <double>[];
      _heights = const <double>[];
      _baseWidth = 0;
      _contentH = 0;
      _anchored = false;
      _prefetched = '';
      _current = 0;
      _scale = 1;
      _qualityScale = 1;
      _offset = Offset.zero;
      _cam.value = const _Camera(Offset.zero, 1);
    }
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
      // 重排后主可见页可能变（竖横屏互转时每页高度全变）：
      // 让 build 末尾补一次上报，页码条与库里的进度才不会停在上一个方向。
      _pendingReport = true;
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
    final (double x, double y) = ScrollMath.clampOffset(
      offsetX: offset.dx,
      offsetY: offset.dy,
      scale: scale,
      contentWidth: _baseWidth,
      contentHeight: _contentH,
      viewportWidth: _viewport.width,
      viewportHeight: _viewport.height,
    );
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

  // ── 矩阵层 ───────────────────────────────────────────────────────

  /// 把当前 offset/scale 发给矩阵层。值没变就跳过（否则无谓重建 Transform）。
  ///
  /// **位移对齐到物理像素**：1 倍时位图是 1:1 贴到屏幕上的（fit-width 宽正好是
  /// 屏宽的 device px），偏移落在半个像素上就会触发一次双线性重采样 ——
  /// 既糊又慢，滑动时还能看到细小抖动。取整到设备像素后，静止画面像素级对齐，
  /// 滑动则是"每 0.4dp 一格的连续位移"，在 400dpi 屏上完全看不出台阶。
  void _publishCamera() {
    final double dpr = _dpr;
    final Offset offset = dpr > 0
        ? Offset(
            (_offset.dx * dpr).roundToDouble() / dpr,
            (_offset.dy * dpr).roundToDouble() / dpr,
          )
        : _offset;
    if (offset == _cam.value.offset && _scale == _cam.value.scale) {
      return;
    }
    _cam.value = _Camera(offset, _scale);
  }

  // ── 手势 ─────────────────────────────────────────────────────────

  // ── 笔优先（规格 T2.1：stylus 出现后 800ms 内忽略单指 touch）────────
  //
  // 为什么必须有：写字时手掌/手指搭在屏上是常态，touch 事件会照常进
  // 缩放手势——表现是"一落笔页面就跟着跑"。100% 时横向被夹紧看不出来，
  // 放大后横向有余量，现象最明显（用户报的"放大后无法书写"）。
  // 实现：用时间戳门槛，**不 setState、不重建**——被挡住的手势直接在
  // 回调里 return，页面不动，墨迹层照常写。双指（pointerCount ≥ 2）
  // 不受影响：捏合缩放是手指的合法操作（§6.9.1）。
  static const int _penGraceMs = 800;
  int _lastPenSeenMs = -1000000;
  bool _gestureBlocked = false;

  void _observePointer(PointerEvent event) {
    if (event.kind == PointerDeviceKind.stylus ||
        event.kind == PointerDeviceKind.invertedStylus) {
      _lastPenSeenMs = DateTime.now().millisecondsSinceEpoch;
    }
  }

  bool _penRecentlyActive(int pointerCount) =>
      pointerCount < 2 &&
      DateTime.now().millisecondsSinceEpoch - _lastPenSeenMs < _penGraceMs;

  void _onScaleStart(ScaleStartDetails details) {
    _gestureBlocked = _penRecentlyActive(details.pointerCount);
    if (_gestureBlocked) {
      return;
    }
    _ticker.stop();
    _velocity = Offset.zero;
    _qualityTimer?.cancel();
    _startScale = _scale;
    // 焦点换算到内容坐标后，整段手势都让这个内容点钉在原来的屏幕位置
    _focalContent = (details.localFocalPoint - _offset) / _scale;
  }

  void _onScaleUpdate(ScaleUpdateDetails details) {
    // 手势中途笔落下来（手掌先搭住、后动笔）：立刻冻结本次手势。
    if (_gestureBlocked || _penRecentlyActive(details.pointerCount)) {
      return;
    }
    final double scale = (_startScale * details.scale).clamp(
      _minScale,
      _maxScale,
    );
    final Offset offset = details.localFocalPoint - _focalContent * scale;
    _scale = scale;
    _offset = _clampOffset(offset, scale);
    // 丝滑关键：**不 setState**。矩阵层自己重建 Transform（一个 renderObject），
    // 页面列表纹丝不动。
    _publishCamera();
    _trackVisible();
  }

  void _onScaleEnd(ScaleEndDetails details) {
    final bool blocked = _gestureBlocked;
    _gestureBlocked = false;
    if (blocked) {
      // 被笔优先挡掉的手势：不甩动、不清晰度升级也不触发（没有位移发生）。
      return;
    }
    widget.onZoomChanged?.call(_scale);
    _scheduleQualityUpgrade();

    final Offset velocity = details.velocity.pixelsPerSecond;
    if (velocity.distance > _flingMinVelocity) {
      _velocity = velocity;
      _lastTick = Duration.zero;
      _ticker.start();
    } else {
      _velocity = Offset.zero;
    }
    _trackVisible();
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
        _maybePrefetch();
        return;
      }
      setState(() {
        _qualityScale = bucket;
        _recomputeBitmapWidth();
      });
      // 位图宽度变了，按新宽度把方向的下一夜烘一遍
      _maybePrefetch();
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
    _velocity = _velocity * math.pow(_flingFriction, dt).toDouble();
    final Offset clamped = _clampOffset(next, _scale);
    final bool hitEdge =
        (clamped.dx - next.dx).abs() > 0.5 || (clamped.dy - next.dy).abs() > 0.5;
    _offset = clamped;
    _publishCamera();
    _trackVisible();
    if (_velocity.distance < _flingStopVelocity || hitEdge) {
      _velocity = Offset.zero;
      _ticker.stop();
    }
  }

  // ── 每帧的可见性跟踪（纯计算 + 最多一次 setState）─────────────────

  /// 手势 / 甩动 / 停手时每帧调用：
  /// 1. 可见集变了才重建页面列表（`setState`）；
  /// 2. 主可见页变了才上报父级（页码条 + 进度防抖）；
  /// 3. 按方向预热下一页。
  void _trackVisible() {
    final (int first, int last) = _visibleRangeNow();
    if (first != _firstVisible || last != _lastVisible) {
      _firstVisible = first;
      _lastVisible = last;
      setState(() {}); // 只重建页面列表；矩阵层不受影响
    }
    _updateCurrentPage();
    _maybePrefetch();
    _lastPanDy = _offset.dy;
  }

  (int, int) _visibleRangeNow() {
    final double visibleTop = -_offset.dy / _scale;
    final double visibleBottom = visibleTop + _viewport.height / _scale;
    return ScrollMath.visibleRange(_tops, _heights, visibleTop, visibleBottom) ??
        (0, -1);
  }

  /// 主可见页 = 与视口**重叠高度最大**的那一页（规格 §6.9.2，A4/A3 混排安全）。
  void _updateCurrentPage() {
    if (_tops.isEmpty || _viewport.isEmpty) {
      return;
    }
    final double visibleTop = -_offset.dy / _scale;
    final double visibleBottom = visibleTop + _viewport.height / _scale;
    final int best = ScrollMath.mainVisiblePage(
      _tops,
      _heights,
      visibleTop,
      visibleBottom,
    );
    if (best != _current) {
      _current = best;
      widget.onPageChanged(best);
    }
  }

  /// 滚动中预热：向"正在去的方向"预热**即将进入视口的那一页**。
  ///
  /// 为什么是 `_lastVisible + dir` 而不是 `_current + dir`：100% 时视口里常驻两页，
  /// `_current + 1` 往往已经在屏上（不需要预热），真正需要的是可见集之外的那一页。
  ///
  /// 为什么只预热 1 页：一页 A4 在 3200px 宽下 ≈ 52MB，200MB 缓存装 3–4 页；
  /// 当前页 + 显示中的邻居 + 1 页预热，留得出余量。反向页现渲染只要 ~12ms
  /// （pdfium 不走 UI 线程），来得及。
  void _maybePrefetch() {
    if (_bitmapWidthPx <= 0 || _tops.isEmpty || _lastVisible < 0) {
      return;
    }
    final int dir = _prefetchDir();
    final int next = dir > 0 ? _lastVisible + 1 : _firstVisible - 1;
    if (next < 0 || next >= widget.pages.length) {
      return;
    }
    final String token = '$next|$_bitmapWidthPx';
    if (token == _prefetched) {
      return;
    }
    _prefetched = token;
    widget.cache.prefetch(next, _bitmapWidthPx);
  }

  /// 预热方向：甩动中取速度方向；拖动 / 静止取最近一帧的位移方向
  /// （内容上移 = 在看后面的页 = +1）；没有位移时默认 +1。
  int _prefetchDir() {
    if (_ticker.isActive && _velocity.dy.abs() > _flingStopVelocity) {
      final int d = -_velocity.dy.sign.toInt();
      if (d != 0) {
        return d;
      }
    }
    final int d = -(_offset.dy - _lastPanDy).sign.toInt();
    return d != 0 ? d : 1;
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
    _publishCamera();
    _trackVisible();
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
    _publishCamera();
    _trackVisible();
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
        _publishCamera();

        final (int first, int last) = _visibleRangeNow();
        _firstVisible = first;
        _lastVisible = last;

        // 重排后补一次页码上报（上面说的 _pendingReport）。
        // 除这一次外，build 不做任何副作用。
        if (_pendingReport) {
          _pendingReport = false;
          _updateCurrentPage();
        }

        final List<Widget> pageWidgets = <Widget>[];
        for (int i = first; i <= last && i < _tops.length; i++) {
          pageWidgets.add(
            Positioned(
              left: 0,
              top: _tops[i],
              width: _baseWidth,
              height: _heights[i],
              child: PageLayer(
                // 按页身份做 key：可见集平移时"离开的 dispose、进入的新建"，
                // 不会出现两个 PageLayer 同时换页重载的闪烁（无 key 时
                // 按索引配对就会）。
                key: ValueKey<int>(widget.pages[i].index),
                cache: widget.cache,
                page: widget.pages[i],
                width: _baseWidth,
                qualityWidth: _bitmapWidthPx,
                style: widget.style,
                intensity: widget.intensity,
                sessionId: widget.sessionId,
                inkEnabled: widget.sessionId != null,
                inkStyle: widget.inkStyle,
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
            // 只收 touch：stylus 的拖动是"写字"（墨迹层自己消费），
            // 绝不能同时被这个缩放手势当成平移——否则边写边跑画面。
            // 规格 §6.9.1「笔写、指滚」在滚动模式的落地方式。
            supportedDevices: const <PointerDeviceKind>{
              PointerDeviceKind.touch,
            },
            onScaleStart: _onScaleStart,
            onScaleUpdate: _onScaleUpdate,
            onScaleEnd: _onScaleEnd,
            child: Listener(
              // 笔优先的观察哨：只记录"笔最近动过"的时间戳，
              // 不消费、不拦截任何事件（translucent）。
              behavior: HitTestBehavior.translucent,
              onPointerDown: _observePointer,
              onPointerMove: _observePointer,
              onPointerUp: _observePointer,
              onPointerCancel: _observePointer,
              child: ClipRect(
                // 丝滑关键：矩阵走 notifier 独立重建，页面列表作为静态 child
                // 不参与每帧重建。
                child: ValueListenableBuilder<_Camera>(
                  valueListenable: _cam,
                  builder: (BuildContext context, _Camera cam, Widget? child) {
                    return Transform(
                      alignment: Alignment.topLeft,
                      transform: Matrix4.identity()
                        ..translateByDouble(cam.offset.dx, cam.offset.dy, 0, 1)
                        ..scaleByDouble(cam.scale, cam.scale, 1, 1),
                      child: child,
                    );
                  },
                  child: content,
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
