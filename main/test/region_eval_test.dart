import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shuaqi/domain/region/confidence.dart';
import 'package:shuaqi/domain/region/page_layout.dart';
import 'package:shuaqi/domain/region/region_rect.dart';
import 'package:shuaqi/domain/region/split.dart';
import 'package:shuaqi/domain/region/text_line.dart';

/// T3.2 的**评测表**（规格 04 §4 DoD：5 份试卷 × 可用率）。
///
/// 5 份卷子的文本层片段来自真机（pdfrx 抽取，`spikes/pdf_text_spike` 批量导出）：
/// - `math_midterm`：真实试卷（北邮 2025 期中，带答案与考试须知）；
/// - 另外 4 份由 `tool/make_test_papers.py` 生成，各自针对一种排版风险：
///   单栏纯数字、双栏、大题+括号小题、【例】+ 跨页长题。
///
/// "自动可用" 的口径：**切出来的题数 = 卷面实际题数**，且没有一个框越界/串栏。
/// 这是最保守的口径——多切一个框（比如把"考试须知"当题）就算这份卷子"需手改"。
void main() {
  final Map<String, _Expect> manifest = <String, _Expect>{
    // 文件名（不含 .json）: 期望
    'eval-single-column': const _Expect(marks: 11, regions: 10, columns: 1),
    'eval-double-column': const _Expect(marks: 9, regions: 8, columns: 2),
    'eval-paren-sub': const _Expect(marks: 20, regions: 16, columns: 1),
    'eval-example-crosspage': const _Expect(marks: 38, regions: 34, columns: 1),
  };

  group('评测卷（合成）', () {
    for (final MapEntry<String, _Expect> entry in manifest.entries) {
      final File file = File('test/fixtures/region/eval/${entry.key}.json');
      test('${entry.key}：题数/区域数/栏数符合预期', () {
        if (!file.existsSync()) {
          // 语料还没采（换机器/首次 clone）。跳过而不是失败：
          // 这些数据是用真机 pdfrx 抽的，宿主机造不出来。
          markTestSkipped('缺少评测语料 ${file.path}');
          return;
        }
        final _Result result = _run(file);
        // 打印成一行，`flutter test` 输出就是评测表的一行
        // ignore: avoid_print
        print(
          '${entry.key.padRight(24)} marks=${result.split.markCount} '
          'regions=${result.split.regionCount} '
          'G/Y/R=${result.gradeCounts} columns=${result.maxColumns}',
        );
        expect(result.split.markCount, entry.value.marks);
        expect(result.split.regionCount, entry.value.regions);
        expect(result.maxColumns, entry.value.columns);
      });

      test('${entry.key}：同一页的区域不重叠、不越界', () {
        if (!file.existsSync()) {
          markTestSkipped('缺少评测语料 ${file.path}');
          return;
        }
        final _Result result = _run(file);
        for (final RegionDraft draft in result.split.regions) {
          for (final PageSlice slice in draft.slices) {
            expect(slice.rect.top, greaterThanOrEqualTo(-0.01));
            expect(
              slice.rect.bottom,
              lessThanOrEqualTo(result.pageHeight(slice.pageIndex) + 0.01),
              reason: '${entry.key} #${draft.ordinal} 越出页底',
            );
            expect(slice.rect.left, greaterThanOrEqualTo(-0.01));
            expect(
              slice.rect.right,
              lessThanOrEqualTo(result.pageWidth(slice.pageIndex) + 0.01),
              reason: '${entry.key} #${draft.ordinal} 越出页右',
            );
          }
        }
        final Map<int, List<RegionRect>> byPage = <int, List<RegionRect>>{};
        for (final RegionDraft draft in result.split.regions) {
          for (final PageSlice slice in draft.slices) {
            byPage
                .putIfAbsent(slice.pageIndex, () => <RegionRect>[])
                .add(slice.rect);
          }
        }
        // 只比较"横向有交集"的两段：双栏页左右两栏的框在同一 y 上并存是正常的，
        // 真正的错误是同一栏里两个框上下打架。
        for (final MapEntry<int, List<RegionRect>> page in byPage.entries) {
          final List<RegionRect> rects = page.value
            ..sort((RegionRect a, RegionRect b) => a.top.compareTo(b.top));
          for (int i = 0; i < rects.length; i++) {
            for (int j = i + 1; j < rects.length; j++) {
              final bool overlapX =
                  rects[i].left < rects[j].right &&
                  rects[j].left < rects[i].right;
              if (!overlapX) {
                continue;
              }
              expect(
                rects[j].top,
                greaterThanOrEqualTo(rects[i].bottom - 0.01),
                reason: '${entry.key} 第 ${page.key} 页第 $j 段与第 $i 段上下重叠',
              );
            }
          }
        }
      });
    }

    test('双栏卷不出现跨栏巨框', () {
      final File file = File(
        'test/fixtures/region/eval/eval-double-column.json',
      );
      if (!file.existsSync()) {
        markTestSkipped('缺少评测语料 ${file.path}');
        return;
      }
      final _Result result = _run(file);
      final double pageWidth = result.pageWidth(0);
      for (final RegionDraft draft in result.split.regions) {
        for (final PageSlice slice in draft.slices) {
          expect(
            slice.rect.width,
            lessThan(pageWidth * 0.62),
            reason: '第 ${draft.ordinal} 题（${draft.label}）横跨了两栏',
          );
        }
      }
    });

    test('合成卷里绿色框占比 ≥ 80%', () {
      int green = 0;
      int total = 0;
      for (final String name in manifest.keys) {
        final File file = File('test/fixtures/region/eval/$name.json');
        if (!file.existsSync()) {
          continue;
        }
        final _Result result = _run(file);
        for (final RegionDraft draft in result.split.regions) {
          if (!draft.hasRegion) {
            continue;
          }
          total++;
          if (draft.grade == RegionGrade.green) {
            green++;
          }
        }
      }
      if (total == 0) {
        markTestSkipped('缺少评测语料');
        return;
      }
      // ignore: avoid_print
      print(
        '合成卷绿色占比 $green/$total = ${(green / total * 100).toStringAsFixed(1)}%',
      );
      expect(green / total, greaterThanOrEqualTo(0.8));
    });
  });
}

class _Expect {
  const _Expect({
    required this.marks,
    required this.regions,
    required this.columns,
  });

  final int marks;
  final int regions;
  final int columns;
}

class _Result {
  const _Result({
    required this.split,
    required this.pages,
    required this.gradeCounts,
    required this.maxColumns,
  });

  final SplitResult split;
  final List<PageLines> pages;
  final String gradeCounts;
  final int maxColumns;

  double pageWidth(int index) => pages[index].width;

  double pageHeight(int index) => pages[index].height;
}

/// 语料是"原始片段"（runs），这里复刻 App 里的第一步：片段 → 行。
_Result _run(File file) {
  final Map<String, Object?> json =
      jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
  final List<PageLines> pages = <PageLines>[];
  for (final Object? rawPage in json['pages']! as List<Object?>) {
    final Map<String, Object?> map = rawPage! as Map<String, Object?>;
    final List<TextPiece> pieces = <TextPiece>[];
    for (final Object? rawRun in map['runs']! as List<Object?>) {
      final List<Object?> run = rawRun! as List<Object?>;
      final String text = run[0]! as String;
      final double x = (run[1]! as num).toDouble();
      final double y = (run[2]! as num).toDouble();
      final double w = (run[3]! as num).toDouble();
      final double h = (run[4]! as num).toDouble();
      if (text.trim().isEmpty || w <= 0 || h <= 0) {
        continue;
      }
      pieces.add(
        TextPiece(text: text, rect: RegionRect.fromLTRB(x, y, x + w, y + h)),
      );
    }
    pages.add(
      buildPageLines(
        pageIndex: (map['index']! as num).toInt(),
        width: (map['w']! as num).toDouble(),
        height: (map['h']! as num).toDouble(),
        pieces: pieces,
      ),
    );
  }
  final SplitResult split = splitQuestions(pages);
  int green = 0;
  int yellow = 0;
  int red = 0;
  for (final RegionDraft draft in split.regions) {
    if (!draft.hasRegion) {
      continue;
    }
    switch (draft.grade) {
      case RegionGrade.green:
        green++;
      case RegionGrade.yellow:
        yellow++;
      case RegionGrade.red:
        red++;
    }
  }
  int maxColumns = 1;
  for (final PageLines page in pages) {
    final int columns =
        page.lines
            .map((TextLine l) => l.column)
            .fold<int>(0, (int a, int b) => a > b ? a : b) +
        1;
    if (columns > maxColumns) {
      maxColumns = columns;
    }
  }
  return _Result(
    split: split,
    pages: pages,
    gradeCounts: '$green/$yellow/$red',
    maxColumns: maxColumns,
  );
}
