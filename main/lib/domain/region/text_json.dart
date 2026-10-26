/// 文本层缓存（`layout/text.json`）的编解码（纯 Dart，可单测）。
///
/// ## 只存"行"，不存原始片段
///
/// 原始片段（pdfrx 的 490 个/页）是**中间产物**：碎到无法直接读、体积大、
/// 而且只有聚行算法关心它。把它落盘属于"存实现细节"，阈值一调就得重新理解旧文件。
///
/// 落盘只保留聚行结果：每行 `t`（文本）/`x`,`y`,`w`,`h`（页面坐标 pt）/`fs`（字号估计）/
/// `c`（栏号）。这份数据正好是**可以直接喂给 AI 的形态**（一句话 + 它的位置），
/// 也是切题唯一的输入；要重跑更细的聚类就重抽一次文本层（真机 7ms/页）。
library;

import 'package:shuaqi/domain/region/region_rect.dart';
import 'package:shuaqi/domain/region/split.dart';
import 'package:shuaqi/domain/region/text_line.dart';

/// 当前格式版本。**只加字段不改语义**；读到不认识的高版本就当缓存失效。
const int kTextDocumentVersion = 1;

/// 序列化。`pages` 必须按页序。
Map<String, Object?> encodeTextDocument(
  List<PageLines> pages, {
  int? extractedAtMillis,
  Map<int, int> runCounts = const <int, int>{},
}) => <String, Object?>{
  'version': kTextDocumentVersion,
  'extractedAt': ?extractedAtMillis,
  'pages': <Object?>[
    for (final PageLines page in pages)
      <String, Object?>{
        'index': page.pageIndex,
        'w': _r(page.width),
        'h': _r(page.height),
        'runs': ?runCounts[page.pageIndex],
        'lines': <Object?>[
          for (final TextLine line in page.lines)
            <String, Object?>{
              't': line.text,
              'x': _r(line.rect.left),
              'y': _r(line.rect.top),
              'w': _r(line.rect.width),
              'h': _r(line.rect.height),
              'fs': _r(line.fontSize),
              'c': line.column,
            },
        ],
      },
  ],
};

/// 反序列化。版本不认识、结构不对时返回空列表（调用方会重新抽取）。
List<PageLines> decodeTextDocument(Map<String, Object?> json) {
  final Object? version = json['version'];
  if (version is! num || version.toInt() > kTextDocumentVersion) {
    return const <PageLines>[];
  }
  final Object? rawPages = json['pages'];
  if (rawPages is! List<Object?>) {
    return const <PageLines>[];
  }
  final List<PageLines> pages = <PageLines>[];
  for (final Object? rawPage in rawPages) {
    if (rawPage is! Map<String, Object?>) {
      continue;
    }
    final Object? rawLines = rawPage['lines'];
    if (rawLines is! List<Object?>) {
      continue;
    }
    final List<TextLine> lines = <TextLine>[];
    for (final Object? rawLine in rawLines) {
      if (rawLine is! Map<String, Object?>) {
        continue;
      }
      final Object? text = rawLine['t'];
      if (text is! String || text.isEmpty) {
        continue;
      }
      final double x = _d(rawLine['x']);
      final double y = _d(rawLine['y']);
      final double w = _d(rawLine['w']);
      final double h = _d(rawLine['h']);
      lines.add(
        TextLine(
          text: text,
          rect: RegionRect.fromLTRB(x, y, x + w, y + h),
          fontSize: _d(rawLine['fs']),
          pieces: const <TextPiece>[],
          column: (rawLine['c'] as num?)?.toInt() ?? 0,
        ),
      );
    }
    pages.add(
      PageLines(
        pageIndex: (rawPage['index'] as num?)?.toInt() ?? pages.length,
        width: _d(rawPage['w']),
        height: _d(rawPage['h']),
        lines: lines,
      ),
    );
  }
  pages.sort((PageLines a, PageLines b) => a.pageIndex.compareTo(b.pageIndex));
  return pages;
}

double _d(Object? value) => value is num ? value.toDouble() : 0;

double _r(double value) => (value * 100).roundToDouble() / 100;
