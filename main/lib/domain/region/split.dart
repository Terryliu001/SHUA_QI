/// 规则切题（L1）：把一页页的文本行切成"一道道题"（纯 Dart，可单测）。
///
/// 输入是**已聚行、已排序、已剔页眉页脚**的文本行（同一页内按"栏 → y"升序），
/// 输出是带包围盒的题目草稿；落库与写 JSON 由 `app/region` 负责。
///
/// 三条硬规则（规格 T3.2 的边界规则，逐条实现）：
/// 1. 一道题的区域 = 从题号行**顶**，到下一个同级或更高级题号行顶（不含）；
/// 2. 跨页：下一页从"内容顶"延续到下一个题号之前——**同一道题写两段**
///    （`question_region` 两行，不同 page_id），不用负数坐标硬凑；
/// 3. 大题（level 1）只当容器、不占区域（它的区域会吞掉所有小题）；
///    但一份卷子若根本没有小题，大题自己就得占区域，否则一道也切不出来。
library;

import 'dart:math' as math;

import 'package:shuaqi/domain/region/answer.dart';
import 'package:shuaqi/domain/region/confidence.dart';
import 'package:shuaqi/domain/region/leveling.dart';
import 'package:shuaqi/domain/region/pattern.dart';
import 'package:shuaqi/domain/region/region_rect.dart';
import 'package:shuaqi/domain/region/text_line.dart';

/// 一页的文本行（切题的唯一输入）。
class PageLines {
  const PageLines({
    required this.pageIndex,
    required this.width,
    required this.height,
    required this.lines,
  });

  final int pageIndex;
  final double width;
  final double height;

  /// 已聚行、已剔页眉页脚。顺序不敏感（切题前会按"栏 → y"重排）。
  final List<TextLine> lines;

  PageLines copyWithLines(List<TextLine> value) => PageLines(
    pageIndex: pageIndex,
    width: width,
    height: height,
    lines: value,
  );
}

/// 区域在某一页上的一段（跨页题有多段）。
class PageSlice {
  const PageSlice({required this.pageIndex, required this.rect});

  final int pageIndex;
  final RegionRect rect;

  Map<String, Object?> toJson() => <String, Object?>{
    'page': pageIndex,
    ...rect.toJson(),
  };
}

/// 切出来的一道题。
class RegionDraft {
  const RegionDraft({
    required this.ordinal,
    required this.label,
    required this.level,
    required this.kind,
    required this.stem,
    required this.slices,
    required this.confidence,
    required this.fontSize,
    this.number,
    this.parentOrdinal,
    this.source = 'rule',
  });

  /// 全卷文档顺序，从 1 开始。**大题也占一个序号**（它是题，只是不占区域）。
  final int ordinal;

  /// 题号原文（`12.` `（3）` `一、`）。
  final String label;

  /// 1 = 大题，2 = 小题。
  final int level;

  /// `choice` / `judge` / `blank` / `essay`。
  final String kind;

  /// 题干（题号之后的内容，最多 240 字）。
  final String stem;

  /// 区域分段。为空 = "这道题只是个容器"（大题）。
  final List<PageSlice> slices;

  final double confidence;
  final double fontSize;

  /// 阿拉伯题号（折算不出来为 null）。
  final int? number;

  /// 所属大题的 [ordinal]（小题才有）。
  final int? parentOrdinal;

  /// `rule` / `layout` / `ocr`。
  final String source;

  bool get hasRegion => slices.isNotEmpty;

  RegionGrade get grade => RegionGrade.of(confidence);

  Map<String, Object?> toJson() => <String, Object?>{
    'ordinal': ordinal,
    'label': label,
    'level': level,
    'kind': kind,
    'stem': stem,
    'confidence': (confidence * 1000).round() / 1000,
    'source': source,
    if (number != null) 'number': number,
    if (parentOrdinal != null) 'parent': parentOrdinal,
    'slices': <Object?>[for (final PageSlice slice in slices) slice.toJson()],
  };
}

/// 切题结果。
class SplitResult {
  const SplitResult({
    required this.regions,
    required this.leveling,
    required this.markCount,
    required this.warnings,
    this.answers = AnswerSet.empty,
  });

  final List<RegionDraft> regions;
  final Leveling leveling;

  /// 命中的题号数量（含大题）。
  final int markCount;

  /// 给用户 / 日志看的告警（例如"没有命中任何题号"）。
  final List<String> warnings;

  /// 文末「参考答案」区抽出的答案（label → 文本）。扫描件为空。
  final AnswerSet answers;

  int get regionCount => regions.where((RegionDraft r) => r.hasRegion).length;

  Map<String, Object?> toJson(int version) => <String, Object?>{
    'version': version,
    'leveling': <String, Object?>{
      'splitByFont': leveling.splitByFont,
      'threshold': leveling.threshold,
      'major': leveling.majorCount,
      'minor': leveling.minorCount,
    },
    'questions': <Object?>[
      for (final RegionDraft region in regions) region.toJson(),
    ],
    'answers': <Object?>[
      for (final AnswerNote note in answers.byLabel.values) note.toJson(),
    ],
    'warnings': warnings,
  };
}

/// 左右留白（pt）：贴住文字，但不贴着笔画。
const double _padX = 4;

/// 上下留白（pt）：框顶不压题号行。
const double _padY = 3;

/// 一段区域的最小高度（pt）：小于它的段不出（避免"一条线"的空框）。
const double _minSliceHeight = 6;

/// 题干最多取多少字入库。
const int _stemLimit = 240;

/// 题内解析/答案最多取多少字（解析可能很长；面板只展示前 10 行）。
const int _answerLimit = 2400;

/// 主入口。pages 必须按页序给出。
SplitResult splitQuestions(List<PageLines> pages, {bool fromOcr = false}) {
  final List<PageLines> ordered = <PageLines>[
    for (final PageLines page in pages) page.copyWithLines(_sorted(page.lines)),
  ];

  // 扁平化：文档顺序 = 页序 → 栏 → y
  final List<_LineRef> flat = <_LineRef>[];
  for (int p = 0; p < ordered.length; p++) {
    final List<TextLine> lines = ordered[p].lines;
    for (int i = 0; i < lines.length; i++) {
      flat.add(_LineRef(page: p, index: i, line: lines[i]));
    }
  }
  if (flat.isEmpty) {
    return SplitResult(
      regions: const <RegionDraft>[],
      leveling: assignLevels(const <MarkKind>[], const <double>[]),
      markCount: 0,
      warnings: const <String>['这一卷没有文本层（可能是扫描件），需要 L2 补位'],
    );
  }

  // 1) 题号
  //
  // 含答案/解析的卷子（用户 2026-10-23 点名）有两种形态，都在这里处理：
  // 1. **文末答案区**：`参考答案` / `答案与解析` 之后编号会从 1 重新开始。
  //    遇到标题后不再收题号，并把上一题的结束位置截到标题行（答案不进题目框）。
  // 2. **题内解答步骤**：`解：` / `证明：` / `【答案】` 后的 `（1）（2）` 是
  //    解答步骤，不是新题；在遇到下一个阿拉伯题号前全部忽略。
  //
  // 扫描件没有文字（`fromOcr = true`），这些文本标记一律不生效。
  final List<QuestionMark> marks = <QuestionMark>[];
  final List<int> markAt = <int>[];
  int? answerStart;
  bool inAnswer = false;
  bool inSolution = false;
  for (int i = 0; i < flat.length; i++) {
    final TextLine line = flat[i].line;
    if (!fromOcr) {
      if (!inAnswer && _isAnswerHeading(line.text)) {
        inAnswer = true;
        answerStart ??= i;
      }
      if (inAnswer) {
        continue;
      }
      if (_isSolutionMarker(line.text)) {
        inSolution = true;
      }
    }
    // 扫描件没有文字，题号是版面几何猜出来的，直接挂在行上（`forcedMark`）；
    // 文本层则照常跑正则。两条路径之后完全合一。
    final QuestionMark? mark = line.forcedMark ?? matchQuestionMark(line.text);
    if (mark == null) {
      continue;
    }
    if (!fromOcr && inSolution) {
      if (_isSolutionStepKind(mark.kind)) {
        continue; // `(1)(2)` 解答步骤：并进当前题的区域，不另起一题
      }
      inSolution = false; // 下一个阿拉伯题号 = 新题
    }
    marks.add(mark);
    markAt.add(i);
  }
  // 文末答案区的起点：最后一题的框要停在这里，不能把答案一起框进去。
  final int documentEnd = answerStart ?? flat.length;
  if (marks.isEmpty) {
    return SplitResult(
      regions: const <RegionDraft>[],
      leveling: assignLevels(const <MarkKind>[], const <double>[]),
      markCount: 0,
      warnings: const <String>['没有命中任何题号，需要 L2 补位或手动切'],
    );
  }

  // 2) 层级（全卷一次判，见 leveling.dart 的说明）
  final Leveling leveling = assignLevels(
    <MarkKind>[for (final QuestionMark mark in marks) mark.kind],
    <double>[for (final int at in markAt) flat[at].line.fontSize],
    // 扫描件的行高是像素行段估的，字号断层不可靠；只信题号字形（见 leveling.dart）。
    allowFontFallback: !fromOcr,
  );

  // 2b) 每道大題挂了几道小题 —— 决定大题要不要自己占区域。
  //
  // 真卷实测：`一、填空题` 下挂 1–6，是容器；而 `三、（14 分）求…` 没有小题，
  // 它本身就是一道题，不占区域的话这一整节就白切了。
  //
  // 2026-10-23 补：**带材料的论述题**（`四、论述题` + 材料一/材料二 + 问题 1/2）
  // 也有小题，但它的大题部分（标题 + 材料）本身就是要读的题面，不能当纯容器。
  // 判据是"标题与第一道小题之间还有正文"——`一、单选题` 下面紧接第 1 题，
  // 中间 0 行，仍然是容器；论述题中间有材料（长段可能被聚成 1 行），就给它
  // 自己的区域（止于第一道小题）。
  final List<int> childCount = List<int>.filled(marks.length, 0);
  final List<int> firstChildGap = List<int>.filled(marks.length, 0);
  int? majorIndex;
  for (int m = 0; m < marks.length; m++) {
    if (leveling.levels[m] == 1) {
      majorIndex = m;
    } else if (majorIndex != null) {
      if (childCount[majorIndex] == 0) {
        firstChildGap[majorIndex] = markAt[m] - markAt[majorIndex] - 1;
      }
      childCount[majorIndex]++;
    }
  }

  // 每一级的字号中位数：字号估计本身有噪声（多行公式对象会把行撑高），
  // 和"相邻那一行"比会让噪声互相放大；和本级中位数比才稳。
  final Map<int, double> levelMedianFont = <int, double>{};
  for (final int level in <int>{...leveling.levels}) {
    levelMedianFont[level] = _median(<double>[
      for (int m = 0; m < marks.length; m++)
        if (leveling.levels[m] == level) flat[markAt[m]].line.fontSize,
    ]);
  }

  final Map<int, int?> lastNumberByLevel = <int, int?>{};
  final List<RegionDraft> drafts = <RegionDraft>[];
  // 题内 `解：/答案：` 之后的文字：既留在题目区域里（用户要看到解析），
  // 又单独抽出来给面板对答案。按 ordinal 挂：同一卷可能有多个 `1.`。
  final Map<int, AnswerNote> inlineAnswers = <int, AnswerNote>{};
  int? currentParentOrdinal;
  String? currentParentKind;

  for (int m = 0; m < marks.length; m++) {
    final QuestionMark mark = marks[m];
    final int startIndex = markAt[m];
    final _LineRef startRef = flat[startIndex];
    final TextLine startLine = startRef.line;
    final int level = leveling.levels[m];
    final double fontSize = startLine.fontSize;
    if (level == 1) {
      currentParentOrdinal = m + 1;
      currentParentKind = kindFromHeading(mark.rest);
    }

    // 下一处切点：之后第一个"同级或更高级"的题号
    int? nextMarkIndex;
    for (int n = m + 1; n < marks.length; n++) {
      if (leveling.levels[n] <= level) {
        nextMarkIndex = n;
        break;
      }
    }
    // 大题自己也要区域时（带材料的论述题），下界是**第一道小题**，不是下一道大题：
    // 否则会把材料后面所有小题一起吞进大题的框里（真机第 4 页 8 段变 7 段）。
    final int? regionEndMark = level == 1 && childCount[m] > 0
        ? m + 1
        : nextMarkIndex;
    final int endIndex = regionEndMark == null
        ? documentEnd
        : markAt[regionEndMark];

    final bool needsRegion =
        level == 2 ||
        (level == 1 && (childCount[m] == 0 || firstChildGap[m] >= 1));
    // 下一题若落在**同一页的另一栏**，"另一栏的栏顶"绝不能当作本题的下界：
    // 双栏页第二栏从页面顶端开始，用它当截断线会让第一栏最后一题的下界
    // 跑到自己的上界之上 → 整段被丢（实测：双栏卷第 4 题直接没有框）。
    final int? endColumn = regionEndMark == null
        ? null
        : flat[markAt[regionEndMark]].line.column;
    final List<PageSlice> slices = needsRegion
        ? _buildSlices(
            ordered: ordered,
            flat: flat,
            startIndex: startIndex,
            endIndex: endIndex,
            startColumn: startLine.column,
            endColumn: endColumn,
          )
        : const <PageSlice>[];

    // 大题只写自己的标题行：它的"题干"不该吞掉第一道小题的题面。
    String stem;
    String inlineAnswer = '';
    if (level == 1) {
      stem = mark.rest;
    } else {
      final ({String stem, String answer}) parts = _buildStem(
        flat: flat,
        startIndex: startIndex,
        endIndex: endIndex,
        mark: mark,
      );
      stem = parts.stem;
      inlineAnswer = parts.answer;
      if (inlineAnswer.trim().isNotEmpty) {
        inlineAnswers[m + 1] = AnswerNote(
          label: mark.label,
          text: inlineAnswer.trim(),
          source: 'inline',
          pageIndex: startRef.page,
          ordinal: m + 1,
        );
      }
    }

    final String ownKind = classifyKind(stem.isEmpty ? mark.rest : stem);
    // 小题自己看不出题型时，继承大题标题（`一、填空题` → blank）。
    final String kind =
        ownKind == 'essay' && level == 2 && currentParentKind != null
        ? currentParentKind
        : ownKind;

    final int? previousNumber = lastNumberByLevel[level];
    lastNumberByLevel[level] = mark.number;

    final bool sameColumn;
    final double gap;
    if (regionEndMark == null) {
      sameColumn = true;
      gap = 0;
    } else {
      final _LineRef nextRef = flat[markAt[regionEndMark]];
      sameColumn =
          nextRef.page != startRef.page ||
          nextRef.line.column == startLine.column;
      final _LineRef lastRef = flat[endIndex - 1];
      gap = nextRef.page == lastRef.page
          ? nextRef.line.top - lastRef.line.bottom
          : 0;
    }

    drafts.add(
      RegionDraft(
        ordinal: m + 1,
        label: mark.label,
        level: level,
        kind: kind,
        stem: stem,
        slices: slices,
        confidence: regionConfidence(
          ConfidenceSignals(
            boundary: boundaryScore(
              gap: gap,
              fontSize: fontSize,
              sameColumn: sameColumn,
              hasNext: nextMarkIndex != null,
            ),
            style: styleScore(
              fontSize: fontSize,
              previousFontSize: levelMedianFont[level] ?? 0,
            ),
            order: orderScore(current: mark.number, previous: previousNumber),
            text: textScore(stem),
            fromOcr: fromOcr,
          ),
        ),
        fontSize: fontSize,
        number: mark.number,
        parentOrdinal: level == 2 ? currentParentOrdinal : null,
        source: fromOcr ? 'ocr' : 'rule',
      ),
    );
  }

  final List<String> warnings = <String>[];
  if (!drafts.any((RegionDraft draft) => draft.hasRegion)) {
    warnings.add('命中 ${drafts.length} 个题号，但没有任何区域（层级判定可能过头）');
  }
  final AnswerSet section = _extractAnswers(
    flat,
    answerStart,
    fromOcr: fromOcr,
  );
  // 题内解析按 ordinal 精确挂；文末答案键按 label 兜底。
  final AnswerSet answers = AnswerSet(
    section.byLabel,
    byOrdinal: inlineAnswers,
  );
  return SplitResult(
    regions: drafts,
    leveling: leveling,
    markCount: marks.length,
    warnings: warnings,
    answers: answers,
  );
}

/// 从「参考答案」区抽答案。
///
/// 支持两种常见版式：
/// - 每题一行/多行：`1. A` / `2. 解：...`；
/// - 答案键压缩成一行：`1.A 2.B 3.C`。
///
/// 只做"能对上的题号 + 文本"，不判断答案对错；面板按题号取用。
AnswerSet _extractAnswers(
  List<_LineRef> flat,
  int? answerStart, {
  required bool fromOcr,
}) {
  if (fromOcr || answerStart == null || answerStart + 1 >= flat.length) {
    return AnswerSet.empty;
  }
  final Map<String, AnswerNote> map = <String, AnswerNote>{};
  String? currentLabel;
  int? currentPage;
  final StringBuffer buffer = StringBuffer();

  void flush() {
    final String label = currentLabel ?? '';
    final String text = buffer.toString().trim();
    if (label.isNotEmpty && text.isNotEmpty) {
      map[answerKeyOf(label)] = AnswerNote(
        label: label,
        text: text.length > 1200 ? text.substring(0, 1200) : text,
        pageIndex: currentPage,
      );
    }
    currentLabel = null;
    currentPage = null;
    buffer.clear();
  }

  // 压缩答案键：`1.A 2.B` / `1 A 2 B`。至少两个才当键，避免把解答里的
  // 数字/字母误拆成答案。
  final RegExp compact = RegExp(
    r'(\d{1,3})\s*[.、．:：]?\s*([A-H√×对错])(?=[\s,，;；]|$)',
  );

  for (int i = answerStart + 1; i < flat.length; i++) {
    final _LineRef ref = flat[i];
    final String text = ref.line.text.trim();
    if (text.isEmpty) {
      continue;
    }
    final List<RegExpMatch> matches = compact.allMatches(text).toList();
    if (matches.length >= 2 && text.length < 120) {
      flush();
      for (final RegExpMatch match in matches) {
        final String label = match.group(1)!;
        final String answer = match.group(2)!;
        map[answerKeyOf(label)] = AnswerNote(
          label: label,
          text: answer,
          pageIndex: ref.page,
        );
      }
      continue;
    }
    final QuestionMark? mark = matchQuestionMark(text);
    if (mark != null) {
      flush();
      currentLabel = mark.label;
      currentPage = ref.page;
      buffer.write(text);
    } else if (currentLabel != null) {
      if (buffer.length < 1600) {
        buffer.write('\n');
        buffer.write(text);
      }
    }
  }
  flush();
  return AnswerSet(map);
}

/// 把 [startIndex, endIndex) 这段行转成"每页一段"的矩形。
List<PageSlice> _buildSlices({
  required List<PageLines> ordered,
  required List<_LineRef> flat,
  required int startIndex,
  required int endIndex,
  required int startColumn,
  required int? endColumn,
}) {
  if (endIndex <= startIndex) {
    return const <PageSlice>[];
  }
  final int startPage = flat[startIndex].page;
  final int endPage = endIndex >= flat.length
      ? ordered.length - 1
      : flat[endIndex].page;
  final double startY = flat[startIndex].line.top - _padY;
  final double cutY = endIndex >= flat.length
      ? double.infinity
      : flat[endIndex].line.top - _padY;

  // 切点在同一页的另一栏：本题的下界是"本栏的栏底"，不是切点所在的栏顶。
  final bool cutInOtherColumn =
      endColumn != null && endColumn != startColumn && endPage == startPage;

  final List<PageSlice> slices = <PageSlice>[];
  for (int p = startPage; p <= endPage && p < ordered.length; p++) {
    final PageLines page = ordered[p];
    final (double contentTop, double contentBottom) = _contentBounds(page);
    final double y0 = p == startPage ? math.max(0, startY) : contentTop;
    final double y1;
    if (cutInOtherColumn) {
      y1 = _columnBottom(page, startColumn, fallback: contentBottom);
    } else if (p == endPage) {
      y1 = math.min(contentBottom, cutY);
    } else {
      y1 = contentBottom;
    }
    if (y1 - y0 < _minSliceHeight) {
      continue;
    }
    double? minLeft;
    double? maxRight;
    for (final TextLine line in page.lines) {
      if (line.bottom < y0 || line.top > y1) {
        continue;
      }
      // 本题只吃自己所在栏的行：双栏页的框绝不能横跨两栏。
      // （跨页续段也按同一栏号取，双栏卷的续段在下一页仍从第 0 栏开始。）
      if (line.column != startColumn) {
        continue;
      }
      if (minLeft == null || line.left < minLeft) {
        minLeft = line.left;
      }
      if (maxRight == null || line.right > maxRight) {
        maxRight = line.right;
      }
    }
    if (minLeft == null || maxRight == null) {
      continue;
    }
    final double left = math.max(0, minLeft - _padX);
    final double right = math.min(page.width, maxRight + _padX);
    if (right - left < _minSliceHeight) {
      continue;
    }
    slices.add(
      PageSlice(
        pageIndex: page.pageIndex,
        rect: RegionRect.fromLTRB(left, y0, right, y1),
      ),
    );
  }
  return slices;
}

/// 某一栏在本页的底（没有该栏的行时退回整页内容底）。
double _columnBottom(PageLines page, int column, {required double fallback}) {
  double bottom = 0;
  bool found = false;
  for (final TextLine line in page.lines) {
    if (line.column != column) {
      continue;
    }
    found = true;
    if (line.bottom > bottom) {
      bottom = line.bottom;
    }
  }
  return found ? math.min(page.height, bottom) : fallback;
}

/// 一页正文的上下界（去掉页眉页脚后剩下内容的包围盒）。
(double, double) _contentBounds(PageLines page) {
  if (page.lines.isEmpty) {
    return (0, 0);
  }
  double top = double.infinity;
  double bottom = 0;
  for (final TextLine line in page.lines) {
    if (line.top < top) {
      top = line.top;
    }
    if (line.bottom > bottom) {
      bottom = line.bottom;
    }
  }
  return (math.max(0, top), math.min(page.height, bottom));
}

/// 题干 + 题内解析：题号行剩余部分 + 后续行，最多 [_stemLimit] 字。
///
/// 遇到 `解：/证明：/答案：/【答案】` 后，余下文字进 [answer]，题干截断。
/// 同一行里出现 marker（`1. ... 解：...`）也能切开。
({String stem, String answer}) _buildStem({
  required List<_LineRef> flat,
  required int startIndex,
  required int endIndex,
  required QuestionMark mark,
}) {
  final StringBuffer stem = StringBuffer();
  final StringBuffer answer = StringBuffer();
  final String rest = mark.rest;
  bool inAnswer = false;
  final RegExpMatch? inlineMarker = _solutionMarkerAnywhere.firstMatch(rest);
  if (inlineMarker != null && inlineMarker.start > 0) {
    stem.write(rest.substring(0, inlineMarker.start));
    answer.write(rest.substring(inlineMarker.start));
    inAnswer = true;
  } else if (_isSolutionMarker(rest)) {
    answer.write(rest);
    inAnswer = true;
  } else {
    stem.write(rest);
  }

  for (int i = startIndex + 1; i < endIndex; i++) {
    final String text = flat[i].line.text;
    if (text.isEmpty) {
      continue;
    }
    if (!inAnswer && _isSolutionMarker(text)) {
      inAnswer = true;
      answer.write(text);
      continue;
    }
    final StringBuffer target = inAnswer ? answer : stem;
    if (target.length >= (inAnswer ? _answerLimit : _stemLimit)) {
      if (inAnswer) {
        break;
      }
      continue;
    }
    if (target.isNotEmpty) {
      // 保留**行**边界：数学卷的公式是"多行基线拼出来的"，压成一行空格后
      // 右侧面板会读成 `1,|x|≤1 ，则… 0,|x|>1` 这种乱序串；换行至少可读。
      target.write('\n');
    }
    target.write(text);
  }
  return (
    stem: _limit(stem.toString(), _stemLimit),
    answer: _limit(answer.toString(), _answerLimit),
  );
}

String _limit(String raw, int limit) =>
    raw.length <= limit ? raw : raw.substring(0, limit);

/// 文末答案区标题（只认"纯标题"，不认 `答案：B` 这种题内答案）。
///
/// `答案：B` 如果也被当成标题，整卷会在第一题的答案处就停止切题。
/// 所以这里要求标题之后**没有正文**（允许一个短括号说明，如 `（1–20 题）`）。
final RegExp _answerHeadingPattern = RegExp(
  r'^(参考答案与解析|参考答案|答案与解析|试题答案|评分标准|答案|解析)'
  r'\s*[:：]?\s*([（(][^）)]{0,16}[）)])?$',
);

bool _isAnswerHeading(String text) =>
    _answerHeadingPattern.hasMatch(text.trim());

/// 题内解答开始标记（`解：` `证明：` `答：` `【答案】`…）。
final RegExp _solutionMarkerPattern = RegExp(
  r'^\s*(解|证明|证|答|分析|解析)\s*[:：]'
  r'|^\s*[【\[]\s*(答案|解析|分析|解)\s*[】\]]',
);

bool _isSolutionMarker(String text) =>
    _solutionMarkerPattern.hasMatch(text.trimLeft());

/// 同一行里出现的解答标记（`1. ... 解：...`）。与行首版本共用词表。
final RegExp _solutionMarkerAnywhere = RegExp(
  r'(解|证明|证|答|分析|解析)\s*[:：]|【\s*(答案|解析|分析|解)\s*】',
);

/// 解答步骤常用的题号样式：`（1）` `(1)` `①`。阿拉伯 `1.` 不在此列
/// （它与下一道主问题无法区分，宁可让用户手改，也不误吞真题）。
bool _isSolutionStepKind(MarkKind kind) =>
    kind == MarkKind.parenArabic || kind == MarkKind.circled;

double _median(List<double> values) {
  final List<double> sorted = values.where((double v) => v > 0).toList()
    ..sort();
  if (sorted.isEmpty) {
    return 0;
  }
  final int mid = sorted.length ~/ 2;
  return sorted.length.isOdd
      ? sorted[mid]
      : (sorted[mid - 1] + sorted[mid]) / 2;
}

List<TextLine> _sorted(List<TextLine> lines) {
  return lines.toList(growable: false)..sort((TextLine a, TextLine b) {
    if (a.column != b.column) {
      return a.column.compareTo(b.column);
    }
    return a.top.compareTo(b.top);
  });
}

class _LineRef {
  const _LineRef({required this.page, required this.index, required this.line});

  /// 页在 [splitQuestions] 入参里的下标（不是 PDF 页码）。
  final int page;

  /// 页内行下标（重排后）。
  final int index;

  final TextLine line;
}
