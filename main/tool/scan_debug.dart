// 真实扫描页的调试入口：读 `tool/scan_samples/*.bin`（8-bit 灰度，行优先），
// 打印行级分析结果与切题结果。纯 Dart，不依赖 Flutter / pdfrx。
//
// 用法：
//   dart --packages=.dart_tool/package_config.json tool/scan_debug.dart \
//     tool/scan_samples/page_luma.bin 1298 1575 1298 1575
//
// 参数：文件 宽 高 页面宽(pt) 页面高(pt)
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:shuaqi/domain/region/scan_lines.dart';
import 'package:shuaqi/domain/region/scan_split.dart';
import 'package:shuaqi/domain/region/split.dart';

void main(List<String> args) {
  if (args.length < 5) {
    stdout.writeln('usage: scan_debug <luma.bin> <w> <h> <pageWpt> <pageHpt>');
    return;
  }
  final Uint8List luma = File(args[0]).readAsBytesSync();
  final int width = int.parse(args[1]);
  final int height = int.parse(args[2]);
  final double pageW = double.parse(args[3]);
  final double pageH = double.parse(args[4]);
  final int threshold = args.length > 5 ? int.parse(args[5]) : 165;
  final ScanPage page = analyzeScanPage(
    luma: luma,
    width: width,
    height: height,
    pageIndex: 0,
    pageWidthPt: pageW,
    pageHeightPt: pageH,
    options: ScanLineOptions(inkThreshold: threshold),
  );
  stdout.writeln('lines=${page.lines.length} em=${page.em.toStringAsFixed(2)}');
  for (int i = 0; i < page.lines.length; i++) {
    final ScanLine line = page.lines[i];
    stdout.writeln(
      '${i.toString().padLeft(3)} y=${line.top.toStringAsFixed(1)}..${line.bottom.toStringAsFixed(1)} '
      'x=${line.left.toStringAsFixed(1)}..${line.right.toStringAsFixed(1)} '
      'w=${line.width.toStringAsFixed(1)} h=${line.fontSize.toStringAsFixed(1)} c=${line.column} '
      'lead=${line.leadKind.name} ${line.leadWidth?.toStringAsFixed(1) ?? '-'} '
      'gap=${line.leadGap?.toStringAsFixed(1) ?? '-'}',
    );
  }
  final SplitResult result = splitScanPages(<ScanPage>[page]);
  stdout.writeln(
    '\nregions=${result.regionCount} marks=${result.markCount} '
    'basis=${result.leveling.basis} levels=${result.leveling.levels}',
  );
  for (final RegionDraft draft in result.regions) {
    final String slices = draft.slices
        .map(
          (PageSlice s) =>
              'p${s.pageIndex}@${s.rect.top.toStringAsFixed(0)}..${s.rect.bottom.toStringAsFixed(0)}',
        )
        .join(' | ');
    stdout.writeln(
      '${draft.ordinal.toString().padLeft(3)} ${draft.label.padRight(8)} '
      'L${draft.level} ${draft.hasRegion ? 'region' : 'container'} $slices',
    );
  }
}
