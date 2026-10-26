import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shuaqi/infra/ai/errors.dart';
import 'package:shuaqi/infra/ai/llm_client.dart';
import 'package:shuaqi/infra/ai/openai_protocol.dart';

void main() {
  group('buildChatRequestBody', () {
    test('图片挂在第一条 user 消息上，历史不会被重复带图', () {
      final LlmRequest request = LlmRequest(
        model: 'm',
        messages: const <LlmMessage>[
          LlmMessage.system('sys'),
          LlmMessage.user('题面'),
          LlmMessage.assistant('上一轮'),
          LlmMessage.user('继续'),
        ],
        taskTag: LlmTaskTag.chat,
        images: <LlmImage>[
          LlmImage(bytes: Uint8List.fromList(<int>[1, 2, 3])),
        ],
      );
      final Map<String, Object?> body = buildChatRequestBody(
        request,
        stream: true,
      );
      final List<Object?> messages = body['messages']! as List<Object?>;
      expect(body['stream'], true);
      final Map<String, Object?> firstUser =
          messages[1]! as Map<String, Object?>;
      final List<Object?> parts = firstUser['content']! as List<Object?>;
      expect(parts.length, 2);
      expect((parts[0]! as Map<String, Object?>)['type'], 'text');
      final Map<String, Object?> imagePart = parts[1]! as Map<String, Object?>;
      expect(imagePart['type'], 'image_url');
      final Map<String, Object?> imageUrl =
          imagePart['image_url']! as Map<String, Object?>;
      expect(
        imageUrl['url'],
        'data:image/png;base64,${base64Encode(<int>[1, 2, 3])}',
      );
      // 最后一条 user 仍是纯文本。
      expect(messages.last, <String, Object?>{'role': 'user', 'content': '继续'});
    });

    test('没有图片时全部是纯文本', () {
      const LlmRequest request = LlmRequest(
        model: 'm',
        messages: <LlmMessage>[LlmMessage.user('hi')],
        taskTag: LlmTaskTag.chat,
      );
      final Map<String, Object?> body = buildChatRequestBody(
        request,
        stream: false,
      );
      final List<Object?> messages = body['messages']! as List<Object?>;
      expect((messages.first! as Map<String, Object?>)['content'], 'hi');
    });

    test('流式 + includeUsage 才带 stream_options', () {
      const LlmRequest request = LlmRequest(
        model: 'm',
        messages: <LlmMessage>[LlmMessage.user('hi')],
        taskTag: LlmTaskTag.chat,
        includeUsage: true,
      );
      final Map<String, Object?> body = buildChatRequestBody(
        request,
        stream: true,
      );
      expect(body['stream_options'], <String, Object?>{'include_usage': true});
      final Map<String, Object?> noUsage = buildChatRequestBody(
        request,
        stream: true,
        includeUsage: false,
      );
      expect(noUsage.containsKey('stream_options'), false);
    });

    test('DeepSeek thinking 开关映射到 thinking / reasoning_effort', () {
      const LlmRequest request = LlmRequest(
        model: 'deepseek-flash',
        messages: <LlmMessage>[LlmMessage.user('hi')],
        taskTag: LlmTaskTag.chat,
        thinkingMode: LlmThinkingMode.enabled,
      );
      final Map<String, Object?> body = buildChatRequestBody(
        request,
        stream: true,
      );
      expect(body['thinking'], <String, Object?>{'type': 'enabled'});
      expect(body['reasoning_effort'], 'high');
      final Map<String, Object?> disabled = buildChatRequestBody(
        request,
        stream: true,
        thinkingMode: LlmThinkingMode.disabled,
      );
      expect(disabled['thinking'], <String, Object?>{'type': 'disabled'});
      expect(disabled.containsKey('reasoning_effort'), false);
    });
  });

  group('parseChatCompletion', () {
    test('文本、usage 与模型名', () {
      final LlmResult result = parseChatCompletion(
        '{"model":"m-1","choices":[{"message":{"content":"你好"}}],'
        '"usage":{"prompt_tokens":10,"completion_tokens":3}}',
      );
      expect(result.text, '你好');
      expect(result.tokensIn, 10);
      expect(result.tokensOut, 3);
      expect(result.model, 'm-1');
    });

    test('content 是 parts 数组也能取文本', () {
      final LlmResult result = parseChatCompletion(
        '{"choices":[{"message":{"content":[{"type":"text","text":"A"},'
        '{"type":"text","text":"B"}]}}]}',
      );
      expect(result.text, 'AB');
    });

    test('reasoning_content 与答案分开', () {
      final LlmResult result = parseChatCompletion(
        '{"choices":[{"message":{"content":"答案","reasoning_content":"推理"}}]}',
      );
      expect(result.text, '答案');
      expect(result.reasoning, '推理');
    });

    test('坏响应抛 badResponse', () {
      expect(
        () => parseChatCompletion('{"choices":[]}'),
        throwsA(
          isA<LlmException>().having(
            (LlmException e) => e.kind,
            'kind',
            LlmErrorKind.badResponse,
          ),
        ),
      );
    });
  });

  group('SSE', () {
    test('按行缓冲：事件被拆成多个包也能拼回来', () {
      final SseParser parser = SseParser();
      expect(
        parser.add('data: {"choices":[{"delta":{"content":"你"}}]}\n'),
        isEmpty,
      );
      final List<String> events = parser.add('\ndata: [DONE]\n\n');
      expect(events.length, 2);
      expect(events.first, contains('"content":"你"'));
      expect(events.last, '[DONE]');
      expect(parseSseData(events.first).text, '你');
      expect(parseSseData(events.last).done, true);
    });

    test('多行 data 会拼成一条事件', () {
      final SseParser parser = SseParser();
      final List<String> events = parser.add(
        ': ping\ndata: {"choices":\ndata: []}\n\n',
      );
      expect(events, <String>['{"choices":\n[]}']);
    });

    test('非流式响应也能从 SSE 里读出来', () {
      expect(
        parseSseData('{"choices":[{"message":{"content":"完整回答"}}]}').text,
        '完整回答',
      );
    });

    test('reasoning_content 与 usage 都能从 SSE 读出来', () {
      final SseDelta thinking = parseSseData(
        '{"choices":[{"delta":{"reasoning_content":"先想"}}]}',
      );
      expect(thinking.reasoning, '先想');
      final SseDelta usage = parseSseData(
        '{"choices":[],"usage":{"prompt_tokens":12,"completion_tokens":5}}',
      );
      expect(usage.text, isEmpty);
      expect(usage.tokensIn, 12);
      expect(usage.tokensOut, 5);
    });

    test('reasoning 放在 choice 或顶层的中转也能读', () {
      expect(
        parseSseData('{"choices":[{"reasoning":"choice 层"}]}').reasoning,
        'choice 层',
      );
      expect(parseSseData('{"reasoning_content":"顶层"}').reasoning, '顶层');
      expect(
        parseSseData(
          '{"choices":[{"delta":{"content":"答案"}}],"reasoning_content":"顶层"}',
        ).reasoning,
        '顶层',
      );
    });
  });

  group('错误分类', () {
    test('401 / 429 / 500 / 图片不支持', () {
      expect(
        classifyHttpStatus(401, '{"error":{"message":"bad key"}}').kind,
        LlmErrorKind.auth,
      );
      expect(classifyHttpStatus(429, '').kind, LlmErrorKind.rateLimited);
      expect(classifyHttpStatus(500, 'boom').kind, LlmErrorKind.server);
      expect(
        classifyHttpStatus(
          400,
          '{"error":{"message":"image input not supported"}}',
        ).kind,
        LlmErrorKind.unsupportedImage,
      );
    });

    test('错误信息从 error.message 抽', () {
      expect(errorMessageFrom('{"error":{"message":"余额不足"}}'), '余额不足');
      expect(errorMessageFrom('not json'), 'not json');
    });
  });
}
