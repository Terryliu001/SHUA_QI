import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shuaqi/domain/ai/chat.dart';
import 'package:shuaqi/domain/ai/llm_config.dart';
import 'package:shuaqi/domain/ai/question_payload.dart';
import 'package:shuaqi/domain/model/grading.dart';
import 'package:shuaqi/domain/region/region_rect.dart';
import 'package:shuaqi/ui/panel/ai_chat_panel.dart';
import 'package:shuaqi/ui/theme/app_theme.dart';

/// 1×1 透明 PNG：让 `Image.memory` 有真实图可解。
final Uint8List _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk'
  '+A8AAQUBAScY42YAAAAASUVORK5CYII=',
);

const LlmConfig _configured = LlmConfig(
  baseUrl: 'https://example.com/v1',
  apiKey: 'key',
  model: 'deepseek-chat',
);

QuestionAiPayload _payload({String? text = '求函数的最值。'}) =>
    buildQuestionAiPayload(
      questionId: 'q1',
      label: '12.',
      pageIndex: 2,
      rect: RegionRect.fromLTRB(40, 100, 520, 300),
      text: text,
      provenance: TextProvenance.pdfTextLayer,
    );

AiImageAttachment _questionImage() => AiImageAttachment(
  kind: AiImageKind.question,
  label: '题面',
  bytes: _png,
  width: 1,
  height: 1,
);

Future<void> _pumpPanel(
  WidgetTester tester, {
  LlmConfig config = _configured,
  List<ChatTurn> initialTurns = const <ChatTurn>[],
  List<AiImageAttachment> attachments = const <AiImageAttachment>[],
  bool hasStudentAnswer = true,
  String? referenceAnswer,
  double width = 360,
  double height = 820,
  Stream<AiChatChunk> Function(
    String message,
    List<ChatTurn> history,
    List<AiImageAttachment> attachments,
    bool deepThinking,
  )?
  onSend,
  Future<AiChatResult?> Function(
    AiQuickAction action,
    List<AiImageAttachment> attachments,
  )?
  onQuick,
  Future<AiImageAttachment?> Function()? onPickImage,
  Future<void> Function(List<ChatTurn> turns)? onPersist,
  VoidCallback? onOpenConfig,
  ThemeData? theme,
}) async {
  tester.view.physicalSize = Size(width * 3, height * 3);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: theme ?? ShqTheme.light(),
      home: Scaffold(
        body: AiChatPanel(
          payload: _payload(),
          width: width,
          config: config,
          initialTurns: initialTurns,
          attachments: attachments,
          hasStudentAnswer: hasStudentAnswer,
          referenceAnswer: referenceAnswer,
          onSend: onSend,
          onQuick: onQuick,
          onPickImage: onPickImage,
          onPersist: onPersist,
          onOpenConfig: onOpenConfig,
          onBack: () {},
          onClose: () {},
        ),
      ),
    ),
  );
  await tester.pump();
}

Future<void> _flush(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 120));
  await tester.pump(const Duration(milliseconds: 120));
}

void main() {
  testWidgets('未配置：给出配置入口，发送键变成「配置 AI」', (WidgetTester tester) async {
    int opened = 0;
    await _pumpPanel(
      tester,
      config: LlmConfig.empty,
      attachments: <AiImageAttachment>[_questionImage()],
      onOpenConfig: () => opened++,
    );
    expect(find.text('还没有配置 AI'), findsOneWidget);
    expect(find.text('去配置'), findsOneWidget);
    expect(find.text('未配置'), findsOneWidget);
    await tester.tap(find.text('配置 AI'));
    await tester.pump();
    expect(opened, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('已配置：题面附件、模型标签与快捷动作都在', (WidgetTester tester) async {
    await _pumpPanel(
      tester,
      attachments: <AiImageAttachment>[_questionImage()],
      onSend: (_, _, _, _) => const Stream<AiChatChunk>.empty(),
    );
    expect(find.text('问 AI'), findsOneWidget);
    expect(find.text('deepseek-chat'), findsOneWidget);
    expect(find.text('将发送 1/4 张图'), findsOneWidget);
    expect(find.text('讲这道题'), findsOneWidget);
    expect(find.text('先做一遍'), findsOneWidget);
    expect(find.text('判我的作答'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('发送：流式增量结束后落成一条助手消息', (WidgetTester tester) async {
    final List<String> sent = <String>[];
    await _pumpPanel(
      tester,
      onSend:
          (
            String message,
            List<ChatTurn> history,
            List<AiImageAttachment> at,
            bool deepThinking,
          ) {
            sent.add(message);
            return Stream<AiChatChunk>.fromIterable(<AiChatChunk>[
              const AiChatChunk(text: '先配方，'),
              const AiChatChunk(text: '再代入。'),
            ]);
          },
    );
    await tester.enterText(find.byType(TextField), '这题怎么算？');
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, '发送'));
    await _flush(tester);
    expect(sent.single, '这题怎么算？');
    expect(find.textContaining('先配方'), findsOneWidget);
    expect(find.text('这题怎么算？'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('流式失败：保留已收内容，重试后成功', (WidgetTester tester) async {
    int calls = 0;
    await _pumpPanel(
      tester,
      onSend: (_, _, _, _) {
        calls++;
        if (calls == 1) {
          return Stream<AiChatChunk>.error(
            const AiFailure(AiFailureKind.timeout, '这次超时了。'),
          );
        }
        return Stream<AiChatChunk>.value(const AiChatChunk(text: '重试成功'));
      },
    );
    await tester.enterText(find.byType(TextField), '讲一下');
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, '发送'));
    await _flush(tester);
    expect(find.textContaining('这次超时了'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
    await tester.tap(find.text('重试'));
    await _flush(tester);
    expect(calls, 2);
    expect(find.text('重试成功'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('停止：保留半截回答并标「已停止生成」', (WidgetTester tester) async {
    final StreamController<AiChatChunk> controller =
        StreamController<AiChatChunk>();
    addTearDown(controller.close);
    await _pumpPanel(tester, onSend: (_, _, _, _) => controller.stream);
    await tester.enterText(find.byType(TextField), '讲一下');
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, '发送'));
    await tester.pump();
    controller.add(const AiChatChunk(text: '写到一半'));
    await tester.pump(const Duration(milliseconds: 120));
    expect(find.textContaining('写到一半'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, '停止'));
    await _flush(tester);
    expect(find.textContaining('已停止生成'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('快捷动作「先做一遍」：展示解析与 AI 参考答案', (WidgetTester tester) async {
    await _pumpPanel(
      tester,
      hasStudentAnswer: false,
      onQuick:
          (AiQuickAction action, List<AiImageAttachment> attachments) async {
            expect(action, AiQuickAction.solve);
            return const AiChatResult(
              text: '先求导，再令导数为零。',
              solution: AiSolution(answer: '42', explanation: '先求导，再令导数为零。'),
            );
          },
    );
    await tester.tap(find.widgetWithText(ActionChip, '先做一遍'));
    await _flush(tester);
    expect(find.text('AI 解法'), findsOneWidget);
    expect(find.text('参考答案（AI 补）'), findsOneWidget);
    expect(find.text('42'), findsOneWidget);
    expect(find.textContaining('先求导'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('快捷动作「判我的作答」：显示 AI 判定与理由', (WidgetTester tester) async {
    await _pumpPanel(
      tester,
      hasStudentAnswer: true,
      onQuick:
          (AiQuickAction action, List<AiImageAttachment> attachments) async {
            expect(action, AiQuickAction.grade);
            return const AiChatResult(
              text: '符号反了。',
              grade: AiGrade(verdict: AnswerVerdict.wrong, reason: '符号反了。'),
              applied: false,
            );
          },
    );
    await tester.tap(find.widgetWithText(ActionChip, '判我的作答'));
    await _flush(tester);
    expect(find.text('AI 判：错'), findsOneWidget);
    expect(find.text('未覆盖手改'), findsOneWidget);
    expect(find.textContaining('符号反了'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('附件：可以从相册再加一张，计数与缩略图更新', (WidgetTester tester) async {
    await _pumpPanel(
      tester,
      attachments: <AiImageAttachment>[_questionImage()],
      onSend: (_, _, _, _) => const Stream<AiChatChunk>.empty(),
      onPickImage: () async => AiImageAttachment(
        kind: AiImageKind.user,
        label: '图片 2',
        bytes: _png,
        width: 1,
        height: 1,
      ),
    );
    expect(find.text('将发送 1/4 张图'), findsOneWidget);
    await tester.tap(find.text('添加图片'));
    await tester.pump();
    expect(find.text('将发送 2/4 张图'), findsOneWidget);
    expect(find.text('图片 2'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('附件条在输入框上方，而不是会话顶部', (WidgetTester tester) async {
    await _pumpPanel(
      tester,
      attachments: <AiImageAttachment>[_questionImage()],
      onSend: (_, _, _, _) => const Stream<AiChatChunk>.empty(),
    );
    final double stripY = tester.getTopLeft(find.text('将发送 1/4 张图')).dy;
    final double inputY = tester.getTopLeft(find.byType(TextField)).dy;
    expect(stripY, lessThan(inputY));
    expect(tester.takeException(), isNull);
  });

  testWidgets('深度思考：开关传给服务，推理默认展开、可收起', (WidgetTester tester) async {
    bool? requested;
    await _pumpPanel(
      tester,
      onSend:
          (
            String message,
            List<ChatTurn> history,
            List<AiImageAttachment> at,
            bool deepThinking,
          ) {
            requested = deepThinking;
            return Stream<AiChatChunk>.fromIterable(<AiChatChunk>[
              const AiChatChunk(thinking: '先看条件，再想反例。'),
              const AiChatChunk(text: '答案是 2。'),
            ]);
          },
    );
    await tester.tap(find.byType(FilterChip));
    await tester.pump();
    await tester.enterText(find.byType(TextField), '仔细讲讲');
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, '发送'));
    await _flush(tester);
    expect(requested, true);
    expect(find.text('思考过程'), findsOneWidget);
    // 默认就要看得见推理，不用用户再点一次。
    expect(find.textContaining('先看条件'), findsOneWidget);
    await tester.tap(find.text('思考过程'));
    await tester.pump();
    expect(find.textContaining('先看条件'), findsNothing);
    expect(find.text('答案是 2。'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('代码块：语言标签、原文与复制按钮都在', (WidgetTester tester) async {
    await _pumpPanel(
      tester,
      initialTurns: <ChatTurn>[
        ChatTurn.assistant('示例：\n```dart\nfinal x = r"\$y";\n```\n完。', at: 1),
      ],
      onSend: (_, _, _, _) => const Stream<AiChatChunk>.empty(),
    );
    expect(find.text('dart'), findsOneWidget);
    expect(find.textContaining(r'final x = r"$y";'), findsOneWidget);
    expect(find.byTooltip('复制代码'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('历史消息：打开时直接显示上次的对话', (WidgetTester tester) async {
    await _pumpPanel(
      tester,
      initialTurns: <ChatTurn>[
        ChatTurn.user('上次的问题', at: 1, imageCount: 2),
        ChatTurn.assistant('上次的回答', at: 2),
      ],
      onSend: (_, _, _, _) => const Stream<AiChatChunk>.empty(),
    );
    expect(find.text('上次的问题'), findsOneWidget);
    expect(find.text('上次的回答'), findsOneWidget);
    expect(find.text('附 2 张图'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('窄面板 + 深色不溢出', (WidgetTester tester) async {
    await _pumpPanel(
      tester,
      width: 250,
      height: 640,
      theme: ShqTheme.dark(),
      attachments: <AiImageAttachment>[_questionImage()],
      onSend: (_, _, _, _) => const Stream<AiChatChunk>.empty(),
    );
    expect(tester.takeException(), isNull);
  });
}
