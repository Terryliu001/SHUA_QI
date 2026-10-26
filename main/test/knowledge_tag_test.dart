import 'package:flutter_test/flutter_test.dart';
import 'package:shuaqi/domain/ai/knowledge_tag.dart';

/// 知识点 AI 归纳的解析（T8.5）。模型很爱加围栏/解释，解析必须宽容但不写脏数据。
void main() {
  test('标准 map 形式', () {
    final Map<String, List<String>>? tags = parseKnowledgeTagResponse(
      '{"tags":{"a":["极限","函数"],"b":["概率"]}}',
    );
    expect(tags, isNotNull);
    expect(tags!['a'], <String>['极限', '函数']);
    expect(tags['b'], <String>['概率']);
  });

  test('markdown 围栏 + 前后解释也能救', () {
    final Map<String, List<String>>? tags = parseKnowledgeTagResponse(
      '好的，结果如下：\n```json\n{"tags":{"a":["导数"]}}\n```\n以上。',
    );
    expect(tags!['a'], <String>['导数']);
  });

  test('list 形式（[{id,tags}]）也认', () {
    final Map<String, List<String>>? tags = parseKnowledgeTagResponse(
      '{"tags":[{"id":"a","tags":["三角函数"]},{"question_id":"b","knowledge_tags":["极限"]}]}',
    );
    expect(tags!['a'], <String>['三角函数']);
    expect(tags['b'], <String>['极限']);
  });

  test('顶层直接 id → 标签（模型省掉 tags 包装）', () {
    final Map<String, List<String>>? tags = parseKnowledgeTagResponse(
      '{"a":["立体几何"],"b":["概率"]}',
    );
    expect(tags!['a'], <String>['立体几何']);
    expect(tags['b'], <String>['概率']);
  });

  test('没有可用标签 → null（上层提示重试，不写半份）', () {
    expect(parseKnowledgeTagResponse('AI 说它不知道'), isNull);
    expect(parseKnowledgeTagResponse('{"tags":{}}'), isNull);
    expect(parseKnowledgeTagResponse('{"tags":{"a":[]}}'), isNull);
    expect(parseKnowledgeTagResponse('{"tags":{"a":["   "]}}'), isNull);
  });

  test('标签规范化：去重 / 去空白 / 截断 20 字 / 最多 5 个', () {
    final Map<String, List<String>>? tags = parseKnowledgeTagResponse(
      '{"tags":{"a":[" 极限 ","极限","一二三四五六七八九十一二三四五六七八九十超出","b","c","d","e"]}}',
    );
    final List<String> got = tags!['a']!;
    expect(got.first, '极限');
    expect(got.where((String t) => t == '极限').length, 1);
    expect(got.length, lessThanOrEqualTo(5));
    expect(got.every((String t) => t.length <= 20), isTrue);
  });

  test('prompt 里带 id 与题干，能按行回填', () {
    final String prompt = knowledgeTagUser(<KnowledgeTagItem>[
      const KnowledgeTagItem(
        id: 'fav1',
        label: '3.',
        workbookTitle: '期中卷',
        kind: 'blank',
        stemText: '求极限 lim x→0',
      ),
      const KnowledgeTagItem(
        id: 'fav2',
        label: '6',
        workbookTitle: '四级卷',
        kind: 'choice',
        stemText: 'Reading comprehension',
      ),
    ]);
    expect(prompt, contains('id=fav1'));
    expect(prompt, contains('id=fav2'));
    expect(prompt, contains('填空题'));
    expect(prompt, contains('求极限'));
    expect(prompt, contains('q1'));
  });

  group('包装形态（用户自接接口最容易踩）', () {
    test('顶层 results 数组', () {
      final Map<String, List<String>>? tags = parseKnowledgeTagResponse(
        '{"results":[{"id":"a","tags":["极限"]},{"id":"b","tags":["概率"]}]}',
      );
      expect(tags!['a'], <String>['极限']);
      expect(tags['b'], <String>['概率']);
    });

    test('整段就是 JSON 数组', () {
      final Map<String, List<String>>? tags = parseKnowledgeTagResponse(
        '[{"id":"a","tags":["导数"]},{"id":"b","tags":["积分"]}]',
      );
      expect(tags!['a'], <String>['导数']);
      expect(tags['b'], <String>['积分']);
    });

    test('favorite_id 作为键', () {
      final Map<String, List<String>>? tags = parseKnowledgeTagResponse(
        '{"tags":[{"favorite_id":"a","knowledge_tags":"极限,函数"}]}',
      );
      expect(tags!['a'], <String>['极限', '函数']);
    });

    test('完全不是 JSON 时按行兜底', () {
      final Map<String, List<String>>? tags = parseKnowledgeTagResponse(
        'q1：极限、函数\n第 2 题: 英语词汇\n3. 概率',
      );
      expect(tags, isNotNull);
      expect(tags!['q1'], <String>['极限', '函数']);
      expect(tags['2'], <String>['英语词汇']);
      expect(tags['3'], <String>['概率']);
    });
  });

  group('键映射：短键 qN / 题号 / 原 id', () {
    const List<KnowledgeTagItem> items = <KnowledgeTagItem>[
      KnowledgeTagItem(
        id: '01ABC',
        label: '3.',
        workbookTitle: '期中卷',
        kind: 'blank',
        ordinal: 3,
      ),
      KnowledgeTagItem(
        id: '01DEF',
        label: '6',
        workbookTitle: '四级卷',
        kind: 'choice',
        ordinal: 6,
      ),
    ];

    test('q1/q2 按顺序映射', () {
      final Map<String, List<String>> resolved = resolveKnowledgeTagKeys(
        <String, List<String>>{
          'q1': <String>['极限'],
          'q2': <String>['英语词汇'],
        },
        items,
      );
      expect(resolved['01ABC'], <String>['极限']);
      expect(resolved['01DEF'], <String>['英语词汇']);
    });

    test('模型写「第 3 题」/「3」也能对上', () {
      expect(
        resolveKnowledgeTagKeys(
          <String, List<String>>{
            '第 3 题': <String>['极限'],
          },
          items,
        )['01ABC'],
        <String>['极限'],
      );
      expect(
        resolveKnowledgeTagKeys(
          <String, List<String>>{
            '6': <String>['英语词汇'],
          },
          items,
        )['01DEF'],
        <String>['英语词汇'],
      );
    });

    test('原 id 原样返回', () {
      expect(
        resolveKnowledgeTagKeys(
          <String, List<String>>{
            '01DEF': <String>['概率'],
          },
          items,
        )['01DEF'],
        <String>['概率'],
      );
    });

    test('对不上的键被丢弃（不写脏数据）', () {
      expect(
        resolveKnowledgeTagKeys(
          <String, List<String>>{
            'unknown': <String>['极限'],
          },
          items,
        ),
        isEmpty,
      );
    });

    test('反向结构「标签 → 题号」也能救', () {
      final Map<String, List<String>> resolved = resolveKnowledgeTagKeys(
        <String, List<String>>{
          '极限': <String>['q1'],
          '英语词汇': <String>['第 6 题'],
        },
        items,
      );
      expect(resolved['01ABC'], <String>['极限']);
      expect(resolved['01DEF'], <String>['英语词汇']);
    });
  });
}
