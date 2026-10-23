import 'dart:typed_data';
import 'dart:ui' show Image, Size;

/// PDF 数据源契约（规格 §7）。
///
/// 职责边界（§4.2）：只负责"把 PDF 变成可画的东西"——渲染、页尺寸、文本层、缩略图。
/// **不做切题判断**、不碰 Vault 路径、不认识 session。
///
/// 坐标约定：本层对外的 [Size] 与 [TextRun] 全部是**页面坐标 pt**。
/// PDF 原生坐标系（左下原点）只允许出现在实现内部，出本层前必须翻转成左上原点 + y 向下。
abstract interface class PdfSource {
  int get pageCount;

  /// 第 index 页的页面尺寸（pt）。
  Size pageSize(int index);

  /// 渲染成 PNG。`maxEdgePx` 是长边像素上限——调用方必须自己乘过 devicePixelRatio，
  /// 否则 400% 放大后会糊（这是 T0.4 明确点名要避免的坑）。
  Future<Uint8List> renderPage(int index, {required double maxEdgePx});

  /// 抽取文本层。扫描件没有文本层时返回空列表，**不抛异常**——
  /// "这份 PDF 没有文本层" 是 L2 补位的正常入口（§6.1）。
  Future<List<TextRun>> extractText(int index);
}

/// 屏显位图数据源（`ui.Image`），只给阅读器的位图缓存用。
///
/// 为什么单独一个窄接口（2026-10-23 补）：
/// 1. 阅读器的 [PageImageCache] 只需要"页数 + 按宽度出图"这两件事，
///    不该绑死在 pdfrx 这个具体实现上（否则宿主机测试里没法注入假实现，
///    也就没法把"刷新后空白"这类竞态钉成回归测试）；
/// 2. PNG 那条契约（[PdfSource.renderPage]）是给导出 / OCR 的，
///    屏显走 `ui.Image` 才不用付 120ms 的编码代价（T0.4 结论）。
abstract interface class PageBitmapSource {
  int get pageCount;

  /// 第 [index] 页、位图宽 [widthPx] 的图像。失败返回 null（不抛给 UI 层）。
  Future<Image?> renderUiImage(int index, {required int widthPx});
}

/// 一段文本及其包围盒。坐标与尺寸都是 pt。
///
/// 这是 L0 切题的输入：题号正则跑在 [text] 上，层级判定靠 [fontSize] 跳变（§6.1）。
class TextRun {
  const TextRun({
    required this.text,
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    required this.fontSize,
    this.fontName = '',
  });

  final String text;
  final double x;
  final double y;
  final double width;
  final double height;

  /// pt。字号跳变 ≥1.15x 视为层级变化。
  final double fontSize;

  final String fontName;

  double get right => x + width;

  double get bottom => y + height;

  @override
  String toString() =>
      'TextRun("$text" @(${x.toStringAsFixed(1)},${y.toStringAsFixed(1)}) '
      '$width×$height fs=$fontSize)';
}
