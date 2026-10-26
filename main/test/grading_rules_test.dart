import 'package:flutter_test/flutter_test.dart';
import 'package:shuaqi/domain/model/grading.dart';
import 'package:shuaqi/domain/region/grading_rules.dart';

/// 本地判题规则（2026-10-24 D 批）。
///
/// 口径：能判的判、判不了的交给 AI、没信息的不判。**绝不把"判不了"当成"错"**。
void main() {
  group('normalizeAnswerText', () {
    test('全角转半角、去空白、去前缀与句末标点', () {
      expect(normalizeAnswerText('答：Ｂ。'), 'b');
      expect(normalizeAnswerText('  1 , 2  '), '1,2');
      expect(normalizeAnswerText('答案: 12。'), '12');
    });

    test('乘除号归一', () {
      expect(normalizeAnswerText('2×3÷4'), '2x3/4');
    });
  });

  group('judgeObjective · 选择题', () {
    test('选对', () {
      expect(
        judgeObjective(answer: 'B', reference: 'B'),
        AnswerVerdict.correct,
      );
    });

    test('选错', () {
      expect(judgeObjective(answer: 'C', reference: 'B'), AnswerVerdict.wrong);
    });

    test('作答里带别的字也算', () {
      expect(
        judgeObjective(answer: '我觉得是B', reference: 'B'),
        AnswerVerdict.correct,
      );
    });

    test('多选提交里包含正确项算对（不倒扣）', () {
      expect(
        judgeObjective(answer: 'AB', reference: 'B'),
        AnswerVerdict.correct,
      );
    });

    test('识别成非选项字母 → 交给 AI，不硬判', () {
      expect(judgeObjective(answer: '八', reference: 'B'), isNull);
    });
  });

  group('judgeObjective · 数值', () {
    test('相等', () {
      expect(
        judgeObjective(answer: '0.5', reference: '0.5'),
        AnswerVerdict.correct,
      );
    });

    test('不等', () {
      expect(
        judgeObjective(answer: '0.6', reference: '0.5'),
        AnswerVerdict.wrong,
      );
    });

    test('整数与小数等价', () {
      expect(
        judgeObjective(answer: '12', reference: '12'),
        AnswerVerdict.correct,
      );
    });
  });

  group('judgeObjective · 文本与主观题', () {
    test('完全一致', () {
      expect(
        judgeObjective(answer: 'f(x)=1', reference: 'f(x)=1'),
        AnswerVerdict.correct,
      );
    });

    test('作答包含短参考答案', () {
      expect(
        judgeObjective(answer: '(1)单调递增', reference: '单调递增'),
        AnswerVerdict.correct,
      );
    });

    test('长答案 / 含"证明" → 交 AI（null），不判错', () {
      expect(
        judgeObjective(answer: '随便写写', reference: '证明过程略，由中值定理可得结论'),
        isNull,
      );
      expect(judgeObjective(answer: '写了一半', reference: '证明：由连续函数性质'), isNull);
    });

    test('没有参考答案 / 没有作答 → none', () {
      expect(judgeObjective(answer: 'B', reference: ''), AnswerVerdict.none);
      expect(judgeObjective(answer: '', reference: 'B'), AnswerVerdict.none);
    });
  });

  group('GradingData', () {
    GradingData sample() => GradingData.empty
        .withGrade(
          const QuestionGrade(questionId: 'a', verdict: AnswerVerdict.correct),
        )
        .withGrade(
          const QuestionGrade(questionId: 'b', verdict: AnswerVerdict.wrong),
        )
        .withGrade(
          const QuestionGrade(questionId: 'c', verdict: AnswerVerdict.pending),
        );

    test('统计按传入的 id 分桶，不数已删题', () {
      final VerdictCounts counts = sample().countsOf(<String>[
        'a',
        'b',
        'c',
        'd',
      ]);
      expect(counts.correct, 1);
      expect(counts.wrong, 1);
      expect(counts.pending, 1);
      expect(counts.none, 1);
      expect(counts.total, 4);
    });

    test('retain 只留存在的题', () {
      final GradingData trimmed = sample().retain(<String>{'a'});
      expect(trimmed.grades.keys, <String>['a']);
    });

    test('JSON 往返', () {
      final GradingData round = GradingData.fromJson(sample().toJson());
      expect(round.verdictOf('b'), AnswerVerdict.wrong);
      expect(round.gradeOf('a')?.source, GradeSource.auto);
    });
  });
}
