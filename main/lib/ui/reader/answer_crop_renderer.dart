import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:shuaqi/domain/ink/ink_doc.dart';
import 'package:shuaqi/domain/model/wb_page.dart';
import 'package:shuaqi/domain/region/region_rect.dart';
import 'package:shuaqi/ui/reader/ink_painters.dart';
import 'package:shuaqi/ui/reader/page_image_cache.dart';

/// 把一道题的「作答框」渲染成一张 PNG：PDF 原图裁切 + 该页笔迹。
///
/// 为什么不用 `RepaintBoundary.toImage`：
/// - 作答框可能在当前视口外/被面板遮住，截图拿不到；
/// - 需要稳定的页面坐标裁切，和屏幕缩放/纸感滤镜无关。
///
/// 默认输出上限 1024 宽、1600 高：够 AI 看清手写，又不会把 PNG 撑到几 MB。
/// 收藏快照（2026-10-25）要的是「点开看清晰」，所以允许调用方放大
/// [scale]/[maxWidth]/[maxHeight]：题面图按 2.8×pt、上限 1800×2600 出图。
/// 失败返回 null，调用方给"原图保存失败"提示，不抛异常。
Future<Uint8List?> renderAnswerCropPng({
  required PageImageCache cache,
  required WbPage page,
  required RegionRect rect,
  required InkDoc doc,
  bool darkPaper = false,
  // 2026-10-26 用户第 14 条（图片清晰度）：1.6×/1024px 太糊了。
  // 提到 2.2×/1600×2400 —— AI 看得更准，存到相册也够看。
  double scale = 2.2,
  int maxWidth = 1600,
  int maxHeight = 2400,
}) async {
  if (rect.isEmpty || page.width <= 0 || page.height <= 0) {
    return null;
  }
  // 先按 [scale]×pt 估宽，再同时受宽度/高度上限约束。
  int outWidth = (rect.width * scale).round().clamp(320, maxWidth);
  int outHeight = (outWidth * rect.height / rect.width).round();
  if (outHeight > maxHeight) {
    outHeight = maxHeight;
    outWidth = (outHeight * rect.width / rect.height).round().clamp(
      200,
      maxWidth,
    );
  }
  if (outHeight < 1) {
    return null;
  }

  ui.Image? pageImage;
  ui.Picture? picture;
  ui.Image? outImage;
  try {
    pageImage = await cache.obtain(
      page.index,
      (outWidth * 1.4).round().clamp(480, 3200),
    );
    final ui.Image? loaded = pageImage;
    if (loaded == null) {
      return null;
    }
    final ui.PictureRecorder recorder = ui.PictureRecorder();
    final Canvas canvas = Canvas(
      recorder,
      Rect.fromLTWH(0, 0, outWidth.toDouble(), outHeight.toDouble()),
    );
    final double scale = outWidth / rect.width;
    canvas.save();
    canvas.scale(scale);
    canvas.translate(-rect.left, -rect.top);
    // PDF 整页图片按页面坐标铺回去，再由 canvas 的平移/缩放裁出作答框。
    canvas.drawImageRect(
      loaded,
      Rect.fromLTWH(
        0,
        0,
        loaded.width.toDouble(),
        loaded.height.toDouble(),
      ),
      Rect.fromLTWH(0, 0, page.width, page.height),
      Paint()..filterQuality = FilterQuality.medium,
    );
    final CommittedInkCache ink = CommittedInkCache()
      ..sync(doc, darkPaper: darkPaper, epoch: doc.revision);
    ink.draw(canvas);
    canvas.restore();
    final ui.Picture recorded = recorder.endRecording();
    picture = recorded;
    outImage = await recorded.toImage(outWidth, outHeight);
    final ByteData? data = await outImage.toByteData(
      format: ui.ImageByteFormat.png,
    );
    if (data == null) {
      return null;
    }
    return data.buffer.asUint8List();
  } on Object {
    return null;
  } finally {
    outImage?.dispose();
    picture?.dispose();
    pageImage?.dispose();
  }
}

/// 把一份**纯笔迹**（收藏二刷的 SIF）渲染成白底 PNG（T8.3b）。
///
/// 不需要 PDF：二刷是虚拟作答纸，白底 + 笔迹就是"我的新作答"的完整样子。
/// 尺寸口径与答题卡一致（默认 1000×600pt），输出宽 1000px，手机/平板都够看。
Future<Uint8List?> renderInkDocPng({
  required InkDoc doc,
  double widthPt = 1000,
  double heightPt = 600,
  int width = 1000,
}) {
  if (doc.strokes.isEmpty || widthPt <= 0 || heightPt <= 0 || width <= 0) {
    return Future<Uint8List?>.value();
  }
  final int height = (width * heightPt / widthPt).round();
  if (height < 1) {
    return Future<Uint8List?>.value();
  }
  return _recordPng(
    width: width,
    height: height,
    paint: (Canvas canvas) {
      canvas.drawRect(
        Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
        Paint()..color = Colors.white,
      );
      canvas.save();
      canvas.scale(width / widthPt);
      _drawInk(canvas, doc, scale: 1);
      canvas.restore();
    },
  );
}

/// 答题卡画布导出：纯白底 + 手写笔迹（不含题目）。
///
/// 多张纸时**纵向拼接**：用户要"按顺序统一收集为该题的作答"，
/// 导出一张图就是这一题的全部作答，发给 AI/老师不用自己拼。
/// 纸样式默认不画（导出图是给机器看的，横线只会干扰）。
Future<Uint8List?> renderAnswerSheetInkPng({
  required List<InkDoc> docs,
  double widthPt = 1000,
  double heightPt = 600,
}) {
  if (widthPt <= 0 || heightPt <= 0) {
    return Future<Uint8List?>.value();
  }
  const int width = 1000;
  final int pageHeight = (width * heightPt / widthPt).round();
  const int gap = 12;
  final int count = docs.isEmpty ? 1 : docs.length;
  final int height = count * pageHeight + (count - 1) * gap;
  return _recordPng(
    width: width,
    height: height,
    paint: (Canvas canvas) {
      canvas.drawRect(
        Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
        Paint()..color = Colors.white,
      );
      for (int i = 0; i < count; i++) {
        canvas.save();
        canvas.translate(0, (i * (pageHeight + gap)).toDouble());
        canvas.scale(width / widthPt);
        if (i < docs.length) {
          _drawInk(canvas, docs[i], scale: 1);
        }
        canvas.restore();
        if (i < count - 1) {
          final double y = (i * (pageHeight + gap) + pageHeight + gap / 2)
              .toDouble();
          canvas.drawLine(
            Offset(0, y),
            Offset(width.toDouble(), y),
            Paint()
              ..color = const Color(0xFFD7D0C2)
              ..strokeWidth = 1,
          );
        }
      }
    },
  );
}

/// 答题卡 + 题目合并图：上方题目裁切，下方作答纸（多张纵向拼接）。
Future<Uint8List?> renderAnswerSheetWithQuestionPng({
  required PageImageCache cache,
  required WbPage page,
  required RegionRect rect,
  required List<InkDoc> docs,
  double widthPt = 1000,
  double heightPt = 600,
}) async {
  if (rect.isEmpty || page.width <= 0 || page.height <= 0) {
    return null;
  }
  if (widthPt <= 0 || heightPt <= 0) {
    return null;
  }
  const int width = 1000;
  final int questionHeight = (width * rect.height / rect.width)
      .round()
      .clamp(120, 520);
  const int gap = 18;
  final int pageHeight = (width * heightPt / widthPt).round();
  final int count = docs.isEmpty ? 1 : docs.length;
  const int pageGap = 10;
  final int height =
      questionHeight + gap + count * pageHeight + (count - 1) * pageGap;

  ui.Image? pageImage;
  try {
    pageImage = await cache.obtain(page.index, 1400);
    final ui.Image? loaded = pageImage;
    if (loaded == null) {
      return null;
    }
    return await _recordPng(
      width: width,
      height: height,
      paint: (Canvas canvas) {
        canvas.drawRect(
          Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
          Paint()..color = Colors.white,
        );
        // 上方：题目原图裁切。
        canvas.save();
        canvas.clipRect(
          Rect.fromLTWH(0, 0, width.toDouble(), questionHeight.toDouble()),
        );
        final double scale = width / rect.width;
        canvas.scale(scale);
        canvas.translate(-rect.left, -rect.top);
        canvas.drawImageRect(
          loaded,
          Rect.fromLTWH(
            0,
            0,
            loaded.width.toDouble(),
            loaded.height.toDouble(),
          ),
          Rect.fromLTWH(0, 0, page.width, page.height),
          Paint()..filterQuality = FilterQuality.medium,
        );
        canvas.restore();

        // 分隔线 + 下方：每一张作答纸。
        final double answerTop = questionHeight + gap.toDouble();
        canvas.drawLine(
          Offset(0, answerTop - gap / 2),
          Offset(width.toDouble(), answerTop - gap / 2),
          Paint()
            ..color = const Color(0xFFD7D0C2)
            ..strokeWidth = 1,
        );
        for (int i = 0; i < count; i++) {
          canvas.save();
          canvas.translate(
            0,
            answerTop + (i * (pageHeight + pageGap)).toDouble(),
          );
          canvas.scale(width / widthPt);
          if (i < docs.length) {
            _drawInk(canvas, docs[i], scale: 1);
          }
          canvas.restore();
        }
      },
    );
  } on Object {
    return null;
  } finally {
    pageImage?.dispose();
  }
}

/// PDF 页内作答框导出：只保留笔迹，白底，不画 PDF 纸面。
Future<Uint8List?> renderPageInkOnlyPng({
  required RegionRect rect,
  required InkDoc doc,
}) async {
  if (rect.isEmpty || rect.width <= 0 || rect.height <= 0) {
    return null;
  }
  int width = (rect.width * 1.8).round().clamp(320, 1200);
  int height = (width * rect.height / rect.width).round();
  if (height > 1600) {
    height = 1600;
    width = (height * rect.width / rect.height).round().clamp(200, 1200);
  }
  if (height < 1) {
    return null;
  }
  return _recordPng(
    width: width,
    height: height,
    paint: (Canvas canvas) {
      canvas.drawRect(
        Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
        Paint()..color = Colors.white,
      );
      final double scale = width / rect.width;
      canvas.save();
      canvas.scale(scale);
      canvas.translate(-rect.left, -rect.top);
      _drawInk(canvas, doc, scale: 1);
      canvas.restore();
    },
  );
}

void _drawInk(Canvas canvas, InkDoc doc, {required double scale}) {
  if (doc.strokes.isEmpty) {
    return;
  }
  final CommittedInkCache ink = CommittedInkCache()
    ..sync(doc, darkPaper: false, epoch: doc.revision);
  ink.draw(canvas);
}

Future<Uint8List?> _recordPng({
  required int width,
  required int height,
  required void Function(Canvas canvas) paint,
}) async {
  ui.Picture? picture;
  ui.Image? image;
  try {
    final ui.PictureRecorder recorder = ui.PictureRecorder();
    final Canvas canvas = Canvas(
      recorder,
      Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    );
    paint(canvas);
    picture = recorder.endRecording();
    image = await picture.toImage(width, height);
    final ByteData? data = await image.toByteData(
      format: ui.ImageByteFormat.png,
    );
    if (data == null) {
      return null;
    }
    return data.buffer.asUint8List();
  } on Object {
    return null;
  } finally {
    image?.dispose();
    picture?.dispose();
  }
}
