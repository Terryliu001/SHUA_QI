/// 扫描件的**行首题号**结构化识别（纯 Dart，可单测）。
///
/// ## 为什么不能只看"短块 + 空白"
///
/// 034/035 的第一版把"行首有一段短墨、后面有一块空白"当成题号指纹。它在
/// 合成位图上成立，但在真扫描卷上到处误判：**汉字的笔画本身是断开的**，
/// `习` `小` `川` 这些字的内部空隙与题号后的空格一样宽；于是每一个以汉字
/// 开头的续行都会被当成题号（真机实测：一页 11 道题切出 10 段，其中 3 段
/// 是上一题的续行，同时漏掉 4 道题）。
///
/// ## 本文件的判据：看"第一个字"的连通域形状
///
/// 题号与正文的第一个字在**字形统计**上差别很大，且与字体无关：
///
/// | 形态 | 宽 / 字高 | 高 / 字高 | 墨占字高² | 例子 |
/// |---|---|---|---|---|
/// | 数字 / 括号 | 0.06–0.55 | 0.35–0.92 | 低（≤0.18） | `9` `1` `0` `（` `）` |
/// | 汉字 | 0.55–1.05 | 0.60–1.00 | 高（通常 >0.18） | `中` `国` `习` |
/// | 句中标点 | ≤0.50 | ≤0.32 | 很低 | `.` `、` `,` |
/// | 横画（中文序号） | ≥0.55 | ≤0.42 | 低 | `一` `二` |
///
/// 流程：**连通域 → 只让"窄高块"或"横画"开头的行进入候选 → 再看行首 token
/// 的右端是不是小数点 / 顿号 / 右括号**。汉字开头的行在第一关就被否掉，
/// 不再依赖"块宽是否离群"这种全卷统计（那种统计一旦被误报污染就整体失准）。
///
/// 三条硬约束（都是真机反复踩出来的）：
/// 1. **小数点必须保留**：一个小数点只有 3×4 像素，旧版按"与行主体重叠 ≥35%"
///    过滤会把它当噪声丢掉，导致 `9.` 永远认不成"数字 + 小数点"。
/// 2. **不要把 `13` 合并成一个字**：两个数字之间的 3–5px 空隙与汉字内部笔画
///    一样宽；一旦合并，宽高比 >1.05，就会被判成汉字（真机第 13 题因此消失）。
/// 3. **题号后面必须还有正文**：只有一个孤零零的编号的行是页码/装饰。
library;

import 'dart:math' as math;
import 'dart:typed_data';

/// 行首题号的类别。`none` = 这一行不像题目开头。
enum ScanLeadKind {
  /// 认不出（正文续行、选项行、普通文字）。
  none,

  /// `1.` `12、` `3．`（数字 + 点/顿号）。
  arabic,

  /// `（1）` `(3)` `【例5】`（括号包起来的编号）。
  paren,

  /// `一、` `二．`（中文序号，通常是**小节标题**而不是小题）。
  cn,
}

/// 一行行首的题号几何（像素坐标）。
class ScanLeadToken {
  const ScanLeadToken({
    required this.kind,
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
    required this.gap,
    required this.pieces,
    required this.firstPieceWidth,
    required this.firstPieceHeight,
  });

  final ScanLeadKind kind;

  /// 题号包围盒（像素）。
  final double left;
  final double top;
  final double right;
  final double bottom;

  /// 题号与后面正文之间的空白（像素）。
  final double gap;

  /// 组成题号的连通域数（`9.` = 2，`10.` = 3，`（1）` = 3）。
  final int pieces;

  /// 第一个连通域的宽/高（像素，调试用）。
  final double firstPieceWidth;
  final double firstPieceHeight;

  double get width => right - left;

  @override
  String toString() =>
      'ScanLeadToken(${kind.name} ${width.toStringAsFixed(1)}×'
      '${(bottom - top).toStringAsFixed(1)} gap=${gap.toStringAsFixed(1)} '
      'pieces=$pieces)';
}

/// 一个连通域（行内）。
class _Piece {
  const _Piece({
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
    required this.area,
  });

  final int left;
  final int top;
  final int right;
  final int bottom;
  final int area;

  double get width => (right - left + 1).toDouble();
  double get height => (bottom - top + 1).toDouble();
}

enum _Shape {
  /// 窄高块：数字、括号、竖笔画。
  narrow,

  /// 句点、顿号、逗号。
  small,

  /// 宽扁横画：`一`、`二` 的上横、破折号。
  wide,

  /// 汉字 / 字母 / 其他成片墨迹。
  text,
}

/// 识别一行行首的题号。不像题号返回 null。
///
/// [left]/[right]/[top]/[bottom] 是这一行的墨迹包围盒（像素），
/// [em] 是本页字高（像素）。窗口只扫行首 3.4 个字高——再宽就不可能是题号。
ScanLeadToken? detectScanLead({
  required Uint8List luma,
  required int width,
  required int height,
  required int left,
  required int right,
  required int top,
  required int bottom,
  required double em,
  required int inkLimit,
}) {
  if (em <= 1 || right <= left || bottom <= top) {
    return null;
  }
  final int windowRight = math.min(
    right,
    left + math.max(10, (em * 3.4).ceil()),
  );
  final List<_Piece> pieces = _pieces(
    luma: luma,
    width: width,
    height: height,
    left: left,
    right: windowRight,
    top: top,
    bottom: bottom,
    inkLimit: inkLimit,
    em: em,
  );
  if (pieces.isEmpty) {
    return null;
  }

  // 允许跳过行首的装饰性小点（扫描装订孔、噪点）；不跳过汉字。
  int start = 0;
  while (start < pieces.length) {
    final _Shape shape = _shapeOf(pieces[start], em);
    if (shape == _Shape.small && pieces[start].area < 16) {
      start++;
      continue;
    }
    break;
  }
  if (start >= pieces.length) {
    return null;
  }
  final _Shape firstShape = _shapeOf(pieces[start], em);
  if (firstShape == _Shape.text) {
    // 汉字开头：可能是正文续行，也可能是 `二、` `三、` `四、` 这类小节标题。
    // 标题的形态是"一个汉字 + **中文顿号**（宽扁）+ 整行很短"；选项 `A.` 的
    // 句点是圆点（宽度只有顿号的一半），靠这个宽度差区分。
    final ScanLeadToken? heading = _cnHeading(
      pieces: pieces,
      start: start,
      em: em,
      lineRight: right,
      lineWidth: (right - left).toDouble(),
      lineHeight: (bottom - top + 1).toDouble(),
      pageWidth: width.toDouble(),
    );
    if (heading != null) {
      return heading;
    }
    return null; // 正文续行或选项 A/B/C/D
  }

  int end = start;
  bool openBracket = firstShape == _Shape.narrow;
  bool sawInner = false;
  if (firstShape == _Shape.wide) {
    // `一、`：横画 + 顿号。只收两个连通域。
    if (start + 1 < pieces.length &&
        pieces[start + 1].left - pieces[start].right - 1 <= em * 0.5 &&
        _shapeOf(pieces[start + 1], em) == _Shape.small) {
      end = start + 1;
    } else {
      return null;
    }
  } else {
    while (end + 1 < pieces.length) {
      final double gap = pieces[end + 1].left - pieces[end].right - 1;
      if (gap > em * 0.32) {
        break;
      }
      final _Shape next = _shapeOf(pieces[end + 1], em);
      if (next == _Shape.small) {
        // 小数点 / 顿号 / 逗号：题号到这儿就结束了。**必须立刻停**：
        // 后面紧跟的 `（` 或 `求` 是正文，继续吞会把 token 拉宽成"括号题号"。
        end++;
        break;
      }
      if (next == _Shape.text) {
        // 正文（汉字/字母）：token 到此为止。
        //
        // 这里**不**允许"括号里的汉字"继续吞（`【例5】`）：`（1）` 内层是数字，
        // 不需要它；而放宽这条会让"数字 + 汉字"的续行被误当成括号题号
        // （真机第 1 页 `中国特色社会主义…` 就这么被切成假题）。
        break;
      }
      if (next == _Shape.wide) {
        break;
      }
      if (next == _Shape.narrow) {
        // 已经收过一个内层块，再遇到窄块 = 右括号；`（ ）` 这种空括号也一样。
        if (openBracket && (sawInner || end > start)) {
          end++;
          openBracket = false;
          break;
        }
        end++;
        sawInner = true;
        if (end - start >= 4) {
          break;
        }
        continue;
      }
      end++;
      if (end - start >= 5) {
        break;
      }
    }
  }

  final _Piece first = pieces[start];
  final _Piece last = pieces[end];
  final double tokenLeft = first.left.toDouble();
  final double tokenRight = last.right.toDouble();
  final double tokenWidth = tokenRight - tokenLeft + 1;
  if (tokenWidth < em * 0.18 || tokenWidth > em * 3.2) {
    return null;
  }

  // 题号后面必须还有正文（只有编号的行是页码/装饰）。
  if (end + 1 >= pieces.length) {
    return null;
  }
  final double gap = pieces[end + 1].left - tokenRight - 1;
  final double restWidth = right - tokenRight;
  if (restWidth < em * 1.2) {
    return null;
  }

  final _Shape lastShape = _shapeOf(last, em);
  final bool lastSmall = lastShape == _Shape.small;
  final bool lastNarrow = lastShape == _Shape.narrow;

  ScanLeadKind kind = ScanLeadKind.none;
  if (firstShape == _Shape.wide) {
    if (lastSmall && tokenWidth <= em * 2.6) {
      kind = ScanLeadKind.cn;
    }
  } else if (firstShape == _Shape.narrow &&
      lastSmall &&
      tokenWidth <= em * 1.9) {
    // `9.` `12、`
    kind = ScanLeadKind.arabic;
  } else if (firstShape == _Shape.narrow &&
      lastNarrow &&
      tokenWidth >= em * 1.2 &&
      tokenWidth <= em * 3.2) {
    // `（1）` `【例5】`：至少 1.2 个字高宽。0.8 会把正文里一对空括号
    // `（ ）` 也当成题号（真机 A4 卷：第 4 页 5 道简答题因此全被升级成"大题"）。
    kind = ScanLeadKind.paren;
  }
  if (kind == ScanLeadKind.none) {
    return null;
  }
  if (kind == ScanLeadKind.cn && gap < em * 0.25) {
    return null;
  }
  return ScanLeadToken(
    kind: kind,
    left: tokenLeft,
    top: first.top.toDouble(),
    right: tokenRight,
    bottom: last.bottom.toDouble(),
    gap: gap,
    pieces: end - start + 1,
    firstPieceWidth: first.width,
    firstPieceHeight: first.height,
  );
}

/// `二、` `三、` `四、` 这类中文序号标题（小节标题，不是小题）。
///
/// 判据全部来自真卷：
/// - 首块是**汉字**（宽 0.5–1.3em、墨占 ≥0.15em²）；选项 `A.` 的 A 墨占只有
///   ≈0.12em²，被这条挡住；
/// - 分隔符必须是**中文顿号**（宽 ≥0.18em）；选项的句点只有 ≈0.12em；
/// - 整行短（<65% 页宽）且行高接近正文（≤1.6em），排除表格/材料段。
///
/// 为什么不要求"居中"：真卷（北邮期末）的小节标题是**左缩进 2 个字**，
/// 和选项的缩进几乎一样；居中会把它们全部漏掉。
ScanLeadToken? _cnHeading({
  required List<_Piece> pieces,
  required int start,
  required double em,
  required int lineRight,
  required double lineWidth,
  required double lineHeight,
  required double pageWidth,
}) {
  if (lineHeight > em * 1.6 || lineWidth > pageWidth * 0.65) {
    return null;
  }
  final _Piece first = pieces[start];
  if (first.width < em * 0.6 ||
      first.width > em * 1.3 ||
      first.height < em * 0.55 ||
      first.area / (em * em) < 0.15) {
    return null;
  }
  if (start + 2 >= pieces.length) {
    return null;
  }
  final _Piece second = pieces[start + 1];
  if (second.left - first.right - 1 > em * 0.45) {
    return null;
  }
  if (_shapeOf(second, em) != _Shape.small) {
    return null;
  }
  if (second.width < em * 0.18 || second.height > em * 0.35) {
    return null; // 句点（圆点）比顿号窄
  }
  final double tokenLeft = first.left.toDouble();
  final double tokenRight = second.right.toDouble();
  final double tokenWidth = tokenRight - tokenLeft + 1;
  if (tokenWidth > em * 2.6) {
    return null;
  }
  if (lineRight - tokenRight < em * 1.2) {
    return null;
  }
  return ScanLeadToken(
    kind: ScanLeadKind.cn,
    left: tokenLeft,
    top: first.top.toDouble(),
    right: tokenRight,
    bottom: second.bottom.toDouble(),
    gap: pieces[start + 2].left - tokenRight - 1,
    pieces: 2,
    firstPieceWidth: first.width,
    firstPieceHeight: first.height,
  );
}

/// 像素连通域（8 邻接）。只扫行首窗口，行级调用，窗口很小（约 120×40）。
List<_Piece> _pieces({
  required Uint8List luma,
  required int width,
  required int height,
  required int left,
  required int right,
  required int top,
  required int bottom,
  required int inkLimit,
  required double em,
}) {
  final int w = right - left;
  final int h = bottom - top + 1;
  if (w <= 0 || h <= 0) {
    return <_Piece>[];
  }
  final Uint8List visited = Uint8List(w * h);
  final List<_Piece> out = <_Piece>[];
  final Int32List stack = Int32List(w * h);
  for (int y = 0; y < h; y++) {
    final int row = (top + y) * width + left;
    for (int x = 0; x < w; x++) {
      final int index = y * w + x;
      if (visited[index] != 0 || luma[row + x] >= inkLimit) {
        continue;
      }
      int sp = 0;
      stack[sp++] = index;
      visited[index] = 1;
      int minX = x;
      int maxX = x;
      int minY = y;
      int maxY = y;
      int area = 0;
      while (sp > 0) {
        final int current = stack[--sp];
        final int cy = current ~/ w;
        final int cx = current - cy * w;
        area++;
        if (cx < minX) {
          minX = cx;
        }
        if (cx > maxX) {
          maxX = cx;
        }
        if (cy < minY) {
          minY = cy;
        }
        if (cy > maxY) {
          maxY = cy;
        }
        for (int dy = -1; dy <= 1; dy++) {
          final int ny = cy + dy;
          if (ny < 0 || ny >= h) {
            continue;
          }
          for (int dx = -1; dx <= 1; dx++) {
            final int nx = cx + dx;
            if (nx < 0 || nx >= w) {
              continue;
            }
            final int next = ny * w + nx;
            if (visited[next] != 0 ||
                luma[(top + ny) * width + left + nx] >= inkLimit) {
              continue;
            }
            visited[next] = 1;
            stack[sp++] = next;
          }
        }
      }
      final int px0 = left + minX;
      final int px1 = left + maxX;
      final int py0 = top + minY;
      final int py1 = top + maxY;
      // 只保留"大部分落在本行里"的连通域；小数点虽然矮，但整颗都在行内，
      // 所以不会被这条规则误杀（旧版按"与行主体重叠 ≥35%"会丢掉它）。
      final double overlap =
          math.min(py1, bottom).toDouble() - math.max(py0, top).toDouble() + 1;
      if (overlap < (py1 - py0 + 1) * 0.6) {
        continue;
      }
      // 噪点：1–2 像素的孤立墨点。
      if (area < 3 && (px1 - px0 + 1) < 2) {
        continue;
      }
      out.add(_Piece(left: px0, top: py0, right: px1, bottom: py1, area: area));
    }
  }
  out.sort((_Piece a, _Piece b) => a.left.compareTo(b.left));
  // 同一个字被扫描噪声拆成几块时，它们的包围盒会**重叠**（真机第 3 题：
  // `3` 被拆成 4×5 与 11×20 两块，左边界相同）。不合并的话，排序后可能先拿到
  // 那块 4×5 的碎片，token 在它身上就结束了，宽度只有 4px → 整题消失。
  final List<_Piece> merged = <_Piece>[];
  for (final _Piece piece in out) {
    if (merged.isEmpty) {
      merged.add(piece);
      continue;
    }
    final _Piece last = merged.last;
    if (piece.left <= last.right) {
      merged[merged.length - 1] = _Piece(
        left: math.min(last.left, piece.left),
        top: math.min(last.top, piece.top),
        right: math.max(last.right, piece.right),
        bottom: math.max(last.bottom, piece.bottom),
        area: last.area + piece.area,
      );
    } else {
      merged.add(piece);
    }
  }
  return merged;
}

_Shape _shapeOf(_Piece piece, double em) {
  final double w = piece.width / em;
  final double h = piece.height / em;
  if (w <= 0 || h <= 0) {
    return _Shape.small;
  }
  final double area = piece.area / (em * em);
  final double aspect = piece.width / piece.height;
  if (h <= 0.32 && w <= 0.5) {
    return _Shape.small;
  }
  if (h <= 0.42 && w >= 0.55) {
    return _Shape.wide;
  }
  if (h >= 0.35 &&
      h <= 0.92 &&
      w >= 0.06 &&
      w <= 0.55 &&
      aspect <= 0.95 &&
      area <= 0.18) {
    return _Shape.narrow;
  }
  return _Shape.text;
}
