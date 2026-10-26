/// OpenAI 兼容协议的**纯函数层**：拼请求体、解析响应、拆 SSE。
///
/// 单独拆出来的理由：这些逻辑不需要网络就能单测，而网络层只负责
/// "把字节发出去、把状态码带回来"。
library;

import 'dart:convert';

import 'package:shuaqi/infra/ai/errors.dart';
import 'package:shuaqi/infra/ai/llm_client.dart';

/// 拼 `/chat/completions` 请求体。
///
/// 图片挂在**第一条 user 消息**上（不是最后一条）：这样每次请求只带一份图，
/// 历史再多也不会把图片重复计费；模型每次都能重新看到题面。
Map<String, Object?> buildChatRequestBody(
  LlmRequest request, {
  required bool stream,
  bool? includeUsage,
  LlmThinkingMode? thinkingMode,
}) {
  final List<Map<String, Object?>> messages = <Map<String, Object?>>[];
  int imageAnchor = -1;
  for (int i = 0; i < request.messages.length; i++) {
    if (request.messages[i].role == LlmRole.user) {
      imageAnchor = i;
      break;
    }
  }
  for (int i = 0; i < request.messages.length; i++) {
    final LlmMessage message = request.messages[i];
    final bool anchor = i == imageAnchor && request.images.isNotEmpty;
    messages.add(<String, Object?>{
      'role': message.role.name,
      'content': anchor
          ? <Map<String, Object?>>[
              <String, Object?>{'type': 'text', 'text': message.content},
              for (final LlmImage image in request.images)
                <String, Object?>{
                  'type': 'image_url',
                  'image_url': <String, Object?>{
                    'url': 'data:image/png;base64,${base64Encode(image.bytes)}',
                  },
                },
            ]
          : message.content,
    });
  }
  final LlmThinkingMode mode = thinkingMode ?? request.thinkingMode;
  return <String, Object?>{
    'model': request.model,
    'messages': messages,
    'stream': stream,
    'temperature': request.temperature,
    'max_tokens': request.maxTokens,
    if (stream && (includeUsage ?? request.includeUsage))
      'stream_options': <String, Object?>{'include_usage': true},
    if (mode == LlmThinkingMode.enabled) ...<String, Object?>{
      'thinking': <String, Object?>{'type': 'enabled'},
      'reasoning_effort': 'high',
    } else if (mode == LlmThinkingMode.disabled) ...<String, Object?>{
      'thinking': <String, Object?>{'type': 'disabled'},
    },
  };
}

/// 从完整 JSON 响应里取结果。
LlmResult parseChatCompletion(String body) {
  final Object? decoded = jsonDecode(body);
  if (decoded is! Map) {
    throw const LlmException(LlmErrorKind.badResponse, '响应不是 JSON 对象');
  }
  final Object? choices = decoded['choices'];
  if (choices is! List || choices.isEmpty) {
    throw const LlmException(LlmErrorKind.badResponse, '响应里没有 choices');
  }
  final Object? first = choices.first;
  if (first is! Map) {
    throw const LlmException(LlmErrorKind.badResponse, 'choices[0] 不是对象');
  }
  final Object? message = first['message'];
  final String text = message is Map
      ? _contentText(message['content'])
      : _contentText(first['text']);
  String reasoning = message is Map ? _reasoningText(message) : '';
  // 兼容把 reasoning 放在 choice / 顶层的中转网关。
  if (reasoning.isEmpty) {
    reasoning = _reasoningText(first);
  }
  if (reasoning.isEmpty) {
    reasoning = _reasoningText(decoded);
  }
  final Map<String, Object?>? usage = decoded['usage'] is Map
      ? (decoded['usage'] as Map).cast<String, Object?>()
      : null;
  return LlmResult(
    text: text,
    reasoning: reasoning,
    tokensIn: (usage?['prompt_tokens'] as num?)?.toInt() ?? 0,
    tokensOut: (usage?['completion_tokens'] as num?)?.toInt() ?? 0,
    model: (decoded['model'] as String?) ?? '',
  );
}

/// 一条 SSE 事件的结果。
class SseDelta {
  const SseDelta({
    this.text = '',
    this.reasoning = '',
    this.tokensIn = 0,
    this.tokensOut = 0,
    this.done = false,
  });

  final String text;

  /// DeepSeek reasoner 的 `reasoning_content`；与 [text] 分开。
  final String reasoning;

  final int tokensIn;
  final int tokensOut;

  final bool done;

  bool get isEmpty =>
      text.isEmpty &&
      reasoning.isEmpty &&
      tokensIn == 0 &&
      tokensOut == 0 &&
      !done;
}

/// 解析一条 `data:` 内容。
///
/// 兼容：
/// - `data: [DONE]`
/// - `choices[0].delta.content`（流式标准）
/// - `choices[0].message.content`（某些中转把非流式塞进 SSE）
SseDelta parseSseData(String data) {
  final String trimmed = data.trim();
  if (trimmed.isEmpty) {
    return const SseDelta();
  }
  if (trimmed == '[DONE]') {
    return const SseDelta(done: true);
  }
  final Object? decoded = jsonDecode(trimmed);
  if (decoded is! Map) {
    return const SseDelta();
  }
  int tokensIn = 0;
  int tokensOut = 0;
  final Object? usage = decoded['usage'];
  if (usage is Map) {
    tokensIn = (usage['prompt_tokens'] as num?)?.toInt() ?? 0;
    tokensOut = (usage['completion_tokens'] as num?)?.toInt() ?? 0;
  }
  final String topReasoning = _reasoningText(decoded);
  final Object? choices = decoded['choices'];
  if (choices is! List || choices.isEmpty) {
    return SseDelta(
      reasoning: topReasoning,
      tokensIn: tokensIn,
      tokensOut: tokensOut,
    );
  }
  final Object? first = choices.first;
  if (first is! Map) {
    return SseDelta(
      reasoning: topReasoning,
      tokensIn: tokensIn,
      tokensOut: tokensOut,
    );
  }
  final String choiceReasoning = _reasoningText(first);
  final Object? delta = first['delta'];
  if (delta is Map) {
    final String text = _contentText(delta['content']);
    final String deltaReasoning = _reasoningText(delta);
    final String reasoning = deltaReasoning.isNotEmpty
        ? deltaReasoning
        : (choiceReasoning.isNotEmpty ? choiceReasoning : topReasoning);
    if (text.isNotEmpty || reasoning.isNotEmpty) {
      return SseDelta(
        text: text,
        reasoning: reasoning,
        tokensIn: tokensIn,
        tokensOut: tokensOut,
      );
    }
  }
  final Object? message = first['message'];
  if (message is Map) {
    final String text = _contentText(message['content']);
    final String messageReasoning = _reasoningText(message);
    final String reasoning = messageReasoning.isNotEmpty
        ? messageReasoning
        : (choiceReasoning.isNotEmpty ? choiceReasoning : topReasoning);
    if (text.isNotEmpty || reasoning.isNotEmpty) {
      return SseDelta(
        text: text,
        reasoning: reasoning,
        tokensIn: tokensIn,
        tokensOut: tokensOut,
      );
    }
  }
  return SseDelta(
    reasoning: choiceReasoning.isNotEmpty ? choiceReasoning : topReasoning,
    tokensIn: tokensIn,
    tokensOut: tokensOut,
  );
}

/// 按行缓冲的 SSE 解析器。
///
/// SSE 一条事件可能被拆成多个 TCP 包，必须按行缓冲（开发指南 07 的坑）。
class SseParser {
  final StringBuffer _data = StringBuffer();
  String _buffer = '';

  /// 喂一块文本，返回**已经完整**的事件 data。
  List<String> add(String chunk) {
    _buffer += chunk;
    final List<String> events = <String>[];
    while (true) {
      final int newline = _buffer.indexOf('\n');
      if (newline < 0) {
        break;
      }
      String line = _buffer.substring(0, newline);
      _buffer = _buffer.substring(newline + 1);
      if (line.endsWith('\r')) {
        line = line.substring(0, line.length - 1);
      }
      if (line.isEmpty) {
        if (_data.isNotEmpty) {
          events.add(_data.toString().trimRight());
          _data.clear();
        }
        continue;
      }
      if (line.startsWith(':')) {
        continue; // 注释/心跳
      }
      if (line.startsWith('data:')) {
        final String value = line.substring(5);
        if (_data.isNotEmpty) {
          _data.write('\n');
        }
        _data.write(value.startsWith(' ') ? value.substring(1) : value);
      }
    }
    return events;
  }

  /// 流结束时把最后一条没有空行收尾的事件吐出来。
  List<String> flush() {
    if (_data.isEmpty) {
      return const <String>[];
    }
    final String event = _data.toString().trimRight();
    _data.clear();
    return event.isEmpty ? const <String>[] : <String>[event];
  }
}

/// HTTP 非 2xx → 分类异常。
LlmException classifyHttpStatus(int status, String body) {
  final String detail = errorMessageFrom(body);
  final String shortBody = _truncate(body);
  if (status == 401 || status == 403) {
    return LlmException(
      LlmErrorKind.auth,
      'Key 无效或没有权限',
      statusCode: status,
      body: shortBody,
    );
  }
  if (status == 429) {
    return LlmException(
      LlmErrorKind.rateLimited,
      '请求过于频繁',
      statusCode: status,
      body: shortBody,
    );
  }
  if (status == 408 || status == 504) {
    return LlmException(
      LlmErrorKind.timeout,
      '服务端超时',
      statusCode: status,
      body: shortBody,
    );
  }
  if (status >= 500) {
    return LlmException(
      LlmErrorKind.server,
      detail.isEmpty ? '服务端错误' : detail,
      statusCode: status,
      body: shortBody,
    );
  }
  if (bodyLooksLikeImageUnsupported(body)) {
    return LlmException(
      LlmErrorKind.unsupportedImage,
      detail.isEmpty ? '当前模型不支持图片输入' : detail,
      statusCode: status,
      body: shortBody,
    );
  }
  return LlmException(
    LlmErrorKind.badResponse,
    detail.isEmpty ? '请求被拒绝（HTTP $status）' : detail,
    statusCode: status,
    body: shortBody,
  );
}

/// 从错误响应里抠 `error.message`；抠不到就返回空。
String errorMessageFrom(String body) {
  try {
    final Object? decoded = jsonDecode(body);
    if (decoded is Map) {
      final Object? error = decoded['error'];
      if (error is Map && error['message'] is String) {
        return (error['message'] as String).trim();
      }
      if (decoded['message'] is String) {
        return (decoded['message'] as String).trim();
      }
    }
  } on FormatException {
    // 非 JSON：下面按纯文本截一段。
  }
  final String text = body.trim();
  if (text.isEmpty) {
    return '';
  }
  return _truncate(text, max: 160);
}

bool bodyLooksLikeImageUnsupported(String body) {
  final String lower = body.toLowerCase();
  for (final String marker in <String>[
    'image',
    'vision',
    'multimodal',
    'image_url',
    'not support',
    'unsupported',
  ]) {
    if (lower.contains(marker)) {
      return true;
    }
  }
  return false;
}

String _contentText(Object? content) {
  if (content is String) {
    return content;
  }
  if (content is List) {
    final StringBuffer buffer = StringBuffer();
    for (final Object? part in content) {
      if (part is Map) {
        final Object? text = part['text'] ?? part['token'] ?? part['content'];
        if (text is String) {
          buffer.write(text);
        }
      }
    }
    return buffer.toString();
  }
  return '';
}

/// 推理字段的兼容读取：
/// - DeepSeek：`reasoning_content`
/// - 部分中转：`reasoning` / `thinking`
String _reasoningText(Object? source) {
  if (source is! Map) {
    return '';
  }
  for (final String key in <String>[
    'reasoning_content',
    'reasoning',
    'thinking',
    'reasoning_details',
  ]) {
    final String value = _contentText(source[key]);
    if (value.isNotEmpty) {
      return value;
    }
  }
  return '';
}

String _truncate(String raw, {int max = 600}) {
  final String text = raw.trim();
  if (text.length <= max) {
    return text;
  }
  return '${text.substring(0, max)}…';
}
