import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:shuaqi/domain/ai/llm_config.dart';
import 'package:shuaqi/infra/ai/errors.dart';
import 'package:shuaqi/infra/ai/llm_client.dart';
import 'package:shuaqi/infra/ai/openai_protocol.dart';

/// 一个薄薄的 OpenAI 兼容客户端。
///
/// 为什么用 `dart:io HttpClient` 而不是 `package:http`：
/// 1. SSE 需要按行读、边收边吐，`HttpClient` 的流最直接；
/// 2. 不新增依赖（本轮只允许 `flutter_math_fork`）；
/// 3. 超时、取消、连接错误都在自己的手里，不被拦截器偷偷重试。
///
/// 这一层**只做协议**：提示词、降级文案、是否展示都在 `app/ai`。
class OpenAiCompatibleClient implements LlmClient {
  OpenAiCompatibleClient({required this.config, HttpClient? httpClient})
    : _http = httpClient ?? HttpClient() {
    _http.connectionTimeout = config.timeout;
    _http.idleTimeout = config.timeout;
  }

  final LlmConfig config;
  final HttpClient _http;

  @override
  Future<LlmResult> complete(LlmRequest request) async {
    _ensureConfigured();
    try {
      final HttpClientResponse response = await _open(request, stream: false);
      final String body = await response
          .transform(utf8.decoder)
          .join()
          .timeout(request.timeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw classifyHttpStatus(response.statusCode, body);
      }
      return parseChatCompletion(body);
    } on LlmException {
      rethrow;
    } on TimeoutException {
      throw const LlmException(LlmErrorKind.timeout, '请求超时');
    } on SocketException catch (error) {
      throw LlmException(LlmErrorKind.network, '网络连接失败：${error.message}');
    } on HandshakeException catch (error) {
      throw LlmException(LlmErrorKind.network, 'TLS 握手失败：${error.message}');
    } on HttpException catch (error) {
      throw LlmException(LlmErrorKind.network, 'HTTP 连接失败：${error.message}');
    } on FormatException {
      throw const LlmException(LlmErrorKind.badResponse, '响应不是合法 JSON');
    }
  }

  @override
  Stream<LlmChunk> stream(LlmRequest request) async* {
    _ensureConfigured();
    try {
      HttpClientResponse response = await _open(
        request,
        stream: true,
        includeUsage: request.includeUsage,
        thinkingMode: request.thinkingMode,
      );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final String body = await response.transform(utf8.decoder).join();
        final bool retryWithoutUsage =
            request.includeUsage && _streamOptionsUnsupported(body);
        final bool retryWithoutThinking =
            request.thinkingMode != LlmThinkingMode.defaultMode &&
            _thinkingUnsupported(body);
        if (retryWithoutUsage || retryWithoutThinking) {
          // 老网关不认 stream_options / thinking：去掉它们重试一次，
          // 统计退回"按字符估算"，推理退回模型默认行为。
          response = await _open(
            request,
            stream: true,
            includeUsage: false,
            thinkingMode: LlmThinkingMode.defaultMode,
          );
          if (response.statusCode < 200 || response.statusCode >= 300) {
            final String retryBody = await response
                .transform(utf8.decoder)
                .join();
            throw classifyHttpStatus(response.statusCode, retryBody);
          }
        } else {
          throw classifyHttpStatus(response.statusCode, body);
        }
      }
      final String contentType =
          response.headers.contentType?.mimeType.toLowerCase() ?? '';
      // 有些兼容端点无视 stream=true，直接回一整段 JSON。
      if (contentType.contains('application/json')) {
        final String body = await response
            .transform(utf8.decoder)
            .join()
            .timeout(request.timeout);
        final LlmResult result = parseChatCompletion(body);
        if (result.reasoning.isNotEmpty) {
          yield LlmChunk(reasoning: result.reasoning);
        }
        if (result.text.isNotEmpty) {
          yield LlmChunk(delta: result.text);
        }
        if (result.tokensIn > 0 || result.tokensOut > 0) {
          yield LlmChunk(
            tokensIn: result.tokensIn,
            tokensOut: result.tokensOut,
          );
        }
        yield const LlmChunk(done: true);
        return;
      }

      final SseParser parser = SseParser();
      await for (final String chunk
          in response.transform(utf8.decoder).timeout(request.timeout)) {
        final List<String> events = parser.add(chunk);
        for (final String event in events) {
          final SseDelta delta = _parseDelta(event);
          if (delta.done) {
            yield const LlmChunk(done: true);
            return;
          }
          if (delta.reasoning.isNotEmpty) {
            yield LlmChunk(reasoning: delta.reasoning);
          }
          if (delta.text.isNotEmpty) {
            yield LlmChunk(delta: delta.text);
          }
          if (delta.tokensIn > 0 || delta.tokensOut > 0) {
            yield LlmChunk(
              tokensIn: delta.tokensIn,
              tokensOut: delta.tokensOut,
            );
          }
        }
      }
      for (final String event in parser.flush()) {
        final SseDelta delta = _parseDelta(event);
        if (delta.done) {
          yield const LlmChunk(done: true);
          return;
        }
        if (delta.reasoning.isNotEmpty) {
          yield LlmChunk(reasoning: delta.reasoning);
        }
        if (delta.text.isNotEmpty) {
          yield LlmChunk(delta: delta.text);
        }
        if (delta.tokensIn > 0 || delta.tokensOut > 0) {
          yield LlmChunk(tokensIn: delta.tokensIn, tokensOut: delta.tokensOut);
        }
      }
      yield const LlmChunk(done: true);
    } on LlmException {
      rethrow;
    } on TimeoutException {
      throw const LlmException(LlmErrorKind.timeout, '流式响应超时');
    } on SocketException catch (error) {
      throw LlmException(LlmErrorKind.network, '网络连接失败：${error.message}');
    } on HandshakeException catch (error) {
      throw LlmException(LlmErrorKind.network, 'TLS 握手失败：${error.message}');
    } on HttpException catch (error) {
      throw LlmException(LlmErrorKind.network, 'HTTP 连接失败：${error.message}');
    }
  }

  @override
  Future<bool> healthCheck() async {
    try {
      await complete(
        LlmRequest(
          model: config.model,
          messages: const <LlmMessage>[LlmMessage.user('ping')],
          taskTag: LlmTaskTag.chat,
          temperature: 0,
          maxTokens: 8,
          timeout: _healthTimeout,
        ),
      );
      return true;
    } on Object {
      return false;
    }
  }

  Duration get _healthTimeout {
    const Duration candidate = Duration(seconds: 20);
    return config.timeout < candidate ? config.timeout : candidate;
  }

  Future<HttpClientResponse> _open(
    LlmRequest request, {
    required bool stream,
    bool? includeUsage,
    LlmThinkingMode? thinkingMode,
  }) async {
    final Uri uri = Uri.parse(config.chatCompletionsUrl);
    final HttpClientRequest httpRequest = await _http
        .postUrl(uri)
        .timeout(request.timeout);
    httpRequest.headers
      ..set(HttpHeaders.contentTypeHeader, 'application/json; charset=utf-8')
      ..set(HttpHeaders.authorizationHeader, 'Bearer ${config.apiKey}')
      ..set(
        HttpHeaders.acceptHeader,
        stream ? 'text/event-stream' : 'application/json',
      )
      ..set(HttpHeaders.userAgentHeader, 'SHUAQI/0.1 (+flutter)');
    httpRequest.add(
      utf8.encode(
        jsonEncode(
          buildChatRequestBody(
            request,
            stream: stream,
            includeUsage: includeUsage,
            thinkingMode: thinkingMode,
          ),
        ),
      ),
    );
    return httpRequest.close().timeout(request.timeout);
  }

  void _ensureConfigured() {
    final String? error = config.validationError();
    if (error != null) {
      throw LlmException(LlmErrorKind.notConfigured, error);
    }
  }

  SseDelta _parseDelta(String data) {
    try {
      return parseSseData(data);
    } on FormatException {
      // 单个坏事件不应该打断整段回复：跳过它，下一段继续。
      return const SseDelta();
    }
  }

  bool _streamOptionsUnsupported(String body) {
    final String lower = body.toLowerCase();
    return lower.contains('stream_options') ||
        lower.contains('include_usage') ||
        lower.contains('unknown field') ||
        lower.contains('unrecognized');
  }

  bool _thinkingUnsupported(String body) {
    final String lower = body.toLowerCase();
    return lower.contains('thinking') ||
        lower.contains('reasoning_effort') ||
        lower.contains('unknown field') ||
        lower.contains('unrecognized');
  }

  /// 客户端持有连接池；页面级服务释放时调用。
  void dispose() => _http.close(force: true);
}
