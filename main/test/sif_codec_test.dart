import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shuaqi/domain/ink/ink_doc.dart';
import 'package:shuaqi/domain/ink/sif_codec.dart';

/// SIF v1 的编解码回归（T2.4）。
///
/// 重点不是"能往返"，而是：**点数/坐标/压力/款式不丢、体积可控、
/// 任何损坏都必须变成 SifCorruptException（绝不让半截数据进画布）**。
void main() {
  const SifPageSize a4 = SifPageSize(595.276, 841.89);

  InkStroke stroke(
    int index, {
    int points = 8,
    InkStrokeStyle style = InkStrokeStyle.pen,
    int color = 0,
    int width = 50,
  }) {
    return InkStroke(
      uid: 'u$index',
      style: style,
      colorIndex: color,
      brushWidth: width,
      points: <InkPoint>[
        for (int i = 0; i < points; i++)
          InkPoint(
            x: 20 + (index % 20) * 25 + i * 0.7,
            y: 30 + (index ~/ 20) * 12 + i * 0.9,
            pressure: 0.1 + (i % 10) / 11,
            t: 1000 + index * 20 + i,
          ),
      ],
    );
  }

  test('往返：款式 / 颜色 / 粗细 / 坐标 / 压力 / t0 都不丢', () {
    final InkDoc doc = InkDoc(
      revision: 3,
      strokes: <InkStroke>[
        stroke(0),
        stroke(1, style: InkStrokeStyle.ballpoint, color: 3, width: 10),
        stroke(2, style: InkStrokeStyle.highlighter, color: 4, width: 90),
      ],
    );
    final InkDoc decoded = SifCodec.decode(SifCodec.encode(doc, a4));

    expect(decoded.strokeCount, 3);
    for (int i = 0; i < 3; i++) {
      final InkStroke a = doc.strokes[i];
      final InkStroke b = decoded.strokes[i];
      expect(b.style, a.style);
      expect(b.colorIndex, a.colorIndex);
      expect(b.brushWidth, a.brushWidth);
      expect(b.pointCount, a.pointCount);
      expect(b.points.first.t, a.points.first.t, reason: 't0 要保留');
      for (int j = 0; j < a.points.length; j++) {
        expect((b.points[j].x - a.points[j].x).abs(), lessThan(0.04));
        expect((b.points[j].y - a.points[j].y).abs(), lessThan(0.04));
        expect(
          (b.points[j].pressure - a.points[j].pressure).abs(),
          lessThan(0.04),
        );
      }
    }
  });

  test('空页也能编码/解码（擦光后仍要能落盘）', () {
    final Uint8List bytes = SifCodec.encode(InkDoc.empty, a4);
    expect(bytes, isNotEmpty);
    expect(SifCodec.decode(bytes).isEmpty, isTrue);
  });

  test('单页 5000 笔 ≤400KB（规格 T2.4 验收线）', () {
    final InkDoc doc = InkDoc(
      revision: 0,
      strokes: <InkStroke>[
        for (int i = 0; i < 5000; i++) stroke(i, points: 24),
      ],
    );
    final Uint8List bytes = SifCodec.encode(doc, a4);
    // ignore: avoid_print
    print('SIF 5000 strokes = ${bytes.length} bytes');
    expect(bytes.length, lessThanOrEqualTo(400 * 1024));
    expect(SifCodec.decode(bytes).strokeCount, 5000);
  });

  test('超过 4096 点的笔拆成多笔，点数总量不丢', () {
    final InkStroke longStroke = InkStroke(
      uid: 'long',
      points: <InkPoint>[
        for (int i = 0; i < 4096 * 2 + 10; i++)
          InkPoint(x: i * 0.05, y: i * 0.03, pressure: 0.6),
      ],
    );
    final InkDoc decoded = SifCodec.decode(
      SifCodec.encode(InkDoc(revision: 0, strokes: <InkStroke>[longStroke]), a4),
    );
    expect(decoded.strokeCount, 3);
    expect(
      decoded.pointCount,
      longStroke.pointCount,
      reason: '拆分只能改笔画边界，不能丢点',
    );
    expect(decoded.strokes.map((InkStroke s) => s.uid).toSet().length, 3);
  });

  test('CRC 被破坏：明确抛 SifCorruptException', () {
    final Uint8List bytes = SifCodec.encode(
      InkDoc(revision: 0, strokes: <InkStroke>[stroke(0)]),
      a4,
    );
    final Uint8List raw = Uint8List.fromList(
      const ZLibDecoder().decodeBytes(bytes),
    );
    // 改 body 中间一个字节（不碰 magic），再压回去 → CRC 必不对。
    raw[raw.length - 8] ^= 0xFF;
    final Uint8List tampered = const ZLibEncoder().encodeBytes(raw);
    expect(
      () => SifCodec.decode(tampered),
      throwsA(isA<SifCorruptException>()),
    );
  });

  test('截断 / 乱码：不崩溃，抛 SifCorruptException', () {
    final Uint8List bytes = SifCodec.encode(
      InkDoc(revision: 0, strokes: <InkStroke>[stroke(0)]),
      a4,
    );
    expect(
      () => SifCodec.decode(Uint8List.sublistView(bytes, 0, bytes.length ~/ 2)),
      throwsA(isA<SifCorruptException>()),
    );
    expect(
      () => SifCodec.decode(Uint8List.fromList(<int>[1, 2, 3, 4, 5, 6, 7, 8])),
      throwsA(isA<SifCorruptException>()),
    );
  });

  test('负增量（来回写）与边界坐标往返正确', () {
    const InkStroke zigzag = InkStroke(
      uid: 'zz',
      points: <InkPoint>[
        InkPoint(x: 500, y: 800, pressure: 0.9),
        InkPoint(x: 10, y: 5, pressure: 0.2),
        InkPoint(x: 590, y: 835, pressure: 1),
        InkPoint(x: 0, y: 0, pressure: 0),
      ],
    );
    final InkStroke decoded = SifCodec.decode(
      SifCodec.encode(
        const InkDoc(revision: 0, strokes: <InkStroke>[zigzag]),
        a4,
      ),
    ).strokes.single;
    expect(decoded.points[0].x, closeTo(500, 0.05));
    expect(decoded.points[1].x, closeTo(10, 0.05));
    expect(decoded.points[2].y, closeTo(835, 0.05));
    expect(decoded.points[3].x, 0);
    expect(decoded.points[3].y, 0);
  });
}
