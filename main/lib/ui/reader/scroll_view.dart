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
/// **放大怎么做的**（滚动模式也要能放大）：
/// 横向滚动放在**外层**（`SingleChildScrollView(horizontal)`），纵向列表在**内层**，
/// 两个轴向各管各的——这样不会像 `InteractiveViewer` 包整个页列表那样抢手势
/// （那种做法下双指缩放会和竖向滚动互相打断，画面会抖，是规格点名的坑）。
///
/// 代价：滚动模式的放大是**档位**（100/125/150/200%），不是双指捏合。
/// 这是刻意取舍——捏合缩放与纵向滚动没有不打架的实现方式。
class ScrollReaderView extends StatefulWidget {
  const ScrollReaderView({
    super.key,
    required this.pages,
    required this.cache,
    required this.initialPage,
    required this.onPageChanged,
    this.zoom = 1,
  });

  final List<WbPage> pages;
  final PageImageCache cache;
  final int initialPage;
  final ValueChanged<int> onPageChanged;

  /// 档位缩放：1.0 / 1.25 / 1.5 / 2.0。页宽 = fit 宽 × zoom。
  final double zoom;

  @override
  State<ScrollReaderView> createState() => ScrollReaderViewState();
}

class ScrollReaderViewState extends State<ScrollReaderView> {
  static const double _gap = 8;

  final ScrollController _vertical = ScrollController();
  final ScrollController _horizontal = ScrollController();

  List<double> _topOffsets = const <double>[];
  List<double> _heights = const <double>[];
  double _contentWidth = 0;
  double _viewportHeight = 0;
  int _current = 0;
  bool _jumped = false;

  @override
  void initState() {
    super.initState();
    _current = widget.initialPage.clamp(0, math.max(0, widget.pages.length - 1));
    _vertical.addListener(_onScroll);
  }

  @override
  void didUpdateWidget(covariant ScrollReaderView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.zoom != widget.zoom) {
      // 缩放后每页高度都变了，旧的滚动偏移不再对应同一页 → 回到当前页
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
        break; // 后面的都在视口下方
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
        final double contentWidth = fitWidth * widget.zoom;
        _layout(contentWidth);
        _viewportHeight = constraints.maxHeight;

        if (!_jumped && _topOffsets.isNotEmpty) {
          _jumped = true;
          // 首帧后跳到最后阅读位置；用 addPostFrameCallback 避免在 build 里动控制器
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

        final Widget list = ListView.builder(
          controller: _vertical,
          // 预构建视口外的内容：滚动时下一屏的页已在渲染，不会闪白
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

        // 不需要横向滚动时不要套 ScrollView：少一层手势竞技，滚动手感更直接
        if (widget.zoom <= 1.0) {
          return list;
        }
        return Scrollbar(
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
