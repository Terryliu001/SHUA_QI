import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:shuaqi/app/app_info.dart';
import 'package:shuaqi/domain/feedback/feedback.dart';

/// 反馈的**自建 HTTP 端点**通道（对应 `server/feedback-worker/` 的 Cloudflare Worker）。
///
/// 2026-10-27 之后默认走 [GitHubFeedbackGateway]；这条留着是因为它更安全
/// （App 里不存任何 GitHub 凭证），之后想换成自己的 Worker 时只要
/// `--dart-define=FEEDBACK_ENDPOINT=...` 即可，客户端不用改。
///
/// 这一层**只负责发**：失败不在这里写本机草稿 —— 反馈在提交前已经由
/// `FeedbackOutbox` 落盘了，再写一次会出现两条重复记录。
///
/// 协议（与 `server/feedback-worker` 对齐）：
/// POST JSON
/// {
///   "kind": "bug", "text": "...", "phone": "...",
///   "app_version": "...", "device": "...",
///   "images": [{"name":"1.png","data":"<base64>"}]
/// }
/// 成功返回 `{ "ok": true, "issue": 12, "url": "..." }`。
class HttpFeedbackGateway implements FeedbackGateway {
  HttpFeedbackGateway({
    required this.endpoint,
    this.token = const String.fromEnvironment('FEEDBACK_APP_TOKEN'),
    this.timeout = const Duration(seconds: 25),
  });

  final String endpoint;

  /// 可选的应用侧共享口令（Worker 配置了 APP_TOKEN 才需要）。
  final String token;

  final Duration timeout;

  @override
  Future<FeedbackReceipt> submit(FeedbackDraft draft) async {
    final Uri? uri = Uri.tryParse(endpoint.trim());
    if (uri == null || !uri.hasScheme) {
      return const FeedbackReceipt(
        delivered: false,
        message: '反馈地址配置不完整',
      );
    }
    final HttpClient client = HttpClient()
      ..connectionTimeout = timeout
      ..idleTimeout = timeout;
    try {
      final HttpClientRequest request = await client
          .postUrl(uri)
          .timeout(timeout);
      request.headers.contentType = ContentType.json;
      if (token.trim().isNotEmpty) {
        request.headers.set('X-App-Token', token.trim());
      }
      request.write(
        jsonEncode(<String, Object?>{
          'kind': draft.kind.name,
          'text': draft.text.trim(),
          'phone': draft.phone.trim(),
          'app_version': draft.appVersion.isEmpty
              ? AppInfo.version
              : draft.appVersion,
          'device': draft.device,
          'images': <Map<String, Object?>>[
            for (int i = 0; i < draft.images.length; i += 1)
              <String, Object?>{
                'name': '${i + 1}.png',
                'data': base64Encode(draft.images[i]),
              },
          ],
        }),
      );
      final HttpClientResponse response = await request.close().timeout(timeout);
      final String body = await response
          .transform(utf8.decoder)
          .join()
          .timeout(timeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return _failed('反馈服务返回 ${response.statusCode}', body);
      }
      Object? decoded;
      try {
        decoded = jsonDecode(body);
      } on Object {
        decoded = null;
      }
      final Map<String, Object?>? map = decoded is Map
          ? decoded.cast<String, Object?>()
          : null;
      if (map?['ok'] != true) {
        return _failed('反馈服务没有确认收到', body);
      }
      final int? issue = switch (map?['issue']) {
        final int value => value,
        final num value => value.toInt(),
        _ => null,
      };
      return FeedbackReceipt(
        delivered: true,
        message: issue == null
            ? '已提交给开发者，修复后会按你留的联系方式回复。'
            : '已提交给开发者（#$issue），修复后会按你留的联系方式回复。',
        issueNumber: issue,
        issueUrl: map?['url'] as String?,
      );
    } on SocketException {
      return const FeedbackReceipt(delivered: false, message: '网络没接通');
    } on TimeoutException {
      return const FeedbackReceipt(delivered: false, message: '提交超时');
    } on Object catch (error) {
      return FeedbackReceipt(delivered: false, message: '网络没有接通（$error）');
    } finally {
      client.close(force: true);
    }
  }

  FeedbackReceipt _failed(String head, String body) {
    String detail = '';
    try {
      final Object? json = jsonDecode(body);
      if (json is Map && json['error'] is String) {
        detail = (json['error'] as String).trim();
      }
    } on Object {
      detail = '';
    }
    return FeedbackReceipt(
      delivered: false,
      message: detail.isEmpty ? head : '$head：$detail',
    );
  }
}
