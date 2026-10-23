import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:pdfrx/pdfrx.dart';
import 'package:shuaqi/infra/pdf/pdf_source.dart';

/// 用 pdfrx 实现规格 §7 的 [PdfSource]（T0.4 已实测：首屏 28ms、翻页 3ms）。
///
/// 两个必须知道的实现事实（T0.4 结论）：
/// 1. **坐标**：pdfrx 给的是 PDF 原生坐标（原点左下、y 向上），
///    出本类前必须翻成"原点左上、y 向下"的页面坐标 pt。
/// 2. **没有字号**：`PdfPageTextFragment` 只有 `bounds`，[TextRun.fontSize] 只能用
///    片段高度近似。单行片段近似成立，多行片段会偏大。
class PdfrxSource implements PdfSource, PageBitmapSource {
  PdfrxSource._(this._doc);

  static Future<PdfrxSource> openFile(String path) async {
    final PdfDocument doc = await PdfDocument.openFile(path);
    return PdfrxSource._(doc);
  }

  final PdfDocument _doc;

  Future<void> dispose() => _doc.dispose();

  @override
  int get pageCount => _doc.pages.length;

  @override
  ui.Size pageSize(int index) {
    final PdfPage page = _doc.pages[index];
    return ui.Size(page.width, page.height);
  }

  @override
  Future<Uint8List> renderPage(int index, {required double maxEdgePx}) async {
    final PdfImage? image = await renderRaw(index, maxEdgePx: maxEdgePx);
    if (image == null) {
      return Uint8List(0);
    }
    try {
      final Uint8List png = await encodePng(image);
      return png;
    } finally {
      image.dispose();
    }
  }

  /// 只渲染、不编码。屏显（T1.5）应该走这条，PNG 编码占 T0.4 实测 120ms 的绝大部分。
  Future<PdfImage?> renderRaw(int index, {required double maxEdgePx}) {
    final PdfPage page = _doc.pages[index];
    final double longEdge = math.max(page.width, page.height);
    final double scale = maxEdgePx / longEdge;
    return page.render(
      fullWidth: page.width * scale,
      fullHeight: page.height * scale,
    );
  }

  /// 按**宽度**渲染一小块（缩略图用）。高度按页面比例自动算。
  ///
  /// 为什么单独一个方法：`renderPage` 是按长边算的，A4 竖版按宽 240px 出图
  /// 与按长边 240px 出图差 1.4 倍，缩略图会大小不一。
  Future<Uint8List> renderThumb(int index, {required int widthPx}) async {
    final PdfPage page = _doc.pages[index];
    final double scale = widthPx / page.width;
    final PdfImage? image = await page.render(
      fullWidth: page.width * scale,
      fullHeight: page.height * scale,
    );
    if (image == null) {
      return Uint8List(0);
    }
    try {
      final Uint8List png = await encodePng(image);
      return png;
    } finally {
      image.dispose();
    }
  }

  /// 按**宽度**渲染成 `ui.Image`，**屏显走这条**。
  ///
  /// 这是 T0.4 的直接结论：渲染 3ms、PNG 编码 120ms。屏显要的是能被 GPU 直接贴图的
  /// `ui.Image`，不是一段 PNG 字节。契约里的 [renderPage] 留给导出与 OCR 裁图。
  @override
  Future<ui.Image?> renderUiImage(int index, {required int widthPx}) async {
    final PdfPage page = _doc.pages[index];
    final double scale = widthPx / page.width;
    final PdfImage? image = await page.render(
      fullWidth: page.width * scale,
      fullHeight: page.height * scale,
    );
    if (image == null) {
      return null;
    }
    try {
      return await toUiImage(image);
    } finally {
      image.dispose();
    }
  }

  @override
  Future<List<TextRun>> extractText(int index) async {
    final PdfPage page = _doc.pages[index];
    final PdfPageText text = await page.loadStructuredText();
    final double pageHeight = page.height;
    final List<TextRun> runs = <TextRun>[];
    for (final PdfPageTextFragment fragment in text.fragments) {
      final PdfRect bounds = fragment.bounds;
      if (bounds.width <= 0 || bounds.height <= 0) {
        continue;
      }
      runs.add(
        TextRun(
          text: fragment.text,
          x: bounds.left,
          // PDF y 向上 → 页面 y 向下
          y: pageHeight - bounds.top,
          width: bounds.width,
          height: bounds.height,
          fontSize: bounds.height,
        ),
      );
    }
    return runs;
  }

  /// BGRA 裸像素 → ui.Image。
  /// 不用已废弃的 `decodeImageFromPixels`，走 `ImageDescriptor.raw`。
  static Future<ui.Image> toUiImage(PdfImage image) async {
    final ui.ImmutableBuffer buffer = await ui.ImmutableBuffer.fromUint8List(
      image.pixels,
    );
    final ui.ImageDescriptor descriptor = ui.ImageDescriptor.raw(
      buffer,
      width: image.width,
      height: image.height,
      pixelFormat: ui.PixelFormat.bgra8888,
    );
    final ui.Codec codec = await descriptor.instantiateCodec();
    final ui.FrameInfo frame = await codec.getNextFrame();
    codec.dispose();
    descriptor.dispose();
    buffer.dispose();
    return frame.image;
  }

  /// BGRA 裸像素 → PNG 字节（导出/OCR 用，不要用在屏显上）。
  static Future<Uint8List> encodePng(PdfImage image) async {
    final ui.Image uiImage = await toUiImage(image);
    try {
      final ByteData? data = await uiImage.toByteData(
        format: ui.ImageByteFormat.png,
      );
      return data?.buffer.asUint8List() ?? Uint8List(0);
    } finally {
      uiImage.dispose();
    }
  }
}
