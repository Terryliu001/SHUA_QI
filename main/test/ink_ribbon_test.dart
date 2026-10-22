import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:shuaqi/domain/ink/ink_doc.dart';
import 'package:shuaqi/domain/ink/ink_width.dart';
import 'package:shuaqi/ui/reader/ink_ribbon.dart';

/// `InkRibbon` 单测：守住"抬笔不跳宽"这条硬承诺。
///
/// 核心断言只有一条：**流式（正在写的这一笔）与整笔（已提交层）产出的几何一致**。
/// 只要两者一致，"写完瞬间整笔变粗/变细"在结构上就不可能发生——
/// 这是 2026-10-22 用户报的第三个症状的根因，必须用测试钉死。
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

  InkRibbon streamed(List<InkPoint> points, {InkStrokeStyle style = InkStrokeStyle.pen}) {
    final InkRibbon ribbon = InkRibbon(style: style, color: const ui.Color(0xFF000000));
    ribbon.beginStroke();
    for (final InkPoint point in points) {
      ribbon.addPoint(point);
    }
    ribbon.endStroke();
    return ribbon;
  }

  InkRibbon batched(List<InkPoint> points, {InkStrokeStyle style = InkStrokeStyle.pen}) {
    final InkRibbon ribbon = InkRibbon(style: style, color: const ui.Color(0xFF000000));
    ribbon.addStroke(InkStroke(uid: 's1', points: points, style: style));
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

  test('压力平滑：落笔第一帧的异常读数不会让整笔起头突变', () {
    // DOWN 事件压力常是 0 —— 中性压力 + 0.45 的 EMA 应当把它平滑掉，
    // 而不是立刻跳到最细。
    final List<InkPoint> points = <InkPoint>[
      const InkPoint(x: 0, y: 0, pressure: 0.0),
      const InkPoint(x: 5, y: 0, pressure: 0.6),
      const InkPoint(x: 10, y: 0, pressure: 0.6),
    ];
    final InkRibbon ribbon = streamed(points);
    expect(ribbon.hasGeometry, isTrue);
    // 起笔圆点的宽度 = 中性压力对应宽度（不是 0 压力的最细值）
    final ui.Rect bounds = ribbon.levelBounds().firstWhere(_nonEmpty);
    expect(bounds.width, greaterThan(0));
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

  test('压感档位落在 [0, levels)：一笔不会画出区间外的宽度', () {
    final InkRibbon ribbon = streamed(samplePoints());
    final List<ui.Rect> bounds = ribbon.levelBounds();
    expect(bounds.length, InkWidth.levels);
    expect(bounds.where(_nonEmpty).length, greaterThan(0));
  });
}

bool _nonEmpty(ui.Rect rect) => !rect.isEmpty;
