/// 纯版面切块（L2 的"无 OCR"分支，纯 Dart，可单测）。
///
/// ## 为什么需要它
/// 扫描件没有文本层，L1 的"题号正则"没有任何原料 —— 实测一份 4 页扫描卷
/// `runs = 0`，切题结果 0 道题，整卷等于不可用。
///
/// 规格 T3.3 原本让扫描件走引擎 B（PP-OCR）拿文本框，但引擎 B 还没接（T0.3/T0.5 未启动）。
/// 在那之前，用**像素投影**就能给出"大致可用"的框：
/// 1. 灰度后按行统计"暗像素占比"，占比低的行 = 空白行；
/// 2. 连续空白行够高 = 分隔带，把页面切成若干**块**；
/// 3. 每块再算横向的墨迹范围，得到一个矩形。
///
/// 这不是"识别题目"，只是"切块"：一份扫描卷切出 8 块、其中 6 块正好是题，
/// 用户就只改 2 处，比"0 个框"好得多。置信度按规格 −0.20（来源是版面推断）。
///
/// ## 为什么把像素处理放在 domain
/// 它是纯计算（输入一段灰度字节 + 宽高，输出的是一堆矩形），没有任何 IO 与 Flutter 依赖，
/// 放在这里才能用合成位图做单测（真机拿不到稳定的扫描件样本）。
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:shuaqi/domain/region/region_rect.dart';

/// 一块版面区域（页面坐标 pt）。
class LayoutBlock {
  const LayoutBlock({required this.rect, required this.darkRatio});

  final RegionRect rect;

  /// 块内暗像素占比（0..1）。用来判断"这块是不是真有内容"。
  final double darkRatio;

  @override
  String toString() =>
      'LayoutBlock(${rect.top.toStringAsFixed(0)}-${rect.bottom.toStringAsFixed(0)} '
      '墨 ${(darkRatio * 100).toStringAsFixed(1)}%)';
}

/// 检测参数。默认值是按 A4 扫描件（正文 10–12pt、行距 1.5）调的，
/// 偏保守：宁可把相邻两题并成一块（用户拆一刀），也不要切出一堆碎框。
class LayoutBlockOptions {
  const LayoutBlockOptions({
    this.inkThreshold = 165,
    this.rowInkRatio = 0.010,
    this.separatorFactor = 1.35,
    this.minBlockFactor = 0.9,
    this.mergeShortFactor = 2.4,
    this.mergeGapFactor = 2.6,
    this.padRatio = 0.004,
    this.maxBlocks = 60,
  });

  /// 亮度低于它算"墨"（0 黑 255 白）。扫描件背景发灰，取 165 而不是 128。
  final int inkThreshold;

  /// 一行里暗像素占比低于它算"空白行"（1% ≈ 一行 6 个字里不到 1 个字）。
  final double rowInkRatio;

  /// 多宽的空白算"题与题"：**典型行间距的多少倍**。
  ///
  /// 不再用固定 pt、也不用"占页高比例"——两者都被真机数据否掉了：
  /// 同一份 A4 卷扫描成 200dpi 后页面是 2384pt 高（A4 的 2.8 倍），
  /// 固定 10pt 在它上面只等于行内空白（一页切 25 块）；
  /// 改成占页高比例后又把 A4 卷切得过粗（4 页只剩 13 块）。
  ///
  /// 真正稳定的口径是"**和这份卷子自己的行距比**"：行距 ≤ 1.35 倍算同一题内部，
  /// ≥ 1.35 倍算换题。行距从本页所有空白带的**中位数**估出来（绝大多数空白都是行距）。
  ///
  /// 为什么是 1.35 而不是 1.8：真卷里"题与题"的间距常常只有 1.5 倍行距
  /// （紧排卷子，选项与下一题只隔半行），1.8 倍门槛切不开，4 页只剩 13 块、
  /// 一块装了 8 道题。宁可在题内多切一刀（短块会被并回去），也不要漏切。
  final double separatorFactor;

  /// 多矮的块直接丢（页眉线、装饰线、页码残影）：行高的多少倍。
  final double minBlockFactor;

  /// 多矮的块算"上一题的尾巴"（选项行、公式续行）：行高的多少倍。
  final double mergeShortFactor;

  /// 尾巴与上一题的间距上限：行间距的多少倍。
  ///
  /// 必须**大于** [separatorFactor]（切块门槛），否则"先切出来再并回去"永远不可能发生
  /// ——这条约束是第一版写成 1.5 时留下的死角（合并规则成了死代码）。
  final double mergeGapFactor;

  /// 块四周外扩（占页高比例）。
  final double padRatio;

  /// 单页最多产出多少块（防止整页图片被切成上百条）。
  final int maxBlocks;
}

/// 从灰度位图切出若干块（按从上到下的顺序）。
///
/// [luma] 长度必须是 `width * height`，值 0（黑）..255（白）。
/// 尺寸单位是 pt，用来把像素行映射回页面坐标。
///
/// 两遍：先扫出所有"连续有墨"的原始行段，用它们的空白带中位数**估出本页行距**，
/// 再按"1.8 倍行距"切块。这样同一套参数在 100dpi 与 200dpi 的扫描件上都成立。
List<LayoutBlock> detectLayoutBlocks({
  required Uint8List luma,
  required int width,
  required int height,
  required double pageWidthPt,
  required double pageHeightPt,
  LayoutBlockOptions options = const LayoutBlockOptions(),
}) {
  if (width <= 0 || height <= 0 || luma.length < width * height) {
    return const <LayoutBlock>[];
  }
  final double scaleY = pageHeightPt / height;
  final double scaleX = pageWidthPt / width;
  final int inkLimit = options.inkThreshold;
  final double padPt = pageHeightPt * options.padRatio;

  // 1) 每行的暗像素数、以及该行墨迹的左右边界
  final Int32List rowDark = Int32List(height);
  final Int32List rowMinX = Int32List(height);
  final Int32List rowMaxX = Int32List(height);
  for (int y = 0; y < height; y++) {
    int count = 0;
    int minX = width;
    int maxX = -1;
    final int base = y * width;
    for (int x = 0; x < width; x++) {
      if (luma[base + x] < inkLimit) {
        count++;
        if (x < minX) {
          minX = x;
        }
        maxX = x;
      }
    }
    rowDark[y] = count;
    rowMinX[y] = minX;
    rowMaxX[y] = maxX;
  }

  final int blankThreshold = (width * options.rowInkRatio).ceil();
  bool isBlank(int y) => rowDark[y] <= blankThreshold;

  // 2) 第一遍：把所有"连续有墨"的行段扫出来，并统计空白带长度
  final List<int> runStarts = <int>[];
  final List<int> runEnds = <int>[];
  final List<int> gaps = <int>[];
  int? runStart;
  for (int y = 0; y < height; y++) {
    if (isBlank(y)) {
      if (runStart != null) {
        runEnds.add(y - 1);
        runStart = null;
      }
      continue;
    }
    if (runStart == null) {
      if (runEnds.isNotEmpty) {
        gaps.add(y - runEnds.last - 1);
      }
      runStart = y;
      runStarts.add(y);
    }
  }
  if (runStart != null) {
    runEnds.add(height - 1);
  }
  if (runStarts.isEmpty) {
    return const <LayoutBlock>[];
  }

  // 3) 估本页行距：空白带中位数（绝大多数空白都是行距；题间距是少数）
  final double lineGapPx = gaps.isEmpty ? 6 : _medianInt(gaps).toDouble();
  // 行高：行段高度的中位数，用来判断"这块是不是只有一行"
  final List<int> runHeights = <int>[
    for (int i = 0; i < runStarts.length; i++) runEnds[i] - runStarts[i] + 1,
  ];
  final double lineHeightPx = _medianInt(runHeights).toDouble().clamp(2, 200);

  final int minGapRows = math.max(
    2,
    (lineGapPx * options.separatorFactor).round(),
  );
  final double minBlockPt = lineHeightPx * options.minBlockFactor * scaleY;
  final double mergeShortPt = lineHeightPx * options.mergeShortFactor * scaleY;
  final double mergeGapPt = lineGapPx * options.mergeGapFactor * scaleY;

  // 4) 第二遍：按"够宽的空隙"把行段聚成块
  final List<LayoutBlock> blocks = <LayoutBlock>[];
  bool lastWasMerged = false;
  int groupStart = runStarts.first;
  int groupEnd = runEnds.first;

  void flush() {
    final double topPt = groupStart * scaleY - padPt;
    final double bottomPt = (groupEnd + 1) * scaleY + padPt;
    final double heightPt = bottomPt - topPt;
    if (heightPt < minBlockPt) {
      return;
    }
    int minX = width;
    int maxX = -1;
    int dark = 0;
    for (int y = groupStart; y <= groupEnd; y++) {
      if (rowMinX[y] < minX) {
        minX = rowMinX[y];
      }
      if (rowMaxX[y] > maxX) {
        maxX = rowMaxX[y];
      }
      dark += rowDark[y];
    }
    if (maxX < 0) {
      return;
    }
    final double left = (minX * scaleX - padPt).clamp(0, pageWidthPt);
    final double right = ((maxX + 1) * scaleX + padPt).clamp(0, pageWidthPt);
    // 又窄又矮的块丢掉：页码、装订线小黑点这类"不是正文"的东西
    // （真卷页脚只有一个"2"，宽度不到页宽 5%，高度也就一行）。
    if (right - left < pageWidthPt * 0.05 &&
        heightPt < lineHeightPx * scaleY * 1.6) {
      return;
    }
    if (right - left <= 1) {
      return;
    }
    final RegionRect rect = RegionRect.fromLTRB(
      left,
      topPt.clamp(0, pageHeightPt),
      right,
      bottomPt.clamp(0, pageHeightPt),
    );
    final double ratio = dark / ((groupEnd - groupStart + 1) * width);
    // 短块并入上一块（选项行、公式续行）；**只并一次**，否则会级联吃成整页一块。
    if (blocks.isNotEmpty &&
        !lastWasMerged &&
        heightPt < mergeShortPt &&
        rect.top - blocks.last.rect.bottom < mergeGapPt) {
      final LayoutBlock previous = blocks.removeLast();
      blocks.add(
        LayoutBlock(
          rect: RegionRect.fromLTRB(
            math.min(previous.rect.left, rect.left),
            previous.rect.top,
            math.max(previous.rect.right, rect.right),
            rect.bottom,
          ),
          darkRatio: (previous.darkRatio + ratio) / 2,
        ),
      );
      lastWasMerged = true;
    } else {
      blocks.add(LayoutBlock(rect: rect, darkRatio: ratio));
      lastWasMerged = false;
    }
  }

  for (int i = 1; i < runStarts.length; i++) {
    final int gap = runStarts[i] - groupEnd - 1;
    if (gap >= minGapRows) {
      flush();
      groupStart = runStarts[i];
    }
    groupEnd = runEnds[i];
  }
  flush();

  if (blocks.length <= options.maxBlocks) {
    return blocks;
  }
  return _mergeToLimit(blocks, options.maxBlocks);
}

int _medianInt(List<int> values) {
  if (values.isEmpty) {
    return 0;
  }
  final List<int> sorted = List<int>.of(values)..sort();
  final int mid = sorted.length ~/ 2;
  return sorted.length.isOdd
      ? sorted[mid]
      : ((sorted[mid - 1] + sorted[mid]) / 2).round();
}

/// 块数超限时，把最矮的相邻两块并起来，直到不超过 [limit]。
List<LayoutBlock> _mergeToLimit(List<LayoutBlock> blocks, int limit) {
  final List<LayoutBlock> merged = List<LayoutBlock>.of(blocks);
  while (merged.length > limit) {
    int bestIndex = 0;
    double bestHeight = double.infinity;
    for (int i = 0; i < merged.length - 1; i++) {
      final double height = merged[i].rect.height + merged[i + 1].rect.height;
      if (height < bestHeight) {
        bestHeight = height;
        bestIndex = i;
      }
    }
    final LayoutBlock a = merged[bestIndex];
    final LayoutBlock b = merged[bestIndex + 1];
    merged.replaceRange(bestIndex, bestIndex + 2, <LayoutBlock>[
      LayoutBlock(
        rect: RegionRect.fromLTRB(
          a.rect.left < b.rect.left ? a.rect.left : b.rect.left,
          a.rect.top,
          a.rect.right > b.rect.right ? a.rect.right : b.rect.right,
          b.rect.bottom,
        ),
        darkRatio: (a.darkRatio + b.darkRatio) / 2,
      ),
    ]);
  }
  return merged;
}

/// BGRA 裸像素 → 灰度（BT.601 亮度）。pdfrx 的 `PdfImage.pixels` 就是 BGRA。
///
/// 抽成纯函数是为了能在宿主机单测：给 4 个像素就能验颜色通道顺序。
Uint8List bgraToLuma(Uint8List bgra, int pixelCount) {
  final Uint8List luma = Uint8List(pixelCount);
  final int limit = pixelCount * 4;
  for (int i = 0; i < pixelCount; i++) {
    final int at = i * 4;
    if (at + 2 >= limit) {
      break;
    }
    final int b = bgra[at];
    final int g = bgra[at + 1];
    final int r = bgra[at + 2];
    luma[i] = ((r * 299 + g * 587 + b * 114) ~/ 1000).clamp(0, 255);
  }
  return luma;
}
