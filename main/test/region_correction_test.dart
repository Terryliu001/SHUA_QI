import 'package:flutter_test/flutter_test.dart';
import 'package:shuaqi/domain/region/correction.dart';
import 'package:shuaqi/domain/region/edited_question.dart';
import 'package:shuaqi/domain/region/region_rect.dart';
import 'package:shuaqi/domain/region/split.dart';

/// 覆盖层（T3.4）：8 种编辑 + 撤销 + 重切后的重新锚定。
///
/// 这里锁的是**语义**而不是实现：拖动只动当前页那段、合并保留先出现者、
/// 拆分出来的下段是新题、重切后 y 抖动仍能命中、锚不上不崩不删数据。
void main() {
  EditedQuestion question(
    String label,
    int page,
    double top, {
    double height = 60,
    int ordinal = 1,
  }) => EditedQuestion(
    key: regionKeyOf(label, <PageSlice>[
      PageSlice(
        pageIndex: page,
        rect: RegionRect.fromLTRB(50, top, 400, top + height),
      ),
    ]),
    ordinal: ordinal,
    label: label,
    level: 2,
    kind: 'essay',
    stem: label,
    confidence: 0.9,
    slices: <PageSlice>[
      PageSlice(
        pageIndex: page,
        rect: RegionRect.fromLTRB(50, top, 400, top + height),
      ),
    ],
  );

  List<EditedQuestion> base() => <EditedQuestion>[
    question('1.', 0, 100, ordinal: 1),
    question('2.', 0, 200, ordinal: 2),
    question('3.', 0, 300, ordinal: 3),
  ];

  test('1. 拖动只改当前页那一段，其它段不动', () {
    final EditedQuestion crossing = EditedQuestion(
      key: '9.|0|100',
      ordinal: 4,
      label: '9.',
      level: 2,
      kind: 'essay',
      stem: '',
      confidence: 0.9,
      slices: <PageSlice>[
        PageSlice(pageIndex: 0, rect: RegionRect.fromLTRB(50, 100, 400, 300)),
        PageSlice(pageIndex: 1, rect: RegionRect.fromLTRB(50, 60, 400, 200)),
      ],
    );
    final List<EditedQuestion> result = CorrectionLog(<RegionCorrection>[
      MoveCorrection(id: 'a', key: crossing.key, page: 1, dx: 0, dy: 40),
    ]).applyTo(<EditedQuestion>[crossing]);
    expect(result.single.slices.first.rect.top, 100, reason: '第一页那段没动');
    expect(result.single.slices.last.rect.top, 100, reason: '第二页那段下移了 40');
  });

  test('2. 缩放直接替换当前页那一段的矩形', () {
    final List<EditedQuestion> result = CorrectionLog(<RegionCorrection>[
      ResizeCorrection(
        id: 'a',
        key: base()[1].key,
        page: 0,
        rect: RegionRect.fromLTRB(60, 210, 380, 260),
      ),
    ]).applyTo(base());
    expect(result[1].slices.single.rect.left, 60);
    expect(result[1].slices.single.rect.height, 50);
  });

  test('3. 新增手画框：序号接在最后、打 userAdded', () {
    final List<EditedQuestion> result = CorrectionLog(<RegionCorrection>[
      AddQuestionCorrection(
        id: 'a',
        key: '',
        label: '手画',
        page: 0,
        rect: RegionRect.fromLTRB(60, 500, 380, 600),
      ),
    ]).applyTo(base());
    expect(result.length, 4);
    expect(result.last.ordinal, 4);
    expect(result.last.userAdded, isTrue);
    expect(result.last.label, '手画');
  });

  test('4. 删除是软删除（记录还在，只是不显示）', () {
    final List<EditedQuestion> result = CorrectionLog(<RegionCorrection>[
      DeleteCorrection(id: 'a', key: base()[0].key),
    ]).applyTo(base());
    expect(result.length, 3);
    expect(result.first.deleted, isTrue);
  });

  test('5. 合并：保留先出现者，后者标删除，矩形取并集', () {
    final List<EditedQuestion> result = CorrectionLog(<RegionCorrection>[
      MergeCorrection(id: 'a', key: base()[0].key, fromKey: base()[1].key),
    ]).applyTo(base());
    expect(result[0].deleted, isFalse);
    expect(result[0].slices.single.rect.top, 100);
    expect(result[0].slices.single.rect.bottom, 260, reason: '并到第二题的底');
    expect(result[1].deleted, isTrue);
  });

  test('6. 拆分：上半留原题，下半成为新题（顺序接最后）', () {
    final List<EditedQuestion> result = CorrectionLog(<RegionCorrection>[
      SplitCorrection(id: 'a', key: base()[1].key, page: 0, atY: 230),
    ]).applyTo(base());
    expect(result.length, 4);
    expect(result[1].slices.single.rect.bottom, 230);
    final EditedQuestion lower = result.last;
    expect(lower.slices.single.rect.top, 230);
    expect(lower.slices.single.rect.bottom, 260);
    expect(lower.userAdded, isTrue);
    expect(lower.ordinal, 4);
  });

  test('7. 拆分点太靠近边缘时不动（不产生碎片框）', () {
    final List<EditedQuestion> result = CorrectionLog(<RegionCorrection>[
      SplitCorrection(id: 'a', key: base()[1].key, page: 0, atY: 205),
    ]).applyTo(base());
    expect(result.length, 3);
  });

  test('8. 跨页：给某题加一段 + 去掉一段', () {
    final CorrectionLog log = CorrectionLog(<RegionCorrection>[
      AddSliceCorrection(
        id: 'a',
        key: base()[2].key,
        page: 1,
        rect: RegionRect.fromLTRB(50, 60, 400, 260),
      ),
    ]);
    final List<EditedQuestion> added = log.applyTo(base());
    expect(added[2].slices.length, 2);
    expect(added[2].firstPage, 0);

    final CorrectionLog trimmed = log.push(
      RemoveSliceCorrection(id: 'b', key: added[2].key, page: 1),
    );
    final List<EditedQuestion> removed = trimmed.applyTo(base());
    expect(removed[2].slices.length, 1);
  });

  test('9. 锁定 / 解锁', () {
    final CorrectionLog lock = CorrectionLog(<RegionCorrection>[
      LockCorrection(id: 'a', key: base()[0].key, value: true),
    ]);
    expect(lock.applyTo(base()).first.locked, isTrue);
    expect(lock.lockedKeys, <String>{base()[0].key});
    final CorrectionLog unlock = lock.push(
      LockCorrection(id: 'b', key: base()[0].key, value: false),
    );
    expect(unlock.applyTo(base()).first.locked, isFalse);
    expect(unlock.lockedKeys, isEmpty, reason: '最后一次是解锁');
  });

  test('10. 撤销 = 弹掉最后一条再重算（不需要每条的 revert）', () {
    final CorrectionLog log = CorrectionLog(<RegionCorrection>[
      DeleteCorrection(id: 'a', key: base()[0].key),
    ]);
    expect(log.applyTo(base()).first.deleted, isTrue);
    expect(log.dropLast().applyTo(base()).first.deleted, isFalse);
    expect(CorrectionLog.empty.dropLast().isEmpty, isTrue);
  });

  test('11. 重切后 y 抖动 ±40 仍能锚定；差太远则跳过且不删数据', () {
    // 模拟"重切后同一题下移 40pt"
    final List<EditedQuestion> recut = <EditedQuestion>[
      question('1.', 0, 140, ordinal: 1),
      question('2.', 0, 240, ordinal: 2),
    ];
    final CorrectionLog log = CorrectionLog(<RegionCorrection>[
      DeleteCorrection(id: 'a', key: question('1.', 0, 100).key),
    ]);
    final List<EditedQuestion> applied = log.applyTo(recut);
    expect(applied[0].deleted, isTrue, reason: '模糊匹配命中');
    expect(log.ops.length, 1, reason: '操作本身没有被删改');

    // 重切后 y 差 300 → 锚不上，跳过，不抛
    final List<EditedQuestion> far = <EditedQuestion>[
      question('1.', 0, 400, ordinal: 1),
    ];
    expect(log.applyTo(far).first.deleted, isFalse);
  });

  test('12. JSON 往返不丢操作', () {
    final CorrectionLog log = CorrectionLog(<RegionCorrection>[
      MoveCorrection(id: 'a', key: base()[0].key, page: 0, dx: 2.5, dy: -3),
      ResizeCorrection(
        id: 'b',
        key: base()[1].key,
        page: 0,
        rect: RegionRect.fromLTRB(60, 210, 380, 260),
      ),
      MergeCorrection(id: 'c', key: base()[0].key, fromKey: base()[1].key),
      SplitCorrection(id: 'd', key: base()[2].key, page: 0, atY: 330),
      LockCorrection(id: 'e', key: base()[2].key, value: true),
      DeleteCorrection(id: 'f', key: base()[0].key),
      AddSliceCorrection(
        id: 'g',
        key: base()[2].key,
        page: 1,
        rect: RegionRect.fromLTRB(50, 60, 400, 200),
      ),
      RemoveSliceCorrection(id: 'h', key: base()[2].key, page: 1),
      AddQuestionCorrection(
        id: 'i',
        key: '',
        label: '手画',
        page: 0,
        rect: RegionRect.fromLTRB(60, 500, 380, 600),
      ),
      RenameCorrection(id: 'j', key: base()[2].key, label: '12.'),
    ]);
    final CorrectionLog restored = CorrectionLog.fromJson(log.toJson('wb'));
    expect(restored.length, log.length);
    // 重放结果一致（顺序与幂等都要对）
    final List<EditedQuestion> a = log.applyTo(base());
    final List<EditedQuestion> b = restored.applyTo(base());
    expect(b.length, a.length);
    for (int i = 0; i < a.length; i++) {
      expect(b[i].key, a[i].key);
      expect(b[i].deleted, a[i].deleted);
      expect(b[i].locked, a[i].locked);
      expect(b[i].slices.length, a[i].slices.length);
    }
  });

  test('14. 改题号：标签与 anchor key 一起换，几何不动', () {
    final List<EditedQuestion> result = CorrectionLog(<RegionCorrection>[
      RenameCorrection(id: 'a', key: base()[1].key, label: '12.'),
    ]).applyTo(base());
    expect(result[1].label, '12.');
    // key 含题号：改完必须重算，否则后续 op（拖动/删除）会对不上
    expect(result[1].key, startsWith('12.|'));
    expect(result[1].slices.single.rect.top, 200, reason: '几何不受影响');
    expect(result[0].label, '1.', reason: '其它题不动');
  });

  test('15. 改题号后仍能继续命中（后续 op 用新 key）', () {
    final List<EditedQuestion> result = CorrectionLog(<RegionCorrection>[
      RenameCorrection(id: 'a', key: base()[0].key, label: '7.'),
      const MoveCorrection(id: 'b', key: '7.|0|100', page: 0, dx: 0, dy: 20),
    ]).applyTo(base());
    expect(result[0].label, '7.');
    expect(result[0].slices.single.rect.top, 120);
  });

  test('13. 未知类型/坏 JSON 不会崩，退化成空覆盖层', () {
    expect(
      CorrectionLog.fromJson(<String, Object?>{
        'version': 1,
        'ops': <Object?>[
          <String, Object?>{'t': 'future-op', 'id': 'x'},
        ],
      }).isEmpty,
      isTrue,
    );
    expect(
      CorrectionLog.fromJson(<String, Object?>{'version': 99}).isEmpty,
      isTrue,
    );
  });
}
