import 'package:flutter_test/flutter_test.dart';
import 'package:shuaqi/domain/model/workbook.dart';
import 'package:shuaqi/domain/model/workbook_search.dart';

Workbook _wb(
  String id, {
  String title = '卷',
  int pages = 4,
  int sortTime = 1000,
  String folder = '',
  List<String> tags = const <String>[],
}) {
  return Workbook(
    id: id,
    title: title,
    sha1: id,
    pageCount: pages,
    pageSize: 'A4',
    sourcePath: '/tmp/$id.pdf',
    createdAt: sortTime,
    openedAt: sortTime,
    folder: folder,
    tags: tags,
  );
}

void main() {
  group('mergeFolders', () {
    test('合并卷子文件夹与手动新建的空文件夹，去重排序', () {
      final List<Workbook> items = <Workbook>[
        _wb('a', folder: '数学'),
        _wb('b', folder: '英语'),
        _wb('c', folder: '数学'),
      ];
      expect(mergeFolders(items, const <String>['英语', ' 物理 ', '']), <String>[
        '数学',
        '物理',
        '英语',
      ]);
    });

    test('空列表 + 空额外列表 = 空', () {
      expect(mergeFolders(const <Workbook>[], const <String>[]), isEmpty);
    });
  });

  group('addableToFolder（文件夹页「选择文件」）', () {
    test('排除已经在该文件夹里的卷，未分类排前面、其余按最近使用', () {
      final List<Workbook> items = <Workbook>[
        _wb('in-folder', folder: '数学', sortTime: 9999),
        _wb('other-new', folder: '英语', sortTime: 3000),
        _wb('free-old', sortTime: 1000),
        _wb('free-new', sortTime: 2000),
      ];
      final List<Workbook> out = addableToFolder(items, '数学');
      expect(out.map((Workbook w) => w.id), <String>[
        'free-new',
        'free-old',
        'other-new',
      ]);
    });

    test('空文件夹：全部卷都可加入，未分类优先', () {
      final List<Workbook> items = <Workbook>[
        _wb('a', folder: '数学', sortTime: 500),
        _wb('b', sortTime: 100),
      ];
      expect(addableToFolder(items, '新文件夹').map((Workbook w) => w.id), <String>[
        'b',
        'a',
      ]);
    });

    test('不修改原列表', () {
      final List<Workbook> items = <Workbook>[
        _wb('a', folder: '数学'),
        _wb('b', folder: '英语'),
      ];
      addableToFolder(items, '数学');
      expect(items.map((Workbook w) => w.folder), <String>['数学', '英语']);
    });
  });

  group('sortWorkbooks', () {
    test('最近优先：sortTime 降序，同值按标题', () {
      final List<Workbook> items = <Workbook>[
        _wb('a', title: 'B', sortTime: 2000),
        _wb('b', title: 'A', sortTime: 3000),
        _wb('c', title: 'C', sortTime: 2000),
      ];
      expect(
        sortWorkbooks(items, BookshelfSort.recent).map((Workbook w) => w.id),
        <String>['b', 'a', 'c'],
      );
    });

    test('标题升序忽略大小写', () {
      final List<Workbook> items = <Workbook>[
        _wb('a', title: 'banana'),
        _wb('b', title: 'Apple'),
        _wb('c', title: 'cherry'),
      ];
      expect(
        sortWorkbooks(items, BookshelfSort.title).map((Workbook w) => w.title),
        <String>['Apple', 'banana', 'cherry'],
      );
    });

    test('页数降序', () {
      final List<Workbook> items = <Workbook>[
        _wb('a', pages: 4),
        _wb('b', pages: 12),
        _wb('c', pages: 8),
      ];
      expect(
        sortWorkbooks(items, BookshelfSort.pages).map((Workbook w) => w.id),
        <String>['b', 'c', 'a'],
      );
    });

    test('不修改原列表', () {
      final List<Workbook> items = <Workbook>[
        _wb('a', pages: 4),
        _wb('b', pages: 12),
      ];
      final List<Workbook> sorted = sortWorkbooks(items, BookshelfSort.pages);
      expect(items.map((Workbook w) => w.id), <String>['a', 'b']);
      expect(sorted.map((Workbook w) => w.id), <String>['b', 'a']);
    });
  });
}
