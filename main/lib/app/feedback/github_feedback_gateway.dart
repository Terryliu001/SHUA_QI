import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:shuaqi/app/app_info.dart';
import 'package:shuaqi/domain/feedback/feedback.dart';
import 'package:shuaqi/domain/util/ulid.dart';

/// 反馈的 GitHub 私有仓库通道（2026-10-27 用户选定）。
///
/// 为什么直连 GitHub 而不需要自建服务器：
/// - 反馈量小（内测），一个私有仓库的 issue 就是最好用的收件箱；
/// - 手机号只出现在**私有** issue 里，不会进公开仓库；
/// - 截图走仓库 Contents API 落到 `feedback/<id>/`，issue 里给链接。
///
/// 安全边界（写在最前面，别忘）：
/// - token 由 `--dart-define=FEEDBACK_GH_TOKEN=...` 注入，不进 git；
/// - **必须是只对该私有仓库** `Issues: RW` + `Contents: RW` 的细粒度 token，
///   不能用账号主 token；泄露只会影响这个仓库，可随时吊销；
/// - 这里只 POST/PUT 两个端点，不读、不列、不删仓库里的任何东西。
///
/// 幂等性：
/// - 图片路径用**提交 id**（重试复用），重复上传返回 422 视为"已存在"；
/// - issue 只有在拿到 2xx 后才算送达。极端情况下（issue 已建成但响应丢失）
///   重试可能产生一条重复 issue —— 宁可重复也不丢用户的反馈。
class GitHubFeedbackGateway implements FeedbackGateway {
  GitHubFeedbackGateway({
    required this.token,
    required this.owner,
    required this.repo,
    this.branch = 'main',
    this.apiBase = 'https://api.github.com',
    this.timeout = const Duration(seconds: 30),
  });

  final String token;
  final String owner;
  final String repo;
  final String branch;
  final String apiBase;
  final Duration timeout;

  @override
  Future<FeedbackReceipt> submit(FeedbackDraft draft) async {
    final String id = draft.submissionId.trim().isEmpty
        ? Ulid.next()
        : draft.submissionId.trim();

    // ① 先传图：issue 建出来时图片链接必须已经能点开。
    final List<String> imagePaths = <String>[];
    for (int i = 0; i < draft.images.length; i += 1) {
      final String path = 'feedback/$id/${i + 1}.png';
      final _ApiResult uploaded = await _put(
        '/repos/$owner/$repo/contents/$path',
        <String, Object?>{
          'message': 'feedback: $id image ${i + 1}',
          'content': base64Encode(draft.images[i]),
          'branch': branch,
        },
      );
      // 201 = 新建；422 = 这个文件已经在了（重试），都算成功。
      if (uploaded.status != 201 && uploaded.status != 200 && uploaded.status != 422) {
        return _fail('截图上传失败（${uploaded.status}）', uploaded);
      }
      imagePaths.add(path);
    }

    // ② 建 issue（手机号只进私有仓库）。
    final _ApiResult created = await _post(
      '/repos/$owner/$repo/issues',
      <String, Object?>{
        'title': _issueTitle(draft),
        'body': _issueBody(draft, id, imagePaths),
      },
    );
    if (created.status < 200 || created.status >= 300) {
      return _fail('反馈没有送达（${created.status}）', created);
    }
    final int? number = switch (created.json?['number']) {
      final int value => value,
      final num value => value.toInt(),
      _ => null,
    };
    final String? url = created.json?['html_url'] as String?;
    return FeedbackReceipt(
      delivered: true,
      message: number == null
          ? '已提交给开发者，修复后会按你留的联系方式回复。'
          : '已提交给开发者（#$number），修复后会按你留的联系方式回复。',
      issueNumber: number,
      issueUrl: url,
    );
  }

  String _issueTitle(FeedbackDraft draft) {
    final String head = draft.text.replaceAll(RegExp(r'\s+'), ' ').trim();
    final String short = head.length <= 40 ? head : '${head.substring(0, 40)}…';
    return '[反馈·${draft.kind.label}] $short';
  }

  String _issueBody(FeedbackDraft draft, String id, List<String> imagePaths) {
    final String version = draft.appVersion.trim().isEmpty
        ? AppInfo.version
        : draft.appVersion.trim();
    final String device = draft.device.trim().isEmpty ? '未知' : draft.device.trim();
    final String phone = draft.phone.trim().isEmpty ? '未填写' : draft.phone.trim();
    final StringBuffer body = StringBuffer()
      ..writeln('**类型**：${draft.kind.label}（${draft.kind.name}）')
      ..writeln()
      ..writeln('**说明**：')
      ..writeln(draft.text.trim())
      ..writeln()
      ..writeln('**App 版本**：$version')
      ..writeln('**设备**：$device')
      ..writeln('**手机号**：$phone')
      ..writeln('**反馈 id**：$id');
    if (imagePaths.isNotEmpty) {
      body
        ..writeln()
        ..writeln('**截图**：');
      for (int i = 0; i < imagePaths.length; i += 1) {
        body.writeln(
          '- [截图 ${i + 1}]'
          '(https://github.com/$owner/$repo/blob/$branch/${imagePaths[i]})',
        );
      }
    }
    // 机器可读的标记，方便以后按 id 去重/检索。
    body
      ..writeln()
      ..writeln('<!-- shuaqi-feedback:$id -->');
    return body.toString();
  }

  FeedbackReceipt _fail(String head, _ApiResult result) {
    if (result.networkDown) {
      return const FeedbackReceipt(
        delivered: false,
        message: '网络没接通；这条已存在本机，联网后可重试',
      );
    }
    final String detail = _shortError(result);
    return FeedbackReceipt(
      delivered: false,
      message: detail.isEmpty ? head : '$head：$detail',
    );
  }

  String _shortError(_ApiResult result) {
    final Object? message = result.json?['message'];
    if (message is String && message.trim().isNotEmpty) {
      return message.trim();
    }
    if (result.status == 401) {
      return '反馈通道凭证无效';
    }
    if (result.status == 403) {
      return '反馈通道被拒绝（可能是权限不足或触发限流）';
    }
    if (result.status == 404) {
      return '反馈仓库不存在，或凭证没有访问权限';
    }
    return '';
  }

  Future<_ApiResult> _put(String path, Map<String, Object?> body) {
    return _request('PUT', path, body);
  }

  Future<_ApiResult> _post(String path, Map<String, Object?> body) {
    return _request('POST', path, body);
  }

  Future<_ApiResult> _request(
    String method,
    String path,
    Map<String, Object?> body,
  ) async {
    final HttpClient client = HttpClient()
      ..connectionTimeout = timeout
      ..idleTimeout = timeout;
    try {
      final Uri uri = Uri.parse('$apiBase$path');
      final HttpClientRequest request = await client
          .openUrl(method, uri)
          .timeout(timeout);
      request.headers.contentType = ContentType.json;
      request.headers.set('Accept', 'application/vnd.github+json');
      request.headers.set('X-GitHub-Api-Version', '2022-11-28');
      request.headers.set('User-Agent', 'shuaqi-app');
      request.headers.set('Authorization', 'Bearer $token');
      request.write(jsonEncode(body));
      final HttpClientResponse response = await request.close().timeout(timeout);
      final String text = await response
          .transform(utf8.decoder)
          .join()
          .timeout(timeout);
      Map<String, Object?>? decoded;
      if (text.isNotEmpty) {
        try {
          final Object? json = jsonDecode(text);
          if (json is Map) {
            decoded = json.cast<String, Object?>();
          }
        } on Object {
          decoded = null;
        }
      }
      return _ApiResult(status: response.statusCode, json: decoded);
    } on SocketException {
      return const _ApiResult(status: 0, json: null, networkDown: true);
    } on TimeoutException {
      return const _ApiResult(status: 0, json: null, networkDown: true);
    } finally {
      client.close(force: true);
    }
  }
}

class _ApiResult {
  const _ApiResult({
    required this.status,
    required this.json,
    this.networkDown = false,
  });

  final int status;
  final Map<String, Object?>? json;
  final bool networkDown;
}
