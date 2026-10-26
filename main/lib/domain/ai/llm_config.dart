/// BYOK 大模型配置（纯 Dart，可单测）。
///
/// 口径（开发指南 07 / T6.1）：
/// - 只支持 **OpenAI 兼容端点**，不绑定厂商；
/// - Key 只存在本机（当前落 `setting` 表，后续可换 Keystore，调用方不用改）；
/// - 端点允许 `http`（局域网自建/中转）与 `https`；不带路径时自动补
///   `/chat/completions`，带 `/v1` 时补 `/v1/chat/completions`。
library;

/// 一条 BYOK 配置。
class LlmConfig {
  const LlmConfig({
    this.baseUrl = '',
    this.apiKey = '',
    this.model = '',
    this.allowImages = true,
    this.timeout = defaultTimeout,
  });

  /// 默认超时。60s 是开发指南的建议值：再长用户会以为卡死。
  static const Duration defaultTimeout = Duration(seconds: 60);

  static const LlmConfig empty = LlmConfig();

  /// 端点根地址，例如 `https://api.deepseek.com/v1`。
  final String baseUrl;

  /// API Key。**不要写进日志/异常信息**。
  final String apiKey;

  /// 模型名，例如 `deepseek-chat` / `qwen-vl-max`。
  final String model;

  /// 是否把题面/作答图片发给模型。默认开：本产品的题面图片是权威来源。
  final bool allowImages;

  final Duration timeout;

  bool get hasBaseUrl => baseUrl.trim().isNotEmpty;

  bool get hasApiKey => apiKey.trim().isNotEmpty;

  bool get hasModel => model.trim().isNotEmpty;

  bool get isConfigured => hasBaseUrl && hasApiKey && hasModel;

  /// 端点是否是一个可用的 http(s) URL。
  bool get hasValidBaseUrl {
    final Uri? uri = Uri.tryParse(baseUrl.trim());
    if (uri == null || !uri.hasAuthority) {
      return false;
    }
    return uri.scheme == 'http' || uri.scheme == 'https';
  }

  /// 给设置页/面板显示的一句话状态。
  String get statusLabel {
    if (!isConfigured) {
      return '未配置';
    }
    return model.trim();
  }

  /// 脱敏后的 Key：只保留末 4 位，给设置页确认"确实存过"。
  String get maskedKey {
    final String key = apiKey.trim();
    if (key.isEmpty) {
      return '未保存';
    }
    if (key.length <= 8) {
      return '••••';
    }
    return '••••${key.substring(key.length - 4)}';
  }

  /// 实际请求地址。
  ///
  /// 规则刻意简单，避免"猜"用户意图：
  /// - 已以 `/chat/completions` 结尾 → 原样；
  /// - 否则去掉末尾 `/` 后补 `/chat/completions`。
  ///   用户若需要 `/v1`，自己写进 baseUrl（大多数厂商文档都是这样给的）。
  String get chatCompletionsUrl {
    final String base = baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
    if (base.isEmpty) {
      return '';
    }
    if (base.endsWith('/chat/completions')) {
      return base;
    }
    return '$base/chat/completions';
  }

  LlmConfig copyWith({
    String? baseUrl,
    String? apiKey,
    String? model,
    bool? allowImages,
    Duration? timeout,
  }) => LlmConfig(
    baseUrl: baseUrl ?? this.baseUrl,
    apiKey: apiKey ?? this.apiKey,
    model: model ?? this.model,
    allowImages: allowImages ?? this.allowImages,
    timeout: timeout ?? this.timeout,
  );

  /// 校验并返回错误文案；null = 可用。
  String? validationError() {
    if (!hasBaseUrl) {
      return '请填写端点地址';
    }
    if (!hasValidBaseUrl) {
      return '端点要以 http:// 或 https:// 开头';
    }
    if (!hasApiKey) {
      return '请填写 API Key';
    }
    if (!hasModel) {
      return '请填写模型名';
    }
    if (timeout.inSeconds < 5 || timeout.inSeconds > 300) {
      return '超时需在 5–300 秒之间';
    }
    return null;
  }

  /// 收紧到合法范围。读旧值时用，避免历史数据把请求挂死。
  LlmConfig normalized() {
    final int seconds = timeout.inSeconds.clamp(5, 300);
    return copyWith(
      baseUrl: baseUrl.trim(),
      apiKey: apiKey.trim(),
      model: model.trim(),
      timeout: Duration(seconds: seconds),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is LlmConfig &&
      other.baseUrl == baseUrl &&
      other.apiKey == apiKey &&
      other.model == model &&
      other.allowImages == allowImages &&
      other.timeout == timeout;

  @override
  int get hashCode => Object.hash(baseUrl, apiKey, model, allowImages, timeout);

  @override
  String toString() =>
      'LlmConfig(baseUrl: $baseUrl, model: $model, '
      'allowImages: $allowImages, timeout: $timeout, key: $maskedKey)';
}
