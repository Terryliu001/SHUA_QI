import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
// ScrollCacheExtent 定义在 rendering 里，material 没有 re-export
import 'package:flutter/rendering.dart';
import 'package:shuaqi/domain/model/wb_page.dart';
import 'package:shuaqi/ui/reader/page_image_cache.dart';
import 'package:shuaqi/ui/reader/page_layer.dart';
import 'package:shuaqi/ui/theme/tokens.dart';

/// 连续滚动模式：竖向连排、页间距 8dp、按"与视口重叠面积最大"取主可见页。
///
/// ## 双指缩放：三个关键设计（都来自实测踩坑）
///
/// **① 不参与手势竞技场。** `InteractiveViewer` 内部的 `ScaleGestureRecognizer` 会把
/// 单指拖动也算进缩放分支，赢下竞技场后吃掉 `Scrollable` 的纵向拖动；关掉它的 pan
/// 也没用（识别器仍占位）。所以这里用最底层的 [Listener] 自己数指针：
/// 单指完全不干预，滚动与原生一致；两指才开始算缩放。
///
/// **② 布局尺寸与位图分辨率解耦。** 这是上一版"渲染有严重问题"的根因：
/// 缩放时布局宽每帧都在变，若位图宽度跟着变，每一帧都会向缓存请求一张全新尺寸的图
/// （一次捏合 60 帧 ≈ 60 张 12–50MB 位图），缓存被反复冲刷 → 闪烁 + 卡顿 + 内存暴涨。
/// 现在缩放期间**冻结** `_qualityZoom`（决定位图宽度），停手 250ms 后才升级一次；
/// 期间靠 GPU 拉伸已有位图，视觉稳定。
///
/// **③ 锚点补偿。** 缩放改变页高会让滚动偏移失效。记录"双指焦点所在的页与页内比例"，
/// 重排后把滚动位置修正到让那个点仍在原屏幕位置——所以不跳。
class ScrollReaderView extends StatefulWidget {
  const ScrollReaderView({
    super.key,
    required this.pages,
    required this.cache,
    required this.initialPage,
    required this.onPageChanged,
    this.zoom = 1,
    this.onZoomChanged,
  });

  final List<WbPage> pages;
  final PageImageCache cache;
  final int initialPage;
  final ValueChanged<int> onPageChanged;

  /// 初始倍率（AppBar 档位菜单用）。之后双指缩放会覆盖它。
  final double zoom;

  /// 倍率变化后回调，让 AppBar 的百分比跟着更新。
  final ValueChanged<double>? onZoomChanged;

  @override
  State<ScrollReaderView> createState() => ScrollReaderViewState();
}

class ScrollReaderViewState extends State<ScrollReaderView> {
  static const double _gap = 8;
  static const double _minZoom = 1;
  static const double _maxZoom = 3;

  final ScrollController _vertical = ScrollController();
  final ScrollController _horizontal = ScrollController();
  final Map<int, Offset> _pointers = <int, Offset>{};

  List<double> _topOffsets = const <double>[];
  List<double> _heights = const <double>[];
  double _contentWidth = 0;
  double _viewportHeight = 0;
  int _current = 0;
  bool _jumped = false;

  /// 真实倍率：决定页宽与布局（拖动时连续变化）
  double _zoom = 1;

  /// 位图倍率：只在停手 250ms 后跟着 `_zoom` 更新一次
  double _qualityZoom = 1;
  Timer? _qualityTimer;

  double _pinchBaseDistance = 0;
  double _pinchBaseZoom = 1;

  int _anchorPage = 0;
  double _anchorRatio = 0;
  double _anchorFocalY = 0;
  bool _needAnchorFix = false;

  bool get _pinching => _pointers.length >= 2;

  @override
  void initState() {
    super.initState();
    _zoom = widget.zoom.clamp(_minZoom, _maxZoom);
    _qualityZoom = _zoom;
    _current = widget.initialPage.clamp(0, math.max(0, widget.pages.length - 1));
    _vertical.addListener(_onScroll);
  }

  @override
  void didUpdateWidget(covariant ScrollReaderView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.zoom != widget.zoom && (widget.zoom - _zoom).abs() > 0.001) {
      _zoom = widget.zoom.clamp(_minZoom, _maxZoom);
      _qualityZoom = _zoom;
      _contentWidth = 0;
      _resyncToCurrent();
    }
  }

  @override
  void dispose() {
    _qualityTimer?.cancel();
    _vertical
      ..removeListener(_onScroll)
      ..dispose();
    _horizontal.dispose();
    super.dispose();
  }

  void _resyncToCurrent() {
    WidgetsBinding.instance.addPostFrameCallback((Duration _) {
      if (!mounted || !_vertical.hasClients) {
        return;
      }
      final double target = _topOffsets.isEmpty
          ? 0
          : _topOffsets[_current] - _gap;
      _vertical.jumpTo(target.clamp(0, _vertical.position.maxScrollExtent));
      if (_horizontal.hasClients) {
        _horizontal.jumpTo(0);
      }
    });
  }

  // ── 指针：单指交给列表，双指自己算 ──────────────────────────────────────

  void _onPointerDown(PointerDownEvent event) {
    _pointers[event.pointer] = event.localPosition;
    if (_pointers.length == 2) {
      _beginPinch();
    }
  }

  void _beginPinch() {
    _pinchBaseDistance = _distance();
    _pinchBaseZoom = _zoom;
    _qualityTimer?.cancel();

    final List<Offset> points = _pointers.values.toList(growable: false);
    final Offset focal = (points[0] + points[1]) / 2;
    _anchorFocalY = focal.dy;
    final double contentY =
        (_vertical.hasClients ? _vertical.offset : 0) + focal.dy;
    if (_topOffsets.isEmpty) {
      _anchorPage = 0;
      _anchorRatio = 0;
      return;
    }
    int page = 0;
    for (int i = 0; i < _topOffsets.length; i++) {
      page = i;
      final double top = _topOffsets[i];
      if (contentY >= top && contentY <= top + _heights[i]) {
        break;
      }
    }
    _anchorPage = page;
    final double height = _heights[page];
    _anchorRatio = height <= 0
        ? 0
        : ((contentY - _topOffsets[page]) / height).clamp(0.0, 1.0);
  }

  void _onPointerMove(PointerMoveEvent event) {
    if (!_pointers.containsKey(event.pointer)) {
      return;
    }
    _pointers[event.pointer] = event.localPosition;
    if (!_pinching || _pinchBaseDistance <= 0) {
      return;
    }
    final double target = (_pinchBaseZoom * _distance() / _pinchBaseDistance)
        .clamp(_minZoom, _maxZoom);
    if ((target - _zoom).abs() < 0.004) {
      return;
    }
    setState(() {
      _zoom = target;
      // 注意：_qualityZoom 不动。位图宽度保持冻结，避免每帧重建位图。
    });
    _needAnchorFix = true;
  }

  void _onPointerEnd(PointerEvent event) {
    _pointers.remove(event.pointer);
    if (_pointers.length >= 2) {
      _beginPinch();
      return;
    }
    if (_pointers.isNotEmpty) {
      _pinchBaseDistance = 0;
      return;
    }
    // 手全部离开：停 250ms 再升级位图分辨率，避免"刚停下就重绘"的抖动
    _qualityTimer?.cancel();
    _qualityTimer = Timer(const Duration(milliseconds: 250), () {
      if (!mounted) {
        return;
      }
      setState(() {
        _qualityZoom = _zoom;
      });
    });
    widget.onZoomChanged?.call(_zoom);
  }

  double _distance() {
    if (_pointers.length < 2) {
      return 0;
    }
    final List<Offset> points = _pointers.values.toList(growable: false);
    return (points[0] - points[1]).distance;
  }

  // ── 布局 ────────────────────────────────────────────────────────────────

  void _layout(double width) {
    if (width == _contentWidth && _topOffsets.isNotEmpty) {
      return;
    }
    _contentWidth = width;
    final List<double> heights = <double>[];
    final List<double> tops = <double>[];
    double y = 0;
    for (final WbPage page in widget.pages) {
      final double height = page.width <= 0
          ? width
          : width * page.height / page.width;
      tops.add(y);
      heights.add(height);
      y += height + _gap * 2;
    }
    _heights = heights;
    _topOffsets = tops;
  }

  /// 缩放后把滚动位置修正到"锚点仍在原屏幕位置"，避免视觉跳动。
  void _scheduleAnchorFix() {
    if (!_needAnchorFix || _topOffsets.isEmpty) {
      return;
    }
    _needAnchorFix = false;
    final int page = _anchorPage.clamp(0, _topOffsets.length - 1);
    final double newContentY =
        _topOffsets[page] + _anchorRatio * _heights[page];
    final double target = newContentY - _anchorFocalY;
    WidgetsBinding.instance.addPostFrameCallback((Duration _) {
      if (!mounted || !_vertical.hasClients) {
        return;
      }
      _vertical.jumpTo(target.clamp(0, _vertical.position.maxScrollExtent));
    });
  }

  void _onScroll() {
    if (_topOffsets.isEmpty || !_vertical.hasClients) {
      return;
    }
    final double top = _vertical.offset;
    final double bottom = top + _viewportHeight;
    int best = 0;
    double bestOverlap = -1;
    for (int i = 0; i < _topOffsets.length; i++) {
      final double itemTop = _topOffsets[i];
      if (itemTop > bottom) {
        break;
      }
      final double overlap =
          math.min(itemTop + _heights[i], bottom) - math.max(itemTop, top);
      if (overlap > bestOverlap) {
        bestOverlap = overlap;
        best = i;
      }
    }
    if (best != _current) {
      setState(() {
        _current = best;
      });
      widget.onPageChanged(best);
    }
  }

  @override
  Widget build(BuildContext context) {
    final double dpr = MediaQuery.devicePixelRatioOf(context);
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double fitWidth = math.min(
          constraints.maxWidth,
          ShqLayout.maxReadingWidth,
        );
        final double contentWidth = fitWidth * _zoom;
        _layout(contentWidth);
        _viewportHeight = constraints.maxHeight;
        _scheduleAnchorFix();

        if (!_jumped && _topOffsets.isNotEmpty) {
          _jumped = true;
          WidgetsBinding.instance.addPostFrameCallback((Duration _) {
            if (!_vertical.hasClients) {
              return;
            }
            final double target = _topOffsets[_current] - _gap;
            _vertical.jumpTo(
              target.clamp(0, _vertical.position.maxScrollExtent),
            );
          });
        }

        final double sidePadding =
            math.max(0, (constraints.maxWidth - contentWidth) / 2) + ShqSpace.sm;

        // 位图宽度用冻结的 _qualityZoom，而不是实时的 _zoom
        final int qualityWidth = (fitWidth * dpr * _qualityZoom).round();

        Widget list = ListView.builder(
          controller: _vertical,
          // 两指缩放期间不要滚动，否则画面一边缩放一边跑
          physics: _pinching
              ? const NeverScrollableScrollPhysics()
              : const ClampingScrollPhysics(),
          scrollCacheExtent: ScrollCacheExtent.pixels(
            constraints.maxHeight * 0.8,
          ),
          padding: EdgeInsets.symmetric(
            horizontal: sidePadding,
            vertical: ShqSpace.sm,
          ),
          itemCount: widget.pages.length,
          itemBuilder: (BuildContext context, int index) {
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: _gap),
              child: PageLayer(
                cache: widget.cache,
                page: widget.pages[index],
                width: contentWidth,
                qualityWidth: qualityWidth,
              ),
            );
          },
        );

        if (_zoom > 1.0) {
          list = Scrollbar(
            controller: _horizontal,
            thumbVisibility: true,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              controller: _horizontal,
              child: SizedBox(
                width: contentWidth + sidePadding * 2,
                height: constraints.maxHeight,
                child: list,
              ),
            ),
          );
        }

        return Listener(
          behavior: HitTestBehavior.translucent,
          onPointerDown: _onPointerDown,
          onPointerMove: _onPointerMove,
          onPointerUp: _onPointerEnd,
          onPointerCancel: _onPointerEnd,
          child: ClipRect(child: list),
        );
      },
    );
  }

  /// 供缩略图抽屉跳页。
  void jumpTo(int index) {
    if (index < 0 || index >= _topOffsets.length || !_vertical.hasClients) {
      return;
    }
    _vertical.jumpTo(
      (_topOffsets[index] - _gap).clamp(0, _vertical.position.maxScrollExtent),
    );
  }
}
