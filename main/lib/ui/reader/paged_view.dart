import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:shuaqi/domain/model/wb_page.dart';
import 'package:shuaqi/ui/reader/page_image_cache.dart';
import 'package:shuaqi/ui/reader/page_layer.dart';
import 'package:shuaqi/ui/theme/tokens.dart';

/// 分页模式：一屏一页 + 页内自由缩放（1.0–4.0）+ 左右边缘 15% 点击翻页 + 双击缩放。
///
/// **每页各自持有一个 [TransformationController]，绝不中途重挂。**
/// 之前是"只给当前页挂同一个控制器"，翻页时控制器从旧页摘下再挂到新页，
/// 正在进行的捏合会被打断——表现就是「翻页后第一次放大不跟手」。
///
/// 为丝滑做的另两件事：预渲染前后页；只在手势结束时换高倍率图。
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

  /// 每页一个缩放控制器。绝不跨页复用——跨页复用会打断正在进行的捏合手势。
  final Map<int, TransformationController> _controllers =
      <int, TransformationController>{};

  late int _current;
  int _renderScale = 1;
  bool _zoomed = false;
  Size _viewport = Size.zero;
  String _prefetched = '';

  @override
  void initState() {
    super.initState();
    _current = widget.initialPage.clamp(0, math.max(0, widget.pages.length - 1));
    _pageController = PageController(initialPage: _current);
  }

  @override
  void dispose() {
    for (final TransformationController controller in _controllers.values) {
      controller.dispose();
    }
    _controllers.clear();
    _pageController.dispose();
    super.dispose();
  }

  TransformationController _controllerFor(int index) {
    return _controllers.putIfAbsent(index, () {
      return TransformationController()..addListener(() => _onZoomTick(index));
    });
  }

  /// 手势过程中只更新"当前页是否已放大"（用来切 PageView 的 physics）。
  /// **不**在这里换高分辨率图——那会触发重渲染，缩放直接卡。
  void _onZoomTick(int index) {
    if (index != _current) {
      return;
    }
    final bool zoomed =
        _controllerFor(index).value.getMaxScaleOnAxis() > 1.05;
    if (zoomed != _zoomed) {
      setState(() {
        _zoomed = zoomed;
      });
    }
  }

  void _commitScale(int index) {
    if (index != _current) {
      return;
    }
    final double scale = _controllerFor(index).value.getMaxScaleOnAxis();
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
    final TransformationController controller = _controllerFor(_current);
    if (target <= 1.0) {
      controller.value = Matrix4.identity();
    } else {
      final Offset center = _viewport.center(Offset.zero);
      controller.value = Matrix4.identity()
        ..translateByDouble(center.dx, center.dy, 0, 1)
        ..scaleByDouble(target, target, target, 1)
        ..translateByDouble(-center.dx, -center.dy, 0, 1);
    }
    _commitScale(_current);
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
            final TransformationController controller = _controllerFor(index);
            final double scale = controller.value.getMaxScaleOnAxis();
            setState(() {
              _current = index;
              _zoomed = scale > 1.05;
              _renderScale = scale <= 1.05
                  ? 1
                  : scale.round().clamp(1, 4);
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
            final TransformationController controller = _controllerFor(index);
            final bool zoomed = controller.value.getMaxScaleOnAxis() > 1.05;

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
              // 双击：fit-width ↔ 2 倍
              onDoubleTap: () {
                if (index != _current) {
                  return;
                }
                final double scale = controller.value.getMaxScaleOnAxis();
                _setScale(scale > 1.5 ? 1.0 : 2.0);
              },
              child: InteractiveViewer(
                minScale: 1,
                maxScale: 4,
                // 每页始终挂着自己的控制器，不再中途重挂
                transformationController: controller,
                // 缩放后单指平移才有意义；1x 时不开，避免和外层翻页抢手势
                panEnabled: zoomed,
                scaleEnabled: true,
                onInteractionEnd: (ScaleEndDetails details) =>
                    _commitScale(index),
                child: Center(
                  child: PageLayer(
                    cache: widget.cache,
                    page: page,
                    width: displayWidth,
                    renderScale: index == _current
                        ? _renderScale.toDouble()
                        : 1,
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
