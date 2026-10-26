import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shuaqi/domain/region/confidence.dart';
import 'package:shuaqi/domain/region/page_layout.dart';
import 'package:shuaqi/domain/region/region_rect.dart';
import 'package:shuaqi/domain/region/split.dart';
import 'package:shuaqi/domain/region/text_line.dart';

/// 切题（T3.2）的行为锁定。
///
/// 最后一组用**真卷片段**（`test/fixtures/region/math_midterm.json`，
/// 由 `spikes/pdf_text_spike` 从 `demo_assets/math_analysis_midterm.pdf` 采出）跑
/// 端到端：真卷是最容易让规则翻车的东西——多行公式的 `bounds.height` 会把
/// "第 1 题"撑到 29pt，任何"按字号判层级"的写法都会在这里露馅。
void main() {
  TextLine line(
    String text, {
    required double top,
    double left = 60,
    double right = 400,
    double fontSize = 11,
    int column = 0,
  }) => TextLine(
    text: text,
    rect: RegionRect.fromLTRB(left, top, right, top + fontSize),
    fontSize: fontSize,
    pieces: const <TextPiece>[],
    column: column,
  );

  PageLines page(List<TextLine> lines, {int index = 0}) =>
      PageLines(pageIndex: index, width: 595, height: 842, lines: lines);

  group('splitQuestions', () {
    test('1. 三题连续：区域首尾相接且不重叠', () {
      final SplitResult result = splitQuestions(<PageLines>[
        page(<TextLine>[
          line('1. 求下列极限', top: 100),
          line('2. 设函数 f(x) 连续', top: 140),
          line('3. 计算积分', top: 180),
        ]),
      ]);
      expect(result.markCount, 3);
      final List<RegionDraft> withRegion = result.regions
          .where((RegionDraft r) => r.hasRegion)
          .toList();
      expect(withRegion.length, 3);
      // 题 1 的框顶在题号行之上，底在题 2 之前
      final RegionRect first = withRegion[0].slices.single.rect;
      expect(first.top, lessThan(100));
      expect(first.bottom, lessThanOrEqualTo(140));
      // 相邻框不重叠
      final RegionRect second = withRegion[1].slices.single.rect;
      expect(first.bottom, lessThanOrEqualTo(second.top));
    });

    test('2. 大题只当容器不占区域，小题挂在它下面', () {
      final SplitResult result = splitQuestions(<PageLines>[
        page(<TextLine>[
          line('一、填空题（共30分）', top: 60),
          line('1. 设 f(x)=x', top: 90),
          line('2. 求导', top: 120),
          line('二、选择题（共30分）', top: 160),
          line('1. 下列正确的是（ ）', top: 190),
        ]),
      ]);
      final RegionDraft heading = result.regions.first;
      expect(heading.level, 1);
      expect(heading.hasRegion, isFalse, reason: '大题占区域会吞掉小题');
      final List<RegionDraft> minors = result.regions
          .where((RegionDraft r) => r.level == 2)
          .toList();
      expect(minors.length, 3);
      expect(minors.first.parentOrdinal, 1);
      expect(minors.last.parentOrdinal, 4, reason: '第二道小题挂到"二、"下面');
      // 大题标题行不计入上一题的题干
      expect(minors[1].stem.contains('二、'), isFalse);
    });

    test('3. 大题没有小题时自己占区域（三、四、这类独立大题）', () {
      final SplitResult result = splitQuestions(<PageLines>[
        page(<TextLine>[
          line('三、（14分）求函数间断点', top: 100),
          line('四、（12分）设极限存在', top: 200),
        ]),
      ]);
      expect(result.regions.length, 2);
      expect(result.regions.every((RegionDraft r) => r.hasRegion), isTrue);
      expect(result.regions.first.kind, 'essay');
    });

    test('4. 跨页题写两段：第一页到页底，第二页从内容顶到下一个题号', () {
      final SplitResult result = splitQuestions(<PageLines>[
        page(<TextLine>[line('1. 长题开始', top: 700), line('继续作答', top: 760)]),
        page(<TextLine>[
          line('继续作答的第二页', top: 60),
          line('2. 下一题', top: 200),
        ], index: 1),
      ]);
      final RegionDraft first = result.regions.first;
      expect(first.slices.length, 2);
      expect(first.slices.first.pageIndex, 0);
      expect(first.slices.last.pageIndex, 1);
      expect(
        first.slices.first.rect.bottom,
        closeTo(771, 0.5),
        reason: '到页内容底',
      );
      expect(first.slices.last.rect.top, closeTo(60, 0.5), reason: '从下一页内容顶');
      expect(first.slices.last.rect.bottom, lessThanOrEqualTo(200));
    });

    test('5. 小题继承大题标题的题型（填空题干里没有"填空"二字）', () {
      final SplitResult result = splitQuestions(<PageLines>[
        page(<TextLine>[
          line('一、填空题（共30分，每小题5分）', top: 60),
          line('1. 设 f(x)=x，则 f(f(x))= ', top: 90),
        ]),
      ]);
      expect(result.regions.last.kind, 'blank');
    });

    test('6. 没有文本层时给出 L2 提示而不是抛异常', () {
      final SplitResult result = splitQuestions(<PageLines>[
        page(const <TextLine>[]),
      ]);
      expect(result.regions, isEmpty);
      expect(result.warnings.single, contains('扫描件'));
    });

    test('7. 置信度落在 0..1，且顺序型提示不会让好题变红', () {
      final SplitResult result = splitQuestions(<PageLines>[
        page(<TextLine>[
          line('一、填空题', top: 60),
          line('1. 设函数 f(x) 在 x=0 处连续，求 a 的值', top: 90),
          line('2. 计算下列极限', top: 130),
        ]),
      ]);
      for (final RegionDraft draft in result.regions) {
        expect(draft.confidence, inInclusiveRange(0, 1));
      }
      expect(
        result.regions.where((RegionDraft r) => r.hasRegion).first.grade,
        isNot(RegionGrade.red),
      );
    });
  });

  group('真卷端到端（math_analysis_midterm.pdf）', () {
    late SplitResult result;

    setUpAll(() {
      final Map<String, Object?> json = jsonDecode(
        File('test/fixtures/region/math_midterm.json').readAsStringSync(),
      ) as Map<String, Object?>;
      final List<Object?> pages = json['pages']! as List<Object?>;
      final List<PageLines> pageLines = <PageLines>[];
      for (final Object? rawPage in pages) {
        final Map<String, Object?> map = rawPage! as Map<String, Object?>;
        final List<Object?> runs = map['runs']! as List<Object?>;
        final List<TextPiece> pieces = <TextPiece>[];
        for (final Object? rawRun in runs) {
          final List<Object?> run = rawRun! as List<Object?>;
          final String text = run[0]! as String;
          if (text.trim().isEmpty) {
            continue;
          }
          final double x = (run[1]! as num).toDouble();
          final double y = (run[2]! as num).toDouble();
          final double w = (run[3]! as num).toDouble();
          final double h = (run[4]! as num).toDouble();
          if (w <= 0 || h <= 0) {
            continue;
          }
          pieces.add(
            TextPiece(
              text: text,
              rect: RegionRect.fromLTRB(x, y, x + w, y + h),
            ),
          );
        }
        pageLines.add(
          buildPageLines(
            pageIndex: (map['index']! as num).toInt(),
            width: (map['w']! as num).toDouble(),
            height: (map['h']! as num).toDouble(),
            pieces: pieces,
          ),
        );
      }
      result = splitQuestions(pageLines);
    });

    test('1. 命中 18 个题号：两道大题 + 12 道小题 + 4 道独立大题', () {
      expect(result.markCount, 18);
      expect(result.leveling.basis, 'style', reason: '中文数字标题必须优先判大题');
      expect(result.leveling.majorCount, 6);
      expect(result.leveling.minorCount, 12);
    });

    test('2. 每道小题都有区域，且区域不越过下一题的题号行', () {
      final List<RegionDraft> minors = result.regions
          .where((RegionDraft r) => r.level == 2)
          .toList();
      expect(minors.length, 12);
      expect(minors.every((RegionDraft r) => r.hasRegion), isTrue);
      // 第 1 题在第 1 页，框顶必须压在自己的题号行上方、底在下一题之前
      final RegionDraft first = minors.first;
      expect(first.slices.single.pageIndex, 0);
      expect(first.slices.single.rect.top, closeTo(100.3, 1));
      expect(first.slices.single.rect.bottom, lessThan(146));
    });

    test('3. 题型继承生效：填空题里的小题是 blank，选择题里是 choice', () {
      final List<RegionDraft> minors = result.regions
          .where((RegionDraft r) => r.level == 2)
          .toList();
      // 填空节：前 5 道是纯填空；第 6 道自带"填对或错"，自己判成判断题
      expect(
        minors.take(5).every((RegionDraft r) => r.kind == 'blank'),
        isTrue,
      );
      expect(minors[5].kind, 'judge');
      // 选择节：选项齐备，全部 choice
      expect(
        minors.skip(6).every((RegionDraft r) => r.kind == 'choice'),
        isTrue,
      );
    });

    test('4. 同一页上的区域两两不重叠（切题不能切出交叉框）', () {
      final Map<int, List<RegionRect>> byPage = <int, List<RegionRect>>{};
      for (final RegionDraft draft in result.regions) {
        for (final PageSlice slice in draft.slices) {
          byPage
              .putIfAbsent(slice.pageIndex, () => <RegionRect>[])
              .add(slice.rect);
        }
      }
      for (final MapEntry<int, List<RegionRect>> entry in byPage.entries) {
        final List<RegionRect> rects = entry.value
          ..sort((RegionRect a, RegionRect b) => a.top.compareTo(b.top));
        for (int i = 1; i < rects.length; i++) {
          expect(
            rects[i].top,
            greaterThanOrEqualTo(rects[i - 1].bottom - 0.01),
            reason: '第 ${entry.key} 页第 $i 段与前一段重叠',
          );
        }
      }
    });

    test('5. 页眉与页脚水印没有混进任何题干', () {
      for (final RegionDraft draft in result.regions) {
        expect(draft.stem.contains('bump-archive'), isFalse);
        expect(draft.stem.contains('分析上期中'), isFalse);
      }
    });

    test('6. 至少七成小题是绿框（构成可用率的底线）', () {
      final List<RegionDraft> minors = result.regions
          .where((RegionDraft r) => r.hasRegion)
          .toList();
      final int green = minors
          .where((RegionDraft r) => r.grade.name == 'green')
          .length;
      expect(green / minors.length, greaterThan(0.7));
    });
  });

  group('含答案的卷', () {
    test('7. 文末参考答案区：答案编号不再切题，最后一题止于标题', () {
      final SplitResult answered = splitQuestions(<PageLines>[
        page(<TextLine>[
          line('1. 第一题', top: 100),
          line('2. 第二题', top: 140),
          line('参考答案', top: 200, fontSize: 12),
          line('1. 答案一', top: 230),
          line('2. 答案二', top: 260),
        ]),
      ]);
      expect(answered.markCount, 2);
      final List<RegionDraft> regions = answered.regions
          .where((RegionDraft r) => r.hasRegion)
          .toList();
      expect(regions.length, 2);
      // 最后一题的框必须停在"参考答案"标题之前，不能把答案吞进去
      expect(regions.last.slices.last.rect.bottom, lessThan(200));
    });

    test('8. 题内解答步骤（1）（2）不另起题，解析单独入库、题干截断', () {
      final SplitResult answered = splitQuestions(<PageLines>[
        page(<TextLine>[
          line('1. 求极限', top: 100),
          line('解：', top: 130),
          line('（1）第一步', top: 160),
          line('（2）第二步', top: 190),
          line('2. 下一题', top: 230),
        ]),
      ]);
      expect(answered.markCount, 2);
      final List<RegionDraft> regions = answered.regions
          .where((RegionDraft r) => r.hasRegion)
          .toList();
      expect(regions.length, 2);
      expect(regions.first.stem, contains('求极限'));
      expect(regions.first.stem, isNot(contains('第一步')));
      expect(
        answered.answers.forQuestion(ordinal: 1, label: '1.')?.text,
        contains('第一步'),
      );
      expect(regions.first.slices.last.rect.bottom, lessThanOrEqualTo(230));
    });

    test('9. 题内 `答案：B` 不会被当成答案区标题', () {
      final SplitResult answered = splitQuestions(<PageLines>[
        page(<TextLine>[
          line('1. 第一题', top: 100),
          line('答案：B', top: 130),
          line('2. 第二题', top: 170),
        ]),
      ]);
      expect(answered.markCount, 2);
      expect(answered.regions.where((RegionDraft r) => r.hasRegion).length, 2);
    });

    test('10. 文末答案区：按题号抽答案，不吞进题目框', () {
      final SplitResult result = splitQuestions(<PageLines>[
        page(<TextLine>[
          line('1. 第一题', top: 100),
          line('2. 第二题', top: 140),
          line('参考答案', top: 200),
          line('1. A', top: 230),
          line('2. 解：由题意得 B', top: 260),
          line('所以选 B', top: 290),
        ]),
      ]);
      expect(result.answers.forLabel('1.')?.text, '1. A');
      expect(result.answers.forLabel('2.')?.text, contains('所以选 B'));
      final RegionDraft last = result.regions.last;
      expect(last.slices.single.rect.bottom, lessThanOrEqualTo(200));
    });

    test('11. 压缩答案键：1.A 2.B 3.C', () {
      final SplitResult result = splitQuestions(<PageLines>[
        page(<TextLine>[
          line('1. 第一题', top: 100),
          line('2. 第二题', top: 140),
          line('3. 第三题', top: 180),
          line('参考答案', top: 220),
          line('1.A 2.B 3.C', top: 250),
        ]),
      ]);
      expect(result.answers.forLabel('1')?.text, 'A');
      expect(result.answers.forLabel('2')?.text, 'B');
      expect(result.answers.forLabel('3')?.text, 'C');
    });
  });
}
