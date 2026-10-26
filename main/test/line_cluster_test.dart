import 'package:flutter_test/flutter_test.dart';
import 'package:shuaqi/domain/ink/ink_doc.dart';
import 'package:shuaqi/domain/ocr/line_cluster.dart';

InkStroke _stroke(
  String uid,
  double x,
  double y, {
  double width = 20,
  double height = 20,
  InkStrokeStyle style = InkStrokeStyle.pen,
}) {
  return InkStroke(
    uid: uid,
    points: <InkPoint>[
      InkPoint(x: x, y: y),
      InkPoint(x: x + width, y: y + height),
    ],
    style: style,
  );
}

void main() {
  group('clusterInkLines', () {
    test('两行按 y 重心分开，行内按 x 排序', () {
      final List<InkLine> lines = clusterInkLines(<InkStroke>[
        _stroke('a2', 200, 100),
        _stroke('b1', 300, 210),
        _stroke('a1', 100, 100),
        _stroke('b2', 100, 210),
      ]);
      expect(lines.length, 2);
      expect(lines[0].strokes.map((InkStroke s) => s.uid), <String>[
        'a1',
        'a2',
      ]);
      expect(lines[1].strokes.map((InkStroke s) => s.uid), <String>[
        'b2',
        'b1',
      ]);
    });

    test('同一行的小上标（重心差 13）并回本行', () {
      // 行高 20 → 1.2×20=24，阈值 0.6×24=14.4。
      final List<InkLine> lines = clusterInkLines(<InkStroke>[
        _stroke('base', 100, 100, width: 100, height: 20),
        _stroke('sup', 220, 92, width: 10, height: 10),
      ]);
      expect(lines.length, 1);
      expect(lines.single.strokes.map((InkStroke s) => s.uid), <String>[
        'base',
        'sup',
      ]);
    });

    test('荧光笔排除', () {
      final List<InkLine> lines = clusterInkLines(<InkStroke>[
        _stroke('pen', 100, 100),
        _stroke('highlighter', 100, 100, style: InkStrokeStyle.highlighter),
      ]);
      expect(lines.length, 1);
      expect(lines.single.strokes.single.uid, 'pen');
    });

    test('空输入 / 全荧光笔 → 空', () {
      expect(clusterInkLines(const <InkStroke>[]), isEmpty);
      expect(
        clusterInkLines(<InkStroke>[
          _stroke('h', 0, 0, style: InkStrokeStyle.highlighter),
        ]),
        isEmpty,
      );
    });

    test('行包围盒覆盖整行', () {
      final List<InkLine> lines = clusterInkLines(<InkStroke>[
        _stroke('a', 100, 100, width: 20, height: 20),
        _stroke('b', 200, 100, width: 30, height: 20),
      ]);
      final InkRect box = lines.single.bounds;
      expect(box.left, 100);
      expect(box.top, 100);
      expect(box.width, 130);
      expect(box.height, 20);
    });

    test('自定义 lineHeight 可放大/缩小分组阈值', () {
      // 两个重心差 20 的笔画：默认阈值 14.4 → 两行；lineHeight=40 → 阈值 24 → 一行。
      final List<InkStroke> strokes = <InkStroke>[
        _stroke('a', 100, 100, height: 10),
        _stroke('b', 100, 120, height: 10),
      ];
      expect(clusterInkLines(strokes).length, 2);
      expect(clusterInkLines(strokes, lineHeight: 40).length, 1);
    });
  });
}
