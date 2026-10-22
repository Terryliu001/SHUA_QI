import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:shuaqi/domain/model/wb_page.dart';
import 'package:shuaqi/ui/reader/page_image_cache.dart';
import 'package:shuaqi/ui/reader/page_layer.dart';
import 'package:shuaqi/ui/theme/tokens.dart';

/// 分页模式：一屏一页 + 页内自由缩放（0.5–4.0）+ 左右边缘 15% 点击翻页。
///
/// 两个关键实现点：
/// 1. **放大时禁掉 PageView 的滑动**，否则双指平移会被 PageView 抢走，画面会抖。
/// 2. **放大后按倍率重渲染**：显示尺寸不变、出图分辨率提高（T0.4 实测 4× 下一块 4ms）。
///    只按 1× 出图再放大，400% 时必然糊。
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

  @override
  void initState() {
    super.initState();
    _current = widget.initialPage.clamp(0, math.max(0, widget.pages.length - 1));
    _pageController = PageController(initialPage: _current);
    _zoom = TransformationController()..addListener(_onZoomChanged);
  }

  @override
  void dispose() {
    _zoom
      ..removeListener(_onZoomChanged)
      ..dispose();
    _pageController.dispose();
    super.dispose();
  }

  void _onZoomChanged() {
    final double scale = _zoom.value.getMaxScaleOnAxis();
    final bool zoomed = scale > 1.05;
    // 只在"倍率档位"或"是否放大"变化时才重建，避免每一帧手势都触发重新渲染
    final int bucket = scale <= 1.05 ? 1 : scale.round().clamp(1, 4);
    if (bucket == _renderScale && zoomed == _zoomed) {
      return;
    }
    setState(() {
      _renderScale = bucket;
      _zoomed = zoomed;
    });
  }

  void _resetZoom() {
    if (_zoom.value.isIdentity()) {
      return;
    }
    _zoom.value = Matrix4.identity();
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

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        return PageView.builder(
          controller: _pageController,
          // 放大时禁止翻页滑动，把横向手势让给平移
          physics: _zoomed
              ? const NeverScrollableScrollPhysics()
              : const PageScrollPhysics(),
          itemCount: widget.pages.length,
          onPageChanged: (int index) {
            _resetZoom();
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

            return GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTapUp: (TapUpDetails details) {
                final double x = details.localPosition.dx;
                final double width = constraints.maxWidth;
                if (x < width * 0.15) {
                  _goTo(-1);
                } else if (x > width * 0.85) {
                  _goTo(1);
                }
              },
              child: InteractiveViewer(
                minScale: 0.5,
                maxScale: 4,
                panEnabled: _zoomed,
                scaleEnabled: true,
                // 只给"当前页"挂控制器；其他页各自用内部控制器
                transformationController: index == _current ? _zoom : null,
                child: Center(
                  child: PageLayer(
                    cache: widget.cache,
                    page: page,
                    width: displayWidth,
                    renderScale: index == _current ? _renderScale.toDouble() : 1,
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
