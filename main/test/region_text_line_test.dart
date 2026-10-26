import 'package:flutter_test/flutter_test.dart';
import 'package:shuaqi/domain/region/columns.dart';
import 'package:shuaqi/domain/region/region_rect.dart';
import 'package:shuaqi/domain/region/text_line.dart';

/// 行聚类 / 字号估计 / 页眉页脚剔除（T3.1）。
/// 片段形态取自真卷实测：`12.` 会拆成 `1` `2` `.`，空格也是独立片段，`\n` 是零宽片段。
void main() {
  TextPiece piece(
    String text,
    double x,
    double y, {
    double width = 12,
    double height = 11,
  }) => TextPiece(
    text: text,
    rect: RegionRect.fromLTRB(x, y, x + width, y + height),
  );

  group('clusterLines', () {
    test('1. 同一基线上的碎片拼成一行，零宽与空片段被丢弃', () {
      final List<TextLine> lines = clusterLines(<TextPiece>[
        piece('1', 79.5, 103.3, width: 6.6),
        piece('2', 86.1, 103.3, width: 6.6),
        piece('.', 92.7, 103.3, width: 3),
        piece('求极限', 96.0, 103.3, width: 33),
        piece('\n', 129.0, 103.3, width: 0),
        piece('  ', 130.0, 103.3, width: 3.8),
      ]);
      expect(lines.length, 1);
      expect(lines.single.text, '12.求极限');
      expect(lines.single.left, 79.5);
    });

    test('2. 行距足够时分成两行（容差 0.5 倍行高）', () {
      final List<TextLine> lines = clusterLines(<TextPiece>[
        piece('第一行', 60, 100),
        piece('第二行', 60, 120),
      ]);
      expect(lines.length, 2);
      expect(lines.first.text, '第一行');
      expect(lines.last.text, '第二行');
    });

    test('3. 大间距补一个空格，小间距直接拼（中文不插空格）', () {
      // 间距 3.8pt < 0.8 × 11pt → 不插空格
      final List<TextLine> tight = clusterLines(<TextPiece>[
        piece('共', 60, 100, width: 10),
        piece('30', 73.8, 100, width: 10),
      ]);
      expect(tight.single.text, '共30');

      // 间距 20pt > 8.8pt → 插空格
      final List<TextLine> loose = clusterLines(<TextPiece>[
        piece('1.', 60, 100, width: 10),
        piece('求导', 90, 100, width: 20),
      ]);
      expect(loose.single.text, '1. 求导');
    });

    test('4. 字号取下四分位：多行公式对象不会把字号撑大', () {
      // 真卷实测：`1.` 与公式对象的片段高度 29.1，正文 11
      final List<TextPiece> pieces = <TextPiece>[
        for (int i = 0; i < 6; i++)
          piece('公式$i', 60 + i * 20, 100, width: 18, height: 29.1),
        for (int i = 0; i < 4; i++)
          piece('正文$i', 200 + i * 20, 100, width: 18, height: 11),
      ];
      final TextLine line = clusterLines(pieces).single;
      expect(line.fontSize, closeTo(11, 0.01));
    });

    test('5. 空输入不炸', () {
      expect(clusterLines(const <TextPiece>[]), isEmpty);
      expect(clusterLines(<TextPiece>[piece('   ', 0, 0)]), isEmpty);
    });
  });

  group('dropMargins', () {
    const double pageHeight = 842;

    TextLine lineAt(double top, String text) => TextLine(
      text: text,
      rect: RegionRect.fromLTRB(60, top, 400, top + 11),
      fontSize: 11,
      pieces: <TextPiece>[],
    );

    test('1. 页眉卷名与页脚水印被剔除', () {
      final List<TextLine> kept = dropMargins(<TextLine>[
        lineAt(30, '[分析上期中]2025–2026学年第一学期《数学分析（上）》期中考试试题'),
        lineAt(100, '1. 求极限'),
        lineAt(800, '©︎大邮数学集 ArtveFlinaInBupt/bump-archive 1/583'),
      ], pageHeight: pageHeight);
      expect(kept.map((TextLine l) => l.text), <String>['1. 求极限']);
    });

    test('2. 压在上边界带里的题号行必须保留（不能无脑切 5%）', () {
      final List<TextLine> kept = dropMargins(<TextLine>[
        lineAt(20, '3. 设函数 f(x) 连续'),
      ], pageHeight: pageHeight);
      expect(kept.length, 1);
    });

    test('2b. 页脚即使不在 5% 带内也剔除（第2页，共4页）', () {
      final List<TextLine> kept = dropMargins(<TextLine>[
        lineAt(760, '第2页，共4页'),
        lineAt(780, '6. 求下列极限'),
        lineAt(800, '第2页，共4页'),
      ], pageHeight: pageHeight);
      expect(kept.map((TextLine l) => l.text), <String>['6. 求下列极限']);
    });

    test('3. 带内的长正文保留，纯页码删除', () {
      final List<TextLine> kept = dropMargins(<TextLine>[
        lineAt(800, '第 3 页 共 8 页'),
        lineAt(805, '1/583'),
        lineAt(810, '这部分内容虽然落在页脚带内，但它明显是一段完整正文，需要保留下来不误删'),
      ], pageHeight: pageHeight);
      expect(kept.length, 1);
      expect(kept.single.text.startsWith('这部分内容'), isTrue);
    });
  });

  group('detectColumns', () {
    /// 造一行"密排正文"：从 [from] 到 [to] 每 18pt 一个片段（模拟真实文本层密度）。
    List<TextPiece> row(double from, double to, double y) {
      final List<TextPiece> pieces = <TextPiece>[];
      for (double x = from; x < to; x += 18) {
        pieces.add(
          TextPiece(text: '字', rect: RegionRect.fromLTRB(x, y, x + 14, y + 11)),
        );
      }
      return pieces;
    }

    test('1. 单栏：每一行都横跨中线，不切栏', () {
      final List<TextPiece> pieces = <TextPiece>[
        for (int i = 0; i < 10; i++) ...row(60, 535, 100 + i * 16),
      ];
      expect(detectColumns(pieces, pageWidth: 595).length, 1);
    });

    test('2. 双栏：左右各自成列、中间有整条空白带 → 切两栏', () {
      final List<TextPiece> pieces = <TextPiece>[
        for (int i = 0; i < 10; i++) ...row(60, 270, 100 + i * 16),
        for (int i = 0; i < 10; i++) ...row(325, 535, 104 + i * 16),
      ];
      final List<ColumnBand> columns = detectColumns(pieces, pageWidth: 595);
      expect(columns.length, 2);
      expect(columns.first.right, lessThanOrEqualTo(columns.last.left));
      expect(columns.first.right, greaterThan(270));
    });

    test('3. 居中标题横跨栏间距也不影响分栏（实测双栏卷就是这样）', () {
      final List<TextPiece> pieces = <TextPiece>[
        for (int i = 0; i < 6; i++) ...row(60, 270, 100 + i * 16),
        for (int i = 0; i < 6; i++) ...row(325, 535, 104 + i * 16),
        // 一行居中标题（横跨栏间距），只占整页 1 行
        TextPiece(
          text: '高等数学（上）期中试卷',
          rect: RegionRect.fromLTRB(215, 40, 380, 55),
        ),
      ];
      expect(detectColumns(pieces, pageWidth: 595).length, 2);
    });

    test('3b. 单栏页里被图注挖空也还是单栏', () {
      final List<TextPiece> pieces = <TextPiece>[
        for (int i = 0; i < 10; i++) ...row(60, 535, 100 + i * 16),
        // 图注：只在页面下半部占一块，横向也没挖穿整页
        TextPiece(text: '图 1', rect: RegionRect.fromLTRB(240, 300, 300, 380)),
      ];
      expect(detectColumns(pieces, pageWidth: 595).length, 1);
    });

    test('4. 按栏分组后每栏都有内容，且不串栏', () {
      final List<TextPiece> pieces = <TextPiece>[
        for (int i = 0; i < 6; i++) ...row(60, 270, 100 + i * 16),
        for (int i = 0; i < 6; i++) ...row(325, 535, 104 + i * 16),
      ];
      final List<ColumnBand> columns = detectColumns(pieces, pageWidth: 595);
      final List<List<TextPiece>> groups = groupByColumn(pieces, columns);
      expect(groups.length, 2);
      expect(groups.first.length + groups.last.length, pieces.length);
      // 左栏全在左边、右栏全在右边（按片段中心判栏）
      expect(
        groups.first.every((TextPiece p) => p.rect.centerX < columns.last.left),
        isTrue,
      );
      expect(
        groups.last.every((TextPiece p) => p.rect.centerX >= columns.last.left),
        isTrue,
      );
    });

    test('5. 全空输入返回单栏', () {
      expect(detectColumns(const <TextPiece>[], pageWidth: 595).length, 1);
    });
  });
}
