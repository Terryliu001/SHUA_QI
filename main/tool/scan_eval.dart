// 扫描件切题评测：把真实 PDF 的文本层"画成"扫描位图，再跑行级扫描算法，
// 与文本层规则切题的结果对齐。
//
// 为什么要有它：scan_lines/scan_split 的既有单测是合成位图，只能钉住边界；
// 真正决定准确率的是"真卷的行距、题号形态、长题干、选项行、答案行"。
// 本工具不依赖 pdfrx / Flutter，直接用 fixtures 里的真实片段位置渲染。
//
// 用法：
//   dart run tool/scan_eval.dart
//   dart run tool/scan_eval.dart test/fixtures/region/math_midterm.json
//
// 输出：每份卷的 真值题数 / 扫描件题数 / 命中/漏切/多切，以及每题的起始页与 y。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:shuaqi/domain/region/page_layout.dart';
import 'package:shuaqi/domain/region/region_rect.dart';
import 'package:shuaqi/domain/region/scan_lines.dart';
import 'package:shuaqi/domain/region/scan_split.dart';
import 'package:shuaqi/domain/region/split.dart';
import 'package:shuaqi/domain/region/text_line.dart';

void main(List<String> args) {
  final List<String> files = args.isEmpty
      ? <String>[
          'test/fixtures/region/math_midterm.json',
          'test/fixtures/region/eval/eval-single-column.json',
          'test/fixtures/region/eval/eval-double-column.json',
          'test/fixtures/region/eval/eval-paren-sub.json',
          'test/fixtures/region/eval/eval-example-crosspage.json',
        ]
      : args;

  int totalTruth = 0;
  int totalHit = 0;
  int totalMissing = 0;
  int totalExtra = 0;
  final List<String> lines = <String>[];

  for (final String file in files) {
    final File handle = File(file);
    if (!handle.existsSync()) {
      stdout.writeln('skip missing: $file');
      continue;
    }
    final Map<String, Object?> doc =
        jsonDecode(handle.readAsStringSync()) as Map<String, Object?>;
    final List<Object?> rawPages = doc['pages'] as List<Object?>;
    final List<PageLines> textPages = <PageLines>[];
    final List<ScanPage> scans = <ScanPage>[];
    for (final Object? rawPage in rawPages) {
      final Map<String, Object?> page = rawPage as Map<String, Object?>;
      final int index = (page['index'] as num?)?.toInt() ?? 0;
      final double width = (page['w'] as num?)?.toDouble() ?? 595.28;
      final double height = (page['h'] as num?)?.toDouble() ?? 841.89;
      final List<Object?> runs =
          (page['runs'] as List<Object?>?) ?? <Object?>[];
      final List<TextPiece> pieces = <TextPiece>[];
      for (final Object? rawRun in runs) {
        if (rawRun is! List<Object?> || rawRun.length < 5) {
          continue;
        }
        final String text = rawRun[0] as String? ?? '';
        final double x = (rawRun[1] as num).toDouble();
        final double y = (rawRun[2] as num).toDouble();
        final double w = (rawRun[3] as num).toDouble();
        final double h = (rawRun[4] as num).toDouble();
        if (text.trim().isEmpty || w <= 0 || h <= 0) {
          continue;
        }
        pieces.add(
          TextPiece(
            text: text,
            rect: RegionRect.fromLTRB(x, y, x + w, y + h),
            fontSize: h,
          ),
        );
      }
      final PageLines pageLines = buildPageLines(
        pageIndex: index,
        width: width,
        height: height,
        pieces: pieces,
      );
      textPages.add(pageLines);
      scans.add(_renderScanPage(pageLines, scale: 2.0));
    }

    final SplitResult truth = splitQuestions(textPages);
    final SplitResult got = splitScanPages(scans);
    final List<RegionDraft> truthRegions = truth.regions
        .where((RegionDraft d) => d.hasRegion)
        .toList();
    final List<RegionDraft> gotRegions = got.regions
        .where((RegionDraft d) => d.hasRegion)
        .toList();

    final List<String> used = <String>[];
    int hit = 0;
    int missing = 0;
    int extra = 0;
    final List<String> detail = <String>[];
    for (final RegionDraft t in truthRegions) {
      final PageSlice ts = t.slices.first;
      RegionDraft? match;
      for (final RegionDraft g in gotRegions) {
        if (used.contains('${g.ordinal}')) {
          continue;
        }
        final PageSlice gs = g.slices.first;
        if (gs.pageIndex == ts.pageIndex &&
            (gs.rect.top - ts.rect.top).abs() <= 14) {
          match = g;
          break;
        }
      }
      if (match == null) {
        missing++;
        detail.add(
          '  漏  ${t.label.padRight(6)} p${ts.pageIndex}@${ts.rect.top.toStringAsFixed(0)}',
        );
        continue;
      }
      used.add('${match.ordinal}');
      hit++;
      final PageSlice gs = match.slices.first;
      detail.add(
        '  中  ${t.label.padRight(6)} p${ts.pageIndex}@${ts.rect.top.toStringAsFixed(0)}'
        ' → ${match.label.padRight(6)} p${gs.pageIndex}@${gs.rect.top.toStringAsFixed(0)}'
        ' ${gs.rect.top - ts.rect.top >= 0 ? '+' : ''}${(gs.rect.top - ts.rect.top).toStringAsFixed(0)}',
      );
    }
    for (final RegionDraft g in gotRegions) {
      if (used.contains('${g.ordinal}')) {
        continue;
      }
      extra++;
      final PageSlice gs = g.slices.first;
      detail.add(
        '  多  ${g.label.padRight(6)} p${gs.pageIndex}@${gs.rect.top.toStringAsFixed(0)}',
      );
    }

    totalTruth += truthRegions.length;
    totalHit += hit;
    totalMissing += missing;
    totalExtra += extra;
    final double recall = truthRegions.isEmpty ? 1 : hit / truthRegions.length;
    final double precision = gotRegions.isEmpty
        ? 1
        : (gotRegions.length - extra) / gotRegions.length;
    lines.add(
      '${_name(file)}: 真值 ${truthRegions.length} / 扫描 ${gotRegions.length} '
      '· 命中 $hit 漏 $missing 多 $extra · 召回 ${(recall * 100).toStringAsFixed(1)}% '
      '精确 ${(precision * 100).toStringAsFixed(1)}%',
    );
    lines.addAll(detail);
    lines.add('');
  }

  for (final String line in lines) {
    stdout.writeln(line);
  }
  stdout.writeln(
    '合计: 真值 $totalTruth / 命中 $totalHit / 漏 $totalMissing / 多 $totalExtra',
  );
}

String _name(String path) =>
    path.split(RegExp(r'[\\/]')).last.replaceAll('.json', '');

/// 把文本层"画"成灰度位图：每个片段是一块实心墨。
///
/// 这是对扫描件最忠实的几何近似——行级算法只看"哪一列有墨"，
/// 字形内部的小空隙（<0.15em）远小于题号后空白的阈值。
ScanPage _renderScanPage(PageLines page, {required double scale}) {
  final int width = (page.width * scale).round();
  final int height = (page.height * scale).round();
  final Uint8List luma = Uint8List(width * height)
    ..fillRange(0, width * height, 255);
  for (final TextLine line in page.lines) {
    for (final TextPiece piece in line.pieces) {
      final int x0 = (piece.rect.left * scale).floor().clamp(0, width - 1);
      final int x1 = (piece.rect.right * scale).ceil().clamp(0, width);
      // 片段高度里包含上下留白（pdfium 的 bounds 比字形高），横向上按字高
      // 取中间 72% 画墨，避免"行与行之间被墨填满"这种扫描件不会有的形态。
      final double center = (piece.rect.top + piece.rect.bottom) / 2;
      final double inkHeight = piece.rect.height * 0.72;
      final int y0 = ((center - inkHeight / 2) * scale).floor().clamp(
        0,
        height - 1,
      );
      final int y1 = ((center + inkHeight / 2) * scale).ceil().clamp(0, height);
      for (int y = y0; y < y1; y++) {
        final int base = y * width;
        for (int x = x0; x < x1; x++) {
          luma[base + x] = 0;
        }
      }
    }
  }
  return analyzeScanPage(
    luma: luma,
    width: width,
    height: height,
    pageIndex: page.pageIndex,
    pageWidthPt: page.width,
    pageHeightPt: page.height,
  );
}
