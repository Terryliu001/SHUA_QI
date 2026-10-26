/// 「问 AI」的对话与结果模型（纯 Dart）。
///
/// 为什么单独一层：
/// - UI 不该 import `infra/ai`（架构约束），所以流式增量、错误、判题结果
///   都用这里的领域类型表达；
/// - 聊天要落盘、要在重启后还在，[ChatTurn] 的 JSON 形状就是数据契约。
library;

import 'dart:typed_data';

import 'package:shuaqi/domain/model/grading.dart';

/// 一张要随消息发给模型的图片。
///
/// 为什么放在 domain 而不是 UI 局部类：`AiService` 也要用它（app 层可 import
/// domain），并按顺序组装成多模态消息。
enum AiImageKind {
  /// PDF 原页裁切（题面），权威来源。
  question,

  /// 学生作答（答题卡或卷内笔迹）。
  answer,

  /// 用户从相册/文件里临时添加的图片。
  user,
}

class AiImageAttachment {
  const AiImageAttachment({
    required this.kind,
    required this.label,
    required this.bytes,
    this.width = 0,
    this.height = 0,
  });

  final AiImageKind kind;
  final String label;
  final Uint8List bytes;
  final double width;
  final double height;

  bool get isEmpty => bytes.isEmpty;
}

/// 流式回复的一小段。
///
/// 为什么要分成 content / thinking 两路：
/// - DeepSeek reasoner 等模型会把推理写在 `reasoning_content` 里；
///   它不该混进最终回答，但用户想看到"它在想什么"。
/// - 不支持的模型只会有 [text]，UI 就只显示回答，并保留"深度思考"提示。
class AiChatChunk {
  const AiChatChunk({this.text = '', this.thinking = ''});

  final String text;
  final String thinking;

  bool get isEmpty => text.isEmpty && thinking.isEmpty;
}

/// 一轮对话的角色。
enum ChatRole {
  user,
  assistant;

  static ChatRole decode(String? raw) =>
      raw == assistant.name ? assistant : user;
}

/// 一轮消息的展示类型。
///
/// `text` 是普通聊天；`verdict` / `answer` 是快捷动作的结构化结果，
/// 面板据此画不同底色的小卡片，而不是让模型输出裸 JSON。
enum ChatTurnKind {
  text,
  verdict,
  answer,
  error,
  notice;

  static ChatTurnKind decode(String? raw) {
    for (final ChatTurnKind kind in values) {
      if (kind.name == raw) {
        return kind;
      }
    }
    return text;
  }
}

/// 对话的一轮。
class ChatTurn {
  const ChatTurn({
    required this.role,
    required this.text,
    this.at = 0,
    this.kind = ChatTurnKind.text,
    this.verdict,
    this.referenceAnswer,
    this.thinking,
    this.deepThinking = false,
    this.imageCount = 0,
    this.retryable = false,
    this.applied = true,
    this.failed = false,
    this.fromText = false,
  });

  factory ChatTurn.user(String text, {int at = 0, int imageCount = 0}) =>
      ChatTurn(role: ChatRole.user, text: text, at: at, imageCount: imageCount);

  factory ChatTurn.assistant(
    String text, {
    int at = 0,
    String? thinking,
    bool deepThinking = false,
  }) => ChatTurn(
    role: ChatRole.assistant,
    text: text,
    at: at,
    thinking: thinking,
    deepThinking: deepThinking,
  );

  factory ChatTurn.error(
    String text, {
    int at = 0,
    String? thinking,
    bool deepThinking = false,
    bool retryable = false,
  }) => ChatTurn(
    role: ChatRole.assistant,
    text: text,
    at: at,
    kind: ChatTurnKind.error,
    thinking: thinking,
    deepThinking: deepThinking,
    retryable: retryable,
    failed: true,
  );

  factory ChatTurn.fromJson(Map<String, Object?> json) => ChatTurn(
    role: ChatRole.decode(json['role'] as String?),
    text: (json['text'] as String?) ?? '',
    at: (json['at'] as num?)?.toInt() ?? 0,
    kind: ChatTurnKind.decode(json['kind'] as String?),
    verdict: json['verdict'] == null
        ? null
        : AnswerVerdict.decode(json['verdict'] as String?),
    referenceAnswer: json['reference_answer'] as String?,
    thinking: json['thinking'] as String?,
    deepThinking: json['deep_thinking'] == true,
    imageCount: (json['image_count'] as num?)?.toInt() ?? 0,
    retryable: json['retryable'] == true,
    applied: json['applied'] != false,
    failed: json['failed'] == true,
    fromText: json['from_text'] == true,
  );

  final ChatRole role;
  final String text;
  final int at;
  final ChatTurnKind kind;

  /// 只有 [ChatTurnKind.verdict] 有值。
  final AnswerVerdict? verdict;

  /// 只有 [ChatTurnKind.answer] 有值（AI 补出来的参考答案）。
  final String? referenceAnswer;

  /// 深度思考的 reasoning 内容（如果接口返回）。不掺进 [text]。
  final String? thinking;

  /// 这一轮是否请求了深度思考（即使模型没返回 reasoning，也留个标）。
  final bool deepThinking;

  /// 这条消息随附了几张图（只记数量，图本身不落盘）。
  final int imageCount;

  /// 失败气泡是否可重试（只有聊天流失败才给重试按钮）。
  final bool retryable;

  /// 结构化结果是否真的写进了判题/答案库。false = 已有手改结论，未覆盖。
  final bool applied;

  /// 网络/解析失败：**不落盘**，重开后不该假装是 AI 说过的话。
  final bool failed;

  /// true = 这一条判题结论是**从纯文字里读出来的**（模型没回 JSON）。
  ///
  /// 界面据此标「按文字判定 · 请复核」——纯文字判定更容易被否定词带偏，
  /// 必须让人自己看一眼再信。
  final bool fromText;

  bool get mine => role == ChatRole.user;

  bool get persistable =>
      !failed &&
      kind != ChatTurnKind.error &&
      (text.trim().isNotEmpty ||
          (thinking != null && thinking!.trim().isNotEmpty));

  Map<String, Object?> toJson() => <String, Object?>{
    'role': role.name,
    'text': text,
    'at': at,
    'kind': kind.name,
    if (verdict != null) 'verdict': verdict!.name,
    if (referenceAnswer != null) 'reference_answer': referenceAnswer,
    if (thinking != null && thinking!.trim().isNotEmpty) 'thinking': thinking,
    if (deepThinking) 'deep_thinking': true,
    if (imageCount > 0) 'image_count': imageCount,
    if (!applied) 'applied': false,
    if (failed) 'failed': true,
    if (fromText) 'from_text': true,
  };

  static List<ChatTurn> listFromJson(Object? raw) {
    if (raw is! List) {
      return const <ChatTurn>[];
    }
    final List<ChatTurn> turns = <ChatTurn>[];
    for (final Object? item in raw) {
      if (item is! Map) {
        continue;
      }
      final ChatTurn turn = ChatTurn.fromJson(item.cast<String, Object?>());
      // 只要还有正文或推理就保留；推理-only 的轮次不能因为 text 为空被丢掉。
      if (turn.text.trim().isEmpty &&
          (turn.thinking == null || turn.thinking!.trim().isEmpty)) {
        continue;
      }
      turns.add(turn);
    }
    return turns;
  }

  static List<Map<String, Object?>> listToJson(
    Iterable<ChatTurn> turns, {
    int limit = 60,
  }) {
    final List<ChatTurn> keep = turns
        .where((ChatTurn turn) => turn.persistable)
        .toList(growable: false);
    final Iterable<ChatTurn> tail = keep.length <= limit
        ? keep
        : keep.sublist(keep.length - limit);
    return <Map<String, Object?>>[
      for (final ChatTurn turn in tail) turn.toJson(),
    ];
  }
}

/// 快捷动作。
enum AiQuickAction {
  /// 讲这道题：走普通对话，不落结构。
  explain,

  /// 先做一遍：让 AI 给出答案 + 解析。
  solve,

  /// 判我的作答。
  grade,
}

/// AI 失败分类。**必须区分**：文案不同，重试策略也不同（开发指南 07 的失败处理表）。
enum AiFailureKind {
  notConfigured,
  auth,
  rateLimited,
  network,
  server,
  timeout,
  badResponse,
  unsupportedImage,
  cancelled,
}

/// 给 UI 的失败对象。异常信息里**不含 Key**。
class AiFailure implements Exception {
  const AiFailure(this.kind, this.message, {this.retryable = true});

  final AiFailureKind kind;
  final String message;
  final bool retryable;

  @override
  String toString() => 'AiFailure(${kind.name}): $message';
}

/// AI 的判题结论。
class AiGrade {
  const AiGrade({
    required this.verdict,
    required this.reason,
    this.confidence = 0,
    this.fromText = false,
  });

  final AnswerVerdict verdict;
  final String reason;
  final double confidence;

  /// true = 结论是从**纯文字**里读出来的（模型没回 JSON）。
  ///
  /// 界面要据此标「按文字判定 · 请复核」——纯文字判定比 JSON 更容易
  /// 被否定词带偏（"答案不对，应该是 B"），必须让人自己看一眼。
  final bool fromText;
}

/// AI 补出来的参考答案。
class AiSolution {
  const AiSolution({
    required this.answer,
    required this.explanation,
    this.confidence = 0,
    this.raw = '',
  });

  /// 最终答案。空 = 没解析出来（只展示 [explanation]，不落答案库）。
  final String answer;

  /// 分步解析。
  final String explanation;

  final double confidence;

  /// 模型原文（解析失败时用于兜底展示）。
  final String raw;
}

/// 快捷动作返回给面板的结果。
class AiChatResult {
  const AiChatResult({
    required this.text,
    this.solution,
    this.grade,
    this.applied = true,
    this.fromText = false,
  });

  final String text;
  final AiSolution? solution;
  final AiGrade? grade;

  /// 判题/答案是否真的落盘（手改优先时可能为 false）。
  final bool applied;

  /// true = 判题结论来自**纯文字**（模型没回 JSON）。
  final bool fromText;
}

/// 连通性测试结果。
class AiHealth {
  const AiHealth({required this.ok, required this.message, this.latency});

  final bool ok;
  final String message;
  final Duration? latency;
}
