/// AI token 用量（纯 Dart）。
///
/// 为什么要单独模型：设置页要展示"最近用了多少"，而数据库行是 infra 细节；
/// UI 只认这里的快照。`estimated=true` 表示端点没返回 usage，按字符估算。
library;

class AiUsageRecord {
  const AiUsageRecord({
    required this.at,
    required this.model,
    required this.task,
    required this.tokensIn,
    required this.tokensOut,
    this.estimated = false,
    this.ok = true,
  });

  final int at;
  final String model;

  /// `chat` / `solve` / `grade` / `test`。
  final String task;
  final int tokensIn;
  final int tokensOut;
  final bool estimated;
  final bool ok;

  int get total => tokensIn + tokensOut;
}

class AiUsageSummary {
  const AiUsageSummary({
    this.calls = 0,
    this.tokensIn = 0,
    this.tokensOut = 0,
    this.estimatedCalls = 0,
    this.failedCalls = 0,
  });

  static const AiUsageSummary empty = AiUsageSummary();

  final int calls;
  final int tokensIn;
  final int tokensOut;
  final int estimatedCalls;
  final int failedCalls;

  int get tokens => tokensIn + tokensOut;

  bool get isEmpty => calls == 0;
}

class AiUsageSnapshot {
  const AiUsageSnapshot({
    this.summary = AiUsageSummary.empty,
    this.recent = const <AiUsageRecord>[],
  });

  static const AiUsageSnapshot empty = AiUsageSnapshot();

  final AiUsageSummary summary;
  final List<AiUsageRecord> recent;

  bool get isEmpty => summary.isEmpty && recent.isEmpty;
}
