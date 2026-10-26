import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shuaqi/domain/ai/llm_config.dart';
import 'package:shuaqi/infra/ai/errors.dart';
import 'package:shuaqi/infra/ai/llm_client.dart';
import 'package:shuaqi/infra/ai/openai_client.dart';

void main() {
  test('流式：SSE 分包、[DONE]、半截公式都按顺序吐出来', () async {
    final HttpServer server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    server.listen((HttpRequest request) async {
      await request.drain<void>();
      final HttpResponse response = request.response;
      response.statusCode = 200;
      response.headers.contentType = ContentType(
        'text',
        'event-stream',
        charset: 'utf-8',
      );
      response.write('data: {"choices":[{"delta":{"content":"设 \$x="}}]}\n\n');
      await response.flush();
      // 故意从 JSON 中间切开，验证按行缓冲。
      response.write('data: {"choices":[{"delta":{"content":"2\$，则 "}}]}\n');
      await response.flush();
      response.write('\ndata: {"choices":[{"delta":{"content":"答案为 2"}}]}\n\n');
      response.write('data: [DONE]\n\n');
      await response.close();
    });

    final OpenAiCompatibleClient client = OpenAiCompatibleClient(
      config: LlmConfig(
        baseUrl: 'http://127.0.0.1:${server.port}/v1',
        apiKey: 'test-key',
        model: 'test-model',
      ),
    );
    final List<LlmChunk> chunks = await client
        .stream(
          const LlmRequest(
            model: 'test-model',
            messages: <LlmMessage>[LlmMessage.user('hi')],
            taskTag: LlmTaskTag.chat,
          ),
        )
        .toList();
    client.dispose();
    await server.close(force: true);

    final String text = chunks.map((LlmChunk c) => c.delta).join();
    expect(text, r'设 $x=2$，则 答案为 2');
    expect(chunks.last.done, true);
  });

  test('非流式：读取 choices[0].message.content', () async {
    final HttpServer server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    server.listen((HttpRequest request) async {
      await request.drain<void>();
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode(<String, Object?>{
          'model': 'm',
          'choices': <Object?>[
            <String, Object?>{
              'message': <String, Object?>{'content': '完整回答'},
            },
          ],
        }),
      );
      await request.response.close();
    });
    final OpenAiCompatibleClient client = OpenAiCompatibleClient(
      config: LlmConfig(
        baseUrl: 'http://127.0.0.1:${server.port}/v1',
        apiKey: 'k',
        model: 'm',
      ),
    );
    final LlmResult result = await client.complete(
      const LlmRequest(
        model: 'm',
        messages: <LlmMessage>[LlmMessage.user('hi')],
        taskTag: LlmTaskTag.chat,
      ),
    );
    client.dispose();
    await server.close(force: true);
    expect(result.text, '完整回答');
  });

  test('401 映射为 auth 异常', () async {
    final HttpServer server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    server.listen((HttpRequest request) async {
      await request.drain<void>();
      request.response.statusCode = 401;
      request.response.headers.contentType = ContentType.json;
      request.response.write('{"error":{"message":"bad key"}}');
      await request.response.close();
    });
    final OpenAiCompatibleClient client = OpenAiCompatibleClient(
      config: LlmConfig(
        baseUrl: 'http://127.0.0.1:${server.port}/v1',
        apiKey: 'wrong',
        model: 'm',
      ),
    );
    await expectLater(
      client.complete(
        const LlmRequest(
          model: 'm',
          messages: <LlmMessage>[LlmMessage.user('hi')],
          taskTag: LlmTaskTag.chat,
        ),
      ),
      throwsA(
        isA<LlmException>().having(
          (LlmException e) => e.kind,
          'kind',
          LlmErrorKind.auth,
        ),
      ),
    );
    client.dispose();
    await server.close(force: true);
  });
}
