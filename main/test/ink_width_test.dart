import 'package:flutter_test/flutter_test.dart';
import 'package:shuaqi/domain/ink/ink_doc.dart';
import 'package:shuaqi/domain/ink/ink_palette.dart';
import 'package:shuaqi/domain/ink/ink_width.dart';

/// `InkWidth` 单测（宿主机秒级）。
///
/// 盯三条：
/// 1. **粗细 0..100 单调**（多级可调的前提）；
/// 2. 压感只调制"这一下按多重"，不改变"这支笔有多粗"的量级；
/// 3. 宽度量化档位（活笔/死笔共用，抬笔不可能跳宽）。
void main() {
  const int thin = 0;
  const int mid = InkStroke.defaultBrushWidth; // 50
  const int bold = 100;

  test('粗细单调：0 < 50 < 100（三支笔都是）', () {
    for (final InkStrokeStyle style in InkStrokeStyle.values) {
      final double a = InkWidth.baseOf(style, thin);
      final double b = InkWidth.baseOf(style, mid);
      final double c = InkWidth.baseOf(style, bold);
      expect(a, lessThan(b), reason: '${style.name} 细 < 中');
      expect(b, lessThan(c), reason: '${style.name} 中 < 粗');
      expect(a, greaterThan(0));
    }
  });

  test('区间与规格同量级：钢笔 0.8–5.2 / 圆珠笔 1–4 / 荧光笔 6–36', () {
    expect(InkWidth.baseOf(InkStrokeStyle.pen, thin), closeTo(0.8, 1e-9));
    expect(InkWidth.baseOf(InkStrokeStyle.pen, bold), closeTo(5.2, 1e-9));
    expect(InkWidth.baseOf(InkStrokeStyle.ballpoint, thin), closeTo(1.0, 1e-9));
    expect(InkWidth.baseOf(InkStrokeStyle.ballpoint, bold), closeTo(4.0, 1e-9));
    expect(
      InkWidth.baseOf(InkStrokeStyle.highlighter, thin),
      closeTo(6, 1e-9),
    );
    expect(
      InkWidth.baseOf(InkStrokeStyle.highlighter, bold),
      closeTo(36, 1e-9),
    );
  });

  test('钢笔：同一粗细下，压感重 → 更粗，压感轻 → 更细', () {
    for (final int width in <int>[thin, mid, bold]) {
      final double light = InkWidth.forStroke(InkStrokeStyle.pen, 0.1, width);
      final double heavy = InkWidth.forStroke(InkStrokeStyle.pen, 0.95, width);
      expect(light, lessThan(heavy));
      // 压感只调制 ±，不能跨过相邻粗细档的量级
      expect(heavy / light, lessThan(2.5));
    }
  });

  test('等宽笔刷不响应压感', () {
    for (final InkStrokeStyle style in <InkStrokeStyle>[
      InkStrokeStyle.ballpoint,
      InkStrokeStyle.highlighter,
    ]) {
      expect(
        InkWidth.forStroke(style, 0.05, mid),
        InkWidth.forStroke(style, 0.99, mid),
      );
    }
  });

  test('粗细越界被夹紧（坏数据不崩、不画出巨笔）', () {
    expect(
      InkWidth.forStroke(InkStrokeStyle.pen, 0.5, 900),
      InkWidth.forStroke(InkStrokeStyle.pen, 0.5, bold),
    );
    expect(
      InkWidth.forStroke(InkStrokeStyle.pen, 0.5, -900),
      InkWidth.forStroke(InkStrokeStyle.pen, 0.5, thin),
    );
    expect(InkWidth.clampBrushWidth(400), 100);
  });

  test('无压感输入（恒 0 / 恒 1）取中性压力对应的宽度', () {
    for (final int width in <int>[thin, mid, bold]) {
      final double expected = InkWidth.midWidth(InkStrokeStyle.pen, width);
      expect(InkWidth.forStroke(InkStrokeStyle.pen, 0, width), expected);
      expect(InkWidth.forStroke(InkStrokeStyle.pen, 1, width), expected);
    }
  });

  test('三笔刷在同档下宽度互不相同（视觉可区分，REQ-03）', () {
    final double pen = InkWidth.forStroke(InkStrokeStyle.pen, 0.5);
    final double ball = InkWidth.forStroke(InkStrokeStyle.ballpoint, 0.5);
    final double hl = InkWidth.forStroke(InkStrokeStyle.highlighter, 0.5);
    expect(pen, isNot(ball));
    expect(ball, isNot(hl));
    expect(pen, isNot(hl));
  });

  // ── 量化档位（活笔与死笔共用，抬笔因此不可能跳宽）────────────────

  test('等宽笔刷：任意宽度都归到第 0 档（整笔一条 Path）', () {
    for (final int width in <int>[thin, mid, bold]) {
      final double w = InkWidth.baseOf(InkStrokeStyle.ballpoint, width);
      expect(InkWidth.levelOf(InkStrokeStyle.ballpoint, w, width), 0);
      expect(InkWidth.widthOfLevel(InkStrokeStyle.ballpoint, 0, width), w);
    }
  });

  test('钢笔档位：两端落在该粗细下的最小/最大宽度', () {
    for (final int width in <int>[thin, mid, bold]) {
      final (double min, double max) = InkWidth.rangeOf(
        InkStrokeStyle.pen,
        width,
      );
      expect(
        InkWidth.widthOfLevel(InkStrokeStyle.pen, 0, width),
        closeTo(min, 1e-9),
      );
      expect(
        InkWidth.widthOfLevel(InkStrokeStyle.pen, InkWidth.levels - 1, width),
        closeTo(max, 1e-9),
      );
    }
  });

  test('相邻档位单调且夹在 [0, levels)（宽度抖动最多跨一档）', () {
    final (double min, double max) = InkWidth.rangeOf(InkStrokeStyle.pen, mid);
    int previous = -1;
    for (double w = min - 1; w <= max + 1; w += 0.02) {
      final int level = InkWidth.levelOf(InkStrokeStyle.pen, w, mid);
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

  // ── 调色板 ────────────────────────────────────────────────────────

  test('调色板：每支笔的颜色数量与索引收敛', () {
    expect(InkPalette.countFor(InkStrokeStyle.pen), 6);
    expect(InkPalette.countFor(InkStrokeStyle.ballpoint), 6);
    expect(InkPalette.countFor(InkStrokeStyle.highlighter), 4);
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

  test('调色板：0 号是墨黑，夜读纸上变暖白（老数据默认值必须仍是墨黑）', () {
    expect(
      InkPalette.argb(
        style: InkStrokeStyle.pen,
        index: 0,
        darkPaper: false,
      ),
      0xFF14161A,
    );
    expect(
      InkPalette.argb(style: InkStrokeStyle.pen, index: 0, darkPaper: true),
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
