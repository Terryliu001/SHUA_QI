import 'package:flutter_test/flutter_test.dart';
import 'package:shuaqi/domain/markup/math_segmenter.dart';

void main() {
  test('纯文本只有一段 Text', () {
    expect(segmentMath('你好，世界'), <MathSegment>[const TextSegment('你好，世界')]);
  });

  test('行内公式 \$…\$', () {
    expect(segmentMath(r'设 $x=1$，则'), <MathSegment>[
      const TextSegment('设 '),
      const FormulaSegment('x=1'),
      const TextSegment('，则'),
    ]);
  });

  test('行间公式 \$\$…\$\$', () {
    expect(segmentMath(r'$$\frac{a}{b}$$'), <MathSegment>[
      const FormulaSegment(r'\frac{a}{b}', display: true),
    ]);
  });

  test('\\(…\\) 与 \\[…\\] 等价转换', () {
    expect(segmentMath(r'\(a+b\)'), <MathSegment>[const FormulaSegment('a+b')]);
    expect(segmentMath(r'\[a+b\]'), <MathSegment>[
      const FormulaSegment('a+b', display: true),
    ]);
  });

  test('转义美元符是字面量', () {
    expect(segmentMath(r'价格 \$5'), <MathSegment>[const TextSegment(r'价格 $5')]);
  });

  test('未闭合的 \$ 余下全文当文本（流式安全）', () {
    expect(segmentMath(r'$\frac{x^2'), <MathSegment>[
      const TextSegment(r'$\frac{x^2'),
    ]);
  });

  test('未闭合的 \$\$ 也当文本', () {
    expect(segmentMath(r'$$\frac{x^2'), <MathSegment>[
      const TextSegment(r'$$\frac{x^2'),
    ]);
  });

  test('代码围栏里的 \$ 不解析', () {
    final List<MathSegment> segments = segmentMath(
      '```\n\$x=1\$\n```\n之后 \$y=2\$',
    );
    expect(segments.first, isA<TextSegment>());
    expect((segments.first as TextSegment).text, contains(r'$x=1$'));
    expect(segments.last, const FormulaSegment('y=2'));
  });

  test('行内代码里的 \$ 不解析', () {
    final List<MathSegment> segments = segmentMath('用 `\$x\$` 表示变量');
    expect(segments.first, isA<TextSegment>());
    expect((segments.first as TextSegment).text, contains(r'`$x$`'));
  });

  test('多个公式与文本混排', () {
    expect(segmentMath(r'a $b$ c $d$ e'), <MathSegment>[
      const TextSegment('a '),
      const FormulaSegment('b'),
      const TextSegment(' c '),
      const FormulaSegment('d'),
      const TextSegment(' e'),
    ]);
  });

  test('空的 \$\$ 保留为文本，不生成空公式', () {
    expect(segmentMath(r'a $$ b'), <MathSegment>[const TextSegment(r'a $$ b')]);
  });

  test('空字符串返回空列表', () {
    expect(segmentMath(''), isEmpty);
  });
}
