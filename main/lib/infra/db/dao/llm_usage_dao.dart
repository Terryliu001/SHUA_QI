import 'package:shuaqi/domain/ai/usage.dart';
import 'package:sqflite/sqflite.dart';

/// `llm_usage` 表的读写（v5）。
///
/// 只做"记一行 / 聚合 / 最近 N 条"，不做缓存；调用量很小（每问一次一行）。
class LlmUsageDao {
  const LlmUsageDao(this._db);

  final DatabaseExecutor _db;

  Future<void> add(AiUsageRecord record) async {
    await _db.insert('llm_usage', <String, Object?>{
      'at': record.at,
      'model': record.model,
      'task': record.task,
      'tokens_in': record.tokensIn,
      'tokens_out': record.tokensOut,
      'estimated': record.estimated ? 1 : 0,
      'ok': record.ok ? 1 : 0,
    });
  }

  Future<AiUsageSummary> summary() async {
    final List<Map<String, Object?>> rows = await _db.rawQuery(
      'SELECT COUNT(*) AS calls, '
      'COALESCE(SUM(tokens_in), 0) AS tin, '
      'COALESCE(SUM(tokens_out), 0) AS tout, '
      'COALESCE(SUM(estimated), 0) AS est, '
      'COALESCE(SUM(CASE WHEN ok = 0 THEN 1 ELSE 0 END), 0) AS failed '
      'FROM llm_usage',
    );
    if (rows.isEmpty) {
      return AiUsageSummary.empty;
    }
    final Map<String, Object?> row = rows.first;
    return AiUsageSummary(
      calls: _intOf(row['calls']),
      tokensIn: _intOf(row['tin']),
      tokensOut: _intOf(row['tout']),
      estimatedCalls: _intOf(row['est']),
      failedCalls: _intOf(row['failed']),
    );
  }

  Future<void> clear() async {
    await _db.delete('llm_usage');
  }

  Future<List<AiUsageRecord>> recent({int limit = 20}) async {
    final int safeLimit = limit.clamp(1, 200);
    final List<Map<String, Object?>> rows = await _db.query(
      'llm_usage',
      orderBy: 'at DESC, id DESC',
      limit: safeLimit,
    );
    return <AiUsageRecord>[
      for (final Map<String, Object?> row in rows)
        AiUsageRecord(
          at: _intOf(row['at']),
          model: (row['model'] as String?) ?? '',
          task: (row['task'] as String?) ?? '',
          tokensIn: _intOf(row['tokens_in']),
          tokensOut: _intOf(row['tokens_out']),
          estimated: _intOf(row['estimated']) == 1,
          ok: _intOf(row['ok']) == 1,
        ),
    ];
  }
}

int _intOf(Object? raw) {
  if (raw is int) {
    return raw;
  }
  if (raw is num) {
    return raw.toInt();
  }
  return int.tryParse('$raw') ?? 0;
}
