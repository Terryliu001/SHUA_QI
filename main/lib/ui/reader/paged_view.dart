import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:shuaqi/domain/model/wb_page.dart';
import 'package:shuaqi/ui/reader/page_image_cache.dart';
import 'package:shuaqi/ui/reader/page_layer.dart';
import 'package:shuaqi/ui/theme/tokens.dart';

/// 分页模式：一屏一页 + 页内自由缩放（1.0–4.0）+ 左右边缘 15% 点击翻页 + 双击缩放。
///
/// 为"丝滑"做的三件事（都是实测出来的卡点）：
/// 1. **预渲染前后页**：翻页时目标页已就绪，不再每次翻页都等渲染 + 解码。
/// 2. **只在手势结束时重渲染高倍率图**：缩放过程中每换一个倍率档就重渲染，会把 CPU 抢光。
/// 3. **`filterQuality.low`**：缩放过程中的重采样更便宜，松手后再换清晰图。
class PagedReaderView extends StatefulWidget {
  const PagedReaderView({
    super.key,
    required this.pages,
    required this.cache,
    required this.initialPage,
    required this.onPageChanged,
  });

  final List<WbPage> pages;
  final PageImageCache cache;
  final int initialPage;
  final ValueChanged<int> onPageChanged;

  @override
  State<PagedReaderView> createState() => PagedReaderViewState();
}

class PagedReaderViewState extends State<PagedReaderView> {
  late final PageController _pageController;
  late final TransformationController _zoom;

  late int _current;
  int _renderScale = 1;
  bool _zoomed = false;
  Size _viewport = Size.zero;

  /// 已经预热过的 (页, 像素宽)，避免 build 里重复发起
  String _prefetched = '';

  @override
  void initState() {
    super.initState();
    _current = widget.initialPage.clamp(0, math.max(0, widget.pages.length - 1));
    _pageController = PageController(initialPage: _current);
    _zoom = TransformationController()..addListener(_onZoomTick);
  }

  @override
  void dispose() {
    _zoom
      ..removeListener(_onZoomTick)
      ..dispose();
    _pageController.dispose();
    super.dispose();
  }

  /// 手势过程中只更新"是否已放大"（用来切 PageView 的 physics，代价极小）。
  /// **不**在这里改 `_renderScale`——那会触发重渲染，缩放直接卡。
  void _onZoomTick() {
    final bool zoomed = _zoom.value.getMaxScaleOnAxis() > 1.05;
    if (zoomed != _zoomed) {
      setState(() {
        _zoomed = zoomed;
      });
    }
  }

  /// 手势结束才决定要不要换更高分辨率的图。
  void _onInteractionEnd(ScaleEndDetails details) {
    final double scale = _zoom.value.getMaxScaleOnAxis();
    final int bucket = scale <= 1.05 ? 1 : scale.round().clamp(1, 4);
    if (bucket != _renderScale) {
      setState(() {
        _renderScale = bucket;
      });
    }
  }

  void _setScale(double target) {
    if (_viewport.isEmpty) {
      return;
    }
    if (target <= 1.0) {
      _zoom.value = Matrix4.identity();
    } else {
      final Offset center = _viewport.center(Offset.zero);
      _zoom.value = Matrix4.identity()
        ..translateByDouble(center.dx, center.dy, 0, 1)
        ..scaleByDouble(target, target, target, 1)
        ..translateByDouble(-center.dx, -center.dy, 0, 1);
    }
    _onInteractionEnd(ScaleEndDetails());
  }

  void _goTo(int delta) {
    final int next = _current + delta;
    if (next < 0 || next >= widget.pages.length) {
      return;
    }
    _pageController.animateToPage(
      next,
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
    );
  }

  void _prefetchNeighbours(double dpr) {
    if (widget.pages.isEmpty) {
      return;
    }
    final WbPage page = widget.pages[_current];
    final double fit = math.min(
      _viewport.width / page.width,
      _viewport.height / page.height,
    );
    final int widthPx = (page.width * fit * dpr).round();
    final String token = '$_current/$widthPx';
    if (token == _prefetched) {
      return;
    }
    _prefetched = token;
    for (final int offset in <int>[-1, 1, 2]) {
      final int index = _current + offset;
      if (index >= 0 && index < widget.pages.length) {
        widget.cache.prefetch(index, widthPx);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final double dpr = MediaQuery.devicePixelRatioOf(context);
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        _viewport = Size(constraints.maxWidth, constraints.maxHeight);
        _prefetchNeighbours(dpr);

        return PageView.builder(
          controller: _pageController,
          // 放大时禁止翻页滑动，把横向手势让给平移
          physics: _zoomed
              ? const NeverScrollableScrollPhysics()
              : const PageScrollPhysics(),
          itemCount: widget.pages.length,
          onPageChanged: (int index) {
            _zoom.value = Matrix4.identity();
            setState(() {
              _current = index;
              _renderScale = 1;
              _zoomed = false;
            });
            widget.onPageChanged(index);
          },
          itemBuilder: (BuildContext context, int index) {
            final WbPage page = widget.pages[index];
            final double fit = math.min(
              constraints.maxWidth / page.width,
              constraints.maxHeight / page.height,
            );
            final double displayWidth = page.width * fit;
            final bool active = index == _current;

            return GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTapUp: (TapUpDetails details) {
                final double x = details.localPosition.dx;
                if (x < constraints.maxWidth * 0.15) {
                  _goTo(-1);
                } else if (x > constraints.maxWidth * 0.85) {
                  _goTo(1);
                }
              },
              // 双击：fit-width ↔ 2 倍。放大后想翻页先双击缩回，或点边缘翻页
              onDoubleTap: () {
                final double scale = _zoom.value.getMaxScaleOnAxis();
                _setScale(scale > 1.5 ? 1.0 : 2.0);
              },
              child: InteractiveViewer(
                minScale: 1,
                maxScale: 4,
                panEnabled: _zoomed,
                scaleEnabled: true,
                transformationController: active ? _zoom : null,
                onInteractionEnd: active ? _onInteractionEnd : null,
                child: Center(
                  child: PageLayer(
                    cache: widget.cache,
                    page: page,
                    width: displayWidth,
                    renderScale: active ? _renderScale.toDouble() : 1,
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  /// 供父级"跳到某页"用（缩略图抽屉）。
  void jumpTo(int index) {
    if (index < 0 || index >= widget.pages.length) {
      return;
    }
    _pageController.jumpToPage(index);
  }
}

/// 顶部页码条。1-based 显示，库里存 0-based。
class PageIndicator extends StatelessWidget {
  const PageIndicator({
    super.key,
    required this.current,
    required this.total,
    this.onTap,
  });

  final int current;
  final int total;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return TextButton(
      onPressed: onTap,
      style: TextButton.styleFrom(
        minimumSize: const Size(0, 36),
        padding: const EdgeInsets.symmetric(horizontal: ShqSpace.md),
      ),
      child: Text(
        '${current + 1} / $total',
        style: theme.textTheme.labelLarge,
      ),
    );
  }
}
