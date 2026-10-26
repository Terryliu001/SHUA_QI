import 'package:shuaqi/domain/ai/usage.dart';
import 'package:shuaqi/infra/db/dao/llm_usage_dao.dart';

/// AI 用量的读写编排。
///
/// 记账失败绝不能影响回答：所有异常在这里吞掉（最多丢一行统计）。
class AiUsageService {
  const AiUsageService(this._dao, {this.onRecorded});

  final LlmUsageDao _dao;

  /// 记完一笔后通知界面刷新（设置页常驻 IndexedStack，不会自动重建）。
  final void Function()? onRecorded;

  Future<void> record(AiUsageRecord record) async {
    try {
      await _dao.add(record);
      onRecorded?.call();
    } on Object {
      // 统计是旁路，失败不打断对话。
    }
  }

  Future<AiUsageSnapshot> load({int recentLimit = 20}) async {
    try {
      final AiUsageSummary summary = await _dao.summary();
      final List<AiUsageRecord> recent = await _dao.recent(limit: recentLimit);
      return AiUsageSnapshot(summary: summary, recent: recent);
    } on Object {
      return AiUsageSnapshot.empty;
    }
  }

  Future<void> clear() async {
    try {
      await _dao.clear();
      onRecorded?.call();
    } on Object {
      // 清空失败也不影响对话。
    }
  }
}
