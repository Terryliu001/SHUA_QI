import 'dart:math' as math;

import 'package:shuaqi/domain/ink/ink_doc.dart';

/// 第 4 周 T4.1 的**纯函数基础**：把手写笔画按视觉行聚类。
///
/// 为什么先做这一块：ML Kit / OCR 都要求"一行一张图"。整块丢进去，多行会被
/// 串成一行，准确率明显下降（开发指南 T4.1 的坑）。行聚类不依赖任何引擎，
/// 可以先用单测把几何口径钉死，等引擎接进来时只负责"把行拼成 InkStroke"。
///
/// 规则（与指南 §T4.1 一致）：
/// 1. 每个 stroke 取包围盒与 y 重心；荧光笔排除；
/// 2. 行高估计 = 非零行高 stroke 的高度中位数 × 1.2；
/// 3. 按 y 重心升序；相邻重心差 < 0.6×行高 → 同一行；
/// 4. 行内按 x 升序（阅读顺序）。
///
/// 纯 Dart、无随机、无时间依赖；同一输入两次结果逐条一致。
class InkLine {
  const InkLine({
    required this.strokes,
    required this.bounds,
    required this.centerY,
  });

  /// 行内笔画，已按左边界升序。
  final List<InkStroke> strokes;

  /// 整行的包围盒（页面 pt）。
  final InkRect bounds;

  /// 行重心 y（用于调试/公式行判别）。
  final double centerY;
}

/// 把 [strokes] 聚成视觉行。空输入返回空列表。
List<InkLine> clusterInkLines(
  Iterable<InkStroke> strokes, {
  double? lineHeight,
}) {
  final List<InkStroke> candidates = <InkStroke>[
    for (final InkStroke stroke in strokes)
      if (stroke.points.isNotEmpty && !stroke.excludeFromOcr) stroke,
  ];
  if (candidates.isEmpty) {
    return const <InkLine>[];
  }

  final List<_StrokeBox> boxes =
      <_StrokeBox>[
        for (final InkStroke stroke in candidates) _StrokeBox(stroke),
      ]..sort((_StrokeBox a, _StrokeBox b) {
        final int byY = a.centerY.compareTo(b.centerY);
        return byY != 0 ? byY : a.bounds.left.compareTo(b.bounds.left);
      });

  final double estimated = lineHeight ?? _estimateLineHeight(boxes);
  final double threshold = math.max(4, estimated * 0.6);

  final List<List<_StrokeBox>> groups = <List<_StrokeBox>>[];
  double currentCenter = boxes.first.centerY;
  List<_StrokeBox> current = <_StrokeBox>[boxes.first];
  for (int i = 1; i < boxes.length; i++) {
    final _StrokeBox box = boxes[i];
    if ((box.centerY - currentCenter).abs() <= threshold) {
      current.add(box);
      // 用组内均值做下一轮基准：一行里的上下起伏（上标/下标）不会把后续
      // 笔画越带越偏。
      currentCenter =
          current.fold<double>(
            0,
            (double sum, _StrokeBox b) => sum + b.centerY,
          ) /
          current.length;
    } else {
      groups.add(current);
      current = <_StrokeBox>[box];
      currentCenter = box.centerY;
    }
  }
  groups.add(current);

  return <InkLine>[for (final List<_StrokeBox> group in groups) _toLine(group)];
}

double _estimateLineHeight(List<_StrokeBox> boxes) {
  final List<double> heights = <double>[
    for (final _StrokeBox box in boxes)
      if (box.bounds.height > 0.5) box.bounds.height,
  ];
  if (heights.isEmpty) {
    return 24;
  }
  heights.sort();
  final double median = heights[heights.length ~/ 2];
  // 0.8–4 倍是"正常一行"的合理范围：太小（点）或太大（跨行涂改）不把行高带偏。
  return (median * 1.2).clamp(8, 96);
}

InkLine _toLine(List<_StrokeBox> group) {
  group.sort(
    (_StrokeBox a, _StrokeBox b) => a.bounds.left.compareTo(b.bounds.left),
  );
  double left = group.first.bounds.left;
  double top = group.first.bounds.top;
  double right = group.first.bounds.left + group.first.bounds.width;
  double bottom = group.first.bounds.top + group.first.bounds.height;
  for (final _StrokeBox box in group.skip(1)) {
    left = math.min(left, box.bounds.left);
    top = math.min(top, box.bounds.top);
    right = math.max(right, box.bounds.left + box.bounds.width);
    bottom = math.max(bottom, box.bounds.top + box.bounds.height);
  }
  return InkLine(
    strokes: <InkStroke>[for (final _StrokeBox box in group) box.stroke],
    bounds: InkRect(
      left: left,
      top: top,
      width: math.max(0, right - left),
      height: math.max(0, bottom - top),
    ),
    centerY: (top + bottom) / 2,
  );
}

class _StrokeBox {
  _StrokeBox(this.stroke) : bounds = stroke.bounds;

  final InkStroke stroke;
  final InkRect bounds;

  double get centerY => bounds.top + bounds.height / 2;
}
