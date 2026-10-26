import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shuaqi/app/region/question_order_controller.dart';
import 'package:shuaqi/domain/model/question.dart';
import 'package:shuaqi/domain/region/region_rect.dart';
import 'package:shuaqi/infra/vault/layout_store.dart';
import 'package:shuaqi/infra/vault/vault.dart';

void main() {
  QuestionBundle q(String id, int ordinal) => QuestionBundle(
    question: Question(
      id: id,
      workbookId: 'w',
      ordinal: ordinal,
      level: 2,
      confidence: 0.9,
    ),
    slices: <QuestionSlice>[
      QuestionSlice(
        pageIndex: 0,
        rect: RegionRect.fromLTRB(
          0,
          ordinal * 100.0,
          300,
          ordinal * 100.0 + 90,
        ),
        pageId: 'p1',
      ),
    ],
  );

  Future<QuestionOrderController> makeController() async {
    final Directory dir = await Directory.systemTemp.createTemp('shq_order_');
    addTearDown(() {
      if (dir.existsSync()) {
        dir.deleteSync(recursive: true);
      }
    });
    final Vault vault = await Vault.open(dir.path);
    final QuestionOrderController controller = QuestionOrderController(
      workbookId: 'w',
      store: LayoutStore(vault),
    );
    await controller.load();
    return controller;
  }

  test('apply 按 order 排，未知题目保持原始相对顺序排最后', () async {
    final QuestionOrderController c = await makeController();
    c.order.value = <String>['c', 'a'];
    final List<QuestionBundle> sorted = c.apply(<QuestionBundle>[
      q('a', 1),
      q('b', 2),
      q('c', 3),
      q('d', 4),
    ]);
    expect(
      <String>[for (final QuestionBundle b in sorted) b.question.id],
      <String>['c', 'a', 'b', 'd'],
    );
    c.order.dispose();
  });

  test('move 使用 onReorderItem 已调整的 newIndex', () async {
    final QuestionOrderController c = await makeController();
    final List<QuestionBundle> list = <QuestionBundle>[
      q('a', 1),
      q('b', 2),
      q('c', 3),
    ];
    // onReorderItem 语义：a 拖到末尾时 newIndex = 2（已扣移除偏移）。
    await c.move(list, 0, 2);
    final List<QuestionBundle> sorted = c.apply(list);
    expect(
      <String>[for (final QuestionBundle b in sorted) b.question.id],
      <String>['b', 'c', 'a'],
    );
    c.order.dispose();
  });

  test('顺序落盘后可重新读回', () async {
    final QuestionOrderController first = await makeController();
    await first.move(
      <QuestionBundle>[q('a', 1), q('b', 2), q('c', 3)],
      0,
      2,
    );
    // 同一个临时目录里不能用 makeController（会新建目录）；直接读 store。
    // 这里用文件的持久化由 first.store 保证，再建一个指向同一目录的控制器。
    final QuestionOrderController second = QuestionOrderController(
      workbookId: 'w',
      store: first.store,
    );
    await second.load();
    expect(second.order.value, <String>['b', 'c', 'a']);
    final List<QuestionBundle> sorted = second.apply(<QuestionBundle>[
      q('a', 1),
      q('b', 2),
      q('c', 3),
    ]);
    expect(
      <String>[for (final QuestionBundle b in sorted) b.question.id],
      <String>['b', 'c', 'a'],
    );
    // 落盘完成后再 dispose：否则 dispose 里的异步 flush 会跑在临时目录清理之后。
    await first.flush();
    first.dispose();
    second.dispose();
  });
}
