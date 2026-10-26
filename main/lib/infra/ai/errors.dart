/// 大模型客户端的错误分类（规格 §6.6 / 开发指南 07）。
///
/// 只有 infra 层知道 HTTP 细节；`app/ai` 把它翻译成给用户看的中文
/// [AiFailure]，UI 不 import 这个文件。
library;

enum LlmErrorKind {
  notConfigured,
  auth,
  rateLimited,
  network,
  server,
  timeout,
  badResponse,
  unsupportedImage,
}

class LlmException implements Exception {
  const LlmException(this.kind, this.message, {this.statusCode, this.body});

  final LlmErrorKind kind;

  /// 给开发者看的短说明。**不得包含 API Key**。
  final String message;

  final int? statusCode;

  /// 服务端原始响应（截断到 600 字以内，便于定位；调用方不要把整段弹给用户）。
  final String? body;

  @override
  String toString() {
    final String code = statusCode == null ? '' : ' HTTP $statusCode';
    return 'LlmException(${kind.name})$code: $message';
  }
}
