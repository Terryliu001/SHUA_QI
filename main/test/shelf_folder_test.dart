import 'package:flutter_test/flutter_test.dart';
import 'package:shuaqi/domain/model/shelf_folder.dart';

ShelfFolder _f(String id, [String parent = '', String name = '']) =>
    ShelfFolder(id: id, name: name.isEmpty ? id : name, parentId: parent);

void main() {
  final List<ShelfFolder> all = <ShelfFolder>[
    _f('a', '', '数学'),
    _f('b', 'a', '期中'),
    _f('c', 'b', '2025'),
    _f('d', '', '英语'),
  ];

  group('childFolders', () {
    test('只取直接子级，按 sort 再按名字', () {
      expect(
        childFolders(all, 'a').map((ShelfFolder f) => f.id).toList(),
        <String>['b'],
      );
      expect(
        childFolders(all, '').map((ShelfFolder f) => f.id).toList(),
        <String>['a', 'd'],
      );
    });
  });

  group('visibleFolderRows', () {
    test('没展开的文件夹只出现自己', () {
      final List<ShelfFolderRow> rows = visibleFolderRows(all, <String>{'a'});
      expect(
        rows.map((ShelfFolderRow r) => '${r.folder.id}@${r.depth}').toList(),
        <String>['a@0', 'b@1', 'd@0'],
      );
    });

    test('全部展开时按深度优先摊平', () {
      final List<ShelfFolderRow> rows = visibleFolderRows(all, <String>{
        'a',
        'b',
        'd',
      });
      expect(
        rows.map((ShelfFolderRow r) => '${r.folder.id}@${r.depth}').toList(),
        <String>['a@0', 'b@1', 'c@2', 'd@0'],
      );
    });

    test('一个都不展开：只有顶层', () {
      expect(visibleFolderRows(all, <String>{}).length, 2);
    });
  });

  group('folderPath', () {
    test('从根到自己，含自己', () {
      expect(
        folderPath(all, 'c').map((ShelfFolder f) => f.id).toList(),
        <String>['a', 'b', 'c'],
      );
    });

    test('未知 id 返回空（不清空调用方的 UI）', () {
      expect(folderPath(all, 'zzz'), isEmpty);
      expect(folderPath(all, ''), isEmpty);
    });

    test('成环也不会死循环（防御）', () {
      final List<ShelfFolder> cyclic = <ShelfFolder>[
        _f('x', 'y'),
        _f('y', 'x'),
      ];
      expect(folderPath(cyclic, 'x').length, lessThanOrEqualTo(64));
    });
  });

  group('folderSubtreeIds', () {
    test('包含自己与所有子孙', () {
      expect(folderSubtreeIds(all, 'a'), <String>{'a', 'b', 'c'});
      expect(folderSubtreeIds(all, 'd'), <String>{'d'});
    });
  });
}
