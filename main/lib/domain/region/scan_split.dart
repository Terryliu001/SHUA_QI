/// 扫描件切题：把"行 + 疑似题号"喂进 L1 的切分引擎（纯 Dart，可单测）。
///
/// ## 设计取舍（2026-10-23）
///
/// 用户的要求是"扫描件也要切到题级、准确优先"。真 OCR 需要新依赖，本阶段不允许，
/// 于是把问题拆成两半：
///
/// 1. **哪些行是题目开头**——靠版面几何（`scan_lines.dart`：行首短块 + 空白 + 左边距）；
/// 2. **怎么从这些开头切出框**——**完全复用文本层那套**（`split.dart`）。
///
/// 第 2 步复用是关键：跨页续段、双栏不串栏、大题容器不占区域、置信度公式，
/// 这些是 032/034 用真卷调出来的，重写一遍必然再踩一遍。
/// 具体做法是给 `TextLine.forcedMark` 挂一个"猜出来的题号"，切题引擎对
/// 文本层和扫描件就只有"题号从哪来"这一处差别。
///
/// 猜出来的题号没有数字（认不出字），所以：
/// - `number` 给 null → 置信度里的"顺序连续"给中性分，**不虚报**；
/// - 标签先用序号占位（用户在面板里看到的是第几块）；
/// - 来源记 `layout`，置信度按规格整体 −0.20 → 一律黄框，提醒逐块核对。
library;

import 'dart:math' as math;

import 'package:shuaqi/domain/region/leveling.dart';
import 'package:shuaqi/domain/region/pattern.dart';
import 'package:shuaqi/domain/region/scan_lines.dart';
import 'package:shuaqi/domain/region/scan_tokens.dart';
import 'package:shuaqi/domain/region/split.dart';
import 'package:shuaqi/domain/region/text_line.dart';

/// 行首题号左边界允许偏离本栏正文左边距多少（× 字高）。
///
/// 1.2 而不是 1.0：真扫描卷会有 0.3–0.6 度的倾斜，一页左侧 20pt 的漂移是常态；
/// 但选择题选项缩进 2 个字（≈2em），仍然被挡在外面。
const double _marginTolerance = 1.2;

/// 中文序号（`一、` `二、`）通常居中或缩进，允许更宽的左边距。
const double _headingMarginTolerance = 3.5;

/// 一行至少要有多少墨（× 字高）才可能是"题号 + 题干"。
const double _minLineInk = 2.2;

/// 短行（小节标题候选）占本栏宽度的上限。
const double _headingWidthRatio = 0.75;

/// 一页扫描分析 + 整卷切题。
///
/// 返回的 [SplitResult] 与文本层同构；`regions` 为空或只有 1 段时，
/// 调用方应退回纯像素切块（`layout_blocks.dart`）。
///
/// ## 两遍法（2026-10-23 第二轮：题号先做字形分类）
///
/// 1. **逐栏收集候选**：`scan_tokens.dart` 已经把"行首是数字/括号/中文序号"
///    的行挑出来了；这里只按左边距（正文左边距 vs 选项缩进）做最后一道闸。
/// 2. 把候选挂成 `forcedMark`，**完全复用 L1 的 `splitQuestions`**：
///    跨页两段、双栏不串栏、大题容器不占区域、层级、置信度全部一致。
///
/// 旧版的"全卷块宽一致性 + 页首闸 + 块形突变闸"已经删除：它们是为了补救
/// "汉字笔画被当成题号"的误报，而误报的根因（只看块宽、不看字形）已经在
/// `scan_tokens.dart` 里修掉。保留那几道闸只会把真正的题号一起误杀
/// （真机：一页 11 道题只切出 10 段，且其中 3 段是续行）。
SplitResult splitScanPages(List<ScanPage> pages) {
  if (pages.isEmpty) {
    return const SplitResult(
      regions: <RegionDraft>[],
      leveling: Leveling(levels: <int>[], basis: 'layout'),
      markCount: 0,
      warnings: <String>['扫描件没有可用的版面行'],
    );
  }

  // 第一遍：逐页逐栏构建"无题号"的行，并收集候选
  final List<List<TextLine>> linesByPage = <List<TextLine>>[];
  final List<_Candidate> candidates = <_Candidate>[];
  int candidateCount = 0;
  for (final ScanPage page in pages) {
    // 栏号已经在 `analyzeScanPage` 里定好（扫描件的分栏必须靠像素纵向空白带，
    // 见 scan_lines.dart 的分栏说明），这里按栏分组即可。
    final List<List<ScanLine>> byColumn = <List<ScanLine>>[];
    for (final ScanLine line in page.lines) {
      while (byColumn.length <= line.column) {
        byColumn.add(<ScanLine>[]);
      }
      byColumn[line.column].add(line);
    }
    // 每栏的最右（算栏宽用）；左边距在下面按众数取
    final List<double> columnRight = <double>[
      for (final List<ScanLine> columnLines in byColumn)
        columnLines.isEmpty
            ? -1
            : columnLines.map((ScanLine l) => l.right).reduce(math.max),
    ];

    final List<TextLine> lines = <TextLine>[];
    for (int c = 0; c < byColumn.length; c++) {
      final List<ScanLine> columnLines = byColumn[c];
      if (columnLines.isEmpty) {
        continue;
      }
      columnLines.sort((ScanLine a, ScanLine b) => a.top.compareTo(b.top));
      // 正文左边距取**众数**，不取最左：真卷第一页常有竖排"考试注意事项"、
      // 表格左栏这类"比正文更靠左"的行，取最左会把整页题号的左边距闸全部否掉
      // （真机实测：扫描卷第 1 页 0 个框，33 道题全跑到第 2–4 页）。
      // 正文行都左对齐在同一 x，成员最多的簇就是它。
      final double left = _dominantLeft(columnLines, em: columnLines.first.em);
      final double width = math.max(1, columnRight[c] - left);
      final double em = columnLines.first.em;

      for (int i = 0; i < columnLines.length; i++) {
        final ScanLine line = columnLines[i];
        final int lineIndex = lines.length;
        lines.add(
          TextLine(
            text: '',
            rect: line.rect,
            fontSize: line.fontSize,
            pieces: const <TextPiece>[],
            column: c,
          ),
        );
        if (line.hasLeadToken && line.width >= em * _minLineInk) {
          candidateCount++;
          candidates.add(
            _Candidate(
              page: linesByPage.length,
              lineIndex: lineIndex,
              scan: line,
              contentLeft: left,
              columnWidth: width,
            ),
          );
        }
      }
    }
    linesByPage.add(lines);
  }

  // 第二遍：左边距闸。题号已经由字形分类认出来了，这里只排除"选项行"
  // （缩进 ≥2 个字）和"居中/偏左的小节标题"。
  int headingCount = 0;
  final Set<_Candidate> accepted = <_Candidate>{};
  for (final _Candidate candidate in candidates) {
    final ScanLeadKind kind = candidate.scan.leadKind;
    final bool isHeading = kind == ScanLeadKind.cn;
    final double em = candidate.scan.em;
    if (isHeading) {
      // 小节标题：允许居中（真卷 `一、单选题` 比正文左边距多 2–3 个字），
      // 但必须是**短行**——长行开头的"一"是正文，不是标题。
      if (candidate.scan.left >
              candidate.contentLeft + em * _headingMarginTolerance ||
          candidate.scan.width > candidate.columnWidth * _headingWidthRatio) {
        continue;
      }
    } else if (candidate.scan.left >
        candidate.contentLeft + em * _marginTolerance) {
      continue; // 选项行 / 缩进的作答区
    }
    accepted.add(candidate);
    if (isHeading) {
      headingCount++;
    }
  }

  // 第三遍：把幸存候选挂回行上，交给 L1 切分
  for (final _Candidate candidate in accepted) {
    final TextLine line = linesByPage[candidate.page][candidate.lineIndex];
    final ScanLeadKind kind = candidate.scan.leadKind;
    linesByPage[candidate.page][candidate.lineIndex] = TextLine(
      text: '',
      rect: line.rect,
      fontSize: line.fontSize,
      pieces: line.pieces,
      column: line.column,
      forcedMark: QuestionMark(
        // 认不出数字：标签由调用方按序号回填（见 [_relabel]）。
        label: kind == ScanLeadKind.cn ? '§' : '#',
        // 层级复用 L1 的"样式优先"：中文序号 = 容器，括号 = 小题。
        kind: switch (kind) {
          ScanLeadKind.cn => MarkKind.cnNumeral,
          ScanLeadKind.paren => MarkKind.parenArabic,
          _ => MarkKind.arabic,
        },
        rest: '',
        number: null,
      ),
    );
  }

  final List<PageLines> pageLines = <PageLines>[
    for (int p = 0; p < pages.length; p++)
      PageLines(
        pageIndex: pages[p].pageIndex,
        width: pages[p].width,
        height: pages[p].height,
        lines: linesByPage[p],
      ),
  ];

  final SplitResult raw = splitQuestions(pageLines, fromOcr: true);
  final List<RegionDraft> drafts = _relabel(raw.regions);
  final int regionCount = drafts
      .where((RegionDraft draft) => draft.hasRegion)
      .length;
  final String warning = regionCount == 0
      ? '扫描件：没找到"题号 + 正文"形态的行（这一页可能是图片、或者题号样式特殊）'
      : '扫描件按版面切成 $regionCount 段（识别到 $candidateCount 处疑似题号，'
            '其中 $headingCount 处判为小节标题）：没有认字，题号只是位置推断，请核对黄框';
  return SplitResult(
    regions: drafts,
    leveling: raw.leveling,
    markCount: raw.markCount,
    warnings: <String>[warning],
  );
}

/// 一个"疑似题号行"。`page`/`lineIndex` 用于第三遍把 mark 挂回行上。
class _Candidate {
  const _Candidate({
    required this.page,
    required this.lineIndex,
    required this.scan,
    required this.contentLeft,
    required this.columnWidth,
  });

  final int page;

  /// 页内行序号（第三遍把 mark 挂回行用）。
  final int lineIndex;

  final ScanLine scan;

  /// 本栏正文左边距（pt）。
  final double contentLeft;

  /// 本栏内容宽度（pt），用于判断"是不是短标题行"。
  final double columnWidth;
}

/// 把占位标签换成序号，并把"来源/题型"改成扫描件的事实口径。
///
/// - `source = 'layout'`：规格要求，表示"这是版面推断，不是认出来的"；
/// - `kind = 'unknown'`：没有文字就无法判题型，绝不能虚报成 `essay`；
/// - `stem = ''`：没有 OCR 就没有题干，第 4 周接入识别后再填。
List<RegionDraft> _relabel(List<RegionDraft> drafts) {
  int serial = 0;
  final List<RegionDraft> out = <RegionDraft>[];
  for (final RegionDraft draft in drafts) {
    final bool isContainer = draft.level == 1 && !draft.hasRegion;
    if (!isContainer) {
      serial++;
    }
    out.add(
      RegionDraft(
        ordinal: draft.ordinal,
        label: isContainer ? '§' : '$serial',
        level: draft.level,
        kind: 'unknown',
        stem: '',
        slices: draft.slices,
        confidence: draft.confidence,
        fontSize: draft.fontSize,
        number: null,
        parentOrdinal: draft.parentOrdinal,
        source: 'layout',
      ),
    );
  }
  return out;
}

/// 本栏正文左边距：把所有行的左边界按 1em 容差聚类，取**最左的"足够大"的簇**。
///
/// 为什么不是"成员最多"：双栏/选择题页的**选项行**（缩进 1.7em）往往比题干
/// 行还多，按众数会选中选项缩进，于是题干反而"在左边距之外"，选项倒成了题
/// （真机第 3 页 9 道题切出 20 段，全是 A/B/C/D）。
///
/// 为什么不是"最左"：真卷第一页常有竖排"考试注意事项"、表格左栏这类比正文
/// 更靠左的行；再加扫描噪声（第 1 页最左有 1 个像素的黑点），取最左会把所有
/// 题号都否掉（真机：第 1 页 0 个框）。
///
/// 现行口径：先算出最大簇 [maxCount]，从左往右取第一个成员数 ≥30% 最大簇
/// （且至少 3 行）的簇。选项簇人数再多也在右边，不会被选中。
double _dominantLeft(List<ScanLine> lines, {required double em}) {
  if (lines.isEmpty) {
    return 0;
  }
  final List<double> lefts = <double>[
    for (final ScanLine line in lines) line.left,
  ]..sort();
  final double tolerance = em * 1.0;
  final List<(double, int)> clusters = <(double, int)>[];
  int i = 0;
  while (i < lefts.length) {
    int j = i;
    while (j < lefts.length && lefts[j] - lefts[i] <= tolerance) {
      j++;
    }
    clusters.add((lefts[i], j - i));
    i = j;
  }
  int maxCount = 0;
  for (final (double, int) cluster in clusters) {
    if (cluster.$2 > maxCount) {
      maxCount = cluster.$2;
    }
  }
  final int threshold = math.max(3, (maxCount * 0.3).ceil());
  for (final (double, int) cluster in clusters) {
    if (cluster.$2 >= threshold) {
      return cluster.$1;
    }
  }
  return clusters.first.$1;
}
