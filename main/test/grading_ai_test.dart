import 'package:flutter_test/flutter_test.dart';
import 'package:shuaqi/domain/model/grading.dart';

void main() {
  test('GradeSource 三态解码，未知值回落 auto', () {
    expect(GradeSource.decode('ai'), GradeSource.ai);
    expect(GradeSource.decode('manual'), GradeSource.manual);
    expect(GradeSource.decode('auto'), GradeSource.auto);
    expect(GradeSource.decode('nonsense'), GradeSource.auto);
    expect(GradeSource.decode(null), GradeSource.auto);
  });

  test('QuestionGrade.fromAi 与 manual 判定', () {
    const QuestionGrade ai = QuestionGrade(
      questionId: 'q',
      verdict: AnswerVerdict.correct,
      source: GradeSource.ai,
      note: '步骤一致',
    );
    expect(ai.fromAi, true);
    expect(ai.manual, false);
    expect(ai.toJson()['source'], 'ai');
    expect(QuestionGrade.fromJson(ai.toJson()).note, '步骤一致');
  });

  test('VerdictCounts 把 AI 的 pending 计入待判', () {
    const GradingData data = GradingData(<String, QuestionGrade>{
      'a': QuestionGrade(
        questionId: 'a',
        verdict: AnswerVerdict.correct,
        source: GradeSource.ai,
      ),
      'b': QuestionGrade(
        questionId: 'b',
        verdict: AnswerVerdict.pending,
        source: GradeSource.ai,
      ),
    });
    final VerdictCounts counts = data.countsOf(<String>['a', 'b', 'c']);
    expect(counts.correct, 1);
    expect(counts.pending, 1);
    expect(counts.none, 1);
  });
}
