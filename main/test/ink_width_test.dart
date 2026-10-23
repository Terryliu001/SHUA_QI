import 'package:flutter_test/flutter_test.dart';
import 'package:shuaqi/domain/ink/ink_doc.dart';
import 'package:shuaqi/domain/ink/ink_palette.dart';
import 'package:shuaqi/domain/ink/ink_width.dart';

/// `InkWidth` 单测（宿主机秒级）。
///
/// 盯三条：三档粗细各自正确、压感区间随档位缩放、无压感输入不糊不细。
void main() {
  test('钢笔：压感轻 → 细，重 → 粗，单调', () {
    final double light = InkWidth.forStroke(InkStrokeStyle.pen, 0.1);
    final double mid = InkWidth.forStroke(InkStrokeStyle.pen, 0.5);
    final double heavy = InkWidth.forStroke(InkStrokeStyle.pen, 0.95);
    // 中档区间 1.2–3.2
    expect(light, closeTo(1.4, 1e-9));
    expect(mid, closeTo(2.2, 1e-9));
    expect(heavy, closeTo(3.1, 1e-9));
    expect(light, lessThan(mid));
    expect(mid, lessThan(heavy));
  });

  test('三档粗细：细 < 中 < 粗，且都在合理区间', () {
    for (final InkStrokeStyle style in InkStrokeStyle.values) {
      final double fine = InkWidth.forStroke(style, 0.5, 0);
      final double normal = InkWidth.forStroke(style, 0.5, 1);
      final double bold = InkWidth.forStroke(style, 0.5, 2);
      expect(fine, lessThan(normal), reason: '${style.name} 细档应小于中档');
      expect(normal, lessThan(bold), reason: '${style.name} 中档应小于粗档');
    }
    // 规格值：圆珠笔 1.6 / 2.4 / 3.2，荧光笔 12 / 18 / 24
    expect(InkWidth.forStroke(InkStrokeStyle.ballpoint, 0.5, 0), 1.6);
    expect(InkWidth.forStroke(InkStrokeStyle.ballpoint, 0.5, 1), 2.4);
    expect(InkWidth.forStroke(InkStrokeStyle.ballpoint, 0.5, 2), 3.2);
    expect(InkWidth.forStroke(InkStrokeStyle.highlighter, 0.5, 0), 12);
    expect(InkWidth.forStroke(InkStrokeStyle.highlighter, 0.5, 1), 18);
    expect(InkWidth.forStroke(InkStrokeStyle.highlighter, 0.5, 2), 24);
  });

  test('粗细档越界被收敛（坏数据不崩、不画出巨笔）', () {
    expect(
      InkWidth.forStroke(InkStrokeStyle.pen, 0.5, 9),
      InkWidth.forStroke(InkStrokeStyle.pen, 0.5, 2),
    );
    expect(InkWidth.forStroke(InkStrokeStyle.pen, 0.5, -3), InkWidth.forStroke(
      InkStrokeStyle.pen,
      0.5,
      0,
    ));
  });

  test('无压感输入（恒 0 / 恒 1）取中值，不糊不细', () {
    for (int level = 0; level < InkStroke.widthLevels; level++) {
      final double mid = InkWidth.penMid(level);
      expect(InkWidth.forStroke(InkStrokeStyle.pen, 0, level), mid);
      expect(InkWidth.forStroke(InkStrokeStyle.pen, 1, level), mid);
    }
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
    expect(InkWidth.levelOf(InkStrokeStyle.ballpoint, 2.4), 0);
    expect(InkWidth.levelOf(InkStrokeStyle.highlighter, 18), 0);
    expect(InkWidth.widthOfLevel(InkStrokeStyle.ballpoint, 0), 2.4);
    expect(InkWidth.widthOfLevel(InkStrokeStyle.highlighter, 0), 18);
  });

  test('钢笔档位：两端精确落在该档的最小/最大宽度', () {
    final (double min, double max) = InkWidth.rangeOf(InkStrokeStyle.pen, 1);
    expect(
      InkWidth.widthOfLevel(InkStrokeStyle.pen, 0),
      closeTo(min, 1e-9),
    );
    expect(
      InkWidth.widthOfLevel(InkStrokeStyle.pen, InkWidth.levels - 1),
      closeTo(max, 1e-9),
    );
  });

  test('相邻档宽度差 ≤0.15pt：肉眼与 400dpi 屏都看不出台阶', () {
    for (final int widthLevel in <int>[0, 1, 2]) {
      for (int level = 1; level < InkWidth.levels; level++) {
        final double step =
            InkWidth.widthOfLevel(InkStrokeStyle.pen, level, widthLevel) -
            InkWidth.widthOfLevel(InkStrokeStyle.pen, level - 1, widthLevel);
        expect(step, lessThanOrEqualTo(0.15));
      }
    }
  });

  test('相邻档吸附：0.05pt 的宽度抖动最多跨一档（不会每帧换 Path）', () {
    final (double min, double max) = InkWidth.rangeOf(InkStrokeStyle.pen, 1);
    for (double w = min; w < max; w += 0.05) {
      final int delta = InkWidth.levelOf(InkStrokeStyle.pen, w + 0.05) -
          InkWidth.levelOf(InkStrokeStyle.pen, w);
      expect(delta, inInclusiveRange(0, 1), reason: '宽度 $w → ${w + 0.05}');
    }
  });

  test('档位单调：宽度越大档位越高，且夹在 [0, levels)', () {
    final (double min, double max) = InkWidth.rangeOf(InkStrokeStyle.pen, 1);
    int previous = -1;
    for (double w = min - 1; w <= max + 1; w += 0.05) {
      final int level = InkWidth.levelOf(InkStrokeStyle.pen, w);
      expect(level, greaterThanOrEqualTo(0));
      expect(level, lessThan(InkWidth.levels));
      expect(
        level,
        greaterThanOrEqualTo(previous),
        reason: '宽度 $w 的档位回退了（非单调会让同一笔来回换 Path）',
      );
      previous = level;
    }
  });

  test('中性压力 = 区间中值：落笔/抬笔的缺失读数不会让笔突然变粗或变细', () {
    expect(
      InkWidth.forStroke(InkStrokeStyle.pen, InkWidth.neutralPressure),
      closeTo(InkWidth.penMid(), 1e-9),
    );
  });

  test('调色板：每支笔的颜色数量与索引收敛', () {
    expect(InkPalette.countFor(InkStrokeStyle.pen), 6);
    expect(InkPalette.countFor(InkStrokeStyle.ballpoint), 6);
    expect(InkPalette.countFor(InkStrokeStyle.highlighter), 4);
    // 越界一律收敛到 0（回落墨黑），绝不抛
    expect(
      InkPalette.argb(
        style: InkStrokeStyle.pen,
        index: 99,
        darkPaper: false,
      ),
      InkPalette.penOnLight.last,
    );
    expect(InkPalette.clampIndex(InkStrokeStyle.highlighter, 9), 3);
  });

  test('调色板：0 号是墨黑（老数据默认值必须仍是墨黑）', () {
    expect(
      InkPalette.argb(
        style: InkStrokeStyle.pen,
        index: 0,
        darkPaper: false,
      ),
      0xFF14161A,
    );
    // 夜读纸上 0 号是暖白（暗纸上墨黑不可见）
    expect(
      InkPalette.argb(
        style: InkStrokeStyle.pen,
        index: 0,
        darkPaper: true,
      ),
      0xFFE9E3D5,
    );
  });

  test('调色板：亮纸/暗纸两套表长度一致（缺一个索引就是运行时崩溃）', () {
    expect(InkPalette.penOnLight.length, InkPalette.penOnDark.length);
    expect(
      InkPalette.highlighterOnLight.length,
      InkPalette.highlighterOnDark.length,
    );
  });
}
