import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shuaqi/domain/ai/chat.dart';
import 'package:shuaqi/domain/ai/llm_config.dart';
import 'package:shuaqi/domain/ai/question_payload.dart';
import 'package:shuaqi/domain/model/grading.dart';
import 'package:shuaqi/ui/theme/tokens.dart';
import 'package:shuaqi/ui/widgets/ai_image_attachment.dart';
import 'package:shuaqi/ui/widgets/image_viewer.dart';
import 'package:shuaqi/ui/widgets/markdown/chat_content.dart';
import 'package:shuaqi/ui/widgets/math/math_text.dart';

/// 一次请求最多带 4 张图（与 `AiService.maxImagesPerRequest` 一致）。
const int kMaxChatAttachments = 4;

/// 阅读器右侧的「问 AI」面板（2026-10-24 接入真实模型）。
///
/// ## 设计口径
/// - **题面图片是附件，不是背景**：进入面板时就渲染好缩略图，用户能先确认
///   "AI 会看到哪一块"；发送时按同样顺序交给模型。
/// - **对话是讲题**：不判分；判题走独立快捷动作，结果才落 `grading.v1.json`。
/// - **失败不装死**：超时/断网保留已收内容，错误气泡给可重试的文案。
/// - **历史落盘**：由 [onPersist] 写 Vault；面板本身不碰 IO。
class AiChatPanel extends StatefulWidget {
  const AiChatPanel({
    super.key,
    required this.payload,
    required this.width,
    this.onBack,
    required this.onClose,
    this.config = LlmConfig.empty,
    this.initialTurns = const <ChatTurn>[],
    this.attachments = const <AiImageAttachment>[],
    this.referenceAnswer,
    this.hasStudentAnswer = false,
    this.onPersist,
    this.onSend,
    this.onQuick,
    this.onOpenConfig,
    this.onPickImage,
  });

  final QuestionAiPayload payload;
  final double width;

  /// 返回上一层面板。null = 没有上一层（收藏夹直接开的就是 AI 面板），不画返回键。
  final VoidCallback? onBack;

  /// 收起整个右侧面板。
  final VoidCallback onClose;

  final LlmConfig config;

  /// 这道题上次的对话（由阅读器从 Vault 读好再传）。
  final List<ChatTurn> initialTurns;

  /// 进入面板时准备好的图片（题面/作答）。
  final List<AiImageAttachment> attachments;

  /// 参考答案（PDF 或 AI 补的）。null = 本题没有。
  final String? referenceAnswer;

  /// 是否已有可判的作答（手写或识别文本）。
  final bool hasStudentAnswer;

  /// 对话结束后落盘。失败不应影响面板。
  final Future<void> Function(List<ChatTurn> turns)? onPersist;

  /// 真正的流式发送入口。null = 未接线（面板给出明确说明）。
  final Stream<AiChatChunk> Function(
    String message,
    List<ChatTurn> history,
    List<AiImageAttachment> attachments,
    bool deepThinking,
  )?
  onSend;

  /// 快捷动作（先做一遍 / 判我的作答）。返回 null = 没有结果。
  final Future<AiChatResult?> Function(
    AiQuickAction action,
    List<AiImageAttachment> attachments,
  )?
  onQuick;

  /// 打开 AI 配置。
  final VoidCallback? onOpenConfig;

  /// 从相册/文件选一张图；null = 用默认实现。
  final Future<AiImageAttachment?> Function()? onPickImage;

  @override
  State<AiChatPanel> createState() => _AiChatPanelState();
}

class _AiChatPanelState extends State<AiChatPanel> {
  late final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();
  late final List<ChatTurn> _turns = List<ChatTurn>.of(widget.initialTurns);
  late final List<AiImageAttachment> _attachments = List<AiImageAttachment>.of(
    widget.attachments,
  );

  bool _sending = false;
  bool _quickBusy = false;
  bool _deepThinking = false;
  String _draft = '';
  String _thinkingDraft = '';
  Timer? _draftTimer;
  StreamSubscription<AiChatChunk>? _subscription;

  /// 最近一次发送的原文与"发送前的历史"，用于重试时不重复插入用户气泡。
  String? _lastUserText;
  List<ChatTurn>? _lastHistory;
  bool _lastDeepThinking = false;

  bool get _configured => widget.config.validationError() == null;

  bool get _busy => _sending || _quickBusy;

  @override
  void initState() {
    super.initState();
    // 打开时直接落到最新一条：历史较长时不这么做，用户看到的是几天前的
    // 开头，还得自己往下翻。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollToEnd(force: true);
    });
  }

  @override
  void didUpdateWidget(covariant AiChatPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 阅读器重新渲染（例如刚补了答案）时不重置用户临时移除/添加的图片；
    // 只有外层真的换了一份附件（引用不同）才同步。
    if (!identical(oldWidget.attachments, widget.attachments)) {
      _attachments
        ..clear()
        ..addAll(widget.attachments);
    }
  }

  @override
  void dispose() {
    _draftTimer?.cancel();
    unawaited(_subscription?.cancel());
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  // ── 滚动 ──────────────────────────────────────────────────────────

  void _scrollToEnd({bool force = false}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) {
        return;
      }
      final ScrollPosition position = _scroll.position;
      // 用户手动往上翻时不要抢滚动条。
      if (!force && position.pixels < position.maxScrollExtent - 120) {
        return;
      }
      _scroll.animateTo(
        position.maxScrollExtent,
        duration: ShqMotion.fast,
        curve: ShqMotion.curveStandard,
      );
    });
  }

  // ── 持久化 ────────────────────────────────────────────────────────

  void _persist() {
    final Future<void> Function(List<ChatTurn>)? save = widget.onPersist;
    if (save == null) {
      return;
    }
    unawaited(save(List<ChatTurn>.of(_turns)));
  }

  List<ChatTurn> _historyForModel() => <ChatTurn>[
    for (final ChatTurn turn in _turns)
      if (!turn.failed && turn.kind != ChatTurnKind.error) turn,
  ];

  // ── 发送 / 流式 ───────────────────────────────────────────────────

  Future<void> _send() async {
    final String text = _input.text.trim();
    if (text.isEmpty || _busy) {
      return;
    }
    if (!_configured) {
      _openConfig();
      return;
    }
    if (widget.onSend == null) {
      _notice('AI 发送入口还没接上。');
      return;
    }
    _input.clear();
    _startStream(text, addUserTurn: true, deepThinking: _deepThinking);
    setState(() {});
  }

  void _startStream(
    String text, {
    required bool addUserTurn,
    required bool deepThinking,
  }) {
    if (widget.onSend == null) {
      return;
    }
    _draftTimer?.cancel();
    unawaited(_subscription?.cancel());
    final List<ChatTurn> history = addUserTurn
        ? _historyForModel()
        : (_lastHistory ?? _historyForModel());
    if (addUserTurn) {
      _lastUserText = text;
      _lastHistory = history;
      _lastDeepThinking = deepThinking;
      _turns.add(
        ChatTurn.user(text, at: _now, imageCount: _attachments.length),
      );
      _persist();
    }
    // 重试时把上一条错误气泡收掉。
    _turns.removeWhere(
      (ChatTurn turn) => turn.failed && turn.kind == ChatTurnKind.error,
    );
    setState(() {
      _sending = true;
      _draft = '';
      _thinkingDraft = '';
    });
    _scrollToEnd(force: true);
    _subscription = widget
        .onSend!(
          text,
          history,
          List<AiImageAttachment>.of(_attachments),
          deepThinking,
        )
        .listen(
          (AiChatChunk chunk) {
            if (!mounted) {
              return;
            }
            if (chunk.thinking.isNotEmpty) {
              _thinkingDraft += chunk.thinking;
            }
            if (chunk.text.isNotEmpty) {
              _draft += chunk.text;
            }
            _draftTimer ??= Timer(const Duration(milliseconds: 80), () {
              _draftTimer = null;
              if (!mounted) {
                return;
              }
              setState(() {});
              _scrollToEnd();
            });
          },
          onError: (Object error, StackTrace stack) {
            if (!mounted || !_sending) {
              return;
            }
            _draftTimer?.cancel();
            _draftTimer = null;
            final String message = error is AiFailure
                ? error.message
                : '发送失败：$error';
            final String partial = _draft.trim();
            final String thinking = _clipThinking(_thinkingDraft);
            _draft = '';
            _thinkingDraft = '';
            setState(() {
              _sending = false;
              _turns.add(
                ChatTurn(
                  role: ChatRole.assistant,
                  text: partial.isEmpty
                      ? message
                      : '$partial\n\n（已中断：$message）',
                  at: _now,
                  kind: ChatTurnKind.error,
                  thinking: thinking.isEmpty ? null : thinking,
                  deepThinking: deepThinking,
                  retryable: true,
                  failed: true,
                ),
              );
            });
            _scrollToEnd(force: true);
          },
          onDone: () {
            if (!mounted || !_sending) {
              return;
            }
            _draftTimer?.cancel();
            _draftTimer = null;
            _finishDraft(deepThinking: deepThinking);
            _scrollToEnd(force: true);
          },
          cancelOnError: true,
        );
  }

  void _finishDraft({required bool deepThinking}) {
    final String text = _draft.trim();
    final String thinking = _clipThinking(_thinkingDraft);
    _draft = '';
    _thinkingDraft = '';
    if (text.isEmpty) {
      setState(() {
        _sending = false;
        _turns.add(
          ChatTurn.error(
            '这次没有拿到回答，点重试再发一次。',
            at: _now,
            thinking: thinking.isEmpty ? null : thinking,
            deepThinking: deepThinking,
            retryable: true,
          ),
        );
      });
      return;
    }
    setState(() {
      _sending = false;
      _turns.add(
        ChatTurn.assistant(
          text,
          at: _now,
          thinking: thinking.isEmpty ? null : thinking,
          deepThinking: deepThinking,
        ),
      );
    });
    _persist();
  }

  void _stop() {
    if (!_sending) {
      return;
    }
    unawaited(_subscription?.cancel());
    _draftTimer?.cancel();
    _draftTimer = null;
    final String text = _draft.trim();
    final String thinking = _clipThinking(_thinkingDraft);
    _draft = '';
    _thinkingDraft = '';
    setState(() {
      _sending = false;
      if (text.isNotEmpty || thinking.isNotEmpty) {
        _turns.add(
          ChatTurn(
            role: ChatRole.assistant,
            text: text.isEmpty ? '（已停止生成）' : '$text\n\n（已停止生成）',
            at: _now,
            thinking: thinking.isEmpty ? null : thinking,
            deepThinking: _lastDeepThinking,
          ),
        );
      }
    });
    _persist();
  }

  void _retry() {
    final String? text = _lastUserText;
    if (text == null || _busy) {
      return;
    }
    _startStream(text, addUserTurn: false, deepThinking: _lastDeepThinking);
  }

  // ── 快捷动作 ──────────────────────────────────────────────────────

  Future<void> _runQuick(AiQuickAction action) async {
    if (_busy) {
      return;
    }
    if (!_configured) {
      _openConfig();
      return;
    }
    if (widget.onQuick == null) {
      _notice('AI 快捷动作还没接上。');
      return;
    }
    if (action == AiQuickAction.grade &&
        !_hasAnswerImage &&
        !widget.hasStudentAnswer) {
      _notice('这道题还没有可判的作答：先在答题卡写，或展开「答题情况」识别一下。');
      return;
    }
    final String userText = switch (action) {
      AiQuickAction.explain => '请先讲这道题：考什么、关键步骤、最后结论。',
      AiQuickAction.solve => '先做一遍这道题，给我最终答案和解析。',
      AiQuickAction.grade => '帮我判一下这道作答：对、错，还是拿不准？',
    };
    if (action == AiQuickAction.explain) {
      _startStream(userText, addUserTurn: true, deepThinking: _deepThinking);
      return;
    }
    setState(() {
      _quickBusy = true;
      _turns.add(
        ChatTurn.user(userText, at: _now, imageCount: _attachments.length),
      );
    });
    _persist();
    _scrollToEnd(force: true);
    try {
      final AiChatResult? result = await widget.onQuick!(
        action,
        List<AiImageAttachment>.of(_attachments),
      );
      if (!mounted) {
        return;
      }
      if (result == null) {
        setState(() {
          _quickBusy = false;
          _turns.add(ChatTurn.error('这次没有拿到 AI 结果，请再试一次。', at: _now));
        });
        return;
      }
      setState(() {
        _quickBusy = false;
        if (action == AiQuickAction.solve) {
          final AiSolution? solution = result.solution;
          _turns.add(
            ChatTurn(
              role: ChatRole.assistant,
              text: result.text,
              at: _now,
              kind: ChatTurnKind.answer,
              referenceAnswer: solution?.answer,
            ),
          );
        } else {
          _turns.add(
            ChatTurn(
              role: ChatRole.assistant,
              text: result.text,
              at: _now,
              kind: ChatTurnKind.verdict,
              verdict: result.grade?.verdict,
              applied: result.applied,
              fromText: result.fromText,
            ),
          );
        }
      });
      _persist();
      _scrollToEnd(force: true);
    } on Object catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _quickBusy = false;
        _turns.add(
          ChatTurn.error(
            error is AiFailure ? error.message : 'AI 调用失败：$error',
            at: _now,
          ),
        );
      });
      _scrollToEnd(force: true);
    }
  }

  bool get _hasAnswerImage => _attachments.any(
    (AiImageAttachment item) => item.kind == AiImageKind.answer,
  );

  // ── 附件 ──────────────────────────────────────────────────────────

  Future<void> _addImage() async {
    if (_attachments.length >= kMaxChatAttachments) {
      _notice('最多附 $kMaxChatAttachments 张图。先移除一张再加。');
      return;
    }
    final Future<AiImageAttachment?> Function()? pick = widget.onPickImage;
    final AiImageAttachment? picked = pick == null
        ? await pickAiImageFromDevice(label: '图片 ${_attachments.length + 1}')
        : await pick();
    if (picked == null || !mounted) {
      return;
    }
    setState(() => _attachments.add(picked));
  }

  void _removeImage(int index) {
    if (index < 0 || index >= _attachments.length) {
      return;
    }
    setState(() => _attachments.removeAt(index));
  }

  void _previewImage(AiImageAttachment image) {
    final double aspect = image.width > 0 && image.height > 0
        ? image.width / image.height
        : 4 / 3;
    unawaited(
      showImageViewer(
        context,
        title: image.label,
        aspectRatio: aspect,
        builder: (BuildContext context, Size size) => Image.memory(
          image.bytes,
          fit: BoxFit.contain,
          gaplessPlayback: true,
        ),
      ),
    );
  }

  // ── 其它动作 ──────────────────────────────────────────────────────

  void _openConfig() {
    final VoidCallback? open = widget.onOpenConfig;
    if (open != null) {
      open();
    } else {
      _notice('去「设置 → AI 分析 → AI 配置」填写端点和 Key。');
    }
  }

  void _notice(String message) {
    setState(() {
      _turns.add(
        ChatTurn(
          role: ChatRole.assistant,
          text: message,
          at: _now,
          kind: ChatTurnKind.notice,
          failed: true,
        ),
      );
    });
    _scrollToEnd(force: true);
  }

  Future<void> _copy(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) {
      return;
    }
    final ScaffoldMessengerState? messenger = ScaffoldMessenger.maybeOf(
      context,
    );
    messenger
      ?..hideCurrentSnackBar()
      ..showSnackBar(
        const SnackBar(
          content: Text('已复制'),
          duration: Duration(milliseconds: 1200),
          behavior: SnackBarBehavior.floating,
        ),
      );
  }

  Future<void> _clearConversation() async {
    if (_busy) {
      _notice('等这次回答结束再清空。');
      return;
    }
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('清空对话？'),
        content: const Text('只清空这一题的聊天记录；已生成的答案与判题不受影响。'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) {
      return;
    }
    setState(() {
      _turns.clear();
      _draft = '';
    });
    _persist();
  }

  int get _now => DateTime.now().millisecondsSinceEpoch;

  String _clipThinking(String raw) {
    final String text = raw.trim();
    if (text.length <= 6000) {
      return text;
    }
    return '${text.substring(0, 6000)}\n…（思考过程已截断）';
  }

  // ── 构建 ──────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final double bubbleMaxWidth = (widget.width - ShqSpace.lg * 2).clamp(
      200,
      760,
    );
    return Material(
      color: scheme.surfaceContainerLow,
      child: SizedBox(
        width: widget.width,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            _Header(
              payload: widget.payload,
              modelLabel: _configured ? widget.config.model : '未配置',
              configured: _configured,
              onBack: widget.onBack,
              onClose: widget.onClose,
              onConfig: _openConfig,
              onClear: _clearConversation,
            ),
            Divider(height: 1, color: scheme.outlineVariant),
            Expanded(
              child: ListView(
                controller: _scroll,
                padding: const EdgeInsets.fromLTRB(
                  ShqSpace.lg,
                  ShqSpace.sm,
                  ShqSpace.lg,
                  ShqSpace.md,
                ),
                children: <Widget>[
                  if (!_configured)
                    _SetupCard(onTap: _openConfig)
                  else if (_turns.isEmpty)
                    _IntroCard(referenceAnswer: widget.referenceAnswer),
                  const SizedBox(height: ShqSpace.sm),
                  _QuickActions(
                    enabled: _configured && !_busy,
                    canGrade:
                        _configured &&
                        !_busy &&
                        (widget.hasStudentAnswer || _hasAnswerImage),
                    onExplain: () => _runQuick(AiQuickAction.explain),
                    onSolve: () => _runQuick(AiQuickAction.solve),
                    onGrade: () => _runQuick(AiQuickAction.grade),
                  ),
                  for (final ChatTurn turn in _turns) ...<Widget>[
                    const SizedBox(height: ShqSpace.sm),
                    _Bubble(
                      turn: turn,
                      maxWidth: bubbleMaxWidth,
                      onCopy: () => unawaited(_copy(turn.text)),
                      onRetry: turn.retryable ? _retry : null,
                    ),
                  ],
                  if (_sending) ...<Widget>[
                    const SizedBox(height: ShqSpace.sm),
                    _StreamingBubble(
                      text: _draft,
                      thinking: _thinkingDraft,
                      deepThinking: _lastDeepThinking,
                      maxWidth: bubbleMaxWidth,
                      onStop: _stop,
                    ),
                  ],
                  if (_quickBusy) ...<Widget>[
                    const SizedBox(height: ShqSpace.sm),
                    const _Typing(label: 'AI 正在处理'),
                  ],
                ],
              ),
            ),
            _Composer(
              controller: _input,
              configured: _configured,
              sending: _sending,
              deepThinking: _deepThinking,
              onToggleDeepThinking: () =>
                  setState(() => _deepThinking = !_deepThinking),
              attachments: _attachments,
              onPreviewImage: _previewImage,
              onRemoveImage: _removeImage,
              onAddImage: () => unawaited(_addImage()),
              canAddImage: _attachments.length < kMaxChatAttachments,
              canSend: !_busy,
              onSend: () => unawaited(_send()),
              onStop: _stop,
              onConfig: _openConfig,
            ),
          ],
        ),
      ),
    );
  }
}

// ── 头部 ────────────────────────────────────────────────────────────

class _Header extends StatelessWidget {
  const _Header({
    required this.payload,
    required this.modelLabel,
    required this.configured,
    this.onBack,
    required this.onClose,
    required this.onConfig,
    required this.onClear,
  });

  final QuestionAiPayload payload;
  final String modelLabel;
  final bool configured;
  final VoidCallback? onBack;
  final VoidCallback onClose;
  final VoidCallback onConfig;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        ShqSpace.xs,
        ShqSpace.xs,
        ShqSpace.xs,
        0,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              if (onBack != null)
                IconButton(
                  onPressed: onBack,
                  tooltip: '返回题目区域',
                  iconSize: 20,
                  icon: const Icon(Icons.arrow_back),
                ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        Text('问 AI', style: theme.textTheme.titleSmall),
                        const SizedBox(width: ShqSpace.sm),
                        Flexible(
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 1,
                            ),
                            decoration: BoxDecoration(
                              color: configured
                                  ? scheme.secondaryContainer
                                  : scheme.surfaceContainerHigh,
                              borderRadius: BorderRadius.circular(
                                ShqRadius.pill,
                              ),
                            ),
                            child: Text(
                              configured ? modelLabel : '未配置',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: configured
                                    ? scheme.onSecondaryContainer
                                    : scheme.outline,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 1),
                    Text(
                      '第 ${payload.pageIndex + 1} 页 · 题号 ${payload.label}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: scheme.outline,
                      ),
                    ),
                  ],
                ),
              ),
              PopupMenuButton<String>(
                tooltip: '更多',
                iconSize: 20,
                padding: EdgeInsets.zero,
                onSelected: (String value) {
                  if (value == 'config') {
                    onConfig();
                  } else if (value == 'clear') {
                    onClear();
                  }
                },
                itemBuilder: (BuildContext context) =>
                    const <PopupMenuEntry<String>>[
                      PopupMenuItem<String>(
                        value: 'config',
                        child: Row(
                          children: <Widget>[
                            Icon(Icons.tune, size: 18),
                            SizedBox(width: ShqSpace.sm),
                            Text('AI 配置'),
                          ],
                        ),
                      ),
                      PopupMenuItem<String>(
                        value: 'clear',
                        child: Row(
                          children: <Widget>[
                            Icon(Icons.delete_sweep_outlined, size: 18),
                            SizedBox(width: ShqSpace.sm),
                            Text('清空对话'),
                          ],
                        ),
                      ),
                    ],
              ),
              IconButton(
                onPressed: onClose,
                tooltip: '收起面板',
                iconSize: 20,
                icon: const Icon(Icons.close),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              ShqSpace.lg,
              0,
              ShqSpace.lg,
              ShqSpace.sm,
            ),
            child: Text(
              '题面图片是权威来源；AI 的答案与判题都会标「请自检」。',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall?.copyWith(
                color: scheme.outline,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ── 附件条 ──────────────────────────────────────────────────────────

class _AttachmentStrip extends StatelessWidget {
  const _AttachmentStrip({
    required this.attachments,
    required this.onPreview,
    required this.onRemove,
    required this.onAdd,
  });

  final List<AiImageAttachment> attachments;
  final void Function(AiImageAttachment image) onPreview;
  final void Function(int index) onRemove;
  final VoidCallback? onAdd;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Icon(Icons.attach_file, size: 14, color: scheme.onSurfaceVariant),
            const SizedBox(width: 4),
            Expanded(
              child: Text(
                attachments.isEmpty
                    ? '这次没有附图（题面图可能取不到）'
                    : '将发送 ${attachments.length}/$kMaxChatAttachments 张图',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: ShqSpace.xs),
        SizedBox(
          height: 76,
          child: ListView(
            scrollDirection: Axis.horizontal,
            children: <Widget>[
              for (int i = 0; i < attachments.length; i++) ...<Widget>[
                _AttachmentTile(
                  image: attachments[i],
                  onTap: () => onPreview(attachments[i]),
                  onRemove: () => onRemove(i),
                ),
                const SizedBox(width: ShqSpace.sm),
              ],
              if (onAdd != null)
                _AddAttachmentTile(onTap: onAdd!)
              else
                Center(
                  child: Text(
                    '已达上限',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.outline,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _AttachmentTile extends StatelessWidget {
  const _AttachmentTile({
    required this.image,
    required this.onTap,
    required this.onRemove,
  });

  final AiImageAttachment image;
  final VoidCallback onTap;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final Color accent = switch (image.kind) {
      AiImageKind.question => scheme.primary,
      AiImageKind.answer => ShqRegion.answer,
      AiImageKind.user => scheme.tertiary,
    };
    return SizedBox(
      width: 104,
      child: Stack(
        clipBehavior: Clip.none,
        children: <Widget>[
          GestureDetector(
            onTap: onTap,
            child: Container(
              height: 76,
              decoration: BoxDecoration(
                color: scheme.surfaceContainer,
                borderRadius: BorderRadius.circular(ShqRadius.sm),
                border: Border.all(color: scheme.outlineVariant),
              ),
              clipBehavior: Clip.antiAlias,
              child: Stack(
                fit: StackFit.expand,
                children: <Widget>[
                  Image.memory(
                    image.bytes,
                    fit: BoxFit.cover,
                    gaplessPlayback: true,
                  ),
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 5,
                        vertical: 2,
                      ),
                      color: Colors.black.withValues(alpha: 0.55),
                      child: Text(
                        image.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: Colors.white,
                          fontSize: ShqType.caption - 1,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          Positioned(
            top: 2,
            right: 2,
            child: Material(
              color: accent,
              shape: const CircleBorder(),
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: onRemove,
                child: const Padding(
                  padding: EdgeInsets.all(3),
                  child: Icon(Icons.close, size: 12, color: Colors.white),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _AddAttachmentTile extends StatelessWidget {
  const _AddAttachmentTile({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(ShqRadius.sm),
      child: Container(
        width: 76,
        height: 76,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(ShqRadius.sm),
          border: Border.all(color: scheme.outlineVariant),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            Icon(
              Icons.add_photo_alternate_outlined,
              size: 20,
              color: scheme.primary,
            ),
            const SizedBox(height: 3),
            Text(
              '添加图片',
              style: Theme.of(context).textTheme.labelSmall
                  ?.copyWith(color: scheme.primary),
            ),
          ],
        ),
      ),
    );
  }
}

// ── 空态 / 快捷动作 ─────────────────────────────────────────────────

class _SetupCard extends StatelessWidget {
  const _SetupCard({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.all(ShqSpace.md),
      decoration: BoxDecoration(
        color: scheme.secondaryContainer.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(ShqRadius.md),
        border: Border.all(color: scheme.primary.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(Icons.auto_awesome, size: 16, color: scheme.primary),
              const SizedBox(width: 6),
              Expanded(
                child: Text('还没有配置 AI', style: theme.textTheme.titleSmall),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '填一个 OpenAI 兼容端点、Key 和模型名，就能对着这道题聊天、'
            '让 AI 先做一遍、或判你的作答。',
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
              height: 1.45,
            ),
          ),
          const SizedBox(height: ShqSpace.sm),
          FilledButton.icon(
            onPressed: onTap,
            icon: const Icon(Icons.tune, size: 16),
            label: const Text('去配置'),
            style: FilledButton.styleFrom(minimumSize: const Size(0, 38)),
          ),
        ],
      ),
    );
  }
}

class _IntroCard extends StatelessWidget {
  const _IntroCard({this.referenceAnswer});

  final String? referenceAnswer;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final bool hasRef =
        referenceAnswer != null && referenceAnswer!.trim().isNotEmpty;
    return Container(
      padding: const EdgeInsets.all(ShqSpace.md),
      decoration: BoxDecoration(
        color: scheme.surfaceContainer,
        borderRadius: BorderRadius.circular(ShqRadius.md),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(Icons.auto_awesome, size: 16, color: scheme.onSurfaceVariant),
          const SizedBox(width: ShqSpace.sm),
          Expanded(
            child: Text(
              hasRef
                  ? '已附上题面与参考答案。可以直接问「为什么是这样」，'
                        '也可以让它先做一遍对一下。'
                  : '已附上题面。可以直接问「这题怎么做」，'
                        '也可以让它先做一遍、或判你的作答。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
                height: 1.45,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _QuickActions extends StatelessWidget {
  const _QuickActions({
    required this.enabled,
    required this.canGrade,
    required this.onExplain,
    required this.onSolve,
    required this.onGrade,
  });

  final bool enabled;
  final bool canGrade;
  final VoidCallback onExplain;
  final VoidCallback onSolve;
  final VoidCallback onGrade;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: ShqSpace.sm,
      runSpacing: ShqSpace.sm,
      children: <Widget>[
        _QuickChip(
          icon: Icons.menu_book_outlined,
          label: '讲这道题',
          onTap: enabled ? onExplain : null,
        ),
        _QuickChip(
          icon: Icons.calculate_outlined,
          label: '先做一遍',
          onTap: enabled ? onSolve : null,
        ),
        _QuickChip(
          icon: Icons.fact_check_outlined,
          label: '判我的作答',
          onTap: enabled && canGrade ? onGrade : null,
          hint: canGrade ? null : '先在答题卡写，或展开答题情况识别',
        ),
      ],
    );
  }
}

class _QuickChip extends StatelessWidget {
  const _QuickChip({
    required this.icon,
    required this.label,
    required this.onTap,
    this.hint,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final String? hint;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final bool enabled = onTap != null;
    return Tooltip(
      message: hint ?? label,
      child: ActionChip(
        avatar: Icon(
          icon,
          size: 15,
          color: enabled ? scheme.primary : scheme.outline,
        ),
        label: Text(
          label,
          style: theme.textTheme.labelMedium?.copyWith(
            color: enabled ? scheme.onSurface : scheme.outline,
          ),
        ),
        onPressed: onTap,
        visualDensity: VisualDensity.compact,
      ),
    );
  }
}

// ── 气泡 ────────────────────────────────────────────────────────────

class _Bubble extends StatelessWidget {
  const _Bubble({
    required this.turn,
    required this.onCopy,
    required this.maxWidth,
    this.onRetry,
  });

  final ChatTurn turn;
  final VoidCallback onCopy;
  final double maxWidth;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    if (turn.kind == ChatTurnKind.verdict) {
      return _VerdictBubble(turn: turn, maxWidth: maxWidth, onCopy: onCopy);
    }
    if (turn.kind == ChatTurnKind.answer) {
      return _AnswerBubble(turn: turn, maxWidth: maxWidth, onCopy: onCopy);
    }
    final bool mine = turn.mine;
    final bool error = turn.kind == ChatTurnKind.error;
    final bool notice = turn.kind == ChatTurnKind.notice;
    final Color background = error
        ? scheme.errorContainer.withValues(alpha: 0.55)
        : notice
        ? scheme.surfaceContainerHigh
        : mine
        ? scheme.primary
        : scheme.surfaceContainerHigh;
    final Color foreground = error
        ? scheme.onErrorContainer
        : notice
        ? scheme.onSurfaceVariant
        : mine
        ? scheme.onPrimary
        : scheme.onSurface;
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: BoxConstraints(maxWidth: maxWidth),
        padding: const EdgeInsets.fromLTRB(
          ShqSpace.md,
          ShqSpace.sm,
          ShqSpace.sm,
          ShqSpace.sm,
        ),
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(ShqRadius.md),
            topRight: const Radius.circular(ShqRadius.md),
            bottomLeft: Radius.circular(mine ? ShqRadius.md : ShqRadius.sm),
            bottomRight: Radius.circular(mine ? ShqRadius.sm : ShqRadius.md),
          ),
          border: (mine || error)
              ? null
              : Border.all(color: scheme.outlineVariant),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            if (mine && turn.imageCount > 0) ...<Widget>[
              Row(
                children: <Widget>[
                  Icon(
                    Icons.image_outlined,
                    size: 12,
                    color: foreground.withValues(alpha: 0.8),
                  ),
                  const SizedBox(width: 3),
                  Text(
                    '附 ${turn.imageCount} 张图',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: foreground.withValues(alpha: 0.8),
                      fontSize: ShqType.caption - 1,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 2),
            ],
            if (!mine &&
                (turn.deepThinking ||
                    (turn.thinking != null &&
                        turn.thinking!.trim().isNotEmpty))) ...<Widget>[
              _ThinkingBlock(
                thinking: turn.thinking ?? '',
                deepThinking: turn.deepThinking,
                // 用户要的是"看得到推理"：默认展开；没有 reasoning 时也展开说明原因。
                initiallyExpanded: true,
              ),
              const SizedBox(height: 4),
            ],
            if (mine)
              SelectionArea(
                child: MathText(
                  turn.text,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: foreground,
                    height: 1.55,
                  ),
                ),
              )
            else
              ChatContent(
                turn.text,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: foreground,
                  height: 1.55,
                ),
              ),
            if (!mine) ...<Widget>[
              const SizedBox(height: 2),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  if (onRetry != null)
                    TextButton.icon(
                      onPressed: onRetry,
                      style: TextButton.styleFrom(
                        minimumSize: const Size(0, 28),
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        visualDensity: VisualDensity.compact,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      icon: const Icon(Icons.refresh, size: 14),
                      label: const Text('重试'),
                    ),
                  if (!error && !notice)
                    IconButton(
                      tooltip: '复制',
                      onPressed: onCopy,
                      iconSize: 14,
                      visualDensity: VisualDensity.compact,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints.tightFor(
                        width: 26,
                        height: 26,
                      ),
                      icon: Icon(
                        Icons.copy_all_outlined,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _VerdictBubble extends StatelessWidget {
  const _VerdictBubble({
    required this.turn,
    required this.maxWidth,
    required this.onCopy,
  });

  final ChatTurn turn;
  final double maxWidth;
  final VoidCallback onCopy;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final AnswerVerdict verdict = turn.verdict ?? AnswerVerdict.pending;
    final Color color = _verdictColor(context, verdict);
    final String label = switch (verdict) {
      AnswerVerdict.correct => 'AI 判：对',
      AnswerVerdict.wrong => 'AI 判：错',
      AnswerVerdict.pending => 'AI 判：拿不准',
      AnswerVerdict.none => 'AI 判：未判',
    };
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        constraints: BoxConstraints(maxWidth: maxWidth),
        padding: const EdgeInsets.all(ShqSpace.md),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(ShqRadius.md),
          border: Border.all(color: color.withValues(alpha: 0.35)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(Icons.fact_check_outlined, size: 16, color: color),
                const SizedBox(width: 5),
                Text(
                  label,
                  style: theme.textTheme.titleSmall?.copyWith(color: color),
                ),
                const Spacer(),
                if (turn.fromText)
                  Padding(
                    padding: const EdgeInsets.only(right: ShqSpace.sm),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: ShqPalette.unclear.withValues(alpha: 0.14),
                        borderRadius: BorderRadius.circular(ShqRadius.pill),
                      ),
                      child: Text(
                        '按文字判定 · 请复核',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: ShqPalette.unclear,
                          fontSize: 10,
                        ),
                      ),
                    ),
                  ),
                Text(
                  turn.applied ? '已记入判题' : '未覆盖手改',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: turn.applied ? scheme.outline : scheme.error,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            ChatContent(
              turn.text,
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurface,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 2),
            Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    'AI 结论，可随时三色手改覆盖。',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.outline,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: '复制',
                  onPressed: onCopy,
                  iconSize: 14,
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints.tightFor(
                    width: 26,
                    height: 26,
                  ),
                  icon: Icon(Icons.copy_all_outlined, color: scheme.outline),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _AnswerBubble extends StatelessWidget {
  const _AnswerBubble({
    required this.turn,
    required this.maxWidth,
    required this.onCopy,
  });

  final ChatTurn turn;
  final double maxWidth;
  final VoidCallback onCopy;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final String? answer = turn.referenceAnswer;
    final bool hasAnswer = answer != null && answer.trim().isNotEmpty;
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        constraints: BoxConstraints(maxWidth: maxWidth),
        padding: const EdgeInsets.all(ShqSpace.md),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(ShqRadius.md),
          border: Border.all(color: scheme.outlineVariant),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(Icons.lightbulb_outline, size: 16, color: scheme.primary),
                const SizedBox(width: 5),
                Text('AI 解法', style: theme.textTheme.titleSmall),
                const Spacer(),
                Text(
                  '请自检',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.outline,
                  ),
                ),
              ],
            ),
            if (hasAnswer) ...<Widget>[
              const SizedBox(height: ShqSpace.sm),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: ShqSpace.sm,
                  vertical: ShqSpace.xs,
                ),
                decoration: BoxDecoration(
                  color: scheme.primary.withValues(alpha: 0.07),
                  borderRadius: BorderRadius.circular(ShqRadius.sm),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      '参考答案（AI 补）',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: scheme.primary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    ChatContent(
                      answer,
                      style: theme.textTheme.bodyMedium?.copyWith(height: 1.45),
                    ),
                  ],
                ),
              ),
            ] else ...<Widget>[
              const SizedBox(height: 4),
              Text(
                '这次没有解析出可直接保存的答案，下面只有解析。',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: scheme.outline,
                ),
              ),
            ],
            const SizedBox(height: ShqSpace.sm),
            ChatContent(
              turn.text,
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurface,
                height: 1.55,
              ),
            ),
            const SizedBox(height: 2),
            Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    hasAnswer ? '已写入参考答案（AI 来源）' : '未写入答案库',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.outline,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: '复制',
                  onPressed: onCopy,
                  iconSize: 14,
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints.tightFor(
                    width: 26,
                    height: 26,
                  ),
                  icon: Icon(Icons.copy_all_outlined, color: scheme.outline),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

Color _verdictColor(BuildContext context, AnswerVerdict verdict) {
  final bool dark = Theme.of(context).brightness == Brightness.dark;
  return switch (verdict) {
    AnswerVerdict.correct => dark ? ShqRegion.greenOnDark : ShqRegion.green,
    AnswerVerdict.wrong => dark ? ShqRegion.redOnDark : ShqRegion.red,
    AnswerVerdict.pending => dark ? ShqRegion.yellowOnDark : ShqRegion.yellow,
    AnswerVerdict.none => Theme.of(context).colorScheme.outline,
  };
}

// ── 流式 / 打字中 ───────────────────────────────────────────────────

class _StreamingBubble extends StatelessWidget {
  const _StreamingBubble({
    required this.text,
    required this.thinking,
    required this.deepThinking,
    required this.maxWidth,
    required this.onStop,
  });

  final String text;
  final String thinking;
  final bool deepThinking;
  final double maxWidth;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final bool hasThinking = thinking.trim().isNotEmpty;
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        constraints: BoxConstraints(maxWidth: maxWidth),
        padding: const EdgeInsets.all(ShqSpace.md),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(ShqRadius.md),
          border: Border.all(color: scheme.outlineVariant),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            if (deepThinking || hasThinking) ...<Widget>[
              _ThinkingBlock(
                thinking: thinking,
                deepThinking: deepThinking,
                initiallyExpanded: text.isEmpty,
                streaming: true,
              ),
              const SizedBox(height: 4),
            ],
            if (text.isEmpty)
              _Typing(
                label: hasThinking
                    ? '思考完了，正在组织回答'
                    : deepThinking
                    ? 'AI 正在深度思考'
                    : 'AI 正在回答',
              )
            else ...<Widget>[
              ChatContent(
                '$text▍',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurface,
                  height: 1.55,
                ),
              ),
            ],
            const SizedBox(height: 4),
            Row(
              children: <Widget>[
                const SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(strokeWidth: 1.8),
                ),
                const SizedBox(width: 6),
                Text(
                  '正在生成',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.outline,
                  ),
                ),
                const Spacer(),
                TextButton.icon(
                  onPressed: onStop,
                  style: TextButton.styleFrom(
                    minimumSize: const Size(0, 28),
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    visualDensity: VisualDensity.compact,
                  ),
                  icon: const Icon(Icons.stop_circle_outlined, size: 15),
                  label: const Text('停止'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 思考过程的折叠块。
///
/// 默认在流式"只有思考、还没有正文"时展开；正文出现后保持用户当前选择。
/// 没有 reasoning 但开了深度思考时，也给一句说明，不假装有思考内容。
class _ThinkingBlock extends StatefulWidget {
  const _ThinkingBlock({
    required this.thinking,
    required this.deepThinking,
    this.initiallyExpanded = false,
    this.streaming = false,
  });

  final String thinking;
  final bool deepThinking;
  final bool initiallyExpanded;
  final bool streaming;

  @override
  State<_ThinkingBlock> createState() => _ThinkingBlockState();
}

class _ThinkingBlockState extends State<_ThinkingBlock> {
  late bool _expanded = widget.initiallyExpanded;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final String thinking = widget.thinking.trim();
    final bool hasThinking = thinking.isNotEmpty;
    final String title = hasThinking
        ? widget.streaming
              ? '正在思考…'
              : '思考过程'
        : widget.deepThinking
        ? '深度思考'
        : '思考过程';
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: scheme.surfaceContainer,
        borderRadius: BorderRadius.circular(ShqRadius.sm),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          InkWell(
            onTap: hasThinking
                ? () => setState(() => _expanded = !_expanded)
                : null,
            borderRadius: BorderRadius.circular(ShqRadius.sm),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                ShqSpace.sm,
                ShqSpace.xs,
                ShqSpace.xs,
                ShqSpace.xs,
              ),
              child: Row(
                children: <Widget>[
                  Icon(
                    Icons.psychology,
                    size: 15,
                    color: widget.deepThinking
                        ? scheme.primary
                        : scheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 5),
                  Expanded(
                    child: Text(
                      title,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: widget.deepThinking
                            ? scheme.primary
                            : scheme.onSurfaceVariant,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  if (hasThinking)
                    Icon(
                      _expanded ? Icons.expand_less : Icons.expand_more,
                      size: 16,
                      color: scheme.outline,
                    ),
                ],
              ),
            ),
          ),
          if (!hasThinking)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                ShqSpace.sm,
                0,
                ShqSpace.sm,
                ShqSpace.xs,
              ),
              child: Text(
                widget.streaming
                    ? '模型没有返回推理内容，正在直接回答。'
                    : '这一轮开启过深度思考，但接口没有返回推理内容。\n'
                          'DeepSeek 请用 deepseek-flash / deepseek-v4-pro；'
                          'deepseek-chat 不是推理模型。',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: scheme.outline,
                  height: 1.4,
                ),
              ),
            )
          else if (_expanded)
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 220),
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(
                  ShqSpace.sm,
                  0,
                  ShqSpace.sm,
                  ShqSpace.sm,
                ),
                child: ChatContent(
                  thinking,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                    height: 1.5,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _Typing extends StatelessWidget {
  const _Typing({this.label = 'AI 正在回答'});

  final String label;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: ShqSpace.md,
        vertical: ShqSpace.sm,
      ),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(ShqRadius.md),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: ShqSpace.sm),
          Text(
            label,
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

// ── 输入区 ──────────────────────────────────────────────────────────

class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.configured,
    required this.sending,
    required this.deepThinking,
    required this.onToggleDeepThinking,
    required this.attachments,
    required this.onPreviewImage,
    required this.onRemoveImage,
    required this.canAddImage,
    required this.canSend,
    required this.onSend,
    required this.onStop,
    required this.onAddImage,
    required this.onConfig,
  });

  final TextEditingController controller;
  final bool configured;
  final bool sending;
  final bool deepThinking;
  final VoidCallback onToggleDeepThinking;
  final List<AiImageAttachment> attachments;
  final void Function(AiImageAttachment image) onPreviewImage;
  final void Function(int index) onRemoveImage;
  final bool canAddImage;
  final bool canSend;
  final VoidCallback onSend;
  final VoidCallback onStop;
  final VoidCallback onAddImage;
  final VoidCallback onConfig;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: scheme.outlineVariant)),
        color: scheme.surfaceContainerLow,
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          ShqSpace.md,
          ShqSpace.xs,
          ShqSpace.md,
          ShqSpace.sm,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            // 附件就在输入框正上方：改图/删图不用再滚到会话顶部。
            _AttachmentStrip(
              attachments: attachments,
              onPreview: onPreviewImage,
              onRemove: onRemoveImage,
              onAdd: canAddImage ? onAddImage : null,
            ),
            const SizedBox(height: ShqSpace.xs),
            TextField(
              controller: controller,
              minLines: 1,
              maxLines: 5,
              textInputAction: TextInputAction.newline,
              style: theme.textTheme.bodySmall?.copyWith(height: 1.45),
              decoration: InputDecoration(
                hintText: configured ? '问这道题，比如：这一步为什么不能直接代入？' : '先配置 AI，才能发送',
                isDense: true,
                filled: true,
                fillColor: scheme.surfaceContainerHigh,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(ShqRadius.md),
                  borderSide: BorderSide.none,
                ),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: ShqSpace.md,
                  vertical: ShqSpace.sm,
                ),
              ),
            ),
            const SizedBox(height: ShqSpace.xs),
            Row(
              children: <Widget>[
                Tooltip(
                  message: deepThinking
                      ? '深度思考已开：先推理再回答，耗时/token 可能更高'
                      : '深度思考：先推理再回答；接口支持时显示思考过程',
                  child: FilterChip(
                    avatar: Icon(
                      Icons.psychology,
                      size: 15,
                      color: deepThinking ? scheme.primary : scheme.outline,
                    ),
                    label: Text(
                      '深度思考',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: deepThinking
                            ? scheme.primary
                            : scheme.onSurfaceVariant,
                      ),
                    ),
                    selected: deepThinking,
                    onSelected: configured
                        ? (_) => onToggleDeepThinking()
                        : null,
                    visualDensity: VisualDensity.compact,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    showCheckmark: false,
                  ),
                ),
                const SizedBox(width: ShqSpace.sm),
                Expanded(
                  child: Text(
                    configured
                        ? '${attachments.isNotEmpty ? '附 ${attachments.length} 张图 · ' : ''}图片随每条消息发送'
                        : '未配置 · 点右侧按钮去填端点/Key',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.outline,
                    ),
                  ),
                ),
                const SizedBox(width: ShqSpace.sm),
                if (!configured)
                  FilledButton.icon(
                    onPressed: onConfig,
                    icon: const Icon(Icons.tune, size: 16),
                    label: const Text('配置 AI'),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(0, 38),
                    ),
                  )
                else if (sending)
                  OutlinedButton.icon(
                    onPressed: onStop,
                    icon: const Icon(Icons.stop, size: 16),
                    label: const Text('停止'),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(0, 38),
                    ),
                  )
                else
                  ValueListenableBuilder<TextEditingValue>(
                    valueListenable: controller,
                    builder:
                        (
                          BuildContext context,
                          TextEditingValue value,
                          Widget? child,
                        ) {
                          final bool enabled =
                              canSend && value.text.trim().isNotEmpty;
                          return FilledButton.icon(
                            onPressed: enabled ? onSend : null,
                            icon: const Icon(Icons.send, size: 16),
                            label: const Text('发送'),
                            style: FilledButton.styleFrom(
                              minimumSize: const Size(0, 38),
                            ),
                          );
                        },
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
