import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shuaqi/domain/region/columns.dart';
import 'package:shuaqi/domain/region/id_keep.dart';
import 'package:shuaqi/domain/region/region_rect.dart';
import 'package:shuaqi/domain/region/scan_lines.dart';
import 'package:shuaqi/domain/region/scan_split.dart';
import 'package:shuaqi/domain/region/split.dart';

/// 扫描件行级分析的单测：用**合成位图**，不依赖任何真实 PDF。
///
/// 为什么合成：真机拿不到稳定的扫描件样本，而这里的判据全是几何
/// （短块宽度、块后空白、左边距、行距倍数），合成图能把每一条边界钉死。
void main() {
  group('analyzeScanPage：行', () {
    test('两行正文 → 两行，且都没有题号特征', () {
      final _Canvas c = _Canvas();
      c.textLine(y: 40, blocks: 12);
      c.textLine(y: 90, blocks: 10);
      final ScanPage page = c.analyze();
      expect(page.lines.length, 2);
      expect(page.lines.every((ScanLine l) => !l.hasLeadToken), isTrue);
      expect(page.em, greaterThan(0));
    });

    test('题号行（短块 + 大空白 + 正文）被认出来', () {
      final _Canvas c = _Canvas();
      c.markLine(y: 40, tokenWidth: 14, gap: 12, bodyBlocks: 8);
      final ScanPage page = c.analyze();
      expect(page.lines.length, 1);
      expect(page.lines.first.hasLeadToken, isTrue);
      expect(page.lines.first.leadGap, greaterThan(0));
    });

    test('行内只有小间隙的正文不会被误判成题号行', () {
      final _Canvas c = _Canvas();
      c.textLine(y: 40, blocks: 14, blockGap: 2);
      final ScanPage page = c.analyze();
      expect(page.lines.single.hasLeadToken, isFalse);
    });

    test('横线（很矮的行）被剔除', () {
      final _Canvas c = _Canvas();
      c.rect(left: 20, top: 200, right: 560, bottom: 202); // 3px 高
      c.textLine(y: 40, blocks: 10);
      final ScanPage page = c.analyze();
      expect(page.lines.length, 1);
    });

    test('页脚带里的短行（页码）被剔除', () {
      final _Canvas c = _Canvas();
      c.textLine(y: 40, blocks: 12);
      c.rect(left: 280, top: 770, right: 320, bottom: 786); // 底部 5% 内的窄块
      final ScanPage page = c.analyze();
      expect(page.lines.length, 1);
    });
  });

  group('detectColumnsFromRects：分栏', () {
    test('左右两列 → 两栏', () {
      final List<RegionRect> rects = <RegionRect>[
        for (int i = 0; i < 8; i++)
          RegionRect.fromLTRB(20, 40.0 + i * 30, 260, 60.0 + i * 30),
        for (int i = 0; i < 8; i++)
          RegionRect.fromLTRB(340, 40.0 + i * 30, 580, 60.0 + i * 30),
      ];
      final List<ColumnBand> bands = detectColumnsFromRects(
        rects,
        pageWidth: 600,
      );
      expect(bands.length, 2);
    });
  });

  group('splitScanPages：整页切题', () {
    test('三道题 → 三段，标签是 1/2/3', () {
      final _Canvas c = _Canvas();
      c.markLine(y: 40, tokenWidth: 14, gap: 12, bodyBlocks: 8);
      c.textLine(y: 66, blocks: 12);
      c.textLine(y: 92, blocks: 11);
      c.markLine(y: 140, tokenWidth: 14, gap: 12, bodyBlocks: 9);
      c.textLine(y: 166, blocks: 12);
      c.markLine(y: 240, tokenWidth: 14, gap: 12, bodyBlocks: 7);
      c.textLine(y: 266, blocks: 12);

      final SplitResult result = splitScanPages(<ScanPage>[c.analyze()]);
      final List<RegionDraft> withRegion = result.regions
          .where((RegionDraft d) => d.hasRegion)
          .toList();
      expect(withRegion.length, 3);
      expect(withRegion.map((RegionDraft d) => d.label).toList(), <String>[
        '1',
        '2',
        '3',
      ]);
      // 扫描件：来源必须是 layout（版面推断），题型不能虚报
      expect(withRegion.every((RegionDraft d) => d.source == 'layout'), isTrue);
      expect(withRegion.every((RegionDraft d) => d.kind == 'unknown'), isTrue);
      // 一律黄框（置信度 −0.20）
      expect(withRegion.every((RegionDraft d) => d.confidence < 0.80), isTrue);
      // 框要从题号行的上沿开始，不能把上一题的尾巴吃进来
      expect(withRegion.first.slices.first.rect.top, lessThan(40 * 842 / 800));
    });

    test('短标题行（大间隔 + 窄）判为小节容器，不占区域', () {
      final _Canvas c = _Canvas();
      c.markLine(
        y: 30,
        tokenWidth: 24,
        gap: 10,
        bodyBlocks: 2,
        kind: _MarkShape.cn,
      ); // 一、填空题（窄）
      c.markLine(y: 130, tokenWidth: 14, gap: 12, bodyBlocks: 12);
      c.textLine(y: 156, blocks: 14);
      c.markLine(y: 210, tokenWidth: 14, gap: 12, bodyBlocks: 12);
      c.textLine(y: 236, blocks: 14);

      final SplitResult result = splitScanPages(<ScanPage>[c.analyze()]);
      final List<RegionDraft> withRegion = result.regions
          .where((RegionDraft d) => d.hasRegion)
          .toList();
      expect(withRegion.length, 2);
      expect(result.regions.first.level, 1);
      expect(result.regions.first.hasRegion, isFalse);
    });

    test('没有任何题号特征 → 0 段（调用方会退块级兜底）', () {
      final _Canvas c = _Canvas();
      c.textLine(y: 40, blocks: 14);
      c.textLine(y: 90, blocks: 14);
      final SplitResult result = splitScanPages(<ScanPage>[c.analyze()]);
      expect(result.regionCount, 0);
      expect(result.warnings, isNotEmpty);
    });

    test('题号后只有一个很小的空格（≈0.19em）也能认出来（真机教训）', () {
      final _Canvas c = _Canvas();
      // 真卷：10.5pt 字 + 半角空格 → 空格只有 0.19 em；门槛曾是 0.26，
      // 整页一条题号都认不出（北邮试卷第 1 页 0 框事故）
      c.markLine(y: 40, tokenWidth: 14, gap: 4, bodyBlocks: 10);
      final ScanPage page = c.analyze();
      expect(page.lines.single.hasLeadToken, isTrue);
    });

    test('缩进更深的"题号行"（选择题选项）不会切出假框', () {
      final _Canvas c = _Canvas();
      c.markLine(y: 40, tokenWidth: 14, gap: 12, bodyBlocks: 10);
      // 下一行、缩进 40px（2em）：这是选项行的典型形态（真实卷子是 2 个字）
      c.markLine(y: 66, tokenWidth: 12, gap: 10, bodyBlocks: 4, left: 70);
      c.markLine(y: 92, tokenWidth: 12, gap: 10, bodyBlocks: 4, left: 70);
      c.markLine(y: 140, tokenWidth: 14, gap: 12, bodyBlocks: 10);
      final SplitResult result = splitScanPages(<ScanPage>[c.analyze()]);
      expect(result.regionCount, 2);
    });

    test('句中逗号触发的假题号（块宽离群）被全卷一致性闸拒绝', () {
      final _Canvas c = _Canvas();
      // 4 道真题号，每道后面跟两行正文（页面里绝大多数间隙是行距，
      // 行段才不会互相合并）
      for (int i = 0; i < 4; i++) {
        final double y = 40.0 + i * 118;
        c.markLine(y: y, tokenWidth: 14, gap: 12, bodyBlocks: 10);
        c.textLine(y: y + 26, blocks: 12);
        c.textLine(y: y + 52, blocks: 12);
      }
      // `础上，指出…`：行首块是"2 个字 + 全角标点" ≈ 2.1em，
      // 逗号后有 0.5em 空白 —— 几何上完全像题号，只能靠"块宽离群"否掉
      c.markLine(y: 118, tokenWidth: 44, gap: 10, bodyBlocks: 6);
      final SplitResult result = splitScanPages(<ScanPage>[c.analyze()]);
      expect(result.regionCount, 4);
    });

    test('双栏扫描页不会出现跨栏巨框', () {
      final _Canvas c = _Canvas();
      for (int i = 0; i < 3; i++) {
        final double y = 40.0 + i * 60;
        c.markLine(y: y, tokenWidth: 14, gap: 12, bodyBlocks: 10, left: 20);
        c.textLine(y: y + 34, blocks: 12, left: 20);
        c.markLine(y: y, tokenWidth: 14, gap: 12, bodyBlocks: 10, left: 340);
        c.textLine(y: y + 34, blocks: 12, left: 340);
      }
      final ScanPage page = c.analyze();
      final SplitResult result = splitScanPages(<ScanPage>[page]);
      final List<RegionDraft> withRegion = result.regions
          .where((RegionDraft d) => d.hasRegion)
          .toList();
      expect(withRegion.length, 6);
      // 每一段都必须完整落在自己那一栏里：不许出现"左边界在左栏、右边界在右栏"的巨框
      for (final RegionDraft draft in withRegion) {
        for (final PageSlice slice in draft.slices) {
          final bool inLeft = slice.rect.right <= 240;
          final bool inRight = slice.rect.left >= 330;
          expect(inLeft || inRight, isTrue);
        }
      }
    });
  });

  group('matchExistingQuestionIds：重算保住 question.id', () {
    test('没动过的题按 key 精确复用', () {
      final List<String?> ids = matchExistingQuestionIds(
        oldIdByKey: <String, String>{'1.|0|100': 'q1', '2.|0|300': 'q2'},
        newKeys: <String>['1.|0|100', '2.|0|300'],
      );
      expect(ids, <String>['q1', 'q2']);
    });

    test('拖动后 y 变了，仍按"同题号 + 同页 + y 差 ≤80"认回来', () {
      final List<String?> ids = matchExistingQuestionIds(
        oldIdByKey: <String, String>{'3.|1|518': 'q3'},
        newKeys: <String>['3.|1|470'],
      );
      expect(ids.single, 'q3');
    });

    test('新题（手画/拆分下段）拿不到旧 id', () {
      final List<String?> ids = matchExistingQuestionIds(
        oldIdByKey: <String, String>{'1.|0|100': 'q1'},
        newKeys: <String>['手画|0|500'],
      );
      expect(ids.single, isNull);
    });

    test('一个旧 id 只能被认领一次', () {
      final List<String?> ids = matchExistingQuestionIds(
        oldIdByKey: <String, String>{'1.|0|100': 'q1'},
        newKeys: <String>['1.|0|100', '1.|0|110'],
      );
      expect(ids[0], 'q1');
      expect(ids[1], isNull);
    });
  });
}

/// 合成题号的字形类别。
enum _MarkShape { arabic, cn }

/// 合成位图：白底黑"字"。
class _Canvas {
  _Canvas() {
    _luma.fillRange(0, _luma.length, 255);
  }

  static const int width = 600;
  static const int height = 800;
  static const double pageWidthPt = 595;
  static const double pageHeightPt = 842;

  final Uint8List _luma = Uint8List(width * height);

  Uint8List get luma => Uint8List.fromList(_luma);

  void rect({
    required double left,
    required double top,
    required double right,
    required double bottom,
  }) {
    for (int y = top.round(); y < bottom.round() && y < height; y++) {
      for (int x = left.round(); x < right.round() && x < width; x++) {
        _luma[y * width + x] = 0;
      }
    }
  }

  /// 一行正文：若干个 16px 宽的字块，字间 2px。
  void textLine({
    required double y,
    int blocks = 12,
    int blockGap = 2,
    int blockWidth = 16,
    double left = 30,
    int lineHeight = 20,
  }) {
    double x = left;
    for (int i = 0; i < blocks; i++) {
      rect(left: x, top: y, right: x + blockWidth, bottom: y + lineHeight);
      x += blockWidth + blockGap;
    }
  }

  /// 一行"题号 + 题干"：**按字形画**，不是一根实心短块。
  ///
  /// 2026-10-23 起题号识别看的是"第一个字的形状"（数字/括号是窄而稀的
  /// 连通域，汉字是宽而密的连通域）。实心矩形在统计上更像汉字，测不出
  /// 真实行为，所以这里画成：空心数字框 + 基点上的小数点；中文序号画成
  /// 横画 + 顿号。
  void markLine({
    required double y,
    required double tokenWidth,
    required double gap,
    int bodyBlocks = 8,
    double left = 30,
    int blockWidth = 16,
    int blockGap = 2,
    int lineHeight = 20,
    _MarkShape kind = _MarkShape.arabic,
  }) {
    double x;
    if (kind == _MarkShape.cn) {
      // `一、`：宽扁横画 + 顿号（宽 6px，比句点宽）。
      rect(
        left: left,
        top: y + lineHeight * 0.45,
        right: left + tokenWidth,
        bottom: y + lineHeight * 0.65,
      );
      rect(
        left: left + tokenWidth + 3,
        top: y + lineHeight * 0.65,
        right: left + tokenWidth + 9,
        bottom: y + lineHeight * 0.85,
      );
      x = left + tokenWidth + gap + 6;
    } else {
      // 数字：空心框（墨占约 0.1 字高²）+ 右下角小数点。
      final double digitWidth = math.max(4, tokenWidth - 5);
      hollow(
        left: left,
        top: y + lineHeight * 0.2,
        right: left + digitWidth,
        bottom: y + lineHeight * 0.9,
      );
      rect(
        left: left + digitWidth + 2,
        top: y + lineHeight * 0.8,
        right: left + digitWidth + 5,
        bottom: y + lineHeight * 0.9,
      );
      x = left + tokenWidth + gap;
    }
    for (int i = 0; i < bodyBlocks; i++) {
      rect(left: x, top: y, right: x + blockWidth, bottom: y + lineHeight);
      x += blockWidth + blockGap;
    }
  }

  /// 空心矩形（模拟数字的笔画，而不是实心块）。
  void hollow({
    required double left,
    required double top,
    required double right,
    required double bottom,
  }) {
    rect(left: left, top: top, right: right, bottom: top + 1);
    rect(left: left, top: bottom - 1, right: right, bottom: bottom);
    rect(left: left, top: top, right: left + 1, bottom: bottom);
    rect(left: right - 1, top: top, right: right, bottom: bottom);
  }

  ScanPage analyze({int? pageIndex}) => analyzeScanPage(
    luma: luma,
    width: width,
    height: height,
    pageIndex: pageIndex ?? 0,
    pageWidthPt: pageWidthPt,
    pageHeightPt: pageHeightPt,
  );
}
