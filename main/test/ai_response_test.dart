import 'package:flutter_test/flutter_test.dart';
import 'package:shuaqi/domain/ai/ai_response.dart';
import 'package:shuaqi/domain/ai/chat.dart';
import 'package:shuaqi/domain/model/grading.dart';

void main() {
  group('stripCodeFence', () {
    test('去掉 json 围栏', () {
      expect(
        stripCodeFence('```json\n{"verdict":"correct"}\n```'),
        '{"verdict":"correct"}',
      );
    });

    test('没有围栏原样返回', () {
      expect(stripCodeFence('  hello  '), 'hello');
    });
  });

  group('parseAiGrade', () {
    test('correct + reason + confidence', () {
      final AiGrade? grade = parseAiGrade(
        '{"verdict":"correct","reason":"答案一致","confidence":0.9}',
      );
      expect(grade?.verdict, AnswerVerdict.correct);
      expect(grade?.reason, '答案一致');
      expect(grade?.confidence, 0.9);
    });

    test('中文判定也认', () {
      expect(
        parseAiGrade('{"verdict":"对","reason":"等价"}')?.verdict,
        AnswerVerdict.correct,
      );
      expect(
        parseAiGrade('{"verdict":"错","reason":"符号反了"}')?.verdict,
        AnswerVerdict.wrong,
      );
    });

    test('unclear 映射到 pending', () {
      expect(
        parseAiGrade('{"verdict":"unclear","reason":"看不清"}')?.verdict,
        AnswerVerdict.pending,
      );
    });

    test('JSON 里没有判定 → null', () {
      expect(parseAiGrade('{"reason":"没有 verdict"}'), isNull);
    });

    test('纯文字读不出判定 → null（不硬猜）', () {
      expect(parseAiGrade('这道题我看看'), isNull);
      expect(parseAiGrade(''), isNull);
    });

    // 2026-10-26 用户第 6 条：模型不回 JSON 时不该弹"格式异常"，
    // 能读出判定词就接住，并标出"这是按文字判的"。
    test('纯文字兜底：读出判定词就返回（fromText）', () {
      final AiGrade? wrong = parseAiGrade('答案不对，应该是 B');
      expect(wrong?.verdict, AnswerVerdict.wrong);
      expect(wrong?.fromText, isTrue);

      final AiGrade? right = parseAiGrade('我觉得是对的');
      expect(right?.verdict, AnswerVerdict.correct);
      expect(right?.fromText, isTrue);

      final AiGrade? unsure = parseAiGrade('这一步我拿不准');
      expect(unsure?.verdict, AnswerVerdict.pending);
    });

    test('否定词优先于肯定词（"答案不对，应该是 B" 不能判成对）', () {
      expect(parseAiGrade('答案不对，应该是 B')?.verdict, AnswerVerdict.wrong);
    });

    test('两段 JSON 时取第一段完整的那个', () {
      final AiGrade? grade = parseAiGrade(
        '好的：{"verdict":"correct","reason":"一致"}\n补充：{"note":"x"}',
      );
      expect(grade?.verdict, AnswerVerdict.correct);
      expect(grade?.reason, '一致');
      expect(grade?.fromText, isFalse);
    });

    test('字符串里的花括号不会把配对扫描带偏', () {
      final AiGrade? grade = parseAiGrade(
        '{"verdict":"wrong","reason":"答案里写的是 {x}"}',
      );
      expect(grade?.verdict, AnswerVerdict.wrong);
      expect(grade?.reason, '答案里写的是 {x}');
    });

    test('confidence 超界会收紧', () {
      expect(
        parseAiGrade('{"verdict":"correct","confidence":1.8}')?.confidence,
        1,
      );
    });
  });

  group('parseAiSolution', () {
    test('标准 JSON', () {
      final AiSolution? solution = parseAiSolution(
        r'{"answer":"$x=2$","explanation":"移项得 $x=2$","confidence":0.8}',
      );
      expect(solution?.answer, r'$x=2$');
      expect(solution?.explanation, r'移项得 $x=2$');
      expect(solution?.confidence, 0.8);
    });

    test('带围栏与前后解释也能抠出来', () {
      final AiSolution? solution = parseAiSolution(
        '这是结果：\n```json\n{"answer":"B","explanation":"排除法"}\n```\n完毕',
      );
      expect(solution?.answer, 'B');
      expect(solution?.explanation, '排除法');
    });

    test('steps 数组拼成编号解析', () {
      final AiSolution? solution = parseAiSolution(
        '{"answer":"2","steps":["第一步","第二步"]}',
      );
      expect(solution?.explanation, contains('1. 第一步'));
      expect(solution?.explanation, contains('2. 第二步'));
    });

    test('纯文本兜底：提取“答案：”行', () {
      final AiSolution? solution = parseAiSolution('先配方。\n答案：x=1\n所以最小值是 2。');
      expect(solution?.answer, 'x=1');
      expect(solution?.explanation, contains('先配方'));
    });

    test('空内容返回 null', () {
      expect(parseAiSolution('   '), isNull);
    });
  });

  group('stripLightMarkdown', () {
    test('去掉标题、粗体、行内代码，保留公式', () {
      final String text = stripLightMarkdown(
        '### 结论\n**答案是** `x=1`，即 \$x=1\$。',
      );
      expect(text, contains('结论'));
      expect(text, isNot(contains('**')));
      expect(text, isNot(contains('###')));
      expect(text, contains(r'$x=1$'));
    });
  });
}
