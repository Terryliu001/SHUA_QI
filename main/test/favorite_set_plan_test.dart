import 'package:flutter_test/flutter_test.dart';
import 'package:shuaqi/domain/model/favorite.dart';
import 'package:shuaqi/domain/model/favorite_set_plan.dart';

/// 组卷成员编排与文案（T8.4）。纯函数，不碰 DB/文件。
void main() {
  FavoriteSet set(String id, String name) => FavoriteSet(
    id: id,
    name: name,
    createdAt: 1,
    updatedAt: 1,
    itemCount: 2,
  );
  group('planSetAppend', () {
    test('空卷加入：按传入顺序', () {
      expect(
        planSetAppend(existing: <String>[], incoming: <String>['a', 'b', 'c']),
        <String>['a', 'b', 'c'],
      );
    });

    test('已有序原样保留，新成员追加在后', () {
      expect(
        planSetAppend(existing: <String>['a', 'c'], incoming: <String>['b']),
        <String>['a', 'c', 'b'],
      );
    });

    test('重复加入不改变顺序、不产生重复', () {
      expect(
        planSetAppend(
          existing: <String>['a', 'b'],
          incoming: <String>['b', 'a', 'b'],
        ),
        <String>['a', 'b'],
      );
    });

    test('一次批量里的重复只留第一次', () {
      expect(
        planSetAppend(
          existing: <String>[],
          incoming: <String>['x', 'y', 'x'],
        ),
        <String>['x', 'y'],
      );
    });

    test('空 id 被忽略（UI 兜底，不该进卷）', () {
      expect(
        planSetAppend(existing: <String>[], incoming: <String>['', 'a', '']),
        <String>['a'],
      );
    });
  });

  test('countSetAdded 只算真正新增', () {
    expect(
      countSetAdded(
        existing: <String>['a', 'b'],
        incoming: <String>['b', 'c'],
      ),
      1,
    );
    expect(
      countSetAdded(existing: <String>['a'], incoming: <String>['a']),
      0,
    );
  });

  group('planSetRemove', () {
    test('移除单个，其余顺序不变', () {
      expect(
        planSetRemove(
          existing: <String>['a', 'b', 'c'],
          removing: <String>['b'],
        ),
        <String>['a', 'c'],
      );
    });

    test('移除不存在的 id 不多删', () {
      expect(
        planSetRemove(
          existing: <String>['a', 'b'],
          removing: <String>['zzz'],
        ),
        <String>['a', 'b'],
      );
    });
  });

  group('redoProgressLabel', () {
    test('正常进度', () {
      expect(redoProgressLabel(index: 0, total: 8), '第 1 / 8 题');
      expect(redoProgressLabel(index: 7, total: 8), '第 8 / 8 题');
    });

    test('空卷不出现 0/0 之外的花样', () {
      expect(redoProgressLabel(index: 0, total: 0), '第 0 / 0 题');
    });

    test('越界收进范围（删成员后索引滞后）', () {
      expect(redoProgressLabel(index: 9, total: 3), '第 3 / 3 题');
      expect(redoProgressLabel(index: -2, total: 3), '第 1 / 3 题');
    });
  });

  group('setSubtitle / relativeDay', () {
    const int minute = 60 * 1000;
    const int hour = 60 * minute;
    const int day = 24 * hour;
    final int now = DateTime.utc(2026, 10, 25, 12).millisecondsSinceEpoch;

    test('刚刚 / 分钟 / 小时 / 天', () {
      expect(relativeDay(now - 10 * 1000, now), '刚刚');
      expect(relativeDay(now - 5 * minute, now), '5 分钟前');
      expect(relativeDay(now - 3 * hour, now), '3 小时前');
      expect(relativeDay(now - 2 * day, now), '2 天前');
    });

    test('未来时间也兜成刚刚（设备时区错也不显示 -3 天）', () {
      expect(relativeDay(now + day, now), '刚刚');
    });

    test('setSubtitle 带题数与更新时间', () {
      expect(
        setSubtitle(itemCount: 8, updatedAtMs: now - day, nowMs: now),
        '8 题 · 1 天前更新',
      );
    });

    test('没时间戳只显示题数', () {
      expect(setSubtitle(itemCount: 0, updatedAtMs: 0, nowMs: now), '0 题');
    });
  });

  group('searchFavoriteSets', () {
    final List<FavoriteSet> sets = <FavoriteSet>[
      set('a', '三角函数易错 10 题'),
      set('b', 'Math Midterm'),
      set('c', '周末回炉'),
    ];

    test('空查询不返回结果（搜索页只在有关键词时列组卷）', () {
      expect(searchFavoriteSets(sets, '   '), isEmpty);
    });

    test('按名称匹配、忽略大小写', () {
      expect(
        searchFavoriteSets(sets, 'math').map((FavoriteSet s) => s.id),
        <String>['b'],
      );
      expect(
        searchFavoriteSets(sets, '三角函数').map((FavoriteSet s) => s.id),
        <String>['a'],
      );
    });

    test('没有命中返回空', () {
      expect(searchFavoriteSets(sets, 'zzz'), isEmpty);
    });
  });

  group('isNewSinceTag（AI 归纳默认勾选）', () {
    test('从没归纳过：全算新增', () {
      expect(isNewSinceTag(1000, 0), isTrue);
    });

    test('上次归纳之后创建/更新才算新增', () {
      expect(isNewSinceTag(2000, 1500), isTrue);
      expect(isNewSinceTag(1000, 1500), isFalse);
      expect(isNewSinceTag(1500, 1500), isFalse);
    });
  });
}
