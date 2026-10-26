import 'package:flutter_test/flutter_test.dart';
import 'package:shuaqi/domain/region/pattern.dart';

/// 题号识别（T3.2 第一道关）。用例覆盖规格点名的六种样式 + 三类伪题号。
void main() {
  group('matchQuestionMark', () {
    test('1. 阿拉伯数字 + 点', () {
      final QuestionMark? mark = matchQuestionMark('12. 求下列极限');
      expect(mark, isNotNull);
      expect(mark!.kind, MarkKind.arabic);
      expect(mark.number, 12);
      expect(mark.label, '12.');
      expect(mark.rest, '求下列极限');
    });

    test('2. 半角与全角括号题号', () {
      expect(matchQuestionMark('(3) 设 f(x)')!.number, 3);
      expect(matchQuestionMark('（3）证明')!.kind, MarkKind.parenArabic);
      expect(matchQuestionMark('（ 12 ）设')!.number, 12);
    });

    test('3. 圈号', () {
      final QuestionMark? mark = matchQuestionMark('①求导');
      expect(mark!.kind, MarkKind.circled);
      expect(mark.number, 1);
    });

    test('4. 第 N 题', () {
      final QuestionMark? mark = matchQuestionMark('第 5 题 判断题');
      expect(mark!.kind, MarkKind.thQuestion);
      expect(mark.number, 5);
    });

    test('5. 【例 7】与 [习题 3]', () {
      expect(matchQuestionMark('【例 7】求极限')!.number, 7);
      expect(matchQuestionMark('[习题 3] 计算')!.kind, MarkKind.example);
    });

    test('6. 中文数字（含十一、二十）', () {
      expect(matchQuestionMark('一、填空题')!.number, 1);
      expect(matchQuestionMark('十一、附加题')!.number, 11);
      expect(matchQuestionMark('二十．解答题')!.number, 20);
    });

    test('6b. 中文序号 + 分值（三(14分)，真卷写法）', () {
      final QuestionMark? mark = matchQuestionMark(
        '三(14分)求函数f(x)=sinx/(x-1)的间断点',
      );
      expect(mark, isNotNull);
      expect(mark!.kind, MarkKind.cnNumeral);
      expect(mark.number, 3);
      expect(mark.label, '三、', reason: '角标只留序号，不挤进分值');
      expect(mark.rest.startsWith('求函数'), isTrue);
      expect(matchQuestionMark('五（8分）设函数')!.number, 5);
    });

    test('7. 罗马数字', () {
      expect(matchQuestionMark('Ⅲ. 计算下列积分')!.kind, MarkKind.roman);
      expect(matchQuestionMark('Ⅳ、证明')!.number, 4);
    });

    test('8. 伪题号：小数、图注、空题干、分值', () {
      expect(matchQuestionMark('1.5 分'), isNull, reason: '小数不是题号');
      expect(matchQuestionMark('3. 图 2-1 所示'), isNull, reason: '图注不是题号');
      expect(matchQuestionMark('1.'), isNull, reason: '单独题号多为排版残留');
      expect(matchQuestionMark('（3 分）'), isNull, reason: '分值标注不是题号');
      expect(matchQuestionMark('A. 选项一 B. 选项二'), isNull);
      expect(matchQuestionMark(''), isNull);
    });
  });

  group('classifyKind', () {
    test('两个以上 A./B. 选项才是选择题', () {
      expect(classifyKind('设 f(x)=x，则（ ）． A.0 B.1 C.e D.不存在'), 'choice');
      expect(classifyKind('如图 A. 所示，求…'), 'essay');
    });

    test('判断题与填空题', () {
      expect(classifyKind('若极限存在则函数连续（  ）'), 'judge');
      expect(classifyKind('填“对”或“错”'), 'judge');
      expect(classifyKind('设 f(x)=＿＿＿，求'), 'blank');
    });
  });

  group('kindFromHeading', () {
    test('从大题标题继承题型', () {
      expect(kindFromHeading('填空题（共30分，每小题5分）'), 'blank');
      expect(kindFromHeading('选择题（共30分）'), 'choice');
      expect(kindFromHeading('判断题'), 'judge');
      expect(kindFromHeading('计算题'), 'essay');
      expect(kindFromHeading('其它'), isNull);
    });
  });
}
