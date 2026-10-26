import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shuaqi/app/export/pdf_writer.dart';

/// PDF 写入器的字节级验收。
///
/// 为什么值得测到字节：这份 PDF 是**给外部世界**的东西（发给老师、打印），
/// 出错的表现是"打不开"，而打不开的原因往往是几十行代码里一个偏移量算错。
/// 这里不依赖任何 PDF 库，只校验结构不变量。
void main() {
  Uint8List pageRgb(int width, int height, {int shade = 200}) {
    final Uint8List rgb = Uint8List(width * height * 3);
    for (int i = 0; i < rgb.length; i += 3) {
      rgb[i] = shade;
      rgb[i + 1] = shade;
      rgb[i + 2] = shade;
    }
    return rgb;
  }

  PdfImagePage page({int w = 8, int h = 6, int shade = 180}) => PdfImagePage(
    rgb: pageRgb(w, h, shade: shade),
    width: w,
    height: h,
    widthPt: 595,
    heightPt: 842,
  );

  /// 按 latin1 把字节摊成字符串：每个字节对应一个 char，**下标 = 字节偏移**。
  /// （不能用"只保留 ASCII"的过滤写法：图片流里有 >=128 的字节，一过滤偏移全乱。）
  String text(Uint8List bytes) => String.fromCharCodes(bytes);

  test('单页 PDF 的结构：头部 / Catalog / 页数 / MediaBox / EOF', () {
    final SimplePdfWriter writer = SimplePdfWriter(title: '线性代数');
    writer.addPage(page());
    final Uint8List bytes = writer.build();
    final String ascii = text(bytes);

    expect(ascii.startsWith('%PDF-1.4'), isTrue);
    expect(ascii.trimRight().endsWith('%%EOF'), isTrue);
    expect(ascii, contains('/Type /Catalog'));
    expect(ascii, contains('/Type /Pages /Count 1'));
    expect(ascii, contains('/MediaBox [0 0 595 842]'));
    expect(ascii, contains('/Subtype /Image'));
    expect(ascii, contains('/Predictor 15 /Colors 3 /BitsPerComponent 8'));
    // 中文标题走 UTF-16BE 十六进制串（PDFDocEncoding 存不下 CJK）。
    expect(ascii, contains('/Title <FEFF'));
  });

  test('每页三个对象，Pages 的 Kids 与页对象对得上', () {
    final SimplePdfWriter writer = SimplePdfWriter();
    writer.addPage(page(shade: 10));
    writer.addPage(page(shade: 20));
    final Uint8List bytes = writer.build();
    final String ascii = text(bytes);

    expect(ascii, contains('/Count 2'));
    expect(writer.pageCount, 2);
    // 无 Info 时页对象从 3 开始，每页：Page / Contents / Image。
    expect(ascii, contains('/Kids [3 0 R 6 0 R]'));
    expect(ascii, contains('3 0 obj'));
    expect(ascii, contains('8 0 obj'));
    expect(ascii, contains('/Size 9'));
  });

  test('xref 偏移真的指到对象与 xref 表（最容易写错的一处）', () {
    final SimplePdfWriter writer = SimplePdfWriter();
    writer.addPage(page());
    final Uint8List bytes = writer.build();
    final String ascii = text(bytes);

    final int startxref = int.parse(
      RegExp(r'startxref\s+(\d+)').firstMatch(ascii)!.group(1)!,
    );
    expect(ascii.substring(startxref, startxref + 4), 'xref');

    // 逐条校验 "00000000XX 00000 n" 里的偏移确实落在 "N 0 obj" 上。
    final int xrefBody = ascii.indexOf('0000000000 65535 f');
    final RegExp entry = RegExp(r'(\d{10}) 00000 n');
    final Iterable<RegExpMatch> matches = entry.allMatches(
      ascii.substring(xrefBody),
    );
    int obj = 1;
    for (final RegExpMatch match in matches) {
      final int offset = int.parse(match.group(1)!);
      expect(
        ascii.substring(offset, offset + '$obj 0 obj'.length),
        '$obj 0 obj',
        reason: '第 $obj 个对象的偏移不对',
      );
      obj += 1;
    }
    expect(obj, greaterThan(1));
  });

  test('图片流：/Length 与 zlib 数据一致，解出来是 PNG 预测器格式', () {
    final SimplePdfWriter writer = SimplePdfWriter();
    writer.addPage(page(w: 8, h: 6));
    final Uint8List bytes = writer.build();
    final String ascii = text(bytes);

    // 找到图片对象里的 /Length 与 stream 起点。
    final RegExpMatch match = RegExp(
      r'/Columns 8 >> /Length (\d+) >>\nstream\n',
    ).firstMatch(ascii)!;
    final int length = int.parse(match.group(1)!);
    final int dataStart = match.end;
    final Uint8List compressed = bytes.sublist(dataStart, dataStart + length);
    final Uint8List decoded = const ZLibDecoder().decodeBytes(compressed);

    // 每行：1 个过滤字节（0 = None）+ 8*3 个 RGB。
    expect(decoded.length, 6 * (1 + 8 * 3));
    for (int y = 0; y < 6; y += 1) {
      expect(decoded[y * (1 + 8 * 3)], 0, reason: '第 $y 行缺预测器字节');
    }
    // stream 之后紧跟 endstream（/Length 没多算少算）。
    expect(
      ascii.substring(dataStart + length, dataStart + length + 12),
      startsWith('\nendstream'),
    );
  });

  test('RGB 长度不对直接报错，而不是生成一个坏 PDF', () {
    expect(
      () => SimplePdfWriter().addPage(
        PdfImagePage(
          rgb: Uint8List(10),
          width: 2,
          height: 2,
          widthPt: 100,
          heightPt: 100,
        ),
      ),
      throwsArgumentError,
    );
    expect(() => SimplePdfWriter().build(), throwsStateError);
  });

  test('rawRgba → RGB：去掉 alpha，通道顺序不变', () {
    final Uint8List rgba = Uint8List.fromList(<int>[
      10, 20, 30, 255, //
      40, 50, 60, 128, //
    ]);
    expect(rgbFromRgba(rgba, 2, 1), <int>[10, 20, 30, 40, 50, 60]);
  });

  test('空标题不写 Info 对象', () {
    final SimplePdfWriter writer = SimplePdfWriter();
    writer.addPage(page());
    final String ascii = text(writer.build());
    expect(ascii.contains('/Info'), isFalse);
  });
}
