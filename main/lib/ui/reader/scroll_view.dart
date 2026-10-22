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
/// ## 双指缩放为什么不直接用 InteractiveViewer
///
/// `InteractiveViewer` 内部是 `ScaleGestureRecognizer`，它把**单指拖动**也当作缩放手势的
/// 平移分支，会赢下手势竞技场、把纵向滚动吃掉；反过来关掉它的 pan，识别器依然占位，
/// 列表照样滚不动——这就是"缩放与滚动互相打架"的根因。
///
/// 这里走成熟方案（photo_view 的思路）：**不参与手势竞技场**，用最底层的 [Listener] 数指针：
/// - 单指：什么都不做，完全交给 ListView，滚动跟原生一样跟手；
/// - 双指：自己算两指距离，过程中用 `Transform.scale` 做**实时预览**（纯 GPU，零布局成本），
///   松手时才提交成新的页宽并重新布局（避免每帧重建位图）。
///
/// 放大后页面比视口宽，横向由外层 `SingleChildScrollView` 负责，纵向仍归列表。
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

  /// 倍率被双指改变后回调，让 AppBar 的百分比跟着更新。
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

  List<double> _topOffsets = const <double>[];
  List<double> _heights = const <double>[];
  double _contentWidth = 0;
  double _viewportHeight = 0;
  int _current = 0;
  bool _jumped = false;

  /// 已提交的倍率（决定页宽与布局）
  double _zoom = 1;

  /// 捏合过程中的临时倍率，只用于 `Transform` 预览
  double _liveScale = 1;

  final Map<int, Offset> _pointers = <int, Offset>{};
  double _pinchBaseDistance = 0;

  bool get _pinching => _pointers.length >= 2;

  @override
  void initState() {
    super.initState();
    _zoom = widget.zoom.clamp(_minZoom, _maxZoom);
    _current = widget.initialPage.clamp(0, math.max(0, widget.pages.length - 1));
    _vertical.addListener(_onScroll);
  }

  @override
  void didUpdateWidget(covariant ScrollReaderView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.zoom != widget.zoom && (widget.zoom - _zoom).abs() > 0.001) {
      _zoom = widget.zoom.clamp(_minZoom, _maxZoom);
      _contentWidth = 0;
      _resyncToCurrent();
    }
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

  @override
  void dispose() {
    _vertical
      ..removeListener(_onScroll)
      ..dispose();
    _horizontal.dispose();
    super.dispose();
  }

  // ── 双指缩放：只用原始指针，不参与手势竞技场 ─────────────────────────────

  void _onPointerDown(PointerDownEvent event) {
    _pointers[event.pointer] = event.localPosition;
    if (_pointers.length == 2) {
      _pinchBaseDistance = _distanceBetweenPointers();
      setState(() {
        _liveScale = 1;
      });
    }
  }

  void _onPointerMove(PointerMoveEvent event) {
    if (!_pointers.containsKey(event.pointer)) {
      return;
    }
    _pointers[event.pointer] = event.localPosition;
    if (!_pinching || _pinchBaseDistance <= 0) {
      return;
    }
    final double distance = _distanceBetweenPointers();
    final double target = (_zoom * distance / _pinchBaseDistance).clamp(
      _minZoom,
      _maxZoom,
    );
    final double preview = target / _zoom;
    if ((preview - _liveScale).abs() < 0.002) {
      return;
    }
    // 只更新预览倍率：Transform 是纯 GPU 变换，这个 setState 很便宜
    setState(() {
      _liveScale = preview;
    });
  }

  void _onPointerEnd(PointerEvent event) {
    _pointers.remove(event.pointer);
    if (_pointers.isNotEmpty) {
      return;
    }
    if ((_liveScale - 1).abs() > 0.01) {
      // 所有手指离开：把预览倍率提交成真实倍率
      final double next = (_zoom * _liveScale).clamp(_minZoom, _maxZoom);
      setState(() {
        _zoom = next;
        _liveScale = 1;
        _contentWidth = 0; // 强制重算布局
      });
      widget.onZoomChanged?.call(next);
      _resyncToCurrent();
    } else if (_liveScale != 1) {
      setState(() {
        _liveScale = 1;
      });
    }
  }

  double _distanceBetweenPointers() {
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
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double fitWidth = math.min(
          constraints.maxWidth,
          ShqLayout.maxReadingWidth,
        );
        final double contentWidth = fitWidth * _zoom;
        _layout(contentWidth);
        _viewportHeight = constraints.maxHeight;

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

        Widget list = ListView.builder(
          controller: _vertical,
          // 捏合的两指期间不要滚动，否则画面会一边缩放一边跑
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
          child: _liveScale == 1
              ? list
              // 捏合预览：只做视觉缩放，不动布局；ClipRect 防止放大时画到父级外面
              : ClipRect(
                  child: Transform.scale(
                    scale: _liveScale,
                    alignment: Alignment.center,
                    child: list,
                  ),
                ),
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
