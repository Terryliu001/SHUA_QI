import 'package:sqflite/sqflite.dart';

/// `ink_state` 表的一行（规格 §5.2）。
///
/// `page_id` 是主键；一张页对应一条状态。`sif_path` 是 Vault 相对路径，
/// 绝对路径只在 [Vault] 里拼。
class InkStateRow {
  const InkStateRow({
    required this.pageId,
    required this.sessionId,
    required this.revision,
    required this.strokeCount,
    required this.byteSize,
    required this.sifPath,
    this.dirty = true,
    this.dirtySince,
  });

  factory InkStateRow.fromRow(Map<String, Object?> row) {
    return InkStateRow(
      pageId: row['page_id']! as String,
      sessionId: row['session_id']! as String,
      revision: (row['revision'] as num?)?.toInt() ?? 0,
      strokeCount: (row['stroke_count'] as num?)?.toInt() ?? 0,
      byteSize: (row['byte_size'] as num?)?.toInt() ?? 0,
      sifPath: row['sif_path']! as String,
      dirty: (row['dirty'] as num?)?.toInt() != 0,
      dirtySince: (row['dirty_since'] as num?)?.toInt(),
    );
  }

  final String pageId;
  final String sessionId;
  final int revision;
  final int strokeCount;
  final int byteSize;
  final String sifPath;
  final bool dirty;
  final int? dirtySince;
}

/// `ink_state` 读写（T2.4）。
///
/// 写入策略：`INSERT ... ON CONFLICT(page_id) DO UPDATE`。**不删旧行再插**——
/// 删除会触发外键/索引动作，且在事务外有"两次操作之间被杀"的窗口。
/// 本周 `dirty` 恒为 1（识别还没接），第 4 周清 0。
class InkStateDao {
  const InkStateDao(this._db);

  final DatabaseExecutor _db;

  /// 某页在指定会话下的状态。没有返回 null（还没写过）。
  Future<InkStateRow?> find(String pageId, String sessionId) async {
    final List<Map<String, Object?>> rows = await _db.query(
      'ink_state',
      where: 'page_id = ? AND session_id = ?',
      whereArgs: <Object?>[pageId, sessionId],
      limit: 1,
    );
    if (rows.isEmpty) {
      return null;
    }
    return InkStateRow.fromRow(rows.first);
  }

  Future<InkStateRow?> byPage(String pageId) async {
    final List<Map<String, Object?>> rows = await _db.query(
      'ink_state',
      where: 'page_id = ?',
      whereArgs: <Object?>[pageId],
      limit: 1,
    );
    if (rows.isEmpty) {
      return null;
    }
    return InkStateRow.fromRow(rows.first);
  }

  /// 写入/更新一页的状态。返回落库后的 revision。
  Future<int> upsert({
    required String pageId,
    required String sessionId,
    required int revision,
    required int strokeCount,
    required int byteSize,
    required String sifPath,
    required int nowUtcMillis,
  }) async {
    await _db.rawInsert(
      '''
INSERT INTO ink_state(
  page_id, session_id, revision, stroke_count, byte_size, dirty,
  last_ocr_at, sif_path, dirty_since
) VALUES(?, ?, ?, ?, ?, 1, NULL, ?, ?)
ON CONFLICT(page_id) DO UPDATE SET
  session_id = excluded.session_id,
  revision = excluded.revision,
  stroke_count = excluded.stroke_count,
  byte_size = excluded.byte_size,
  dirty = 1,
  sif_path = excluded.sif_path,
  dirty_since = excluded.dirty_since
''',
      <Object?>[
        pageId,
        sessionId,
        revision,
        strokeCount,
        byteSize,
        sifPath,
        nowUtcMillis,
      ],
    );
    return revision;
  }
}
