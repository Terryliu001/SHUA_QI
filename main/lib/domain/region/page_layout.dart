/// 一页的"排版还原"：片段 → 分栏 → 聚行 → 剔页眉页脚（纯 Dart，可单测）。
///
/// 这一步之所以抽成纯函数而不是塞在 `app` 里：它是整个切题的**数据入口**，
/// 阈值（容差、栏间距、页眉带）需要拿真卷反复调；放在 domain 才能用真样本
/// 做回归测试（`test/region_split_test.dart` 用的就是真卷片段）。
library;

import 'package:shuaqi/domain/region/columns.dart';
import 'package:shuaqi/domain/region/split.dart';
import 'package:shuaqi/domain/region/text_line.dart';

/// 把一页的原始片段还原成"按栏、按行"的文本行。
///
/// 顺序：分栏 → 每栏各自聚行（**必须在栏内聚行**，否则双栏页会被拼成一行）
/// → 给行打上栏号 → 剔页眉页脚。
PageLines buildPageLines({
  required int pageIndex,
  required double width,
  required double height,
  required List<TextPiece> pieces,
  double bandRatio = 0.05,
}) {
  final List<ColumnBand> columns = detectColumns(pieces, pageWidth: width);
  final List<List<TextPiece>> groups = groupByColumn(pieces, columns);
  final List<TextLine> lines = <TextLine>[];
  for (int i = 0; i < groups.length; i++) {
    lines.addAll(clusterLines(groups[i], column: i));
  }
  lines.sort((TextLine a, TextLine b) {
    if (a.column != b.column) {
      return a.column.compareTo(b.column);
    }
    return a.top.compareTo(b.top);
  });
  return PageLines(
    pageIndex: pageIndex,
    width: width,
    height: height,
    lines: dropMargins(lines, pageHeight: height, bandRatio: bandRatio),
  );
}
