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

  // ── 量化档位（T2.2：活笔与死笔共用，抬笔因此不可能跳宽）────────────────

  test('等宽笔刷：任意宽度都归到第 0 档（整笔一条 Path）', () {
    expect(InkWidth.levelOf(InkStrokeStyle.ballpoint, 1.8), 0);
    expect(InkWidth.levelOf(InkStrokeStyle.highlighter, 14), 0);
    expect(InkWidth.widthOfLevel(InkStrokeStyle.ballpoint, 0), 1.8);
    expect(InkWidth.widthOfLevel(InkStrokeStyle.highlighter, 0), 14);
  });

  test('钢笔档位：两端精确落在最小/最大宽度', () {
    expect(
      InkWidth.widthOfLevel(InkStrokeStyle.pen, 0),
      closeTo(InkWidth.penMin, 1e-9),
    );
    expect(
      InkWidth.widthOfLevel(InkStrokeStyle.pen, InkWidth.levels - 1),
      closeTo(InkWidth.penMax, 1e-9),
    );
  });

  test('相邻档宽度差 ≤0.15pt：肉眼与 400dpi 屏都看不出台阶', () {
    for (int level = 1; level < InkWidth.levels; level++) {
      final double step =
          InkWidth.widthOfLevel(InkStrokeStyle.pen, level) -
          InkWidth.widthOfLevel(InkStrokeStyle.pen, level - 1);
      expect(step, lessThanOrEqualTo(0.15));
    }
  });

  test('相邻档吸附：0.05pt 的宽度抖动最多跨一档（不会每帧换 Path）', () {
    for (double w = InkWidth.penMin; w < InkWidth.penMax; w += 0.05) {
      final int delta = InkWidth.levelOf(InkStrokeStyle.pen, w + 0.05) -
          InkWidth.levelOf(InkStrokeStyle.pen, w);
      expect(delta, inInclusiveRange(0, 1), reason: '宽度 $w → ${w + 0.05}');
    }
  });

  test('档位单调：宽度越大档位越高，且夹在 [0, levels)', () {
    int previous = -1;
    for (double w = InkWidth.penMin - 1; w <= InkWidth.penMax + 1; w += 0.05) {
      final int level = InkWidth.levelOf(InkStrokeStyle.pen, w);
      expect(level, greaterThanOrEqualTo(0));
      expect(level, lessThan(InkWidth.levels));
      expect(level, greaterThanOrEqualTo(previous),
          reason: '宽度 $w 的档位回退了（非单调会让同一笔来回换 Path）');
      previous = level;
    }
  });

  test('中性压力 = 区间中值：落笔/抬笔的缺失读数不会让笔突然变粗或变细', () {
    expect(
      InkWidth.forStroke(InkStrokeStyle.pen, InkWidth.neutralPressure),
      closeTo(InkWidth.penMid, 1e-9),
    );
  });
}
