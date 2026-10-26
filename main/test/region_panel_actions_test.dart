import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shuaqi/domain/model/question.dart';
import 'package:shuaqi/domain/model/region_set.dart';
import 'package:shuaqi/domain/region/answer.dart';
import 'package:shuaqi/domain/region/region_rect.dart';
import 'package:shuaqi/ui/panel/region_panel.dart';
import 'package:shuaqi/ui/region/region_action.dart';
import 'package:shuaqi/ui/theme/app_theme.dart';

/// 题目区域的面板动作（2026-10-24 第二轮）：
/// - 顶部只剩「显示作答框 / 保存修改 / 收起」三个图标；
/// - 常驻工具行是「多选 / 改卷」（从底部搬上来）；
/// - 「收藏 / 对答案 / 问 AI」只在选中题之后出现。
void main() {
  QuestionBundle bundle(String id, String label, double y) => QuestionBundle(
    question: Question(
      id: id,
      workbookId: 'wb',
      ordinal: y.toInt(),
      level: 2,
      confidence: 0.9,
      label: label,
      stemText: '第 $label 题的题干',
    ),
    slices: <QuestionSlice>[
      QuestionSlice(
        pageIndex: 0,
        rect: RegionRect.fromLTRB(40, y, 520, y + 120),
        pageId: 'p1',
      ),
    ],
  );

  Future<void> pumpPanel(
    WidgetTester tester, {
    double width = 320,
    ThemeData? theme,
    void Function(QuestionBundle)? onFavorite,
    void Function(QuestionBundle)? onCheck,
    void Function(QuestionBundle)? onAsk,
    bool selected = true,
    bool multiSelecting = false,
    Set<String> selectedIds = const <String>{'q1'},
    void Function()? onToggleMultiSelect,
    void Function()? onGradeAll,
    void Function()? onGradeAi,
    bool showAnswers = false,
    void Function(bool)? onToggleShowAnswers,
    String? answerQuestionId,
    void Function(QuestionBundle)? onToggleAnswer,
    Widget? answerPanel,
    void Function()? onSave,
    bool saving = false,
    void Function(int, int)? onReorder,
    Widget? preview,
    AnswerSet answers = AnswerSet.empty,
  }) async {
    final RegionSet set = RegionSet(
      <QuestionBundle>[bundle('q1', '1.', 100), bundle('q2', '2.', 260)],
      answers: answers,
    );
    tester.view.physicalSize = Size(width * 3, 900 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: theme ?? ShqTheme.light(),
        home: Scaffold(
          body: RegionPanel(
            width: width,
            set: set,
            answers: answers,
            selectedKey: selected ? set.questions.first.anchorKey : null,
            editedCount: 0,
            canUndo: false,
            canRedo: false,
            actionsOf: (QuestionBundle b) => <RegionAction>{},
            onSelect: (_) {},
            onAdd: () {},
            onUndo: () {},
            onRedo: () {},
            onClearAll: () {},
            onRecut: () {},
            onClose: () {},
            onAction: (_, _) {},
            onFavorite: onFavorite,
            onCheckAnswer: onCheck,
            onAskAi: onAsk,
            onGradeAll: onGradeAll,
            onFillAnswers: onGradeAi,
            multiSelecting: multiSelecting,
            selectedIds: selectedIds,
            onToggleMultiSelect: onToggleMultiSelect,
            showAnswers: showAnswers,
            onToggleShowAnswers: onToggleShowAnswers,
            answerQuestionId: answerQuestionId,
            onToggleAnswer: onToggleAnswer,
            answerPanel: answerPanel,
            onSave: onSave,
            saving: saving,
            onReorder: onReorder,
            preview: preview,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('常驻工具行是多选 / 改卷；没选题时不出现收藏与对答案', (WidgetTester tester) async {
    await pumpPanel(
      tester,
      selected: false,
      onToggleMultiSelect: () {},
      onGradeAll: () {},
    );
    expect(find.text('多选'), findsOneWidget);
    expect(find.text('改卷'), findsOneWidget);
    // 用户口径：不选就不显示，而不是灰着长期占位。
    expect(find.text('收藏'), findsNothing);
    expect(find.text('AI 判'), findsNothing);
    expect(find.text('问 AI'), findsNothing);
    expect(find.text('AI 判'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  // 2026-10-26 用户第 1 条：工具行的「AI 判」换成「补答案」——
  // 批量 AI 判挪到多选条里。
  testWidgets('工具行：接了补答案回调就出现「补答案」并可点', (WidgetTester tester) async {
    int calls = 0;
    await pumpPanel(
      tester,
      selected: false,
      onToggleMultiSelect: () {},
      onGradeAll: () {},
      onGradeAi: () => calls++,
    );
    expect(find.text('补答案'), findsOneWidget);
    expect(find.text('AI 判'), findsNothing);
    await tester.tap(find.text('补答案'));
    await tester.pump();
    expect(calls, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('选中之后才出现收藏 / 对答案 / 问 AI，回调带当前题', (WidgetTester tester) async {
    final List<String> calls = <String>[];
    const AnswerNote note = AnswerNote(label: '1.', text: 'A', ordinal: 100);
    await pumpPanel(
      tester,
      answers: const AnswerSet(
        <String, AnswerNote>{'1.': note},
        byOrdinal: <int, AnswerNote>{100: note},
      ),
      onFavorite: (QuestionBundle b) => calls.add('fav:${b.question.id}'),
      onCheck: (QuestionBundle b) => calls.add('check:${b.question.id}'),
      onAsk: (QuestionBundle b) => calls.add('ai:${b.question.id}'),
    );
    expect(find.text('收藏'), findsOneWidget);
    expect(find.text('对答案'), findsOneWidget);
    expect(find.text('问 AI'), findsOneWidget);
    await tester.tap(find.text('收藏'));
    await tester.tap(find.text('对答案'));
    await tester.tap(find.text('问 AI'));
    expect(calls, <String>['fav:q1', 'check:q1', 'ai:q1']);
    expect(tester.takeException(), isNull);
  });

  // 2026-10-26 收尾：对答案必须有参考答案才可用，不能点了只弹一句提示。
  testWidgets('没有参考答案时「对答案」不可点', (WidgetTester tester) async {
    int checks = 0;
    await pumpPanel(
      tester,
      onCheck: (_) => checks++,
    );
    await tester.tap(find.text('对答案'));
    expect(checks, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('层级：多选/改卷 在题面预览之上；预览与收藏/对答案同级', (WidgetTester tester) async {
    const Widget preview = Text('题面预览占位块');
    await pumpPanel(
      tester,
      preview: preview,
      onToggleMultiSelect: () {},
      onGradeAll: () {},
      onFavorite: (_) {},
      onCheck: (_) {},
    );
    final double toolsY = tester.getTopLeft(find.text('多选')).dy;
    final double previewY = tester.getTopLeft(find.text('题面预览占位块')).dy;
    // 用户口径：多选 / 改卷 比题面预览高一层。
    expect(toolsY, lessThan(previewY));
    // 两者被同一件事（选中某题）唤起 → 同时出现。
    expect(find.text('收藏'), findsOneWidget);
    expect(find.text('对答案'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('不选时：工具行常驻，预览与收藏/对答案一起收掉', (WidgetTester tester) async {
    await pumpPanel(
      tester,
      selected: false,
      preview: const Text('题面预览占位块'),
      onToggleMultiSelect: () {},
      onGradeAll: () {},
      onFavorite: (_) {},
      onCheck: (_) {},
    );
    expect(find.text('多选'), findsOneWidget);
    expect(find.text('题面预览占位块'), findsNothing);
    expect(find.text('收藏'), findsNothing);
    expect(find.text('AI 判'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('多选模式：工具行变「退出多选」，批量条出现在它下方', (WidgetTester tester) async {
    bool toggled = false;
    await pumpPanel(
      tester,
      multiSelecting: true,
      selectedIds: const <String>{'q1', 'q2'},
      onToggleMultiSelect: () => toggled = true,
      onGradeAll: () {},
    );
    expect(find.text('退出多选'), findsOneWidget);
    expect(find.text('已选 2'), findsOneWidget);
    await tester.tap(find.text('退出多选'));
    expect(toggled, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('窄面板（手机 42%）不溢出', (WidgetTester tester) async {
    await pumpPanel(
      tester,
      width: 160,
      theme: ShqTheme.dark(),
      onToggleMultiSelect: () {},
      onGradeAll: () {},
    );
    expect(tester.takeException(), isNull);
    expect(find.text('多选'), findsOneWidget);
  });

  testWidgets('选中题有「答题情况」入口，展开后显示作答卡', (WidgetTester tester) async {
    int taps = 0;
    await pumpPanel(
      tester,
      onToggleAnswer: (_) => taps++,
      answerQuestionId: 'q1',
      answerPanel: const Text('作答框测试卡'),
    );
    // 箭头已经换成文字入口；展开后按钮变成「收起」，卡片内容已插入。
    expect(find.text('收起'), findsOneWidget);
    expect(find.text('作答框测试卡'), findsOneWidget);
    await tester.tap(find.text('收起'));
    expect(taps, 1);
  });

  testWidgets('面板上部「显示作答情况」开关可切换', (WidgetTester tester) async {
    bool? value;
    await pumpPanel(tester, onToggleShowAnswers: (bool v) => value = v);
    expect(find.byTooltip('显示作答情况'), findsOneWidget);
    await tester.tap(find.byTooltip('显示作答情况'));
    await tester.pumpAndSettle();
    expect(value, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('窄面板 + 显示作答情况不溢出', (WidgetTester tester) async {
    await pumpPanel(
      tester,
      width: 160,
      theme: ShqTheme.dark(),
      showAnswers: true,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('标题旁有保存修改入口，可点击', (WidgetTester tester) async {
    int saves = 0;
    await pumpPanel(tester, onSave: () => saves++);
    expect(find.byTooltip('保存修改'), findsOneWidget);
    await tester.tap(find.byTooltip('保存修改'));
    expect(saves, 1);
  });

  testWidgets('拖动把手可以触发重排', (WidgetTester tester) async {
    int? oldIndex;
    int? newIndex;
    await pumpPanel(
      tester,
      onReorder: (int o, int n) {
        oldIndex = o;
        newIndex = n;
      },
    );
    final Finder handle = find.byType(ReorderableDragStartListener).first;
    expect(handle, findsOneWidget);
    await tester.timedDrag(
      handle,
      const Offset(0, 90),
      const Duration(milliseconds: 900),
    );
    await tester.pumpAndSettle();
    expect(oldIndex, 0);
    expect(newIndex, isNotNull);
  });
}
