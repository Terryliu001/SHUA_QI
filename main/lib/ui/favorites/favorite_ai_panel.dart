import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shuaqi/app/ai/ai_service.dart';
import 'package:shuaqi/app/favorite/favorite_store.dart';
import 'package:shuaqi/domain/ai/chat.dart';
import 'package:shuaqi/domain/ai/llm_config.dart';
import 'package:shuaqi/domain/ai/question_payload.dart';
import 'package:shuaqi/domain/ink/ink_doc.dart';
import 'package:shuaqi/domain/model/favorite.dart';
import 'package:shuaqi/domain/model/grading.dart';
import 'package:shuaqi/domain/region/answer.dart';
import 'package:shuaqi/infra/vault/paths.dart';
import 'package:shuaqi/infra/vault/vault.dart';
import 'package:shuaqi/state/ai_providers.dart';
import 'package:shuaqi/state/app_providers.dart';
import 'package:shuaqi/state/favorite_providers.dart';
import 'package:shuaqi/state/ink_providers.dart';
import 'package:shuaqi/ui/panel/ai_chat_panel.dart';
import 'package:shuaqi/ui/reader/answer_crop_renderer.dart';
import 'package:shuaqi/ui/settings/ai_settings_sheet.dart';

/// 收藏题的「问 AI」右侧面板（T8.3b，2026-10-25）。
///
/// 直接复用阅读器的 [AiChatPanel]（同一套气泡/公式/深度思考/附件/错误重试），
/// 这里只做三件事：
/// 1. 把**快照**准备成面板要的输入（题面/原作答/重刷作答 + 参考答案 + 历史）；
/// 2. 把流式对话接到 `AiService.chat`，历史落回 `favorites/<id>/chat.json`；
/// 3. 快捷动作：先做一遍（不落答案，只回在对话里）/ 判我的作答（写回
///    `grading.json` + 列表判定点）。
///
/// 单题重刷与看题页共用**同一份** chat.json：在哪里问都一样。
class FavoriteAiPanel extends ConsumerStatefulWidget {
  const FavoriteAiPanel({
    super.key,
    required this.favorite,
    required this.width,
    required this.onClose,
    this.onGraded,
  });

  final Favorite favorite;
  final double width;
  final VoidCallback onClose;

  /// AI 判完并写回快照后通知外层（看题页要刷新判定卡片与自己的副本）。
  final VoidCallback? onGraded;

  @override
  ConsumerState<FavoriteAiPanel> createState() => _FavoriteAiPanelState();
}

class _FavoriteAiPanelState extends ConsumerState<FavoriteAiPanel> {
  List<ChatTurn>? _turns;
  List<AiImageAttachment> _attachments = const <AiImageAttachment>[];
  String? _referenceAnswer;
  bool _hasStudentAnswer = false;

  /// 判题中临时给的正在写入提示（避免连点重复判）。
  bool _grading = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final FavoriteStore store = ref.read(favoriteStoreProvider);
    final String id = widget.favorite.id;
    final List<ChatTurn> turns = await store.loadChat(id);
    final AnswerNote? note = await store.loadAnswerNote(id);
    final List<AiImageAttachment> attachments = await _buildAttachments();
    final bool hasRedo = await _hasRedoInk();
    if (!mounted) {
      return;
    }
    setState(() {
      _turns = turns;
      _referenceAnswer = note?.text.trim().isEmpty ?? true ? null : note!.text;
      _attachments = attachments;
      _hasStudentAnswer = hasRedo || attachments.any(
        (AiImageAttachment item) => item.kind == AiImageKind.answer,
      );
    });
  }

  Future<List<AiImageAttachment>> _buildAttachments() async {
    final Favorite favorite = widget.favorite;
    final Vault vault = ref.read(vaultProvider);
    final List<AiImageAttachment> out = <AiImageAttachment>[];
    Future<void> add(String path, AiImageKind kind, String label) async {
      if (out.length >= AiService.maxImagesPerRequest) {
        return;
      }
      final File file = vault.file(path);
      if (!file.existsSync()) {
        return;
      }
      try {
        final Uint8List bytes = await file.readAsBytes();
        if (bytes.isNotEmpty) {
          out.add(AiImageAttachment(kind: kind, label: label, bytes: bytes));
        }
      } on Object {
        // 单张读失败不影响其余附件。
      }
    }

    await add(VaultPaths.favoriteStem(favorite.id), AiImageKind.question, '题面');
    await add(VaultPaths.favoriteAnswerImg(favorite.id), AiImageKind.answer, '原作答');
    // 重刷的作答也发给 AI：用户问"我这次写得对不对"时，模型要能看到它。
    final Uint8List? redo = await _redoPng();
    if (redo != null && out.length < AiService.maxImagesPerRequest) {
      out.add(
        AiImageAttachment(kind: AiImageKind.answer, label: '重刷作答', bytes: redo),
      );
    }
    return out;
  }

  Future<bool> _hasRedoInk() async {
    final InkDoc doc = await _redoDoc();
    return doc.strokes.isNotEmpty;
  }

  Future<InkDoc> _redoDoc() async {
    final InkPageKey key = InkPageKey(
      favoriteRedoSessionId(widget.favorite.id),
      0,
    );
    try {
      return await ref
          .read(inkStoreForKeyProvider(key))
          .load(key.sessionId, key.pageIndex);
    } on Object {
      return InkDoc.empty;
    }
  }

  Future<Uint8List?> _redoPng() async {
    final InkDoc doc = await _redoDoc();
    if (doc.strokes.isEmpty) {
      return null;
    }
    return renderInkDocPng(doc: doc);
  }

  Future<void> _openConfig(LlmConfig current) async {
    final bool saved = await showAiSettingsSheet(context, initial: current);
    if (!mounted || !saved) {
      return;
    }
    ref.invalidate(aiConfigProvider);
    setState(() {});
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
    final AiService service = ref.read(aiServiceProvider(widget.favorite.id));
    final QuestionAiPayload payload = _payload();
    if (action == AiQuickAction.solve) {
      final AiSolution solution = await service.solve(
        config: config,
        payload: payload,
        attachments: attachments,
      );
      return AiChatResult(
        text: solution.explanation.trim().isEmpty
            ? solution.answer
            : solution.explanation,
        solution: solution,
      );
    }
    if (action == AiQuickAction.grade) {
      if (_grading) {
        return null;
      }
      _grading = true;
      try {
        final AiGrade grade = await service.grade(
          config: config,
          payload: payload,
          referenceAnswer: _referenceAnswer,
          // 收藏快照没有可靠的 OCR 文本：判题以作答图为准。
          studentAnswerText: '',
          attachments: attachments,
        );
        await ref
            .read(favoriteStoreProvider)
            .saveGrading(
              widget.favorite.id,
              QuestionGrade(
                questionId: widget.favorite.questionId,
                verdict: grade.verdict,
                source: GradeSource.ai,
                at: DateTime.now().toUtc().millisecondsSinceEpoch,
                note: grade.reason,
              ),
            );
        ref.invalidate(favoritesProvider);
        widget.onGraded?.call();
        return AiChatResult(
          text: grade.reason,
          grade: grade,
          applied: true,
        );
      } finally {
        _grading = false;
      }
    }
    return null;
  }

  LlmConfig _configFrom(AsyncValue<LlmConfig> value) {
    return value.maybeWhen<LlmConfig>(
      data: (LlmConfig loaded) => loaded,
      orElse: () => LlmConfig.empty,
    );
  }

  QuestionAiPayload _payload() {
    final Favorite favorite = widget.favorite;
    return buildQuestionAiPayload(
      questionId: favorite.questionId,
      label: favorite.label,
      pageIndex: favorite.pageIndex,
      rect: favorite.rect,
      text: favorite.stemText.trim().isEmpty ? null : favorite.stemText,
    );
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
      key: ValueKey<String>('fav-ai-${widget.favorite.id}'),
      width: widget.width,
      payload: _payload(),
      config: config,
      initialTurns: turns,
      attachments: _attachments,
      referenceAnswer: _referenceAnswer,
      hasStudentAnswer: _hasStudentAnswer,
      onPersist: (List<ChatTurn> next) =>
          ref.read(favoriteStoreProvider).saveChat(widget.favorite.id, next),
      onSend:
          (
            String message,
            List<ChatTurn> history,
            List<AiImageAttachment> attachments,
            bool deepThinking,
          ) {
            final AiService service = ref.read(
              aiServiceProvider(widget.favorite.id),
            );
            return service.chat(
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
