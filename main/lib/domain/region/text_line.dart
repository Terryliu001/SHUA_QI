/// 印刷文字的**行**模型与聚类（纯 Dart，可单测）。
///
/// 为什么必须聚行：pdfrx 的文本片段是"按 PDF 内部排版块"切出来的，实测一份
/// 真实试卷第 1 页有 490 个片段，`12.` 会拆成 `1` / `2` / `.` 三段，还夹着
/// 零宽空白片段。题号正则如果直接跑在片段上，几乎不可能命中。
///
/// 聚类口径（唯一）：
/// 1. 按片段**垂直中心**升序；与当前行中心差 ≤ `tolerance × 行高` 归入该行；
/// 2. 行内按 x 升序拼接，间距超过 `spaceGapRatio × 字号` 时补一个空格；
/// 3. 行字号 = 行内非空片段高度的**中位数**（pdfrx 不给 fontSize，只能用高度近似；
///    取中位数是为了不被个别上下标/括号拉偏）。
library;

import 'dart:math' as math;

import 'package:shuaqi/domain/region/pattern.dart';
import 'package:shuaqi/domain/region/region_rect.dart';

/// 一段印刷文字。坐标是页面坐标 pt（左上原点，y 向下）。
class TextPiece {
  const TextPiece({required this.text, required this.rect, this.fontSize = 0});

  final String text;
  final RegionRect rect;

  /// pt。0 表示未知（调用方没给），聚类时按 [rect] 高度兜底。
  final double fontSize;

  double get height => rect.height;

  /// 用于聚行的字号估计：真实的字号不会小于 1pt，取不到就退回几何高度。
  double get effectiveFontSize => fontSize > 0 ? fontSize : rect.height;

  double get centerY => rect.centerY;

  bool get isBlank => text.trim().isEmpty;

  @override
  String toString() => 'TextPiece("$text" $rect)';
}

/// 一行印刷文字（已把该行的碎片拼成一句）。
class TextLine {
  const TextLine({
    required this.text,
    required this.rect,
    required this.fontSize,
    required this.pieces,
    this.column = 0,
    this.forcedMark,
  });

  /// 拼接后的整行文本（已 trim）。
  final String text;

  /// 整行包围盒。
  final RegionRect rect;

  /// pt，见文件头说明。
  final double fontSize;

  /// 组成这一行的原始片段（按 x 升序）。L2 的"块间距"判断要用。
  final List<TextPiece> pieces;

  /// 栏序号（单栏恒 0）。由 [clusterLines] 的调用方分栏后传入。
  final int column;

  /// **外部给定的题号**（扫描件专用）。
  ///
  /// 扫描件没有文字，题号只能靠版面几何猜（见 `scan_lines.dart`）。猜出来的
  /// "这一行是题目开头"没法写成文本让正则去匹配，就挂在这里：切题时
  /// `forcedMark ?? matchQuestionMark(text)`，其余逻辑（层级、区间、跨页、
  /// 置信度）与文本层完全共用一条路径——这是"少写一套切分算法"的关键。
  final QuestionMark? forcedMark;

  double get top => rect.top;

  double get bottom => rect.bottom;

  double get left => rect.left;

  double get right => rect.right;

  double get centerY => rect.centerY;

  TextLine withColumn(int value) => TextLine(
    text: text,
    rect: rect,
    fontSize: fontSize,
    pieces: pieces,
    column: value,
    forcedMark: forcedMark,
  );

  @override
  String toString() =>
      'TextLine(y=${rect.top.toStringAsFixed(1)} fs=${fontSize.toStringAsFixed(1)} '
      '"${text.length > 28 ? '${text.substring(0, 28)}…' : text}")';
}

/// 片段 → 行。行为等价于"同一条基线上的碎片合并"。
///
/// [tolerance] 取 0.5：实测片段高度即近似字高，0.5 倍字高能容下上下标偏移，
/// 又不会把相邻两行（行距通常 ≥1.2 倍字高）并成一行。
List<TextLine> clusterLines(
  List<TextPiece> pieces, {
  double tolerance = 0.5,
  double spaceGapRatio = 0.8,
  int column = 0,
}) {
  final List<TextPiece> usable = pieces
      .where((TextPiece piece) => !piece.isBlank && !piece.rect.isEmpty)
      .toList(growable: false);
  if (usable.isEmpty) {
    return const <TextLine>[];
  }
  final List<TextPiece> sorted = usable.toList(growable: false)
    ..sort((TextPiece a, TextPiece b) => a.centerY.compareTo(b.centerY));

  final List<_Row> rows = <_Row>[];
  for (final TextPiece piece in sorted) {
    if (rows.isNotEmpty) {
      final _Row last = rows.last;
      // 行高取两者的较大值：一行里混着大小字时，以"更大的那个"为准更容易稳定。
      final double ref = math.max(piece.effectiveFontSize, last.fontSize);
      if ((piece.centerY - last.centerY).abs() <= ref * tolerance) {
        last.add(piece);
        continue;
      }
    }
    rows.add(_Row(piece));
  }

  return rows
      .map(
        (_Row row) => row.toLine(spaceGapRatio: spaceGapRatio, column: column),
      )
      .toList(growable: false);
}

class _Row {
  _Row(TextPiece first)
    : pieces = <TextPiece>[first],
      left = first.rect.left,
      top = first.rect.top,
      right = first.rect.right,
      bottom = first.rect.bottom;

  final List<TextPiece> pieces;
  double left;
  double top;
  double right;
  double bottom;

  double get centerY => (top + bottom) / 2;

  /// 行高：先按外框算，拼行时会用片段高度中位数覆盖。
  double get fontSize => bottom - top;

  void add(TextPiece piece) {
    pieces.add(piece);
    if (piece.rect.left < left) {
      left = piece.rect.left;
    }
    if (piece.rect.top < top) {
      top = piece.rect.top;
    }
    if (piece.rect.right > right) {
      right = piece.rect.right;
    }
    if (piece.rect.bottom > bottom) {
      bottom = piece.rect.bottom;
    }
  }

  TextLine toLine({required double spaceGapRatio, required int column}) {
    final List<TextPiece> ordered = pieces.toList(growable: false)
      ..sort((TextPiece a, TextPiece b) => a.rect.left.compareTo(b.rect.left));
    final double fontSize = _fontSizeOf(ordered);
    final StringBuffer buffer = StringBuffer();
    TextPiece? previous;
    for (final TextPiece piece in ordered) {
      if (previous != null) {
        final double gap = piece.rect.left - previous.rect.right;
        if (gap > fontSize * spaceGapRatio) {
          buffer.write(' ');
        }
      }
      buffer.write(piece.text.trim());
      previous = piece;
    }
    return TextLine(
      text: buffer.toString().trim(),
      rect: RegionRect.fromLTRB(left, top, right, bottom),
      fontSize: fontSize,
      pieces: ordered,
      column: column,
    );
  }

  /// 行字号的估计：片段高度的**下四分位**（不是中位数，也不是最大值）。
  ///
  /// 实测（2026-10-23 真卷）：pdfium 会把多行公式报成一个文本对象，片段的
  /// `bounds.height` 直接等于整个对象的跨度（`设𝑓(𝑥)={…}` 那行片段高度 29.1pt，
  /// 而正文只有 11.6pt）。中位数会被这种"高个子"整体带偏；下四分位只要一行里
  /// 有四分之一的片段是正常正文高度，就能拿到接近真字号的估计。
  static double _fontSizeOf(List<TextPiece> ordered) {
    final List<double> heights =
        ordered
            .map((TextPiece piece) => piece.effectiveFontSize)
            .where((double value) => value > 0)
            .toList(growable: false)
          ..sort();
    if (heights.isEmpty) {
      return 0;
    }
    final int index = ((heights.length - 1) * 0.25).floor();
    return heights[index];
  }
}

/// 页眉/页脚带与页码的剔除（规格 T3.1 第 3 步）。
///
/// 判定用"位置 + 形态"两条，**不要**无脑切掉上下 5%：
/// 密排卷子的第一题常常就压在上边界带里，切了会凭空丢一题。所以：
/// - 在带内但**看着像题号行**（`1.` / `一、` / `（1）`）→ 保留；
/// - 在带内且是页码形态（`12`、`第 3 页`、`3/20`）→ 删；
/// - 在带内且**长得像正文**（>30 字且有句读）→ 保留；
/// - 其余在带内的一律删（页眉卷名、装订线水印这类）。
///
/// 实测依据：真卷页眉 `[分析上期中]2025–2026 学年…期中考试试题`（41 字、无句读）
/// 与页脚水印 `…bump-archive 1/583`（45 字、无句读，但命中页码后缀）都被正确剔除。
List<TextLine> dropMargins(
  List<TextLine> lines, {
  required double pageHeight,
  double bandRatio = 0.05,
  int proseMinChars = 30,
}) {
  if (pageHeight <= 0) {
    return lines;
  }
  final double band = pageHeight * bandRatio;
  return lines
      .where((TextLine line) {
        // 页码形态的行**不管在哪一带**都不是正文：真卷的页脚常常在页面下方 8% 处
        // （下边距比上边距大），只按 5% 带过滤会把它算进最后一道题的区域里。
        if (_pageNumberPattern.hasMatch(line.text) ||
            _tailPageNumber.hasMatch(line.text)) {
          return false;
        }
        final bool inTop = line.centerY < band;
        final bool inBottom = line.centerY > pageHeight - band;
        if (!inTop && !inBottom) {
          return true;
        }
        if (matchQuestionMark(line.text) != null) {
          return true;
        }
        final bool looksLikeProse =
            line.text.length > proseMinChars &&
            _sentencePunctuation.hasMatch(line.text);
        return looksLikeProse;
      })
      .toList(growable: false);
}

/// 句读（不含括号：卷名里常有 `《…（上）》`，用括号判断会把页眉当正文）。
final RegExp _sentencePunctuation = RegExp(r'[，。？！；：]');

final RegExp _pageNumberPattern = RegExp(
  r'^[\s\-—–©第]*('
  r'\d{1,3}'
  r'|第\s*\d{1,3}\s*页([\s，,、/／]*共?[\s]*\d{1,3}\s*页?)?'
  r'|\d{1,3}\s*[/／]\s*\d{1,3}\s*页?'
  r'|page\s*\d{1,3}'
  r')[\s\-—–页]*$',
  caseSensitive: false,
);

/// 行尾是"x/y"页码（水印、装订线、页脚常见的组合形态）。
final RegExp _tailPageNumber = RegExp(r'\d{1,4}\s*[/／]\s*\d{1,4}\s*$');
