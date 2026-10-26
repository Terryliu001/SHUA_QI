import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:shuaqi/app/app_info.dart';
import 'package:shuaqi/app/feedback/local_feedback_gateway.dart';
import 'package:shuaqi/domain/feedback/feedback.dart';
import 'package:shuaqi/infra/vault/vault.dart';

/// 反馈的远端通道（2026-10-26 用户：先做客户端，URL 后补）。
///
/// 端点用编译期注入，代码里不写死：
/// ```
/// flutter build apk --dart-define=FEEDBACK_ENDPOINT=https://xxx.workers.dev
/// ```
/// 没配端点时 `settings_providers` 仍用 [LocalFeedbackGateway]，
/// 界面会明说"通道未接通、只存本机"，不假装成功。
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
    required this.vault,
    this.token = const String.fromEnvironment('FEEDBACK_APP_TOKEN'),
    this.timeout = const Duration(seconds: 25),
  });

  final String endpoint;
  final Vault vault;

  /// 可选的应用侧共享口令（Worker 配置了 APP_TOKEN 才需要）。
  final String token;

  final Duration timeout;

  @override
  Future<FeedbackReceipt> submit(FeedbackDraft draft) async {
    final Uri? uri = Uri.tryParse(endpoint.trim());
    if (uri == null || !uri.hasScheme) {
      return await _fallback(draft, '反馈地址配置不完整');
    }
    final HttpClient client = HttpClient()
      ..connectionTimeout = timeout
      ..idleTimeout = timeout;
    try {
      final HttpClientRequest request = await client.postUrl(uri);
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
        return await _fallback(
          draft,
          '反馈服务返回 ${response.statusCode}',
        );
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
        return await _fallback(draft, '反馈服务没有确认收到');
      }
      final int? issue = (map?['issue'] as num?)?.toInt();
      return FeedbackReceipt(
        delivered: true,
        message: issue == null
            ? '已提交给开发者，修复后会按你留的联系方式回复。'
            : '已提交给开发者（#$issue），修复后会按你留的联系方式回复。',
      );
    } on Object catch (error) {
      return await _fallback(draft, '网络没有接通（$error）');
    } finally {
      client.close(force: true);
    }
  }

  /// 远端失败时**不丢内容**：落本机草稿，并明确告诉用户没发出去。
  Future<FeedbackReceipt> _fallback(FeedbackDraft draft, String why) async {
    try {
      final FeedbackReceipt local = await LocalFeedbackGateway(
        vault: vault,
      ).submit(draft);
      return FeedbackReceipt(
        delivered: false,
        message: '$why；这条已存在本机，不会自动重发。检查网络或地址后再点一次提交。',
        localPath: local.localPath,
      );
    } on Object {
      return FeedbackReceipt(
        delivered: false,
        message: '$why；本机草稿也没能保存，请把内容复制下来再试。',
      );
    }
  }
}
