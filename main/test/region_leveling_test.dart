import 'package:flutter_test/flutter_test.dart';
import 'package:shuaqi/domain/region/confidence.dart';
import 'package:shuaqi/domain/region/leveling.dart';
import 'package:shuaqi/domain/region/pattern.dart';

/// 层级判定（T3.2）。真机数据推翻了"字号优先"，这里锁定现行口径：
/// 样式优先 → 两级并存 → 字号兜底 → 全同级。
void main() {
  test('1. 中文数字题号直接判为大题（不看字号）', () {
    final Leveling result = assignLevels(
      <MarkKind>[
        MarkKind.cnNumeral,
        MarkKind.arabic,
        MarkKind.arabic,
        MarkKind.cnNumeral,
      ],
      // 故意让小题字号更大：真卷里公式对象会把"第 1 题"撑到 29pt
      <double>[11.6, 29.1, 11.8, 11.6],
    );
    expect(result.basis, 'style');
    expect(result.levels, <int>[1, 2, 2, 1]);
    expect(result.majorCount, 2);
  });

  test('2. 1. 与 (1) 并存 → 前者大题', () {
    final Leveling result = assignLevels(
      <MarkKind>[
        MarkKind.arabic,
        MarkKind.parenArabic,
        MarkKind.parenArabic,
        MarkKind.arabic,
      ],
      <double>[11, 11, 11, 11],
    );
    expect(result.basis, 'mixed');
    expect(result.levels, <int>[1, 2, 2, 1]);
  });

  test('3. 同一种题号 + 字号有断层 → 按字号分', () {
    final Leveling result = assignLevels(
      <MarkKind>[MarkKind.arabic, MarkKind.arabic, MarkKind.arabic],
      <double>[16, 11, 11],
    );
    expect(result.basis, 'font');
    expect(result.levels, <int>[1, 2, 2]);
    expect(result.threshold, 16);
  });

  test('4. 同一种题号 + 字号一致 → 全同级（都是小题）', () {
    final Leveling result = assignLevels(
      <MarkKind>[MarkKind.arabic, MarkKind.arabic],
      <double>[11, 11],
    );
    expect(result.basis, 'none');
    expect(result.levels, <int>[2, 2]);
  });

  test('5. 空输入与字号跳变不足阈值', () {
    expect(assignLevels(const <MarkKind>[], const <double>[]).levels, isEmpty);
    // 1.10 倍 < 1.15，不算断层
    final Leveling result = assignLevels(
      <MarkKind>[MarkKind.arabic, MarkKind.arabic],
      <double>[11, 12.1],
    );
    expect(result.basis, 'none');
  });

  test('6. 罗马数字与【例】也算大题样式', () {
    final Leveling result = assignLevels(
      <MarkKind>[MarkKind.roman, MarkKind.arabic, MarkKind.example],
      <double>[11, 11, 11],
    );
    expect(result.levels, <int>[1, 2, 1]);
  });

  group('confidence', () {
    test('1. 各项满分 → 绿', () {
      final double value = regionConfidence(
        const ConfidenceSignals(boundary: 1, style: 1, order: 1, text: 1),
      );
      expect(value, closeTo(1, 0.0001));
      expect(RegionGrade.of(value), RegionGrade.green);
    });

    test('2. OCR 来源整体 −0.20', () {
      double score(double boundary, {required bool ocr}) => regionConfidence(
        ConfidenceSignals(
          boundary: boundary,
          style: 1,
          order: 1,
          text: 1,
          fromOcr: ocr,
        ),
      );
      expect(
        score(0.5, ocr: true),
        closeTo(score(0.5, ocr: false) - 0.2, 0.0001),
      );
      // 同一份切题，OCR 来源直接掉一档颜色：绿 → 黄
      expect(RegionGrade.of(score(0.5, ocr: false)), RegionGrade.green);
      expect(RegionGrade.of(score(0.5, ocr: true)), RegionGrade.yellow);
    });

    test('3. 题号连续性与字号一致性', () {
      expect(orderScore(current: 5, previous: 4), 1);
      expect(orderScore(current: 6, previous: 4), 0.5, reason: '允许跳一个号');
      expect(orderScore(current: 9, previous: 4), 0.2);
      expect(orderScore(current: 2, previous: 5), 0);
      expect(styleScore(fontSize: 11, previousFontSize: 11), 1);
      // 字号只是近似值，差得远也只扣到 0.4，不一票否决
      expect(styleScore(fontSize: 20, previousFontSize: 11), 0.4);
    });

    test('4. 三色分级边界', () {
      expect(RegionGrade.of(0.80), RegionGrade.green);
      expect(RegionGrade.of(0.799), RegionGrade.yellow);
      expect(RegionGrade.of(0.55), RegionGrade.yellow);
      expect(RegionGrade.of(0.549), RegionGrade.red);
    });

    test('5. 留白过大只衰减不归零；最后一题给中性分', () {
      final double wide = boundaryScore(
        gap: 200,
        fontSize: 11,
        sameColumn: true,
        hasNext: true,
      );
      expect(wide, 0.3);
      expect(
        boundaryScore(gap: 0, fontSize: 11, sameColumn: true, hasNext: false),
        0.6,
      );
      expect(
        boundaryScore(gap: 5, fontSize: 11, sameColumn: false, hasNext: true),
        0.4,
      );
    });
  });
}
