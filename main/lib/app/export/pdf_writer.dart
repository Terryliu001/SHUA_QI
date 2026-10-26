import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

/// 一页「已经是像素」的 PDF 页。
///
/// 为什么是 RGB 而不是 PNG：PDF 里最稳的位图嵌入方式是
/// `/Filter /FlateDecode` + PNG 预测器（Predictor 15），它要求的输入就是
/// "每行前加一个过滤字节的 RGB"。我们本来就要把页面合成出来（PDF 页 + 笔迹），
/// 合成结果是 `ui.Image`，直接取 `rawRgba` 去掉 alpha 就是这份数据——
/// 少一次 PNG 编码/解码，也少一个"PNG 变体不支持"的坑。
class PdfImagePage {
  const PdfImagePage({
    required this.rgb,
    required this.width,
    required this.height,
    required this.widthPt,
    required this.heightPt,
  });

  /// 紧凑排列的 RGB 字节，长度必须是 `width * height * 3`。
  final Uint8List rgb;

  final int width;
  final int height;

  /// 页面物理尺寸（pt）。用原始 PDF 页的尺寸，导出后比例与 A4 一致。
  final double widthPt;
  final double heightPt;
}

/// 极简 PDF 写入器：**只做一件事**——把一组 RGB 页拼成一个 PDF。
///
/// ## 为什么不引第三方包
/// 依赖白名单里没有 PDF 生成库（`pdfrx` 只能读）。而"每页一张整页位图"这种
/// 输出只需要几百行：PDF 的对象/流语法很老，稳定得可以手写。
///
/// ## 为什么不用 Android 的 `PdfDocument`
/// 它能做，但会把核心逻辑锁进平台代码（宿主测试跑不了、也没法在 CI 上验字节）。
/// 这里全部在 Dart 里生成，`test/export_pdf_test.dart` 可以直接校验
/// 头部、对象数、MediaBox 与 xref 偏移。
class SimplePdfWriter {
  SimplePdfWriter({this.title = ''});

  /// 写进 `/Info /Title`（中文用 UTF-16BE 十六进制串，避免 PDFDocEncoding 丢字）。
  final String title;

  final List<_EncodedPage> _pages = <_EncodedPage>[];

  int get pageCount => _pages.length;

  bool get isEmpty => _pages.isEmpty;

  /// 加入一页。**当场压缩并释放整页 RGB**。
  ///
  /// 2026-10-26 收尾：20 页 2400px 的原始 RGB 约 500MB；如果等 build 时
  /// 才逐页编码，内存会爆。这里把"编码"提前到 addPage，之后只留压缩流。
  void addPage(PdfImagePage page) {
    if (page.rgb.length != page.width * page.height * 3) {
      throw ArgumentError(
        'RGB 长度不匹配：${page.rgb.length} != ${page.width * page.height * 3}',
      );
    }
    _pages.add(
      _EncodedPage(
        body: _imageStream(page),
        widthPt: page.widthPt,
        heightPt: page.heightPt,
      ),
    );
  }

  /// 生成完整的 PDF 字节。调用方负责把它落盘/交给系统。
  Uint8List build() {
    final int count = _pages.length;
    if (count == 0) {
      throw StateError('PDF 没有任何页');
    }

    final bool hasInfo = title.trim().isNotEmpty;
    // 对象编号：1 = Catalog，2 = Pages，3 = Info（可选），之后每页 3 个对象。
    final int firstPageObj = hasInfo ? 4 : 3;
    final int lastObj = firstPageObj + count * 3 - 1;

    final Map<int, Uint8List> objects = <int, Uint8List>{};
    objects[1] = _ascii('<< /Type /Catalog /Pages 2 0 R >>');
    final List<String> kids = <String>[
      for (int i = 0; i < count; i += 1) '${firstPageObj + i * 3} 0 R',
    ];
    objects[2] = _ascii(
      '<< /Type /Pages /Count $count /Kids [${kids.join(' ')}] >>',
    );
    if (hasInfo) {
      objects[3] = _ascii(
        '<< /Title ${_pdfText(title)} /Producer (SHUAQI) >>',
      );
    }

    for (int i = 0; i < count; i += 1) {
      final _EncodedPage page = _pages[i];
      final int pageObj = firstPageObj + i * 3;
      final String w = _num(page.widthPt);
      final String h = _num(page.heightPt);
      objects[pageObj] = _ascii(
        '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 $w $h] '
        '/Resources << /XObject << /Im0 ${pageObj + 2} 0 R >> >> '
        '/Contents ${pageObj + 1} 0 R >>',
      );
      objects[pageObj + 1] = _stream(
        _ascii('q\n$w 0 0 $h 0 0 cm\n/Im0 Do\nQ\n'),
      );
      objects[pageObj + 2] = page.body;
    }

    final BytesBuilder out = BytesBuilder(copy: false);
    out.add(_ascii('%PDF-1.4\n'));
    // 二进制注释行：告诉传输工具"这是二进制文件"，别做换行转换。
    out.add(<int>[0x25, 0xE2, 0xE3, 0xCF, 0xD3, 0x0A]);

    final List<int> offsets = List<int>.filled(lastObj + 1, 0);
    for (int obj = 1; obj <= lastObj; obj += 1) {
      final Uint8List? body = objects[obj];
      if (body == null) {
        continue;
      }
      offsets[obj] = out.length;
      out.add(_ascii('$obj 0 obj\n'));
      out.add(body);
      out.add(_ascii('\nendobj\n'));
    }

    final int xrefOffset = out.length;
    out.add(_ascii('xref\n0 ${lastObj + 1}\n'));
    out.add(_ascii('0000000000 65535 f \n'));
    for (int obj = 1; obj <= lastObj; obj += 1) {
      out.add(_ascii('${offsets[obj].toString().padLeft(10, '0')} 00000 n \n'));
    }
    out.add(
      _ascii(
        'trailer\n<< /Size ${lastObj + 1} /Root 1 0 R'
        '${hasInfo ? ' /Info 3 0 R' : ''} >>\n'
        'startxref\n$xrefOffset\n%%EOF\n',
      ),
    );
    return out.takeBytes();
  }

  // ── 内部 ─────────────────────────────────────────────────────────────

  /// 图片对象：FlateDecode + PNG 预测器（每行一个 0 号过滤字节）。
  Uint8List _imageStream(PdfImagePage page) {
    final int rowBytes = page.width * 3;
    // 每行前加一个 0（None 过滤）：这是 Predictor 15 的输入格式。
    final Uint8List filtered = Uint8List(page.height * (rowBytes + 1));
    for (int y = 0; y < page.height; y += 1) {
      final int dst = y * (rowBytes + 1);
      filtered[dst] = 0;
      filtered.setRange(
        dst + 1,
        dst + 1 + rowBytes,
        page.rgb,
        y * rowBytes,
      );
    }
    final Uint8List compressed = const ZLibEncoder().encodeBytes(filtered);
    final BytesBuilder body = BytesBuilder(copy: false);
    body.add(
      _ascii(
        '<< /Type /XObject /Subtype /Image '
        '/Width ${page.width} /Height ${page.height} '
        '/ColorSpace /DeviceRGB /BitsPerComponent 8 '
        '/Filter /FlateDecode '
        '/DecodeParms << /Predictor 15 /Colors 3 /BitsPerComponent 8 '
        '/Columns ${page.width} >> '
        '/Length ${compressed.length} >>\nstream\n',
      ),
    );
    body.add(compressed);
    body.add(_ascii('\nendstream'));
    return body.takeBytes();
  }

  Uint8List _stream(Uint8List content) {
    final BytesBuilder body = BytesBuilder(copy: false);
    body.add(_ascii('<< /Length ${content.length} >>\nstream\n'));
    body.add(content);
    body.add(_ascii('\nendstream'));
    return body.takeBytes();
  }
}

/// 已压缩的一页：只保留 PDF 图片对象体（含字典与 stream），不再持有 RGB。
class _EncodedPage {
  const _EncodedPage({
    required this.body,
    required this.widthPt,
    required this.heightPt,
  });

  final Uint8List body;
  final double widthPt;
  final double heightPt;
}

/// 把 `ui.Image` 的 `rawRgba` 去掉 alpha（我们的合成页永不透明）。
Uint8List rgbFromRgba(Uint8List rgba, int width, int height) {  final int pixels = width * height;
  if (rgba.length < pixels * 4) {
    throw ArgumentError('RGBA 长度不足：${rgba.length} < ${pixels * 4}');
  }
  final Uint8List rgb = Uint8List(pixels * 3);
  int src = 0;
  int dst = 0;
  for (int i = 0; i < pixels; i += 1) {
    rgb[dst] = rgba[src];
    rgb[dst + 1] = rgba[src + 1];
    rgb[dst + 2] = rgba[src + 2];
    src += 4;
    dst += 3;
  }
  return rgb;
}

Uint8List _ascii(String value) => Uint8List.fromList(latin1.encode(value));

/// 数字写法：去掉无意义的小数尾巴（`595.0` → `595`）。
String _num(double value) {
  final String text = value.toStringAsFixed(2);
  return text.endsWith('.00') ? text.substring(0, text.length - 3) : text;
}

/// PDF 文本串：纯 ASCII 用字面量，含中文用 UTF-16BE 十六进制串。
String _pdfText(String value) {
  final bool ascii = value.codeUnits.every((int c) => c < 128);
  if (ascii) {
    final String escaped = value
        .replaceAll(r'\', r'\\')
        .replaceAll('(', r'\(')
        .replaceAll(')', r'\)');
    return '($escaped)';
  }
  final StringBuffer hex = StringBuffer('<FEFF');
  for (final int unit in value.codeUnits) {
    hex.write(unit.toRadixString(16).padLeft(4, '0').toUpperCase());
  }
  hex.write('>');
  return hex.toString();
}
