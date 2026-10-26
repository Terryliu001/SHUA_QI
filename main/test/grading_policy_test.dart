import 'package:flutter_test/flutter_test.dart';
import 'package:shuaqi/domain/model/grading.dart';
import 'package:shuaqi/domain/region/grading_policy.dart';

void main() {
  test('没有参考答案：入口不可用，不落任何结论', () {
    final LocalGrade grade = judgeLocally(
      reference: '',
      studentText: 'B',
      ocrConfidence: 0.9,
      hasWork: true,
    );
    expect(grade.readiness, GradeReadiness.noAnswer);
    expect(grade.verdict, AnswerVerdict.none);
  });

  test('有答案但没作答：只展示答案，不判', () {
    final LocalGrade grade = judgeLocally(
      reference: 'B',
      studentText: '',
      ocrConfidence: 0,
      hasWork: false,
    );
    expect(grade.readiness, GradeReadiness.noWork);
    expect(grade.verdict, AnswerVerdict.none);
  });

  test('选择题本地可信：对/错都直接落', () {
    final LocalGrade right = judgeLocally(
      reference: 'B',
      studentText: 'B',
      ocrConfidence: 0.92,
      hasWork: true,
    );
    expect(right.readiness, GradeReadiness.ready);
    expect(right.verdict, AnswerVerdict.correct);

    final LocalGrade wrong = judgeLocally(
      reference: 'B',
      studentText: 'C',
      ocrConfidence: 0.92,
      hasWork: true,
    );
    expect(wrong.readiness, GradeReadiness.ready);
    expect(wrong.verdict, AnswerVerdict.wrong);
  });

  test('数值等价也算对', () {
    final LocalGrade grade = judgeLocally(
      reference: '0.5',
      studentText: '0.50',
      ocrConfidence: 0.9,
      hasWork: true,
    );
    expect(grade.readiness, GradeReadiness.ready);
    expect(grade.verdict, AnswerVerdict.correct);
  });

  test('低识别置信：即使判出对错也降级为黄点', () {
    final LocalGrade grade = judgeLocally(
      reference: 'B',
      studentText: 'C',
      ocrConfidence: 0.4,
      hasWork: true,
    );
    expect(grade.readiness, GradeReadiness.untrusted);
    expect(grade.verdict, AnswerVerdict.pending);
  });

  test('主观题参考答案：本地不硬判', () {
    final LocalGrade grade = judgeLocally(
      reference: '证明：由中值定理可得……（略）',
      studentText: '证明：由中值定理可得……',
      ocrConfidence: 0.95,
      hasWork: true,
    );
    expect(grade.readiness, GradeReadiness.untrusted);
    expect(grade.verdict, AnswerVerdict.pending);
  });

  test('有作答但没有识别文本：交 AI，不落 none', () {
    final LocalGrade grade = judgeLocally(
      reference: 'B',
      studentText: '',
      ocrConfidence: 0,
      hasWork: true,
    );
    expect(grade.readiness, GradeReadiness.untrusted);
    expect(grade.verdict, AnswerVerdict.pending);
  });
}
