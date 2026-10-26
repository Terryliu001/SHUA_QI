import 'package:flutter_test/flutter_test.dart';
import 'package:shuaqi/domain/model/favorite.dart';
import 'package:shuaqi/domain/model/favorite_group.dart';
import 'package:shuaqi/domain/model/grading.dart';
import 'package:shuaqi/domain/region/region_rect.dart';

Favorite _f({
  required String id,
  required String workbookId,
  required String workbookTitle,
  required String label,
  required int updatedAt,
  List<String> tags = const <String>[],
  String stemText = '',
}) => Favorite(
  id: id,
  questionId: 'q$id',
  workbookId: workbookId,
  workbookTitle: workbookTitle,
  label: label,
  ordinal: 0,
  kind: 'unknown',
  stemText: stemText,
  pageIndex: 0,
  rect: RegionRect.empty,
  knowledgeTags: tags,
  verdict: AnswerVerdict.none,
  sourceDeleted: false,
  createdAt: updatedAt,
  updatedAt: updatedAt,
);

void main() {
  group('groupByWorkbook', () {
    test('按卷分组，组序按组内最新 updatedAt 倒序，组内也倒序', () {
      final List<Favorite> input = <Favorite>[
        _f(id: 'a', workbookId: 'w1', workbookTitle: '卷A', label: '2.', updatedAt: 5),
        _f(id: 'b', workbookId: 'w2', workbookTitle: '卷B', label: '1.', updatedAt: 4),
        _f(id: 'c', workbookId: 'w1', workbookTitle: '卷A', label: '1.', updatedAt: 3),
      ];
      final List<FavoriteGroup> groups = groupByWorkbook(input);
      expect(groups.map((FavoriteGroup g) => g.title).toList(), <String>['卷A', '卷B']);
      expect(groups[0].items.map((Favorite f) => f.label).toList(), <String>['2.', '1.']);
      expect(groups[1].items.map((Favorite f) => f.label).toList(), <String>['1.']);
    });

    test('空列表返回空分组', () {
      expect(groupByWorkbook(<Favorite>[]), isEmpty);
    });
  });

  group('groupByKnowledge', () {
    test('按标签分组，一题多标签时在每个组都出现', () {
      final List<Favorite> input = <Favorite>[
        _f(id: 'a', workbookId: 'w1', workbookTitle: '卷A', label: '1.', updatedAt: 3, tags: <String>['三角函数', '导数']),
        _f(id: 'b', workbookId: 'w1', workbookTitle: '卷A', label: '2.', updatedAt: 2, tags: <String>['导数']),
      ];
      final List<FavoriteGroup> groups = groupByKnowledge(input);
      final Map<String, List<String>> byTitle = <String, List<String>>{
        for (final FavoriteGroup g in groups) g.title: g.items.map((Favorite f) => f.label).toList(),
      };
      expect(byTitle['三角函数'], <String>['1.']);
      expect(byTitle['导数'], <String>['1.', '2.']);
    });

    test('无标签的题进「未归纳」组且排最后', () {
      final List<Favorite> input = <Favorite>[
        _f(id: 'a', workbookId: 'w1', workbookTitle: '卷A', label: '1.', updatedAt: 3, tags: <String>['导数']),
        _f(id: 'b', workbookId: 'w1', workbookTitle: '卷A', label: '2.', updatedAt: 2),
      ];
      final List<FavoriteGroup> groups = groupByKnowledge(input);
      expect(groups.last.title, kUnfiledGroupTitle);
      expect(groups.last.items.map((Favorite f) => f.label).toList(), <String>['2.']);
    });

    test('全部未归纳时只有「未归纳」一组', () {
      final List<Favorite> input = <Favorite>[
        _f(id: 'a', workbookId: 'w1', workbookTitle: '卷A', label: '1.', updatedAt: 1),
      ];
      final List<FavoriteGroup> groups = groupByKnowledge(input);
      expect(groups.length, 1);
      expect(groups.single.title, kUnfiledGroupTitle);
    });
  });

  group('searchFavorites', () {
    final List<Favorite> input = <Favorite>[
      _f(id: 'a', workbookId: 'w1', workbookTitle: '期中数学', label: '12.', updatedAt: 2, tags: <String>['三角函数'], stemText: '求 sin 值'),
      _f(id: 'b', workbookId: 'w2', workbookTitle: '四级英语', label: '3.', updatedAt: 1, stemText: 'translate'),
    ];

    test('空查询原样返回', () {
      expect(searchFavorites(input, '  '), input);
    });

    test('按卷名匹配', () {
      expect(searchFavorites(input, '四级').map((Favorite f) => f.id), <String>['b']);
    });

    test('按题干匹配（忽略大小写）', () {
      expect(searchFavorites(input, 'SIN').map((Favorite f) => f.id), <String>['a']);
    });

    test('按知识点匹配', () {
      expect(searchFavorites(input, '三角').map((Favorite f) => f.id), <String>['a']);
    });

    test('无命中返回空', () {
      expect(searchFavorites(input, '不存在的词'), isEmpty);
    });
  });

  group('filterByTag / distinctKnowledgeTags / hasUnfiled', () {
    final List<Favorite> input = <Favorite>[
      _f(id: 'a', workbookId: 'w1', workbookTitle: '卷A', label: '1.', updatedAt: 3, tags: <String>['三角函数', '导数']),
      _f(id: 'b', workbookId: 'w1', workbookTitle: '卷A', label: '2.', updatedAt: 2, tags: <String>['导数']),
      _f(id: 'c', workbookId: 'w1', workbookTitle: '卷A', label: '3.', updatedAt: 1),
    ];

    test('null 不过滤', () {
      expect(filterByTag(input, null), input);
    });

    test('按具体标签筛选', () {
      expect(
        filterByTag(input, '三角函数').map((Favorite f) => f.id),
        <String>['a'],
      );
    });

    test('未归纳筛选', () {
      expect(
        filterByTag(input, kUnfiledGroupKey).map((Favorite f) => f.id),
        <String>['c'],
      );
    });

    test('distinctKnowledgeTags 去重保序', () {
      expect(distinctKnowledgeTags(input), <String>['三角函数', '导数']);
    });

    test('hasUnfiled 判断', () {
      expect(hasUnfiled(input), isTrue);
      expect(
        hasUnfiled(<Favorite>[
          _f(id: 'a', workbookId: 'w1', workbookTitle: '卷A', label: '1.', updatedAt: 1, tags: <String>['x']),
        ]),
        isFalse,
      );
    });
  });
}
