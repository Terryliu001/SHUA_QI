import 'package:flutter_test/flutter_test.dart';
import 'package:shuaqi/domain/ink/ink_session_id.dart';
import 'package:shuaqi/domain/records/answer_log.dart';

/// 「这一笔算不算某道题的作答」——落笔记录的唯一判据。
///
/// 打点在 `InkEditController._scheduleSave`（答题卡每一笔都经过它），
/// 但**判据**抽在这里：它决定热力图上的数字是真是假，必须能单测。
void main() {
  group('作答归属判定', () {
    test('答题卡上有笔迹 → 归属这道题', () {
      expect(
        answerQuestionIdOf(
          sessionId: 'ans:s1:q7',
          workbookId: 'wb1',
          strokeCount: 3,
        ),
        'q7',
      );
    });

    test('没有笔迹（清空/新画布）不算', () {
      expect(
        answerQuestionIdOf(
          sessionId: 'ans:s1:q7',
          workbookId: 'wb1',
          strokeCount: 0,
        ),
        isNull,
      );
    });

    test('没有卷 id（宿主测试的裸编辑器）不算', () {
      expect(
        answerQuestionIdOf(
          sessionId: 'ans:s1:q7',
          workbookId: '',
          strokeCount: 3,
        ),
        isNull,
      );
    });

    test('PDF 页笔迹不算（页上的墨迹不归属某道题）', () {
      expect(
        answerQuestionIdOf(
          sessionId: '06GQ5BAE3BYGB8KSPD586DGZSW',
          workbookId: 'wb1',
          strokeCount: 5,
        ),
        isNull,
      );
    });

    test('收藏二刷不算（它的来源卷/题要从收藏表查，不是 ans 格式）', () {
      expect(
        answerQuestionIdOf(
          sessionId: 'fav:fav-1',
          workbookId: 'wb1',
          strokeCount: 5,
        ),
        isNull,
      );
    });
  });

  group('session 编码', () {
    test('答题卡往返', () {
      final String id = answerInkSessionId('s1', 'q1');
      expect(id, 'ans:s1:q1');
      expect(parseAnswerInkSession(id)?.sessionId, 's1');
      expect(parseAnswerInkSession(id)?.questionId, 'q1');
    });

    test('不是答题卡格式一律 null', () {
      expect(parseAnswerInkSession('ans:s1'), isNull);
      expect(parseAnswerInkSession('ans::q1'), isNull);
      expect(parseAnswerInkSession('ans:s1:'), isNull);
      expect(parseAnswerInkSession('ans:s1:q1:extra'), isNull);
      expect(parseAnswerInkSession('fav:fav-1'), isNull);
    });

    test('收藏二刷往返，且不与答题卡混淆', () {
      expect(favoriteRedoSessionId('fav-1'), 'fav:fav-1');
      expect(parseFavoriteRedoSession('fav:fav-1'), 'fav-1');
      expect(parseFavoriteRedoSession('fav:'), isNull);
      expect(parseFavoriteRedoSession('ans:s1:q1'), isNull);
    });
  });

  group('去重键', () {
    test('同一天同一题 → 同一个键（不管几点）', () {
      final int morning = DateTime(2026, 10, 25, 8, 30).millisecondsSinceEpoch;
      final int night = DateTime(2026, 10, 25, 23, 59).millisecondsSinceEpoch;
      expect(answerRecordKeyOf('q1', morning), answerRecordKeyOf('q1', night));
    });

    test('跨天换键（第二天要重新记一次）', () {
      final int today = DateTime(2026, 10, 25, 22, 0).millisecondsSinceEpoch;
      final int tomorrow = DateTime(2026, 10, 26, 0, 10).millisecondsSinceEpoch;
      expect(
        answerRecordKeyOf('q1', today),
        isNot(answerRecordKeyOf('q1', tomorrow)),
      );
    });

    test('不同题目不互相去重', () {
      final int at = DateTime(2026, 10, 25, 12).millisecondsSinceEpoch;
      expect(answerRecordKeyOf('q1', at), isNot(answerRecordKeyOf('q2', at)));
    });
  });
}
