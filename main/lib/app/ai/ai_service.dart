import 'dart:async';

import 'package:shuaqi/app/ai/usage_service.dart';
import 'package:shuaqi/domain/ai/ai_response.dart';
import 'package:shuaqi/domain/ai/chat.dart';
import 'package:shuaqi/domain/ai/knowledge_tag.dart';
import 'package:shuaqi/domain/ai/llm_config.dart';
import 'package:shuaqi/domain/ai/prompts.dart';
import 'package:shuaqi/domain/ai/question_payload.dart';
import 'package:shuaqi/domain/ai/usage.dart';
import 'package:shuaqi/infra/ai/errors.dart';
import 'package:shuaqi/infra/ai/llm_client.dart';
import 'package:shuaqi/infra/ai/llm_config_store.dart';
import 'package:shuaqi/infra/ai/openai_client.dart';

/// 把"配置 + 客户端 + 提示词 + 解析"编排成 UI 能直接用的三个动作：
/// 对话、补答案、判题。
///
/// 这一层在 `app/`：可以 import infra，但不 import Flutter，方便在纯 Dart
/// 测试里注入假客户端。
class AiService {
  AiService({
    required this.configStore,
    this.usage,
    LlmClient Function(LlmConfig config)? clientFactory,
  }) : _clientFactory =
           clientFactory ??
           ((LlmConfig config) => OpenAiCompatibleClient(config: config));

  final LlmConfigStore configStore;

  /// 旁路记账；null = 测试或不关心用量。
  final AiUsageService? usage;

  final LlmClient Function(LlmConfig config) _clientFactory;

  LlmClient? _client;
  LlmConfig? _clientConfig;

  LlmClient _clientFor(LlmConfig config) {
    final LlmClient? existing = _client;
    if (existing != null && _clientConfig == config) {
      return existing;
    }
    _disposeClient();
    _client = _clientFactory(config);
    _clientConfig = config;
    return _client!;
  }

  void _disposeClient() {
    final LlmClient? client = _client;
    if (client is OpenAiCompatibleClient) {
      client.dispose();
    }
    _client = null;
    _clientConfig = null;
  }

  Future<LlmConfig> loadConfig() => configStore.load();

  /// 设置页的"测试连接"。
  Future<AiHealth> testConnection(LlmConfig config) async {
    final LlmConfig value = config.normalized();
    final String? problem = value.validationError();
    if (problem != null) {
      return AiHealth(ok: false, message: problem);
    }
    final Stopwatch watch = Stopwatch()..start();
    final LlmRequest request = LlmRequest(
      model: value.model,
      messages: const <LlmMessage>[LlmMessage.user('ping')],
      taskTag: LlmTaskTag.chat,
      temperature: 0,
      maxTokens: 8,
      timeout: value.timeout < const Duration(seconds: 20)
          ? value.timeout
          : const Duration(seconds: 20),
    );
    try {
      final LlmClient client = _clientFor(value);
      final LlmResult result = await client.complete(request);
      watch.stop();
      await _recordUsage(
        task: 'test',
        config: value,
        tokensIn: result.tokensIn > 0
            ? result.tokensIn
            : _estimatePrompt(request.messages),
        tokensOut: result.tokensOut > 0
            ? result.tokensOut
            : _estimateTokens(result.text),
        estimated: result.tokensIn == 0 && result.tokensOut == 0,
        ok: true,
      );
      final String modelLabel = result.model.trim().isEmpty
          ? value.model
          : result.model.trim();
      return AiHealth(
        ok: true,
        message: '连接成功 · ${watch.elapsedMilliseconds}ms · $modelLabel',
        latency: watch.elapsed,
      );
    } on Object catch (error) {
      watch.stop();
      await _recordUsage(
        task: 'test',
        config: value,
        tokensIn: _estimatePrompt(request.messages),
        tokensOut: 0,
        estimated: true,
        ok: false,
      );
      final AiFailure failure = _mapError(error);
      return AiHealth(
        ok: false,
        message: failure.message,
        latency: watch.elapsed,
      );
    }
  }

  /// 流式对话。调用方累积 content / thinking；失败抛 [AiFailure]。
  Stream<AiChatChunk> chat({
    required LlmConfig config,
    required QuestionAiPayload payload,
    required List<ChatTurn> history,
    required String message,
    List<AiImageAttachment> attachments = const <AiImageAttachment>[],
    String? referenceAnswer,
    bool deepThinking = false,
    int historyLimit = 20,
  }) async* {
    _ensureConfigured(config);
    final bool sendImages = config.allowImages;
    final List<AiImageAttachment> usable = _usableAttachments(attachments);
    final bool hasText =
        payload.extractedText != null &&
        payload.extractedText!.trim().isNotEmpty;
    if (!sendImages && !hasText) {
      // 没图也没文本，模型看不到题；提前给出可操作的原因。
      throw const AiFailure(
        AiFailureKind.unsupportedImage,
        '设置里关闭了「发送题面图片」，这道题又没有可发送的文本；'
        '请在设置里打开传图，或换一道有文本层的题。',
        retryable: false,
      );
    }
    final List<LlmImage> images = sendImages
        ? _toLlmImages(usable)
        : <LlmImage>[];
    if (images.isEmpty && !hasText) {
      throw const AiFailure(
        AiFailureKind.unsupportedImage,
        '题面图片没有取到，本题也没有可发送的文本；'
        '先点题面预览重试，或在设置里打开「发送题面图片」。',
        retryable: false,
      );
    }
    final List<LlmMessage> messages = <LlmMessage>[
      LlmMessage.system(
        chatSystem(
          payload,
          referenceAnswer: referenceAnswer,
          imagesIncluded: images.isNotEmpty,
          deepThinking: deepThinking,
        ),
      ),
      LlmMessage.user(
        chatIntro(
          payload,
          imageLabels: images.isEmpty
              ? const <String>[]
              : <String>[
                  for (final AiImageAttachment item in usable) item.label,
                ],
        ),
      ),
    ];
    final List<ChatTurn> usableHistory = history
        .where((ChatTurn turn) => !turn.failed && turn.text.trim().isNotEmpty)
        .toList(growable: false);
    final Iterable<ChatTurn> tail = usableHistory.length <= historyLimit
        ? usableHistory
        : usableHistory.sublist(usableHistory.length - historyLimit);
    for (final ChatTurn turn in tail) {
      messages.add(
        turn.mine
            ? LlmMessage.user(turn.text)
            : LlmMessage.assistant(turn.text),
      );
    }
    messages.add(LlmMessage.user(message));
    final LlmRequest request = LlmRequest(
      model: config.model,
      messages: messages,
      taskTag: LlmTaskTag.chat,
      images: images,
      temperature: 0.6,
      // 推理内容也算 completion tokens；1400 在 thinking 模式下容易被推理吃光。
      maxTokens: deepThinking ? 4096 : 1400,
      timeout: config.timeout,
      includeUsage: true,
      thinkingMode: _isDeepSeek(config)
          ? (deepThinking ? LlmThinkingMode.enabled : LlmThinkingMode.disabled)
          : LlmThinkingMode.defaultMode,
    );
    int tokensIn = 0;
    int tokensOut = 0;
    bool gotUsage = false;
    int estimatedOut = 0;
    bool ok = true;
    try {
      final LlmClient client = _clientFor(config);
      await for (final LlmChunk chunk in client.stream(request)) {
        if (chunk.tokensIn > 0 || chunk.tokensOut > 0) {
          tokensIn = chunk.tokensIn > 0 ? chunk.tokensIn : tokensIn;
          tokensOut = chunk.tokensOut > 0 ? chunk.tokensOut : tokensOut;
          gotUsage = true;
        }
        if (chunk.reasoning.isNotEmpty || chunk.delta.isNotEmpty) {
          estimatedOut +=
              _estimateTokens(chunk.reasoning) + _estimateTokens(chunk.delta);
          yield AiChatChunk(text: chunk.delta, thinking: chunk.reasoning);
        }
        if (chunk.done) {
          return;
        }
      }
    } on Object catch (error) {
      ok = false;
      throw _mapError(error);
    } finally {
      await _recordUsage(
        task: 'chat',
        config: config,
        tokensIn: gotUsage
            ? tokensIn
            : _estimatePrompt(messages, images: images.length),
        tokensOut: gotUsage ? tokensOut : estimatedOut,
        estimated: !gotUsage,
        ok: ok,
      );
    }
  }

  /// 让 AI 独立做一遍这道题。返回的 answer 为空 = 没解析出答案。
  Future<AiSolution> solve({
    required LlmConfig config,
    required QuestionAiPayload payload,
    List<AiImageAttachment> attachments = const <AiImageAttachment>[],
  }) async {
    _ensureConfigured(config);
    final List<AiImageAttachment> usable = _usableAttachments(attachments);
    final bool hasText =
        payload.extractedText != null &&
        payload.extractedText!.trim().isNotEmpty;
    if (!config.allowImages && !hasText) {
      throw const AiFailure(
        AiFailureKind.unsupportedImage,
        '设置里关闭了「发送题面图片」，这道题又没有可发送的文本；无法解题。',
        retryable: false,
      );
    }
    final List<LlmImage> images = config.allowImages
        ? _toLlmImages(usable)
        : const <LlmImage>[];
    if (images.isEmpty && !hasText) {
      throw const AiFailure(
        AiFailureKind.unsupportedImage,
        '题面图片没有取到，本题也没有可发送的文本；无法解题。',
        retryable: false,
      );
    }
    final LlmRequest request = LlmRequest.analysis(
      model: config.model,
      messages: <LlmMessage>[
        LlmMessage.system(
          solveSystem(payload, imagesIncluded: images.isNotEmpty),
        ),
        LlmMessage.user(solveUser()),
      ],
      taskTag: LlmTaskTag.insightMd,
      images: images,
      maxTokens: 2000,
      timeout: config.timeout,
    );
    try {
      final LlmResult result = await _clientFor(config).complete(request);
      await _recordUsage(
        task: 'solve',
        config: config,
        tokensIn: result.tokensIn > 0
            ? result.tokensIn
            : _estimatePrompt(request.messages, images: images.length),
        tokensOut: result.tokensOut > 0
            ? result.tokensOut
            : _estimateTokens(result.text),
        estimated: result.tokensIn == 0 && result.tokensOut == 0,
        ok: true,
      );
      final AiSolution? solution = parseAiSolution(result.text);
      if (solution == null) {
        throw const AiFailure(
          AiFailureKind.badResponse,
          'AI 这次没有返回可用内容，请再试一次。',
        );
      }
      return solution;
    } on Object catch (error) {
      if (error is! AiFailure) {
        await _recordUsage(
          task: 'solve',
          config: config,
          tokensIn: _estimatePrompt(request.messages, images: images.length),
          tokensOut: 0,
          estimated: true,
          ok: false,
        );
      }
      throw _mapError(error);
    }
  }

  /// 判一道题。返回 pending 表示"AI 也拿不准"。
  Future<AiGrade> grade({
    required LlmConfig config,
    required QuestionAiPayload payload,
    String? referenceAnswer,
    required String studentAnswerText,
    List<AiImageAttachment> attachments = const <AiImageAttachment>[],
  }) async {
    _ensureConfigured(config);
    final List<AiImageAttachment> usable = _usableAttachments(attachments);
    final bool hasText = studentAnswerText.trim().isNotEmpty;
    final bool hasAnswerImage = usable.any(
      (AiImageAttachment item) => item.kind == AiImageKind.answer,
    );
    final bool hasImage = config.allowImages && hasAnswerImage;
    if (!hasText && !hasImage) {
      throw const AiFailure(
        AiFailureKind.badResponse,
        '这道题还没有可判的作答：先在答题卡写，或展开「答题情况」识别一下。',
        retryable: false,
      );
    }
    final List<LlmImage> images = config.allowImages
        ? _toLlmImages(usable)
        : const <LlmImage>[];
    final LlmRequest request = LlmRequest.analysis(
      model: config.model,
      messages: <LlmMessage>[
        LlmMessage.system(
          gradeSystem(
            payload,
            referenceAnswer: referenceAnswer,
            imagesIncluded: images.isNotEmpty,
          ),
        ),
        LlmMessage.user(
          gradeUser(
            studentAnswerText: studentAnswerText,
            referenceAnswer: referenceAnswer,
            hasAnswerImage: hasImage,
          ),
        ),
      ],
      taskTag: LlmTaskTag.insightMd,
      images: images,
      maxTokens: 600,
      timeout: config.timeout,
    );
    try {
      final LlmResult result = await _clientFor(config).complete(request);
      await _recordUsage(
        task: 'grade',
        config: config,
        tokensIn: result.tokensIn > 0
            ? result.tokensIn
            : _estimatePrompt(request.messages, images: images.length),
        tokensOut: result.tokensOut > 0
            ? result.tokensOut
            : _estimateTokens(result.text),
        estimated: result.tokensIn == 0 && result.tokensOut == 0,
        ok: true,
      );
      final AiGrade? grade = parseAiGrade(result.text);
      if (grade == null) {
        throw const AiFailure(
          AiFailureKind.badResponse,
          'AI 判题结果格式异常，这次没有写入判题。请重试。',
        );
      }
      return grade;
    } on Object catch (error) {
      if (error is! AiFailure) {
        await _recordUsage(
          task: 'grade',
          config: config,
          tokensIn: _estimatePrompt(request.messages, images: images.length),
          tokensOut: 0,
          estimated: true,
          ok: false,
        );
      }
      throw _mapError(error);
    }
  }

  /// 一次请求最多 4 张图：题面 + 作答 + 2 张用户补充。
  /// 再多会显著抬成本，也让模型抓不住重点。
  static const int maxImagesPerRequest = 4;

  /// 批量归纳知识点（T8.5）。返回 `favoriteId → 标签列表`。
  ///
  /// 只发文本：收藏可能没有题面图/原卷已删，归纳只看"题号+卷名+题型+题干"。
  /// 每批最多 [maxTagItemsPerRequest] 题：太多会把 JSON 撑到 max_tokens 之外，
  /// 模型会截断成半截 JSON（用户接自己的接口时最容易踩这个坑）。
  /// 解析失败时错误信息带一小段原始返回，便于用户判断是模型/网关的问题。
  static const int maxTagItemsPerRequest = 20;

  Future<Map<String, List<String>>> tagKnowledge({
    required LlmConfig config,
    required List<KnowledgeTagItem> items,
  }) async {
    _ensureConfigured(config);
    if (items.isEmpty) {
      return <String, List<String>>{};
    }
    final Map<String, List<String>> merged = <String, List<String>>{};
    for (int start = 0; start < items.length; start += maxTagItemsPerRequest) {
      final List<KnowledgeTagItem> chunk = items
          .skip(start)
          .take(maxTagItemsPerRequest)
          .toList(growable: false);
      final Map<String, List<String>> part = await _tagKnowledgeChunk(
        config: config,
        items: chunk,
      );
      merged.addAll(part);
    }
    return merged;
  }

  Future<Map<String, List<String>>> _tagKnowledgeChunk({
    required LlmConfig config,
    required List<KnowledgeTagItem> items,
  }) async {
    final LlmRequest request = LlmRequest.analysis(
      model: config.model,
      messages: <LlmMessage>[
        LlmMessage.system(knowledgeTagSystem()),
        LlmMessage.user(knowledgeTagUser(items)),
      ],
      taskTag: LlmTaskTag.insightMd,
      maxTokens: 2048,
      timeout: config.timeout,
    );
    try {
      final LlmResult result = await _clientFor(config).complete(request);
      await _recordUsage(
        task: 'tags',
        config: config,
        tokensIn: result.tokensIn > 0
            ? result.tokensIn
            : _estimatePrompt(request.messages),
        tokensOut: result.tokensOut > 0
            ? result.tokensOut
            : _estimateTokens(result.text),
        estimated: result.tokensIn == 0 && result.tokensOut == 0,
        ok: true,
      );
      Map<String, List<String>>? parsed = parseKnowledgeTagResponse(
        result.text,
      );
      // 少数推理模型把 JSON 塞进 reasoning_content，content 留空。
      if ((parsed == null || parsed.isEmpty) &&
          result.reasoning.trim().isNotEmpty) {
        parsed = parseKnowledgeTagResponse(result.reasoning);
      }
      if (parsed == null || parsed.isEmpty) {
        final String head = result.text.trim().isEmpty
            ? (result.reasoning.trim().isEmpty
                  ? '（空回复）'
                  : result.reasoning.trim())
            : result.text.trim();
        final String snippet = head.length <= 120
            ? head
            : '${head.substring(0, 120)}…';
        throw AiFailure(
          AiFailureKind.badResponse,
          'AI 返回里没有可用的知识点标签。原始返回开头：$snippet\n'
          '可重试，或换一个能稳定输出 JSON 的模型。',
        );
      }
      final Map<String, List<String>> resolved = resolveKnowledgeTagKeys(
        parsed,
        items,
      );
      if (resolved.isEmpty) {
        throw const AiFailure(
          AiFailureKind.badResponse,
          'AI 给出了标签，但和题目对不上（可能用了题号/别的 id）。请重试。',
        );
      }
      return resolved;
    } on Object catch (error) {
      if (error is! AiFailure) {
        await _recordUsage(
          task: 'tags',
          config: config,
          tokensIn: _estimatePrompt(request.messages),
          tokensOut: 0,
          estimated: true,
          ok: false,
        );
      }
      throw _mapError(error);
    }
  }

  List<AiImageAttachment> _usableAttachments(
    List<AiImageAttachment> attachments,
  ) {
    final List<AiImageAttachment> usable = <AiImageAttachment>[];
    for (final AiImageAttachment item in attachments) {
      if (item.isEmpty || usable.length >= maxImagesPerRequest) {
        continue;
      }
      usable.add(item);
    }
    return usable;
  }

  List<LlmImage> _toLlmImages(List<AiImageAttachment> attachments) =>
      <LlmImage>[
        for (final AiImageAttachment item in attachments)
          LlmImage(bytes: item.bytes),
      ];

  void _ensureConfigured(LlmConfig config) {
    final String? problem = config.validationError();
    if (problem != null) {
      throw AiFailure(
        AiFailureKind.notConfigured,
        '还没有配置 AI：$problem。点右上角设置填写端点、Key 和模型。',
        retryable: false,
      );
    }
  }

  /// 旁路记一笔。失败不影响主流程。
  Future<void> _recordUsage({
    required String task,
    required LlmConfig config,
    required int tokensIn,
    required int tokensOut,
    required bool estimated,
    required bool ok,
  }) async {
    final AiUsageService? sink = usage;
    if (sink == null) {
      return;
    }
    await sink.record(
      AiUsageRecord(
        at: DateTime.now().millisecondsSinceEpoch,
        model: config.model,
        task: task,
        tokensIn: tokensIn,
        tokensOut: tokensOut,
        estimated: estimated,
        ok: ok,
      ),
    );
  }

  int _estimateTokens(String text) {
    if (text.isEmpty) {
      return 0;
    }
    int cjk = 0;
    int ascii = 0;
    for (final int rune in text.runes) {
      if (rune >= 0x2E80) {
        cjk++;
      } else if (rune > 0x20 && rune != 0x7F) {
        ascii++;
      }
    }
    return cjk + (ascii / 4).ceil();
  }

  int _estimatePrompt(List<LlmMessage> messages, {int images = 0}) {
    int total = 0;
    for (final LlmMessage message in messages) {
      total += _estimateTokens(message.content);
    }
    // 一张图按 ~600 token 粗估（不同厂商差异很大，只用于"没有 usage"时占位）。
    return total + images * 600;
  }

  /// 只有 DeepSeek 才发 `thinking` / `reasoning_effort`；其他兼容端点不猜。
  bool _isDeepSeek(LlmConfig config) {
    final String base = config.baseUrl.toLowerCase();
    final String model = config.model.toLowerCase();
    return base.contains('deepseek') || model.contains('deepseek');
  }

  AiFailure _mapError(Object error) {
    if (error is AiFailure) {
      return error;
    }
    if (error is LlmException) {
      switch (error.kind) {
        case LlmErrorKind.notConfigured:
          return const AiFailure(
            AiFailureKind.notConfigured,
            '还没有配置 AI。点右上角设置填端点、Key 和模型。',
            retryable: false,
          );
        case LlmErrorKind.auth:
          return const AiFailure(
            AiFailureKind.auth,
            'Key 无效或没有权限（401/403）。去设置里检查 Key。',
            retryable: false,
          );
        case LlmErrorKind.rateLimited:
          return const AiFailure(
            AiFailureKind.rateLimited,
            '请求太频繁（429）。等一会儿再点重试。',
          );
        case LlmErrorKind.network:
          return const AiFailure(
            AiFailureKind.network,
            '网络不通（连接被拒绝或已断开）。检查平板网络或端点地址。',
          );
        case LlmErrorKind.server:
          return AiFailure(
            AiFailureKind.server,
            '服务端出错：${error.message}。稍后再试。',
          );
        case LlmErrorKind.timeout:
          return const AiFailure(
            AiFailureKind.timeout,
            '这次超时了。已收到的内容会保留，可以点重试。',
          );
        case LlmErrorKind.badResponse:
          return AiFailure(
            AiFailureKind.badResponse,
            'AI 返回格式异常：${error.message}。',
          );
        case LlmErrorKind.unsupportedImage:
          return AiFailure(
            AiFailureKind.unsupportedImage,
            '当前模型不支持图片：${error.message}。'
            '可以去设置里关掉「发送题面图片」，只发文本。',
          );
      }
    }
    if (error is TimeoutException) {
      return const AiFailure(AiFailureKind.timeout, '这次超时了。已收到的内容会保留，可以点重试。');
    }
    if (error is FormatException) {
      return const AiFailure(
        AiFailureKind.badResponse,
        'AI 返回的 JSON 解析失败。请重试，或换个模型。',
      );
    }
    return AiFailure(AiFailureKind.badResponse, 'AI 调用失败：$error');
  }

  void dispose() => _disposeClient();
}
