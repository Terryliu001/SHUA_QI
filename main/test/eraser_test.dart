import 'package:flutter_test/flutter_test.dart';
import 'package:shuaqi/domain/ink/eraser.dart';
import 'package:shuaqi/domain/ink/ink_doc.dart';

/// 局部擦除的几何测试（纯 Dart）。
///
/// 这是"擦到哪删到哪"的核心：一条折线被橡皮圆盘覆盖的区间要被切掉，
/// 剩下的**碎片**必须是新笔画，且几何上接得上（缺口宽度 ≈ 橡皮直径）。
///
/// 断言口径：
/// - 没碰到 → `null`（调用方跳过，不触发重建）；
/// - 擦光 → 空列表；
/// - 擦中间 → 2 段，两段的断口分别贴着擦除圆的两侧边界（误差 < 0.01pt）。
void main() {
  int seq = 0;
  String newUid() => 'f${seq++}';

  InkPoint at(double x, double y) => InkPoint(x: x, y: y);

  /// 一条从 (0,0) 到 (100,0) 的水平线，点距 10。
  InkStroke horizontal({double y = 0, double x0 = 0, double x1 = 100}) {
    final List<InkPoint> points = <InkPoint>[];
    for (double x = x0; x <= x1; x += 10) {
      points.add(InkPoint(x: x, y: y));
    }
    return InkStroke(uid: 'h', points: points);
  }

  group('没碰到', () {
    test('橡皮在笔画上方很远处 → null（不触发重建）', () {
      final List<InkStroke>? result = Eraser.carve(
        stroke: horizontal(),
        eraserPath: <InkPoint>[at(50, 40)],
        radius: 12,
        newUid: newUid,
      );
      expect(result, isNull);
    });

    test('空笔画 / 空路径 → null（坏数据不崩）', () {
      const InkStroke empty = InkStroke(uid: 'e', points: <InkPoint>[]);
      expect(
        Eraser.carve(
          stroke: empty,
          eraserPath: <InkPoint>[at(0, 0)],
          radius: 12,
          newUid: newUid,
        ),
        isNull,
      );
      expect(
        Eraser.carve(
          stroke: horizontal(),
          eraserPath: const <InkPoint>[],
          radius: 12,
          newUid: newUid,
        ),
        isNull,
      );
    });
  });

  group('局部擦除（关键行为）', () {
    test('擦中间 → 切成两段，缺口 = 橡皮直径', () {
      final List<InkStroke>? result = Eraser.carve(
        stroke: horizontal(),
        eraserPath: <InkPoint>[at(50, 0)],
        radius: 10,
        newUid: newUid,
      );
      expect(result, isNotNull);
      expect(result!.length, 2, reason: '一笔擦中间应当变成两笔');
      expect(result[0].points.first.x, closeTo(0, 1e-9));
      expect(result[1].points.last.x, closeTo(100, 1e-9));
      final double leftEnd = result[0].points.last.x;
      final double rightStart = result[1].points.first.x;
      expect(leftEnd, closeTo(40, 0.01));
      expect(rightStart, closeTo(60, 0.01));
      expect(rightStart - leftEnd, closeTo(20, 0.02));
    });

    test('擦端头 → 只剩一段（另一头没了）', () {
      final List<InkStroke>? result = Eraser.carve(
        stroke: horizontal(),
        eraserPath: <InkPoint>[at(100, 0)],
        radius: 10,
        newUid: newUid,
      );
      expect(result, isNotNull);
      expect(result!.length, 1);
      expect(result.single.points.first.x, closeTo(0, 1e-9));
      expect(result.single.points.last.x, closeTo(90, 0.01));
    });

    test('一划扫过整条 → 空列表（整笔擦光）', () {
      final List<InkStroke>? result = Eraser.carve(
        stroke: horizontal(x0: 0, x1: 100),
        eraserPath: <InkPoint>[at(-20, 0), at(120, 0)],
        radius: 12,
        newUid: newUid,
      );
      expect(result, isNotNull);
      expect(result, isEmpty);
    });

    test('碎片继承原笔的样式/颜色/粗细（擦一半不该换色变粗）', () {
      final InkStroke source = InkStroke(
        uid: 's',
        points: horizontal().points,
        style: InkStrokeStyle.highlighter,
        colorIndex: 2,
        brushWidth: 2,
      );
      final List<InkStroke>? result = Eraser.carve(
        stroke: source,
        eraserPath: <InkPoint>[at(50, 0)],
        radius: 10,
        newUid: newUid,
      );
      expect(result, isNotNull);
      for (final InkStroke fragment in result!) {
        expect(fragment.style, InkStrokeStyle.highlighter);
        expect(fragment.colorIndex, 2);
        expect(fragment.brushWidth, 2);
        expect(fragment.uid, isNot('s'), reason: '碎片必须换新 uid');
      }
    });

    test('碎片之间有真实的点（每段 ≥2 点，能画出线）', () {
      final List<InkStroke>? result = Eraser.carve(
        stroke: horizontal(),
        eraserPath: <InkPoint>[at(30, 0)],
        radius: 8,
        newUid: newUid,
      );
      expect(result, isNotNull);
      for (final InkStroke fragment in result!) {
        expect(fragment.points.length, greaterThanOrEqualTo(2));
      }
    });

    test('单点笔画（点一下）：圆内擦掉，圆外不动', () {
      const InkStroke dot = InkStroke(
        uid: 'd',
        points: <InkPoint>[InkPoint(x: 10, y: 10)],
      );
      expect(
        Eraser.carve(
          stroke: dot,
          eraserPath: <InkPoint>[at(12, 10)],
          radius: 5,
          newUid: newUid,
        ),
        isEmpty,
      );
      expect(
        Eraser.carve(
          stroke: dot,
          eraserPath: <InkPoint>[at(40, 40)],
          radius: 5,
          newUid: newUid,
        ),
        isNull,
      );
    });

    test('斜着画的一笔：碎片不会落进橡皮圆内', () {
      final InkStroke diagonal = InkStroke(
        uid: 'diag',
        points: <InkPoint>[
          for (int i = 0; i <= 20; i++) InkPoint(x: i * 5.0, y: i * 5.0),
        ],
      );
      final List<InkStroke>? result = Eraser.carve(
        stroke: diagonal,
        eraserPath: <InkPoint>[at(50, 50)],
        radius: 10,
        newUid: newUid,
      );
      expect(result, isNotNull);
      expect(result!.length, 2);
      for (final InkStroke fragment in result) {
        for (final InkPoint p in fragment.points) {
          final double dx = p.x - 50;
          final double dy = p.y - 50;
          expect(
            dx * dx + dy * dy,
            greaterThan(10 * 10 - 1),
            reason: '碎片不该落在橡皮圆内',
          );
        }
      }
    });

    test('橡皮是一段路径（拖动）：按整条覆盖切，不只切最后一个点', () {
      // 竖着一笔 x=50；橡皮横着划过去
      final InkStroke vertical = InkStroke(
        uid: 'v',
        points: <InkPoint>[
          for (int i = -10; i <= 10; i++) InkPoint(x: 50, y: i * 10.0),
        ],
      );
      final List<InkStroke>? result = Eraser.carve(
        stroke: vertical,
        eraserPath: <InkPoint>[at(0, 0), at(100, 0)],
        radius: 12,
        newUid: newUid,
      );
      expect(result, isNotNull);
      expect(result!.length, 2, reason: '横划竖笔应当切成上下两段');
      expect(result[0].points.last.y, closeTo(-12, 0.5));
      expect(result[1].points.first.y, closeTo(12, 0.5));
    });
  });

  group('橡皮大小（0..100 多级）', () {
    test('半径随粗细单调、越界夹紧、中间档接近规格 12pt', () {
      expect(Eraser.radiusOfWidth(0), Eraser.minRadius);
      expect(Eraser.radiusOfWidth(100), Eraser.maxRadius);
      expect(
        Eraser.radiusOfWidth(0),
        lessThan(Eraser.radiusOfWidth(50)),
      );
      expect(
        Eraser.radiusOfWidth(50),
        lessThan(Eraser.radiusOfWidth(100)),
      );
      // 越界不抛，夹到两端
      expect(Eraser.radiusOfWidth(-40), Eraser.minRadius);
      expect(Eraser.radiusOfWidth(400), Eraser.maxRadius);
      // 中档（50）落在 16pt 左右，与旧"三档"的中档 12–22 同量级
      expect(Eraser.radiusOfWidth(50), closeTo(16, 0.5));
    });

    test('粗档擦掉的缺口比细档宽（大小真的生效）', () {
      double gapOf(int width) {
        final List<InkStroke>? result = Eraser.carve(
          stroke: horizontal(),
          eraserPath: <InkPoint>[at(50, 0)],
          radius: Eraser.radiusOfWidth(width),
          newUid: newUid,
        );
        expect(result, isNotNull);
        return result![1].points.first.x - result[0].points.last.x;
      }

      expect(gapOf(0), lessThan(gapOf(50)));
      expect(gapOf(50), lessThan(gapOf(100)));
    });
  });

  group('包围盒预筛', () {
    test('相隔很远的笔画直接跳过（5000 笔的页不能每条都求交）', () {
      final InkStroke far = horizontal(y: 500);
      expect(
        Eraser.mayTouch(far, at(0, 0), at(100, 0), radius: 12),
        isFalse,
      );
      expect(
        Eraser.mayTouch(horizontal(), at(0, 0), at(100, 0), radius: 12),
        isTrue,
      );
    });
  });
}
