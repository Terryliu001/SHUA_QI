import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shuaqi/domain/ink/ink_doc.dart';
import 'package:shuaqi/domain/model/answer_sheet.dart';
import 'package:shuaqi/domain/region/answer.dart';
import 'package:shuaqi/domain/region/region_rect.dart';
import 'package:shuaqi/ui/panel/answer_status_card.dart';
import 'package:shuaqi/ui/theme/app_theme.dart';

/// 「答题情况」卡（2026-10-24 重做）：
/// 两栏预览、无「调整答题框/下载/识别」三个键、双击重新生成、待重识别标记。
void main() {
  AnswerSheetEntry entry({
    bool hasCrop = false,
    String ocrText = '',
    int updatedAt = 0,
    int ocrAt = 0,
    bool manual = false,
  }) => AnswerSheetEntry(
    questionId: 'q1',
    pageIndex: 0,
    rect: RegionRect.fromLTRB(40, 100, 500, 300),
    cropPath: hasCrop ? 'workbooks/w/layout/answer_crops/q1.png' : null,
    ocrText: ocrText,
    ocrAt: ocrAt,
    updatedAt: updatedAt,
    regionSource: manual ? AnswerRegionSource.manual : AnswerRegionSource.auto,
  );

  InkDoc inkDoc() => const InkDoc(
    revision: 1,
    strokes: <InkStroke>[
      InkStroke(uid: 'a', points: <InkPoint>[InkPoint(x: 10, y: 10)]),
    ],
  );

  Future<void> pumpCard(
    WidgetTester tester, {
    AnswerSheetEntry? data,
    AnswerNote? answerNote,
    bool withInk = false,
    VoidCallback? onOpenSheet,
    VoidCallback? onRegenerate,
    Future<Uint8List?> Function()? onRenderMerged,
  }) async {
    tester.view.physicalSize = const Size(320 * 3, 900 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: ShqTheme.light(),
        home: Scaffold(
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(10),
            child: AnswerStatusCard(
              entry: data ?? entry(),
              strokeCount: 3,
              answerNote: answerNote,
              onJump: () {},
              answerInk: withInk ? inkDoc() : null,
              onOpenSheet: onOpenSheet,
              onRegenerate: onRegenerate,
              onRenderMerged: onRenderMerged,
              onAskAi: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('只有一栏「作答」：没有题面栏，也没有三个旧按钮', (WidgetTester tester) async {
    await pumpCard(tester);
    expect(find.text('答题情况'), findsOneWidget);
    expect(find.textContaining('3 笔'), findsOneWidget);
    // 用户第 2 条：题面那栏去掉（和上面的题面预览重复）。
    expect(find.text('题面'), findsNothing);
    expect(find.text('调整答题框'), findsNothing);
    expect(find.text('下载'), findsNothing);
    expect(find.text('识别'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('没有笔迹也没有文字时给「点这里去写」', (WidgetTester tester) async {
    int opened = 0;
    await pumpCard(tester, onOpenSheet: () => opened++);
    expect(find.text('点这里去写'), findsOneWidget);
    await tester.tap(find.text('点这里去写'));
    expect(opened, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('有笔迹时双击切到"题面+书写合并"', (WidgetTester tester) async {
    int renders = 0;
    await pumpCard(
      tester,
      withInk: true,
      onRenderMerged: () async {
        renders += 1;
        return null;
      },
    );
    expect(find.textContaining('双击看题面'), findsOneWidget);
    await tester.tap(find.textContaining('双击看题面'));
    await tester.pump(const Duration(milliseconds: 40));
    await tester.tap(find.textContaining('双击看题面'));
    await tester.pumpAndSettle();
    expect(renders, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('PDF 答案优先显示文本与来源，且不再出现 AI 补答案', (WidgetTester tester) async {
    await pumpCard(
      tester,
      answerNote: const AnswerNote(
        label: '1',
        text: 'f(f(x))=1',
        source: 'pdf_text',
      ),
    );
    expect(find.text('参考答案'), findsOneWidget);
    expect(find.text('f(f(x))=1'), findsOneWidget);
    expect(find.text('PDF'), findsOneWidget);
    expect(find.text('AI 补答案'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('没有答案时只给说明，不再有 AI 补答案按钮', (WidgetTester tester) async {
    await pumpCard(tester);
    expect(find.text('PDF 未收录答案'), findsOneWidget);
    expect(find.text('AI 补答案'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('框改过但文字是旧的 → 显示「待重识别」', (WidgetTester tester) async {
    await pumpCard(
      tester,
      data: entry(ocrText: '旧文字', ocrAt: 100, updatedAt: 200, manual: true),
    );
    expect(find.text('待重识别'), findsOneWidget);
    expect(find.text('手调'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('窄面板不溢出', (WidgetTester tester) async {
    await pumpCard(
      tester,
      data: entry(ocrText: '一段比较长的识别文字，用来把卡片撑高', ocrAt: 1, updatedAt: 1),
      answerNote: const AnswerNote(label: '1', text: '答案文本', source: 'inline'),
    );
    expect(tester.takeException(), isNull);
  });
}
