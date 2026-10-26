import 'package:flutter_test/flutter_test.dart';
import 'package:shuaqi/domain/ai/chat.dart';

void main() {
  test('推理-only 的助手轮也能落盘并恢复', () {
    final List<ChatTurn> turns = <ChatTurn>[
      ChatTurn.user('讲一下'),
      ChatTurn.assistant('', thinking: '先分析条件', deepThinking: true),
    ];
    final List<Map<String, Object?>> json = ChatTurn.listToJson(turns);
    expect(json.length, 2);
    final List<ChatTurn> back = ChatTurn.listFromJson(json);
    expect(back.length, 2);
    expect(back.last.text, isEmpty);
    expect(back.last.thinking, '先分析条件');
    expect(back.last.deepThinking, true);
  });
}
