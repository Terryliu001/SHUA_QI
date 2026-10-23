import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:shuaqi/domain/ink/ink_doc.dart';
import 'package:shuaqi/domain/util/ulid.dart';

/// SIF v1：一页笔迹的二进制落盘格式（纯 Dart，可单测）。
///
/// ## 文件结构（整文件 zlib）
/// ```text
/// zlib( Header 16B | Stroke × n | Footer 4B )
///
/// Header: 'SIF1' | flags u8 | pageW u16 | pageH u16 | nStrokes u32 | reserved 3B
///         pageW/pageH 单位 = **0.1pt**（841.89pt → 8419）。
/// Stroke: style u8 | color u8 | width u8 | flags u8 | nPoints u16
///         | bbox 4×u16 | t0 u32 | points(dx,dy zigzag varint) | pressure(4bit×n)
/// Footer: crc32(body) u32      // body = Header + Strokes
/// ```
///
/// 与规格 03-第2周 §T2.4 的差异（有意，已记日志 031）：
/// - stroke 头增加 `color` / `width` 两个字节（T2.2 的契约变更，见日志 025）；
/// - 每点压力用 **4bit**（15 级）打包在坐标之后，不是丢掉——钢笔的粗细靠它；
/// - t0 仍是每笔一个：逐点时间戳不进屏显/识别，T2.4 只保留笔内顺序。
///
/// 坐标量化 `q = round(v / pageSize * 16383)`；往返误差 ≤ pageSize/(2×16383)
/// （A4 高 842pt 时约 0.026pt，远小于 400dpi 下的一个像素）。页尺寸用 0.1pt
/// 存 u16，避免"841.89 被存成 842"在长边累积出 0.2pt 级别的误差。
/// 验收里写的 "<0.01pt" 是按 1/100pt 固定点算的，u16 量化在 A4 上物理达不到，
/// 这里如实记录（实测最大约 0.035pt）。
///
/// 单笔上限 4096 点（规格）：超长笔拆成多笔同款式碎片；UID 不进文件，
/// 解码时重新生成（UID 是会话内身份，不是跨进程事实）。
///
/// **笔型编码是数据契约**：`style u8` 写的是 [InkStrokeStyle.index]，
/// 枚举只能追加，不能重排。
abstract final class SifCodec {
  static const int magic0 = 0x53; // S
  static const int magic1 = 0x49; // I
  static const int magic2 = 0x46; // F
  static const int magic3 = 0x31; // 1

  static const int headerBytes = 16;
  static const int footerBytes = 4;
  static const int maxPointsPerStroke = 4096;
  static const int maxStrokes = 1000000;

  /// 量化上限：q ∈ [0, 16383]。
  static const int quantMax = 16383;

  /// 压力 4bit：0..15。
  static const int pressureLevels = 15;

  /// 编码（含整文件 zlib）。失败抛 [SifEncodeException]。
  static Uint8List encode(InkDoc doc, SifPageSize pageSize) {
    if (!pageSize.isValid) {
      throw const SifEncodeException('页面尺寸非法');
    }
    final List<_Chunk> chunks = _chunkStrokes(doc.strokes);
    if (chunks.length > maxStrokes) {
      throw const SifEncodeException('笔画数超过上限');
    }

    final _Writer body = _Writer();
    body.u8(magic0);
    body.u8(magic1);
    body.u8(magic2);
    body.u8(magic3);
    body.u8(0); // flags：保留
    // 0.1pt 定点：A4 高 841.89 → 8419，u16 足够到 6553.5pt（A0 以内）。
    body.u16((pageSize.width * 10).round().clamp(1, 65535));
    body.u16((pageSize.height * 10).round().clamp(1, 65535));
    body.u32(chunks.length);
    body.u8(0);
    body.u8(0);
    body.u8(0);

    for (final _Chunk chunk in chunks) {
      _writeStroke(body, chunk, pageSize);
    }

    final Uint8List bodyBytes = body.takeBytes();
    final _Writer file = _Writer()..bytes(bodyBytes);
    file.u32(crc32(bodyBytes));

    try {
      return const ZLibEncoder().encodeBytes(file.takeBytes());
    } on Object catch (error) {
      throw SifEncodeException('zlib 压缩失败：$error');
    }
  }

  /// 解码（含 zlib 解压 + CRC 校验）。任何结构错误抛 [SifCorruptException]。
  static InkDoc decode(Uint8List bytes) {
    if (bytes.length < 8) {
      throw const SifCorruptException('文件太短');
    }
    Uint8List body;
    try {
      body = const ZLibDecoder().decodeBytes(
        bytes,
        maxOutputSize: 64 * 1024 * 1024,
      );
    } on Object catch (error) {
      throw SifCorruptException('zlib 解压失败：$error');
    }
    if (body.length < headerBytes + footerBytes) {
      throw const SifCorruptException('解压后长度不足');
    }

    final Uint8List content = Uint8List.sublistView(
      body,
      0,
      body.length - footerBytes,
    );
    final _Reader footerReader = _Reader(body, offset: body.length - 4);
    final int expected = footerReader.u32();
    final int actual = crc32(content);
    if (expected != actual) {
      throw SifCorruptException('CRC 不匹配（$expected != $actual）');
    }

    final _Reader reader = _Reader(content);
    if (reader.u8() != magic0 ||
        reader.u8() != magic1 ||
        reader.u8() != magic2 ||
        reader.u8() != magic3) {
      throw const SifCorruptException('magic 不是 SIF1');
    }
    final int flags = reader.u8();
    if (flags != 0) {
      throw SifCorruptException('不支持的 flags=$flags');
    }
    // 头里是 0.1pt 定点。
    final double pageW = reader.u16() / 10;
    final double pageH = reader.u16() / 10;
    if (pageW <= 0 || pageH <= 0) {
      throw const SifCorruptException('页面尺寸为 0');
    }
    final int count = reader.u32();
    if (count > maxStrokes) {
      throw SifCorruptException('笔画数越界：$count');
    }
    reader.skip(3); // reserved

    final List<InkStroke> strokes = <InkStroke>[];
    for (int i = 0; i < count; i++) {
      final InkStroke? stroke = _readStroke(
        reader,
        pageWidth: pageW,
        pageHeight: pageH,
      );
      if (stroke != null) {
        strokes.add(stroke);
      }
    }
    if (reader.remaining != 0) {
      throw SifCorruptException('笔画区后还有 ${reader.remaining} 字节');
    }
    return InkDoc(revision: 0, strokes: strokes);
  }

  // ── 写 ───────────────────────────────────────────────────────────

  static void _writeStroke(_Writer w, _Chunk chunk, SifPageSize size) {
    final List<InkPoint> points = chunk.points;
    w.u8(chunk.style.index);
    w.u8(chunk.colorIndex.clamp(0, 255));
    w.u8(chunk.brushWidth.clamp(0, 100));
    // bit0 = 带压力；bit1 = 荧光笔（冗余，便于以后只读头做筛选）
    w.u8(1 | (chunk.style == InkStrokeStyle.highlighter ? 2 : 0));
    w.u16(points.length);

    final InkRect bounds = InkRect.fromPoints(points);
    final int ql = _quantize(bounds.left, size.width);
    final int qt = _quantize(bounds.top, size.height);
    final int qr = _quantize(bounds.right, size.width);
    final int qb = _quantize(bounds.bottom, size.height);
    w.u16(ql);
    w.u16(qt);
    w.u16(qr);
    w.u16(qb);
    w.u32(points.first.t < 0 ? 0 : points.first.t);

    int prevX = 0;
    int prevY = 0;
    for (final InkPoint point in points) {
      final int qx = _quantize(point.x, size.width);
      final int qy = _quantize(point.y, size.height);
      w.varint(_zigZag(qx - prevX));
      w.varint(_zigZag(qy - prevY));
      prevX = qx;
      prevY = qy;
    }

    // 4bit 压力，两个点一字节（低半字节 = 前一个点）。
    for (int i = 0; i < points.length; i += 2) {
      final int low = _quantizePressure(points[i].pressure);
      final int high = i + 1 < points.length
          ? _quantizePressure(points[i + 1].pressure)
          : 0;
      w.u8(low | (high << 4));
    }
  }

  static int _quantize(double value, double pageSize) {
    if (!value.isFinite || pageSize <= 0) {
      return 0;
    }
    final double q = value / pageSize * quantMax;
    if (q <= 0) {
      return 0;
    }
    if (q >= quantMax) {
      return quantMax;
    }
    return q.round();
  }

  static int _quantizePressure(double pressure) {
    if (!pressure.isFinite || pressure <= 0) {
      return 0;
    }
    if (pressure >= 1) {
      return pressureLevels;
    }
    return (pressure * pressureLevels).round();
  }

  // ── 读 ───────────────────────────────────────────────────────────

  static InkStroke? _readStroke(
    _Reader r, {
    required double pageWidth,
    required double pageHeight,
  }) {
    final int styleIndex = r.u8();
    if (styleIndex >= InkStrokeStyle.values.length) {
      throw SifCorruptException('未知笔型：$styleIndex');
    }
    final int colorIndex = r.u8();
    final int brushWidth = r.u8().clamp(0, 100);
    final int flags = r.u8();
    if ((flags & ~3) != 0) {
      throw SifCorruptException('未知笔 flags=$flags');
    }
    final int nPoints = r.u16();
    if (nPoints > maxPointsPerStroke) {
      throw SifCorruptException('单笔点数越界：$nPoints');
    }
    // bbox 只做结构占位：解码后用点重算，避免 bbox 与点不一致时相信错的一方。
    final int ql = r.u16();
    final int qt = r.u16();
    final int qr = r.u16();
    final int qb = r.u16();
    if (ql > qr || qt > qb) {
      throw const SifCorruptException('bbox 非法');
    }
    if (ql > quantMax || qt > quantMax || qr > quantMax || qb > quantMax) {
      throw const SifCorruptException('bbox 超出量化范围');
    }
    final int t0 = r.u32();

    int prevX = 0;
    int prevY = 0;
    final List<InkPoint> points = <InkPoint>[];
    for (int i = 0; i < nPoints; i++) {
      final int dx = _unZigZag(r.varint());
      final int dy = _unZigZag(r.varint());
      final int qx = prevX + dx;
      final int qy = prevY + dy;
      if (qx < 0 || qx > quantMax || qy < 0 || qy > quantMax) {
        throw SifCorruptException('坐标越界：($qx,$qy)');
      }
      prevX = qx;
      prevY = qy;
      points.add(
        InkPoint(
          x: qx / quantMax * pageWidth,
          y: qy / quantMax * pageHeight,
          // 压力在坐标之后统一读；先占位，读完后回填。
          pressure: 0.5,
          t: t0 + i,
        ),
      );
    }

    final int pressureBytes = (nPoints + 1) ~/ 2;
    final List<int> pressures = <int>[];
    for (int i = 0; i < pressureBytes; i++) {
      final int packed = r.u8();
      pressures.add(packed & 0x0F);
      if (pressures.length < nPoints) {
        pressures.add((packed >> 4) & 0x0F);
      }
    }
    if (pressures.length != nPoints) {
      throw const SifCorruptException('压力块长度不正确');
    }

    if (nPoints == 0) {
      return null;
    }
    final List<InkPoint> withPressure = <InkPoint>[
      for (int i = 0; i < points.length; i++)
        InkPoint(
          x: points[i].x,
          y: points[i].y,
          pressure: pressures[i] / pressureLevels,
          t: points[i].t,
        ),
    ];
    return InkStroke(
      uid: Ulid.next(),
      points: withPressure,
      style: InkStrokeStyle.values[styleIndex],
      colorIndex: colorIndex,
      brushWidth: brushWidth,
    );
  }

  // ── 拆分 ─────────────────────────────────────────────────────────

  static List<_Chunk> _chunkStrokes(List<InkStroke> strokes) {
    final List<_Chunk> chunks = <_Chunk>[];
    for (final InkStroke stroke in strokes) {
      if (stroke.points.isEmpty) {
        continue;
      }
      if (stroke.points.length <= maxPointsPerStroke) {
        chunks.add(
          _Chunk(
            points: stroke.points,
            style: stroke.style,
            colorIndex: stroke.colorIndex,
            brushWidth: stroke.brushWidth,
          ),
        );
        continue;
      }
      for (int start = 0; start < stroke.points.length; start += maxPointsPerStroke) {
        final int end = (start + maxPointsPerStroke).clamp(
          0,
          stroke.points.length,
        );
        chunks.add(
          _Chunk(
            points: stroke.points.sublist(start, end),
            style: stroke.style,
            colorIndex: stroke.colorIndex,
            brushWidth: stroke.brushWidth,
          ),
        );
      }
    }
    return chunks;
  }

  // ── 压缩/编码小工具 ──────────────────────────────────────────────

  static int _zigZag(int value) => (value << 1) ^ (value >> 31);

  static int _unZigZag(int value) => (value >> 1) ^ -(value & 1);

  static Uint32List? _crcTable;

  /// CRC-32（IEEE 802.3，多项式 0xEDB88320）。
  static int crc32(List<int> bytes) {
    final Uint32List table = _crcTable ??= _buildCrcTable();
    int crc = 0xFFFFFFFF;
    for (final int byte in bytes) {
      crc = (crc >> 8) ^ table[(crc ^ byte) & 0xFF];
    }
    return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
  }

  static Uint32List _buildCrcTable() {
    final Uint32List table = Uint32List(256);
    for (int i = 0; i < 256; i++) {
      int c = i;
      for (int k = 0; k < 8; k++) {
        c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
      }
      table[i] = c;
    }
    return table;
  }
}

/// SIF 头里记录的逻辑页面尺寸（pt）。
class SifPageSize {
  const SifPageSize(this.width, this.height);

  final double width;
  final double height;

  bool get isValid =>
      width.isFinite && height.isFinite && width > 0 && height > 0;

  @override
  String toString() => 'SifPageSize($width×$height)';
}

/// 编码失败（页面尺寸非法 / 超过结构上限）。
class SifEncodeException implements Exception {
  const SifEncodeException(this.message);

  final String message;

  @override
  String toString() => 'SifEncodeException: $message';
}

/// 文件损坏（zlib / magic / CRC / 结构任一不合法）。
class SifCorruptException implements Exception {
  const SifCorruptException(this.message);

  final String message;

  @override
  String toString() => 'SifCorruptException: $message';
}

class _Chunk {
  const _Chunk({
    required this.points,
    required this.style,
    required this.colorIndex,
    required this.brushWidth,
  });

  final List<InkPoint> points;
  final InkStrokeStyle style;
  final int colorIndex;
  final int brushWidth;
}

class _Writer {
  final BytesBuilder _builder = BytesBuilder(copy: false);

  void u8(int value) => _builder.addByte(value & 0xFF);

  void u16(int value) {
    _builder.addByte(value & 0xFF);
    _builder.addByte((value >> 8) & 0xFF);
  }

  void u32(int value) {
    _builder.addByte(value & 0xFF);
    _builder.addByte((value >> 8) & 0xFF);
    _builder.addByte((value >> 16) & 0xFF);
    _builder.addByte((value >> 24) & 0xFF);
  }

  void varint(int value) {
    int v = value;
    while (v >= 0x80) {
      _builder.addByte((v & 0x7F) | 0x80);
      v >>= 7;
    }
    _builder.addByte(v & 0x7F);
  }

  void bytes(List<int> values) => _builder.add(values);

  Uint8List takeBytes() => _builder.takeBytes();
}

class _Reader {
  _Reader(this._data, {this.offset = 0});

  final Uint8List _data;
  int offset;

  int get remaining => _data.length - offset;

  void _need(int count) {
    if (remaining < count) {
      throw const SifCorruptException('读取越界');
    }
  }

  int u8() {
    _need(1);
    return _data[offset++];
  }

  int u16() {
    _need(2);
    final int value = _data[offset] | (_data[offset + 1] << 8);
    offset += 2;
    return value;
  }

  int u32() {
    _need(4);
    final int value =
        _data[offset] |
        (_data[offset + 1] << 8) |
        (_data[offset + 2] << 16) |
        (_data[offset + 3] << 24);
    offset += 4;
    return value;
  }

  int varint() {
    int result = 0;
    int shift = 0;
    while (true) {
      _need(1);
      final int byte = _data[offset++];
      result |= (byte & 0x7F) << shift;
      if ((byte & 0x80) == 0) {
        break;
      }
      shift += 7;
      if (shift > 35) {
        throw const SifCorruptException('varint 过长');
      }
    }
    return result;
  }

  void skip(int count) {
    _need(count);
    offset += count;
  }
}
