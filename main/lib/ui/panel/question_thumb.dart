import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:shuaqi/domain/model/wb_page.dart';
import 'package:shuaqi/domain/region/region_rect.dart';
import 'package:shuaqi/ui/reader/page_image_cache.dart';
import 'package:shuaqi/ui/theme/tokens.dart';

/// 题目缩略图：把一道题的 PDF 区域**完整装进**给定宽高（BoxFit.contain）。
///
/// 与 [RegionPreview] 的区别：
/// - preview 是"纵向裁一段"（面板里看题面开头）；
/// - thumb 是"整题缩小"（答题卡确认/题号概览必须看到完整区域）。
///
/// 它只画 PDF，不画笔迹；作答卡阶段再叠加墨迹层。
class QuestionThumb extends StatefulWidget {
  const QuestionThumb({
    super.key,
    required this.cache,
    required this.page,
    required this.rect,
    required this.width,
    required this.height,
    this.paperColor = ShqPaper.base,
  });

  final PageImageCache cache;
  final WbPage page;
  final RegionRect rect;
  final double width;
  final double height;
  final Color paperColor;

  @override
  State<QuestionThumb> createState() => _QuestionThumbState();
}

class _QuestionThumbState extends State<QuestionThumb> {
  ui.Image? _image;
  int _request = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    unawaited(_load());
  }

  @override
  void didUpdateWidget(covariant QuestionThumb oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.page.index != widget.page.index ||
        oldWidget.rect != widget.rect ||
        oldWidget.width != widget.width) {
      unawaited(_load());
    }
  }

  @override
  void dispose() {
    _request++;
    _image?.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final int request = ++_request;
    final double dpr = math.max(1, MediaQuery.devicePixelRatioOf(context));
    final int px = (widget.width * dpr * 1.2).round().clamp(240, 1400);
    ui.Image? image;
    try {
      image = await widget.cache.obtain(widget.page.index, px);
    } on Object {
      image = null;
    }
    if (!mounted || request != _request) {
      image?.dispose();
      return;
    }
    final ui.Image? previous = _image;
    setState(() => _image = image);
    previous?.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ui.Image? image = _image;
    return SizedBox(
      width: widget.width,
      height: widget.height,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: widget.paperColor,
          borderRadius: BorderRadius.circular(ShqRadius.sm),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(ShqRadius.sm),
          child: image == null
              ? const Center(
                  child: SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              : CustomPaint(
                  painter: _QuestionThumbPainter(
                    image: image,
                    pageWidth: widget.page.width,
                    pageHeight: widget.page.height,
                    rect: widget.rect,
                  ),
                ),
        ),
      ),
    );
  }
}

class _QuestionThumbPainter extends CustomPainter {
  _QuestionThumbPainter({
    required this.image,
    required this.pageWidth,
    required this.pageHeight,
    required this.rect,
  });

  final ui.Image image;
  final double pageWidth;
  final double pageHeight;
  final RegionRect rect;

  @override
  void paint(Canvas canvas, Size size) {
    if (pageWidth <= 0 || pageHeight <= 0 || rect.isEmpty) {
      return;
    }
    final double sx = image.width / pageWidth;
    final double sy = image.height / pageHeight;
    final Rect src = Rect.fromLTRB(
      (rect.left * sx).clamp(0, image.width.toDouble()),
      (rect.top * sy).clamp(0, image.height.toDouble()),
      (rect.right * sx).clamp(0, image.width.toDouble()),
      (rect.bottom * sy).clamp(0, image.height.toDouble()),
    );
    if (src.isEmpty) {
      return;
    }
    final FittedSizes fitted = applyBoxFit(BoxFit.contain, src.size, size);
    final Rect dst = Alignment.center.inscribe(
      fitted.destination,
      Offset.zero & size,
    );
    canvas.drawImageRect(
      image,
      src,
      dst,
      Paint()..filterQuality = FilterQuality.medium,
    );
  }

  @override
  bool shouldRepaint(_QuestionThumbPainter oldDelegate) =>
      oldDelegate.image != image ||
      oldDelegate.rect != rect ||
      oldDelegate.pageWidth != pageWidth ||
      oldDelegate.pageHeight != pageHeight;
}
