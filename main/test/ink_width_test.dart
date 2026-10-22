import 'package:flutter_test/flutter_test.dart';
import 'package:shuaqi/domain/ink/ink_doc.dart';
import 'package:shuaqi/domain/ink/ink_width.dart';

/// `InkWidth` 单测（宿主机秒级）。
///
/// 盯两条：压感区间正确（轻/重分明）、无压感输入不糊不细。
void main() {
  test('钢笔：压感轻 → 细，重 → 粗，单调', () {
    final double light = InkWidth.forStroke(InkStrokeStyle.pen, 0.1);
    final double mid = InkWidth.forStroke(InkStrokeStyle.pen, 0.5);
    final double heavy = InkWidth.forStroke(InkStrokeStyle.pen, 0.95);
    expect(light, closeTo(1.54, 1e-9));
    expect(mid, closeTo(2.9, 1e-9));
    expect(heavy, closeTo(4.43, 1e-9));
    expect(light, lessThan(mid));
    expect(mid, lessThan(heavy));
  });

  test('无压感输入（恒 0 / 恒 1）取中值，不糊不细', () {
    // 鼠标/触摸事件 pressure 恒 1.0；老设备可能给 0。都归到中值。
    expect(InkWidth.forStroke(InkStrokeStyle.pen, 0), InkWidth.penMid);
    expect(InkWidth.forStroke(InkStrokeStyle.pen, 1), InkWidth.penMid);
    expect(InkWidth.penMid, closeTo(2.9, 1e-9));
  });

  test('圆珠笔：等宽', () {
    expect(InkWidth.forStroke(InkStrokeStyle.ballpoint, 0.2), 1.8);
    expect(InkWidth.forStroke(InkStrokeStyle.ballpoint, 0.9), 1.8);
  });

  test('荧光笔：等宽且宽', () {
    expect(InkWidth.forStroke(InkStrokeStyle.highlighter, 0.5), 14);
  });

  test('三笔刷宽度互不相同（视觉可区分，REQ-03）', () {
    final double pen = InkWidth.forStroke(InkStrokeStyle.pen, 0.5);
    final double ball = InkWidth.forStroke(InkStrokeStyle.ballpoint, 0.5);
    final double hl = InkWidth.forStroke(InkStrokeStyle.highlighter, 0.5);
    expect(pen, isNot(ball));
    expect(ball, isNot(hl));
    expect(pen, isNot(hl));
  });
}
