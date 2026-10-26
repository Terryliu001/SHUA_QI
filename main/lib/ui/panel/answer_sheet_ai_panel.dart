import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shuaqi/app/ai/ai_service.dart';
import 'package:shuaqi/domain/ai/chat.dart';
import 'package:shuaqi/domain/ai/llm_config.dart';
import 'package:shuaqi/domain/ai/question_payload.dart';
import 'package:shuaqi/domain/answer/answer_paper.dart';
import 'package:shuaqi/domain/ink/ink_doc.dart';
import 'package:shuaqi/domain/model/question.dart';
import 'package:shuaqi/domain/model/region_set.dart';
import 'package:shuaqi/domain/model/wb_page.dart';
import 'package:shuaqi/domain/region/answer.dart';
import 'package:shuaqi/domain/region/math_text.dart';
import 'package:shuaqi/infra/vault/layout_store.dart';
import 'package:shuaqi/state/ai_providers.dart';
import 'package:shuaqi/state/grading_providers.dart';
import 'package:shuaqi/state/ink_providers.dart';
import 'package:shuaqi/state/region_providers.dart';
import 'package:shuaqi/ui/panel/ai_chat_panel.dart';
import 'package:shuaqi/ui/reader/answer_crop_renderer.dart';
import 'package:shuaqi/ui/reader/page_image_cache.dart';
import 'package:shuaqi/ui/settings/ai_settings_sheet.dart';

/// 答题卡里的「问 AI」面板（2026-10-25，与收藏重刷同一套）。
///
/// 复用 `AiChatPanel`；这里只把**这一道题**的输入准备出来：
/// - 附件：题面裁切 + 答题纸笔迹导出（多张纵向拼接）；
/// - 历史：`layout/ai_chat.v1.json`（与阅读器「问 AI」**共用同一份**）；
/// - 快捷动作：先做一遍（写 `answers_ai`）/ 判我的作答（写 `grading.v1.json`）。
class AnswerSheetAiPanel extends ConsumerStatefulWidget {
  const AnswerSheetAiPanel({
    super.key,
    required this.workbookId,
    required this.sessionId,
    required this.bundle,
    required this.set,
    required this.pages,
    required this.cache,
    required this.paper,
    required this.width,
    required this.onClose,
    this.onGraded,
  });

  final String workbookId;
  final String sessionId;
  final QuestionBundle bundle;
  final RegionSet set;
  final List<WbPage> pages;
  final PageImageCache cache;
  final AnswerPaper paper;
  final double width;
  final VoidCallback onClose;
  final VoidCallback? onGraded;

  @override
  ConsumerState<AnswerSheetAiPanel> createState() =>
      _AnswerSheetAiPanelState();
}

class _AnswerSheetAiPanelState extends ConsumerState<AnswerSheetAiPanel> {
  List<ChatTurn>? _turns;
  List<AiImageAttachment> _attachments = const <AiImageAttachment>[];
  String? _referenceAnswer;
  bool _hasStudentAnswer = false;

  String get _questionId => widget.bundle.question.id;

  String get _inkSessionId =>
      answerInkSessionId(widget.sessionId, widget.bundle.question.id);

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final List<ChatTurn> turns = await ref
        .read(aiChatStoreProvider(widget.workbookId))
        .load(widget.workbookId, _questionId);
    final AnswerNote? note = widget.set.answers.forQuestion(
      ordinal: widget.bundle.question.ordinal,
      label: widget.bundle.question.label,
    );
    final List<InkDoc> docs = await _answerDocs();
    final bool hasInk = docs.any((InkDoc doc) => doc.strokes.isNotEmpty);
    final List<AiImageAttachment> attachments = await _attachmentsOf(
      docs,
      hasInk: hasInk,
    );
    if (!mounted) {
      return;
    }
    setState(() {
      _turns = turns;
      _referenceAnswer = note?.text.trim().isEmpty ?? true ? null : note!.text;
      _attachments = attachments;
      _hasStudentAnswer = hasInk;
    });
  }

  Future<List<InkDoc>> _answerDocs() async {
    final int pages = widget.paper.pages;
    final InkStoreLookup lookup = InkStoreLookup(ref);
    final List<InkDoc> docs = <InkDoc>[];
    for (int i = 0; i < pages; i++) {
      try {
        docs.add(
          await lookup.load(
            InkPageKey(_inkSessionId, i, workbookId: widget.workbookId),
          ),
        );
      } on Object {
        docs.add(InkDoc.empty);
      }
    }
    return docs;
  }

  Future<List<AiImageAttachment>> _attachmentsOf(
    List<InkDoc> docs, {
    required bool hasInk,
  }) async {
    final List<AiImageAttachment> out = <AiImageAttachment>[];
    final QuestionSlice? slice = widget.bundle.slices.isEmpty
        ? null
        : widget.bundle.slices.first;
    if (slice != null &&
        slice.pageIndex >= 0 &&
        slice.pageIndex < widget.pages.length) {
      final Uint8List? stem = await renderAnswerCropPng(
        cache: widget.cache,
        page: widget.pages[slice.pageIndex],
        rect: slice.rect,
        doc: InkDoc.empty,
        scale: 2.2,
        maxWidth: 1400,
        maxHeight: 2000,
      );
      if (stem != null) {
        out.add(
          AiImageAttachment(
            kind: AiImageKind.question,
            label: '题面',
            bytes: stem,
          ),
        );
      }
    }
    if (hasInk) {
      final Uint8List? answer = await renderAnswerSheetInkPng(
        docs: docs,
        widthPt: widget.paper.widthPt,
        heightPt: widget.paper.heightPt,
      );
      if (answer != null) {
        out.add(
          AiImageAttachment(
            kind: AiImageKind.answer,
            label: '答题卡作答',
            bytes: answer,
          ),
        );
      }
    }
    return out;
  }

  Future<void> _openConfig(LlmConfig current) async {
    final bool saved = await showAiSettingsSheet(context, initial: current);
    if (!mounted || !saved) {
      return;
    }
    ref.invalidate(aiConfigProvider);
    setState(() {});
  }

  LlmConfig _configFrom(AsyncValue<LlmConfig> value) {
    return value.maybeWhen<LlmConfig>(
      data: (LlmConfig loaded) => loaded,
      orElse: () => LlmConfig.empty,
    );
  }

  QuestionAiPayload _payload() {
    final Question question = widget.bundle.question;
    final String? raw = question.stemText;
    final String? text = raw != null && !formulaHeavyText(raw) ? raw : null;
    final QuestionSlice slice = widget.bundle.slices.first;
    return buildQuestionAiPayload(
      questionId: question.id,
      label: question.label ?? '${question.ordinal}',
      pageIndex: slice.pageIndex,
      rect: slice.rect,
      text: text,
      provenance: text == null
          ? TextProvenance.none
          : TextProvenance.pdfTextLayer,
    );
  }

  Future<AiChatResult?> _quick(
    AiQuickAction action,
    List<AiImageAttachment> attachments,
  ) async {
    final LlmConfig config = _configFrom(ref.read(aiConfigProvider));
    if (config.validationError() != null) {
      await _openConfig(config);
      return null;
    }
    final AiService service = ref.read(aiServiceProvider(widget.workbookId));
    final QuestionAiPayload payload = _payload();
    if (action == AiQuickAction.solve) {
      final AiSolution solution = await service.solve(
        config: config,
        payload: payload,
        attachments: attachments,
      );
      if (solution.answer.trim().isNotEmpty) {
        await _saveAiAnswer(solution.answer);
      }
      return AiChatResult(
        text: solution.explanation.trim().isEmpty
            ? solution.answer
            : solution.explanation,
        solution: solution,
      );
    }
    if (action == AiQuickAction.grade) {
      final AiGrade grade = await service.grade(
        config: config,
        payload: payload,
        referenceAnswer: _referenceAnswer,
        studentAnswerText: '',
        attachments: attachments,
      );
      final bool applied = await ref
          .read(gradingProvider(widget.workbookId))
          .applyAi(_questionId, grade.verdict, note: grade.reason);
      widget.onGraded?.call();
      return AiChatResult(
        text: grade.reason,
        grade: grade,
        applied: applied,
      );
    }
    return null;
  }

  Future<void> _saveAiAnswer(String text) async {
    final LayoutStore store = ref.read(layoutStoreProvider);
    final AnswerSet existing = AnswerSet.fromJson(
      await store.readAiAnswers(widget.workbookId),
    );
    final Question question = widget.bundle.question;
    final String label = question.label ?? '${question.ordinal}';
    final QuestionSlice slice = widget.bundle.slices.first;
    final AnswerSet next = existing.withNote(
      AnswerNote(
        label: label,
        text: text,
        source: 'ai',
        pageIndex: slice.pageIndex,
        ordinal: question.ordinal,
      ),
    );
    await store.writeAiAnswers(widget.workbookId, next.toJson());
    ref.invalidate(regionSetProvider(widget.workbookId));
  }

  @override
  Widget build(BuildContext context) {
    final List<ChatTurn>? turns = _turns;
    if (turns == null) {
      return SizedBox(
        width: widget.width,
        height: double.infinity,
        child: const Center(child: CircularProgressIndicator()),
      );
    }
    final LlmConfig config = _configFrom(ref.watch(aiConfigProvider));
    return AiChatPanel(
      key: ValueKey<String>('sheet-ai-$_questionId'),
      width: widget.width,
      payload: _payload(),
      config: config,
      initialTurns: turns,
      attachments: _attachments,
      referenceAnswer: _referenceAnswer,
      hasStudentAnswer: _hasStudentAnswer,
      onPersist: (List<ChatTurn> next) => ref
          .read(aiChatStoreProvider(widget.workbookId))
          .save(widget.workbookId, _questionId, next),
      onSend:
          (
            String message,
            List<ChatTurn> history,
            List<AiImageAttachment> attachments,
            bool deepThinking,
          ) {
            return ref
                .read(aiServiceProvider(widget.workbookId))
                .chat(
                  config: config,
                  payload: _payload(),
                  history: history,
                  message: message,
                  attachments: attachments,
                  referenceAnswer: _referenceAnswer,
                  deepThinking: deepThinking,
                );
          },
      onQuick: _quick,
      onOpenConfig: () => unawaited(_openConfig(config)),
      onClose: widget.onClose,
    );
  }
}

/// 小工具：按页键取笔迹 store（答题卡每题一份）。
class InkStoreLookup {
  InkStoreLookup(this.ref);

  final WidgetRef ref;

  Future<InkDoc> load(InkPageKey key) =>
      ref.read(inkStoreForKeyProvider(key)).load(key.sessionId, key.pageIndex);
}
