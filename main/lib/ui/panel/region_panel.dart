import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:shuaqi/domain/model/grading.dart';
import 'package:shuaqi/domain/model/question.dart';
import 'package:shuaqi/domain/model/region_set.dart';
import 'package:shuaqi/domain/region/answer.dart';
import 'package:shuaqi/domain/region/math_text.dart';
import 'package:shuaqi/ui/panel/grade_dot.dart';
import 'package:shuaqi/ui/region/region_action.dart';
import 'package:shuaqi/ui/theme/tokens.dart';
import 'package:shuaqi/ui/widgets/labeled_action.dart';
import 'package:shuaqi/ui/widgets/math/math_text.dart';

/// 多选题之后的批量动作：批量收藏 / 批量 AI 判。
///
/// 2026-10-24 第二轮去掉了「批量问 AI」：AI 面板一次只聊一题，
/// 留一个"批量"入口等于骗人；单题问 AI 从「答题情况」卡进。
///
/// 2026-10-26（用户第 7 条）：批量「对答案」换成 **AI 判**——
/// 对答案只跑本地规则（没有识别文本时几乎判不出东西），
/// 而 AI 判会：给缺答案的题**补答案** → 判题 → 把结论写进该题的
/// 「问 AI」对话（用户在那一题里能看到）。
enum RegionPanelBatch { favorite, aiGrade }

/// 题目区域检查面板（T3.5）：右侧 320dp 的列表。
///
/// 设计口径（2026-10-23 用户反馈后收敛）：
/// - **面向用户，不露开发信息**：不再显示置信度百分比、题型"未分类"、三色点
///   与"建议检查"——那些是调算法时看的，放在面板里会误导用户。
/// - **点一下就定位**：点条目 → 跳到那一页并选中那个框；反过来在画布上选中框，
///   面板会自动滚到该题（[_ensureSelectedVisible]）。
/// - **选中就能操作**：选中条目下方展开一行动作（切开 / 并入上题 / 跨页 / 锁定 / 删除），
///   与贴框浮动条是同一批动作。
/// - **不抢画布**：面板是 `AnimatedSlide` 盖在右侧，**不重建**阅读视图。
/// - **给答题卡看板留位**：`dashboard` 槽位在标题与题列表之间；后续把答题卡
///   总览/得分/错题分布接进来时不用再动列表结构。
class RegionPanel extends StatefulWidget {
  const RegionPanel({
    super.key,
    this.showLabels = false,
    required this.set,
    required this.selectedKey,
    required this.onSelect,
    required this.onAdd,
    required this.onUndo,
    required this.onRedo,
    required this.onClearAll,
    required this.onRecut,
    required this.onClose,
    required this.canUndo,
    required this.canRedo,
    required this.editedCount,
    this.questionDelta = 0,
    this.saveTick = 0,
    required this.actionsOf,
    required this.onAction,
    this.dashboard,
    this.preview,
    this.showStemText = true,
    this.answers = AnswerSet.empty,
    this.onFavorite,
    this.onCheckAnswer,
    this.onAskAi,
    this.showAnswers = false,
    this.onToggleShowAnswers,
    this.answerQuestionId,
    this.onToggleAnswer,
    this.answerPanel,
    this.onReorder,
    this.onSave,
    this.saving = false,
    this.onMoveSelected,
    this.onResetOrder,
    this.verdictOf,
    this.counts,
    this.grading = false,
    this.onGradeAll,
    this.onFillAnswers,
    this.fillingAi = false,
    this.fillDone = 0,
    this.fillTotal = 0,
    this.onSetVerdict,
    this.multiSelecting = false,
    this.selectedIds = const <String>{},
    this.favoriteQuestionIds = const <String>{},
    this.onToggleMultiSelect,
    this.onToggleSelect,
    this.onBatch,
    this.width = 320,
  });

  /// **文字模式**（2026-10-26 用户第 15 条）：顶栏动作旁显示功能文字。
  /// 由阅读器页读全局开关后传进来——面板本身是 StatefulWidget，不读 Provider。
  final bool showLabels;

  final RegionSet set;
  final String? selectedKey;

  /// 点条目：父层负责"跳页 + 选中"。
  final ValueChanged<QuestionBundle> onSelect;

  final VoidCallback onAdd;
  final VoidCallback onUndo;
  final VoidCallback onRedo;
  final VoidCallback onClearAll;
  final VoidCallback onRecut;
  final VoidCallback onClose;

  final bool canUndo;
  final bool canRedo;

  /// 覆盖层里累计了多少步操作（0 = 纯自动结果）。
  ///
  /// **只用于"复原"按钮的可用性**，不再显示给用户——操作步数是后台数据。
  /// 给用户看的是 [questionDelta]（题目增减了几道）。
  final int editedCount;

  /// 手改让题目**净增减了几道**（见 `questionDeltaOf`）。
  ///
  /// 只在非 0 时短暂提示，用户点「保存修改」后消失（2026-10-24 口径）。
  final int questionDelta;

  /// 保存动作的序号：每次保存成功 +1，用来把 [questionDelta] 的提示收掉。
  final int saveTick;

  /// 这道题此刻可用的操作（由阅读器判定：有没有上一题、有没有下一页）。
  final Set<RegionAction> Function(QuestionBundle bundle) actionsOf;

  /// 条目内动作的回调。
  final void Function(QuestionBundle bundle, RegionAction action) onAction;

  /// 预留给答题卡看板（后续集成）。null = 不显示。
  final Widget? dashboard;

  /// 当前选中题的**题面预览**（PDF 原图裁切）。null = 没选中 / 拿不到页图。
  final Widget? preview;

  /// 是否显示抽出的题干文字。
  ///
  /// 数学/符号题做不到正确排版时置 false：只给 PDF 题面预览，不拿乱序碎片
  /// 冒充题干（用户 2026-10-23 口径）。
  final bool showStemText;

  /// 文末答案区抽出的答案（label → 文本）。
  final AnswerSet answers;

  /// 「收藏」入口（2026-10-24 由「保存」改名：顶栏的「保存」= 落盘笔迹）。
  final void Function(QuestionBundle bundle)? onFavorite;

  /// 「对答案」入口（同上：先放按钮与位置）。
  final void Function(QuestionBundle bundle)? onCheckAnswer;

  /// 「问 AI」入口（2026-10-24 接入真模型后加回）。
  ///
  /// 为什么不只在「答题情况」卡里：那个卡只对 level>1 的题展开；
  /// 大题/无作答框的题也需要能问 AI。这里用小图标 + 短文案，不抢
  /// 「收藏 / 对答案」的位置。
  final void Function(QuestionBundle bundle)? onAskAi;

  /// 是否在卷面上同步显示所有作答框（紫色虚线）。
  final bool showAnswers;
  final ValueChanged<bool>? onToggleShowAnswers;

  /// 当前展开「答题情况」的题目 id；null = 没有展开。
  final String? answerQuestionId;

  /// 点条目里的「答题情况」：父层负责选中/跳页/切换展开。
  final void Function(QuestionBundle bundle)? onToggleAnswer;

  /// 选中题展开后的答题情况卡（由阅读器组装，面板只负责摆位置）。
  final Widget? answerPanel;

  /// 拖动排序：old/new 是当前展示列表的索引，父层负责落盘。
  final void Function(int oldIndex, int newIndex)? onReorder;

  /// 「保存修改」：落盘切题覆盖层 + 作答框/顺序，父层负责。
  final VoidCallback? onSave;
  final bool saving;

  /// 选中题上移/下移一位（拖动之外的键盘/菜单兜底）。
  final ValueChanged<int>? onMoveSelected;
  final VoidCallback? onResetOrder;

  /// 每道题的判题结论；null = 这个入口不显示判题状态。
  final AnswerVerdict Function(QuestionBundle bundle)? verdictOf;

  /// 底部统计（对/待判/错/未判）；null = 不显示统计条。
  final VerdictCounts? counts;

  /// 「一键改卷」进行中。
  final bool grading;

  final VoidCallback? onGradeAll;

  /// 「AI 判」：本地规则 + 对剩余待判题逐题调用模型。
  /// 「AI 补答案」（工具行第三个键）。
  final VoidCallback? onFillAnswers;

  /// AI 批量判题进行中与进度（按钮文字显示 done/total）。
  /// 「AI 补答案」进行中与进度。
  final bool fillingAi;
  final int fillDone;
  final int fillTotal;

  /// 点状态点手改判题结论。
  final void Function(QuestionBundle bundle, AnswerVerdict verdict)?
  onSetVerdict;

  /// 多选模式：顶部按钮进入，行首出现勾选圈，行点击 = 勾选而不是单选。
  final bool multiSelecting;
  final Set<String> selectedIds;

  /// 已收藏的题目 id：面板据此把「收藏」画成实心星，再点一次取消。
  final Set<String> favoriteQuestionIds;
  final VoidCallback? onToggleMultiSelect;
  final void Function(QuestionBundle bundle)? onToggleSelect;

  /// 批量动作（收藏 / 对答案 / 问 AI）。
  final void Function(RegionPanelBatch action)? onBatch;

  final double width;

  @override
  State<RegionPanel> createState() => _RegionPanelState();
}

class _RegionPanelState extends State<RegionPanel> {
  final ScrollController _scroll = ScrollController();

  /// 列表视口的 key：拖动夹紧要用它的全局矩形（A2，2026-10-24）。
  final GlobalKey _listKey = GlobalKey();

  /// 每行的 GlobalKey（按 anchor key），拖动开始时用它取被拖行的矩形。
  final Map<String, GlobalKey> _rowKeys = <String, GlobalKey>{};

  /// 拖动状态：指针全局 y / 起始指针 y / 起始行顶 / 被拖行高度。
  ///
  /// 只用来把拖影夹在列表视口内——Flutter 的 `ReorderableListView` 把拖影放在
  /// 根 Overlay 里跟手，没有任何边界约束，实测能拖到状态栏上（用户 2026-10-24 报）。
  bool _dragging = false;
  double? _pointerY;
  double _dragStartPointerY = 0;
  double _dragStartTop = 0;
  double _dragRowHeight = 0;

  /// 「手改 +N 道」提示是否可见。默认隐藏；有变化才出现，保存后收掉。
  bool _deltaVisible = false;

  /// 展开的「答题情况」卡。展开后自动滚进视口，避免只露出标题一半。
  final GlobalKey _answerPanelKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    _deltaVisible = widget.questionDelta != 0;
    _ensureSelectedVisible();
  }

  @override
  void didUpdateWidget(covariant RegionPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selectedKey != widget.selectedKey ||
        oldWidget.set != widget.set) {
      _ensureSelectedVisible();
    }
    if (oldWidget.answerQuestionId != widget.answerQuestionId &&
        widget.answerQuestionId != null) {
      _ensureAnswerVisible();
    }
    // 保存成功 = 这条"改了哪几道题"的提示已经完成使命。
    if (oldWidget.saveTick != widget.saveTick) {
      _deltaVisible = false;
    }
    if (oldWidget.questionDelta != widget.questionDelta &&
        widget.questionDelta != 0) {
      _deltaVisible = true;
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  /// 当前选中题的 anchor key（行的 GlobalKey 按它索引）。
  String? get _selectedRowKey => widget.selectedKey;

  GlobalKey _rowKeyFor(String anchorKey) =>
      _rowKeys.putIfAbsent(anchorKey, GlobalKey.new);

  /// 清掉已经不在本次结果里的行 key，避免重切题后无限增长。
  void _pruneRowKeys(List<QuestionBundle> questions) {
    if (_rowKeys.length <= questions.length) {
      return;
    }
    final Set<String> alive = <String>{
      for (final QuestionBundle bundle in questions) bundle.anchorKey,
    };
    _rowKeys.removeWhere((String key, _) => !alive.contains(key));
  }

  /// 拖动开始：记下"起点指针 y / 行顶 / 行高"，用于夹紧拖影。
  ///
  /// 用**相对位移**（行顶 + 指针位移）而不是绝对指针位置：
  /// 指针在行内的落点各不相同，相对量不受影响，也不会因为行内 padding 偏一截。
  /// 长按题目行 → 顺序菜单。
  ///
  /// 2026-10-24 第二轮：顶部那排图标（含顺序菜单）显示异常被撤掉，
  /// 但「上移/下移/恢复自动顺序」是纠错入口，不能丢，挪到行的长按里。
  Future<void> _openOrderMenu(QuestionBundle bundle) async {
    final String? picked = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      backgroundColor: Theme.of(context).colorScheme.surfaceContainerHigh,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(ShqRadius.xl)),
      ),
      builder: (BuildContext context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            ListTile(
              leading: const Icon(Icons.arrow_upward),
              title: const Text('上移一位'),
              onTap: () => Navigator.of(context).pop('up'),
            ),
            ListTile(
              leading: const Icon(Icons.arrow_downward),
              title: const Text('下移一位'),
              onTap: () => Navigator.of(context).pop('down'),
            ),
            ListTile(
              leading: const Icon(Icons.restart_alt),
              title: const Text('恢复自动顺序'),
              subtitle: const Text('清掉手动顺序，回到切题结果的顺序'),
              onTap: () => Navigator.of(context).pop('reset'),
            ),
            const SizedBox(height: ShqSpace.sm),
          ],
        ),
      ),
    );
    if (picked == null || !mounted) {
      return;
    }
    widget.onSelect(bundle);
    if (picked == 'reset') {
      widget.onResetOrder?.call();
    } else {
      widget.onMoveSelected?.call(picked == 'up' ? -1 : 1);
    }
  }

  void _onDragStart(int index, List<QuestionBundle> questions) {
    if (index < 0 || index >= questions.length) {
      return;
    }
    final BuildContext? rowContext =
        _rowKeys[questions[index].anchorKey]?.currentContext;
    final RenderBox? row = rowContext?.findRenderObject() as RenderBox?;
    _dragRowHeight = row?.size.height ?? 56;
    _dragStartTop = row?.localToGlobal(Offset.zero).dy ?? 0;
    _dragStartPointerY = _pointerY ?? _dragStartTop;
    setState(() => _dragging = true);
  }

  /// 拖影要偏移多少才能留在列表视口里（0 = 不用夹，正常跟手）。
  double _proxyClampDelta() {
    if (!_dragging || _pointerY == null) {
      return 0;
    }
    final RenderBox? list =
        _listKey.currentContext?.findRenderObject() as RenderBox?;
    if (list == null) {
      return 0;
    }
    final double listTop = list.localToGlobal(Offset.zero).dy;
    final double listBottom = listTop + list.size.height;
    final double desiredTop = _dragStartTop + (_pointerY! - _dragStartPointerY);
    final double lowest = math.max(listTop, listBottom - _dragRowHeight);
    final double clamped = desiredTop.clamp(listTop, lowest);
    return clamped - desiredTop;
  }

  /// 选中框时把列表滚到那一行（面板打开 / 画布点选都会走到这里）。
  ///
  /// 用 `Scrollable.ensureVisible` 而不是估算偏移：题号胶囊、动作条展开都会
  /// 改变行高，估算必然漂移。列表是 `SingleChildScrollView + Column`（几十行，
  /// 全部构建），所以选中行即使不在视口内也有 context。
  void _ensureSelectedVisible() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final String? key = _selectedRowKey;
      final BuildContext? context = key == null
          ? null
          : _rowKeys[key]?.currentContext;
      if (!mounted || context == null) {
        return;
      }
      Scrollable.ensureVisible(
        context,
        alignment: 0.12,
        duration: ShqMotion.base,
        curve: ShqMotion.curveStandard,
      );
    });
  }

  void _ensureAnswerVisible() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final BuildContext? context = _answerPanelKey.currentContext;
      if (!mounted || context == null) {
        return;
      }
      Scrollable.ensureVisible(
        context,
        alignment: 0.0,
        duration: ShqMotion.base,
        curve: ShqMotion.curveStandard,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final List<QuestionBundle> questions = <QuestionBundle>[
      for (final QuestionBundle bundle in widget.set.questions)
        if (bundle.slices.isNotEmpty) bundle,
    ];
    QuestionBundle? selected;
    for (final QuestionBundle bundle in questions) {
      if (bundle.anchorKey == widget.selectedKey) {
        selected = bundle;
        break;
      }
    }
    _pruneRowKeys(questions);
    final AnswerNote? selectedAnswer = selected == null
        ? null
        : widget.answers.forQuestion(
            ordinal: selected.question.ordinal,
            label: selected.question.label,
          );

    return Material(
      color: scheme.surfaceContainerLow,
      child: SizedBox(
        width: widget.width,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            _Header(
              showLabels: widget.showLabels,
              total: questions.length,
              delta: widget.questionDelta,
              showDelta: _deltaVisible,
              showAnswers: widget.showAnswers,
              onToggleShowAnswers: widget.onToggleShowAnswers,
              onSave: widget.onSave,
              saving: widget.saving,
              onClose: widget.onClose,
            ),
            Divider(height: 1, color: scheme.outlineVariant),
            // 常驻工具行：多选 / 改卷（2026-10-24 第二轮：从底部搬上来，
            // 原来这里的三连动作只在选中后出现，且去掉了「问 AI」——答题情况卡里有入口）。
            //
            // 层级：它**高于**题面预览。多选 / 改卷是"不开着就一直想用"的
            // 能力，题面预览是选中某一题之后才有的上下文，压在上面会把它俩挤下去。
            if (widget.onGradeAll != null ||
                widget.onFillAnswers != null ||
                widget.onToggleMultiSelect != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  ShqSpace.sm,
                  ShqSpace.xs,
                  ShqSpace.sm,
                  0,
                ),
                child: _ToolsBar(
                  multiSelecting: widget.multiSelecting,
                  grading: widget.grading,
                  fillingAi: widget.fillingAi,
                  fillDone: widget.fillDone,
                  fillTotal: widget.fillTotal,
                  onGradeAll: widget.onGradeAll,
                  onFillAnswers: widget.onFillAnswers,
                  onToggleMultiSelect: widget.onToggleMultiSelect,
                ),
              ),
            // 多选的批量条：压在工具栏下方（用户要求"在这行工具栏的下方出现"）。
            if (widget.multiSelecting)
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  ShqSpace.sm,
                  0,
                  ShqSpace.sm,
                  ShqSpace.xxs,
                ),
                child: _BatchBar(
                  selectedCount: widget.selectedIds.length,
                  allFavorited:
                      widget.selectedIds.isNotEmpty &&
                      widget.selectedIds.every(
                        widget.favoriteQuestionIds.contains,
                      ),
                  onBatch: widget.onBatch,
                  onDone: widget.onToggleMultiSelect,
                ),
              ),
            // 选中一道题之后才出现：**题面预览 + 收藏 / 对答案同级**。
            // 这两样是被同一件事（选中某题）唤起的，放在一个块里，
            // 预览不再单独占面板最高的位置。
            if (selected != null && !widget.multiSelecting)
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  ShqSpace.lg,
                  ShqSpace.sm,
                  ShqSpace.lg,
                  ShqSpace.sm,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    if (widget.preview != null) ...<Widget>[
                      widget.preview!,
                      const SizedBox(height: ShqSpace.sm),
                    ],
                    _SelectionActions(
                      favorited: widget.favoriteQuestionIds.contains(
                        selected.question.id,
                      ),
                      onFavorite: widget.onFavorite == null
                          ? null
                          : () => widget.onFavorite!(selected!),
                      onCheckAnswer:
                          widget.onCheckAnswer == null || selectedAnswer == null
                          ? null
                          : () => widget.onCheckAnswer!(selected!),
                      onAskAi: widget.onAskAi == null
                          ? null
                          : () => widget.onAskAi!(selected!),
                    ),
                  ],
                ),
              ),
            Divider(height: 1, color: scheme.outlineVariant),
            if (selected != null &&
                (selectedAnswer != null || !widget.answers.isEmpty))
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  ShqSpace.lg,
                  ShqSpace.sm,
                  ShqSpace.lg,
                  ShqSpace.sm,
                ),
                child: _AnswerCard(
                  answer: selectedAnswer,
                  hasAnyAnswer: !widget.answers.isEmpty,
                ),
              ),
            if (selected != null &&
                (selectedAnswer != null || !widget.answers.isEmpty))
              Divider(height: 1, color: scheme.outlineVariant),
            if (widget.dashboard != null) ...<Widget>[
              widget.dashboard!,
              Divider(height: 1, color: scheme.outlineVariant),
            ],
            Expanded(
              child: questions.isEmpty
                  ? _Empty(onRecut: widget.onRecut)
                  : Listener(
                      // 只记录指针全局 y（夹紧拖影要用），不参与手势竞争、不 setState。
                      onPointerDown: (PointerDownEvent e) =>
                          _pointerY = e.position.dy,
                      onPointerMove: (PointerMoveEvent e) =>
                          _pointerY = e.position.dy,
                      child: ReorderableListView.builder(
                        key: _listKey,
                        scrollController: _scroll,
                        buildDefaultDragHandles: false,
                        padding: const EdgeInsets.symmetric(
                          vertical: ShqSpace.xs,
                        ),
                        itemCount: questions.length,
                        onReorderItem: widget.onReorder ?? (_, _) {},
                        onReorderStart: (int index) =>
                            _onDragStart(index, questions),
                        onReorderEnd: (int index) {
                          if (_dragging) {
                            setState(() => _dragging = false);
                          }
                        },
                        // 拖影默认完全跟手：能拖到列表外的状态栏上（用户 2026-10-24 报）。
                        // 这里按"列表视口"夹紧，越界时贴在视口边缘。
                        //
                        // 注意：框架默认的 proxyDecorator 会包一层 `Material`（抬升起浮感），
                        // 覆盖它必须自己补上——否则行里的 InkWell 会报 "No Material widget found"。
                        proxyDecorator:
                            (
                              Widget child,
                              int index,
                              Animation<double> animation,
                            ) {
                              final double delta = _proxyClampDelta();
                              return Transform.translate(
                                offset: Offset(0, delta),
                                child: Material(
                                  elevation: 6,
                                  color: Theme.of(context)
                                      .colorScheme
                                      .surfaceContainerHigh,
                                  borderRadius: BorderRadius.circular(
                                    ShqRadius.md,
                                  ),
                                  clipBehavior: Clip.antiAlias,
                                  child: child,
                                ),
                              );
                            },
                        itemBuilder: (BuildContext context, int i) {
                          final bool selected =
                              questions[i].anchorKey == widget.selectedKey;
                          return Column(
                            // ReorderableListView 要求每个 item 有稳定 key；
                            // GlobalKey 同时是 ensureVisible / 拖动夹紧的锚点。
                            key: _rowKeyFor(questions[i].anchorKey),
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: <Widget>[
                              _QuestionRow(
                                bundle: questions[i],
                                selected: selected,
                                multiSelecting: widget.multiSelecting,
                                checked: widget.selectedIds.contains(
                                  questions[i].question.id,
                                ),
                                grade: widget.verdictOf?.call(questions[i]),
                                onGrade: widget.onSetVerdict == null
                                    ? null
                                    : (AnswerVerdict verdict) =>
                                          widget.onSetVerdict!(
                                            questions[i],
                                            verdict,
                                          ),
                                showStemText: widget.showStemText,
                                dragHandle:
                                    widget.onReorder == null ||
                                        widget.multiSelecting
                                    ? null
                                    : ReorderableDragStartListener(
                                        index: i,
                                        child: const Padding(
                                          padding: EdgeInsets.only(top: 3),
                                          child: Icon(
                                            Icons.drag_indicator,
                                            size: 16,
                                          ),
                                        ),
                                      ),
                                hasAnswer:
                                    widget.answers.forQuestion(
                                      ordinal: questions[i].question.ordinal,
                                      label: questions[i].question.label,
                                    ) !=
                                    null,
                                answerOpen:
                                    questions[i].question.id ==
                                    widget.answerQuestionId,
                                onToggleAnswer: widget.onToggleAnswer == null
                                    ? null
                                    : () =>
                                          widget.onToggleAnswer!(questions[i]),
                                answerPanel:
                                    questions[i].question.id ==
                                            widget.answerQuestionId &&
                                        widget.answerPanel != null
                                    ? KeyedSubtree(
                                        key: _answerPanelKey,
                                        child: widget.answerPanel!,
                                      )
                                    : null,
                                actions: widget.actionsOf(questions[i]),
                                // 多选模式下点行 = 勾选，不改"当前选中题"（两者是不同状态）。
                                onTap: widget.multiSelecting
                                    ? () => widget.onToggleSelect?.call(
                                        questions[i],
                                      )
                                    : () => widget.onSelect(questions[i]),
                                onLongPress:
                                    widget.onMoveSelected == null &&
                                        widget.onResetOrder == null
                                    ? null
                                    : () => _openOrderMenu(questions[i]),
                                onAction: (RegionAction action) =>
                                    widget.onAction(questions[i], action),
                              ),
                              if (i != questions.length - 1)
                                Divider(
                                  height: 1,
                                  indent: ShqSpace.lg,
                                  endIndent: ShqSpace.lg,
                                  color: scheme.outlineVariant.withValues(
                                    alpha: 0.6,
                                  ),
                                ),
                            ],
                          );
                        },
                      ),
                    ),
            ),
            Divider(height: 1, color: scheme.outlineVariant),
            if (widget.counts != null) ...<Widget>[
              _GradeBar(counts: widget.counts),
              Divider(height: 1, color: scheme.outlineVariant),
            ],
            _Actions(
              canUndo: widget.canUndo,
              canRedo: widget.canRedo,
              editedCount: widget.editedCount,
              onAdd: widget.onAdd,
              onUndo: widget.onUndo,
              onRedo: widget.onRedo,
              onClearAll: widget.onClearAll,
              onRecut: widget.onRecut,
            ),
          ],
        ),
      ),
    );
  }
}

/// 面板顶栏：只剩三个每时每刻都要用的动作。
///
/// 2026-10-24 第二轮用户口径：原来那排「眼睛 / 保存 / 顺序 / 收起」挤在一起显示异常，
/// **标题与顺序菜单都不要**（拖动已经能排序，上移/下移/恢复自动顺序挪到题目行长按里）。
/// 「显示作答框」与「保存修改」保留，因为它们不是"选完题才用"的动作。
class _Header extends StatelessWidget {
  const _Header({
    required this.showLabels,
    required this.total,
    required this.delta,
    required this.showDelta,
    required this.showAnswers,
    required this.onToggleShowAnswers,
    required this.onSave,
    required this.saving,
    required this.onClose,
  });

  /// 文字模式：图标旁显示「作答」「保存」。
  final bool showLabels;

  final int total;
  final int delta;
  final bool showDelta;
  final bool showAnswers;
  final ValueChanged<bool>? onToggleShowAnswers;
  final VoidCallback? onSave;
  final bool saving;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        ShqSpace.md,
        ShqSpace.xs,
        ShqSpace.xxs,
        ShqSpace.xxs,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              // 「题目区域」四个字要保留（2026-10-24 用户纠正：上一版连它一起删掉了）。
              // 它是这一栏的身份，不是"可以省掉的信息"。
              Expanded(
                child: Text(
                  '题目区域',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              if (onToggleShowAnswers != null)
                LabeledAction(
                  icon: showAnswers
                      ? Icons.visibility
                      : Icons.visibility_outlined,
                  label: '作答',
                  tooltip: showAnswers ? '收起作答框' : '显示作答情况',
                  onPressed: () => onToggleShowAnswers!(!showAnswers),
                  selected: showAnswers,
                  showLabel: showLabels,
                  compact: true,
                ),
              if (onSave != null)
                LabeledAction(
                  icon: Icons.save_outlined,
                  label: '保存',
                  tooltip: '保存修改',
                  onPressed: saving ? null : onSave,
                  showLabel: showLabels,
                  compact: true,
                ),
              IconButton(
                onPressed: onClose,
                tooltip: '收起面板',
                iconSize: 20,
                visualDensity: VisualDensity.compact,
                constraints: const BoxConstraints.tightFor(
                  width: 32,
                  height: 32,
                ),
                padding: EdgeInsets.zero,
                icon: const Icon(Icons.close),
              ),
            ],
          ),
          if (showDelta)
            Padding(
              padding: const EdgeInsets.only(top: 2, right: ShqSpace.sm),
              child: _DeltaChip(total: total, delta: delta),
            ),
        ],
      ),
    );
  }
}

/// 常驻工具行：多选 / 改卷。
///
/// 用户口径（2026-10-24 第二轮）：这两个是"不开着就一直想用"的能力，
/// 从底部搬到这里常驻；选中题之后的「收藏 / 对答案」再出现在它下面一行。
class _ToolsBar extends StatelessWidget {
  const _ToolsBar({
    required this.multiSelecting,
    required this.grading,
    required this.fillingAi,
    required this.fillDone,
    required this.fillTotal,
    required this.onGradeAll,
    required this.onFillAnswers,
    required this.onToggleMultiSelect,
  });

  final bool multiSelecting;
  final bool grading;

  /// 「AI 补答案」进行中。
  final bool fillingAi;

  /// 补答案进度（已补 / 总数）。
  final int fillDone;
  final int fillTotal;

  final VoidCallback? onGradeAll;
  final VoidCallback? onFillAnswers;
  final VoidCallback? onToggleMultiSelect;

  @override
  Widget build(BuildContext context) {
    final bool hasGrade = onGradeAll != null || onFillAnswers != null;
    return Row(
      children: <Widget>[
        if (onToggleMultiSelect != null)
          Expanded(
            child: _BarButton(
              icon: Icons.checklist,
              label: multiSelecting ? '退出多选' : '多选',
              emphasized: multiSelecting,
              onTap: onToggleMultiSelect,
            ),
          ),
        if (onToggleMultiSelect != null && hasGrade)
          const SizedBox(width: ShqSpace.sm),
        if (onGradeAll != null)
          Expanded(
            child: _BarButton(
              icon: Icons.fact_check_outlined,
              label: grading ? '改卷中' : '改卷',
              busy: grading,
              onTap: (grading || fillingAi) ? null : onGradeAll,
            ),
          ),
        if (onGradeAll != null && onFillAnswers != null)
          const SizedBox(width: ShqSpace.sm),
        if (onFillAnswers != null)
          Expanded(
            child: _BarButton(
              icon: Icons.auto_awesome,
              label: fillingAi
                  ? (fillTotal > 0 ? '补 $fillDone/$fillTotal' : '补答案…')
                  : '补答案',
              busy: fillingAi,
              onTap: (grading || fillingAi) ? null : onFillAnswers,
            ),
          ),
      ],
    );
  }
}

class _BarButton extends StatelessWidget {
  const _BarButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.emphasized = false,
    this.busy = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool emphasized;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final bool enabled = onTap != null;
    final Color color = emphasized
        ? scheme.primary
        : enabled
        ? scheme.onSurface
        : scheme.onSurfaceVariant.withValues(alpha: 0.4);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(ShqRadius.sm),
      child: Container(
        height: 34,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: emphasized
              ? scheme.primary.withValues(alpha: 0.10)
              : scheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(ShqRadius.sm),
          border: Border.all(
            color: emphasized
                ? scheme.primary.withValues(alpha: 0.5)
                : scheme.outlineVariant,
          ),
        ),
        // 窄面板（160dp）里两个按钮各只剩 ~64dp：图标固定、文字可省略，
        // 否则「退出多选」四个字会把 Row 撑溢出（有测试钉这条）。
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              if (busy)
                const SizedBox(
                  width: 13,
                  height: 13,
                  child: CircularProgressIndicator(strokeWidth: 1.8),
                )
              else
                Icon(icon, size: 16, color: color),
              const SizedBox(width: 5),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: color,
                    fontWeight: emphasized ? FontWeight.w600 : FontWeight.w500,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 选中一道题之后才出现的三个动作：收藏 / 对答案 / 问 AI。
///
/// 2026-10-24 接入真实模型后把「问 AI」加回来：它是这道题最常用的动作之一，
/// 只藏在 level>1 的「答题情况」卡里会让大题找不到入口。
class _SelectionActions extends StatelessWidget {
  const _SelectionActions({
    required this.favorited,
    required this.onFavorite,
    required this.onCheckAnswer,
    required this.onAskAi,
  });

  final bool favorited;
  final VoidCallback? onFavorite;
  final VoidCallback? onCheckAnswer;
  final VoidCallback? onAskAi;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Row(
      children: <Widget>[
        Expanded(
          child: _QuestionAction(
            icon: favorited ? Icons.star : Icons.star_outline,
            color: favorited ? scheme.tertiary : null,
            label: favorited ? '已收藏' : '收藏',
            tooltip: favorited ? '取消收藏这道题（再点一次）' : '收藏这道题',
            onTap: onFavorite,
          ),
        ),
        Expanded(
          child: _QuestionAction(
            icon: Icons.fact_check_outlined,
            label: '对答案',
            tooltip: onCheckAnswer == null
                ? '这题还没有参考答案：先补答案或用多选 AI 判'
                : '有参考答案时判这道题，并在指示灯上显示对/错/待判',
            onTap: onCheckAnswer,
          ),
        ),
        Expanded(
          child: _QuestionAction(
            icon: Icons.auto_awesome,
            label: '问 AI',
            tooltip: '对着这道题问 AI / 先做一遍 / 判作答',
            onTap: onAskAi,
          ),
        ),
      ],
    );
  }
}

/// 多选后的批量条（顶部第二行）。
class _BatchBar extends StatelessWidget {
  const _BatchBar({
    required this.selectedCount,
    required this.allFavorited,
    required this.onBatch,
    required this.onDone,
  });

  final int selectedCount;

  /// 已选的题是否全都收藏过（全收藏时批量按钮显示实心星）。
  final bool allFavorited;
  final void Function(RegionPanelBatch action)? onBatch;
  final VoidCallback? onDone;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final bool enabled = selectedCount > 0;
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Row(
        children: <Widget>[
          Text(
            '已选 $selectedCount',
            style: theme.textTheme.labelSmall?.copyWith(
              color: enabled ? scheme.primary : scheme.outline,
              fontWeight: FontWeight.w600,
            ),
          ),
          const Spacer(),
          _BatchAction(
            icon: allFavorited ? Icons.star : Icons.star_outline,
            // 全收藏时再点=取消收藏；混合时只补没收藏的（见 reader_page._runBatch）。
            label: allFavorited ? '取消收藏' : '收藏',
            enabled: enabled,
            onTap: () => onBatch?.call(RegionPanelBatch.favorite),
          ),
          _BatchAction(
            icon: Icons.auto_awesome,
            label: 'AI 判',
            enabled: enabled,
            onTap: () => onBatch?.call(RegionPanelBatch.aiGrade),
          ),
          TextButton(
            onPressed: onDone,
            style: TextButton.styleFrom(
              minimumSize: const Size(0, 28),
              padding: const EdgeInsets.symmetric(horizontal: 6),
              visualDensity: VisualDensity.compact,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: const Text('完成'),
          ),
        ],
      ),
    );
  }
}

class _BatchAction extends StatelessWidget {
  const _BatchAction({
    required this.icon,
    required this.label,
    required this.enabled,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final Color color = enabled
        ? scheme.onSurface
        : scheme.onSurfaceVariant.withValues(alpha: 0.35);
    return InkWell(
      onTap: enabled ? onTap : null,
      borderRadius: BorderRadius.circular(ShqRadius.sm),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 3),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(icon, size: 16, color: color),
            Text(
              label,
              style: theme.textTheme.labelSmall?.copyWith(
                color: color,
                fontSize: 9.5,
                height: 1.2,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 「手改：题目 +2 道」提示。
///
/// 2026-10-24 用户口径：这类信息不必长期挂着 —— 只有题目**条数**被手改时才出现，
/// 点「保存修改」后立刻收掉。显示的是"增减了几道题"，不是操作步数（那是后台数据）。
class _DeltaChip extends StatelessWidget {
  const _DeltaChip({required this.total, required this.delta});

  final int total;
  final int delta;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final String signed = delta > 0 ? '+$delta' : '$delta';
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        decoration: BoxDecoration(
          color: scheme.primary.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(ShqRadius.pill),
        ),
        child: Text(
          '手改：题目 $signed 道 · 共 $total 道',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.labelSmall?.copyWith(
            color: scheme.primary,
            fontSize: ShqType.caption,
          ),
        ),
      ),
    );
  }
}

/// 选中题的答案卡（来自文末「参考答案」区）。
///
/// 只展示、不判分：判题是第 5 周的事；这里先把"答案是什么、从哪来"摆出来，
/// 用户能边看题边对答案。来源徽标必须保留（PDF / OCR / 手工 / AI）。
class _AnswerCard extends StatelessWidget {
  const _AnswerCard({required this.answer, required this.hasAnyAnswer});

  final AnswerNote? answer;
  final bool hasAnyAnswer;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    if (answer == null) {
      if (!hasAnyAnswer) {
        return const SizedBox.shrink();
      }
      return Text(
        '这道题没有匹配到答案',
        style: theme.textTheme.bodySmall?.copyWith(
          color: scheme.onSurfaceVariant,
        ),
      );
    }
    final String source = switch (answer!.source) {
      'ocr' => 'OCR',
      'manual' => '手工',
      'inline' => '随题解析',
      'ai' => 'AI',
      _ => 'PDF 文本',
    };
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(ShqSpace.md),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(ShqRadius.md),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(
                Icons.fact_check_outlined,
                size: 16,
                color: scheme.onSurfaceVariant,
              ),
              const SizedBox(width: 6),
              Text('答案', style: theme.textTheme.labelMedium),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: scheme.secondaryContainer.withValues(alpha: 0.6),
                  borderRadius: BorderRadius.circular(ShqRadius.sm),
                ),
                child: Text(
                  source,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.onSecondaryContainer,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: ShqSpace.xs),
          MathText(
            answer!.text,
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurface,
              height: 1.45,
            ),
          ),
          const SizedBox(height: ShqSpace.xxs),
          if (answer!.source != 'ai' && formulaHeavyText(answer!.text))
            Text(
              '答案含公式，文本可能错序；以卷面为准。',
              style: theme.textTheme.labelSmall?.copyWith(
                color: scheme.tertiary,
              ),
            ),
          Text(
            switch (answer!.source) {
              'inline' => '来自题内解析，供对答案；未做判题。',
              'ai' => 'AI 补的答案，请自检；未做判题。',
              _ => '来自文末答案区，供对答案；未做判题。',
            },
            style: theme.textTheme.labelSmall?.copyWith(color: scheme.outline),
          ),
        ],
      ),
    );
  }
}

class _QuestionAction extends StatelessWidget {
  const _QuestionAction({
    required this.icon,
    required this.label,
    required this.tooltip,
    this.onTap,
    this.color,
  });

  final IconData icon;
  final String label;
  final String tooltip;
  final VoidCallback? onTap;

  /// 强调色（如已收藏的星标）；为空用普通前景色。
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final bool enabled = onTap != null;
    final Color resolved = enabled
        ? (color ?? scheme.onSurface)
        : scheme.onSurfaceVariant.withValues(alpha: 0.35);
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(ShqRadius.md),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              // 图标切换有过渡，点下去"空星 → 实星"不会硬跳。
              AnimatedSwitcher(
                duration: ShqMotion.fast,
                switchInCurve: ShqMotion.curveEmphasized,
                transitionBuilder: (
                  Widget child,
                  Animation<double> animation,
                ) => ScaleTransition(scale: animation, child: child),
                child: Icon(
                  icon,
                  key: ValueKey<IconData>(icon),
                  size: 18,
                  color: resolved,
                ),
              ),
              const SizedBox(height: 1),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: resolved,
                  fontWeight: FontWeight.w500,
                  fontSize: 10.5,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _QuestionRow extends StatelessWidget {
  const _QuestionRow({
    required this.bundle,
    required this.selected,
    required this.actions,
    required this.onTap,
    required this.onAction,
    this.showStemText = true,
    this.hasAnswer = false,
    this.answerOpen = false,
    this.onToggleAnswer,
    this.answerPanel,
    this.dragHandle,
    this.multiSelecting = false,
    this.checked = false,
    this.grade,
    this.onGrade,
    this.onLongPress,
  });

  final QuestionBundle bundle;
  final bool selected;
  final bool showStemText;
  final bool hasAnswer;

  /// 这道题的「答题情况」是否展开。
  final bool answerOpen;
  final VoidCallback? onToggleAnswer;

  /// 展开后插在动作条下面的答题情况卡。
  final Widget? answerPanel;

  /// 拖动排序把手（由 ReorderableListView 包一层）。
  final Widget? dragHandle;

  /// 多选模式：行首画勾选框，点击行 = 勾选。
  final bool multiSelecting;
  final bool checked;

  /// 这道题的判题结论；null = 不显示状态点。
  final AnswerVerdict? grade;
  final ValueChanged<AnswerVerdict>? onGrade;

  /// 长按整行：顺序调整（顶部顺序菜单撤掉后的唯一入口）。
  final VoidCallback? onLongPress;

  /// 这道题此刻能做什么（不可用的动作会灰掉，而不是藏起来——
  /// 藏起来用户就不知道"并入上一题"这个能力存在）。
  final Set<RegionAction> actions;

  final VoidCallback onTap;
  final ValueChanged<RegionAction> onAction;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final Question question = bundle.question;
    final int page = bundle.slices.first.pageIndex + 1;
    // 只显示**用户能理解的结构事实**：第几页、跨几段、是否锁定/手画。
    // 置信度、题型、三色分级是调算法用的开发信息，用户看了只会被误导。
    final List<String> facts = <String>[
      '第 $page 页',
      if (bundle.slices.length > 1) '${bundle.slices.length} 段',
      if (bundle.locked) '已锁定',
      if (question.source == 'manual') '手画',
      if (hasAnswer) '有答案',
    ];
    // 显示层公式归一化：入库仍保留原始 Unicode，界面把数学字符折成可读文本。
    final String? stem = question.stemText == null
        ? null
        : mathForDisplay(question.stemText!);

    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Container(
        color: selected ? scheme.primary.withValues(alpha: 0.09) : null,
        padding: const EdgeInsets.symmetric(
          horizontal: ShqSpace.lg,
          vertical: ShqSpace.sm,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                if (multiSelecting)
                  Padding(
                    padding: const EdgeInsets.only(right: 6, top: 2),
                    child: Icon(
                      checked ? Icons.check_box : Icons.check_box_outline_blank,
                      size: 18,
                      color: checked ? scheme.primary : scheme.outline,
                    ),
                  )
                else if (dragHandle != null) ...<Widget>[
                  dragHandle!,
                  const SizedBox(width: 2),
                ],
                _LabelPill(text: question.label ?? '${question.ordinal}'),
                if (grade != null) ...<Widget>[
                  const SizedBox(width: 3),
                  GradeDot(verdict: grade!, onChanged: onGrade),
                ],
                const SizedBox(width: ShqSpace.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        facts.join(' · '),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                          fontSize: ShqType.caption,
                        ),
                      ),
                      if (!showStemText) ...<Widget>[
                        const SizedBox(height: ShqSpace.xxs),
                        Text(
                          '公式题 · 以题面预览为准',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: scheme.outline,
                          ),
                        ),
                      ],
                      if (showStemText &&
                          stem != null &&
                          stem.trim().isNotEmpty) ...<Widget>[
                        const SizedBox(height: ShqSpace.xxs),
                        Text(
                          stem.trim(),
                          // 公式按行摘录：piecewise/多行公式保留换行，比压成一行可读；
                          // 4 行后省略，避免单条题目把列表撑得太高。
                          maxLines: 4,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: scheme.onSurface,
                            height: 1.35,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                if (selected && question.level > 1)
                  TextButton(
                    onPressed: onToggleAnswer,
                    style: TextButton.styleFrom(
                      minimumSize: const Size(0, 28),
                      padding: const EdgeInsets.symmetric(horizontal: 5),
                      visualDensity: VisualDensity.compact,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        const Icon(Icons.edit_note, size: 15),
                        const SizedBox(width: 2),
                        Text(
                          answerOpen ? '收起' : '答题情况',
                          style: theme.textTheme.labelSmall?.copyWith(
                            fontSize: 10.5,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
            // 选中后在条目内展开动作条：与画布上贴框的浮动条是同一批动作，
            // 只是这里空间更宽，可以带文字。
            if (selected) ...<Widget>[
              const SizedBox(height: ShqSpace.sm),
              _InlineActions(
                locked: bundle.locked,
                actions: actions,
                onAction: onAction,
              ),
            ],
            if (selected && answerOpen && answerPanel != null) ...<Widget>[
              const SizedBox(height: ShqSpace.sm),
              answerPanel!,
            ],
          ],
        ),
      ),
    );
  }
}

/// 条目内的动作条：小图标 + 文字的胶囊按钮。
class _InlineActions extends StatelessWidget {
  const _InlineActions({
    required this.locked,
    required this.actions,
    required this.onAction,
  });

  final bool locked;
  final Set<RegionAction> actions;
  final ValueChanged<RegionAction> onAction;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(ShqRadius.md),
      ),
      child: SingleChildScrollView(
        // 窄屏（手机）上面板只有屏宽 42%，五个动作排不下——横向滚动而不是换行，
        // 避免条目高度跳动（列表一抖，点选就点空）。
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 1),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            for (final RegionAction action in RegionAction.values)
              _InlineAction(
                icon: regionActionIcon(action, locked: locked),
                label: regionActionLabel(action, locked: locked),
                destructive: action.destructive,
                enabled: actions.contains(action),
                onTap: () => onAction(action),
              ),
          ],
        ),
      ),
    );
  }
}

class _InlineAction extends StatelessWidget {
  const _InlineAction({
    required this.icon,
    required this.label,
    required this.enabled,
    required this.onTap,
    this.destructive = false,
  });

  final IconData icon;
  final String label;
  final bool enabled;
  final bool destructive;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final Color color = !enabled
        ? scheme.onSurfaceVariant.withValues(alpha: 0.35)
        : destructive
        ? scheme.error
        : scheme.onSurface;
    return Tooltip(
      message: label,
      waitDuration: const Duration(milliseconds: 500),
      child: InkWell(
        onTap: enabled ? onTap : null,
        borderRadius: BorderRadius.circular(ShqRadius.sm),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: ShqSpace.xs,
            vertical: 4,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(icon, size: 15, color: color),
              const SizedBox(height: 1),
              Text(
                label,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: color,
                  fontSize: 9.5,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _LabelPill extends StatelessWidget {
  const _LabelPill({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    return Container(
      constraints: const BoxConstraints(minWidth: 30),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(ShqRadius.sm - 4),
      ),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: theme.textTheme.bodySmall?.copyWith(
          fontWeight: FontWeight.w600,
          fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.onRecut});

  final VoidCallback onRecut;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(ShqSpace.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              Icons.crop_free,
              size: 26,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: ShqSpace.sm),
            Text(
              '还没切出题目',
              style: theme.textTheme.titleSmall,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: ShqSpace.xxs),
            Text(
              '扫描件没有文本层时切不出来；也可以先手动框一道试试。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: ShqSpace.md),
            TextButton(onPressed: onRecut, child: const Text('重新切题')),
          ],
        ),
      ),
    );
  }
}

/// 判题结果条（2026-10-24 第二轮：这块位置**全部给判题结果**）。
///
/// 一行四组「色点 + 名称 + 数量」，左"判题结果"、右总数。
/// 「改卷 / 多选」已经搬到顶部常驻工具行，这里不再放按钮——它只负责"看结果"。
class _GradeBar extends StatelessWidget {
  const _GradeBar({required this.counts});

  final VerdictCounts? counts;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final VerdictCounts data = counts ?? const VerdictCounts();
    return Container(
      padding: const EdgeInsets.fromLTRB(ShqSpace.md, 4, ShqSpace.md, 4),
      child: Row(
        children: <Widget>[
          // 用一个小图标代替"判题结果"四个字：窄面板（320dp）里四个数字 + 总数
          // 已经占满一行，多四个字就会把"错/未判"挤到滚动区外面（真机踩到）。
          Tooltip(
            message: '判题结果',
            child: Icon(
              Icons.fact_check_outlined,
              size: 13,
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: 6),
          Flexible(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: <Widget>[
                  _CountItem(
                    verdict: AnswerVerdict.correct,
                    label: '对',
                    count: data.correct,
                  ),
                  _CountItem(
                    verdict: AnswerVerdict.pending,
                    label: '待判',
                    count: data.pending,
                  ),
                  _CountItem(
                    verdict: AnswerVerdict.wrong,
                    label: '错',
                    count: data.wrong,
                  ),
                  _CountItem(
                    verdict: AnswerVerdict.none,
                    label: '未判',
                    count: data.none,
                  ),
                ],
              ),
            ),
          ),
          const Spacer(),
          Text(
            '共 ${data.total}',
            style: theme.textTheme.labelSmall?.copyWith(
              color: scheme.outline,
              fontSize: ShqType.caption,
            ),
          ),
        ],
      ),
    );
  }
}

class _CountItem extends StatelessWidget {
  const _CountItem({
    required this.verdict,
    required this.label,
    required this.count,
  });

  final AnswerVerdict verdict;
  final String label;
  final int count;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final Color color = gradeColor(context, verdict);
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(
              color: verdict == AnswerVerdict.none ? Colors.transparent : color,
              shape: BoxShape.circle,
              border: Border.all(color: color, width: 1.2),
            ),
          ),
          const SizedBox(width: 3),
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: scheme.outline,
              fontSize: ShqType.caption - 0.5,
            ),
          ),
          const SizedBox(width: 2),
          Text(
            '$count',
            style: theme.textTheme.labelSmall?.copyWith(
              color: count == 0 ? scheme.outline : scheme.onSurface,
              fontSize: ShqType.caption,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _Actions extends StatelessWidget {
  const _Actions({
    required this.canUndo,
    required this.canRedo,
    required this.editedCount,
    required this.onAdd,
    required this.onUndo,
    required this.onRedo,
    required this.onClearAll,
    required this.onRecut,
  });

  final bool canUndo;
  final bool canRedo;
  final int editedCount;
  final VoidCallback onAdd;
  final VoidCallback onUndo;
  final VoidCallback onRedo;
  final VoidCallback onClearAll;
  final VoidCallback onRecut;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    // 用户 2026-10-24：底部太占面积。改成一行 34dp 图标 + tooltip，
    // 只保留五个高频动作；文字说明交给 tooltip，不再撑两行。
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: ShqSpace.sm, vertical: 2),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        border: Border(top: BorderSide(color: scheme.outlineVariant)),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            _CompactAction(
              icon: Icons.add,
              label: '新增',
              tooltip: '新增框',
              onPressed: onAdd,
            ),
            _CompactAction(
              icon: Icons.undo,
              label: '撤销',
              tooltip: '撤销改框',
              onPressed: canUndo ? onUndo : null,
            ),
            _CompactAction(
              icon: Icons.redo,
              label: '重做',
              tooltip: '重做改框',
              onPressed: canRedo ? onRedo : null,
            ),
            _CompactAction(
              icon: Icons.settings_backup_restore,
              // 用户要求：从「放弃修改」缩成「复原」，保留文字但更省空间。
              label: '复原',
              tooltip: editedCount > 0 ? '复原（放弃修改）' : '无修改',
              onPressed: editedCount > 0 ? onClearAll : null,
            ),
            _CompactAction(
              icon: Icons.refresh,
              // 从「重新切题」缩成「重切」。
              label: '重切',
              tooltip: '重切',
              onPressed: onRecut,
              color: scheme.primary,
            ),
          ],
        ),
      ),
    );
  }
}

class _CompactAction extends StatelessWidget {
  const _CompactAction({
    required this.icon,
    required this.label,
    required this.tooltip,
    required this.onPressed,
    this.color,
  });

  final IconData icon;

  /// 底栏可见的两字短标签（如「复原」「重切」），不靠 tooltip 才能懂。
  final String label;
  final String tooltip;
  final VoidCallback? onPressed;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Color ink = onPressed == null
        ? scheme.onSurface.withValues(alpha: 0.30)
        : (color ?? scheme.onSurfaceVariant);
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(ShqRadius.sm),
        child: SizedBox(
          width: 48,
          height: 44,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              Icon(icon, size: 18, color: ink),
              const SizedBox(height: 1),
              Text(
                label,
                maxLines: 1,
                style: TextStyle(
                  fontSize: 10,
                  height: 1.05,
                  fontWeight: FontWeight.w500,
                  color: ink,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
