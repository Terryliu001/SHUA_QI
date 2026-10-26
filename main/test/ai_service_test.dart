import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shuaqi/app/ai/ai_service.dart';
import 'package:shuaqi/app/ai/usage_service.dart';
import 'package:shuaqi/domain/ai/chat.dart';
import 'package:shuaqi/domain/ai/llm_config.dart';
import 'package:shuaqi/domain/ai/question_payload.dart';
import 'package:shuaqi/domain/ai/usage.dart';
import 'package:shuaqi/domain/model/grading.dart';
import 'package:shuaqi/domain/region/region_rect.dart';
import 'package:shuaqi/infra/ai/errors.dart';
import 'package:shuaqi/infra/ai/llm_client.dart';
import 'package:shuaqi/infra/ai/llm_config_store.dart';
import 'package:shuaqi/infra/db/dao/llm_usage_dao.dart';

class _FakeConfigStore implements LlmConfigStore {
  LlmConfig value = LlmConfig.empty;

  @override
  Future<LlmConfig> load() async => value;

  @override
  Future<void> save(LlmConfig config) async => value = config;

  @override
  Future<void> clear() async => value = LlmConfig.empty;
}

class _FakeUsageDao implements LlmUsageDao {
  final List<AiUsageRecord> records = <AiUsageRecord>[];

  @override
  Future<void> add(AiUsageRecord record) async => records.add(record);

  @override
  Future<AiUsageSummary> summary() async => AiUsageSummary(
    calls: records.length,
    tokensIn: records.fold<int>(
      0,
      (int sum, AiUsageRecord r) => sum + r.tokensIn,
    ),
    tokensOut: records.fold<int>(
      0,
      (int sum, AiUsageRecord r) => sum + r.tokensOut,
    ),
  );

  @override
  Future<List<AiUsageRecord>> recent({int limit = 20}) async =>
      records.reversed.take(limit).toList();

  @override
  Future<void> clear() async => records.clear();
}

class _FakeClient implements LlmClient {
  _FakeClient({
    this.reply = '回答',
    this.streamReply = '流式回答',
    this.streamThinking = '',
    this.tokensIn = 0,
    this.tokensOut = 0,
  });

  final String reply;
  final String streamReply;
  final String streamThinking;
  final int tokensIn;
  final int tokensOut;
  final List<LlmRequest> requests = <LlmRequest>[];
  LlmException? streamError;
  LlmException? completeError;

  @override
  Future<LlmResult> complete(LlmRequest request) async {
    requests.add(request);
    if (completeError != null) {
      throw completeError!;
    }
    return LlmResult(text: reply, model: request.model);
  }

  @override
  Stream<LlmChunk> stream(LlmRequest request) async* {
    requests.add(request);
    if (streamError != null) {
      throw streamError!;
    }
    yield LlmChunk(
      delta: streamReply,
      reasoning: streamThinking,
      tokensIn: tokensIn,
      tokensOut: tokensOut,
    );
    yield const LlmChunk(done: true);
  }

  @override
  Future<bool> healthCheck() async => true;
}

QuestionAiPayload _payload({String? text = '求函数的最值。'}) =>
    buildQuestionAiPayload(
      questionId: 'q1',
      label: '12.',
      pageIndex: 2,
      rect: RegionRect.fromLTRB(40, 100, 520, 300),
      text: text,
      provenance: TextProvenance.pdfTextLayer,
    );

LlmConfig _config({
  bool allowImages = true,
  String model = 'model',
  String baseUrl = 'https://example.com/v1',
}) => LlmConfig(
  baseUrl: baseUrl,
  apiKey: 'key',
  model: model,
  allowImages: allowImages,
);

void main() {
  test('对话请求：题面图只带一张，历史按顺序进 messages', () async {
    final _FakeClient client = _FakeClient(streamReply: '答案');
    final AiService service = AiService(
      configStore: _FakeConfigStore(),
      clientFactory: (LlmConfig _) => client,
    );
    final List<AiChatChunk> chunks = await service
        .chat(
          config: _config(),
          payload: _payload(),
          history: <ChatTurn>[ChatTurn.user('上一问'), ChatTurn.assistant('上一答')],
          message: '这题怎么做',
          attachments: <AiImageAttachment>[
            AiImageAttachment(
              kind: AiImageKind.question,
              label: '题面',
              bytes: Uint8List.fromList(<int>[1, 2, 3]),
            ),
          ],
        )
        .toList();
    expect(chunks.map((AiChatChunk c) => c.text).join(), '答案');
    final LlmRequest request = client.requests.single;
    expect(request.images.length, 1);
    expect(request.messages.first.role, LlmRole.system);
    expect(request.messages[1].role, LlmRole.user);
    expect(request.messages.first.content, contains('权威来源'));
    final List<String> userTexts = <String>[
      for (final LlmMessage message in request.messages)
        if (message.role == LlmRole.user) message.content,
    ];
    expect(userTexts.last, '这题怎么做');
    expect(userTexts, contains('上一问'));
    expect(
      request.messages.any((LlmMessage m) => m.role == LlmRole.assistant),
      true,
    );
  });

  test('关闭传图时：不把图片放进请求，只靠文本', () async {
    final _FakeClient client = _FakeClient();
    final AiService service = AiService(
      configStore: _FakeConfigStore(),
      clientFactory: (LlmConfig _) => client,
    );
    await service
        .chat(
          config: _config(allowImages: false),
          payload: _payload(text: '求函数的最值。'),
          history: const <ChatTurn>[],
          message: '讲一下',
          attachments: <AiImageAttachment>[
            AiImageAttachment(
              kind: AiImageKind.question,
              label: '题面',
              bytes: Uint8List.fromList(<int>[1]),
            ),
          ],
        )
        .toList();
    expect(client.requests.single.images, isEmpty);
  });

  test('关闭传图且没有文本：提前给可操作的失败', () async {
    final AiService service = AiService(
      configStore: _FakeConfigStore(),
      clientFactory: (LlmConfig _) => _FakeClient(),
    );
    await expectLater(
      service
          .chat(
            config: _config(allowImages: false),
            payload: _payload(text: null),
            history: const <ChatTurn>[],
            message: '讲一下',
          )
          .toList(),
      throwsA(
        isA<AiFailure>().having(
          (AiFailure e) => e.kind,
          'kind',
          AiFailureKind.unsupportedImage,
        ),
      ),
    );
  });

  test('未配置：不发请求，给 notConfigured', () async {
    final _FakeClient client = _FakeClient();
    final AiService service = AiService(
      configStore: _FakeConfigStore(),
      clientFactory: (LlmConfig _) => client,
    );
    await expectLater(
      service
          .chat(
            config: LlmConfig.empty,
            payload: _payload(),
            history: const <ChatTurn>[],
            message: 'hi',
          )
          .toList(),
      throwsA(
        isA<AiFailure>().having(
          (AiFailure e) => e.kind,
          'kind',
          AiFailureKind.notConfigured,
        ),
      ),
    );
    expect(client.requests, isEmpty);
  });

  test('鉴权失败映射为 auth 文案', () async {
    final _FakeClient client = _FakeClient()
      ..streamError = const LlmException(LlmErrorKind.auth, 'bad');
    final AiService service = AiService(
      configStore: _FakeConfigStore(),
      clientFactory: (LlmConfig _) => client,
    );
    await expectLater(
      service
          .chat(
            config: _config(),
            payload: _payload(),
            history: const <ChatTurn>[],
            message: 'hi',
          )
          .toList(),
      throwsA(
        isA<AiFailure>().having(
          (AiFailure e) => e.kind,
          'kind',
          AiFailureKind.auth,
        ),
      ),
    );
  });

  test('补答案：解析 JSON 并保留解析', () async {
    final _FakeClient client = _FakeClient(
      reply: '{"answer":"B","explanation":"排除法","confidence":0.8}',
    );
    final AiService service = AiService(
      configStore: _FakeConfigStore(),
      clientFactory: (LlmConfig _) => client,
    );
    final AiSolution solution = await service.solve(
      config: _config(),
      payload: _payload(),
    );
    expect(solution.answer, 'B');
    expect(solution.explanation, '排除法');
  });

  test('判题：解析 JSON 为 AnswerVerdict.wrong', () async {
    final _FakeClient client = _FakeClient(
      reply: '{"verdict":"wrong","reason":"符号反了","confidence":0.9}',
    );
    final AiService service = AiService(
      configStore: _FakeConfigStore(),
      clientFactory: (LlmConfig _) => client,
    );
    final AiGrade grade = await service.grade(
      config: _config(),
      payload: _payload(),
      referenceAnswer: 'B',
      studentAnswerText: 'C',
      attachments: <AiImageAttachment>[
        AiImageAttachment(
          kind: AiImageKind.question,
          label: '题面',
          bytes: Uint8List.fromList(<int>[1]),
        ),
        AiImageAttachment(
          kind: AiImageKind.answer,
          label: '我的作答',
          bytes: Uint8List.fromList(<int>[9]),
        ),
      ],
    );
    expect(grade.verdict, AnswerVerdict.wrong);
    expect(grade.reason, '符号反了');
    expect(client.requests.single.images.length, 2);
  });

  test('判题：读不出结论时抛出 badResponse', () async {
    final _FakeClient client = _FakeClient(reply: '这道题我看看');
    final AiService service = AiService(
      configStore: _FakeConfigStore(),
      clientFactory: (LlmConfig _) => client,
    );
    await expectLater(
      service.grade(
        config: _config(),
        payload: _payload(),
        studentAnswerText: 'A',
      ),
      throwsA(
        isA<AiFailure>().having(
          (AiFailure e) => e.kind,
          'kind',
          AiFailureKind.badResponse,
        ),
      ),
    );
  });

  test('判题：模型只给纯文字结论时也能接住（fromText）', () async {
    final _FakeClient client = _FakeClient(reply: '答案不对，应该是 B');
    final AiService service = AiService(
      configStore: _FakeConfigStore(),
      clientFactory: (LlmConfig _) => client,
    );
    final AiGrade grade = await service.grade(
      config: _config(),
      payload: _payload(),
      referenceAnswer: 'B',
      studentAnswerText: 'C',
      attachments: <AiImageAttachment>[
        AiImageAttachment(
          kind: AiImageKind.answer,
          label: '我的作答',
          bytes: Uint8List.fromList(<int>[9]),
        ),
      ],
    );
    expect(grade.verdict, AnswerVerdict.wrong);
    expect(grade.fromText, isTrue);
  });

  test('深度思考：thinking/content 分开，真实 usage 记账', () async {
    final _FakeClient client = _FakeClient(
      streamReply: '最终答案',
      streamThinking: '先分析条件',
      tokensIn: 30,
      tokensOut: 12,
    );
    final _FakeUsageDao dao = _FakeUsageDao();
    final AiService service = AiService(
      configStore: _FakeConfigStore(),
      usage: AiUsageService(dao),
      clientFactory: (LlmConfig _) => client,
    );
    final List<AiChatChunk> chunks = await service
        .chat(
          config: _config(model: 'deepseek-flash'),
          payload: _payload(),
          history: const <ChatTurn>[],
          message: '讲一下',
          deepThinking: true,
        )
        .toList();
    expect(chunks.map((AiChatChunk c) => c.thinking).join(), '先分析条件');
    expect(chunks.map((AiChatChunk c) => c.text).join(), '最终答案');
    expect(client.requests.single.includeUsage, true);
    expect(client.requests.single.maxTokens, 4096);
    expect(client.requests.single.thinkingMode, LlmThinkingMode.enabled);
    expect(dao.records.single.tokensIn, 30);
    expect(dao.records.single.tokensOut, 12);
    expect(dao.records.single.estimated, false);
    expect(dao.records.single.task, 'chat');
  });
}
