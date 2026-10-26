/// 分栏检测（纯 Dart）。
///
/// 为什么必须有：双栏卷子若不先分栏，左右两栏会被"按 y 聚行"拼成同一行
/// （`1. 求极限（ 2. 求导`），切出来的是一堆横跨两栏的巨框 —— 规格 T3.2 点名的坑。
///
/// ## 做法（第三版，2026-10-23 用合成双栏卷实测后重写）
///
/// 把页面按 1pt 切成 x 分箱，统计**每一箱被多少"文字行"覆盖**：
/// - 不能用"全页并集"（第一版做法）：双栏卷的标题常常**居中横跨栏间距**，
///   只要有一行跨过去，那条空白带就消失了 —— 实测双栏卷因为一行居中标题被判成单栏。
/// - 也不能用"同一行两侧都有字就否掉"（第二版做法，已废弃）：真双栏的两栏
///   共用基线，左右同一 y 上都有字才是常态。
///
/// 现行判据：一箱若被 **≥15% 的文字行**覆盖就算"有字"；一条连续"无字"带
/// 若宽度 ≥ `max(10pt, 页宽×2.5%)`、中心落在页宽 35%–65%、且两侧各自都有
/// ≥12% 的片段与 ≥20% 页宽的横向跨度，就认定为栏间距。
///
/// 为什么 15%：居中标题通常只占 2–3 行（<5%），而真栏间距是"整页都不是字"（0%）。
/// 图注造成的局部空白最多占 30–40% 的行，仍会落在"有字"一侧，不会被误判成栏。
library;

import 'package:shuaqi/domain/region/region_rect.dart';
import 'package:shuaqi/domain/region/text_line.dart';

/// 一栏的横向范围（pt）。`left` 含、`right` 不含。
class ColumnBand {
  const ColumnBand({required this.left, required this.right});

  final double left;
  final double right;

  double get width => right - left;

  bool contains(double x) => x >= left && x < right;

  @override
  String toString() =>
      'ColumnBand(${left.toStringAsFixed(1)}–${right.toStringAsFixed(1)})';
}

/// 一箱被多少比例的行覆盖就算"有字"。
const double _blockedRowShare = 0.15;

/// 行分箱高度（pt）。用垂直中心归箱即可，不需要精确聚行。
const double _rowBinHeight = 8;

/// 检测页面分栏。单栏时返回一个覆盖整页的 [ColumnBand]。
///
/// 只吃"墨迹矩形"：文本层给的是片段矩形，扫描件给的是行矩形——两者都是
/// "一坨字占的地方"，分栏这个几何问题对它们完全一样（2026-10-23 抽象出来，
/// 供扫描件与文本层共用一份实现，避免两套阈值各自漂移）。
List<ColumnBand> detectColumnsFromRects(
  List<RegionRect> rects, {
  required double pageWidth,
  double minGutterRatio = 0.025,
}) {
  final List<ColumnBand> single = <ColumnBand>[
    ColumnBand(left: 0, right: pageWidth),
  ];
  if (pageWidth <= 0 || rects.isEmpty) {
    return single;
  }

  final List<RegionRect> usable = rects
      .where((RegionRect rect) => !rect.isEmpty)
      .toList(growable: false);
  if (usable.length < 6) {
    return single;
  }

  final int bins = pageWidth.ceil();
  final Map<int, List<RegionRect>> rows = <int, List<RegionRect>>{};
  for (final RegionRect rect in usable) {
    final int row = (rect.centerY / _rowBinHeight).floor();
    rows.putIfAbsent(row, () => <RegionRect>[]).add(rect);
  }
  final int rowCount = rows.length;
  if (rowCount < 4) {
    return single;
  }
  final int blockThreshold = (rowCount * _blockedRowShare).ceil();

  final List<int> coveredRows = List<int>.filled(bins, 0);
  final List<bool> touched = List<bool>.filled(bins, false);
  for (final List<RegionRect> row in rows.values) {
    // 同一行里同一个箱子只算一次（一行内多个片段重叠不能重复计数）
    touched.fillRange(0, bins, false);
    for (final RegionRect rect in row) {
      final int from = rect.left.floor().clamp(0, bins - 1);
      final int to = rect.right.ceil().clamp(0, bins);
      for (int i = from; i < to; i++) {
        touched[i] = true;
      }
    }
    for (int i = 0; i < bins; i++) {
      if (touched[i]) {
        coveredRows[i]++;
      }
    }
  }

  final double minGutter = pageWidth * minGutterRatio > 10
      ? pageWidth * minGutterRatio
      : 10;

  // 找最宽的"无字带"，且必须居中、两侧都有料。
  int bestStart = -1;
  int bestEnd = -1;
  int i = 0;
  while (i < bins) {
    if (coveredRows[i] >= blockThreshold) {
      i++;
      continue;
    }
    int j = i;
    while (j < bins && coveredRows[j] < blockThreshold) {
      j++;
    }
    // 只考虑内部空白带：起点不能贴左边、终点不能贴右边。
    if (i > 0 && j < bins) {
      final double width = (j - i).toDouble();
      final double center = (i + j) / 2;
      final bool centered =
          center > pageWidth * 0.35 && center < pageWidth * 0.65;
      if (width >= minGutter && centered) {
        if (bestStart < 0 || (j - i) > (bestEnd - bestStart)) {
          bestStart = i;
          bestEnd = j;
        }
      }
    }
    i = j;
  }
  if (bestStart < 0) {
    return single;
  }

  final double gutterLeft = bestStart.toDouble();
  final double gutterRight = bestEnd.toDouble();
  int leftCount = 0;
  int rightCount = 0;
  double leftMin = double.infinity;
  double leftMax = 0;
  double rightMin = double.infinity;
  double rightMax = 0;
  for (final RegionRect rect in usable) {
    if (rect.right <= gutterLeft) {
      leftCount++;
      if (rect.left < leftMin) {
        leftMin = rect.left;
      }
      if (rect.right > leftMax) {
        leftMax = rect.right;
      }
    } else if (rect.left >= gutterRight) {
      rightCount++;
      if (rect.left < rightMin) {
        rightMin = rect.left;
      }
      if (rect.right > rightMax) {
        rightMax = rect.right;
      }
    }
  }
  final bool enoughLeft = leftCount >= usable.length * 0.12;
  final bool enoughRight = rightCount >= usable.length * 0.12;
  final bool wideEnough =
      (leftMax - leftMin) >= pageWidth * 0.2 &&
      (rightMax - rightMin) >= pageWidth * 0.2;
  if (!enoughLeft || !enoughRight || !wideEnough) {
    return single;
  }

  return <ColumnBand>[
    ColumnBand(left: 0, right: gutterLeft),
    ColumnBand(left: gutterRight, right: pageWidth),
  ];
}

/// 文本层片段的分栏检测（[detectColumnsFromRects] 的片段版本）。
List<ColumnBand> detectColumns(
  List<TextPiece> pieces, {
  required double pageWidth,
  double minGutterRatio = 0.025,
}) {
  final List<RegionRect> rects = <RegionRect>[
    for (final TextPiece piece in pieces)
      if (!piece.isBlank && !piece.rect.isEmpty) piece.rect,
  ];
  return detectColumnsFromRects(
    rects,
    pageWidth: pageWidth,
    minGutterRatio: minGutterRatio,
  );
}

/// 某个横向中心落在第几栏（找不到按第 0 栏）。
int columnIndexOf(double centerX, List<ColumnBand> columns) {
  for (int i = 0; i < columns.length; i++) {
    if (columns[i].contains(centerX)) {
      return i;
    }
  }
  return 0;
}

/// 把片段按栏分组（按片段中心判栏，保持原有顺序）。
List<List<TextPiece>> groupByColumn(
  List<TextPiece> pieces,
  List<ColumnBand> columns,
) {
  final List<List<TextPiece>> groups = List<List<TextPiece>>.generate(
    columns.length,
    (int _) => <TextPiece>[],
    growable: false,
  );
  for (final TextPiece piece in pieces) {
    final double center = piece.rect.centerX;
    int index = 0;
    for (int i = 0; i < columns.length; i++) {
      if (columns[i].contains(center)) {
        index = i;
        break;
      }
    }
    groups[index].add(piece);
  }
  return groups;
}
