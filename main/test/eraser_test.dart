import 'package:flutter_test/flutter_test.dart';
import 'package:shuaqi/domain/ink/eraser.dart';
import 'package:shuaqi/domain/ink/ink_doc.dart';

/// T2.3 橡皮的几何判定（纯 Dart）。
///
/// 阈值是规格写死的 12pt，所以这里也用 12 做边界：**11.9 命中、12.1 不命中**，
/// 免得以后有人"顺手调大一点"把相邻行擦掉。
InkStroke line({
  String uid = 'l',
  List<(double, double)> points = const <(double, double)>[(0, 0), (100, 0)],
  InkStrokeStyle style = InkStrokeStyle.pen,
}) {
  return InkStroke(
    uid: uid,
    style: style,
    points: <InkPoint>[
      for (final (double x, double y) in points) InkPoint(x: x, y: y),
    ],
  );
}

InkPoint at(double x, double y) => InkPoint(x: x, y: y);

void main() {
  group('点命中（笔尖按下去）', () {
    test('距离在 12pt 内命中，刚过 12pt 不命中', () {
      final InkStroke s = line();
      expect(Eraser.hitsPoint(s, at(50, 11.9)), isTrue);
      expect(Eraser.hitsPoint(s, at(50, 12.1)), isFalse);
      // 笔尖在笔画延长线外（但离端点 < 12）也算命中：用户是"擦到笔尖"
      expect(Eraser.hitsPoint(s, at(108, 0)), isTrue);
      expect(Eraser.hitsPoint(s, at(120, 0)), isFalse);
    });

    test('单点笔画（点一下）也能被擦掉', () {
      final InkStroke dot = line(points: <(double, double)>[(30, 30)]);
      expect(Eraser.hitsPoint(dot, at(30, 38)), isTrue);
      expect(Eraser.hitsPoint(dot, at(30, 45)), isFalse);
    });

    test('空笔画永远不命中（坏数据不崩）', () {
      const InkStroke empty = InkStroke(uid: 'e', points: <InkPoint>[]);
      expect(Eraser.hitsPoint(empty, at(0, 0)), isFalse);
      expect(Eraser.hitsSegment(empty, at(0, 0), at(10, 10)), isFalse);
    });
  });

  group('划过即删（橡皮拖动）', () {
    test('橡皮垂直穿过笔画：命中（只看采样点会漏，必须算线段相交）', () {
      final InkStroke s = line(points: <(double, double)>[(0, 0), (200, 0)]);
      // 这两个点本身都离笔画 50pt，但这一划从上方切到下方，穿过了笔画
      expect(Eraser.hitsSegment(s, at(100, -50), at(100, 50)), isTrue);
    });

    test('橡皮与笔画平行且相距 20pt：不命中（不误伤相邻行）', () {
      final InkStroke s = line();
      expect(Eraser.hitsSegment(s, at(0, 20), at(100, 20)), isFalse);
    });

    test('单点笔画被划过时命中', () {
      final InkStroke dot = line(points: <(double, double)>[(50, 50)]);
      expect(Eraser.hitsSegment(dot, at(0, 55), at(100, 55)), isTrue);
    });
  });

  group('整页筛选', () {
    test('只返回被命中的笔画，顺序与 doc 一致，不重复', () {
      final List<InkStroke> strokes = <InkStroke>[
        line(uid: 'a', points: <(double, double)>[(0, 0), (100, 0)]),
        line(uid: 'b', points: <(double, double)>[(0, 100), (100, 100)]),
        line(uid: 'c', points: <(double, double)>[(0, 300), (100, 300)]),
      ];
      final List<InkStroke> hit = Eraser.strokesHit(strokes, null, at(50, 5));
      expect(hit.map((InkStroke s) => s.uid), <String>['a']);
      // 一划同时跨过 a 与 b
      final List<InkStroke> both = Eraser.strokesHit(
        strokes,
        at(0, 50),
        at(0, 105),
      );
      expect(both.map((InkStroke s) => s.uid), <String>['b']);
    });

    test('荧光笔也在可擦范围内（荧光是笔迹，不是图层）', () {
      final InkStroke highlighter = line(
        uid: 'h',
        style: InkStrokeStyle.highlighter,
      );
      expect(Eraser.hitsPoint(highlighter, at(50, 3)), isTrue);
    });
  });
}
