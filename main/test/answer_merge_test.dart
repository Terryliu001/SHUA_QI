import 'package:flutter_test/flutter_test.dart';
import 'package:shuaqi/domain/region/answer.dart';

void main() {
  AnswerNote note(
    String label,
    String text, {
    int? ordinal,
    String source = 'ai',
  }) => AnswerNote(label: label, text: text, ordinal: ordinal, source: source);

  test('mergeMissing：PDF 已有答案不被 AI 顶掉', () {
    final AnswerSet pdf = AnswerSet(<String, AnswerNote>{
      '1': note('1.', 'B', source: 'pdf_text'),
    });
    final AnswerSet ai = AnswerSet(<String, AnswerNote>{
      '1': note('1.', 'C'),
      '2': note('2.', 'D'),
    });
    final AnswerSet merged = pdf.mergeMissing(ai);
    expect(merged.forQuestion(ordinal: 1, label: '1.')?.text, 'B');
    expect(merged.forQuestion(ordinal: 2, label: '2.')?.text, 'D');
  });

  test('mergeMissing：ordinal 精确匹配', () {
    final AnswerSet pdf = AnswerSet(
      const <String, AnswerNote>{},
      byOrdinal: <int, AnswerNote>{1: note('1.', 'B', ordinal: 1)},
    );
    final AnswerSet ai = AnswerSet(
      const <String, AnswerNote>{},
      byOrdinal: <int, AnswerNote>{
        1: note('1.', 'C', ordinal: 1),
        2: note('2.', 'D', ordinal: 2),
      },
    );
    final AnswerSet merged = pdf.mergeMissing(ai);
    expect(merged.forQuestion(ordinal: 1, label: '1.')?.text, 'B');
    expect(merged.forQuestion(ordinal: 2, label: '2.')?.text, 'D');
  });

  test('withNote：写入后 label/ordinal 两个索引都能查到', () {
    final AnswerSet set = AnswerSet.empty.withNote(note('3.', 'E', ordinal: 3));
    expect(set.forLabel('3.')?.text, 'E');
    expect(set.forQuestion(ordinal: 3, label: '3.')?.text, 'E');
    expect(set.isEmpty, isFalse);
  });

  test('withNote：替换同题旧答案', () {
    final AnswerSet a = AnswerSet.empty.withNote(note('1.', 'B', ordinal: 1));
    final AnswerSet b = a.withNote(note('1.', 'C', ordinal: 1));
    expect(b.forQuestion(ordinal: 1, label: '1.')?.text, 'C');
    expect(b.toJson()['answers'], hasLength(1));
  });
}
