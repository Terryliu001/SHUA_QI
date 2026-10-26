/// 扫描件的**行级**版面分析（纯 Dart，可单测）。
///
/// ## 为什么要有它（2026-10-23 用户拍板"扫描件要做到题级"）
///
/// 034 的 L2 是"按行投影切块"：只认"空白带"，不认行内结构。它有一个天花板——
/// **题与题之间没有额外空行时（紧排卷），纯空白带无从区分**，只能切到小节级
/// （实测 A4 扫描卷 30 块装了 44 道题）。
///
/// 真正的题号要靠 OCR，但本项目当前不许引入新依赖（用户 2026-10-23 决定：
/// "尽可能在现有条件下离线实现"）。退一步看，**题号在字形统计上有很强的指纹**：
///
/// ```text
/// 数字/括号：窄而高的连通域（宽 0.06–0.55em、高 0.35–0.92em、墨占 ≤0.18em²）
/// 汉字：     宽而密的连通域（宽 0.55–1.05em、墨占 ≥0.13em²）
/// 中文序号： 宽扁横画 + 顿号
/// ```
///
/// 旧版只看"短块 + 空白"，把汉字的笔画空隙当成了题号后的空格，误报成灾；
/// 现在行首 token 的形状由 `scan_tokens.dart` 判，本文件只负责"行 + 分栏 +
/// 页眉页脚"。切分策略在 `scan_split.dart`。
///
/// ## 分栏必须先做（第二版才发现的硬伤）
/// 第一版先按行聚、再分栏，结果双栏扫描页被判成单栏：左右两栏共用基线，
/// **同一 y 上两栏都有墨**，行投影会把它们并成一条横跨整页的行。
/// 所以顺序是：像素扫描 → 找纵向空白带（栏间距）→ **逐栏**做行分析。
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:shuaqi/domain/region/region_rect.dart';
import 'package:shuaqi/domain/region/scan_tokens.dart';

/// 一行扫描文字的几何（页面坐标 pt，**没有文字**）。
class ScanLine {
  const ScanLine({
    required this.rect,
    required this.fontSize,
    required this.em,
    required this.column,
    this.leadKind = ScanLeadKind.none,
    this.leadWidth,
    this.leadGap,
  });

  /// 整行包围盒（墨迹范围，**只含本栏**）。
  final RegionRect rect;

  /// 行高（pt）。近似字号，只用于置信度里的"样式一致性"。
  final double fontSize;

  /// 本页字高估计（pt）：所有行高度的中位数。**所有阈值都相对它**，
  /// 这样同一套参数在 100dpi 与 200dpi 的扫描件上都成立（034 的教训）。
  final double em;

  /// 栏序号（单栏恒 0）。
  final int column;

  /// 行首题号的类别（2026-10-23 重做）。`none` = 不像题目开头。
  ///
  /// 旧版只有"块宽 + 空白"两个数，无法区分"题号"与"汉字笔画之间的空隙"；
  /// 现在由 `scan_tokens.dart` 做连通域形状判定，这里只保存结论。
  final ScanLeadKind leadKind;

  /// 题号墨块的宽度（pt）。null = 这一行不像"题号 + 正文"。
  final double? leadWidth;

  /// 题号与后面正文之间的空白（pt）。
  final double? leadGap;

  bool get hasLeadToken => leadKind != ScanLeadKind.none;

  double get top => rect.top;

  double get bottom => rect.bottom;

  double get left => rect.left;

  double get right => rect.right;

  double get width => rect.width;

  double get centerX => rect.centerX;

  @override
  String toString() =>
      'ScanLine(c$column ${rect.top.toStringAsFixed(0)}-${rect.bottom.toStringAsFixed(0)} '
      '${rect.left.toStringAsFixed(0)}..${rect.right.toStringAsFixed(0)}'
      '${hasLeadToken ? ' 题号?${leadWidth!.toStringAsFixed(1)}pt' : ''})';
}

/// 一页的扫描分析结果。
class ScanPage {
  const ScanPage({
    required this.pageIndex,
    required this.width,
    required this.height,
    required this.lines,
  });

  final int pageIndex;

  /// 页面尺寸（pt）。
  final double width;
  final double height;

  /// 按（栏 → y）升序，已剔除页眉页脚、横线与噪点。
  final List<ScanLine> lines;

  bool get isEmpty => lines.isEmpty;

  double get em => lines.isEmpty ? 0 : lines.first.em;

  /// 本页疑似题号的行数。
  int get leadCount => lines.where((ScanLine line) => line.hasLeadToken).length;
}

/// 分析参数。全部是"相对字高 / 行距"的倍数，**不要改成绝对 pt**。
class ScanLineOptions {
  const ScanLineOptions({
    this.inkThreshold = 165,
    this.rowInkRatio = 0.008,
    this.joinGapFactor = 0.6,
    this.minLineFactor = 0.38,
    this.smallWidthRatio = 0.045,
    this.smallHeightFactor = 1.25,
    this.marginBandRatio = 0.05,
    this.shortMarginLineRatio = 0.45,
    this.maxLeadLineHeightFactor = 2.4,
    this.columnInkRatio = 0.02,
    this.columnMinGutterRatio = 0.025,
    this.columnMinGutterPt = 10,
    this.borderTrimRatio = 0.008,
  });

  /// 亮度低于它算"墨"（0 黑 255 白）。扫描件背景发灰，取 165。
  final int inkThreshold;

  /// 一行里暗像素占比低于它算"空白行"。
  final double rowInkRatio;

  /// 行间空白 < 该倍数 × 行距 → 仍算同一行（上下标、离行的符号）。
  final double joinGapFactor;

  /// 行高小于该倍数 × 字高 → 丢弃（横线、表格线、噪点）。
  final double minLineFactor;

  /// 又窄又矮的行丢弃（页码、装订线黑点）。
  final double smallWidthRatio;
  final double smallHeightFactor;

  /// 页眉页脚带的高度占比。
  final double marginBandRatio;

  /// 带内**短于本页内容宽度多少比例**的行整行丢弃（页眉卷名、页脚页码）。
  final double shortMarginLineRatio;

  /// 高过该倍数 × 字高的行不参与"题号"判定（多半是图表、表格被并成一块）。
  final double maxLeadLineHeightFactor;

  /// 一列里"有多少比例的行有墨"低于它就算空白列（栏间距）。
  final double columnInkRatio;

  /// 栏间距的最小宽度（占页宽比例）。
  final double columnMinGutterRatio;

  /// 栏间距的最小宽度（pt，再换算成像素）。
  final double columnMinGutterPt;

  /// 页面四周这一比例内的墨迹不参与行/栏统计。
  ///
  /// 扫描件常带黑边/装订线残影；真机第 1 页右边界有一列黑条，整页每一行都
  /// "有墨"，行距被算成 0，44 行并成 1 行。页面正文边距通常 >5%，
  /// 0.8% 的裁剪不会碰到内容。
  final double borderTrimRatio;
}

/// 一行的原始几何（像素坐标，尚未判题号）。
class _LineBox {
  _LineBox({
    required this.top,
    required this.bottom,
    required this.left,
    required this.right,
    required this.column,
  });

  final int top;
  final int bottom;
  final int left;
  final int right;
  final int column;
}

/// 把一页灰度位图切成"行"，并标出每行行首是否像题号。
///
/// [luma] 长度必须是 `width * height`，值 0（黑）..255（白）。
/// 尺寸单位是 pt，用来把像素映射回页面坐标。
ScanPage analyzeScanPage({
  required Uint8List luma,
  required int width,
  required int height,
  required int pageIndex,
  required double pageWidthPt,
  required double pageHeightPt,
  ScanLineOptions options = const ScanLineOptions(),
}) {
  final ScanPage empty = ScanPage(
    pageIndex: pageIndex,
    width: pageWidthPt,
    height: pageHeightPt,
    lines: const <ScanLine>[],
  );
  if (width <= 0 || height <= 0 || luma.length < width * height) {
    return empty;
  }
  final double sx = pageWidthPt / width;
  final double sy = pageHeightPt / height;
  final int inkLimit = options.inkThreshold;
  // 扫描件四周的装订线/黑边不参与统计（见 borderTrimRatio 说明）。
  final int trimX = math.max(1, (width * options.borderTrimRatio).round());
  final int trimY = math.max(1, (height * options.borderTrimRatio).round());
  final int xStart = trimX;
  final int xEnd = width - trimX;
  final int yStart = trimY;
  final int yEnd = height - trimY;

  // 1) 一次像素扫描：每行暗像素数 + 每一列"有多少行有墨"
  final Int32List rowDark = Int32List(height);
  final Int32List colRows = Int32List(width);
  int inkRowCount = 0;
  for (int y = yStart; y < yEnd; y++) {
    int count = 0;
    final int base = y * width;
    for (int x = xStart; x < xEnd; x++) {
      if (luma[base + x] < inkLimit) {
        count++;
        colRows[x]++;
      }
    }
    rowDark[y] = count;
    if (count > 0) {
      inkRowCount++;
    }
  }

  // 2) 分栏（必须在行分析之前：双栏页左右两栏共用基线，先聚行会并成一条横跨页的行）
  final List<(int, int)> columnXs = _detectColumnBands(
    colRows: colRows,
    inkRowCount: inkRowCount,
    width: width,
    scaleX: sx,
    options: options,
  );

  // 3) 逐栏做行分析
  final List<_LineBox> boxes = <_LineBox>[];
  for (int c = 0; c < columnXs.length; c++) {
    final int x0 = math.max(xStart, columnXs[c].$1);
    final int x1 = math.min(xEnd, columnXs[c].$2);
    if (x1 - x0 < 2) {
      continue;
    }
    // 栏内每行的墨量（只扫这一栏的 x 范围）
    final Int32List colRowDark = Int32List(height);
    for (int y = yStart; y < yEnd; y++) {
      if (rowDark[y] == 0) {
        continue;
      }
      int count = 0;
      final int base = y * width;
      for (int x = x0; x < x1; x++) {
        if (luma[base + x] < inkLimit) {
          count++;
        }
      }
      colRowDark[y] = count;
    }
    final int blankLimit = math.max(
      1,
      ((x1 - x0) * options.rowInkRatio).ceil(),
    );
    // 3a) 连续有墨的行段
    final List<int> bandStarts = <int>[];
    final List<int> bandEnds = <int>[];
    int? start;
    for (int y = 0; y < height; y++) {
      if (colRowDark[y] <= blankLimit) {
        if (start != null) {
          bandEnds.add(y - 1);
          start = null;
        }
        continue;
      }
      if (start == null) {
        start = y;
        bandStarts.add(y);
      }
    }
    if (start != null) {
      bandEnds.add(height - 1);
    }
    if (bandStarts.isEmpty) {
      continue;
    }
    // 3b) 行距 = 行段间空白的**下四分位**（不是中位数）。
    //     一页里段落间距远大于行距，行数少时中位数会被段落间距抬高
    //     （实测 5 行的一页中位数算出 19px，而真实行距是 5px）。
    final List<int> gaps = <int>[];
    for (int i = 1; i < bandStarts.length; i++) {
      gaps.add(bandStarts[i] - bandEnds[i - 1] - 1);
    }
    final double lineGapPx = (gaps.isEmpty ? 6 : _percentile(gaps, 0.25))
        .toDouble();
    final int joinGapPx = math.max(
      1,
      (lineGapPx * options.joinGapFactor).round(),
    );
    // 3c) 合并"同一行"被拆开的行段（上下标、离行的小符号）
    final List<int> lineTops = <int>[];
    final List<int> lineBottoms = <int>[];
    int groupTop = bandStarts.first;
    int groupBottom = bandEnds.first;
    for (int i = 1; i < bandStarts.length; i++) {
      if (bandStarts[i] - groupBottom - 1 < joinGapPx) {
        groupBottom = bandEnds[i];
        continue;
      }
      lineTops.add(groupTop);
      lineBottoms.add(groupBottom);
      groupTop = bandStarts[i];
      groupBottom = bandEnds[i];
    }
    lineTops.add(groupTop);
    lineBottoms.add(groupBottom);
    for (int i = 0; i < lineTops.length; i++) {
      int minX = x1;
      int maxX = -1;
      // 行的左右边界只认"有一定高度的墨迹列"：扫描件的孤立墨点（1–2 像素）
      // 会把行左边界拉到正文左边之外，于是行首第一块变成噪点、题号反而认不出来
      // （真机 A4 卷第 2 页：选项 `C.` 左边一个 1 像素黑点，切出一段假题）。
      final int lineHeight = lineBottoms[i] - lineTops[i] + 1;
      final int minColumnInk = math.max(2, (lineHeight * 0.08).round());
      for (int x = x0; x < x1; x++) {
        int count = 0;
        for (int y = lineTops[i]; y <= lineBottoms[i]; y++) {
          if (luma[y * width + x] < inkLimit) {
            count++;
          }
        }
        if (count < minColumnInk) {
          continue;
        }
        if (x < minX) {
          minX = x;
        }
        maxX = x;
      }
      if (maxX < 0 || maxX - minX < 1) {
        continue;
      }
      boxes.add(
        _LineBox(
          top: lineTops[i],
          bottom: lineBottoms[i],
          left: minX,
          right: maxX,
          column: c,
        ),
      );
    }
  }
  if (boxes.isEmpty) {
    return empty;
  }

  // 4) 本页字高：行高中位数（**不能从合并后的行求**：合并会把"题干 + 下一行"
  //    并成 2 倍高的块，中位数被带偏后所有阈值一起放大，题号就再也认不出来）。
  final double emPx = _medianInt(<int>[
    for (final _LineBox box in boxes) box.bottom - box.top + 1,
  ]).toDouble().clamp(3, 400);

  // 5) 过滤 + 行首短块
  double? contentLeft;
  double? contentRight;
  final List<ScanLine> raw = <ScanLine>[];
  for (final _LineBox box in boxes) {
    final double heightPx = (box.bottom - box.top + 1).toDouble();
    if (heightPx < emPx * options.minLineFactor) {
      continue; // 横线、表格线
    }
    if ((box.right - box.left + 1) < width * options.smallWidthRatio &&
        heightPx < emPx * options.smallHeightFactor) {
      continue; // 又窄又矮：页码、装订线黑点
    }
    final double leftPt = box.left * sx;
    final double rightPt = (box.right + 1) * sx;
    contentLeft = contentLeft == null ? leftPt : math.min(contentLeft, leftPt);
    contentRight = contentRight == null
        ? rightPt
        : math.max(contentRight, rightPt);

    ScanLeadKind leadKind = ScanLeadKind.none;
    double? leadWidth;
    double? leadGap;
    // 太高的行（图表/表格被并成一块）不判题号：它的"行首字"没有意义。
    if (heightPx <= emPx * options.maxLeadLineHeightFactor) {
      final ScanLeadToken? lead = detectScanLead(
        luma: luma,
        width: width,
        height: height,
        inkLimit: inkLimit,
        left: box.left,
        right: box.right,
        top: box.top,
        bottom: box.bottom,
        em: emPx,
      );
      if (lead != null) {
        leadKind = lead.kind;
        leadWidth = lead.width * sx;
        leadGap = lead.gap * sx;
      }
    }
    raw.add(
      ScanLine(
        rect: RegionRect.fromLTRB(
          leftPt,
          box.top * sy,
          rightPt,
          (box.bottom + 1) * sy,
        ),
        fontSize: heightPx * sy,
        em: emPx * sy,
        column: box.column,
        leadKind: leadKind,
        leadWidth: leadWidth,
        leadGap: leadGap,
      ),
    );
  }
  if (raw.isEmpty) {
    return empty;
  }

  // 6) 页眉页脚带里的**短行**整行丢掉（页脚"第2页 共4页"、页眉卷名）。
  //    只丢短行：长行可能是正文的最后一行，丢了会把框截断。
  final double contentWidth =
      (contentRight ?? pageWidthPt) - (contentLeft ?? 0);
  final double band = pageHeightPt * options.marginBandRatio;
  final List<ScanLine> lines = <ScanLine>[];
  for (final ScanLine line in raw) {
    final bool inBand =
        line.rect.centerY < band || line.rect.centerY > pageHeightPt - band;
    if (contentWidth > 0 &&
        inBand &&
        line.width < contentWidth * options.shortMarginLineRatio) {
      continue;
    }
    lines.add(line);
  }
  lines.sort((ScanLine a, ScanLine b) {
    if (a.column != b.column) {
      return a.column.compareTo(b.column);
    }
    return a.top.compareTo(b.top);
  });
  return ScanPage(
    pageIndex: pageIndex,
    width: pageWidthPt,
    height: pageHeightPt,
    lines: lines,
  );
}

/// 找纵向空白带 → 分栏。返回每栏的 `[x0, x1)`（像素）。
///
/// 扫描件的栏间距比文本层更干净：**整页那一列都没有墨**。所以判据是
/// "有多少比例的行在这一列有墨"，而不是文本层那套"行覆盖率"。
List<(int, int)> _detectColumnBands({
  required Int32List colRows,
  required int inkRowCount,
  required int width,
  required double scaleX,
  required ScanLineOptions options,
}) {
  if (width <= 0 || inkRowCount < 8) {
    return <(int, int)>[(0, width)];
  }
  final int blankLimit = math.max(
    1,
    (inkRowCount * options.columnInkRatio).ceil(),
  );
  final double minGutter = math.max(
    width * options.columnMinGutterRatio,
    options.columnMinGutterPt / math.max(0.0001, scaleX),
  );

  int bestStart = -1;
  int bestEnd = -1;
  int i = 0;
  while (i < width) {
    if (colRows[i] > blankLimit) {
      i++;
      continue;
    }
    int j = i;
    while (j < width && colRows[j] <= blankLimit) {
      j++;
    }
    // 只考虑内部空白带：不能贴左边/右边（那是页边距），且要居中
    if (i > width * 0.15 && j < width * 0.85) {
      final double gutterWidth = (j - i).toDouble();
      final double center = (i + j) / 2;
      final bool centered = center > width * 0.35 && center < width * 0.65;
      if (gutterWidth >= minGutter &&
          centered &&
          (bestStart < 0 || gutterWidth > bestEnd - bestStart)) {
        bestStart = i;
        bestEnd = j;
      }
    }
    i = j;
  }
  if (bestStart < 0) {
    return <(int, int)>[(0, width)];
  }
  return <(int, int)>[(0, bestStart), (bestEnd, width)];
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

/// 分位数（[q] 取 0..1）。用于行距：下四分位比中位数抗"段落间距"干扰。
int _percentile(List<int> values, double q) {
  if (values.isEmpty) {
    return 0;
  }
  final List<int> sorted = List<int>.of(values)..sort();
  final int index = ((sorted.length - 1) * q).round().clamp(
    0,
    sorted.length - 1,
  );
  return sorted[index];
}
