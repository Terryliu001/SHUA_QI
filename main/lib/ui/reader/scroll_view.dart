import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart'
    show DragStartBehavior, PointerDeviceKind, PointerEvent;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:shuaqi/domain/ink/ink_tool.dart';
import 'package:shuaqi/domain/model/wb_page.dart';
import 'package:shuaqi/domain/reader/reader_prefs.dart';
import 'package:shuaqi/domain/reader/scroll_math.dart';
import 'package:shuaqi/ui/reader/camera_viewport.dart';
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
/// 1. **相机矩阵独立成层**：`ValueNotifier<Camera>` + `ValueListenableBuilder`
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
    this.inkTool = InkTool.pen,
    this.inkColorIndex = 0,
    this.inkbrushWidth = 1,
    this.onPenMissed,
  });

  /// 默认缩放：0.86 = 页宽占屏幕 86%，两侧留白（和翻页模式的观感一致）。
  ///
  /// 2026-10-23 之前是 1.0（fit-width，页宽正好贴满屏幕），用户反馈
  /// "不顺滑"且"最小就是全屏不合适"——1.0 时横向被夹死、任何抖动都直接可见。
  /// 现在 1.0 仍是 fit-width（语义不变），但**默认从 0.86 起步**，
  /// 最小可到 0.45（整页浏览），最大 4.0。
  static const double defaultScale = 0.86;

  /// 缩放区间（给 AppBar 档位菜单做合法性判断）。
  static const double minScale = 0.45;
  static const double maxScale = 4;

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
  final InkTool inkTool;

  /// 当前颜色（调色板索引）与粗细档。只影响之后落下的笔。
  final int inkColorIndex;
  final int inkbrushWidth;

  /// 这一笔没落在纸上（落在纸外 / 纸还没就绪）时回调一次。
  ///
  /// 存在的意义：用户"按下去没反应"是最难排查的体验。与其让人猜，
  /// 不如明确告诉他这一笔没被纸接住。
  final VoidCallback? onPenMissed;

  @override
  State<ScrollReaderView> createState() => ScrollReaderViewState();
}

class ScrollReaderViewState extends State<ScrollReaderView>
    with SingleTickerProviderStateMixin {
  /// 页间距。规格 §6.9.1：连续滚动页间距 8dp。
  static const double _pageGap = ShqSpace.sm;

  // ── 缩放区间（2026-10-23 重定，用户要求"不要默认占满屏"）───────────
  //
  // 旧规则：最小 = 1.0 = fit-width（页宽正好等于屏宽），只能放大。
  // 用户在真机上觉得"不顺滑"，而且明确说"最小就是全屏不合适"。
  //
  // 根因有两层：
  // 1. 1.0 时横向被**夹死**（内容宽 == 视口宽），任何横向位移都被 clamp 掉，
  //    手指的斜向拖动一半被吃掉；纵向到顶/到底也是硬停。
  // 2. 没有"留白"，页面永远顶着两侧边缘，任何抖动都被看成画面在抖。
  //
  // 新规则：1.0 仍然是 fit-width（保持与旧数据的语义一致），但
  // - **默认 0.86**：页宽只占屏幕 86%，两侧留白（和翻页模式的观感一致）；
  // - **最小 0.45**：可以缩到很小，整页浏览；横向自动居中（见 ScrollMath.clampOffset）；
  // - **最大 4.0**：放大到全屏以上。
  // 这样"任何大小"都有明确落点，且没有一个尺寸是"贴死在边缘"的。
  static const double _minScale = 0.45;
  static const double _maxScale = 4;
  static const double _defaultScale = ScrollReaderView.defaultScale;

  /// 单页位图像素宽上限。再往上就该走分块渲染（T1.5.1，未做）。
  ///
  /// 3200 而不是 4096（2026-10-22 调整）：A4 在 3200 宽时一页位图 ≈ 52MB，
  /// 视口 ±1 三页同屏 ≈ 156MB，留在 200MB 缓存与 650MB 峰值预算内。
  /// 代价：200% 以上放大的清晰度从 1:1 降到 0.75:1（真无损要等分块渲染）。
  static const int _maxBitmapWidthPx = 3200;

  /// 清晰度档位：捏合停手后取 `>= scale` 的最小档，避免每次微小变化都重渲染。
  /// 相邻档比值 ≤1.25，肉眼看不出差别。
  ///
  /// 2026-10-23 向下扩展：允许缩小以后，位图按缩小后的实际像素出图
  /// （0.45 档一页只要 1350px 宽 ≈ 11MB），省下来的内存正好给预热用。
  static const List<double> _qualityBuckets = <double>[
    0.45,
    0.6,
    0.75,
    0.86,
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
  final ValueNotifier<Camera> _cam = ValueNotifier<Camera>(
    const Camera(Offset.zero, 1),
  );

  // ── 内容坐标系（只在视口尺寸变化时重算，缩放不动它）───────────────
  double _baseWidth = 0;
  List<double> _tops = const <double>[];
  List<double> _heights = const <double>[];
  double _contentH = 0;

  Size _viewport = Size.zero;
  double _dpr = 2;

  // ── 屏幕坐标系（唯一可变的两个量）────────────────────────────────
  double _scale = _defaultScale;
  double _qualityScale = _defaultScale;
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

  /// 手势开始时的平移量 / 焦点（轴向锁定要用"起点 + 投影位移"重算）。
  Offset _startOffset = Offset.zero;
  Offset _startFocal = Offset.zero;

  /// 本次手势锁定的轴：true = 竖轴，false = 横轴，null = 还没判定。
  bool? _lockVertical;

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
    // 退出时**必须把缓存的暂停淘汰恢复**：缓存比这个视图活得久
    // （切模式 / 回书架再开一卷都可能复用同一份缓存），
    // 不然一次"运动中退出"会让缓存永久不再淘汰，越滚越吃内存，
    // 最终一页都渲染不出来。
    widget.cache.deferEviction = false;
    widget.cache.trim();
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
      _scale = _defaultScale;
      _qualityScale = _defaultScale;
      _offset = Offset.zero;
      _cam.value = const Camera(Offset.zero, _defaultScale);
      _ticker.stop();
      _bouncing = false;
      _gestureActive = false;
      _gestureFrozen = false;
      _pendingPage = null;
      // 换卷时旧卷的缓存在新卷不适用：立刻恢复淘汰并收敛一次。
      widget.cache.deferEviction = false;
      widget.cache.trim();
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

  /// 夹紧平移量。
  ///
  /// [allowOverscroll] = true 时**允许越界**，但越界部分按 iOS 的"橡皮筋"曲线
  /// 衰减（拉得越远越拉不动），松手后由 [_startBounce] 用弹簧弹回去。
  /// 2026-10-23 用户反馈"一到边界就立刻停很自然"，这是对应的修法：
  /// 边界不再是一堵硬墙，而是一根有阻尼的皮筋。
  Offset _clampOffset(
    Offset offset,
    double scale, {
    bool allowOverscroll = false,
    bool overscrollVertical = true,
    bool overscrollHorizontal = true,
  }) {
    final (double x, double y) = ScrollMath.clampOffset(
      offsetX: offset.dx,
      offsetY: offset.dy,
      scale: scale,
      contentWidth: _baseWidth,
      contentHeight: _contentH,
      viewportWidth: _viewport.width,
      viewportHeight: _viewport.height,
    );
    if (!allowOverscroll) {
      return Offset(x, y);
    }
    return Offset(
      overscrollHorizontal
          ? x + _rubberBand(offset.dx - x, _viewport.width)
          : x,
      overscrollVertical ? y + _rubberBand(offset.dy - y, _viewport.height) : y,
    );
  }

  /// 橡皮筋衰减：`f(o) = (1 - 1/(o/c + 1)) · c · sign(o)`，`c = 0.35·dim`。
  ///
  /// 性质：o=0 时 0；o 很大时趋近 `c`（拉到头也只会超出约 1/3 屏），
  /// 一阶导数在 0 处为 1（刚开始跟手），越拉越钝 —— 正是"皮筋"的手感。
  static double _rubberBand(double over, double dim) {
    if (over == 0 || dim <= 0) {
      return 0;
    }
    final double c = dim * 0.35;
    final double pulled = (1 - 1 / (over.abs() / c + 1)) * c;
    return pulled * over.sign;
  }

  // ── 边界回弹（2026-10-23）──────────────────────────────────────────
  //
  // 欠阻尼弹簧：`a = -k·位移 - c·速度`。k/c 选得让它"弹一下、不过冲太多"：
  // ζ = c / (2√k) = 26 / (2·√260) ≈ 0.81 —— 轻微过冲，像 iOS 的回弹。
  static const double _bounceStiffness = 260;
  static const double _bounceDamping = 26;
  Offset _bounceVelocity = Offset.zero;
  bool _bouncing = false;

  void _startBounce(Offset velocity) {
    _bouncing = true;
    _bounceVelocity = velocity;
    _velocity = Offset.zero;
    _lastTick = Duration.zero;
    _gestureActive = true; // 回弹期间也延后页码上报
    if (!_ticker.isActive) {
      _ticker.start();
    }
  }

  void _tickBounce(double dt) {
    final Offset target = _clampOffset(_offset, _scale);
    final Offset disp = _offset - target;
    if (disp.distance < 0.4 && _bounceVelocity.distance < 8) {
      _offset = target;
      _bounceVelocity = Offset.zero;
      _bouncing = false;
      _ticker.stop();
      _publishCamera();
      _trackVisible();
      _gestureActive = false;
      _flushPendingPage();
      _endMotionSoon();
      return;
    }
    final Offset accel =
        -disp * _bounceStiffness - _bounceVelocity * _bounceDamping;
    _bounceVelocity += accel * dt;
    _offset += _bounceVelocity * dt;
    _publishCamera();
    _trackVisible();
  }

  void _recomputeBitmapWidth() {
    final double bucket = _bucketOf(_qualityScale);
    _bitmapWidthPx = (_baseWidth * _dpr * bucket).round().clamp(
      1,
      _maxBitmapWidthPx,
    );
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
    _cam.value = Camera(offset, _scale);
  }

  // ── 手势 ─────────────────────────────────────────────────────────

  /// 停掉一切"自动运动"：惯性甩动 + 清晰度升级定时器。
  /// 落笔时调用（笔一碰屏，纸就该停）。
  void _stopMotion() {
    _ticker.stop();
    _velocity = Offset.zero;
    _endMotionSoon();
  }

  /// 运动结束：恢复淘汰并立刻收敛一次（见 [PageImageCache.deferEviction]）。
  ///
  /// 放在下一帧而不是当前帧：停手那一帧往往还有一张纹理正在上传，
  /// 这时 dispose 别的页会让"刚进来的页"白闪一下。
  void _endMotionSoon() {
    if (_trimScheduled) {
      return;
    }
    _trimScheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _trimScheduled = false;
      if (!mounted) {
        return;
      }
      widget.cache.deferEviction = false;
      widget.cache.trim();
    });
  }

  bool _trimScheduled = false;

  /// 纸面接住了这一笔：停运动 + 计数（与 [_observePointer] 的视口计数配对）。
  void _onPenDownOnPaper() {
    _inkPenDowns++;
    _stopMotion();
  }

  // ── 笔优先（规格 T2.1：笔在写的时候忽略单指 touch）──────────────
  //
  // 为什么必须有：写字时手掌/手指搭在屏上是常态，touch 事件会照常进
  // 缩放手势——表现是"一落笔页面就跟着跑"。100% 时横向被夹紧看不出来，
  // 放大后横向有余量，现象最明显（用户报的"放大后无法书写"）。
  //
  // ## 2026-10-23 收紧（"滑动不跟手"的真凶）
  // 原来用"笔最近 800ms 内出现过"当门槛，副作用是：**写完抬笔后 0.8 秒内
  // 用手指滑，页面一点反应都没有**，紧接着又突然能滑——主观就是"不跟手"。
  // 现在改成两条更贴事实的规则：
  //  1. **笔在纸上（`_penDown`）时一律冻结**：这才是"手掌搭屏"的真实场景；
  //  2. 只有 **200ms** 的尾巴（笔尖刚离开时落下的手掌算 palm）。
  // 另外手势在**开始那一刻**就被冻结的，整段都不动（防止"手指在动、页面没动"
  // 之后突然窜一段），也不甩动。
  static const int _penGraceMs = 200;
  int _lastPenSeenMs = -1000000;

  /// 笔尖此刻是否压在屏幕上。由观察哨在 DOWN / UP / CANCEL 里维护。
  bool _penDown = false;

  /// 落笔计数：视口看见的笔落屏次数 vs 纸面（InkLayer）真正接住的次数。
  ///
  /// 两者不等 = 有一笔落在纸外（或纸还没就绪）——用户按下去"没反应"，
  /// 与其让人猜，不如给一句"这一笔没落在纸上"。
  int _viewportPenDowns = 0;
  int _inkPenDowns = 0;

  /// 本次手势是否被"笔优先"冻过。冻过就不能甩动——手指在动、页面没动，
  /// 这时按手指速度甩出去会让页面突然窜一段。
  bool _gestureFrozen = false;

  void _observePointer(PointerEvent event) {
    if (event.kind == PointerDeviceKind.stylus ||
        event.kind == PointerDeviceKind.invertedStylus) {
      _lastPenSeenMs = DateTime.now().millisecondsSinceEpoch;
      if (event is PointerDownEvent) {
        _penDown = true;
        _viewportPenDowns++;
        if (_viewportPenDowns > _inkPenDowns) {
          // 这一笔没被任何一页接住。派发顺序是"深的先"（InkLayer 在观察哨
          // 里面），所以纸面接住时计数已经加过了——这里不等就是落在纸外。
          _viewportPenDowns = _inkPenDowns;
          widget.onPenMissed?.call();
        }
      } else if (event is PointerUpEvent || event is PointerCancelEvent) {
        _penDown = false;
      }
    }
  }

  /// 笔是否"正在用"：压着屏幕，或刚离开不到 [_penGraceMs]。
  bool _penActiveNow() =>
      _penDown ||
      DateTime.now().millisecondsSinceEpoch - _lastPenSeenMs < _penGraceMs;

  void _onScaleStart(ScaleStartDetails details) {
    // 这里**不**因笔而阻塞整段手势（见上面关于 pointerCount 的说明）。
    // 但"手势从手掌开始"这件事要记住：那一眼就是 palm，整段都不许动页面。
    _gestureFrozen = _penActiveNow();
    _gestureActive = true;
    _ticker.stop();
    _velocity = Offset.zero;
    _qualityTimer?.cancel();
    // 手势一开始就暂停位图淘汰：滑动中淘汰 = 每页重新渲染 + 重新上传 51MB 纹理。
    widget.cache.deferEviction = true;
    _startScale = _scale;
    _startOffset = _offset;
    _startFocal = details.localFocalPoint;
    // 轴向锁定：内容不够宽（横向推不动）时**直接锁竖轴**，连判定都不等；
    // 否则等累计位移越过 6dp 再判（偏 35° 以内都算竖滑）。见 DragAxisLock。
    final bool canPanX = _baseWidth * _scale > _viewport.width + 0.5;
    _lockVertical = canPanX ? null : true;
    // 焦点换算到内容坐标后，整段手势都让这个内容点钉在原来的屏幕位置
    _focalContent = (details.localFocalPoint - _offset) / _scale;
  }

  void _onScaleUpdate(ScaleUpdateDetails details) {
    // 双指捏合永远放行（规格 T2.1「双指缩放除外」）。
    // 单指：手势一开始就被判成 palm，或者此刻笔正压在屏幕上 → 冻结。
    if (details.pointerCount < 2 && (_gestureFrozen || _penActiveNow())) {
      _gestureFrozen = true;
      return;
    }
    final double scale = (_startScale * details.scale).clamp(
      _minScale,
      _maxScale,
    );

    Offset offset = details.localFocalPoint - _focalContent * scale;

    // ── 轴向锁定（单指平移）────────────────────────────────────────
    //
    // 为什么必须做：手指画不出直线，想竖滑时轨迹总有横向分量。
    // 旧实现把两个分量都收下，横向那部分一到边界就被吃掉/被橡皮筋弹回，
    // 主观感受就是"滑了很长距离，页面只走了一点、还有点钝"。
    // 现在一次手势只认一个轴：竖滑时 dx 完全丢弃 → 竖向 1:1 跟手、不再左右晃。
    if (details.pointerCount < 2) {
      final Offset moved = details.localFocalPoint - _startFocal;
      _lockVertical ??= DragAxisLock.decide(
        moved.dx,
        moved.dy,
        allowHorizontal: _baseWidth * _scale > _viewport.width + 0.5,
      );
      final bool? lock = _lockVertical;
      if (lock != null) {
        // 用"起点 + 投影后的位移"重算，避免焦点式累加把丢弃的分量又带回来。
        final (double dx, double dy) = DragAxisLock.project(
          moved.dx,
          moved.dy,
          vertical: lock,
        );
        offset = _startOffset + Offset(dx, dy);
      }
    }

    _scale = scale;
    // 拖动允许越界（橡皮筋），松手在 _onScaleEnd 里回弹。
    // 只给**锁定轴**橡皮筋：另一轴硬夹紧，斜滑时页面不会左右晃。
    _offset = _clampOffset(
      offset,
      scale,
      allowOverscroll: true,
      overscrollVertical: _lockVertical ?? true,
      overscrollHorizontal: _lockVertical == false,
    );
    // 丝滑关键：**不 setState**。矩阵层自己重建 Transform（一个 renderObject），
    // 页面列表纹丝不动。
    _publishCamera();
    _trackVisible();
  }

  void _onScaleEnd(ScaleEndDetails details) {
    final bool frozen = _gestureFrozen;
    _gestureFrozen = false;
    if (frozen) {
      // 被笔优先冻掉的手势：不甩动（手指在动而页面没动，甩出去会突然窜一段）。
      _gestureActive = false;
      _flushPendingPage();
      // 这个分支原来直接 return，漏掉了"恢复淘汰" —— 一次被冻结的手势
      // 就会让缓存一直停在 deferEviction，长时间使用后内存只增不减。
      _endMotionSoon();
      return;
    }
    widget.onZoomChanged?.call(_scale);
    _scheduleQualityUpgrade();

    // 甩动速度也**投影到锁定轴**：斜着甩一把时，不能让它横着飘。
    Offset velocity = details.velocity.pixelsPerSecond;
    if (details.pointerCount < 2 && _lockVertical != null) {
      final (double vx, double vy) = DragAxisLock.project(
        velocity.dx,
        velocity.dy,
        vertical: _lockVertical!,
      );
      velocity = Offset(vx, vy);
    }
    // 已经越界（拖到了边界外）：立刻回弹，不甩动 —— 手感与 iOS 一致。
    final bool outOfBounds =
        (_clampOffset(_offset, _scale) - _offset).distance > 0.5;
    if (outOfBounds) {
      _startBounce(velocity * 0.6);
      _trackVisible();
      return;
    }
    if (velocity.distance > _flingMinVelocity) {
      _velocity = velocity;
      _lastTick = Duration.zero;
      // 甩动期间同样延后页码上报（-frame 里 setState 会打断合成）。
      _gestureActive = true;
      _ticker.start();
      // 甩动期间继续暂停淘汰；停下来的那一帧由 _endMotionSoon 收敛。
    } else {
      _velocity = Offset.zero;
      _gestureActive = false;
      _flushPendingPage();
      _endMotionSoon();
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
    // 回弹用自己的弹簧积分（见 _tickBounce）；甩动走下面的衰减。
    if (_bouncing) {
      _tickBounce(dt);
      return;
    }
    final Offset next = _offset + _velocity * dt;
    _velocity = _velocity * math.pow(_flingFriction, dt).toDouble();
    final Offset clamped = _clampOffset(next, _scale);
    final bool hitEdge =
        (clamped.dx - next.dx).abs() > 0.5 ||
        (clamped.dy - next.dy).abs() > 0.5;
    if (hitEdge) {
      // **不硬停**（2026-10-23）：撞到边界时把速度交给回弹弹簧，
      // 让它先越出一点点再弹回来 —— 原来这里直接 ticker.stop()，手感是"撞墙"。
      _offset = _clampOffset(next, _scale, allowOverscroll: true);
      _publishCamera();
      _trackVisible();
      _startBounce(_velocity * 0.5);
      return;
    }
    _offset = clamped;
    _publishCamera();
    _trackVisible();
    if (_velocity.distance < _flingStopVelocity) {
      _velocity = Offset.zero;
      _ticker.stop();
      _gestureActive = false;
      _flushPendingPage();
      _endMotionSoon();
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
    return ScrollMath.visibleRange(
          _tops,
          _heights,
          visibleTop,
          visibleBottom,
        ) ??
        (0, -1);
  }

  /// 主可见页 = 与视口**重叠高度最大**的那一页（规格 §6.9.2，A4/A3 混排安全）。
  ///
  /// 手势期间**不回调父级**：`onPageChanged` 会让 ReaderPage `setState`，
  /// 整页（含顶栏、工具条、两个视图）在拖动过程中重建一次，容易掉帧。
  /// 拖动中只更新内部 `_current`，抬手指后补发一次（[_flushPendingPage]）。
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
      if (_gestureActive) {
        _pendingPage = best;
      } else {
        widget.onPageChanged(best);
      }
    }
  }

  /// 手势是否进行中（拖动/捏合）。用来把"重建整页"的操作推迟到抬手之后。
  bool _gestureActive = false;

  /// 手势期间攒下的页码上报。
  int? _pendingPage;

  void _flushPendingPage() {
    final int? pending = _pendingPage;
    if (pending == null) {
      return;
    }
    _pendingPage = null;
    widget.onPageChanged(pending);
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
      _offset = _clampOffset(
        Offset(_offset.dx, -_tops[index] * _scale),
        _scale,
      );
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

        // **打开就预热**（2026-10-23 实测补的一处）：
        // 之前预热只在手势回调里跑，于是"打开文档 → 立刻滑"这一段永远是现渲染
        // （51MB 位图 + 首次纹理上传），HUD 抓到单帧 30.7ms 的顿挫。
        // 这里在 build 末尾预热一次，用户还没碰屏幕时下一页就烘好了。
        // 纯缓存调用，不 setState、不改状态（token 去重，重复调用是空操作）。
        _maybePrefetch();

        // 重排后补一次页码上报（上面说的 _pendingReport）。
        // **必须放到帧后**：_updateCurrentPage 会回调父级 onPageChanged，
        // 父级 ReaderPage 随即 setState —— 在 build 过程中动祖先会直接抛
        // "setState() or markNeedsBuild() called during build"，
        // 表现就是转屏 / 窗口尺寸变化后整页空白。
        if (_pendingReport) {
          _pendingReport = false;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) {
              return;
            }
            _updateCurrentPage();
            _trackVisible();
          });
        }

        final List<Widget> pageWidgets = <Widget>[];
        // 构建范围比"可见集"左右各多一页（2026-10-23）：
        // 页面列表只在可见集变化时重建（`setState`）。如果恰好贴着视口边界，
        // 拖动中会频繁跨页触发重建；多烘一页后，跨页只在"真的又走远一页"时发生，
        // 拖动过程中的重建次数从"每页几次"降到"每页最多一次"。
        // 代价是离屏多一张位图——缓存 320MB、且淘汰已被手势暂停，可以接受。
        final int buildFirst = first > 0 ? first - 1 : first;
        final int buildLast = last + 1 < _tops.length ? last + 1 : last;
        for (int i = buildFirst; i <= buildLast && i < _tops.length; i++) {
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
                inkTool: widget.inkTool,
                inkColorIndex: widget.inkColorIndex,
                inkbrushWidth: widget.inkbrushWidth,
                // 落笔即停：笔一碰屏，惯性滚动立刻停（否则字画在"还在飘的纸"上）。
                onPenDown: _onPenDownOnPaper,
              ),
            ),
          );
        }

        // 内容坐标系里的整卷：宽 = 视口宽（fit-width），高 = 各页 + 页间距。
        // 屏幕位置只由 [CameraViewport] 的矩阵决定，这里不含任何缩放。
        final Widget content = SizedBox(
          width: _baseWidth,
          height: _contentH,
          child: Stack(clipBehavior: Clip.none, children: pageWidgets),
        );

        // 视口、裁剪、矩阵三件事全在 [CameraViewport] 里 —— 那里有一条
        // **不能改回的硬约束**：Transform 必须是"整卷尺寸"，否则命中区会被
        // 压成视口大小（滚动模式下"看得到、写不上"的真凶，见 camera_viewport.dart）。
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          // 只收 touch：stylus 的拖动是"写字"（墨迹层自己消费），
          // 绝不能同时被这个缩放手势当成平移——否则边写边跑画面。
          // 规格 §6.9.1「笔写、指滚」在滚动模式的落地方式。
          supportedDevices: const <PointerDeviceKind>{PointerDeviceKind.touch},
          // **跟手的关键**（2026-10-23）：默认的 `DragStartBehavior.start`
          // 会让"手指按下 → 越过 18dp 触摸阈值"这一段位移**被丢掉**
          // （onScaleStart 的 focalPoint 取的是阈值判定那一刻的位置），
          // 于是内容永远落后手指 18dp，起手还有一小段死区 —— 主观就是"不顺滑/不跟手"。
          // 改成 `.down` 后，焦点基准取按下点，越过阈值的那一帧内容会一次补上，
          // 之后 1:1 跟随（标准滚动手感）。
          dragStartBehavior: DragStartBehavior.down,
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
            child: CameraViewport(
              viewport: viewport,
              camera: _cam,
              content: content,
            ),
          ),
        );
      },
    );
  }
}
