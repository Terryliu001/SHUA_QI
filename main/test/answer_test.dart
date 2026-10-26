import 'package:flutter_test/flutter_test.dart';
import 'package:shuaqi/domain/region/answer.dart';

void main() {
  group('answerKeyOf', () {
    test('题号尾部标点归一', () {
      expect(answerKeyOf('1.'), '1');
      expect(answerKeyOf(' 12、 '), '12');
      expect(answerKeyOf('一、'), '一');
      expect(answerKeyOf('（3）'), '（3）');
    });
  });

  group('AnswerSet', () {
    test('按归一题号取答案', () {
      const AnswerSet set = AnswerSet(<String, AnswerNote>{
        '1': AnswerNote(label: '1.', text: 'A'),
      });
      expect(set.forLabel('1')?.text, 'A');
      expect(set.forLabel('1.')?.text, 'A');
      expect(set.forLabel('2'), isNull);
    });

    test('ordinal 优先于 label，避免两个 1. 串答案', () {
      const AnswerSet set = AnswerSet(
        <String, AnswerNote>{'1': AnswerNote(label: '1.', text: '选择题答案')},
        byOrdinal: <int, AnswerNote>{
          7: AnswerNote(label: '1.', text: '填空题解析', ordinal: 7),
        },
      );
      expect(set.forQuestion(ordinal: 7, label: '1.')?.text, '填空题解析');
      expect(set.forQuestion(ordinal: 8, label: '1.')?.text, '选择题答案');
    });

    test('JSON 往返', () {
      const AnswerSet source = AnswerSet(<String, AnswerNote>{
        '1': AnswerNote(
          label: '1.',
          text: '1. A',
          source: 'pdf_text',
          pageIndex: 3,
        ),
      });
      final AnswerSet restored = AnswerSet.fromJson(source.toJson());
      expect(restored.forLabel('1.')?.text, '1. A');
      expect(restored.forLabel('1.')?.pageIndex, 3);
    });

    test('坏 JSON 不抛', () {
      expect(AnswerSet.fromJson(null).isEmpty, isTrue);
      expect(
        AnswerSet.fromJson(<String, Object?>{'answers': 'nope'}).isEmpty,
        isTrue,
      );
    });
  });
}
