import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shuaqi/domain/region/layout_blocks.dart';

/// 纯版面切块（扫描件降级路径）。用合成位图测，不需要真扫描件。
///
/// 造数据刻意贴近真卷：**一页有很多行**（不是两个实心色块）。因为算法要先从
/// "空白带长度的中位数"估出本页行距，只有一个空隙时估不准——这正是真机上踩过的坑
/// （同一套固定阈值在 A4 与 200dpi 扫描件上效果差 7 倍）。
void main() {
  const int width = 200;
  const int lineHeight = 8;
  const int lineGap = 5;

  /// 一行"文字"：宽 [inkWidth]，隔一个字留白（真实正文的暗像素占比约 10–30%）。
  void paintLine(
    Uint8List luma,
    int y, {
    int inkWidth = 120,
    int leftInset = 20,
  }) {
    for (int x = leftInset; x < leftInset + inkWidth && x < width; x++) {
      if ((x ~/ 6).isEven) {
        luma[y * width + x] = 20;
      }
    }
  }

  /// 造一页：[paragraphs] 每段多少行；段内行距 [lineGap]，段间额外 [paraGap] 行。
  Uint8List page(
    int height,
    List<int> paragraphs, {
    int paraGap = 10,
    int top = 40,
    int inkWidth = 120,
  }) {
    final Uint8List luma = Uint8List(width * height)
      ..fillRange(0, width * height, 255);
    int y = top;
    for (int p = 0; p < paragraphs.length; p++) {
      for (int l = 0; l < paragraphs[p]; l++) {
        for (int i = 0; i < lineHeight && y + i < height; i++) {
          paintLine(luma, y + i, inkWidth: inkWidth);
        }
        y += lineHeight + lineGap;
      }
      y += paraGap;
    }
    return luma;
  }

  List<LayoutBlock> cut(
    Uint8List luma, {
    int height = 400,
    LayoutBlockOptions? options,
  }) {
    return detectLayoutBlocks(
      luma: luma,
      width: width,
      height: height,
      pageWidthPt: 400,
      pageHeightPt: 800,
      options: options ?? const LayoutBlockOptions(),
    );
  }

  test('1. 两段之间的大空白 → 切成两块', () {
    final List<LayoutBlock> blocks = cut(page(400, <int>[4, 4]));
    expect(blocks.length, 2);
    expect(blocks.first.rect.top, closeTo(77, 4));
    expect(blocks.last.rect.top, greaterThan(blocks.first.rect.bottom));
  });

  test('2. 段间距只有行距那么大 → 不断开（还在同一题里）', () {
    final List<LayoutBlock> blocks = cut(page(400, <int>[4, 4], paraGap: 0));
    expect(blocks.length, 1);
  });

  test('2b. 紧排卷子：段间距 1.5 倍行距也要切开（真卷常见）', () {
    // paraGap=3 行 + 行距 5 行 = 8 行 = 1.6 倍行距
    final List<LayoutBlock> blocks = cut(page(400, <int>[4, 4], paraGap: 3));
    expect(blocks.length, 2, reason: '1.8 倍门槛切不开这种紧排卷子');
  });

  test('3. 又窄又矮的块被丢掉（页码/装订线黑点）', () {
    final Uint8List luma = page(400, <int>[6]);
    // 正文之后 20 行处放一个 3 个字宽的"页码"
    const int y = 40 + 6 * (lineHeight + lineGap) + 20;
    for (int i = 0; i < lineHeight; i++) {
      paintLine(luma, y + i, inkWidth: 16);
    }
    final List<LayoutBlock> blocks = cut(luma);
    expect(blocks.length, 1, reason: '窄块应该被丢掉，只留正文');
    expect(blocks.single.rect.width, greaterThan(100));
  });

  test('4. 全白页 → 零块（空页不该产出假框）', () {
    final Uint8List blank = Uint8List(width * 400)
      ..fillRange(0, width * 400, 255);
    expect(cut(blank), isEmpty);
  });

  test('5. 横向范围贴住墨迹而不是整页宽', () {
    final List<LayoutBlock> blocks = cut(page(400, <int>[6], inkWidth: 100));
    final LayoutBlock block = blocks.single;
    // leftInset=20px → 40pt；inkWidth=100px → 到 240pt
    expect(block.rect.left, closeTo(44, 6));
    expect(block.rect.right, lessThan(400), reason: '不能撑成整页宽');
    expect(block.rect.right, closeTo(235, 14));
  });

  test('6. 整页是一张图 → 被 maxBlocks 兜住，不会切成上百条', () {
    final List<LayoutBlock> blocks = cut(
      page(400, List<int>.filled(24, 1), paraGap: 6),
      options: const LayoutBlockOptions(maxBlocks: 6),
    );
    expect(blocks.length, lessThanOrEqualTo(6));
  });

  test('7. 单行尾巴（选项行）并入上一段，不单独成框', () {
    // 段间距 4 行（= 1.8 倍行距，刚好够"切开"），但尾巴只有一行 → 并回去
    final List<LayoutBlock> blocks = cut(page(400, <int>[4, 1], paraGap: 4));
    expect(blocks.length, 1, reason: '一行的尾巴应该并进上一题');
  });

  test('8. 尾巴是整段就不合并（那是新的一题）', () {
    final List<LayoutBlock> blocks = cut(page(400, <int>[4, 4]));
    expect(blocks.length, 2);
  });

  test('9. 行距放大 2.8 倍（200dpi 扫描件）用同一套参数仍正确', () {
    Uint8List scaled(int height, List<int> paras) {
      final Uint8List luma = Uint8List(width * height)
        ..fillRange(0, width * height, 255);
      int y = 110;
      for (int p = 0; p < paras.length; p++) {
        for (int l = 0; l < paras[p]; l++) {
          for (int i = 0; i < 22 && y + i < height; i++) {
            paintLine(luma, y + i);
          }
          y += 22 + 14;
        }
        y += 28;
      }
      return luma;
    }

    final List<LayoutBlock> blocks = detectLayoutBlocks(
      luma: scaled(1120, <int>[4, 4]),
      width: width,
      height: 1120,
      pageWidthPt: 1684,
      pageHeightPt: 2384,
    );
    expect(blocks.length, 2, reason: '放大后应仍切成两块，而不是一块或碎成很多块');
  });

  test('10. BGRA → 灰度：通道顺序不能搞反', () {
    final Uint8List bgra = Uint8List.fromList(<int>[
      0,
      0,
      255,
      255,
      255,
      0,
      0,
      255,
      255,
      255,
      255,
      255,
      0,
      0,
      0,
      255,
    ]);
    final Uint8List luma = bgraToLuma(bgra, 4);
    expect(luma[0], 76, reason: '红');
    expect(luma[1], 29, reason: '蓝');
    expect(luma[2], 255, reason: '白');
    expect(luma[3], 0, reason: '黑');
  });

  test('11. 尺寸不合法时返回空，不崩', () {
    expect(
      detectLayoutBlocks(
        luma: Uint8List(0),
        width: 0,
        height: 0,
        pageWidthPt: 0,
        pageHeightPt: 0,
      ),
      isEmpty,
    );
  });
}
