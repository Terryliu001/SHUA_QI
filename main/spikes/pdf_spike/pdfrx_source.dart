import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:pdfrx/pdfrx.dart';
import 'package:shuaqi/infra/pdf/pdf_source.dart';

/// 用 pdfrx 实现规格 §7 的 [PdfSource]。
///
/// T0.4 的目的不只是"能渲染"，还要验**这份契约本身是否够用**。已经发现两处需要记下来：
///
/// 1. **pdfrx 不提供 `fontSize`**。`PdfPageTextFragment` 只有 `bounds`，
///    所以 `TextRun.fontSize` 目前只能用**片段高度**近似。§6.1 的 L1 规则靠"字号跳变 ≥1.15x"
///    判层级，改成按"高度跳变"判——这两个量对单行片段近似，对多行片段不等价。
/// 2. **契约要求返回 PNG 字节**，而 pdfrx 给的是 RGBA 裸像素，转 PNG 要额外的编码成本。
///    这个成本算不算得进 200ms 的翻页预算，得实测（见页面里的 raw / png 分开计时）。
class PdfrxSource implements PdfSource {
  PdfrxSource._(this._doc, this.path);

  static Future<PdfrxSource> open(String path) async {
    final PdfDocument doc = await PdfDocument.openFile(path);
    return PdfrxSource._(doc, path);
  }

  final PdfDocument _doc;
  final String path;

  Future<void> dispose() => _doc.dispose();

  @override
  int get pageCount => _doc.pages.length;

  @override
  ui.Size pageSize(int index) {
    final PdfPage page = _doc.pages[index];
    return ui.Size(page.width, page.height);
  }

  /// spike 专用：只做渲染、不做 PNG 编码，用来把两段成本拆开计时。
  Future<PdfImage?> renderRaw(int index, {required double maxEdgePx}) {
    final PdfPage page = _doc.pages[index];
    final double longEdge = math.max(page.width, page.height);
    final double scale = maxEdgePx / longEdge;
    return page.render(
      fullWidth: page.width * scale,
      fullHeight: page.height * scale,
    );
  }

  @override
  Future<Uint8List> renderPage(int index, {required double maxEdgePx}) async {
    final PdfImage? image = await renderRaw(index, maxEdgePx: maxEdgePx);
    if (image == null) {
      return Uint8List(0);
    }
    try {
      return await encodePng(image);
    } finally {
      image.dispose();
    }
  }

  /// 裸像素（BGRA）→ ui.Image → PNG。
  /// 不用已废弃的 `decodeImageFromPixels`，走 `ImageDescriptor.raw`。
  static Future<Uint8List> encodePng(PdfImage image) async {
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
    final ByteData? data = await frame.image.toByteData(
      format: ui.ImageByteFormat.png,
    );
    frame.image.dispose();
    codec.dispose();
    descriptor.dispose();
    buffer.dispose();
    return data?.buffer.asUint8List() ?? Uint8List(0);
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
          // PDF 坐标 y 向上、原点左下；页面坐标 y 向下、原点左上。
          y: pageHeight - bounds.top,
          width: bounds.width,
          height: bounds.height,
          // pdfrx 不给字号，用片段高度近似（单行片段近似成立，多行片段会偏大）。
          fontSize: bounds.height,
        ),
      );
    }
    return runs;
  }

  /// 原始文本（不做行分段），用于对比"结构化文本是否真的解析出了阅读顺序"。
  Future<String> rawText(int index) async {
    final PdfPageRawText? raw = await _doc.pages[index].loadText();
    return raw?.fullText ?? '';
  }
}
