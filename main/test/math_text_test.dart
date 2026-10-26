import 'package:flutter_test/flutter_test.dart';
import 'package:shuaqi/domain/region/math_text.dart';

/// 公式显示归一化：PDF 文本层保留原始 Unicode，界面只做"可读的纯文本"。
void main() {
  group('mathForDisplay', () {
    test('数学斜体字母折成 ASCII', () {
      expect(mathForDisplay('𝑓(𝑥)'), 'f(x)');
      expect(mathForDisplay('𝑥→∞'), 'x-> inf ');
      expect(mathForDisplay('𝑎𝑛+𝑏𝑛'), 'an+bn');
    });

    test('常见数学符号可读，不再出现豆腐块', () {
      expect(mathForDisplay('|𝑥|≤1'), '|x|<=1');
      expect(mathForDisplay('𝑥≥0'), 'x>=0');
      expect(mathForDisplay('√𝑛'), ' sqrt n');
      expect(mathForDisplay('∑𝑛'), ' sum n');
      expect(mathForDisplay('∫𝑓(𝑥)d𝑥'), ' int f(x)dx');
    });

    test('PDF 私有区字形：能认的转义，认不出的丢掉（不出豆腐块）', () {
      // 真卷 Q1 的原始码位：\uF0ED 是 {，\uF0E9..\uF0FB 是大括号上下片段，
      // \uF03E 是 >；片段括号丢掉后仍可读。
      expect(
        mathForDisplay(
          '设f(x)=\uF0ED,则f\uF0E9\uF0F9\uF0EB\uF0FBf(x)=1.\n\uF0EF\uF0EE0,x\uF03E1',
        ),
        '设f(x)={,则ff(x)=1.\n0,x>1',
      );
      expect(mathForDisplay('x\uF0A5'), 'x inf ');
      expect(mathForDisplay('a\uF03Cb'), 'a<b');
      expect(mathForDisplay('a\uF0B9b'), 'a!=b');
    });

    test('公式密度：数学卷判为高，普通中文不误判', () {
      expect(formulaHeavyText('设f(x)=\uF0ED,则f\uF0E9f(x)=1'), isTrue);
      expect(formulaHeavyText('𝑥→∞，lim sin x'), isTrue);
      expect(formulaHeavyText('学生参加考试须带学生证，未带者不准进入考场。'), isFalse);
      expect(formulaHeavyText(''), isFalse);
    });

    test('中文与普通 ASCII 原样保留', () {
      expect(mathForDisplay('设函数 y=y(x)，求 dy/dx'), '设函数 y=y(x)，求 dy/dx');
    });

    test('零宽字符被清掉', () {
      expect(mathForDisplay('a\u200Bb\uFEFFc'), 'abc');
    });

    test('空串不炸', () {
      expect(mathForDisplay(''), '');
    });
  });
}
