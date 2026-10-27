import 'package:flutter_test/flutter_test.dart';
import 'package:shuaqi/domain/model/question.dart';
import 'package:shuaqi/domain/model/region_set.dart';
import 'package:shuaqi/domain/region/correction.dart';
import 'package:shuaqi/domain/region/edited_question.dart';
import 'package:shuaqi/domain/region/region_rect.dart';
import 'package:shuaqi/domain/region/split.dart';
import 'package:shuaqi/ui/region/add_question_action.dart';

/// 「加题」按钮的语义（2026-10-27 用户反馈）。
///
/// 这是本轮最容易改坏的一处：**虚线框**上的「加题」是"就地确认"，
/// 不是"新建一道题 + 删掉原框"。写死在这里，避免以后又被改回
/// "题号 = 最大号 +1、面板位置跳到末尾"。
void main() {
  QuestionBundle bundle({
    required String id,
    required String label,
    required int ordinal,
    required int level,
    double top = 100,
  }) {
    final Question question = Question(
      id: id,
      workbookId: 'wb',
      ordinal: ordinal,
      level: level,
      confidence: 0.4,
      label: label,
    );
    final QuestionSlice slice = QuestionSlice(
      pageIndex: 0,
      rect: RegionRect.fromLTRB(50, top, 400, top + 120),
      pageId: 'p0',
    );
    return QuestionBundle(
      question: question,
      slices: <QuestionSlice>[slice],
    );
  }

  test('虚线框（level 1）→ 确认原题，不新建、key 不变', () {
    final QuestionBundle dashed = bundle(
      id: 'q2',
      label: '二、',
      ordinal: 2,
      level: 1,
      top: 500,
    );
    final QuestionBundle solid = bundle(
      id: 'q1',
      label: '1.',
      ordinal: 1,
      level: 2,
    );
    final RegionSet set = RegionSet(<QuestionBundle>[solid, dashed]);

    final RegionCorrection op = addQuestionFor(
      bundle: dashed,
      set: set,
      id: 'op',
      key: dashed.anchorKey,
    );

    expect(op, isA<ConfirmQuestionCorrection>());
    expect(op.key, dashed.anchorKey, reason: '必须指回原来那个框');
    expect(op, isNot(isA<AddQuestionCorrection>()), reason: '不能新增一道题');
  });

  test('确认后：题号 / 序号 / 区域不变，只把 level 1 → 2', () {
    final QuestionBundle dashed = bundle(
      id: 'q2',
      label: '二、',
      ordinal: 2,
      level: 1,
      top: 500,
    );
    final EditedQuestion before = EditedQuestion(
      key: dashed.anchorKey,
      ordinal: dashed.question.ordinal,
      label: dashed.question.label!,
      level: dashed.question.level,
      kind: 'unknown',
      stem: '',
      confidence: dashed.question.confidence,
      slices: dashed.slices
          .map(
            (QuestionSlice s) => PageSlice(pageIndex: s.pageIndex, rect: s.rect),
          )
          .toList(),
    );

    final RegionCorrection op = addQuestionFor(
      bundle: dashed,
      set: RegionSet(<QuestionBundle>[dashed]),
      id: 'op',
      key: dashed.anchorKey,
    );
    final EditedQuestion after = CorrectionLog(<RegionCorrection>[
      op,
    ]).applyTo(<EditedQuestion>[before]).single;

    expect(after.key, before.key, reason: 'key 不变 → 题目 id 会被复用');
    expect(after.ordinal, 2, reason: '序号不变 → 题目面板位置不变');
    expect(after.label, '二、', reason: '题号不变');
    expect(after.level, 2, reason: '虚线变实线');
    expect(after.slices.single.rect.top, 500);
    expect(after.slices.single.rect.bottom, 620);
  });

  test('实线题（level 2）→ 仍然新增一道，题号接最大号 +1', () {
    final QuestionBundle solid = bundle(
      id: 'q2',
      label: '2.',
      ordinal: 2,
      level: 2,
      top: 300,
    );
    final RegionSet set = RegionSet(<QuestionBundle>[
      bundle(id: 'q1', label: '1.', ordinal: 1, level: 2),
      solid,
    ]);

    final RegionCorrection op = addQuestionFor(
      bundle: solid,
      set: set,
      id: 'op',
      key: solid.anchorKey,
    );

    expect(op, isA<AddQuestionCorrection>());
    final AddQuestionCorrection add = op as AddQuestionCorrection;
    expect(add.label, '3.', reason: '最大题号 2 → 新题 3');
    expect(add.key, isEmpty, reason: '新题的 key 由区域自己算');
    expect(add.page, 0);
    expect(add.rect.top, 300, reason: '区域取本题最后一段');
  });

  test('nextQuestionLabel：只认标签里的数字，没有数字时给 1.', () {
    QuestionBundle labeled(String label, int ordinal) =>
        bundle(id: 'q$ordinal', label: label, ordinal: ordinal, level: 2);

    expect(
      nextQuestionLabel(
        RegionSet(<QuestionBundle>[labeled('1.', 1), labeled('12.', 2)]),
      ),
      '13.',
    );
    expect(
      nextQuestionLabel(RegionSet(<QuestionBundle>[labeled('（3）', 1)])),
      '4.',
    );
    expect(
      nextQuestionLabel(RegionSet(<QuestionBundle>[labeled('一、', 1)])),
      '1.',
    );
  });
}
