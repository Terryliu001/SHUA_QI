import 'package:flutter_test/flutter_test.dart';
import 'package:shuaqi/domain/model/workbook.dart';
import 'package:shuaqi/domain/model/workbook_search.dart';

Workbook _wb(String id, String title) => Workbook(
  id: id,
  title: title,
  sha1: 'sha1_$id',
  pageCount: 4,
  pageSize: '595x842',
  sourcePath: '/tmp/$id.pdf',
  createdAt: 0,
);

/// 书架标题搜索（纯函数，宿主机秒级）。
void main() {
  final List<Workbook> books = <Workbook>[
    _wb('a', '数学分析（上）期中试卷'),
    _wb('b', '高等数学 下册'),
    _wb('c', 'ENGLISH Final Exam'),
  ];

  test('空 query 返回全部（搜索框刚聚焦、还没输入时不该变空）', () {
    expect(filterByQuery(books, ''), books);
    expect(filterByQuery(books, '   '), books); // 全空白等同空
  });

  test('中文子串命中', () {
    final List<Workbook> hit = filterByQuery(books, '数学');
    expect(hit.length, 2); // 数学分析 + 高等数学
    expect(hit.first.id, 'a');
  });

  test('忽略大小写（英文标题）', () {
    expect(filterByQuery(books, 'english').single.id, 'c');
    expect(filterByQuery(books, 'FINAL').single.id, 'c');
  });

  test('无命中返回空列表', () {
    expect(filterByQuery(books, '量子力学'), isEmpty);
  });

  test('首尾空白不影响匹配（用户从别处粘贴的 query 常带空格）', () {
    expect(filterByQuery(books, '  高等数学  ').single.id, 'b');
  });
}
