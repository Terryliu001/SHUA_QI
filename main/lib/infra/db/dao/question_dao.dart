import 'package:shuaqi/domain/model/question.dart';
import 'package:shuaqi/domain/region/region_rect.dart';
import 'package:sqflite/sqflite.dart';

/// `question` 与 `question_region` 两张表的读写（T3.x）。
///
/// 写入策略：**整卷替换**。切题是"整份重算"，逐条 diff 只会让状态更难推理；
/// 替换放在一个事务里，失败整份回滚——不会出现"题目表更新了、区域表没更新"。
///
/// 窗口期：`DELETE` 与 `INSERT` 之间数据是空的，但都在事务内，其他连接看不到。
class QuestionDao {
  const QuestionDao(this._db);

  final DatabaseExecutor _db;

  /// 用新结果整体替换一卷的题目与区域。
  Future<void> replaceForWorkbook({
    required String workbookId,
    required List<Question> questions,
    required List<QuestionRegion> regions,
  }) async {
    await _db.delete(
      'question',
      where: 'workbook_id = ?',
      whereArgs: <Object?>[workbookId],
    );
    if (questions.isNotEmpty) {
      final Batch batch = _db.batch();
      for (final Question question in questions) {
        batch.insert('question', question.toRow());
      }
      await batch.commit(noResult: true);
    }
    if (regions.isNotEmpty) {
      final Batch batch = _db.batch();
      for (final QuestionRegion region in regions) {
        batch.insert('question_region', region.toRow());
      }
      await batch.commit(noResult: true);
    }
  }

  /// 整卷读出（含跨页分段）。
  ///
  /// 一次 JOIN 取完，不做 N+1：20 页卷大约 60 道题，一次查询就够；
  /// N+1 在真机上会因为 sqlite 平台通道往返变成几十毫秒。
  Future<List<QuestionBundle>> loadBundle(String workbookId) async {
    final List<Map<String, Object?>> rows = await _db.rawQuery(
      '''
SELECT
  q.id AS q_id, q.workbook_id, q.ordinal, q.label, q.level, q.parent_id,
  q.kind, q.stem_text, q.confidence AS q_conf, q.source,
  r.id AS r_id, r.page_id, r.x, r.y, r.w, r.h, r.role,
  r.confidence AS r_conf, r.locked,
  p.idx AS page_idx
FROM question q
LEFT JOIN question_region r ON r.question_id = q.id
LEFT JOIN wb_page p ON p.id = r.page_id
WHERE q.workbook_id = ?
ORDER BY q.ordinal ASC, p.idx ASC, r.y ASC
''',
      <Object?>[workbookId],
    );

    final Map<String, Question> questions = <String, Question>{};
    final Map<String, List<QuestionSlice>> slices =
        <String, List<QuestionSlice>>{};
    final Set<String> lockedIds = <String>{};
    for (final Map<String, Object?> row in rows) {
      final String id = row['q_id']! as String;
      questions.putIfAbsent(
        id,
        () => Question.fromRow(<String, Object?>{
          'id': id,
          'workbook_id': row['workbook_id'],
          'ordinal': row['ordinal'],
          'label': row['label'],
          'level': row['level'],
          'parent_id': row['parent_id'],
          'kind': row['kind'],
          'stem_text': row['stem_text'],
          'confidence': row['q_conf'],
          'source': row['source'],
        }),
      );
      final String? regionId = row['r_id'] as String?;
      if (regionId == null || row['page_idx'] == null) {
        continue;
      }
      if (((row['locked'] as num?)?.toInt() ?? 0) != 0) {
        lockedIds.add(id);
      }
      slices
          .putIfAbsent(id, () => <QuestionSlice>[])
          .add(
            QuestionSlice(
              pageIndex: (row['page_idx']! as num).toInt(),
              pageId: row['page_id']! as String,
              rect: RegionRect.fromLTRB(
                (row['x']! as num).toDouble(),
                (row['y']! as num).toDouble(),
                (row['x']! as num).toDouble() + (row['w']! as num).toDouble(),
                (row['y']! as num).toDouble() + (row['h']! as num).toDouble(),
              ),
            ),
          );
    }
    return <QuestionBundle>[
      for (final Question question in questions.values)
        QuestionBundle(
          question: question,
          slices: slices[question.id] ?? const <QuestionSlice>[],
          locked: lockedIds.contains(question.id),
        ),
    ];
  }

  Future<int> countOf(String workbookId) async {
    final List<Map<String, Object?>> rows = await _db.rawQuery(
      'SELECT COUNT(*) AS c FROM question WHERE workbook_id = ?',
      <Object?>[workbookId],
    );
    return (rows.first['c'] as num?)?.toInt() ?? 0;
  }
}
