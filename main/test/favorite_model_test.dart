import 'package:flutter_test/flutter_test.dart';
import 'package:shuaqi/domain/model/favorite.dart';
import 'package:shuaqi/domain/model/grading.dart';
import 'package:shuaqi/domain/region/region_rect.dart';

void main() {
  test('Favorite toRow → fromRow 往返一致', () {
    const Favorite favorite = Favorite(
      id: '01J0ABCDEFGHJKMNPRSTVWXYZ',
      questionId: 'q1',
      workbookId: 'wb1',
      workbookTitle: '期中数学',
      label: '12.',
      ordinal: 12,
      kind: 'choice',
      stemText: '设 x=2，求 x+1。',
      pageIndex: 3,
      rect: RegionRect(left: 10, top: 20, width: 300, height: 80),
      knowledgeTags: <String>['三角函数', '导数'],
      verdict: AnswerVerdict.correct,
      sourceDeleted: true,
      createdAt: 1700000000000,
      updatedAt: 1700000001000,
    );

    final Favorite restored = Favorite.fromRow(favorite.toRow());

    expect(restored.id, favorite.id);
    expect(restored.questionId, 'q1');
    expect(restored.workbookTitle, '期中数学');
    expect(restored.label, '12.');
    expect(restored.ordinal, 12);
    expect(restored.kind, 'choice');
    expect(restored.stemText, '设 x=2，求 x+1。');
    expect(restored.pageIndex, 3);
    expect(restored.rect, const RegionRect(left: 10, top: 20, width: 300, height: 80));
    expect(restored.knowledgeTags, <String>['三角函数', '导数']);
    expect(restored.verdict, AnswerVerdict.correct);
    expect(restored.sourceDeleted, isTrue);
    expect(restored.createdAt, 1700000000000);
    expect(restored.updatedAt, 1700000001000);
  });

  test('rect 为空或缺字段时回落 RegionRect.empty', () {
    final Favorite restored = Favorite.fromRow(<String, Object?>{
      'id': 'x',
      'question_id': '',
      'workbook_id': '',
      'workbook_title': '',
      'label': '',
      'ordinal': 0,
      'kind': 'unknown',
      'stem_text': '',
      'page_index': 0,
      'rect': '',
      'knowledge_tags': '',
      'verdict': 'none',
      'source_deleted': 0,
      'created_at': 1,
      'updated_at': 1,
    });
    expect(restored.rect, RegionRect.empty);
    expect(restored.verdict, AnswerVerdict.none);
    expect(restored.sourceDeleted, isFalse);
  });

  test('KnowledgeTags.parse：中英文逗号分隔、去重、截断', () {
    expect(KnowledgeTags.parse('三角函数，导数、积分'), <String>['三角函数', '导数', '积分']);
    expect(KnowledgeTags.parse(' 导数 , 导数 , 函数 '), <String>['导数', '函数']);
    expect(
      KnowledgeTags.parse('一二三四五六七八九十一二三四五六七八九十X'),
      <String>['一二三四五六七八九十一二三四五六七八九十'],
    );
  });

  test('KnowledgeTags.parse：最多 5 个', () {
    expect(
      KnowledgeTags.parse('a,b,c,d,e,f,g'),
      <String>['a', 'b', 'c', 'd', 'e'],
    );
  });

  test('KnowledgeTags.encode/decode 往返一致', () {
    const List<String> tags = <String>['三角函数', '导数应用'];
    expect(KnowledgeTags.decode(KnowledgeTags.encode(tags)), tags);
    expect(KnowledgeTags.decode(null), isEmpty);
    expect(KnowledgeTags.decode(''), isEmpty);
  });

  test('AnswerVerdict.decode 未知值回落 none', () {
    expect(AnswerVerdict.decode('correct'), AnswerVerdict.correct);
    expect(AnswerVerdict.decode('wrong'), AnswerVerdict.wrong);
    expect(AnswerVerdict.decode('pending'), AnswerVerdict.pending);
    expect(AnswerVerdict.decode('bogus'), AnswerVerdict.none);
    expect(AnswerVerdict.decode(null), AnswerVerdict.none);
  });
}
