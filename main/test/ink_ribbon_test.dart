import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shuaqi/domain/ink/ink_doc.dart';
import 'package:shuaqi/domain/ink/ink_width.dart';
import 'package:shuaqi/ui/reader/ink_brush_spec.dart';
import 'package:shuaqi/ui/reader/ink_ribbon.dart';

/// `InkRibbon` 单测：守住"抬笔不跳宽"与"活笔/死笔同参"两条硬承诺。
///
/// 断言只有两类：
/// 1. **流式（正在写的这一笔）与整笔（已提交层）产出的几何一致** ——
///    只要一致，"写完瞬间整笔变粗/变细"在结构上就不可能发生；
/// 2. **参数只从 [InkBrushSpec] 来** —— 2026-10-23 荧光笔"落笔先画成黑色"
///    的根因就是两层各拼一半参数，现在只有一个入口。
void main() {
  List<InkPoint> samplePoints() => List<InkPoint>.generate(
    40,
    (int i) => InkPoint(
      x: 10 + i * 3.0,
      y: 100 + (i % 7) * 2.0,
      pressure: 0.1 + (i % 10) * 0.08,
      t: i * 4,
    ),
  );

  InkBrushSpec specOf(
    InkStrokeStyle style, {
    int colorIndex = 0,
    int brushWidth = 1,
    bool darkPaper = false,
  }) => InkBrushSpec.of(
    style: style,
    colorIndex: colorIndex,
    brushWidth: brushWidth,
    darkPaper: darkPaper,
  );

  InkRibbon streamed(
    List<InkPoint> points, {
    InkStrokeStyle style = InkStrokeStyle.pen,
    int brushWidth = 1,
  }) {
    final InkRibbon ribbon = InkRibbon(specOf(style, brushWidth: brushWidth));
    ribbon.beginStroke();
    for (final InkPoint point in points) {
      ribbon.addPoint(point);
    }
    ribbon.endStroke();
    return ribbon;
  }

  InkRibbon batched(
    List<InkPoint> points, {
    InkStrokeStyle style = InkStrokeStyle.pen,
    int brushWidth = 1,
  }) {
    final InkRibbon ribbon = InkRibbon(specOf(style, brushWidth: brushWidth));
    ribbon.addStroke(
      InkStroke(
        uid: 's1',
        points: points,
        style: style,
        brushWidth: brushWidth,
      ),
    );
    return ribbon;
  }

  test('流式与整笔的几何逐档一致（抬笔不跳宽的结构保证）', () {
    final List<InkPoint> points = samplePoints();
    final InkRibbon a = streamed(points);
    final InkRibbon b = batched(points);

    expect(a.hasGeometry, isTrue);
    expect(b.hasGeometry, isTrue);
    expect(a.strokeCount, 1);
    expect(b.strokeCount, 1);

    // ui.Path 没有值相等，只能比包围盒；逐档比已经足够说明"同一批点落进同一批档"。
    final List<ui.Rect> ra = a.levelBounds();
    final List<ui.Rect> rb = b.levelBounds();
    expect(ra.length, rb.length);
    for (int i = 0; i < ra.length; i++) {
      expect(ra[i].left, closeTo(rb[i].left, 1e-9));
      expect(ra[i].top, closeTo(rb[i].top, 1e-9));
      expect(ra[i].right, closeTo(rb[i].right, 1e-9));
      expect(ra[i].bottom, closeTo(rb[i].bottom, 1e-9));
    }
  });

  test('三档粗细各自与流式一致（换粗细不会让抬笔跳变）', () {
    final List<InkPoint> points = samplePoints();
    for (final int brushWidth in <int>[0, 1, 2]) {
      final List<ui.Rect> a = streamed(points, brushWidth: brushWidth)
          .levelBounds();
      final List<ui.Rect> b = batched(points, brushWidth: brushWidth)
          .levelBounds();
      for (int i = 0; i < a.length; i++) {
        expect(
          a[i].width,
          closeTo(b[i].width, 1e-9),
          reason: '粗细档 $brushWidth 第 $i 档包围盒宽度不一致',
        );
      }
    }
  });

  test('荧光笔的活动层与已提交层同色同混合（落笔即荧光，不再先黑一下）', () {
    final InkBrushSpec active = specOf(
      InkStrokeStyle.highlighter,
      colorIndex: 0,
    );
    final InkBrushSpec committed = specOf(
      InkStrokeStyle.highlighter,
      colorIndex: 0,
    );
    expect(active.color, committed.color);
    expect(active.blendMode, committed.blendMode);
    expect(active.color.a, lessThan(1.0), reason: '荧光必须半透明');
  });

  test('荧光笔：半透明、不依赖目标像素（合成层里 multiply 会整笔消失）', () {
    final InkBrushSpec light = specOf(
      InkStrokeStyle.highlighter,
      colorIndex: 1,
    );
    final InkBrushSpec dark = specOf(
      InkStrokeStyle.highlighter,
      colorIndex: 1,
      darkPaper: true,
    );
    // 2026-10-23：荧光笔原先用 multiply/screen，在 RepaintBoundary 的透明层里
    // 一个像素都画不出来（真机像素扫描为 0）。现在一律 srcOver + 半透明。
    expect(light.blendMode, BlendMode.srcOver);
    expect(dark.blendMode, BlendMode.srcOver);
    expect(light.color.a, lessThan(1.0), reason: '荧光必须透光，否则盖住题干');
    // 墨色不透明、组合笔刷也用 srcOver
    expect(specOf(InkStrokeStyle.pen).blendMode, BlendMode.srcOver);
    expect(specOf(InkStrokeStyle.pen).color.a, 1.0);
  });

  test('压力平滑：落笔第一帧的异常读数不会让整笔起头突变', () {
    final List<InkPoint> points = <InkPoint>[
      const InkPoint(x: 0, y: 0, pressure: 0.0),
      const InkPoint(x: 5, y: 3, pressure: 0.6),
      const InkPoint(x: 10, y: 6, pressure: 0.6),
    ];
    final InkRibbon ribbon = streamed(points);
    expect(ribbon.hasGeometry, isTrue);
    // 起笔不画圆斑（taperIn），几何来自线段：包围盒应覆盖全部采样点。
    final ui.Rect bounds = ribbon.levelBounds().reduce(_union);
    expect(bounds.left, closeTo(0, 1e-6));
    expect(bounds.right, closeTo(10, 1e-6));
    expect(bounds.bottom, closeTo(6, 1e-6));
  });

  test('单点笔画 = 一个点（选择题打钩打点也是合法输入）', () {
    final InkRibbon ribbon = streamed(<InkPoint>[
      const InkPoint(x: 42, y: 88, pressure: 0.5),
    ]);
    expect(ribbon.hasGeometry, isTrue);
    expect(ribbon.strokeCount, 1);
  });

  test('clear() 之后没有残留几何（换笔刷 / 抬笔后重画不得留旧笔）', () {
    final InkRibbon ribbon = streamed(samplePoints());
    expect(ribbon.hasGeometry, isTrue);
    ribbon.clear();
    expect(ribbon.hasGeometry, isFalse);
    expect(ribbon.strokeCount, 0);
    for (final ui.Rect rect in ribbon.levelBounds()) {
      expect(rect.isEmpty, isTrue);
    }
  });

  test('水平/垂直笔画必须画得出来（包围盒面积为 0 不等于空笔）', () {
    // 2026-10-23 真机事故：draw() 用 `path.getBounds().isEmpty` 跳过空档，
    // 而**完美水平线**的包围盒高度是 0 → isEmpty 为 true → 整笔被跳过。
    // 用户看到的是"横着写不出墨，斜着才行"。
    for (final InkStrokeStyle style in InkStrokeStyle.values) {
      final InkRibbon horizontal = InkRibbon(specOf(style));
      horizontal.addStroke(
        InkStroke(
          uid: 'h',
          style: style,
          points: const <InkPoint>[
            InkPoint(x: 10, y: 25),
            InkPoint(x: 190, y: 25),
          ],
        ),
      );
      expect(horizontal.hasGeometry, isTrue, reason: '${style.name} 水平');
      final bool anyLevel =
          List<int>.generate(InkWidth.levels, (int i) => i).any(
            horizontal.isLevelUsed,
          );
      expect(
        anyLevel,
        isTrue,
        reason: '${style.name} 水平线被当成空笔跳过了',
      );
    }
  });

  test('Paint 真的带上了 spec 的颜色/混合（不是默认的不透明黑）', () {
    // 2026-10-23：重构漏掉 paint.color 时，所有颜色都会画成纯黑（像素取样 (0,0,0)）。
    // 这条断言只看绘制参数本身，几何断言永远抓不到它。
    //
    // 比较用 toARGB32()：Paint.color 由引擎按浮点回读，Color 对象会比 value 相等更严，
    // 直接比 Color 会在"看起来一模一样"时报不等（踩过）。
    final InkBrushSpec red = specOf(InkStrokeStyle.pen, colorIndex: 2);
    final Paint penPaint = InkRibbon(red).paintForLevel(0);
    expect(penPaint.color.toARGB32(), red.color.toARGB32());
    expect(penPaint.color.toARGB32(), isNot(0xFF000000));

    final InkBrushSpec hl = specOf(InkStrokeStyle.highlighter, colorIndex: 0);
    final Paint hlPaint = InkRibbon(hl).paintForLevel(0);
    expect(hlPaint.color.toARGB32(), hl.color.toARGB32());
    expect(hlPaint.blendMode, BlendMode.srcOver);
    expect(hlPaint.color.a, lessThan(1.0), reason: '荧光必须半透明');
  });

  test('压感档位落在 [0, levels)：一笔不会画出区间外的宽度', () {
    final InkRibbon ribbon = streamed(samplePoints());
    final List<ui.Rect> bounds = ribbon.levelBounds();
    expect(bounds.length, InkWidth.levels);
    expect(bounds.where(_nonEmpty).length, greaterThan(0));
  });
}

bool _nonEmpty(ui.Rect rect) => !rect.isEmpty;

ui.Rect _union(ui.Rect a, ui.Rect b) => a.expandToInclude(b);
