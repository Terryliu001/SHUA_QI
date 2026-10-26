import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shuaqi/app/answer/answer_paper_store.dart';
import 'package:shuaqi/domain/answer/answer_paper.dart';
import 'package:shuaqi/domain/ink/ink_brush.dart';
import 'package:shuaqi/domain/model/question.dart';
import 'package:shuaqi/domain/model/region_set.dart';
import 'package:shuaqi/domain/model/wb_page.dart';
import 'package:shuaqi/domain/reader/panel_metrics.dart';
import 'package:shuaqi/infra/ink/answer_ink_store.dart';
import 'package:shuaqi/state/ink_providers.dart';
import 'package:shuaqi/state/ink_tool_provider.dart';
import 'package:shuaqi/state/panel_width_provider.dart';
import 'package:shuaqi/state/region_providers.dart';
import 'package:shuaqi/state/ui_prefs_provider.dart';
import 'package:shuaqi/ui/panel/answer_paper_painter.dart';
import 'package:shuaqi/ui/panel/answer_paper_sheet.dart';
import 'package:shuaqi/ui/panel/answer_sheet_ai_panel.dart';
import 'package:shuaqi/ui/panel/panel_resize_handle.dart';
import 'package:shuaqi/ui/panel/question_thumb.dart';
import 'package:shuaqi/ui/reader/ink_layer.dart';
import 'package:shuaqi/ui/reader/ink_toolbar.dart';
import 'package:shuaqi/ui/reader/page_image_cache.dart';
import 'package:shuaqi/ui/theme/tokens.dart';
import 'package:shuaqi/ui/widgets/image_viewer.dart';
import 'package:shuaqi/ui/widgets/labeled_action.dart';
import 'package:shuaqi/ui/widgets/question_capture.dart';

/// 答题卡第二步：**逐题作答**。
///
/// 口径（2026-10-24 用户需求）：
/// - 每道小题一张卡：题面缩略图在上，空白作答区在下；
/// - 作答区是独立画布（虚拟 1000×600pt），笔迹存 `sessions/<sid>/answers/<qid>.sif`，
///   绝不和 PDF 页的 SIF 混——这样"一题内都是该题作答"从数据层就成立；
/// - 复用阅读器同一套 `InkLayer` / 笔刷 / 撤销 / 橡皮；
/// - 逐题按钮切换，不靠横向滑动（滑动会和书写/橡皮抢手势）。
/// 从答题卡带回来的意图。
///
/// 目前只有一种：用户点了顶栏「重框」——要把这道题的**作答区域重新框一下**。
/// 阅读器收到后打开题目区域、选中该题、进入作答框编辑，并给出「返回 / 停留」浮窗。
class AnswerSheetResult {
  const AnswerSheetResult.adjust(this.questionId);

  final String? questionId;
}

Future<AnswerSheetResult?> showAnswerSheetPage(
  BuildContext context, {
  required String workbookId,
  required String sessionId,
  required RegionSet set,
  required List<WbPage> pages,
  required PageImageCache cache,
  bool handTool = true,
  String? initialQuestionId,
}) {
  return Navigator.of(context).push<AnswerSheetResult>(
    MaterialPageRoute<AnswerSheetResult>(
      fullscreenDialog: true,
      builder: (BuildContext context) => AnswerSheetPage(
        workbookId: workbookId,
        sessionId: sessionId,
        set: set,
        pages: pages,
        cache: cache,
        handTool: handTool,
        initialQuestionId: initialQuestionId,
      ),
    ),
  );
}

class AnswerSheetPage extends ConsumerStatefulWidget {
  const AnswerSheetPage({
    super.key,
    required this.workbookId,
    required this.sessionId,
    required this.set,
    required this.pages,
    required this.cache,
    this.handTool = true,
    this.initialQuestionId,
  });

  final String workbookId;
  final String sessionId;
  final RegionSet set;
  final List<WbPage> pages;
  final PageImageCache cache;

  /// 手势模式（与阅读器共用全局偏好）：开 = 手指只平移缩放、笔书写。
  final bool handTool;

  /// 打开时直接定位到这道题（从「答题情况 → 去写」或「重框 → 返回」进来）。
  final String? initialQuestionId;

  @override
  ConsumerState<AnswerSheetPage> createState() => _AnswerSheetPageState();
}

class _AnswerSheetPageState extends ConsumerState<AnswerSheetPage> {

  /// 文字模式（2026-10-26 用户第 15 条）：顶栏动作旁显示功能文字。
  ///
  /// 宽度放不下 6 个带文字的动作就退回纯图标——答题卡顶栏有 7 个入口，
  /// 挤在一起会顶掉标题。
  bool get _showLabels =>
      ref.watch(iconLabelsProvider) &&
      labelsFitWidth(
        width: MediaQuery.sizeOf(context).width,
        actionCount: 6,
      );
  late final PageController _pager;
  int _index = 0;

  /// 当前是这一题的第几张纸（0-based）。多张时底栏有页签。
  int _paperIndex = 0;

  /// 纸张配置（全局默认 + 每题覆盖）。
  AnswerPaperData _papers = AnswerPaperData.empty;
  AnswerPaperStore? _paperStore;
  bool _saving = false;
  bool _questionCollapsed = false;

  /// 问 AI 面板（与收藏重刷同一套：右侧滑入、宽度可拖、全局记住）。
  bool _aiOpen = false;
  double? _dragPanelWidth;
  double _dragStartPanelWidth = 0;

  late final List<QuestionBundle> _questions = _filterQuestions(widget.set);

  static List<QuestionBundle> _filterQuestions(RegionSet set) {
    final List<QuestionBundle> all = <QuestionBundle>[
      for (final QuestionBundle bundle in set.questions)
        if (bundle.slices.isNotEmpty) bundle,
    ];
    final List<QuestionBundle> subs = <QuestionBundle>[
      for (final QuestionBundle bundle in all)
        if (bundle.question.level > 1) bundle,
    ];
    return subs.isEmpty ? all : subs;
  }

  QuestionBundle? get _current =>
      _questions.isEmpty ? null : _questions[_index];

  String _sessionIdOf(QuestionBundle bundle) =>
      answerInkSessionId(widget.sessionId, bundle.question.id);

  InkPageKey _inkKeyOf(QuestionBundle bundle) => InkPageKey(
    _sessionIdOf(bundle),
    _paperIndex,
    workbookId: widget.workbookId,
  );

  AnswerPaper _paperFor(QuestionBundle bundle) =>
      _papers.forQuestion(bundle.question.id);

  @override
  void initState() {
    super.initState();
    // 从"答题情况 → 去写"或"重框 → 返回"进来时，直接落在这一题上，
    // 而不是又从第 1 题开始（用户第 2 条：没有准确跳转到对应的答题区域）。
    final String? target = widget.initialQuestionId;
    if (target != null) {
      final int found = _questions.indexWhere(
        (QuestionBundle b) => b.question.id == target,
      );
      if (found >= 0) {
        _index = found;
      }
    }
    _pager = PageController(initialPage: _index);
    unawaited(_loadPapers());
  }

  Future<void> _loadPapers() async {
    final AnswerPaperStore store = AnswerPaperStore(
      ref.read(layoutStoreProvider),
    );
    final AnswerPaperData data = await store.load(widget.workbookId);
    if (!mounted) {
      return;
    }
    setState(() {
      _paperStore = store;
      _papers = data;
    });
  }

  /// 打开「纸张」浮层（尺寸 / 方向 / 张数 / 纸样式）。
  Future<void> _openPaperSheet() async {
    final QuestionBundle? bundle = _current;
    if (bundle == null) {
      return;
    }
    final AnswerPaperChange? change = await showAnswerPaperSheet(
      context,
      current: _paperFor(bundle),
      questionLabel: bundle.question.label ?? '${bundle.question.ordinal}',
    );
    if (change == null || !mounted) {
      return;
    }
    await _applyPaper(bundle, change);
  }

  Future<void> _applyPaper(
    QuestionBundle bundle,
    AnswerPaperChange change,
  ) async {
    final AnswerPaperStore? store = _paperStore;
    if (store == null) {
      return;
    }
    // 先把待写的笔迹落盘，再换配置——否则重载时会把刚写的一笔丢掉。
    await _flushCurrent();
    final AnswerPaperData next = change.applyAll
        ? _papers.withDefault(change.paper)
        : _papers.withQuestion(bundle.question.id, change.paper);
    if (!mounted) {
      return;
    }
    setState(() {
      _papers = next;
      _paperIndex = _paperIndex.clamp(0, change.paper.pages - 1);
    });
    await store.save(widget.workbookId, next);
    AnswerInkStore.invalidatePaperCache(widget.workbookId);
    if (!mounted) {
      return;
    }
    // 尺寸/张数变了：按新纸张重读一遍笔迹（store 会把旧坐标等比搬过去）。
    final InkPageKey key = _inkKeyOf(bundle);
    ref.invalidate(inkStoreForKeyProvider(key));
    ref.invalidate(inkEditProvider(key));
  }

  void _stepPaper(int delta) {
    final QuestionBundle? bundle = _current;
    if (bundle == null) {
      return;
    }
    _setPaperIndex(_paperIndex + delta);
  }

  /// 最后一页的「＋」：加一张并立即跳过去（上限 [AnswerPaper.maxPages]，不提示）。
  ///
  /// 只改张数、不改尺寸，所以不用重载笔迹（`_applyPaper` 那套是换纸张才需要的）。
  Future<void> _addPaper() async {
    final QuestionBundle? bundle = _current;
    final AnswerPaperStore? store = _paperStore;
    if (bundle == null || store == null) {
      return;
    }
    final AnswerPaper paper = _paperFor(bundle);
    if (paper.pages >= AnswerPaper.maxPages) {
      return;
    }
    await _flushCurrent();
    if (!mounted) {
      return;
    }
    final AnswerPaper next = paper.copyWith(pages: paper.pages + 1);
    final AnswerPaperData data = _papers.withQuestion(bundle.question.id, next);
    setState(() {
      _papers = data;
      _paperIndex = next.pages - 1;
    });
    await store.save(widget.workbookId, data);
  }

  void _setPaperIndex(int value) {
    final QuestionBundle? bundle = _current;
    if (bundle == null) {
      return;
    }
    final int pages = _paperFor(bundle).pages;
    if (value < 0 || value >= pages) {
      return;
    }
    unawaited(_flushCurrent());
    setState(() => _paperIndex = value);
  }

  @override
  void dispose() {
    _pager.dispose();
    super.dispose();
  }

  Future<void> _flushCurrent() async {
    final QuestionBundle? bundle = _current;
    if (bundle == null) {
      return;
    }
    await ref.read(inkEditProvider(_inkKeyOf(bundle)).notifier).flushSave();
  }

  Future<void> _goTo(int index, {bool animate = true}) async {
    if (index < 0 || index >= _questions.length || index == _index) {
      return;
    }
    // 离开当前题：立即落盘，不等 500ms 防抖（用户可能马上去写下一题）。
    await ref
        .read(inkEditProvider(_inkKeyOf(_questions[_index])).notifier)
        .flushSave();
    if (!mounted) {
      return;
    }
    setState(() {
      _index = index;
      _paperIndex = 0;
    });
    if (animate) {
      await _pager.animateToPage(
        index,
        duration: ShqMotion.base,
        curve: ShqMotion.curveStandard,
      );
    } else {
      _pager.jumpToPage(index);
    }
  }

  Future<void> _save() async {
    if (_saving) {
      return;
    }
    setState(() => _saving = true);
    try {
      await _flushCurrent();
      if (mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            const SnackBar(
              content: Text('答题卡已保存'),
              duration: Duration(milliseconds: 1600),
              behavior: SnackBarBehavior.floating,
            ),
          );
      }
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  void _toast(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          duration: const Duration(seconds: 3),
          behavior: SnackBarBehavior.floating,
        ),
      );
  }

  void _close() {
    unawaited(_flushCurrent());
    Navigator.of(context).pop();
  }

  /// 「重框」：先落盘，再把意图带回阅读器（由它打开题目区域选中该题）。
  void _requestAdjust(QuestionBundle bundle) {
    unawaited(_flushCurrent());
    Navigator.of(context).pop(AnswerSheetResult.adjust(bundle.question.id));
  }

  @override
  Widget build(BuildContext context) {
    final QuestionBundle? current = _current;
    final InkPageKey? key = current == null ? null : _inkKeyOf(current);
    final InkEditState? edit = key == null
        ? null
        : ref.watch(inkEditProvider(key));
    final bool pinned = ref.watch(inkToolbarPinnedProvider);
    ref.watch(panelWidthProvider);
    final double panelWidth = _aiOpen && current != null
        ? _panelWidth(context)
        : 0;
    return PopScope(
      // canPop:true 时页面立即退出；在回调里再 flush，writer 仍存活，能完成写入。
      canPop: true,
      onPopInvokedWithResult: (bool didPop, Object? result) {
        if (didPop) {
          unawaited(_flushCurrent());
        }
      },
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            tooltip: '返回阅读器',
            onPressed: _close,
            icon: const Icon(Icons.close),
          ),
          title: Text(
            current == null
                ? '答题卡'
                : '答题卡 · ${_index + 1}/${_questions.length}',
          ),
          actions: <Widget>[
            IconButton.filledTonal(
              tooltip: _aiOpen ? '收起 AI' : '问 AI',
              isSelected: _aiOpen,
              icon: const Icon(Icons.auto_awesome_outlined),
              selectedIcon: const Icon(Icons.auto_awesome),
              onPressed: current == null
                  ? null
                  : () => setState(() => _aiOpen = !_aiOpen),
            ),
            LabeledAction(
              icon: Icons.undo,
              label: '撤销',
              tooltip: '撤销',
              showLabel: _showLabels,
              onPressed: edit?.canUndo == true
                  ? () => ref.read(inkEditProvider(key!).notifier).undo()
                  : null,
            ),
            LabeledAction(
              icon: Icons.redo,
              label: '重做',
              tooltip: '重做',
              showLabel: _showLabels,
              onPressed: edit?.canRedo == true
                  ? () => ref.read(inkEditProvider(key!).notifier).redo()
                  : null,
            ),
            LabeledAction(
              icon: Icons.crop_free,
              label: '重框',
              tooltip: '重框这道题',
              showLabel: _showLabels,
              onPressed: current == null ? null : () => _requestAdjust(current),
            ),
            LabeledAction(
              icon: Icons.description_outlined,
              label: '答题纸',
              tooltip: '答题纸（尺寸 / 张数 / 纸样式）',
              showLabel: _showLabels,
              onPressed: () => unawaited(_openPaperSheet()),
            ),
            LabeledAction(
              icon: Icons.save_outlined,
              label: '保存',
              tooltip: '保存答题卡',
              showLabel: _showLabels,
              onPressed: _saving ? null : _save,
            ),
          ],
          bottom: pinned && current != null
              ? const InkToolStrip(darkPaper: false)
              : null,
        ),
        body: current == null
            ? const Center(child: Text('没有可作答的题目'))
            : Stack(
                children: <Widget>[
                  Positioned.fill(
                    child: AnimatedPadding(
                      duration: ShqMotion.base,
                      curve: ShqMotion.curveStandard,
                      padding: EdgeInsets.only(right: panelWidth),
                      child: Column(
                        children: <Widget>[
                          Expanded(
                            child: PageView.builder(
                              controller: _pager,
                              physics: const NeverScrollableScrollPhysics(),
                              itemCount: _questions.length,
                              itemBuilder: (BuildContext context, int index) {
                                final QuestionBundle bundle = _questions[index];
                                return _AnswerQuestionBody(
                                  bundle: bundle,
                                  cache: widget.cache,
                                  pages: widget.pages,
                                  inkKey: _inkKeyOf(bundle),
                                  paper: _paperFor(bundle),
                                  paperIndex: _paperIndex,
                                  panMode: widget.handTool,
                                  onPaperStep: _stepPaper,
                                  onAddPaper: () => unawaited(_addPaper()),
                                  pageLabel:
                                      '第 ${index + 1} / ${_questions.length} 题',
                                  questionCollapsed: _questionCollapsed,
                                  onToggleQuestion: () => setState(
                                    () =>
                                        _questionCollapsed = !_questionCollapsed,
                                  ),
                                );
                              },
                            ),
                          ),
                          _AnswerBottomBar(
                            count: _questions.length,
                            index: _index,
                            labels: <String>[
                              for (final QuestionBundle bundle in _questions)
                                bundle.question.label ??
                                    '${bundle.question.ordinal}',
                            ],
                            onSelected: (int index) => unawaited(_goTo(index)),
                            onPrevious: _index > 0
                                ? () => unawaited(_goTo(_index - 1))
                                : null,
                            onNext: _index < _questions.length - 1
                                ? () => unawaited(_goTo(_index + 1))
                                : null,
                          ),
                        ],
                      ),
                    ),
                  ),
                  if (_aiOpen)
                    Positioned(
                      top: 0,
                      bottom: 0,
                      right: 0,
                      width: panelWidth,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          boxShadow: <BoxShadow>[
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.12),
                              blurRadius: 22,
                              offset: const Offset(-3, 0),
                            ),
                          ],
                        ),
                        child: AnswerSheetAiPanel(
                          key: ValueKey<String>(
                            'sheet-ai-${current.question.id}',
                          ),
                          workbookId: widget.workbookId,
                          sessionId: _sessionIdOf(current),
                          bundle: current,
                          set: widget.set,
                          pages: widget.pages,
                          cache: widget.cache,
                          paper: _paperFor(current),
                          width: panelWidth,
                          onClose: () => setState(() => _aiOpen = false),
                          onGraded: () => _toast('AI 已记入判题'),
                        ),
                      ),
                    ),
                  if (_aiOpen)
                    Positioned(
                      top: 0,
                      bottom: 0,
                      right: panelWidth - 14,
                      width: 28,
                      child: PanelResizeHandle(
                        onResizeStart: _onPanelResizeStart,
                        onResize: _onPanelResize,
                        onResizeEnd: _onPanelResizeEnd,
                      ),
                    ),
                ],
              ),
        floatingActionButton: !pinned && current != null && !_aiOpen
            ? const InkFab(darkPaper: false)
            : null,
      ),
    );
  }

  double _panelWidth(BuildContext context) {
    final double screen = MediaQuery.sizeOf(context).width;
    final double stored =
        _dragPanelWidth ??
        ref.read(panelWidthProvider) ??
        PanelMetrics.defaultFor(screen);
    return PanelMetrics.clampWidth(stored, screen);
  }

  void _onPanelResizeStart() {
    _dragStartPanelWidth = _panelWidth(context);
    setState(() => _dragPanelWidth = _dragStartPanelWidth);
  }

  void _onPanelResize(double totalGrow) {
    final double screen = MediaQuery.sizeOf(context).width;
    setState(() {
      _dragPanelWidth = PanelMetrics.clampWidth(
        _dragStartPanelWidth + totalGrow,
        screen,
      );
    });
  }

  void _onPanelResizeEnd() {
    final double? width = _dragPanelWidth;
    if (width == null) {
      return;
    }
    setState(() => _dragPanelWidth = null);
    ref.read(panelWidthProvider.notifier).commit(width);
  }
}

class _AnswerQuestionBody extends ConsumerStatefulWidget {
  const _AnswerQuestionBody({
    required this.bundle,
    required this.cache,
    required this.pages,
    required this.inkKey,
    required this.paper,
    required this.paperIndex,
    required this.panMode,
    required this.onPaperStep,
    required this.onAddPaper,
    required this.pageLabel,
    required this.questionCollapsed,
    required this.onToggleQuestion,
  });

  final QuestionBundle bundle;
  final PageImageCache cache;
  final List<WbPage> pages;
  final InkPageKey inkKey;
  final AnswerPaper paper;
  final int paperIndex;

  /// 初始是否手势模式（手指不落墨）。
  final bool panMode;

  /// 翻到上一张 / 下一张（+1 / -1）。
  final ValueChanged<int> onPaperStep;

  /// 最后一页的「＋」：加一张并跳过去。
  final VoidCallback onAddPaper;
  final String pageLabel;
  final bool questionCollapsed;
  final VoidCallback onToggleQuestion;

  @override
  ConsumerState<_AnswerQuestionBody> createState() =>
      _AnswerQuestionBodyState();
}

class _AnswerQuestionBodyState extends ConsumerState<_AnswerQuestionBody> {
  /// 长按题面图 → 侧边浮窗（存到相册）。
  ///
  /// 2026-10-26 用户第 13 条：与阅读器里的题面预览同一套交互——
  /// 长按不直接保存，浮窗里说清楚"存哪一种 / 存好了没有"。
  Future<void> _openQuestionImageActions() async {
    final Size screen = MediaQuery.sizeOf(context);
    await showImageActions(
      context,
      anchor: Offset(screen.width, screen.height * 0.42),
      actions: questionImageActions(onSave: _saveQuestionImage),
    );
  }

  /// 题面图存到相册（浮窗里调）。
  Future<String?> _saveQuestionImage() async {
    final QuestionBundle bundle = widget.bundle;
    if (bundle.slices.isEmpty) {
      return '这道题没有题面图';
    }
    final QuestionSlice slice = bundle.slices.first;
    if (slice.pageIndex < 0 || slice.pageIndex >= widget.pages.length) {
      return '题目页无效';
    }
    return saveQuestionImageToGallery(
      cache: widget.cache,
      page: widget.pages[slice.pageIndex],
      rect: slice.rect,
      fileName: questionImageFileName(
        bundle.question.label ?? '${bundle.question.ordinal}',
        bundle.question.id,
      ),
    );
  }


  final TransformationController _zoom = TransformationController();
  late bool _panMode = widget.panMode;

  @override
  void dispose() {
    _zoom.dispose();
    super.dispose();
  }

  void _zoomBy(double factor) {
    final double current = _zoom.value.getMaxScaleOnAxis();
    final double next = (current * factor).clamp(0.8, 4.0);
    _zoom.value = Matrix4.identity()..scaleByDouble(next, next, 1, 1);
  }

  void _fit() {
    _zoom.value = Matrix4.identity();
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final QuestionSlice slice = widget.bundle.slices.first;
    final InkBrush brush = ref.watch(inkToolProvider);
    final bool pageValid =
        slice.pageIndex >= 0 && slice.pageIndex < widget.pages.length;
    return SafeArea(
      top: false,
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints viewport) {
          const double gutter = 12;
          final AnswerPaper paper = widget.paper;
          final double fit = math.max(
            0.1,
            math.min(
              (viewport.maxWidth - gutter * 2) / paper.widthPt,
              (viewport.maxHeight - gutter * 2) / paper.heightPt,
            ),
          );
          final double canvasWidth = paper.widthPt * fit;
          final double canvasHeight = paper.heightPt * fit;
          final bool lastPaper = widget.paperIndex >= widget.paper.pages - 1;
          final bool canAdd =
              lastPaper && widget.paper.pages < AnswerPaper.maxPages;
          // 题面卡**占布局**（不再浮在画布上）：展开/收起时画布自动在剩余区域居中，
          // 不会互相遮挡——用户第 1 条"处理好题目是否展开条件下的显示"。
          return Column(
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
                child: _QuestionFloatCard(
                  bundle: widget.bundle,
                  cache: widget.cache,
                  pages: widget.pages,
                  pageLabel: widget.pageLabel,
                  pageValid: pageValid,
                  collapsed: widget.questionCollapsed,
                  onToggle: widget.onToggleQuestion,
                  onSaveImage: () => unawaited(_openQuestionImageActions()),
                ),
              ),
              Expanded(
                child: Stack(
                  children: <Widget>[
                    Positioned.fill(
                      child: ColoredBox(
                        color: scheme.surfaceContainerLowest,
                        child: InteractiveViewer(
                          transformationController: _zoom,
                          panEnabled: _panMode,
                          scaleEnabled: true,
                          minScale: 0.8,
                          maxScale: 4,
                          boundaryMargin: const EdgeInsets.all(180),
                          child: Center(
                            child: SizedBox(
                              width: canvasWidth,
                              height: canvasHeight,
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  color: ShqPaper.base,
                                  borderRadius: BorderRadius.circular(
                                    ShqRadius.md,
                                  ),
                                  border: Border.all(
                                    color: scheme.outlineVariant,
                                  ),
                                  boxShadow: <BoxShadow>[
                                    BoxShadow(
                                      color: Colors.black.withValues(
                                        alpha: 0.10,
                                      ),
                                      blurRadius: 18,
                                      offset: const Offset(0, 4),
                                    ),
                                  ],
                                ),
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(
                                    ShqRadius.md,
                                  ),
                                  child: Stack(
                                    children: <Widget>[
                                      Positioned.fill(
                                        child: CustomPaint(
                                          painter: AnswerPaperPainter(
                                            color: scheme.outlineVariant
                                                .withValues(alpha: 0.35),
                                            rule: paper.rule,
                                            widthPt: paper.widthPt,
                                            heightPt: paper.heightPt,
                                          ),
                                        ),
                                      ),
                                      Positioned.fill(
                                        child: InkLayer(
                                          inkKey: widget.inkKey,
                                          pageWidthPt: paper.widthPt,
                                          width: canvasWidth,
                                          darkPaper: false,
                                          tool: brush.tool,
                                          colorIndex: brush.colorIndex,
                                          brushWidth: brush.brushWidth,
                                          enabled: !_panMode,
                                          inkTouch: !_panMode,
                                        ),
                                      ),
                                      Positioned(
                                        left: ShqSpace.sm,
                                        top: ShqSpace.xs,
                                        child: IgnorePointer(
                                          child: Text(
                                            _panMode
                                                ? '拖动查看 · 双指缩放'
                                                : '单指书写 · 双指缩放',
                                            style: theme.textTheme.labelSmall
                                                ?.copyWith(
                                                  color: scheme.outline,
                                                ),
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    // 纸张翻页（2026-10-24 第二轮）：左右各一枚，最后一页的右键变「＋」。
                    Positioned(
                      left: 4,
                      top: 0,
                      bottom: 0,
                      child: Center(
                        child: _PaperStepButton(
                          icon: Icons.chevron_left,
                          tooltip: '上一张',
                          onTap: widget.paperIndex > 0
                              ? () => widget.onPaperStep(-1)
                              : null,
                        ),
                      ),
                    ),
                    Positioned(
                      right: 4,
                      top: 0,
                      bottom: 0,
                      child: Center(
                        child: _PaperStepButton(
                          icon: canAdd ? Icons.add : Icons.chevron_right,
                          tooltip: canAdd ? '加一张' : '下一张',
                          highlight: canAdd,
                          onTap: canAdd
                              ? widget.onAddPaper
                              : lastPaper
                              ? null
                              : () => widget.onPaperStep(1),
                        ),
                      ),
                    ),
                    Positioned(
                      right: 10,
                      bottom: 10,
                      child: _CanvasZoomBar(
                        zoom: _zoom,
                        panMode: _panMode,
                        onPanMode: () => setState(() => _panMode = !_panMode),
                        onZoomOut: () => _zoomBy(1 / 1.25),
                        onZoomIn: () => _zoomBy(1.25),
                        onFit: _fit,
                        paperLabel: widget.paper.pages > 1
                            ? '${widget.paperIndex + 1}/${widget.paper.pages}'
                            : null,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// 浮在答题卡上方的题面卡：默认展开，点标题行收起。
class _QuestionFloatCard extends StatelessWidget {
  const _QuestionFloatCard({
    required this.bundle,
    required this.cache,
    required this.pages,
    required this.pageLabel,
    required this.pageValid,
    required this.collapsed,
    required this.onToggle,
    this.onSaveImage,
  });

  final QuestionBundle bundle;
  final PageImageCache cache;
  final List<WbPage> pages;
  final String pageLabel;
  final bool pageValid;
  final bool collapsed;
  final VoidCallback onToggle;

  /// 长按题面图 → 存到相册（null = 不提供这个动作）。
  final VoidCallback? onSaveImage;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final QuestionSlice slice = bundle.slices.first;
    return Material(
      color: scheme.surfaceContainerHigh.withValues(alpha: 0.96),
      elevation: 4,
      borderRadius: BorderRadius.circular(ShqRadius.md),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          InkWell(
            onTap: onToggle,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 6, 8, 6),
              child: Row(
                children: <Widget>[
                  Container(
                    constraints: const BoxConstraints(minWidth: 28),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: ShqRegion.answer.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(ShqRadius.sm),
                    ),
                    child: Text(
                      bundle.question.label ?? '${bundle.question.ordinal}',
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: ShqRegion.answer,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(pageLabel, style: theme.textTheme.labelSmall),
                  const Spacer(),
                  Text(
                    collapsed ? '展开题面' : '收起题面',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.outline,
                    ),
                  ),
                  Icon(
                    collapsed ? Icons.expand_more : Icons.expand_less,
                    size: 19,
                    color: scheme.outline,
                  ),
                ],
              ),
            ),
          ),
          if (!collapsed)
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
              child: SizedBox(
                height: 118,
                width: double.infinity,
                child: pageValid
                    ? LayoutBuilder(
                        builder:
                            (
                              BuildContext context,
                              BoxConstraints constraints,
                            ) => GestureDetector(
                              // 2026-10-26 用户第 13 条：题面图长按也能存图
                              //（与阅读器里的题面预览同一套侧边浮窗）。
                              onLongPress: () => onSaveImage?.call(),
                              child: QuestionThumb(
                                cache: cache,
                                page: pages[slice.pageIndex],
                                rect: slice.rect,
                                width: constraints.maxWidth,
                                height: constraints.maxHeight,
                                paperColor: ShqPaper.base,
                              ),
                            ),
                      )
                    : Center(
                        child: Text('题目页无效', style: theme.textTheme.labelSmall),
                      ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 画布左右两侧的纸张翻页键。
///
/// 右键在"最后一页且还能加"时变成「＋」，语义是"再加一张接着写"，
/// 加不下了（到 9 张）就变灰——界面上不写上限数字（用户第 1 条）。
class _PaperStepButton extends StatelessWidget {
  const _PaperStepButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.highlight = false,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final bool enabled = onTap != null;
    final Color color = !enabled
        ? scheme.outline.withValues(alpha: 0.35)
        : highlight
        ? scheme.primary
        : scheme.onSurfaceVariant;
    return Tooltip(
      message: tooltip,
      child: Material(
        color: scheme.surfaceContainerHigh.withValues(alpha: 0.92),
        shape: const CircleBorder(),
        elevation: enabled ? 2 : 0,
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: SizedBox(
            width: 38,
            height: 38,
            child: Icon(icon, size: 20, color: color),
          ),
        ),
      ),
    );
  }
}

class _CanvasZoomBar extends StatelessWidget {
  const _CanvasZoomBar({
    required this.zoom,
    required this.panMode,
    required this.onPanMode,
    required this.onZoomOut,
    required this.onZoomIn,
    required this.onFit,
    this.paperLabel,
  });

  /// 多张时的「当前/总数」（例如 `2/3`），挂在工具条最右。
  final String? paperLabel;

  final TransformationController zoom;
  final bool panMode;
  final VoidCallback onPanMode;
  final VoidCallback onZoomOut;
  final VoidCallback onZoomIn;
  final VoidCallback onFit;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerHigh.withValues(alpha: 0.94),
      elevation: 2,
      borderRadius: BorderRadius.circular(ShqRadius.pill),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            IconButton(
              tooltip: panMode ? '切回书写' : '拖动/缩放',
              onPressed: onPanMode,
              visualDensity: VisualDensity.compact,
              constraints: const BoxConstraints.tightFor(width: 34, height: 34),
              icon: Icon(
                panMode ? Icons.edit : Icons.pan_tool_alt_outlined,
                size: 18,
                color: panMode ? scheme.primary : scheme.onSurfaceVariant,
              ),
            ),
            IconButton(
              tooltip: '缩小',
              onPressed: onZoomOut,
              visualDensity: VisualDensity.compact,
              constraints: const BoxConstraints.tightFor(width: 32, height: 34),
              icon: const Icon(Icons.remove, size: 18),
            ),
            AnimatedBuilder(
              animation: zoom,
              builder: (BuildContext context, Widget? child) {
                final double scale = zoom.value.getMaxScaleOnAxis();
                return SizedBox(
                  width: 42,
                  child: Text(
                    '${(scale * 100).round()}%',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 11,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                );
              },
            ),
            IconButton(
              tooltip: '放大',
              onPressed: onZoomIn,
              visualDensity: VisualDensity.compact,
              constraints: const BoxConstraints.tightFor(width: 32, height: 34),
              icon: const Icon(Icons.add, size: 18),
            ),
            IconButton(
              tooltip: '适应屏幕',
              onPressed: onFit,
              visualDensity: VisualDensity.compact,
              constraints: const BoxConstraints.tightFor(width: 34, height: 34),
              icon: const Icon(Icons.fit_screen_outlined, size: 18),
            ),
            if (paperLabel != null) ...<Widget>[
              Container(
                margin: const EdgeInsets.symmetric(horizontal: 4),
                width: 1,
                height: 16,
                color: Theme.of(context).colorScheme.outlineVariant,
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Text(
                  paperLabel!,
                  style: TextStyle(
                    fontSize: 11,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 作答纸的纸样式已抽到 `answer_paper_painter.dart`（答题卡与收藏重刷共用）。

class _AnswerBottomBar extends StatelessWidget {
  const _AnswerBottomBar({
    required this.count,
    required this.index,
    required this.labels,
    required this.onSelected,
    required this.onPrevious,
    required this.onNext,
  });

  final int count;
  final int index;
  final List<String> labels;
  final ValueChanged<int> onSelected;
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: scheme.surface,
        border: Border(top: BorderSide(color: scheme.outlineVariant)),
      ),
      padding: const EdgeInsets.fromLTRB(
        ShqSpace.md,
        ShqSpace.xs,
        ShqSpace.md,
        ShqSpace.sm,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Row(
            children: <Widget>[
              IconButton(
                tooltip: '上一题',
                onPressed: onPrevious,
                icon: const Icon(Icons.chevron_left),
              ),
              Expanded(
                child: SizedBox(
                  height: 38,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: count,
                    separatorBuilder: (_, _) => const SizedBox(width: 6),
                    itemBuilder: (BuildContext context, int i) {
                      final bool active = i == index;
                      return InkWell(
                        onTap: () => onSelected(i),
                        borderRadius: BorderRadius.circular(ShqRadius.pill),
                        child: Container(
                          constraints: const BoxConstraints(minWidth: 38),
                          alignment: Alignment.center,
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          decoration: BoxDecoration(
                            color: active
                                ? ShqRegion.answer
                                : scheme.surfaceContainerHigh,
                            borderRadius: BorderRadius.circular(ShqRadius.pill),
                            border: Border.all(
                              color: active
                                  ? ShqRegion.answer
                                  : scheme.outlineVariant,
                            ),
                          ),
                          child: Text(
                            labels[i],
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.labelMedium?.copyWith(
                              color: active
                                  ? scheme.onPrimary
                                  : scheme.onSurfaceVariant,
                              fontWeight: active
                                  ? FontWeight.w600
                                  : FontWeight.w400,
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
              IconButton(
                tooltip: '下一题',
                onPressed: onNext,
                icon: const Icon(Icons.chevron_right),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
