import 'dart:typed_data';

/// BYOK 大模型客户端契约（规格 §6.6、§7）。
///
/// 这一层只负责"把请求发出去、把回复拿回来、把计量记下来"。
/// **提示词策略、降级文案、是否展示** 全部属于 `app/analysis`，不许下沉到这里。
///
/// 7 种失败场景（未配置 / 401 / 429 / 5xx / 超时 / 非法 JSON / 不支持图片）
/// 的处置策略在 app 层实现，因为只有它知道"当前是在结果页还是在对话里"。
abstract interface class LlmClient {
  Future<LlmResult> complete(LlmRequest request);

  /// 流式。**超时时必须保留已收到的内容**（§6.6），所以调用方要自己累积 chunk，
  /// 不能等 stream 正常结束才使用。
  Stream<LlmChunk> stream(LlmRequest request);

  /// 设置页的"测试连接"。任何异常都返回 false，不抛。
  Future<bool> healthCheck();
}

/// 提示词任务标签。写进计费日志，也用于同题去重键（§6.6 约束）。
enum LlmTaskTag {
  /// 步骤复述（结构化 JSON）。
  stepCoverage,

  /// 单题洞察（markdown）。
  insightMd,

  /// 自动打标签（v1.1）。
  tag,

  /// 单题对话。
  chat,
}

enum LlmRole { system, user, assistant }

class LlmMessage {
  const LlmMessage(this.role, this.content);

  const LlmMessage.system(this.content) : role = LlmRole.system;

  const LlmMessage.assistant(this.content) : role = LlmRole.assistant;

  const LlmMessage.user(this.content) : role = LlmRole.user;

  final LlmRole role;
  final String content;

  Map<String, Object?> toJson() => <String, Object?>{
    'role': role.name,
    'content': content,
  };
}

/// 一张图。长边上限 1024（§6.6），超过由调用方先缩，不在这里做。
class LlmImage {
  const LlmImage({required this.bytes, this.maxEdge = 1024});

  final Uint8List bytes;
  final int maxEdge;
}

/// 推理开关的服务端表达。只有 DeepSeek 这类明确支持 `thinking` 的端点才发。
enum LlmThinkingMode { defaultMode, enabled, disabled }

class LlmRequest {
  const LlmRequest({
    required this.model,
    required this.messages,
    required this.taskTag,
    this.images = const <LlmImage>[],
    this.temperature = 0.7,
    this.maxTokens = 1024,
    this.timeout = const Duration(seconds: 60),
    this.includeUsage = false,
    this.thinkingMode = LlmThinkingMode.defaultMode,
  });

  /// 分析类请求：temperature 固定 0.3（§6.6）。
  const LlmRequest.analysis({
    required this.model,
    required this.messages,
    required this.taskTag,
    this.images = const <LlmImage>[],
    this.maxTokens = 2048,
    this.timeout = const Duration(seconds: 60),
    this.includeUsage = false,
    this.thinkingMode = LlmThinkingMode.defaultMode,
  }) : temperature = 0.3;

  final String model;
  final List<LlmMessage> messages;
  final List<LlmImage> images;
  final double temperature;
  final int maxTokens;
  final Duration timeout;
  final LlmTaskTag taskTag;

  /// 流式请求是否让服务端在末尾回一条 usage（`stream_options.include_usage`）。
  /// 部分兼容端点不认这个字段，客户端会做一次无该字段的降级重试。
  final bool includeUsage;

  /// DeepSeek 等端点的 thinking 开关；默认不发，避免老网关 400。
  final LlmThinkingMode thinkingMode;
}

class LlmResult {
  const LlmResult({
    required this.text,
    this.reasoning = '',
    this.tokensIn = 0,
    this.tokensOut = 0,
    this.model = '',
  });

  final String text;

  /// DeepSeek reasoner 等返回的推理内容（`reasoning_content`）。
  final String reasoning;

  final int tokensIn;
  final int tokensOut;

  /// 服务端回报的模型名，可能和请求的不一样（部分兼容实现会改写）。
  final String model;
}

class LlmChunk {
  const LlmChunk({
    this.delta = '',
    this.reasoning = '',
    this.tokensIn = 0,
    this.tokensOut = 0,
    this.done = false,
  });

  final String delta;

  /// 推理增量；与 [delta] 分开，避免混进最终回答。
  final String reasoning;

  /// 服务端在流末尾回报的用量（需要 `stream_options.include_usage`）。
  final int tokensIn;
  final int tokensOut;

  final bool done;
}
