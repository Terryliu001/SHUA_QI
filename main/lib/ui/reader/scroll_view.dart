import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:shuaqi/domain/model/wb_page.dart';
import 'package:shuaqi/ui/reader/page_image_cache.dart';
import 'package:shuaqi/ui/reader/page_layer.dart';
import 'package:shuaqi/ui/theme/tokens.dart';

/// 连续滚动模式：竖向连排、页间距 8dp、按"与视口重叠面积最大"取主可见页。
///
/// 注意：**不要把整个列表塞进 `InteractiveViewer`**——双指缩放会和竖向滚动抢手势，
/// 画面会抖（规格 T1.5 明确点名的坑）。所以这里只做 fit-width，
/// 档位缩放目前只在分页模式提供（记录在 T1.5 的已知限制里）。
class ScrollReaderView extends StatefulWidget {
  const ScrollReaderView({
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
  State<ScrollReaderView> createState() => ScrollReaderViewState();
}

class ScrollReaderViewState extends State<ScrollReaderView> {
  static const double _gap = 8;

  final ScrollController _controller = ScrollController();
  List<double> _topOffsets = const <double>[];
  List<double> _heights = const <double>[];
  double _viewportWidth = 0;
  double _viewportHeight = 0;
  int _current = 0;
  bool _jumped = false;

  @override
  void initState() {
    super.initState();
    _current = widget.initialPage.clamp(0, math.max(0, widget.pages.length - 1));
    _controller.addListener(_onScroll);
  }

  @override
  void dispose() {
    _controller
      ..removeListener(_onScroll)
      ..dispose();
    super.dispose();
  }

  void _layout(double width) {
    if (width == _viewportWidth && _topOffsets.isNotEmpty) {
      return;
    }
    _viewportWidth = width;
    final List<double> heights = <double>[];
    final List<double> tops = <double>[];
    double y = 0;
    for (final WbPage page in widget.pages) {
      final double height = page.width <= 0 ? width : width * page.height / page.width;
      tops.add(y);
      heights.add(height);
      y += height + _gap * 2;
    }
    _heights = heights;
    _topOffsets = tops;
  }

  void _onScroll() {
    if (_topOffsets.isEmpty || !_controller.hasClients) {
      return;
    }
    final double top = _controller.offset;
    final double bottom = top + _viewportHeight;
    int best = 0;
    double bestOverlap = -1;
    for (int i = 0; i < _topOffsets.length; i++) {
      final double itemTop = _topOffsets[i];
      final double itemBottom = itemTop + _heights[i];
      final double overlap =
          math.min(itemBottom, bottom) - math.max(itemTop, top);
      if (overlap > bestOverlap) {
        bestOverlap = overlap;
        best = i;
      }
      if (itemTop > bottom) {
        break; // 后面的都在视口下方，不用再算
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
        final double contentWidth = math.min(
          constraints.maxWidth,
          ShqLayout.maxReadingWidth,
        );
        _layout(contentWidth);
        _viewportHeight = constraints.maxHeight;

        if (!_jumped && _topOffsets.isNotEmpty) {
          _jumped = true;
          // 首帧后跳到最后阅读位置；用 addPostFrameCallback 避免在 build 里动控制器
          WidgetsBinding.instance.addPostFrameCallback((Duration _) {
            if (!_controller.hasClients) {
              return;
            }
            final double target = _topOffsets[_current] - _gap;
            _controller.jumpTo(
              target.clamp(0, _controller.position.maxScrollExtent),
            );
          });
        }

        return ListView.builder(
          controller: _controller,
          padding: EdgeInsets.symmetric(
            horizontal: (constraints.maxWidth - contentWidth) / 2 + ShqSpace.sm,
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
      },
    );
  }

  /// 供缩略图抽屉跳页。
  void jumpTo(int index) {
    if (index < 0 || index >= _topOffsets.length || !_controller.hasClients) {
      return;
    }
    _controller.jumpTo(
      (_topOffsets[index] - _gap).clamp(0, _controller.position.maxScrollExtent),
    );
  }
}
