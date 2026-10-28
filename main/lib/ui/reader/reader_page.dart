import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show kReleaseMode;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shuaqi/app/ai/ai_service.dart';
import 'package:shuaqi/app/ai/chat_store.dart';
import 'package:shuaqi/app/answer/answer_paper_store.dart';
import 'package:shuaqi/app/answer/answer_sheet_controller.dart';
import 'package:shuaqi/app/favorite/favorite_store.dart';
import 'package:shuaqi/app/grade/grading_controller.dart';
import 'package:shuaqi/app/reader/reader_prefs_store.dart';
import 'package:shuaqi/app/region/question_order_controller.dart';
import 'package:shuaqi/app/region/region_builder.dart';
import 'package:shuaqi/domain/ai/chat.dart';
import 'package:shuaqi/domain/ai/llm_config.dart';
import 'package:shuaqi/domain/ai/question_payload.dart';
import 'package:shuaqi/domain/answer/answer_paper.dart';
import 'package:shuaqi/domain/ink/ink_brush.dart';
import 'package:shuaqi/domain/ink/ink_doc.dart';
import 'package:shuaqi/domain/model/answer_sheet.dart';
import 'package:shuaqi/domain/model/favorite.dart';
import 'package:shuaqi/domain/model/grading.dart';
import 'package:shuaqi/domain/model/question.dart';
import 'package:shuaqi/domain/model/region_set.dart';
import 'package:shuaqi/domain/model/wb_page.dart';
import 'package:shuaqi/domain/reader/panel_metrics.dart';
import 'package:shuaqi/domain/reader/reader_prefs.dart';
import 'package:shuaqi/domain/region/answer.dart';
import 'package:shuaqi/domain/region/answer_freshness.dart';
import 'package:shuaqi/domain/region/correction.dart';
import 'package:shuaqi/domain/region/edited_question.dart';
import 'package:shuaqi/domain/region/grading_policy.dart';
import 'package:shuaqi/domain/region/math_text.dart';
import 'package:shuaqi/domain/region/region_rect.dart';
import 'package:shuaqi/domain/util/ulid.dart';
import 'package:shuaqi/infra/ocr/mlkit_ink_engine.dart';
import 'package:shuaqi/infra/ocr/ocr_engine.dart';
import 'package:shuaqi/infra/vault/layout_store.dart';
import 'package:shuaqi/infra/vault/paths.dart';
import 'package:shuaqi/state/ai_providers.dart';
import 'package:shuaqi/state/answer_sheet_providers.dart';
import 'package:shuaqi/state/app_providers.dart';
import 'package:shuaqi/state/favorite_providers.dart';
import 'package:shuaqi/state/grading_providers.dart';
import 'package:shuaqi/state/ink_providers.dart';
import 'package:shuaqi/state/ink_tool_provider.dart';
import 'package:shuaqi/state/panel_width_provider.dart';
import 'package:shuaqi/state/question_order_providers.dart';
import 'package:shuaqi/state/reader_prefs_providers.dart';
import 'package:shuaqi/state/reader_providers.dart';
import 'package:shuaqi/state/region_providers.dart';
import 'package:shuaqi/state/ui_prefs_provider.dart';
import 'package:shuaqi/ui/panel/ai_chat_panel.dart';
import 'package:shuaqi/ui/panel/answer_adjust_bar.dart';
import 'package:shuaqi/ui/panel/answer_ink_preview.dart';
import 'package:shuaqi/ui/panel/answer_sheet_page.dart';
import 'package:shuaqi/ui/panel/answer_sheet_prep.dart';
import 'package:shuaqi/ui/panel/answer_status_card.dart';
import 'package:shuaqi/ui/panel/grade_dot.dart';
import 'package:shuaqi/ui/panel/panel_resize_handle.dart';
import 'package:shuaqi/ui/panel/question_thumb.dart';
import 'package:shuaqi/ui/panel/region_panel.dart';
import 'package:shuaqi/ui/panel/region_preview.dart';
import 'package:shuaqi/ui/reader/answer_crop_renderer.dart';
import 'package:shuaqi/ui/reader/debug_hud.dart';
import 'package:shuaqi/ui/reader/ink_toolbar.dart';
import 'package:shuaqi/ui/reader/page_image_cache.dart';
import 'package:shuaqi/ui/reader/paged_view.dart';
import 'package:shuaqi/ui/reader/paper_style_sheet.dart';
import 'package:shuaqi/ui/reader/reader_top_actions.dart';
import 'package:shuaqi/ui/reader/region_overlay.dart';
import 'package:shuaqi/ui/reader/scroll_view.dart';
import 'package:shuaqi/ui/reader/thumb_drawer.dart';
import 'package:shuaqi/ui/region/add_question_action.dart';
import 'package:shuaqi/ui/region/region_action.dart';
import 'package:shuaqi/ui/settings/ai_settings_sheet.dart';
import 'package:shuaqi/ui/theme/tokens.dart';
import 'package:shuaqi/ui/widgets/ai_image_attachment.dart';
import 'package:shuaqi/ui/widgets/image_viewer.dart';
import 'package:shuaqi/ui/widgets/labeled_action.dart';

/// 阅读器（T1.5）：**只读**的 PDF 视图，双模式 + 缩放 + 翻页 + 记进度。
///
/// 第 2 周的墨迹层会叠在 `PageLayer` 上，这一版刻意不碰笔。
class ReaderPage extends ConsumerStatefulWidget {
  const ReaderPage({
    super.key,
    required this.workbookId,
    this.initialQuestionId,
  });

  final String workbookId;

  /// 打开后定位并选中这道题（收藏夹「回看出处」用）；null = 正常打开。
  final String? initialQuestionId;

  @override
  ConsumerState<ReaderPage> createState() => _ReaderPageState();
}

class _ReaderPageState extends ConsumerState<ReaderPage>
    with WidgetsBindingObserver {
  static const MethodChannel _mediaChannel = MethodChannel(
    'com.shuaqi.shuaqi/media',
  );

  final GlobalKey<PagedReaderViewState> _pagedKey =
      GlobalKey<PagedReaderViewState>();
  final GlobalKey<ScrollReaderViewState> _scrollKey =
      GlobalKey<ScrollReaderViewState>();
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

  PageImageCache? _cache;
  ReaderHandle? _handle;
  int _current = 0;

  /// 写入器/编辑器的"落盘函数"在依赖就绪时缓存下来。
  ///
  /// 不能在 [dispose] 里 `ref.read`：Riverpod 3 会报
  /// `Bad state: Using "ref" when a widget is about to or has been unmounted`。
  /// 这里存函数而不是控制器，避免 ui 直接依赖 infra 的类型。
  Future<void> Function()? _flushAllInk;
  Future<void> Function(String sessionId, int page)? _flushPageInk;
  Future<void> Function()? _flushRegions;

  /// 阅读偏好（mode / style / intensity）。null 表示还没从库加载完成，
  /// 期间用 [ReaderPrefs.defaults] 渲染，加载完再无缝替换。
  ReaderPrefs? _prefs;
  ReaderPrefsStore? _store;
  Timer? _prefsSaveTimer;
  bool _prefsDirty = false;

  /// 滚动模式的档位缩放（分页模式用双指捏合，不使用它）
  double _scrollZoom = ScrollReaderView.defaultScale;

  /// 切模式时的落点。null 表示还没定（首帧从会话进度恢复）。
  int? _initialPage;
  Timer? _progress;

  ViewMode get _mode => _prefs?.mode ?? ViewMode.paged;
  PaperStyle get _style => _prefs?.style ?? PaperStyle.original;
  int get _intensity => _prefs?.intensity ?? ReaderPrefs.defaultIntensity;

  /// 手势模式：开 = 手指只平移/缩放，**笔仍然书写**；关 = 手指和笔都能书写。
  ///
  /// 2026-10-24 用户口径：手势模式下"仅手写笔可以书写，手不能书写"。
  /// 所以这个开关只决定**手指算不算笔**，不再把笔一起禁掉；笔的书写入口
  /// 与工具体在两种模式下都保留。
  bool get _handTool => _prefs?.handTool ?? false;

  /// 性能 HUD 的帧耗时采集（T2.5）。release 构建不创建，不产生任何开销。
  FrameStatsCollector? _frameStats;

  /// 本轮打开是否已经尝试过自动切题（只试一次，失败也不反复重试）。
  bool _regionEnsured = false;

  /// 右侧检查面板是否展开（T3.5）。展开即"看框/改框"模式。
  bool _panelOpen = false;

  /// 正在拖面板宽度时的临时宽度（dp）。null = 没在拖。
  ///
  /// 拖动中只改面板自身宽度、**不让阅读区跟着重排**（重排会让 PageLayer
  /// 重新取位图，12ms/次 × 每帧 = 直接掉帧）；松手才一次性应用并落盘。
  double? _dragPanelWidth;

  /// 开始拖动时的面板宽度。配合把手抛来的**总位移**算新宽度——
  /// 用累加 + clamp 的话，超限后要"抵消超出量"才动，手感就是"不跟手"（2026-10-24 用户第 10 条）。
  double _dragStartPanelWidth = 0;

  /// 当前选中的框。存的是**锚点**（题号 + 起始页 + 起始 y）而不是 anchor key：
  /// 拖动会改变 key（key 含 y），存 key 的话"拖一下就丢选中"。
  ({String label, int page, double y})? _selected;

  /// 「问 AI」面板：盖在题目区域上，返回即回到题目区域。
  /// [_aiBundle] 保留上一道题，关闭时还能播放滑出动画。
  bool _aiOpen = false;
  QuestionBundle? _aiBundle;

  /// 打开 AI 面板时一次性准备好的对话与附件。
  ///
  /// 面板自己管理后续消息；这里只在"打开/换题"时换一份，
  /// 避免父级重建（例如刚补了答案）把用户临时移除的图片又加回来。
  List<ChatTurn> _aiTurns = const <ChatTurn>[];
  List<AiImageAttachment> _aiAttachments = const <AiImageAttachment>[];

  /// 作答框控制器（每卷一个）。由 provider 持有，页面只监听它的 value。
  AnswerSheetController? _answerSheet;
  bool _answerSheetAttached = false;

  /// 是否在卷面上同步显示全部作答框（面板上部的开关）。
  bool _showAnswers = false;

  /// 当前展开「答题情况」的题目 id；null = 没有展开。
  String? _answerQuestionId;

  /// 答题卡画布上的内容（按题缓存），用于「答题情况」同步预览与 OCR。
  final Map<String, InkDoc> _answerInkDocs = <String, InkDoc>{};

  /// 每道题答题卡所有张的笔数合计（预览统计用）。
  final Map<String, int> _answerInkTotals = <String, int>{};

  /// 面板里「答题情况」的 OCR 引擎。
  MlKitInkEngine? _panelOcr;

  /// 正在识别的题（按 questionId，允许多题排队；卡片只给自己的题转圈）。
  final Set<String> _recognizingIds = <String>{};

  /// 每道题在途的 OCR Future：同一题不并跑，不同题排队但不丢。
  final Map<String, Future<void>> _ocrInFlight = <String, Future<void>>{};

  /// 改框后的 OCR 防抖（拖动会连续触发 updateRect）。
  Timer? _answerBoxOcrTimer;

  /// 一键改卷进度。
  int _gradeDone = 0;
  int _gradeTotal = 0;

  /// 正在保存作答原图（防连点）。
  bool _savingAnswerCrop = false;

  /// 面板「保存修改」的进行态。
  bool _savingEdits = false;

  /// 面板「保存修改」成功了几次。面板用它把"手改 +N 道"的提示收掉。
  int _saveTick = 0;

  /// 手动题目顺序（拖动排序）。null = 尚未挂载。
  QuestionOrderController? _questionOrder;
  bool _questionOrderAttached = false;

  /// 判题结果（对/待判/错）。null = 尚未挂载。
  GradingController? _grades;
  bool _gradesAttached = false;

  /// 一键改卷进行中。
  bool _grading = false;

  /// 「AI 补答案」进行中与进度（工具行第三个键）。
  bool _fillingAi = false;
  int _fillDone = 0;
  int _fillTotal = 0;

  /// 本轮刚补出来、还没被 provider 重新读到的 AI 答案。
  ///
  /// 2026-10-26 用户第 4 条：每补出一道就要能看见、且立刻落盘；
  /// 不能等整批结束才写，否则中途退出会丢已补的答案。
  /// 这里做一层"内存覆盖"，避免每补一道就 invalidate provider 导致页面跳。
  AnswerSet _liveAiAnswers = AnswerSet.empty;

  /// 多选批量「AI 判」进行中。
  bool _batchAiRunning = false;

  /// 「本地判不了/不可信 → 询问后 AI 后台判」的进度。
  bool _aiGrading = false;
  int _aiGradeDone = 0;
  int _aiGradeTotal = 0;
  bool _aiGradeStop = false;

  /// 「重框」态的目标题（左上角浮窗用）。null = 不在重框态。
  QuestionBundle? _adjustTarget;

  /// 最近一次把改动落盘的时刻（浮窗显示"已保存 12:34"）。
  ///
  /// 2026-10-26 用户第 5/12 条：自动保存要**看得见**——
  /// 用户改完框最怕的是"到底存没存"，界面上写一句就踏实了。
  DateTime? _lastSavedAt;

  /// 多选模式与已勾选的题（按 questionId，跨重算稳定）。
  bool _multiSelecting = false;
  final Set<String> _multiSelected = <String>{};

  /// 本卷已收藏的题目 id（题目面板画实心星；收藏/取消后由 provider 刷新）。
  Set<String> _favoriteQuestionIds = <String>{};

  /// 待定位的题（收藏夹「回看出处」传入）；切题结果加载后跳转并选中，然后清空。
  String? _pendingQuestionId;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _pendingQuestionId = widget.initialQuestionId;
    // 进卷时丢掉上一次的切题/答案缓存：AI 补答案可能刚写完文件，
    // 而 provider 不是 autoDispose；不刷新的话退出再进会读到旧快照。
    ref.invalidate(regionSetProvider(widget.workbookId));
    if (!kReleaseMode) {
      _frameStats = FrameStatsCollector();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 只在这里取一次 ref；dispose 阶段只调用缓存下来的函数。
    _flushAllInk ??= ref.read(inkWriterProvider(widget.workbookId)).flushAll;
    _flushPageInk ??= ref.read(inkWriterProvider(widget.workbookId)).flush;
    _flushRegions ??= ref.read(regionEditProvider(widget.workbookId)).flush;
    // 作答框只在一个地方初始化；provider 会负责 load 与 dispose。
    if (!_answerSheetAttached) {
      _answerSheetAttached = true;
      final AnswerSheetController controller = ref.read(
        answerSheetProvider(widget.workbookId),
      );
      _answerSheet = controller;
      controller.data.addListener(_onAnswerSheetChanged);
    }
    if (!_questionOrderAttached) {
      _questionOrderAttached = true;
      final QuestionOrderController controller = ref.read(
        questionOrderProvider(widget.workbookId),
      );
      _questionOrder = controller;
      controller.order.addListener(_onQuestionOrderChanged);
    }
    if (!_gradesAttached) {
      _gradesAttached = true;
      final GradingController controller = ref.read(
        gradingProvider(widget.workbookId),
      );
      _grades = controller;
      controller.data.addListener(_onGradesChanged);
    }
  }

  void _onGradesChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  void _onQuestionOrderChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  void _onAnswerSheetChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // T2.4：切后台/被系统杀之前把待写页落盘。paused 已经可能来不及，
    // 所以防抖仍然是第一道保险，这里是最后一道。
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      final Future<void> Function()? flushAll = _flushAllInk;
      if (flushAll != null) {
        unawaited(flushAll());
      }
      // 覆盖层同理：300ms 防抖窗口里的修改也要落地。
      final Future<void> Function()? flushRegions = _flushRegions;
      if (flushRegions != null) {
        unawaited(flushRegions());
      }
      final AnswerSheetController? answers = _answerSheet;
      if (answers != null) {
        unawaited(answers.flush());
      }
      final QuestionOrderController? order = _questionOrder;
      if (order != null) {
        unawaited(order.flush());
      }
    }
  }

  /// 立刻落一页（切页 / 切模式时调用）。
  void _flushInk(int page) {
    final session = _handle?.session;
    if (session == null) {
      return;
    }
    final Future<void> Function(String, int)? flushPage = _flushPageInk;
    if (flushPage == null) {
      return;
    }
    unawaited(flushPage(session.id, page));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _answerBoxOcrTimer?.cancel();
    unawaited(_panelOcr?.dispose());
    // 退出阅读器前把 500ms 防抖窗口里的内容也写掉。
    // **不能在这时 ref.read**：widget 已 deactivated，Riverpod 3 会直接报错。
    final Future<void> Function()? flushAll = _flushAllInk;
    if (flushAll != null) {
      unawaited(flushAll());
    }
    final Future<void> Function()? flushRegions = _flushRegions;
    if (flushRegions != null) {
      unawaited(flushRegions());
    }
    final AnswerSheetController? answers = _answerSheet;
    if (answers != null) {
      answers.data.removeListener(_onAnswerSheetChanged);
      unawaited(answers.flush());
    }
    final QuestionOrderController? order = _questionOrder;
    if (order != null) {
      order.order.removeListener(_onQuestionOrderChanged);
      unawaited(order.flush());
    }
    _frameStats?.dispose();
    _progress?.cancel();
    _prefsSaveTimer?.cancel();
    // 退出前若还有未落盘的偏好，立刻写一次（store/db 都比页面活得久，安全）
    final ReaderPrefsStore? store = _store;
    final ReaderPrefs? prefs = _prefs;
    if (_prefsDirty && store != null && prefs != null) {
      unawaited(store.save(widget.workbookId, prefs));
    }
    _cache?.dispose();
    super.dispose();
  }

  /// 偏好变化 → 刷新界面 + 防抖落盘（500ms，拖滑条时不会每帧写库）。
  void _updatePrefs(ReaderPrefs next) {
    setState(() => _prefs = next);
    _prefsDirty = true;
    _prefsSaveTimer?.cancel();
    _prefsSaveTimer = Timer(const Duration(milliseconds: 500), () {
      final ReaderPrefsStore? store = _store;
      if (store != null) {
        unawaited(store.save(widget.workbookId, next));
      }
      _prefsDirty = false;
    });
  }

  void _onPageChanged(int index) {
    // 首次挂载时视图会把 initialPage 回报一次。页码没变就不要写库，
    // 否则"只是打开一下"也会改掉进度（实测会让 last_page 漂移）。
    if (index == _current) {
      return;
    }
    // 离开这一页：把 500ms 防抖窗口里的笔迹立刻落掉（切页触发条件）。
    _flushInk(_current);
    setState(() {
      _current = index;
    });
    _progress?.cancel();
    // 防抖 500ms：翻页时不要每一页都写一次库
    _progress = Timer(const Duration(milliseconds: 500), () {
      final ReaderHandle? handle = _handle;
      if (handle != null) {
        unawaited(handle.saveLastPage(index));
      }
    });
  }

  void _switchMode() {
    _flushInk(_current);
    final ReaderPrefs next = (_prefs ?? ReaderPrefs.defaults).copyWith(
      mode: _mode == ViewMode.paged ? ViewMode.scroll : ViewMode.paged,
    );
    setState(() {
      _initialPage = _current;
    });
    _updatePrefs(next);
  }

  /// 打开/收起检查面板。**打开面板 = 同时打开框显示**：
  /// 面板里全是框的条目，框却看不见会让人不知道在改什么。
  void _togglePanel() {
    setState(() {
      _panelOpen = !_panelOpen;
      if (!_panelOpen) {
        _selected = null;
        _answerQuestionId = null;
        _adjustTarget = null;
        // AI 是题目区域的下一层，主面板收起时一起收，避免留下一个悬空对话。
        _aiOpen = false;
      }
    });
  }

  /// 打开「答题卡」：先确认切题，再逐题作答。
  ///
  /// 这一层只负责把"当前卷的题目 + 页图"交给确认组件；逐题作答画布是下一步，
  /// 不在这里提前造第二套笔迹存储。
  void _openAnswerSheet() {
    final ReaderHandle? handle = _handle;
    final PageImageCache? cache = _cache;
    final RegionSet set = _regionSetOf();
    if (handle == null || cache == null || set.isEmpty) {
      _showReaderTip('题目还没切好，稍等一下再打开答题卡');
      return;
    }
    unawaited(_openAnswerSheetFlow(handle, cache, set));
  }

  Future<void> _openAnswerSheetFlow(
    ReaderHandle handle,
    PageImageCache cache,
    RegionSet set, {
    String? initialQuestionId,
  }) async {
    final AnswerSheetPrepResult? result = await showAnswerSheetPrep(
      context,
      workbookId: widget.workbookId,
      set: set,
      pages: handle.pages,
      cache: cache,
    );
    if (!mounted || result == null) {
      return;
    }
    if (result.action == AnswerSheetPrepAction.adjust) {
      // 和「题目区域」共用同一套原卷拖框，不在确认页重复造第二套编辑器。
      setState(() {
        _panelOpen = true;
        _aiOpen = false;
        _answerQuestionId = null;
        _showAnswers = false;
      });
      final QuestionBundle? target = result.questionId == null
          ? null
          : _bundleById(set, result.questionId!);
      if (target != null) {
        _selectFromPanel(target);
      }
      _showReaderTip('在原卷拖动**题目框**调整切题；完成后可重新打开答题卡');
      return;
    }
    final AnswerSheetResult? sheet = await showAnswerSheetPage(
      context,
      workbookId: widget.workbookId,
      sessionId: handle.session.id,
      set: set,
      pages: handle.pages,
      cache: cache,
      handTool: _handTool,
      initialQuestionId: initialQuestionId,
    );
    if (!mounted) {
      return;
    }
    // 用户在答题卡里点了「重框」：回到原卷、选中这道题、进作答框编辑。
    final String? adjustId = sheet?.questionId;
    if (adjustId != null) {
      _enterAdjustFor(adjustId);
      return;
    }
    // 答题卡笔迹独立存储；回到题目面板时刷新一下"答题情况"里的统计。
    final QuestionBundle? selected = _bundleById(set, _answerQuestionId ?? '');
    if (selected != null) {
      unawaited(_refreshAnswerInkCount(selected));
      // 用户刚在答题卡里写过：卡片还开着就按新指纹自动重识别。
      unawaited(_autoRecognizeIfNeeded(selected));
    }
    setState(() {});
  }

  /// 直接打开答题卡并定位到某题（跳过确认页）。
  ///
  /// 「答题情况 → 去写」用它：用户已经看着这道题的作答情况了，
  /// 再让他过一遍"确认切题"没有意义，而且要准确落在这道题上。
  void _openAnswerSheetAt(String questionId) {
    final ReaderHandle? handle = _handle;
    final PageImageCache? cache = _cache;
    final RegionSet set = _regionSetOf();
    if (handle == null || cache == null || set.isEmpty) {
      _showReaderTip('题目还没切好，稍等一下再打开答题卡');
      return;
    }
    unawaited(
      _openAnswerSheetFlow(handle, cache, set, initialQuestionId: questionId),
    );
  }

  /// 进入「重框」态：打开面板、选中该题、进入**切题框**编辑，并显示左上角浮窗。
  ///
  /// 2026-10-26 用户第 12 条：这里原来置 `_showAnswers = true`，
  /// 于是拖的是**作答框**（紫色虚线），用户以为是改切题框——白改一场。
  /// 现在 `_showAnswers = false`：拖的就是题目框本身。
  void _enterAdjustFor(String questionId) {
    final RegionSet set = _regionSetOf();
    final QuestionBundle? bundle = _bundleById(set, questionId);
    if (bundle == null) {
      _showReaderTip('这道题已经不在了，可能刚重新切过题');
      return;
    }
    setState(() {
      _panelOpen = true;
      // 编辑**题目框**（作答框的编辑由面板里的「答题情况」进入）。
      _showAnswers = false;
      _aiOpen = false;
      _answerQuestionId = questionId;
      _adjustTarget = bundle;
    });
    _selectFromPanel(bundle);
    _showReaderTip('正在调整这道题的切题框；改完点左上角「完成」');
  }

  /// 浮窗「返回」：保存 + 等重算完，再带着这道题回答题卡。
  Future<void> _backToAnswerSheet() async {
    final QuestionBundle? target = _adjustTarget;
    if (target == null) {
      return;
    }
    await _saveEdits();
    if (!mounted) {
      return;
    }
    // 重算后 id 可能变：优先 id，其次 anchor（题号|页|y），都不中就用原 bundle。
    final RegionSet set = _regionSetOf();
    final QuestionBundle resolved =
        _bundleById(set, target.question.id) ??
        _bundleOf(set, target.anchorKey) ??
        target;
    setState(() => _adjustTarget = null);
    _openAnswerSheetAt(resolved.question.id);
  }

  /// 浮窗「停留」：保存并收起浮窗，人留在原卷。
  Future<void> _stayInReader() async {
    await _saveEdits();
    if (mounted) {
      setState(() => _adjustTarget = null);
    }
  }

  /// 手势按钮：在"书写模式"和"手势模式"之间切。
  ///
  /// - 手势模式（开）：手指只平移缩放，笔仍然书写（手掌放屏上不会画线）；
  /// - 书写模式（关）：手指和笔都书写，双指平移缩放。
  void _toggleHandTool() {
    _updatePrefs(
      (_prefs ?? ReaderPrefs.defaults).copyWith(handTool: !_handTool),
    );
  }

  /// 点面板条目：跳到那一页并选中。
  void _selectFromPanel(QuestionBundle bundle) {
    if (bundle.slices.isEmpty) {
      return;
    }
    if (_answerQuestionId != null) {
      setState(() => _answerQuestionId = null);
    }
    final int page = bundle.slices.first.pageIndex;
    _selectBundle(bundle);
    if (page != _current) {
      _jumpTo(page);
    }
  }

  // ── 作答框 / 答题情况（2026-10-24）──────────────────────────────

  static String _answerMarkKey(String questionId) => 'ans:$questionId';

  static String? _answerIdOfKey(String key) {
    return key.startsWith('ans:') ? key.substring(4) : null;
  }

  AnswerSheetEntry _answerEntryOf(QuestionBundle bundle) {
    return _answerSheet?.entryFor(bundle) ??
        AnswerSheetEntry.defaultFor(bundle);
  }

  QuestionBundle? _bundleById(RegionSet set, String questionId) {
    for (final QuestionBundle bundle in set.questions) {
      if (bundle.question.id == questionId) {
        return bundle;
      }
    }
    return null;
  }

  /// 展开/收起某道题的「答题情况」。
  void _toggleAnswerFor(QuestionBundle bundle) {
    if (bundle.question.level <= 1) {
      return;
    }
    if (_answerQuestionId == bundle.question.id) {
      setState(() => _answerQuestionId = null);
      return;
    }
    _openAnswerFor(bundle);
  }

  /// 选中某道题的作答框：跳作答页、展开「答题情况」、把叠加层选中态切到作答框。
  void _openAnswerFor(QuestionBundle bundle) {
    if (bundle.slices.isEmpty || bundle.question.level <= 1) {
      return;
    }
    final AnswerSheetEntry entry = _answerEntryOf(bundle);
    final int lastPage = math.max(0, (_handle?.pages.length ?? 1) - 1);
    final int page = entry.pageIndex.clamp(0, lastPage);
    setState(() {
      _panelOpen = true;
      _selected = (
        label: bundle.question.label ?? '',
        page: bundle.slices.first.pageIndex,
        y: bundle.slices.first.rect.top,
      );
      _answerQuestionId = bundle.question.id;
    });
    if (page != _current) {
      _jumpTo(page);
    }
    // 展开即自动识别（用户第 4 条：不要「识别」按钮，展开就是后台行为）。
    // 0.1.3：不再用 `_autoOcrTried` 一次性闸门，而是按「作答指纹」判断——
    // 改框 / 增删笔迹 / 换纸之后再展开都会重新识别。
    unawaited(_autoRecognizeIfNeeded(bundle));
  }

  Future<void> _autoRecognizeIfNeeded(QuestionBundle bundle) async {
    if (!mounted) {
      return;
    }
    await _ensureFreshAnswerOcr(bundle);
  }

  /// 确保这道题的 OCR 对应当前笔迹/作答框；返回最新的作答快照。
  ///
  /// 同一题在途的 OCR 会被等待；等完再算一次指纹，防止"识别过程中又写了一笔"
  /// 导致结果仍然过期。最多再补一次，避免极端情况下死循环。
  Future<_AnswerInkSnapshot> _ensureFreshAnswerOcr(
    QuestionBundle bundle, {
    bool force = false,
  }) async {
    for (int attempt = 0; attempt < 2; attempt += 1) {
      final Future<void>? running = _ocrInFlight[bundle.question.id];
      if (running != null) {
        await running;
      }
      if (!mounted) {
        break;
      }
      final _AnswerInkSnapshot snapshot = await _answerInkSnapshotOf(bundle);
      final AnswerSheetEntry entry = snapshot.entry;
      final bool needs =
          force ||
          entry.inkSig != snapshot.signature ||
          !entry.hasText ||
          entry.ocrStale;
      if (!needs || !snapshot.hasAnyInk) {
        return snapshot;
      }
      await _enqueueAnswerOcr(bundle, snapshot: snapshot, silent: true);
    }
    return _answerInkSnapshotOf(bundle);
  }

  /// 读这一题的全部作答笔迹，算指纹，并顺手刷新卡片预览用的缓存。
  Future<_AnswerInkSnapshot> _answerInkSnapshotOf(QuestionBundle bundle) async {
    final ReaderHandle? handle = _handle;
    final AnswerSheetController? controller = _answerSheet;
    if (handle == null || controller == null || handle.pages.isEmpty) {
      return _AnswerInkSnapshot(
        entry: controller?.entryFor(bundle) ?? _answerEntryOf(bundle),
        sheetDocs: const <InkDoc>[],
        pageRevision: 0,
        pageStrokes: const <InkStroke>[],
        paperPages: 1,
        signature: '',
      );
    }
    final AnswerSheetEntry entry = controller.entryFor(bundle);
    final AnswerPaperData papers = await _papersOf();
    final int paperPages = papers.forQuestion(bundle.question.id).pages;
    final List<InkDoc> sheetDocs = await _loadAnswerInkPages(bundle);
    final bool hasSheetInk = sheetDocs.any(
      (InkDoc doc) => doc.strokes.isNotEmpty,
    );

    int pageRevision = 0;
    List<InkStroke> pageStrokes = const <InkStroke>[];
    if (!hasSheetInk) {
      final int pageIndex = entry.pageIndex.clamp(0, handle.pages.length - 1);
      await ref
          .read(inkWriterProvider(widget.workbookId))
          .flush(handle.session.id, pageIndex);
      final InkDoc pageDoc = await ref
          .read(inkStoreProvider(widget.workbookId))
          .load(handle.session.id, pageIndex);
      pageRevision = pageDoc.revision;
      pageStrokes = _strokesInRect(pageDoc, entry.rect);
    }

    final String signature = answerSignatureOf(
      entry: entry,
      sheetDocs: sheetDocs,
      pageRevision: pageRevision,
      pageStrokes: pageStrokes,
      paperPages: paperPages,
    );
    final int total =
        sheetDocs.fold<int>(0, (int sum, InkDoc doc) => sum + doc.strokeCount) +
        pageStrokes.length;
    if (mounted) {
      setState(() {
        _answerInkDocs[bundle.question.id] = sheetDocs.isEmpty
            ? InkDoc.empty
            : sheetDocs.first;
        _answerInkTotals[bundle.question.id] = total;
      });
    }
    return _AnswerInkSnapshot(
      entry: entry,
      sheetDocs: sheetDocs,
      pageRevision: pageRevision,
      pageStrokes: pageStrokes,
      paperPages: paperPages,
      signature: signature,
    );
  }

  /// 同一题只跑一个 OCR；不同题排队但不会被丢掉。
  Future<void> _enqueueAnswerOcr(
    QuestionBundle bundle, {
    _AnswerInkSnapshot? snapshot,
    bool silent = true,
  }) {
    final String id = bundle.question.id;
    final Future<void>? running = _ocrInFlight[id];
    if (running != null) {
      return running;
    }
    final Future<void> future =
        _recognizePanelAnswer(
          bundle,
          snapshot: snapshot,
          silent: silent,
        ).whenComplete(() {
          unawaited(_ocrInFlight.remove(id));
          if (mounted) {
            setState(() => _recognizingIds.remove(id));
          }
        });
    _ocrInFlight[id] = future;
    if (mounted) {
      setState(() => _recognizingIds.add(id));
    }
    return future;
  }

  /// 改框后 300ms 再识别：拖动会连续触发 updateRect，不能每帧跑模型。
  void _scheduleAnswerOcr(QuestionBundle bundle) {
    _answerBoxOcrTimer?.cancel();
    final String id = bundle.question.id;
    _answerBoxOcrTimer = Timer(const Duration(milliseconds: 300), () {
      if (!mounted || _answerQuestionId != id) {
        return;
      }
      final RegionSet set = _regionSetOf();
      final QuestionBundle? latest = _bundleById(set, id);
      if (latest == null) {
        return;
      }
      unawaited(_autoRecognizeIfNeeded(latest));
    });
  }

  Future<void> _refreshAnswerInkCount(QuestionBundle bundle) async {
    if (!mounted) {
      return;
    }
    await _answerInkSnapshotOf(bundle);
  }

  /// 卷面上点中作答框。
  void _selectAnswerById(RegionSet set, String questionId) {
    final QuestionBundle? bundle = _bundleById(set, questionId);
    if (bundle == null) {
      return;
    }
    _openAnswerFor(bundle);
  }

  void _moveAnswer(String key, int page, double dx, double dy) {
    final String? id = _answerIdOfKey(key);
    if (id == null) {
      return;
    }
    final RegionSet set = _regionSetOf();
    final QuestionBundle? bundle = _bundleById(set, id);
    final AnswerSheetController? controller = _answerSheet;
    if (bundle == null || controller == null) {
      return;
    }
    final AnswerSheetEntry entry = controller.entryFor(bundle);
    final RegionRect rect = RegionRect.fromLTRB(
      entry.rect.left + dx,
      entry.rect.top + dy,
      entry.rect.right + dx,
      entry.rect.bottom + dy,
    );
    // 框变了：旧文字属于旧框，展开/改卷时会按新指纹自动重识别；
    // 如果这张卡正开着，防抖后立刻重识别一次。
    unawaited(controller.updateRect(bundle, pageIndex: page, rect: rect));
    _scheduleAnswerOcr(bundle);
  }

  void _resizeAnswer(String key, int page, RegionRect rect) {
    final String? id = _answerIdOfKey(key);
    if (id == null) {
      return;
    }
    final RegionSet set = _regionSetOf();
    final QuestionBundle? bundle = _bundleById(set, id);
    final AnswerSheetController? controller = _answerSheet;
    if (bundle == null || controller == null) {
      return;
    }
    // 同上：框变了就按新指纹重新识别。
    unawaited(controller.updateRect(bundle, pageIndex: page, rect: rect));
    _scheduleAnswerOcr(bundle);
  }

  /// 长按作答框：只给一个恢复整题的入口，避免和题目动作条混在一起。
  Future<void> _showAnswerMenu(QuestionBundle bundle) async {
    final bool? reset = await showModalBottomSheet<bool>(
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
              leading: const Icon(Icons.restart_alt),
              title: const Text('恢复整题作答框'),
              subtitle: const Text('回到覆盖整道题的默认区域；已有识别文字会保留'),
              onTap: () => Navigator.of(context).pop(true),
            ),
            const SizedBox(height: ShqSpace.sm),
          ],
        ),
      ),
    );
    if (!mounted || reset != true) {
      return;
    }
    await _answerSheet?.reset(bundle);
  }

  /// 当前页上落在这道题作答框里的笔数。`-1` = 不在当前页，未统计。
  int _answerStrokeCountOf(AnswerSheetEntry entry) {
    final ReaderHandle? handle = _handle;
    if (handle == null || entry.pageIndex != _current) {
      return -1;
    }
    final InkDoc doc = ref.watch(
      inkDocProvider(
        InkPageKey(
          handle.session.id,
          entry.pageIndex,
          workbookId: widget.workbookId,
        ),
      ),
    );
    int count = 0;
    for (final InkStroke stroke in doc.recognizableStrokes) {
      if (stroke.points.isEmpty) {
        continue;
      }
      final InkPoint first = stroke.points.first;
      final InkRect bounds = stroke.bounds;
      if (entry.rect.contains(first.x, first.y) ||
          entry.rect.contains(bounds.centerX, bounds.centerY)) {
        count++;
      }
    }
    return count;
  }

  Widget _buildAnswerPanel(QuestionBundle bundle, AnswerNote? answerNote) {
    final AnswerSheetEntry entry = _answerEntryOf(bundle);
    final InkDoc? ink = _answerInkDocs[bundle.question.id];
    final InkDoc? pageInk = _pageInkOf(entry);
    final ReaderHandle? handle = _handle;
    final WbPage? page =
        handle != null &&
            entry.pageIndex >= 0 &&
            entry.pageIndex < handle.pages.length
        ? handle.pages[entry.pageIndex]
        : null;
    return AnswerStatusCard(
      entry: entry,
      strokeCount: _answerStrokeCountOf(entry),
      answerNote: answerNote,
      onJump: () => _jumpTo(entry.pageIndex),
      answerInkCount:
          _answerInkTotals[bundle.question.id] ?? ink?.strokeCount ?? -1,
      answerInk: ink,
      pageInk: pageInk,
      pageWidth: page?.width ?? 0,
      pageHeight: page?.height ?? 0,
      recognizing: _recognizingIds.contains(bundle.question.id),
      onRegenerate: () => unawaited(_regenerateAnswer(bundle)),
      onPreview: () => unawaited(_showAnswerPreview(bundle)),
      onLongPress: () => _openAnswerImageActions(bundle),
      onOpenSheet: () => _openAnswerSheetAt(bundle.question.id),
      onRenderMerged: () => _renderMergedAnswer(bundle),
      onAskAi: () => unawaited(_showAskAi(bundle)),
    );
  }

  /// 当前页作答框里的笔画（只算当前页，别的页等切过去再算）。
  ///
  /// 没有答题卡笔迹时，答题情况卡显示的就是这一份——用户的口径是
  /// "没有答题卡就当他是直接在卷面上写的"（2026-10-24 第二轮第 2 条）。
  InkDoc? _pageInkOf(AnswerSheetEntry entry) {
    final ReaderHandle? handle = _handle;
    if (handle == null || entry.pageIndex != _current) {
      return null;
    }
    final InkDoc doc = ref.watch(
      inkDocProvider(
        InkPageKey(
          handle.session.id,
          entry.pageIndex,
          workbookId: widget.workbookId,
        ),
      ),
    );
    final List<InkStroke> strokes = _strokesInRect(doc, entry.rect);
    if (strokes.isEmpty) {
      return null;
    }
    return InkDoc(revision: doc.revision, strokes: strokes);
  }

  /// 点「作答」预览：有答题卡笔迹看答题卡大图，否则看页内笔迹。
  Future<void> _showAnswerPreview(QuestionBundle bundle) async {
    final AnswerSheetEntry entry = _answerEntryOf(bundle);
    final InkDoc? ink = _answerInkDocs[bundle.question.id];
    if (ink != null && ink.strokes.isNotEmpty) {
      await _showAnswerInk(bundle);
      return;
    }
    final InkDoc? pageInk = _pageInkOf(entry);
    final ReaderHandle? handle = _handle;
    if (pageInk == null || handle == null) {
      return;
    }
    final WbPage? page =
        entry.pageIndex >= 0 && entry.pageIndex < handle.pages.length
        ? handle.pages[entry.pageIndex]
        : null;
    final String label = bundle.question.label ?? '${bundle.question.ordinal}';
    await showImageViewer(
      context,
      title: '第 $label 题 · 作答手写',
      aspectRatio: entry.rect.width / math.max(1, entry.rect.height),
      actions: _answerImageActions(bundle),
      builder: (BuildContext context, Size size) => AnswerInkPreview(
        doc: pageInk,
        region: entry.rect,
        canvasWidth: page?.width ?? 1000,
        canvasHeight: page?.height ?? 1000,
      ),
    );
  }

  /// 双击「答题情况」卡片时生成"题面 + 书写"的合并图。
  ///
  /// - 有答题卡笔迹：题面裁切 + 多张作答纵向拼接（`renderAnswerSheetWithQuestionPng`）；
  /// - 只有页内笔迹：题面裁切 + 框内笔迹叠加（`renderAnswerCropPng`）。
  ///
  /// 这里的"总区域"就是题目区域本身（`slice.rect`）——题面和书写不重合时，
  /// 以能覆盖两者的题目框为准，不做二次并集（并集会让题面露出半截更难看）。
  Future<Uint8List?> _renderMergedAnswer(QuestionBundle bundle) async {
    final ReaderHandle? handle = _handle;
    final PageImageCache? cache = _cache;
    if (handle == null || cache == null || bundle.slices.isEmpty) {
      return null;
    }
    final AnswerSheetEntry entry = _answerEntryOf(bundle);
    final List<InkDoc> docs = await _loadAnswerInkPages(bundle);
    final bool hasSheet = docs.any((InkDoc d) => d.strokes.isNotEmpty);
    if (hasSheet) {
      final QuestionSlice slice = bundle.slices.first;
      if (slice.pageIndex < 0 || slice.pageIndex >= handle.pages.length) {
        return null;
      }
      final AnswerPaper paper = (await _papersOf()).forQuestion(
        bundle.question.id,
      );
      return renderAnswerSheetWithQuestionPng(
        cache: cache,
        page: handle.pages[slice.pageIndex],
        rect: slice.rect,
        docs: docs,
        widthPt: paper.widthPt,
        heightPt: paper.heightPt,
      );
    }
    final int page = entry.pageIndex.clamp(0, handle.pages.length - 1);
    await ref
        .read(inkWriterProvider(widget.workbookId))
        .flush(handle.session.id, page);
    final InkDoc pageDoc = await ref
        .read(inkStoreProvider(widget.workbookId))
        .load(handle.session.id, page);
    return renderAnswerCropPng(
      cache: cache,
      page: handle.pages[page],
      rect: entry.rect,
      doc: pageDoc,
      darkPaper: false,
    );
  }

  /// 作答图的长按照片动作：两种图各存一张（用户第 7 条的两个选项）。
  List<ImageAction> _answerImageActions(QuestionBundle bundle) => <ImageAction>[
    ImageAction(
      label: '保存含题图',
      subtitle: '题目 + 作答，一张合并图',
      icon: Icons.image_outlined,
      onSelected: () =>
          _downloadAnswerImage(bundle, includeQuestion: true, silent: true),
    ),
    ImageAction(
      label: '保存仅笔迹',
      subtitle: '白底手写，不含题目',
      icon: Icons.draw_outlined,
      onSelected: () =>
          _downloadAnswerImage(bundle, includeQuestion: false, silent: true),
    ),
  ];

  void _openAnswerImageActions(QuestionBundle bundle) {
    final Size screen = MediaQuery.sizeOf(context);
    unawaited(
      showImageActions(
        context,
        anchor: Offset(screen.width, screen.height * 0.34),
        actions: _answerImageActions(bundle),
      ),
    );
  }

  /// 作答手写大图（弹窗）：白纸 + 笔迹，按答题卡画布比例显示。
  Future<void> _showAnswerInk(QuestionBundle bundle) async {
    final InkDoc doc = await _loadAnswerInk(bundle);
    if (!mounted || doc.strokes.isEmpty) {
      return;
    }
    final String label = bundle.question.label ?? '${bundle.question.ordinal}';
    await showImageViewer(
      context,
      title: '第 $label 题 · 作答手写',
      aspectRatio: AnswerCanvas.aspect,
      actions: _answerImageActions(bundle),
      builder: (BuildContext context, Size size) => AnswerInkPreview(doc: doc),
    );
  }

  /// 双击「答题情况」= 重新生成：重跑本地识别。
  Future<void> _regenerateAnswer(QuestionBundle bundle) async {
    final Future<void>? running = _ocrInFlight[bundle.question.id];
    if (running != null) {
      await running;
    }
    if (!mounted) {
      return;
    }
    await _enqueueAnswerOcr(
      bundle,
      snapshot: await _answerInkSnapshotOf(bundle),
      silent: false,
    );
  }

  // ── 判题 / 改卷 / 多选（2026-10-24 用户第 9、10 条）──────────────

  /// 参与判题的题：与答题卡同一口径——有小题目录时只判小题。
  List<QuestionBundle> _gradableQuestions(RegionSet set) {
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

  /// 一键改卷（2026-10-28 v0.1.3 口径）：
  ///
  /// 1. 逐题**先按作答指纹确认 OCR 是新的**（改过框/加过笔迹就自动重识别）；
  /// 2. 只对已有参考答案的题跑本地规则；没有答案/没有作答的题分别计数；
  /// 3. 本地可信 → 落绿/红；低置信度的客观题按用户口径**强制落判**并注明；
  /// 4. AI 判过的题：答案无明显改动 → 保留原判；明显改动 → 用当前 OCR 重判；
  /// 5. 手改结论永远保留；
  /// 6. 主观/公式/无识别文字 → 先标黄，汇总后询问是否交给 AI，不自动扣 token。
  Future<void> _gradeAll() async {
    if (_grading || _aiGrading || _fillingAi || _batchAiRunning) {
      return;
    }
    final GradingController? controller = _grades;
    final RegionSet set = _regionSetOf();
    if (controller == null || set.isEmpty) {
      return;
    }
    final List<QuestionBundle> questions = _gradableQuestions(set);
    setState(() {
      _grading = true;
      _gradeDone = 0;
      _gradeTotal = questions.length;
    });
    int correct = 0;
    int wrong = 0;
    int pending = 0;
    int unanswered = 0;
    int noAnswer = 0;
    int reOcr = 0;
    int aiKept = 0;
    int manualKept = 0;
    int lowConfidence = 0;
    final List<QuestionBundle> untrusted = <QuestionBundle>[];
    try {
      for (final QuestionBundle bundle in questions) {
        if (!mounted) {
          return;
        }
        final String id = bundle.question.id;
        try {
          final QuestionGrade? existing = controller.data.value.gradeOf(id);
          final String beforeSig = _answerEntryOf(bundle).inkSig;
          // 先确保 OCR 对应当前笔迹/作答框（改过就自动重识别）。
          final _AnswerInkSnapshot snapshot = await _ensureFreshAnswerOcr(
            bundle,
          );
          if (!mounted) {
            return;
          }
          final AnswerSheetEntry entry = snapshot.entry;
          if (entry.inkSig != beforeSig) {
            reOcr++;
          }

          // 手改永远保留；但仍然先把 OCR 刷新，卡片/后续查看看到的是新文字。
          if (existing?.manual == true) {
            manualKept++;
            continue;
          }

          final String? reference = _referenceAnswerOf(
            bundle,
            answers: set.answers,
          );
          if (reference == null) {
            noAnswer++;
            continue;
          }
          if (!snapshot.hasWork) {
            unanswered++;
            continue;
          }

          final GradeEvidence evidence = GradeEvidence(
            text: entry.ocrText,
            sig: snapshot.signature,
            refHash: referenceHashOf(reference),
          );
          final bool fromAi = existing?.fromAi == true;
          final bool significantChange = fromAi
              ? isSignificantAnswerChange(
                  grade: existing!,
                  currentText: entry.ocrText,
                  currentReference: reference,
                  currentSignature: snapshot.signature,
                )
              : false;
          if (fromAi && !significantChange) {
            aiKept++;
            continue;
          }

          final LocalGrade local = judgeLocally(
            reference: reference,
            studentText: entry.ocrText,
            ocrConfidence: entry.ocrConfidence,
            hasWork: true,
          );
          final Map<String, GradeEvidence> evidenceById =
              <String, GradeEvidence>{id: evidence};
          final Map<String, String> notes = <String, String>{};

          switch (local.readiness) {
            case GradeReadiness.ready:
              if (fromAi) {
                notes[id] = '答案有明显改动，已按当前识别重判';
              }
              await controller.applyAuto(
                <String, AnswerVerdict>{id: local.verdict},
                evidence: evidenceById,
                notes: notes,
                replaceAi: fromAi,
              );
              if (local.verdict == AnswerVerdict.correct) {
                correct++;
              } else if (local.verdict == AnswerVerdict.wrong) {
                wrong++;
              }
            case GradeReadiness.untrusted:
              if (local.forceable && local.tentative != null) {
                // 用户口径：低置信度的客观题也按本地结论落判，结果里注明。
                lowConfidence++;
                notes[id] = fromAi
                    ? '答案有明显改动；低置信度本地判题（${local.reason}）'
                    : '低置信度本地判题（${local.reason}）';
                await controller.applyAuto(
                  <String, AnswerVerdict>{id: local.tentative!},
                  evidence: evidenceById,
                  notes: notes,
                  replaceAi: fromAi,
                );
                if (local.tentative == AnswerVerdict.correct) {
                  correct++;
                } else if (local.tentative == AnswerVerdict.wrong) {
                  wrong++;
                }
              } else {
                // 主观/公式/没有识别文字：标黄，汇总后问 AI。
                notes[id] = fromAi ? '答案有明显改动，本地仍判不了' : '';
                await controller.applyAuto(
                  <String, AnswerVerdict>{id: AnswerVerdict.pending},
                  evidence: evidenceById,
                  notes: notes,
                  replaceAi: fromAi,
                );
                untrusted.add(bundle);
                pending++;
              }
            case GradeReadiness.noAnswer:
              noAnswer++;
            case GradeReadiness.noWork:
              unanswered++;
          }
        } finally {
          if (mounted) {
            setState(() => _gradeDone++);
          }
        }
      }
    } finally {
      if (mounted) {
        setState(() {
          _grading = false;
          _gradeTotal = 0;
          _gradeDone = 0;
        });
      }
    }
    if (!mounted) {
      return;
    }
    _showReaderTip(
      '改卷：对 $correct · 错 $wrong · 待判 $pending · 未作答 $unanswered'
      ' · 无答案 $noAnswer · 重识别 $reOcr · 保留AI $aiKept · 保留手改 $manualKept'
      '${lowConfidence > 0 ? ' · 低置信 $lowConfidence' : ''}',
    );
    if (correct + wrong + pending + aiKept + manualKept + lowConfidence == 0 &&
        unanswered > 0) {
      await _showUnansweredSummary(unanswered);
    }
    if (untrusted.isEmpty) {
      return;
    }
    final LlmConfig config = await ref.read(llmConfigStoreProvider).load();
    if (config.validationError() != null) {
      if (mounted) {
        _showReaderTip('还有 $pending 道需要 AI；先在「设置 → AI 分析」配置');
      }
      return;
    }
    if (!mounted) {
      return;
    }
    final bool useAi = await _askAiGrade(
      count: untrusted.length,
      reason:
          '主观题/公式题/没有识别文字，本地规则判不了；'
          '低置信度的客观题已按本地结论落判',
    );
    if (useAi) {
      await _runAiGrading(untrusted, asked: '改卷：帮我判一下这道作答。');
    }
  }

  /// 一道都没判出来、且有一批未作答时给一次明确反馈。
  Future<void> _showUnansweredSummary(int count) async {
    final bool? go = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('这轮没有可判的作答'),
        content: Text(
          '有 $count 道题还没有作答（卷面作答框和答题卡都没有笔迹），已跳过。\n\n'
          '去答题卡写一遍，回来再改卷就会判了。',
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(height: 1.6),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('知道了'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('去答题卡'),
          ),
        ],
      ),
    );
    if (go == true && mounted) {
      final RegionSet set = _regionSetOf();
      final List<QuestionBundle> questions = _gradableQuestions(set);
      final QuestionBundle? target = questions.isEmpty ? null : questions.first;
      if (target != null) {
        _openAnswerSheetAt(target.question.id);
      }
    }
  }

  /// 弹窗询问是否把 N 道题交给 AI（不自动决定）。
  Future<bool> _askAiGrade({required int count, required String reason}) async {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Text('$count 道题需要 AI'),
        content: Text(
          '$reason。\n\n'
          '「改卷」= 只保留本地结果，这 $count 道保持黄点待判；\n'
          '「交给 AI 改」= 在后台逐题请求模型，会产生 $count 次请求，'
          '费用由你的服务商按调用量结算。',
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(height: 1.65),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('改卷'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('交给 AI 改'),
          ),
        ],
      ),
    );
    return ok ?? false;
  }

  /// 串行 AI 判一批题；页面内异步，不挡阅读，可点进度条上的「停止」。
  Future<void> _runAiGrading(
    List<QuestionBundle> bundles, {
    String asked = 'AI 判：帮我判一下这道作答。',
  }) async {
    if (_aiGrading || bundles.isEmpty) {
      return;
    }
    final LlmConfig config = await ref.read(llmConfigStoreProvider).load();
    if (config.validationError() != null) {
      if (mounted) {
        _showReaderTip('先在「设置 → AI 分析」填端点与 Key');
      }
      return;
    }
    final AiService service = ref.read(aiServiceProvider(widget.workbookId));
    if (!mounted) {
      return;
    }
    setState(() {
      _aiGrading = true;
      _aiGradeDone = 0;
      _aiGradeTotal = bundles.length;
      _aiGradeStop = false;
    });
    int graded = 0;
    int skipped = 0;
    try {
      for (final QuestionBundle bundle in bundles) {
        if (!mounted || _aiGradeStop) {
          break;
        }
        try {
          final AiGrade? grade = await _aiGradeOne(
            bundle,
            config: config,
            service: service,
            asked: asked,
          );
          if (grade != null) {
            graded++;
          } else {
            skipped++;
          }
        } on Object {
          skipped++;
        }
        if (mounted) {
          setState(() => _aiGradeDone++);
        }
      }
    } finally {
      if (mounted) {
        setState(() {
          _aiGrading = false;
          _aiGradeStop = false;
        });
      }
    }
    if (mounted) {
      _showReaderTip(
        'AI 判完成：判了 $graded 道'
        '${skipped > 0 ? ' · 跳过 $skipped 道（没作答或调用失败）' : ''}',
      );
    }
  }

  /// AI 判一道题并写回（判题 + 该题「问 AI」对话）。没有作答返回 null。
  Future<AiGrade?> _aiGradeOne(
    QuestionBundle bundle, {
    required LlmConfig config,
    required AiService service,
    String asked = 'AI 判：帮我判一下这道作答。',
    AnswerSet? answers,
  }) async {
    // AI 判也要用当前笔迹对应的 OCR；否则「我刚改完答案，AI 还在看旧文字」。
    final _AnswerInkSnapshot snapshot = await _ensureFreshAnswerOcr(bundle);
    final AnswerSheetEntry entry = snapshot.entry;
    final List<AiImageAttachment> attachments = await _aiAttachmentsOf(bundle);
    final bool hasWork =
        snapshot.hasWork ||
        attachments.any(
          (AiImageAttachment item) => item.kind == AiImageKind.answer,
        );
    if (!hasWork) {
      return null;
    }
    final String? reference = _referenceAnswerOf(bundle, answers: answers);
    final AiGrade grade = await service.grade(
      config: config,
      payload: _aiPayloadOf(bundle),
      referenceAnswer: reference,
      studentAnswerText: entry.ocrText,
      attachments: attachments,
    );
    final bool applied =
        await _grades?.applyAi(
          bundle.question.id,
          grade.verdict,
          note: grade.reason,
          evidence: GradeEvidence(
            text: entry.ocrText,
            sig: snapshot.signature,
            refHash: referenceHashOf(reference),
          ),
        ) ??
        false;
    await _appendBatchAiTurns(
      bundle,
      grade: grade,
      applied: applied,
      referenceAnswer: reference,
      asked: asked,
    );
    return grade;
  }

  /// 「AI 补答案」（2026-10-26 用户第 1 条）。
  ///
  /// 给**没有参考答案**的题补一份 AI 答案：题面图发给模型，它做一遍，
  /// 答案写进 `layout/answers_ai.v1.json`（PDF 里的答案仍然优先）。
  ///
  /// 为什么要单独做一个动作：卷子里的答案常常只解析出一部分
  /// （尤其是扫描件），剩下的题连"对答案"都无从谈起。
  /// 补齐之后，判题与「问 AI」才有东西可对照。
  Future<void> _fillAnswersWithAi() async {
    if (_grading || _fillingAi || _batchAiRunning || _aiGrading) {
      return;
    }
    final RegionSet set = _regionSetOf();
    final List<QuestionBundle> targets = <QuestionBundle>[
      for (final QuestionBundle bundle in _gradableQuestions(set))
        if (!_hasReferenceAnswer(bundle, set)) bundle,
    ];
    if (targets.isEmpty) {
      _showReaderTip('这卷的题都已有答案了');
      return;
    }
    final LlmConfig config = await ref.read(llmConfigStoreProvider).load();
    if (config.validationError() != null) {
      _showReaderTip('先在「设置 → AI 分析」填端点与 Key');
      return;
    }
    final AiService service = ref.read(aiServiceProvider(widget.workbookId));
    setState(() {
      _fillingAi = true;
      _fillDone = 0;
      _fillTotal = targets.length;
    });
    final LayoutStore store = ref.read(layoutStoreProvider);
    AnswerSet next = AnswerSet.fromJson(
      await store.readAiAnswers(widget.workbookId),
    );
    int filled = 0;
    int skipped = 0;
    try {
      for (final QuestionBundle bundle in targets) {
        if (!mounted) {
          return;
        }
        try {
          final AiSolution solution = await service.solve(
            config: config,
            payload: _aiPayloadOf(bundle),
            attachments: await _aiAttachmentsOf(bundle, includeAnswer: false),
          );
          final String answer = solution.answer.trim();
          if (answer.isEmpty) {
            skipped++;
          } else {
            final AnswerNote note = AnswerNote(
              label: _answerLabelOf(bundle),
              text: answer,
              source: 'ai',
              pageIndex: bundle.slices.first.pageIndex,
              ordinal: bundle.question.ordinal,
            );
            next = next.withNote(note);
            // 逐题落盘 + 内存覆盖：中途退出/被杀，已补的答案也留得住。
            // 不 invalidate provider（那会让整卷闪一下/跳一下），
            // 用 _liveAiAnswers 先在当前页生效，重新进卷自然从文件读到。
            await store.writeAiAnswers(widget.workbookId, next.toJson());
            if (mounted) {
              setState(() {
                _liveAiAnswers = _liveAiAnswers.withNote(note);
              });
            } else {
              _liveAiAnswers = _liveAiAnswers.withNote(note);
            }
            filled++;
          }
        } on Object {
          skipped++;
        } finally {
          if (mounted) {
            setState(() => _fillDone++);
          }
        }
      }
    } finally {
      if (mounted) {
        setState(() {
          _fillingAi = false;
          _fillTotal = 0;
        });
        // 实时阶段用 _liveAiAnswers 覆盖，避免每补一题就 invalidate 闪一下；
        // 整批结束再同步 provider，保证退出/重进也读到已落盘的答案。
        if (filled > 0) {
          ref.invalidate(regionSetProvider(widget.workbookId));
        }
        _showReaderTip('补答案完成：补了 $filled 道 · 跳过 $skipped 道（没题面或调用失败）');
      }
    }
  }

  /// 多选批量「AI 判」（2026-10-26 用户第 7 条）。
  ///
  /// 三步走一步都不能少：
  /// 1. **缺答案的先补答案**（否则模型没有参考答案可比）；
  /// 2. **判题**（写 `grading.v1.json`，不覆盖用户手改）；
  /// 3. **写进该题的「问 AI」对话**——用户在那一题里能看到这次判了什么、
  ///    为什么判成对/错/拿不准。
  Future<void> _gradeSelectedWithAi(List<QuestionBundle> picked) async {
    if (_batchAiRunning || _fillingAi || _aiGrading || _grading) {
      return;
    }
    if (picked.isEmpty) {
      return;
    }
    final LlmConfig config = await ref.read(llmConfigStoreProvider).load();
    if (config.validationError() != null) {
      _showReaderTip('先在「设置 → AI 分析」填端点与 Key');
      return;
    }
    final AiService service = ref.read(aiServiceProvider(widget.workbookId));
    final LayoutStore store = ref.read(layoutStoreProvider);
    final RegionSet set = _regionSetOf();
    final AnswerSet baseAnswers = set.answers;
    setState(() => _batchAiRunning = true);
    int filled = 0;
    int graded = 0;
    int skipped = 0;
    try {
      // 1) 只给没有参考答案的题补答案；已有答案的题不重复生成。
      AnswerSet next = AnswerSet.fromJson(
        await store.readAiAnswers(widget.workbookId),
      );
      for (final QuestionBundle bundle in picked) {
        if (!mounted) {
          return;
        }
        if (_hasReferenceAnswer(bundle, set) || bundle.slices.isEmpty) {
          continue;
        }
        // 没有作答的题补答案会白花 token；这类题直接跳过（用户要的是判作答）。
        if (!await _hasStudentWorkAsync(bundle)) {
          continue;
        }
        try {
          final AiSolution solution = await service.solve(
            config: config,
            payload: _aiPayloadOf(bundle),
            attachments: await _aiAttachmentsOf(bundle, includeAnswer: false),
          );
          final String answer = solution.answer.trim();
          if (answer.isEmpty) {
            continue;
          }
          final AnswerNote note = AnswerNote(
            label: _answerLabelOf(bundle),
            text: answer,
            source: 'ai',
            pageIndex: bundle.slices.first.pageIndex,
            ordinal: bundle.question.ordinal,
          );
          next = next.withNote(note);
          // 与「AI 补答案」同口径：逐题写盘 + 当前页内存覆盖。
          await store.writeAiAnswers(widget.workbookId, next.toJson());
          if (mounted) {
            setState(() {
              _liveAiAnswers = _liveAiAnswers.withNote(note);
            });
          } else {
            _liveAiAnswers = _liveAiAnswers.withNote(note);
          }
          filled++;
        } on Object {
          // 单题补答案失败不中断整批；判题阶段会按"没有参考答案"处理。
        }
      }

      // 2) 逐题判 + 3) 写回对话。
      //
      // 关键：用内存里刚合并好的答案集，不要从已 invalidate 的 provider 取
      //（否则刚补的答案读不到，模型会以为没有参考答案）。
      final AnswerSet merged = baseAnswers.mergeMissing(next);
      for (final QuestionBundle bundle in picked) {
        if (!mounted) {
          return;
        }
        try {
          final AiGrade? grade = await _aiGradeOne(
            bundle,
            config: config,
            service: service,
            answers: merged,
          );
          if (grade == null) {
            skipped++;
          } else {
            graded++;
          }
        } on Object {
          skipped++;
        }
      }
    } finally {
      if (mounted) {
        setState(() => _batchAiRunning = false);
        // 同补答案：实时靠 _liveAiAnswers，收尾再同步一次 provider。
        if (filled > 0) {
          ref.invalidate(regionSetProvider(widget.workbookId));
        }
        final String filledText = filled > 0 ? ' · 补答案 $filled 道' : '';
        _showReaderTip(
          'AI 判完成：判了 $graded 道$filledText'
          '${skipped > 0 ? ' · 跳过 $skipped 道（没作答或调用失败）' : ''}',
        );
      }
    }
  }

  /// 把这次批量判题的结论写进该题的「问 AI」对话。
  ///
  /// 用户在题目面板点「问 AI」时看到的就是这一段——所以这里要写全：
  /// 问了什么、参考答案是多少、判成什么、为什么。
  Future<void> _appendBatchAiTurns(
    QuestionBundle bundle, {
    required AiGrade grade,
    required bool applied,
    String? referenceAnswer,
    String asked = '批量 AI 判：帮我判一下这道作答。',
  }) async {
    try {
      final AiChatStore store = ref.read(
        aiChatStoreProvider(widget.workbookId),
      );
      final List<ChatTurn> turns = await store.load(
        widget.workbookId,
        bundle.question.id,
      );
      final int at = DateTime.now().millisecondsSinceEpoch;
      await store.save(widget.workbookId, bundle.question.id, <ChatTurn>[
        ...turns,
        ChatTurn.user(asked, at: at),
        if (referenceAnswer != null && referenceAnswer.trim().isNotEmpty)
          ChatTurn(
            role: ChatRole.assistant,
            text: '参考答案：\n$referenceAnswer',
            at: at,
            kind: ChatTurnKind.answer,
            referenceAnswer: referenceAnswer,
          ),
        ChatTurn(
          role: ChatRole.assistant,
          text: grade.reason,
          at: at,
          kind: ChatTurnKind.verdict,
          verdict: grade.verdict,
          applied: applied,
        ),
      ]);
    } on Object {
      // 写对话失败不影响判题结果（判题已经落库了）。
    }
  }

  /// 这道题有没有参考答案（PDF 的或 AI 补的）。
  bool _hasReferenceAnswer(QuestionBundle bundle, RegionSet set) {
    final AnswerNote? note = set.answers.forQuestion(
      ordinal: bundle.question.ordinal,
      label: bundle.question.label,
    );
    return note != null && note.text.trim().isNotEmpty;
  }

  /// 答案库里的题号口径（与 [_saveAiAnswer] 一致）。
  String _answerLabelOf(QuestionBundle bundle) =>
      bundle.question.label ?? '${bundle.question.ordinal}';

  Future<void> _setVerdict(QuestionBundle bundle, AnswerVerdict verdict) async {
    await _grades?.setManual(bundle.question.id, verdict);
  }

  VerdictCounts? _gradeCounts(RegionSet set) {
    final GradingController? controller = _grades;
    if (controller == null) {
      return null;
    }
    return controller.data.value.countsOf(<String>[
      for (final QuestionBundle bundle in _gradableQuestions(set))
        bundle.question.id,
    ]);
  }

  void _toggleMultiSelect() {
    setState(() {
      _multiSelecting = !_multiSelecting;
      if (!_multiSelecting) {
        _multiSelected.clear();
      }
    });
  }

  void _toggleSelect(QuestionBundle bundle) {
    setState(() {
      final String id = bundle.question.id;
      if (!_multiSelected.add(id)) {
        _multiSelected.remove(id);
      }
    });
  }

  /// 批量动作：收藏 / 对答案。
  Future<void> _runBatch(RegionPanelBatch action) async {
    final List<QuestionBundle> picked = <QuestionBundle>[
      for (final QuestionBundle bundle in _regionSetOf().questions)
        if (_multiSelected.contains(bundle.question.id)) bundle,
    ];
    if (picked.isEmpty) {
      return;
    }
    switch (action) {
      case RegionPanelBatch.favorite:
        final FavoriteStore store = ref.read(favoriteStoreProvider);
        // 先摸清这一批里哪些已经收藏、哪些没有：
        // - 全都收藏过 → 再点一次是**取消收藏**（用户第 1 条）；
        // - 全都没收藏 → 收藏；
        // - 混合 → 只补没收藏的，已有收藏不动（不 silently 删除）。
        final List<String> existingIds = <String>[];
        final List<QuestionBundle> missing = <QuestionBundle>[];
        for (final QuestionBundle bundle in picked) {
          final String? id = await store.idOfQuestion(bundle.question.id);
          if (id == null) {
            missing.add(bundle);
          } else {
            existingIds.add(id);
          }
        }
        if (existingIds.length == picked.length) {
          int removed = 0;
          for (final String id in existingIds) {
            try {
              await store.remove(id);
              removed++;
            } on Object {
              // 单题失败不中断整批。
            }
          }
          if (mounted) {
            ref.invalidate(favoritesProvider);
            _showReaderTip('已取消收藏 $removed 道题');
          }
          return;
        }
        int added = 0;
        for (final QuestionBundle bundle in missing) {
          final FavoriteCapture? capture = await _buildFavoriteCapture(bundle);
          if (capture == null) {
            continue;
          }
          try {
            await store.capture(capture);
            added++;
          } on Object {
            // 单题失败不中断整批。
          }
        }
        if (mounted) {
          ref.invalidate(favoritesProvider);
          final int kept = existingIds.length;
          _showReaderTip(
            kept == 0 ? '已收藏 $added 道题' : '已收藏 $added 道题 · $kept 道本来就在收藏夹',
          );
        }
      case RegionPanelBatch.aiGrade:
        // 2026-10-26 用户第 7 条：批量「对答案」换成「AI 判」——
        // 补答案 → 判题 → 把结论写进该题的「问 AI」对话。
        await _gradeSelectedWithAi(picked);
    }
  }

  /// 把虚线作答框**提升为一道题目**（用户第 10 条）。
  ///
  /// 走的是同一个覆盖层（`AddQuestionCorrection`），所以可撤销、重切题也保留；
  /// 题号给一个"最大数字 +1"的默认值，用户可以在列表里改。
  Future<void> _promoteAnswerToQuestion(
    RegionSet set,
    String questionId,
  ) async {
    final QuestionBundle? bundle = _bundleById(set, questionId);
    if (bundle == null) {
      return;
    }
    final AnswerSheetEntry entry = _answerEntryOf(bundle);
    if (entry.rect.isEmpty) {
      return;
    }
    await ref
        .read(regionEditProvider(widget.workbookId))
        .run(
          AddQuestionCorrection(
            id: Ulid.next(),
            key: '',
            label: nextQuestionLabel(set),
            rect: entry.rect,
            page: entry.pageIndex,
          ),
        );
    if (mounted) {
      _showReaderTip('已把这一块加为题目，可在列表里改题号');
    }
  }

  /// 保存题目图片。返回一句给用户看的结果（由长按浮窗就地显示）。
  ///
  /// 优先走原生 MediaStore 存进相册（Android 10+ 不需要存储权限）；
  /// 原生通道不可用时退回应用导出目录，至少不丢图。
  Future<String?> _saveQuestionImage(QuestionBundle bundle) async {
    final ReaderHandle? handle = _handle;
    final PageImageCache? cache = _cache;
    if (handle == null || cache == null || bundle.slices.isEmpty) {
      return null;
    }
    final QuestionSlice slice = bundle.slices.first;
    if (slice.pageIndex < 0 || slice.pageIndex >= handle.pages.length) {
      return null;
    }
    try {
      final Uint8List? bytes = await renderAnswerCropPng(
        cache: cache,
        page: handle.pages[slice.pageIndex],
        rect: slice.rect,
        doc: InkDoc.empty,
      );
      if (bytes == null) {
        return '题目图片生成失败';
      }
      final String label =
          (bundle.question.label ?? '${bundle.question.ordinal}').replaceAll(
            RegExp(r'[^\w\u4e00-\u9fa5-]'),
            '_',
          );
      final String name =
          'shuaqi_${label}_${bundle.question.id.substring(0, 6)}.png';
      try {
        await _mediaChannel.invokeMethod<String>('saveImage', <String, Object>{
          'bytes': bytes,
          'name': name,
        });
        return '已保存到相册';
      } on PlatformException {
        // 通道不可用/被拒绝：落应用导出目录兜底。
      } on MissingPluginException {
        // 同上。
      }
      final String path = VaultPaths.exportQuestionImage(
        widget.workbookId,
        bundle.question.id,
      );
      await ref
          .read(appDependenciesProvider)
          .vault
          .writeAtomically(path, bytes);
      return '已保存到应用导出目录';
    } on Object {
      return '题目图片保存失败';
    }
  }

  /// 题面图片的动作（长按侧边浮窗用）。B 批：题目原图只有"存相册"一件事。
  List<ImageAction> _questionImageActions(QuestionBundle bundle) =>
      <ImageAction>[
        ImageAction(
          label: '保存到相册',
          subtitle: '题目原图，适合发给老师或 AI',
          icon: Icons.download_outlined,
          onSelected: () => _saveQuestionImage(bundle),
        ),
      ];

  /// 打开题面大图（2026-10-24 用户第 2 条：预览必须单独弹窗、比例真实）。
  ///
  /// 图片按**整题真实宽高比**显示：长题限高并居中，极宽的题占满横向；
  /// 弹窗内可双指放大拖动，再点一下回到面板原尺寸。
  Future<void> _showQuestionImage(QuestionBundle bundle) async {
    final ReaderHandle? handle = _handle;
    final PageImageCache? cache = _cache;
    if (handle == null || cache == null || bundle.slices.isEmpty) {
      return;
    }
    final QuestionSlice slice = bundle.slices.first;
    if (slice.pageIndex < 0 || slice.pageIndex >= handle.pages.length) {
      return;
    }
    final WbPage page = handle.pages[slice.pageIndex];
    final String label = bundle.question.label ?? '${bundle.question.ordinal}';
    await showImageViewer(
      context,
      title: '第 ${slice.pageIndex + 1} 页 · 第 $label 题',
      aspectRatio: slice.rect.width / math.max(1, slice.rect.height),
      actions: _questionImageActions(bundle),
      builder: (BuildContext context, Size size) => QuestionThumb(
        cache: cache,
        page: page,
        rect: slice.rect,
        width: size.width,
        height: size.height,
        paperColor: ShqPaper.base,
      ),
    );
  }

  /// 面板里长按题面预览：贴着图片右侧出浮窗（不再直接保存）。
  void _openQuestionImageActions(QuestionBundle bundle) {
    final Size screen = MediaQuery.sizeOf(context);
    unawaited(
      showImageActions(
        context,
        anchor: Offset(screen.width, screen.height * 0.42),
        actions: _questionImageActions(bundle),
      ),
    );
  }

  void _toggleShowAnswers(bool value) {
    setState(() => _showAnswers = value);
  }

  /// 面板「保存修改」：把切题覆盖层、作答框、手动顺序和笔迹一起落盘。
  ///
  /// 这些改动平时都有自动保存；这个按钮给用户一个**确定的提交点**，
  /// 也是"保存切题修改"这个需求最直接的落点。
  Future<void> _saveEdits() async {
    if (_savingEdits) {
      return;
    }
    setState(() => _savingEdits = true);
    try {
      final Future<void> Function()? flushRegions = _flushRegions;
      if (flushRegions != null) {
        await flushRegions();
      }
      final AnswerSheetController? answers = _answerSheet;
      if (answers != null) {
        final Set<String> keep = <String>{
          for (final QuestionBundle bundle in _regionSetOf().questions)
            bundle.question.id,
        };
        await answers.prune(keep);
        await answers.flush();
      }
      final QuestionOrderController? order = _questionOrder;
      if (order != null) {
        final Set<String> keep = <String>{
          for (final QuestionBundle bundle in _regionSetOf().questions)
            bundle.question.id,
        };
        await order.prune(keep);
        await order.flush();
      }
      // 判题结果同样是用户产物：删过题之后把幽灵记录清掉并落盘。
      final GradingController? grades = _grades;
      if (grades != null) {
        await grades.prune(<String>{
          for (final QuestionBundle bundle in _regionSetOf().questions)
            bundle.question.id,
        });
        await grades.flush();
      }
      final Future<void> Function()? flushAll = _flushAllInk;
      if (flushAll != null) {
        await flushAll();
      }
      if (mounted) {
        // 保存 = 本次"改了哪几道题"的提示使命结束（面板据此把提示收掉）。
        setState(() {
          _saveTick += 1;
          _lastSavedAt = DateTime.now();
        });
        _showReaderTip('修改已保存');
      }
    } on Object {
      if (mounted) {
        _showReaderTip('保存失败，请稍后再试');
      }
    } finally {
      if (mounted) {
        setState(() => _savingEdits = false);
      }
    }
  }

  /// 下载答题信息：含题目合并图 / 仅白底笔迹图。
  ///
  /// 不传 [includeQuestion] 时先弹选择；传了就按选择直接导出。
  /// **返回一句给用户看的结果**（长按浮窗就地显示），不再自己弹提示——
  /// 同一件事在两个地方各弹一次提示会互相打架（2026-10-24）。
  Future<String?> _downloadAnswerImage(
    QuestionBundle bundle, {
    bool? includeQuestion,
    bool silent = false,
  }) async {
    if (includeQuestion == null) {
      final bool? picked = await showModalBottomSheet<bool>(
        context: context,
        showDragHandle: true,
        backgroundColor: Theme.of(context).colorScheme.surfaceContainerHigh,
        builder: (BuildContext context) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              ListTile(
                leading: const Icon(Icons.image_outlined),
                title: const Text('含题目：题目 + 作答'),
                subtitle: const Text('一张合并图，适合发给 AI / 老师'),
                onTap: () => Navigator.of(context).pop(true),
              ),
              ListTile(
                leading: const Icon(Icons.draw_outlined),
                title: const Text('仅笔迹：白底手写'),
                subtitle: const Text('不含题目，适合判题 / 归档'),
                onTap: () => Navigator.of(context).pop(false),
              ),
              const SizedBox(height: ShqSpace.sm),
            ],
          ),
        ),
      );
      if (picked == null || !mounted) {
        return null;
      }
      includeQuestion = picked;
    }

    final ReaderHandle? handle = _handle;
    final PageImageCache? cache = _cache;
    final AnswerSheetController? controller = _answerSheet;
    if (handle == null || cache == null || controller == null) {
      return null;
    }
    final AnswerSheetEntry entry = controller.entryFor(bundle);
    if (entry.rect.isEmpty || bundle.slices.isEmpty) {
      return null;
    }
    if (!silent && _savingAnswerCrop) {
      return null;
    }
    if (!silent) {
      setState(() => _savingAnswerCrop = true);
    }
    try {
      final List<InkDoc> sheetDocs = await _loadAnswerInkPages(bundle);
      final AnswerPaper paper = (await _papersOf()).forQuestion(
        bundle.question.id,
      );
      final int pageIndex = entry.pageIndex.clamp(0, handle.pages.length - 1);
      await ref
          .read(inkWriterProvider(widget.workbookId))
          .flush(handle.session.id, pageIndex);
      final InkDoc pageDoc = await ref
          .read(inkStoreProvider(widget.workbookId))
          .load(handle.session.id, pageIndex);
      final bool hasSheetInk = sheetDocs.any(
        (InkDoc d) => d.strokes.isNotEmpty,
      );
      final List<InkStroke> pageStrokes = _strokesInRect(pageDoc, entry.rect);
      final bool hasPageInk = pageStrokes.isNotEmpty;
      if (!hasSheetInk && !hasPageInk) {
        return '还没有手写内容';
      }

      Uint8List? bytes;
      String path;
      if (hasSheetInk) {
        if (includeQuestion) {
          final QuestionSlice slice = bundle.slices.first;
          if (slice.pageIndex < 0 || slice.pageIndex >= handle.pages.length) {
            return '题目页无效，无法合成含题图';
          }
          bytes = await renderAnswerSheetWithQuestionPng(
            cache: cache,
            page: handle.pages[slice.pageIndex],
            rect: slice.rect,
            docs: sheetDocs,
            widthPt: paper.widthPt,
            heightPt: paper.heightPt,
          );
          path = VaultPaths.answerSheetExport(
            widget.workbookId,
            bundle.question.id,
          );
        } else {
          bytes = await renderAnswerSheetInkPng(
            docs: sheetDocs,
            widthPt: paper.widthPt,
            heightPt: paper.heightPt,
          );
          path = VaultPaths.answerInkExport(
            widget.workbookId,
            bundle.question.id,
          );
        }
      } else {
        if (includeQuestion) {
          bytes = await renderAnswerCropPng(
            cache: cache,
            page: handle.pages[pageIndex],
            rect: entry.rect,
            doc: pageDoc,
            darkPaper: false,
          );
          path = VaultPaths.answerCrop(widget.workbookId, bundle.question.id);
        } else {
          bytes = await renderPageInkOnlyPng(rect: entry.rect, doc: pageDoc);
          path = VaultPaths.answerInkExport(
            widget.workbookId,
            bundle.question.id,
          );
        }
      }
      if (bytes == null || bytes.isEmpty) {
        return '答题图片生成失败';
      }
      await ref
          .read(appDependenciesProvider)
          .vault
          .writeAtomically(path, bytes);
      await controller.updateCrop(bundle, cropPath: path);
      if (!mounted) {
        return null;
      }
      final String label =
          (bundle.question.label ?? '${bundle.question.ordinal}').replaceAll(
            RegExp(r'[^\w\u4e00-\u9fa5-]'),
            '_',
          );
      final String suffix = includeQuestion ? 'with_question' : 'ink';
      final String name =
          'shuaqi_answer_${label}_${bundle.question.id.substring(0, 6)}_$suffix.png';
      try {
        await _mediaChannel.invokeMethod<String>('saveImage', <String, Object>{
          'bytes': bytes,
          'name': name,
        });
        return includeQuestion ? '已保存含题图到相册' : '已保存仅笔迹图到相册';
      } on Object {
        // 原生通道不可用：图已经写进 Vault，不算失败。
        return includeQuestion ? '已保存含题图（应用目录）' : '已保存仅笔迹图（应用目录）';
      }
    } on Object {
      return '答题图片保存失败';
    } finally {
      if (mounted && !silent) {
        setState(() => _savingAnswerCrop = false);
      }
    }
  }

  Future<InkDoc> _loadAnswerInk(QuestionBundle bundle) async {
    final ReaderHandle? handle = _handle;
    if (handle == null) {
      return InkDoc.empty;
    }
    final InkPageKey key = InkPageKey(
      answerInkSessionId(handle.session.id, bundle.question.id),
      0,
      workbookId: widget.workbookId,
    );
    try {
      await ref.read(inkEditProvider(key).notifier).flushSave();
      return await ref.read(inkStoreForKeyProvider(key)).load(key.sessionId, 0);
    } on Object {
      return InkDoc.empty;
    }
  }

  /// 这一题的全部纸张配置（进程内缓存一次，换配置由答题卡页写盘后重进生效）。
  AnswerPaperData? _answerPapers;

  Future<AnswerPaperData> _papersOf() async {
    final AnswerPaperData? cached = _answerPapers;
    if (cached != null) {
      return cached;
    }
    final AnswerPaperData data = await AnswerPaperStore(
      ref.read(layoutStoreProvider),
    ).load(widget.workbookId);
    _answerPapers = data;
    return data;
  }

  /// 这一题**所有张**的笔迹（按顺序）。多张作答要一起识别/导出。
  Future<List<InkDoc>> _loadAnswerInkPages(QuestionBundle bundle) async {
    final ReaderHandle? handle = _handle;
    if (handle == null) {
      return const <InkDoc>[];
    }
    final AnswerPaperData papers = await _papersOf();
    final int pages = papers.forQuestion(bundle.question.id).pages;
    final String sid = answerInkSessionId(
      handle.session.id,
      bundle.question.id,
    );
    final List<InkDoc> docs = <InkDoc>[];
    for (int i = 0; i < pages; i++) {
      final InkPageKey key = InkPageKey(sid, i, workbookId: widget.workbookId);
      try {
        await ref.read(inkEditProvider(key).notifier).flushSave();
        docs.add(
          await ref.read(inkStoreForKeyProvider(key)).load(key.sessionId, i),
        );
      } on Object {
        docs.add(InkDoc.empty);
      }
    }
    return docs;
  }

  List<InkStroke> _strokesInRect(InkDoc doc, RegionRect rect) {
    return <InkStroke>[
      for (final InkStroke stroke in doc.strokes)
        if (stroke.points.isNotEmpty &&
            (rect.contains(stroke.points.first.x, stroke.points.first.y) ||
                rect.contains(stroke.bounds.centerX, stroke.bounds.centerY)))
          stroke,
    ];
  }

  /// 「答题情况」卡里的 OCR：优先答题卡，其次 PDF 页内该作答框的笔画。
  ///
  /// [silent] = 自动触发（展开卡片时）：不弹任何提示，结果只落在卡片文字上；
  /// 用户主动双击重生成时走非 silent，过程与结果都给一句。
  ///
  /// 识别结果为空也要写回 `ocr_at` + `ink_sig`：否则「本来就没识别出字」的题
  /// 每次展开都会重跑模型（用户会觉得一直转圈）。识别抛异常则不写，
  /// 保留旧指纹以便下次重试。
  Future<void> _recognizePanelAnswer(
    QuestionBundle bundle, {
    bool silent = false,
    _AnswerInkSnapshot? snapshot,
  }) async {
    final ReaderHandle? handle = _handle;
    final AnswerSheetController? controller = _answerSheet;
    if (handle == null || controller == null) {
      return;
    }
    if (!silent) {
      _showReaderTip('正在识别…首次使用会下载本地模型');
    }
    try {
      final _AnswerInkSnapshot data =
          snapshot ?? await _answerInkSnapshotOf(bundle);
      final List<InkDoc> targets = <InkDoc>[
        for (final InkDoc doc in data.sheetDocs)
          if (doc.strokes.isNotEmpty) doc,
      ];
      if (targets.isEmpty && data.pageStrokes.isNotEmpty) {
        targets.add(InkDoc(revision: 0, strokes: data.pageStrokes));
      }
      if (targets.isEmpty) {
        if (!silent) {
          _showReaderTip('这道题还没有手写内容');
        }
        return;
      }
      final MlKitInkEngine engine = _panelOcr ??= MlKitInkEngine();
      final StringBuffer buffer = StringBuffer();
      double confidenceSum = 0;
      int confidenceCount = 0;
      for (final InkDoc doc in targets) {
        final OcrOutput output = await engine.recognizeStrokes(
          doc.strokes,
          revision: 0,
        );
        if (output.text.trim().isEmpty) {
          continue;
        }
        if (buffer.isNotEmpty) {
          buffer.writeln();
        }
        buffer.write(output.text);
        confidenceSum += output.confidence;
        confidenceCount += 1;
      }
      if (!mounted) {
        return;
      }
      final String text = buffer.toString();
      final double confidence = confidenceCount == 0
          ? 0
          : confidenceSum / confidenceCount;
      await controller.updateOcr(
        bundle,
        text: text,
        confidence: confidence,
        engine: engine.name,
        inkSig: data.signature,
      );
      if (!mounted) {
        return;
      }
      if (!silent) {
        if (text.trim().isEmpty) {
          _showReaderTip('未识别出文字；公式/符号可先保留原图');
        } else {
          final String preview = text.replaceAll('\n', ' ');
          _showReaderTip(
            '识别完成：${preview.length > 28 ? preview.substring(0, 28) : preview}',
          );
        }
      }
    } on Object {
      if (mounted && !silent) {
        _showReaderTip('本地 OCR 不可用');
      }
    }
  }

  /// 按 anchor key 找题（找不到返回 null）。
  QuestionBundle? _bundleOf(RegionSet set, String key) {
    for (final QuestionBundle bundle in set.questions) {
      if (bundle.anchorKey == key) {
        return bundle;
      }
    }
    return null;
  }

  /// 上一道"有区域"的题 = 合并目标（规格：保留先出现者）。
  QuestionBundle? _previousOf(RegionSet set, QuestionBundle bundle) {
    final int index = set.questions.indexWhere(
      (QuestionBundle item) => item.anchorKey == bundle.anchorKey,
    );
    if (index <= 0) {
      return null;
    }
    for (int i = index - 1; i >= 0; i--) {
      if (set.questions[i].slices.isNotEmpty) {
        return set.questions[i];
      }
    }
    return null;
  }

  /// 这道题此刻能用哪些动作。
  ///
  /// 不可用的动作**灰掉而不是藏起来**：用户看到"并入上题"是灰的，会知道
  /// "这已经是第一题"，而不是以为这个功能不存在。
  Set<RegionAction> _actionsFor(
    QuestionBundle bundle,
    RegionSet set,
    ReaderHandle handle,
  ) {
    // 2026-10-26 用户第 18 条：**锁定后只保留改题号**。
    // 锁定原来的语义只是"重新切题不覆盖它"，用户以为锁了就是"框不能动"；
    // 现在门禁做实：拖框 / 切开 / 并入 / 跨页 / 加题 / 删除全部禁用，
    // 想改框必须先解锁。
    if (bundle.locked) {
      return allowedActionsWhenLocked();
    }
    final Set<RegionAction> out = <RegionAction>{
      RegionAction.split,
      RegionAction.lock,
      RegionAction.rename,
      RegionAction.delete,
      // 2026-10-24 用户第 10 条：题目框上也能"加题"——
      // 切题把两道题并成一条时，从中间加一道回去比"切开"更直观。
      RegionAction.addQuestion,
    };
    if (_previousOf(set, bundle) != null) {
      out.add(RegionAction.merge);
    }
    if (bundle.slices.isNotEmpty &&
        bundle.slices.last.pageIndex < handle.pages.length - 1) {
      out.add(RegionAction.extend);
    }
    return out;
  }

  /// 执行一个框操作。三个入口（贴框浮动条 / 面板条目 / 长按菜单）共用这一条路径。
  Future<void> _applyAction(
    QuestionBundle bundle,
    RegionAction action,
    ReaderHandle handle,
    RegionSet set,
  ) async {
    final RegionEditController edit = ref.read(
      regionEditProvider(widget.workbookId),
    );
    final String key = bundle.anchorKey;
    switch (action) {
      case RegionAction.addQuestion:
        // 2026-10-27 用户：虚线框上的「加题」= **就地确认**，不是"再加一道"。
        //
        // 具体走哪条 correction 由 [addQuestionFor] 决定（纯函数，已单测）：
        // - 虚线框（level ≤ 1）→ ConfirmQuestionCorrection：题号 / 面板位置 /
        //   题目 id 全都不变，只把虚线变实线；
        // - 实线题（level ≥ 2）→ 在本题下方新增一道（题号接现有最大号 +1）。
        //
        // 旧实现把第一种也做成了 AddQuestion + Delete：题号被改成最大号 +1，
        // 在面板里也跳到了末尾 —— 已被用户指出并修正。
        final RegionCorrection op = addQuestionFor(
          bundle: bundle,
          set: set,
          id: Ulid.next(),
          key: key,
        );
        await edit.run(op);
        if (op is ConfirmQuestionCorrection && mounted) {
          _showReaderTip('已确认这一块是题目（题号不变，虚线框已变实线）');
        }
      case RegionAction.split:
        final QuestionSlice slice = bundle.slices.firstWhere(
          (QuestionSlice s) => s.pageIndex == _current,
          orElse: () => bundle.slices.first,
        );
        await edit.run(
          SplitCorrection(
            id: Ulid.next(),
            key: key,
            page: slice.pageIndex,
            atY: slice.rect.centerY,
          ),
        );
      case RegionAction.merge:
        final QuestionBundle? previous = _previousOf(set, bundle);
        if (previous == null) {
          return;
        }
        await edit.run(
          MergeCorrection(
            id: Ulid.next(),
            key: previous.anchorKey,
            fromKey: key,
          ),
        );
        _selectBundle(previous);
      case RegionAction.extend:
        final int nextPage = bundle.slices.last.pageIndex + 1;
        if (nextPage >= handle.pages.length) {
          return;
        }
        final WbPage page = handle.pages[nextPage];
        final RegionRect last = bundle.slices.last.rect;
        await edit.run(
          AddSliceCorrection(
            id: Ulid.next(),
            key: key,
            page: nextPage,
            rect: RegionRect.fromLTRB(
              last.left,
              page.height * 0.06,
              last.right,
              page.height * 0.45,
            ),
          ),
        );
      case RegionAction.lock:
        await edit.run(
          LockCorrection(id: Ulid.next(), key: key, value: !bundle.locked),
        );
      case RegionAction.rename:
        await _renameRegion(bundle);
      case RegionAction.delete:
        await edit.run(DeleteCorrection(id: Ulid.next(), key: key));
        if (mounted) {
          setState(() => _selected = null);
        }
    }
  }

  /// 改题号（浮动条点题号 / 面板条目 / 长按菜单共用）。
  ///
  /// 为什么必须有：扫描件与版面切块**认不出数字**，标签只是序号。用户手填一个
  /// "12."，这一题在第 4 周喂给 AI 时才有真正的题号，面板上也能一眼对上卷面。
  Future<void> _renameRegion(QuestionBundle bundle) async {
    final TextEditingController controller = TextEditingController(
      text: bundle.question.label ?? '',
    );
    final String? next = await showDialog<String>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('改题号'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 12,
          textInputAction: TextInputAction.done,
          decoration: const InputDecoration(
            hintText: '例如 12. / （3） / 一、',
            isDense: true,
          ),
          onSubmitted: (String value) => Navigator.of(context).pop(value),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(controller.text),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    controller.dispose();
    final String? label = next?.trim();
    if (!mounted || label == null || label.isEmpty) {
      return;
    }
    if (label == (bundle.question.label ?? '')) {
      return;
    }
    await ref
        .read(regionEditProvider(widget.workbookId))
        .run(
          RenameCorrection(
            id: Ulid.next(),
            key: bundle.anchorKey,
            label: label,
          ),
        );
  }

  /// 长按框体弹出的菜单。与浮动条/面板同一批动作，只是多一行解释文案。
  Future<void> _showRegionMenu(String key, ReaderHandle handle) async {
    final RegionSet set = _regionSetOf();
    final QuestionBundle? target = _bundleOf(set, key);
    if (target == null || target.slices.isEmpty) {
      return;
    }
    final QuestionBundle bundle = target;
    _selectBundle(bundle);
    final QuestionBundle? previous = _previousOf(set, bundle);
    final Set<RegionAction> enabled = _actionsFor(bundle, set, handle);
    final String? picked = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      // 主题的 bottom sheet 背景是透明的（给自绘容器用）；这里只有 ListTile，
      // 不给实底会把下面的卷面透出来。
      backgroundColor: Theme.of(context).colorScheme.surfaceContainerHigh,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(ShqRadius.xl)),
      ),
      builder: (BuildContext context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            for (final RegionAction action in RegionAction.values)
              ListTile(
                leading: Icon(
                  regionActionIcon(action, locked: bundle.locked),
                  color: action.destructive
                      ? Theme.of(context).colorScheme.error
                      : null,
                ),
                title: Text(
                  action == RegionAction.lock && bundle.locked
                      ? '解锁'
                      : action.menuLabel,
                  style: action.destructive
                      ? TextStyle(color: Theme.of(context).colorScheme.error)
                      : null,
                ),
                subtitle: Text(_menuSubtitle(action, bundle, previous, handle)),
                enabled: enabled.contains(action),
                onTap: () => Navigator.of(context).pop(action.name),
              ),
            const SizedBox(height: ShqSpace.sm),
          ],
        ),
      ),
    );
    if (!mounted || picked == null) {
      return;
    }
    for (final RegionAction action in RegionAction.values) {
      if (action.name == picked) {
        await _applyAction(bundle, action, handle, set);
        return;
      }
    }
  }

  static String _menuSubtitle(
    RegionAction action,
    QuestionBundle bundle,
    QuestionBundle? previous,
    ReaderHandle handle,
  ) => switch (action) {
    RegionAction.split => '从框的中间切成上下两道题',
    RegionAction.merge =>
      previous == null
          ? '已经是第一道题'
          : '并入 ${previous.question.label ?? previous.question.ordinal}',
    RegionAction.extend =>
      bundle.slices.last.pageIndex < handle.pages.length - 1
          ? '跨页题：在下一页补一段'
          : '已经是最后一页',
    RegionAction.lock => bundle.locked ? '解锁后重新切题会覆盖它' : '锁定后重新切题不会覆盖它',
    RegionAction.rename => bundle.question.label ?? '扫描件认不出题号，可以手填',
    RegionAction.delete => '这一块不再算作题目（可撤销）',
    RegionAction.addQuestion => '在本题下方补一道题，再拖框定位',
  };

  /// 在当前页空白处补一个框（面板「新增框」）。
  Future<void> _addRegion(ReaderHandle handle) async {
    if (_current >= handle.pages.length) {
      return;
    }
    final WbPage page = handle.pages[_current];
    final RegionRect rect = RegionRect.fromLTRB(
      page.width * 0.08,
      page.height * 0.28,
      page.width * 0.92,
      page.height * 0.28 + 120,
    );
    final String key = anchorKey('手画', _current, rect.top);
    await ref
        .read(regionEditProvider(widget.workbookId))
        .run(
          AddQuestionCorrection(
            id: Ulid.next(),
            key: key,
            label: '手画',
            page: _current,
            rect: rect,
          ),
        );
    if (mounted) {
      _selected = (label: '手画', page: _current, y: rect.top);
    }
  }

  /// 把锚点解析成当前数据里的 anchor key（数据一刷新就是新的 key）。
  String? _selectedKeyOf(RegionSet set) {
    final ({String label, int page, double y})? anchor = _selected;
    if (anchor == null) {
      return null;
    }
    QuestionBundle? best;
    double bestDistance = double.infinity;
    for (final QuestionBundle bundle in set.questions) {
      if (bundle.question.label != anchor.label || bundle.slices.isEmpty) {
        continue;
      }
      if (bundle.slices.first.pageIndex != anchor.page) {
        continue;
      }
      final double distance = (bundle.slices.first.rect.top - anchor.y).abs();
      if (distance < bestDistance) {
        bestDistance = distance;
        best = bundle;
      }
    }
    return best?.anchorKey;
  }

  /// 选中题的 PDF 原图裁切预览：公式按矢量原样显示，不经过文本层。
  ///
  /// 文本层的公式是碎片 + 私有区码位，纯文本只能做到"可读的近似"；
  /// 预览图给用户一个"这一题在卷面上到底长什么样"的可靠锚点。
  Widget? _previewFor(
    ReaderHandle handle,
    RegionSet set,
    BuildContext context, {
    bool formulaPaper = false,
  }) {
    final PageImageCache? cache = _cache;
    if (cache == null || _selected == null) {
      return null;
    }
    final String? key = _selectedKeyOf(set);
    if (key == null) {
      return null;
    }
    QuestionBundle? bundle;
    for (final QuestionBundle item in set.questions) {
      if (item.anchorKey == key) {
        bundle = item;
        break;
      }
    }
    if (bundle == null || bundle.slices.isEmpty) {
      return null;
    }
    final QuestionSlice slice = bundle.slices.first;
    if (slice.pageIndex < 0 || slice.pageIndex >= handle.pages.length) {
      return null;
    }
    return RegionPreview(
      cache: cache,
      page: handle.pages[slice.pageIndex],
      rect: slice.rect,
      width: math.max(120, _panelWidth(context) - ShqSpace.lg * 2),
      // 公式卷不显示文字，预览就是唯一题面：给高一点。
      maxHeight: formulaPaper ? 230 : 150,
      note: formulaPaper ? '公式题：以卷面为准，不做文字转写' : null,
      // 点击 = 独立大图弹窗；长按 = 贴图侧边浮窗（保存）。不再做"框内 2× 缩放"。
      onTap: () => unawaited(_showQuestionImage(bundle!)),
      onLongPress: () => _openQuestionImageActions(bundle!),
    );
  }

  /// 公式/符号题是否多到"整卷不适合显示文字"。
  ///
  /// 用户口径：数学等符号多的学科，如果公式不能正确显示，就**不显示文字**，
  /// 只给 PDF 题面预览；提交给 AI 时以图片为准。
  bool _showStemText(RegionSet set) {
    final List<String> stems = <String>[
      for (final QuestionBundle bundle in set.questions)
        if (bundle.question.stemText != null &&
            bundle.question.stemText!.trim().isNotEmpty)
          bundle.question.stemText!,
    ];
    if (stems.length < 3) {
      return true;
    }
    final int heavy = stems.where(formulaHeavyText).length;
    return heavy / stems.length < 0.3;
  }

  /// 打开右侧「问 AI」面板（2026-10-24 接入真实模型）。
  ///
  /// 打开前做三件事，避免"面板先弹出来、图片晚半拍"：
  /// 1. 读这一题上次的对话（Vault）；
  /// 2. 把题面与当前作答渲染成 PNG（≤1024 长边）；
  /// 3. 刷新答题卡笔迹统计（决定「判我的作答」是否可用）。
  Future<void> _showAskAi(QuestionBundle bundle) async {
    if (bundle.slices.isEmpty) {
      return;
    }
    await _refreshAnswerInkCount(bundle);
    final List<ChatTurn> turns = await ref
        .read(aiChatStoreProvider(widget.workbookId))
        .load(widget.workbookId, bundle.question.id);
    final List<AiImageAttachment> attachments = await _aiAttachmentsOf(bundle);
    if (!mounted) {
      return;
    }
    setState(() {
      _aiBundle = bundle;
      _aiTurns = turns;
      _aiAttachments = attachments;
      _aiOpen = true;
      _panelOpen = true;
    });
  }

  /// 题面 + 学生作答两张图。题面永远第一张（与 system 里的声明顺序一致）。
  ///
  /// [includeAnswer] = false 时**只给题面**：补答案（让 AI 自己做一遍）
  /// 不需要看学生的作答，发过去只是白费 token 与等待。
  Future<List<AiImageAttachment>> _aiAttachmentsOf(
    QuestionBundle bundle, {
    bool includeAnswer = true,
  }) async {
    final PageImageCache? cache = _cache;
    final ReaderHandle? handle = _handle;
    if (cache == null || handle == null || bundle.slices.isEmpty) {
      return const <AiImageAttachment>[];
    }
    final QuestionSlice slice = bundle.slices.first;
    if (slice.pageIndex < 0 || slice.pageIndex >= handle.pages.length) {
      return const <AiImageAttachment>[];
    }
    final List<AiImageAttachment> out = <AiImageAttachment>[];
    final Uint8List? questionBytes = await renderAnswerCropPng(
      cache: cache,
      page: handle.pages[slice.pageIndex],
      rect: slice.rect,
      doc: InkDoc.empty,
    );
    if (questionBytes != null) {
      final AiImageAttachment? question = await prepareAiImage(
        bytes: questionBytes,
        kind: AiImageKind.question,
        label: '题面',
      );
      if (question != null) {
        out.add(question);
      }
    }

    if (!includeAnswer) {
      return out;
    }

    final AnswerSheetEntry entry = _answerEntryOf(bundle);
    final List<InkDoc> docs = await _loadAnswerInkPages(bundle);
    Uint8List? answerBytes;
    if (docs.any((InkDoc doc) => doc.strokes.isNotEmpty)) {
      final AnswerPaper paper = (await _papersOf()).forQuestion(
        bundle.question.id,
      );
      answerBytes = await renderAnswerSheetInkPng(
        docs: docs,
        widthPt: paper.widthPt,
        heightPt: paper.heightPt,
      );
    } else {
      // 没有答题卡笔迹：把 PDF 页内该作答框里的笔画单独画出来。
      final int pageIndex = entry.pageIndex.clamp(0, handle.pages.length - 1);
      await ref
          .read(inkWriterProvider(widget.workbookId))
          .flush(handle.session.id, pageIndex);
      final InkDoc pageDoc = await ref
          .read(inkStoreProvider(widget.workbookId))
          .load(handle.session.id, pageIndex);
      final List<InkStroke> strokes = _strokesInRect(pageDoc, entry.rect);
      if (strokes.isNotEmpty) {
        answerBytes = await renderPageInkOnlyPng(
          rect: entry.rect,
          doc: InkDoc(revision: 0, strokes: strokes),
        );
      }
    }
    if (answerBytes != null) {
      final AiImageAttachment? answer = await prepareAiImage(
        bytes: answerBytes,
        kind: AiImageKind.answer,
        label: '我的作答',
      );
      if (answer != null) {
        out.add(answer);
      }
    }
    return out;
  }

  /// 本题参考答案（PDF 或 AI 补的）。没有返回 null。
  ///
  /// [answers] 用于"刚刚补完答案、provider 还没重建"的调用点：
  /// 不能从已 invalidate 的 provider 里取，否则会拿到空集（2026-10-26 修）。
  String? _referenceAnswerOf(QuestionBundle bundle, {AnswerSet? answers}) {
    final AnswerSet source = answers ?? _regionSetOf().answers;
    final AnswerNote? note = source.forQuestion(
      ordinal: bundle.question.ordinal,
      label: bundle.question.label,
    );
    final String? text = note?.text.trim();
    return text == null || text.isEmpty ? null : text;
  }

  /// 这题有没有作答（答题卡笔迹 / 页内作答框墨迹 / OCR 文本 / 作答原图）。
  ///
  /// 比 [_hasStudentAnswerOf] 多做了两件事：跨页也能查，且会先 flush 再读 SIF。
  /// 改卷要一次过几十道题，必须有这个"不依赖当前页"的版本。
  Future<bool> _hasStudentWorkAsync(QuestionBundle bundle) async {
    final AnswerSheetEntry entry = _answerEntryOf(bundle);
    if (entry.hasText || entry.hasCrop) {
      return true;
    }
    final InkDoc? cached = _answerInkDocs[bundle.question.id];
    if (cached != null && cached.strokes.isNotEmpty) {
      return true;
    }
    final ReaderHandle? handle = _handle;
    if (handle == null) {
      return false;
    }
    try {
      final List<InkDoc> docs = await _loadAnswerInkPages(bundle);
      if (docs.any((InkDoc doc) => doc.strokes.isNotEmpty)) {
        return true;
      }
      if (handle.pages.isEmpty) {
        return false;
      }
      final int pageIndex = entry.pageIndex.clamp(0, handle.pages.length - 1);
      await ref
          .read(inkWriterProvider(widget.workbookId))
          .flush(handle.session.id, pageIndex);
      final InkDoc pageDoc = await ref
          .read(inkStoreProvider(widget.workbookId))
          .load(handle.session.id, pageIndex);
      return _strokesInRect(pageDoc, entry.rect).isNotEmpty;
    } on Object {
      return false;
    }
  }

  bool _hasStudentAnswerOf(QuestionBundle bundle) {
    final AnswerSheetEntry entry = _answerEntryOf(bundle);
    if (entry.hasText) {
      return true;
    }
    final InkDoc? ink = _answerInkDocs[bundle.question.id];
    if (ink != null && ink.strokes.isNotEmpty) {
      return true;
    }
    // 页内书写（没有答题卡时）：只有当前页能便宜地统计。
    return entry.pageIndex == _current && _answerStrokeCountOf(entry) > 0;
  }

  /// 打开 AI 配置（面板里没有配置时的"去配置"、以及菜单项都走这里）。
  Future<void> _openAiConfig(LlmConfig config) async {
    final bool saved = await showAiSettingsSheet(context, initial: config);
    if (!mounted) {
      return;
    }
    if (saved) {
      ref.invalidate(aiConfigProvider);
      setState(() {});
    }
  }

  Stream<AiChatChunk> _aiSend(
    LlmConfig config,
    QuestionBundle bundle,
    String message,
    List<ChatTurn> history,
    List<AiImageAttachment> attachments,
    bool deepThinking,
  ) {
    return ref
        .read(aiServiceProvider(widget.workbookId))
        .chat(
          config: config,
          payload: _aiPayloadOf(bundle),
          history: history,
          message: message,
          attachments: attachments,
          referenceAnswer: _referenceAnswerOf(bundle),
          deepThinking: deepThinking,
        );
  }

  /// 快捷动作：先做一遍 → 落 AI 答案；判我的作答 → 落 grading（source=ai）。
  Future<AiChatResult?> _runAiQuick(
    LlmConfig config,
    QuestionBundle bundle,
    AiQuickAction action,
    List<AiImageAttachment> attachments,
  ) async {
    final AiService service = ref.read(aiServiceProvider(widget.workbookId));
    final QuestionAiPayload payload = _aiPayloadOf(bundle);
    switch (action) {
      case AiQuickAction.explain:
        return null;
      case AiQuickAction.solve:
        final AiSolution solution = await service.solve(
          config: config,
          payload: payload,
          attachments: attachments,
        );
        if (solution.answer.trim().isNotEmpty) {
          await _saveAiAnswer(bundle, solution.answer.trim());
        }
        return AiChatResult(text: solution.explanation, solution: solution);
      case AiQuickAction.grade:
        final String studentAnswer = _answerEntryOf(bundle).ocrText;
        final AiGrade grade = await service.grade(
          config: config,
          payload: payload,
          referenceAnswer: _referenceAnswerOf(bundle),
          studentAnswerText: studentAnswer,
          attachments: attachments,
        );
        final bool applied =
            await _grades?.applyAi(
              bundle.question.id,
              grade.verdict,
              note: grade.reason,
            ) ??
            false;
        return AiChatResult(text: grade.reason, grade: grade, applied: applied);
    }
  }

  /// AI 补的答案单独落 `answers_ai.v1.json`：重切题不会覆盖它。
  Future<void> _saveAiAnswer(QuestionBundle bundle, String text) async {
    final store = ref.read(layoutStoreProvider);
    final AnswerSet existing = AnswerSet.fromJson(
      await store.readAiAnswers(widget.workbookId),
    );
    final String label = bundle.question.label ?? '${bundle.question.ordinal}';
    final AnswerNote note = AnswerNote(
      label: label,
      text: text,
      source: 'ai',
      pageIndex: bundle.slices.first.pageIndex,
      ordinal: bundle.question.ordinal,
    );
    final AnswerSet next = existing.withNote(note);
    await store.writeAiAnswers(widget.workbookId, next.toJson());
    if (!mounted) {
      _liveAiAnswers = _liveAiAnswers.withNote(note);
      return;
    }
    // 与批量补答案同口径：只更新当前页的内存覆盖，不 invalidate 整卷。
    setState(() {
      _liveAiAnswers = _liveAiAnswers.withNote(note);
    });
    // 单题快捷补答案：当前页用 live 立即显示，同时同步 provider 供重进读取。
    ref.invalidate(regionSetProvider(widget.workbookId));
    _showReaderTip('已写入参考答案（AI · 请自检）');
  }

  /// 顶栏「保存」：把**当前答题情况**立刻落盘。
  ///
  /// 落三样东西，缺一不可：
  /// - **笔迹**（`_flushAllInk`）：所有待写页，不只是当前页——
  ///   用户可能翻回前一页补了一笔，那一笔也在防抖窗口里；
  /// - **阅读进度**（`saveLastPage`）：500ms 防抖可能还没写；
  /// - **切题改动**（`_flushRegions`）：题目区域的覆盖层同样有防抖。
  ///
  /// 笔迹本来就有 500ms 自动落盘 + 生命周期兜底，所以这个按钮的价值是
  /// **给用户一个确定感**（"我写的东西已经存下来了"），而不是救数据。
  /// 落盘完成后给一句明确反馈——按下去没反应会让人怀疑没点上。
  Future<void> _saveNow() async {
    final Future<void> Function()? flushAll = _flushAllInk;
    final Future<void> Function()? flushRegions = _flushRegions;
    final ReaderHandle? handle = _handle;
    if (flushAll != null) {
      await flushAll();
    }
    if (flushRegions != null) {
      await flushRegions();
    }
    if (handle != null) {
      await handle.saveLastPage(_current);
    }
    if (!mounted) {
      return;
    }
    _showReaderTip('已保存答题情况');
  }

  /// 「收藏」入口：已收藏则取消，未收藏则做一份独立快照。
  Future<void> _favoriteQuestion(QuestionBundle bundle) async {
    final String label = bundle.question.label ?? '${bundle.question.ordinal}';
    final FavoriteStore store = ref.read(favoriteStoreProvider);
    try {
      final String? existing = await store.idOfQuestion(bundle.question.id);
      if (existing != null) {
        await store.remove(existing);
        if (mounted) {
          ref.invalidate(favoritesProvider);
          _showReaderTip('已取消收藏第 $label 题');
        }
        return;
      }
      final FavoriteCapture? capture = await _buildFavoriteCapture(bundle);
      if (capture == null) {
        if (mounted) {
          _showReaderTip('收藏失败：题面无法生成');
        }
        return;
      }
      await store.capture(capture);
      if (mounted) {
        ref.invalidate(favoritesProvider);
        _showReaderTip('已收藏第 $label 题');
      }
    } on Object {
      if (mounted) {
        _showReaderTip('收藏失败，请重试');
      }
    }
  }

  /// 收藏那一刻定格的数据：题面图 + 作答图 + AI 对话 + 判题 + 答案。
  ///
  /// 渲染失败不阻断收藏——图片/JSON 都允许缺，只是看题页少一部分展示。
  /// 返回 null 表示连题面图都渲染不出来（没有可用的页/区域）。
  Future<FavoriteCapture?> _buildFavoriteCapture(QuestionBundle bundle) async {
    final ReaderHandle? handle = _handle;
    final PageImageCache? cache = _cache;
    if (handle == null || cache == null || bundle.slices.isEmpty) {
      return null;
    }
    final Question question = bundle.question;
    final QuestionSlice slice = bundle.slices.first;
    if (slice.pageIndex < 0 || slice.pageIndex >= handle.pages.length) {
      return null;
    }
    final WbPage page = handle.pages[slice.pageIndex];

    // 题面图（纯题面，不含笔迹）。收藏夹「点开看」要清晰：
    // 按 2.8×pt、上限 1800×2600 出图（默认的 1.6×/1024 在平板上会发虚）。
    final Uint8List? stemPng = await renderAnswerCropPng(
      cache: cache,
      page: page,
      rect: slice.rect,
      doc: InkDoc.empty,
      scale: 2.8,
      maxWidth: 1800,
      maxHeight: 2600,
    );

    // 作答图：优先答题卡笔迹，其次 PDF 页内该作答框的笔迹。
    Uint8List? answerPng;
    final List<InkDoc> sheetDocs = await _loadAnswerInkPages(bundle);
    if (sheetDocs.any((InkDoc doc) => doc.strokes.isNotEmpty)) {
      answerPng = await renderAnswerSheetInkPng(docs: sheetDocs);
    } else {
      final AnswerSheetEntry entry = _answerEntryOf(bundle);
      final int pageIndex = entry.pageIndex.clamp(0, handle.pages.length - 1);
      final InkDoc pageDoc = await ref
          .read(inkStoreProvider(widget.workbookId))
          .load(handle.session.id, pageIndex);
      final List<InkStroke> strokes = _strokesInRect(pageDoc, entry.rect);
      if (strokes.isNotEmpty) {
        answerPng = await renderAnswerCropPng(
          cache: cache,
          page: handle.pages[pageIndex],
          rect: entry.rect,
          doc: InkDoc(revision: 0, strokes: strokes),
          scale: 2.4,
          maxWidth: 1600,
          maxHeight: 2400,
        );
      }
    }

    // AI 对话快照。
    final List<ChatTurn> turns = await ref
        .read(aiChatStoreProvider(widget.workbookId))
        .load(widget.workbookId, question.id);
    final Map<String, Object?>? chatJson = turns.isEmpty
        ? null
        : <String, Object?>{'turns': ChatTurn.listToJson(turns)};

    // 判题结论快照。
    final QuestionGrade? grade = _grades?.data.value.gradeOf(question.id);
    final Map<String, Object?>? gradingJson = grade?.toJson();

    // 答案快照。
    final AnswerNote? note = _regionSetOf().answers.forQuestion(
      ordinal: question.ordinal,
      label: question.label,
    );
    final Map<String, Object?>? answerJson = note?.toJson();

    return FavoriteCapture(
      questionId: question.id,
      workbookId: widget.workbookId,
      workbookTitle: handle.workbook.title,
      label: question.label ?? '${question.ordinal}',
      ordinal: question.ordinal,
      kind: question.kind,
      stemText: question.stemText ?? '',
      pageIndex: slice.pageIndex,
      rect: slice.rect,
      verdict: grade?.verdict ?? AnswerVerdict.none,
      stemPng: stemPng,
      answerPng: answerPng,
      chatJson: chatJson,
      gradingJson: gradingJson,
      answerJson: answerJson,
    );
  }

  /// 「对答案」入口（2026-10-28 v0.1.3 口径）：
  ///
  /// - 先确保 OCR 对应当前笔迹/作答框（改过就自动重识别）；
  /// - 没有参考答案 → 不可用（按钮已在面板置灰）；
  /// - 有答案没作答 → 只展示参考答案，不改指示灯，明确写"卷面与答题卡都没有笔迹"；
  /// - 手改 → 永远保留，只展示当前依据；
  /// - AI 判过且无明显改动 → 保留 AI 原判；明显改动 → 用当前 OCR 重判；
  /// - 本地可信 → 直接落结论；低置信客观题点「判题」按本地结论落判；
  ///   主观/公式 → 黄点 + 询问是否 AI。
  Future<void> _checkAnswer(QuestionBundle bundle) async {
    final String label = bundle.question.label ?? '${bundle.question.ordinal}';
    final RegionSet set = _regionSetOf();
    final String? reference = _referenceAnswerOf(bundle, answers: set.answers);
    if (reference == null) {
      _showReaderTip('第 $label 题还没有参考答案：先「补答案」或多选用「AI 判」');
      return;
    }
    final _AnswerInkSnapshot snapshot = await _ensureFreshAnswerOcr(bundle);
    if (!mounted) {
      return;
    }
    final AnswerSheetEntry entry = snapshot.entry;
    final GradeEvidence evidence = GradeEvidence(
      text: entry.ocrText,
      sig: snapshot.signature,
      refHash: referenceHashOf(reference),
    );
    final QuestionGrade? existing = _grades?.data.value.gradeOf(
      bundle.question.id,
    );

    // 手改：永远保留。
    if (existing != null && existing.manual) {
      await _showGradeResult(
        bundle: bundle,
        reference: reference,
        verdict: existing.verdict,
        reason: existing.note.isEmpty
            ? '这道题是你手动改的结论，本次不会覆盖；如需改判，点题号旁的三色点。'
            : '手改结论优先：${existing.note}',
        judgedText: entry.ocrText,
        manual: true,
      );
      return;
    }

    final bool fromAi = existing != null && existing.fromAi;
    final bool significantChange = fromAi
        ? isSignificantAnswerChange(
            grade: existing,
            currentText: entry.ocrText,
            currentReference: reference,
            currentSignature: snapshot.signature,
          )
        : false;

    // AI 判过、答案没有明显改动：保留原判，不重复扣 token。
    if (fromAi && !significantChange) {
      await _showGradeResult(
        bundle: bundle,
        reference: reference,
        verdict: existing.verdict,
        reason: existing.note.isEmpty
            ? '答案没有明显改动，保留 AI 原判。'
            : '答案没有明显改动，保留 AI 原判。\n${existing.note}',
        judgedText: entry.ocrText,
        fromAi: true,
      );
      return;
    }

    final LocalGrade local = judgeLocally(
      reference: reference,
      studentText: entry.ocrText,
      ocrConfidence: entry.ocrConfidence,
      hasWork: snapshot.hasWork,
    );
    if (local.readiness == GradeReadiness.noWork) {
      await _showReferenceOnly(
        bundle: bundle,
        reference: reference,
        reason: '这道题还没有作答：卷面作答框和答题卡都没有笔迹。先看看参考答案，或去答题卡写一遍。',
      );
      return;
    }
    if (local.canApply) {
      await _grades?.applyAuto(
        <String, AnswerVerdict>{bundle.question.id: local.verdict},
        evidence: <String, GradeEvidence>{bundle.question.id: evidence},
        notes: fromAi
            ? <String, String>{bundle.question.id: '答案有明显改动，已按当前识别重判'}
            : const <String, String>{},
        replaceAi: fromAi,
      );
      if (mounted) {
        await _showGradeResult(
          bundle: bundle,
          reference: reference,
          verdict: local.verdict,
          reason: local.reason,
          judgedText: entry.ocrText,
        );
      }
      return;
    }

    // 本地不可信：先黄点（明显改动的 AI 旧结论不再保留），再问用户。
    await _grades?.applyAuto(
      <String, AnswerVerdict>{bundle.question.id: AnswerVerdict.pending},
      evidence: <String, GradeEvidence>{bundle.question.id: evidence},
      notes: fromAi
          ? <String, String>{bundle.question.id: '答案有明显改动，本地仍判不了'}
          : const <String, String>{},
      replaceAi: fromAi,
    );
    final LlmConfig config = await ref.read(llmConfigStoreProvider).load();
    if (!mounted) {
      return;
    }
    if (config.validationError() != null) {
      await _showGradeResult(
        bundle: bundle,
        reference: reference,
        verdict: AnswerVerdict.pending,
        reason: '${local.reason}\n\n要 AI 判，先在「设置 → AI 分析」配置端点与 Key。',
        judgedText: entry.ocrText,
      );
      return;
    }
    final bool useAi = await _askSingleAi(
      label: label,
      reason: local.reason,
      forceable: local.forceable,
      tentative: local.tentative,
    );
    if (!mounted) {
      return;
    }
    if (!useAi) {
      // 用户选「判题」：有可强制的本地结论就落判，否则保持黄点。
      if (local.forceable && local.tentative != null) {
        final String note = '低置信度本地判题（${local.reason}），请自行核对';
        await _grades?.applyAuto(
          <String, AnswerVerdict>{bundle.question.id: local.tentative!},
          evidence: <String, GradeEvidence>{bundle.question.id: evidence},
          notes: <String, String>{bundle.question.id: note},
          replaceAi: fromAi,
        );
        if (mounted) {
          await _showGradeResult(
            bundle: bundle,
            reference: reference,
            verdict: local.tentative!,
            reason: note,
            judgedText: entry.ocrText,
          );
        }
      } else {
        await _showGradeResult(
          bundle: bundle,
          reference: reference,
          verdict: AnswerVerdict.pending,
          reason:
              '${local.reason}\n\n这道题没有可强制的本地结论，已保留黄点；'
              '可以点三色手改，或配置 AI 后交给模型。',
          judgedText: entry.ocrText,
        );
      }
      return;
    }
    try {
      final AiGrade? grade = await _aiGradeOne(
        bundle,
        config: config,
        service: ref.read(aiServiceProvider(widget.workbookId)),
        asked: '对答案：帮我判一下这道作答。',
      );
      if (grade != null && mounted) {
        await _showGradeResult(
          bundle: bundle,
          reference: reference,
          verdict: grade.verdict,
          reason: grade.reason,
          judgedText: entry.ocrText,
          fromAi: true,
        );
      }
    } on Object catch (error) {
      if (mounted) {
        _showReaderTip('AI 判失败：$error');
      }
    }
  }

  Future<bool> _askSingleAi({
    required String label,
    required String reason,
    required bool forceable,
    AnswerVerdict? tentative,
  }) async {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Text('第 $label 题 · 本地判不了'),
        content: Text(
          '$reason。\n\n'
          '${forceable && tentative != null ? '本地倾向：${gradeLabel(tentative)}（低置信度）。\n'
                    '「判题」= 按本地结论落判；' : '「判题」= 保持黄点待判；'}'
          '「交给 AI 判」= 让模型看当前识别文字与作答图，会产生 1 次模型请求。',
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(height: 1.65),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('判题'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('交给 AI 判'),
          ),
        ],
      ),
    );
    return ok ?? false;
  }

  Future<void> _showGradeResult({
    required QuestionBundle bundle,
    required String reference,
    required AnswerVerdict verdict,
    required String reason,
    String? judgedText,
    bool fromAi = false,
    bool manual = false,
  }) async {
    final String label = bundle.question.label ?? '${bundle.question.ordinal}';
    final ThemeData theme = Theme.of(context);
    final Color color = gradeColor(context, verdict);
    final String source = manual
        ? '（手改）'
        : fromAi
        ? '（AI）'
        : '（本地）';
    await showDialog<void>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Row(
          children: <Widget>[
            Container(
              width: 12,
              height: 12,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
            const SizedBox(width: ShqSpace.sm),
            Expanded(child: Text('第 $label 题 · ${gradeLabel(verdict)}$source')),
          ],
        ),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  reason.isEmpty ? '没有更多依据。' : reason,
                  style: theme.textTheme.bodyMedium?.copyWith(height: 1.6),
                ),
                if (judgedText != null) ...<Widget>[
                  const SizedBox(height: ShqSpace.md),
                  Text(
                    '本次识别',
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: ShqSpace.xs),
                  SelectableText(
                    judgedText.trim().isEmpty ? '没有识别到文字' : judgedText,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      height: 1.65,
                      color: judgedText.trim().isEmpty
                          ? theme.colorScheme.outline
                          : null,
                    ),
                  ),
                ],
                if (reference.trim().isNotEmpty) ...<Widget>[
                  const SizedBox(height: ShqSpace.md),
                  Text(
                    '参考答案',
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: ShqSpace.xs),
                  SelectableText(
                    reference,
                    style: theme.textTheme.bodyMedium?.copyWith(height: 1.65),
                  ),
                ],
              ],
            ),
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  Future<void> _showReferenceOnly({
    required QuestionBundle bundle,
    required String reference,
    required String reason,
  }) async {
    final String label = bundle.question.label ?? '${bundle.question.ordinal}';
    final ThemeData theme = Theme.of(context);
    final bool? goWrite = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Text('第 $label 题 · 还没有作答'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(reason, style: theme.textTheme.bodyMedium),
                const SizedBox(height: ShqSpace.md),
                Text(
                  '参考答案',
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: ShqSpace.xs),
                SelectableText(
                  reference,
                  style: theme.textTheme.bodyMedium?.copyWith(height: 1.65),
                ),
              ],
            ),
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('知道了'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('去作答'),
          ),
        ],
      ),
    );
    if (goWrite == true && mounted) {
      _openAnswerSheetAt(bundle.question.id);
    }
  }

  /// AI 面板用的载荷：图片权威、公式题只给图。
  QuestionAiPayload _aiPayloadOf(QuestionBundle bundle) {
    final QuestionSlice slice = bundle.slices.first;
    final String? rawStem = bundle.question.stemText;
    final String? text = rawStem != null && !formulaHeavyText(rawStem)
        ? rawStem
        : null;
    return buildQuestionAiPayload(
      questionId: bundle.question.id,
      label: bundle.question.label ?? '${bundle.question.ordinal}',
      pageIndex: slice.pageIndex,
      rect: slice.rect,
      text: text,
      provenance: text == null
          ? TextProvenance.none
          : TextProvenance.pdfTextLayer,
    );
  }

  /// 阅读器里的一句轻提示（统一 SnackBar 口径，避免每个入口各写一份）。
  void _showReaderTip(String message) {
    final ScaffoldMessengerState? messenger = ScaffoldMessenger.maybeOf(
      context,
    );
    if (messenger == null) {
      return;
    }
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          duration: const Duration(milliseconds: 2200),
          behavior: SnackBarBehavior.floating,
        ),
      );
  }

  void _selectAnchorOf(RegionSet set, String key) {
    if (_answerQuestionId != null) {
      setState(() => _answerQuestionId = null);
    }
    for (final QuestionBundle bundle in set.questions) {
      if (bundle.anchorKey == key) {
        _selectBundle(bundle);
        return;
      }
    }
  }

  void _selectBundle(QuestionBundle bundle) {
    if (bundle.slices.isEmpty) {
      return;
    }
    setState(() {
      _selected = (
        label: bundle.question.label ?? '',
        page: bundle.slices.first.pageIndex,
        y: bundle.slices.first.rect.top,
      );
    });
  }

  /// 当前卷的切题结果（从 provider 的当前值取，拿不到给空集）。
  RegionSet _regionSetOf() {
    final RegionSet raw =
        ref.read(regionSetProvider(widget.workbookId)).value ?? RegionSet.empty;
    return _withLiveAiAnswers(_orderedSet(raw));
  }

  /// 把本批刚补的 AI 答案叠到 provider 的旧快照上。
  ///
  /// `AnswerSet.mergeMissing` 让 PDF/已有答案优先，AI 只补缺；
  /// 这样不 invalidate provider 也能立刻在面板/判题里读到新答案。
  RegionSet _withLiveAiAnswers(RegionSet set) {
    if (_liveAiAnswers.isEmpty) {
      return set;
    }
    return RegionSet(
      set.questions,
      answers: set.answers.mergeMissing(_liveAiAnswers),
    );
  }

  /// 套用用户手动顺序；没有手动顺序时原样返回。
  RegionSet _orderedSet(RegionSet set) {
    final QuestionOrderController? order = _questionOrder;
    if (order == null ||
        order.order.value.isEmpty ||
        set.questions.length < 2) {
      return set;
    }
    return RegionSet(order.apply(set.questions), answers: set.answers);
  }

  Future<void> _moveQuestion(RegionSet set, int oldIndex, int newIndex) async {
    final QuestionOrderController? order = _questionOrder;
    if (order == null) {
      return;
    }
    await order.move(set.questions, oldIndex, newIndex);
  }

  /// 面板菜单的"选中题上移/下移一位"。
  void _moveSelectedQuestion(int delta) {
    final RegionSet set = _regionSetOf();
    final String? key = _selectedKeyOf(set);
    if (key == null) {
      return;
    }
    final int index = set.questions.indexWhere(
      (QuestionBundle bundle) => bundle.anchorKey == key,
    );
    if (index < 0) {
      return;
    }
    final int target = index + delta;
    if (target < 0 || target >= set.questions.length) {
      return;
    }
    unawaited(_moveQuestion(set, index, target));
  }

  void _resetQuestionOrder() {
    final QuestionOrderController? order = _questionOrder;
    if (order != null) {
      unawaited(order.reset());
    }
  }

  /// 面板宽度：平板 320dp；窄屏按 42% 收窄（手机上 320 会占掉半个屏）。
  /// 面板**当前**宽度：拖动中跟随手指，否则用记住的全局宽度。
  ///
  /// 2026-10-24 用户口径：最小 = 原来的宽度（宽屏 320dp / 窄屏 42%），
  /// 最大 = 横向屏幕的一半，题目区域与问 AI 共用同一个值。
  double _panelWidth(BuildContext context) {
    final double screen = MediaQuery.sizeOf(context).width;
    final double? drag = _dragPanelWidth;
    if (drag != null) {
      return PanelMetrics.clampWidth(drag, screen);
    }
    return PanelMetrics.clampWidth(_storedPanelWidth(screen), screen);
  }

  /// 阅读区要让出的宽度：拖动过程中**保持松手前的值**（见 [_dragPanelWidth]）。
  double _panelInset(BuildContext context) {
    if (_dragPanelWidth == null) {
      return _panelWidth(context);
    }
    return PanelMetrics.clampWidth(
      _storedPanelWidth(MediaQuery.sizeOf(context).width),
      MediaQuery.sizeOf(context).width,
    );
  }

  double _storedPanelWidth(double screen) {
    return ref.read(panelWidthProvider) ?? PanelMetrics.defaultFor(screen);
  }

  /// 拖宽过程中的一步：只改内存状态，UI 立即跟随。
  ///
  /// [totalGrow] 是**自拖动起点以来的总变宽量**（不是每帧增量），
  /// 所以夹到上下限之后手一反向就立刻跟手。
  void _onPanelResize(double totalGrow) {
    final double screen = MediaQuery.sizeOf(context).width;
    setState(() {
      _dragPanelWidth = PanelMetrics.clampWidth(
        _dragStartPanelWidth + totalGrow,
        screen,
      );
    });
  }

  /// 按下把手：记住当前宽度，作为这一轮拖动的基准。
  void _onPanelResizeStart() {
    _dragStartPanelWidth = _panelWidth(context);
    setState(() => _dragPanelWidth = _dragStartPanelWidth);
  }

  /// 松手：把最终宽度交给全局状态（异步落盘），阅读区在此刻一次性让位。
  void _onPanelResizeEnd() {
    final double? width = _dragPanelWidth;
    if (width == null) {
      return;
    }
    setState(() => _dragPanelWidth = null);
    ref.read(panelWidthProvider.notifier).commit(width);
  }

  /// 把框按页分组。只算一次（每次 build 重算也是 O(题数)，几十道题可忽略），
  /// 换来的是 PageLayer 不用自己过滤——滚动模式每帧要建 3 个页面，别在那里做 O(n) 扫描。
  static Map<int, List<RegionMark>> _marksByPage(
    RegionSet set,
    AnswerSheetData answerData, {
    required bool showAllAnswers,
    String? answerQuestionId,
  }) {
    final Map<int, List<RegionMark>> grouped = <int, List<RegionMark>>{};
    for (final RegionMark mark in regionMarksOf(set)) {
      grouped.putIfAbsent(mark.pageIndex, () => <RegionMark>[]).add(mark);
    }
    if (!showAllAnswers && answerQuestionId == null) {
      return grouped;
    }
    for (final QuestionBundle bundle in set.questions) {
      // 大题（level 1）是容器，不是可作答的单题；作答框只给小题。
      if (bundle.question.level <= 1) {
        continue;
      }
      if (!showAllAnswers && bundle.question.id != answerQuestionId) {
        continue;
      }
      if (bundle.slices.isEmpty) {
        continue;
      }
      final AnswerSheetEntry entry = answerData.regionFor(bundle);
      if (entry.rect.isEmpty) {
        continue;
      }
      grouped
          .putIfAbsent(entry.pageIndex, () => <RegionMark>[])
          .add(
            RegionMark(
              key: _answerMarkKey(bundle.question.id),
              pageIndex: entry.pageIndex,
              rect: entry.rect,
              label: '答 ${bundle.question.label ?? bundle.question.ordinal}',
              grade: 'green',
              confidence: 1,
              level: 2,
              isAnswer: true,
            ),
          );
    }
    return grouped;
  }

  void _openDisplaySheet() {
    unawaited(
      showPaperStyleSheet(
        context,
        prefs: _prefs ?? ReaderPrefs.defaults,
        onChanged: _updatePrefs,
      ),
    );
  }

  void _jumpTo(int index) {
    _onPageChanged(index);
    if (_mode == ViewMode.paged) {
      _pagedKey.currentState?.jumpTo(index);
    } else {
      _scrollKey.currentState?.jumpTo(index);
    }
  }

  /// 后台自动切题：**无感**——不弹窗、不转圈、不 await，用户可以直接翻页写字。
  ///
  /// 已经有结果（`layout_status` 是 auto/manual 且库里题目非空）时内部直接返回，
  /// 所以哪怕每次打开都调一次也不会有额外开销。
  void _ensureRegions(ReaderHandle handle) {
    if (_regionEnsured) {
      return;
    }
    _regionEnsured = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      unawaited(
        ref
            .read(regionCutterProvider(widget.workbookId))
            .ensure(source: handle.source, pages: handle.pages),
      );
      // 编辑控制器要记住 source/pages（改完框要整卷重算）。
      unawaited(
        ref
            .read(regionEditProvider(widget.workbookId))
            .attach(source: handle.source, pages: handle.pages),
      );
    });
  }

  /// 用户主动点"重新切题"：重抽文本层并覆盖自动结果。
  Future<void> _recut(ReaderHandle handle) async {
    final RegionBuildOutcome? outcome = await ref
        .read(regionCutterProvider(widget.workbookId))
        .cut(source: handle.source, pages: handle.pages, force: true);
    if (!mounted || outcome == null) {
      return;
    }
    final ScaffoldMessengerState? messenger = ScaffoldMessenger.maybeOf(
      context,
    );
    messenger
      ?..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          // 三色统计是开发信息（用户 2026-10-23 明确不要在界面露出来）。
          content: Text(
            outcome.isEmpty
                ? '没切出题目（这一页可能是整页图片，或题号样式特殊）'
                : '已切出 ${outcome.regions} 道题',
          ),
          duration: const Duration(milliseconds: 2200),
          behavior: SnackBarBehavior.floating,
        ),
      );
  }

  /// 落笔没被纸接住（落在纸外）时给一句提示。
  ///
  /// 为什么必须有：放大后页面比屏幕大，用户很容易写到"纸外"，
  /// 此时按笔完全没反应——没有提示就只能靠猜（"是不是坏了"）。
  void _showPenMissed() {
    final ScaffoldMessengerState? messenger = ScaffoldMessenger.maybeOf(
      context,
    );
    if (messenger == null) {
      return;
    }
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        const SnackBar(
          content: Text('这一笔没落在纸上，换个位置写'),
          duration: Duration(milliseconds: 1400),
          behavior: SnackBarBehavior.floating,
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    // 当前笔（工具 + 颜色 + 粗细，全局唯一一份，只影响之后画的新笔）
    final InkBrush brush = ref.watch(inkToolProvider);
    // 笔的颜色预览要跟"纸的明暗"配对（夜读纸上用提亮版）
    final bool darkPaper = _style.isDarkPaper;
    if (brush.darkPaper != darkPaper) {
      // 只影响色块预览：放到帧后改，避免在 build 里写 provider。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          ref.read(inkToolProvider.notifier).setDarkPaper(darkPaper);
        }
      });
    }
    final AsyncValue<ReaderHandle> async = ref.watch(
      readerHandleProvider(widget.workbookId),
    );
    // 题目面板的「收藏」要显示实心/空心星：收藏夹变化后立刻重绘（invoke 已在收藏/取消后做）。
    final Set<String> favoriteQuestionIds = ref
        .watch(favoritesProvider)
        .maybeWhen<Set<String>>(
          data: (List<Favorite> items) => <String>{
            for (final Favorite favorite in items)
              if (favorite.workbookId == widget.workbookId) favorite.questionId,
          },
          orElse: () => const <String>{},
        );
    _favoriteQuestionIds = favoriteQuestionIds;
    // 直接用 async 的当前值建 UI：不能"在 build 里偷偷赋值给字段，指望下一帧生效"，
    // 否则首帧的 AppBar 标题会一直是兜底文案（实测踩过）。
    // Riverpod 3 里没有 valueOrNull，用 maybeWhen 取安全值
    final ReaderHandle? ready = async.maybeWhen<ReaderHandle?>(
      data: (ReaderHandle value) => value,
      orElse: () => null,
    );
    if (ready != null) {
      _handle = ready;
      _cache ??= PageImageCache(source: ready.source);
      if (_initialPage == null) {
        _initialPage = ready.session.lastPage.clamp(0, ready.pages.length - 1);
        _current = _initialPage!;
      }
    }

    // 偏好：异步从库加载；首次拿到就用它，之后以本地 `_prefs` 为准（用户改了立即生效）。
    final AsyncValue<ReaderPrefs> prefsAsync = ref.watch(
      readerPrefsProvider(widget.workbookId),
    );
    final ReaderPrefs? loadedPrefs = prefsAsync.maybeWhen<ReaderPrefs?>(
      data: (ReaderPrefs value) => value,
      orElse: () => null,
    );
    if (loadedPrefs != null && _prefs == null) {
      _store ??= ref.read(readerPrefsStoreProvider);
      _prefs = loadedPrefs;
    }

    // AI 配置：面板头部的模型标签、发送、快捷动作都读这一份。
    final LlmConfig aiConfig = ref
        .watch(aiConfigProvider)
        .maybeWhen<LlmConfig>(
          data: (LlmConfig value) => value,
          orElse: () => LlmConfig.empty,
        );

    // 撤销/重做看的是**当前页**的历史（滚到第 3 页撤的是第 3 页的笔）。
    final InkPageKey pageKey = InkPageKey(
      ready?.session.id ?? '',
      _current,
      workbookId: widget.workbookId,
    );
    final bool pinnedToolbar = ref.watch(inkToolbarPinnedProvider);
    final bool canUndo =
        ready != null &&
        ref.watch(
          inkEditProvider(pageKey).select((InkEditState s) => s.canUndo),
        );
    final bool canRedo =
        ready != null &&
        ref.watch(
          inkEditProvider(pageKey).select((InkEditState s) => s.canRedo),
        );

    // 切题结果 + 框的显示开关（默认关，开关全局记住）。
    final RegionSet regionSet = _withLiveAiAnswers(
      _orderedSet(
        ready == null
            ? RegionSet.empty
            : ref.watch(regionSetProvider(widget.workbookId)).value ??
                  RegionSet.empty,
      ),
    );
    // **框跟随面板**：面板是"看/改切题结果"的唯一入口。
    // 面板关闭 = 只读态，叠加层完全不参与命中（写字/滚动/缩放零干扰）。
    final bool showRegions = _panelOpen;
    // 面板宽度是全局偏好：watch 一次，拖动/落盘后整棵树重建（面板与阅读区留白同源）。
    ref.watch(panelWidthProvider);
    final AnswerSheetData answerData =
        _answerSheet?.data.value ?? AnswerSheetData.empty;
    // 作答框在两种情况下出现：面板上部开关打开（全部），或当前展开了某题的
    // 「答题情况」（只显示那一题）。两者都只在面板打开时参与叠加层。
    final Map<int, List<RegionMark>> marksByPage = showRegions
        ? _marksByPage(
            regionSet,
            answerData,
            showAllAnswers: _showAnswers,
            answerQuestionId: _answerQuestionId,
          )
        : const <int, List<RegionMark>>{};
    final RegionEditController edit = ref.watch(
      regionEditProvider(widget.workbookId),
    );
    // 框可见 = 可拖可缩（用户拍板的口径）。框内仍然透传给笔，只有框线与角标吃指针。
    final String? selectedKey = _selectedKeyOf(regionSet);
    final String? selectedAnswerKey = _answerQuestionId == null
        ? null
        : _answerMarkKey(_answerQuestionId!);
    final RegionOverlayConfig? regionConfig = showRegions && ready != null
        ? RegionOverlayConfig(
            editable: true,
            // 「显示作答情况」= 作答框编辑模式：所有作答框吃指针；
            // 关闭时回到题目框编辑（两者默认重合，不能同时全量可点）。
            answerEditing: _showAnswers,
            // 作答框选中时把叠加层选中态切到它；否则保持题目框选中。
            selectedKey: selectedAnswerKey ?? selectedKey,
            onSelect: (String key) {
              final String? answerId = _answerIdOfKey(key);
              if (answerId != null) {
                _selectAnswerById(regionSet, answerId);
              } else {
                _selectAnchorOf(regionSet, key);
              }
            },
            onDeselect: () => setState(() {
              _selected = null;
              _answerQuestionId = null;
            }),
            // 贴框浮动条：选中就能看到"能做什么"，不用去猜长按。
            actionsOf: (RegionMark mark) {
              if (mark.isAnswer) {
                // 虚线作答框：只给「加题」。它经常是"被识别成答案、其实是一道题"
                // 的那一块，用户点一下就能扶正（2026-10-24 用户第 10 条）。
                return const <RegionAction>{RegionAction.addQuestion};
              }
              final QuestionBundle? bundle = _bundleOf(regionSet, mark.key);
              return bundle == null
                  ? const <RegionAction>{}
                  : _actionsFor(bundle, regionSet, ready);
            },
            onAction: (String key, RegionAction action) {
              final String? answerId = _answerIdOfKey(key);
              if (answerId != null) {
                if (action == RegionAction.addQuestion) {
                  unawaited(_promoteAnswerToQuestion(regionSet, answerId));
                }
                return;
              }
              final QuestionBundle? bundle = _bundleOf(regionSet, key);
              if (bundle == null) {
                return;
              }
              unawaited(_applyAction(bundle, action, ready, regionSet));
            },
            onMove: (String key, int page, double dx, double dy) {
              if (_answerIdOfKey(key) != null) {
                _moveAnswer(key, page, dx, dy);
                return;
              }
              unawaited(
                edit.run(
                  MoveCorrection(
                    id: Ulid.next(),
                    key: key,
                    page: page,
                    dx: dx,
                    dy: dy,
                  ),
                ),
              );
            },
            onResize: (String key, int page, RegionRect rect) {
              if (_answerIdOfKey(key) != null) {
                _resizeAnswer(key, page, rect);
                return;
              }
              unawaited(
                edit.run(
                  ResizeCorrection(
                    id: Ulid.next(),
                    key: key,
                    page: page,
                    rect: rect,
                  ),
                ),
              );
            },
            onMenu: (String key, Offset position) {
              final String? answerId = _answerIdOfKey(key);
              if (answerId != null) {
                final QuestionBundle? bundle = _bundleById(regionSet, answerId);
                if (bundle != null) {
                  unawaited(_showAnswerMenu(bundle));
                }
                return;
              }
              unawaited(_showRegionMenu(key, ready));
            },
          )
        : null;
    if (ready != null) {
      _ensureRegions(ready);
    }

    // 「回看出处」：切题结果加载后，一次性跳到该题所在页并选中、打开面板。
    if (ready != null && _pendingQuestionId != null && !regionSet.isEmpty) {
      final QuestionBundle? target = _bundleById(
        regionSet,
        _pendingQuestionId!,
      );
      if (target != null && target.slices.isNotEmpty) {
        final QuestionBundle bundle = target;
        _pendingQuestionId = null;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) {
            return;
          }
          setState(() => _panelOpen = true);
          _selectBundle(bundle);
          _jumpTo(bundle.slices.first.pageIndex);
        });
      }
    }

    return PopScope(
      // 系统返回键先收面板：AI 打开时回题目区域，题目区域打开时才退出阅读器。
      // 这是"右侧面板 = 阅读器内的一层"应有的返回语义。
      canPop: !_panelOpen,
      onPopInvokedWithResult: (bool didPop, Object? result) {
        if (didPop || !_panelOpen) {
          return;
        }
        if (_aiOpen) {
          setState(() => _aiOpen = false);
        } else {
          _togglePanel();
        }
      },
      child: Scaffold(
        key: _scaffoldKey,
        appBar: AppBar(
          title: Text(
            ready?.workbook.title ?? '阅读器',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          // 固定形态：工具带贴在顶栏下方（用户可在设置里切换形态）。
          bottom: pinnedToolbar && ready != null
              ? InkToolStrip(darkPaper: darkPaper)
              : null,
          actions: buildReaderTopActions(
            width: MediaQuery.sizeOf(context).width,
            // 文字模式：宽度放得下 8 个带文字的动作才开，否则退回纯图标
            // （AppBar 的 actions 压不动标题，溢出只会出黄黑条）。
            showLabels:
                ref.watch(iconLabelsProvider) &&
                labelsFitWidth(
                  width: MediaQuery.sizeOf(context).width,
                  actionCount: 8,
                ),
            canUndo: canUndo,
            canRedo: canRedo,
            onUndo: () => ref.read(inkEditProvider(pageKey).notifier).undo(),
            onRedo: () => ref.read(inkEditProvider(pageKey).notifier).redo(),
            onSave: () => unawaited(_saveNow()),
            handTool: _handTool,
            onToggleHandTool: _toggleHandTool,
            mode: _mode,
            onToggleMode: _switchMode,
            scrollZoom: _scrollZoom,
            onZoomSelected: (double value) =>
                _scrollKey.currentState?.setScale(value),
            onOpenDisplay: _openDisplaySheet,
            panelOpen: _panelOpen,
            onTogglePanel: _togglePanel,
            onOpenThumbnails: () => _scaffoldKey.currentState?.openEndDrawer(),
            hasThumbnails: _cache != null,
            onOpenAnswerSheet: _openAnswerSheet,
          ),
        ),
        endDrawer: (ready == null || _cache == null)
            ? null
            : ThumbDrawer(
                pages: ready.pages,
                cache: _cache!,
                currentPage: _current,
                onSelected: _jumpTo,
              ),
        body: _buildBody(
          theme,
          async,
          ready,
          brush,
          darkPaper,
          marksByPage,
          regionConfig,
          edit,
          regionSet,
          selectedKey,
          aiConfig,
        ),
      ),
    );
  }

  Widget _buildBody(
    ThemeData theme,
    AsyncValue<ReaderHandle> async,
    ReaderHandle? ready,
    InkBrush brush,
    bool darkPaper,
    Map<int, List<RegionMark>> marksByPage,
    RegionOverlayConfig? regionConfig,
    RegionEditController edit,
    RegionSet regionSet,
    String? selectedKey,
    LlmConfig aiConfig,
  ) {
    if (async.hasError) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(ShqSpace.xl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text('打不开这一卷', style: theme.textTheme.titleLarge),
              const SizedBox(height: ShqSpace.sm),
              Text('${async.error}', style: theme.textTheme.bodySmall),
            ],
          ),
        ),
      );
    }
    if (ready == null || _cache == null) {
      return const Center(child: CircularProgressIndicator());
    }

    final int initial = _initialPage ?? 0;
    // 走到这里 ready 一定非空（上面 guard 过），session 一定已建好
    final String sessionId = ready.session.id;
    QuestionBundle? selectedBundle;
    for (final QuestionBundle bundle in regionSet.questions) {
      if (bundle.anchorKey == selectedKey) {
        selectedBundle = bundle;
        break;
      }
    }
    return Column(
      // 必须 stretch：Column 默认 center 会把阅读视图按"自身宽度"居中，
      // 阅读视图一旦不撑满宽度，它的裁剪边界就变成内容边界（实测会裁掉右侧内容）。
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (_aiGrading)
          _AiGradeBanner(
            done: _aiGradeDone,
            total: _aiGradeTotal,
            onStop: () => setState(() => _aiGradeStop = true),
          ),
        Expanded(
          child: Stack(
            children: <Widget>[
              Positioned.fill(
                // 编辑态面板会占右侧：给阅读区留出同样的内边距，
                // 否则正在调的框会被面板压住（一次重排，不做动画——动画会每帧
                // 触发位图重取，见 2026-10-23 的位图缓存红线）。
                child: Padding(
                  padding: EdgeInsets.only(
                    right: _panelOpen ? _panelInset(context) : 0,
                  ),
                  child: _mode == ViewMode.paged
                      ? PagedReaderView(
                          key: _pagedKey,
                          pages: ready.pages,
                          cache: _cache!,
                          initialPage: initial,
                          onPageChanged: _onPageChanged,
                          style: _style,
                          intensity: _intensity,
                          sessionId: sessionId,
                          inkTool: brush.tool,
                          inkColorIndex: brush.colorIndex,
                          inkbrushWidth: brush.brushWidth,
                          regionMarksByPage: marksByPage,
                          regionConfig: regionConfig,
                          // 打开题目区域 = 调框模式：墨迹层只画不收笔，
                          // 手写笔专用于点选/拖动/缩放框（2026-10-23 用户口径）。
                          regionEditing: _panelOpen,
                          // 调框时虽然不写字，但单指仍应能平移页面看别的框；
                          // 所以 fingerWrites 也关掉（= 浏览手势），不是书写手势。
                          fingerWrites: !_handTool && !_panelOpen,
                        )
                      : ScrollReaderView(
                          key: _scrollKey,
                          pages: ready.pages,
                          cache: _cache!,
                          initialPage: initial,
                          onPageChanged: _onPageChanged,
                          style: _style,
                          intensity: _intensity,
                          sessionId: sessionId,
                          inkTool: brush.tool,
                          inkColorIndex: brush.colorIndex,
                          inkbrushWidth: brush.brushWidth,
                          regionMarksByPage: marksByPage,
                          regionConfig: regionConfig,
                          regionEditing: _panelOpen,
                          // 调框时单指仍可平移页面；见 paged 分支同一理由。
                          fingerWrites: !_handTool && !_panelOpen,
                          // 这一笔没落在纸上：给一句明确的话，别让用户干瞪眼。
                          onPenMissed: _showPenMissed,
                          // 双指缩放改了倍率后，把 AppBar 的百分比同步过来
                          onZoomChanged: (double value) => setState(() {
                            _scrollZoom = value;
                          }),
                        ),
                ),
              ),
              // 浮钮形态（默认）：收起时只有一个圆，展开才是完整笔刷面板。
              // 固定形态时工具带在 AppBar.bottom，这里就不画了。
              // 调框模式不显示笔刷钮：这时笔用来调框，写字被禁用，留着只会误导。
              // 手势模式下**仍然显示**：笔依旧书写，工具必须可用。
              if (!ref.watch(inkToolbarPinnedProvider) && !_panelOpen)
                Positioned(
                  right: ShqSpace.md,
                  bottom: ShqSpace.sm,
                  child: SafeArea(
                    top: false,
                    child: InkFab(darkPaper: darkPaper),
                  ),
                ),
              // 检查面板（T3.5）：从右侧滑入，**不重建**阅读视图 → 书写帧率不受影响。
              Positioned(
                top: 0,
                bottom: 0,
                right: 0,
                // 面板收起后仍在树里（保留动画与滚动位置），但不能让读屏
                // 继续读到屏幕外的按钮；AI 打开时下面的题目面板同理。
                child: ExcludeSemantics(
                  excluding: !_panelOpen || _aiOpen,
                  child: IgnorePointer(
                    ignoring: !_panelOpen,
                    child: AnimatedSlide(
                      offset: _panelOpen ? Offset.zero : const Offset(1, 0),
                      duration: ShqMotion.base,
                      curve: ShqMotion.curveStandard,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          boxShadow: <BoxShadow>[
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.10),
                              blurRadius: 18,
                              offset: const Offset(-2, 0),
                            ),
                          ],
                        ),
                        child: ValueListenableBuilder<CorrectionLog>(
                          valueListenable: edit.log,
                          builder:
                              (BuildContext context, CorrectionLog log, _) {
                                // 数学/符号题多到整卷不适合文字转写时，面板只给题面预览。
                                final bool showStemText = _showStemText(
                                  regionSet,
                                );
                                return RegionPanel(
                                  width: _panelWidth(context),
                                  showLabels: ref.watch(iconLabelsProvider),
                                  set: regionSet,
                                  selectedKey: selectedKey,
                                  editedCount: log.length,
                                  questionDelta: questionDeltaOf(log),
                                  saveTick: _saveTick,
                                  verdictOf: (QuestionBundle bundle) =>
                                      _grades?.verdictOf(bundle.question.id) ??
                                      AnswerVerdict.none,
                                  counts: _gradeCounts(regionSet),
                                  grading: _grading || _aiGrading,
                                  gradeBusyLabel: _grading && _gradeTotal > 0
                                      ? '改卷 $_gradeDone/$_gradeTotal'
                                      : null,
                                  onGradeAll: () => unawaited(_gradeAll()),
                                  onFillAnswers: () =>
                                      unawaited(_fillAnswersWithAi()),
                                  fillingAi: _fillingAi,
                                  fillDone: _fillDone,
                                  fillTotal: _fillTotal,
                                  onSetVerdict: (
                                    QuestionBundle bundle,
                                    AnswerVerdict verdict,
                                  ) => unawaited(_setVerdict(bundle, verdict)),
                                  multiSelecting: _multiSelecting,
                                  selectedIds: _multiSelected,
                                  favoriteQuestionIds: _favoriteQuestionIds,
                                  onToggleMultiSelect: _toggleMultiSelect,
                                  onToggleSelect: _toggleSelect,
                                  onBatch: (RegionPanelBatch action) =>
                                      unawaited(_runBatch(action)),
                                  canUndo: log.ops.isNotEmpty,
                                  canRedo: edit.canRedo,
                                  onSelect: _selectFromPanel,
                                  onAdd: () => unawaited(_addRegion(ready)),
                                  onUndo: () => unawaited(edit.undo()),
                                  onRedo: () => unawaited(edit.redo()),
                                  onClearAll: () => unawaited(edit.clearAll()),
                                  onRecut: () => unawaited(_recut(ready)),
                                  onClose: _togglePanel,
                                  preview: _previewFor(
                                    ready,
                                    regionSet,
                                    context,
                                    formulaPaper: !showStemText,
                                  ),
                                  showStemText: showStemText,
                                  answers: regionSet.answers,
                                  onFavorite: _favoriteQuestion,
                                  onCheckAnswer: (QuestionBundle bundle) =>
                                      unawaited(_checkAnswer(bundle)),
                                  onAskAi: (QuestionBundle bundle) =>
                                      unawaited(_showAskAi(bundle)),
                                  showAnswers: _showAnswers,
                                  onToggleShowAnswers: _toggleShowAnswers,
                                  onReorder: (int oldIndex, int newIndex) =>
                                      unawaited(
                                        _moveQuestion(
                                          regionSet,
                                          oldIndex,
                                          newIndex,
                                        ),
                                      ),
                                  onSave: () => unawaited(_saveEdits()),
                                  saving: _savingEdits,
                                  onMoveSelected: _moveSelectedQuestion,
                                  onResetOrder: _resetQuestionOrder,
                                  answerQuestionId: _answerQuestionId,
                                  onToggleAnswer: _toggleAnswerFor,
                                  answerPanel: selectedBundle == null
                                      ? null
                                      : _buildAnswerPanel(
                                          selectedBundle,
                                          regionSet.answers.forQuestion(
                                            ordinal:
                                                selectedBundle.question.ordinal,
                                            label:
                                                selectedBundle.question.label,
                                          ),
                                        ),
                                  actionsOf: (QuestionBundle bundle) =>
                                      _actionsFor(bundle, regionSet, ready),
                                  onAction:
                                      (
                                        QuestionBundle bundle,
                                        RegionAction action,
                                      ) => unawaited(
                                        _applyAction(
                                          bundle,
                                          action,
                                          ready,
                                          regionSet,
                                        ),
                                      ),
                                );
                              },
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              // 问 AI（2026-10-24）：盖在题目区域上的一层右侧面板。
              // 与题目区域同宽、同位置；返回 = 回到题目区域，收起 = 整个面板关闭。
              // 用 AnimatedSlide 而不是 Navigator push：不打断阅读视图，
              // 笔迹层与位图缓存都保持原状。
              Positioned(
                top: 0,
                bottom: 0,
                right: 0,
                child: ExcludeSemantics(
                  excluding: !_aiOpen,
                  child: IgnorePointer(
                    ignoring: !_aiOpen,
                    child: AnimatedSlide(
                      offset: _aiOpen ? Offset.zero : const Offset(1, 0),
                      duration: ShqMotion.base,
                      curve: ShqMotion.curveStandard,
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
                        child: _aiBundle == null
                            ? const SizedBox.shrink()
                            : AiChatPanel(
                                // 换一道题就换一份输入状态：历史与附件都是按题的。
                                key: ValueKey<String>(_aiBundle!.anchorKey),
                                width: _panelWidth(context),
                                payload: _aiPayloadOf(_aiBundle!),
                                config: aiConfig,
                                initialTurns: _aiTurns,
                                attachments: _aiAttachments,
                                referenceAnswer: _referenceAnswerOf(_aiBundle!),
                                hasStudentAnswer: _hasStudentAnswerOf(
                                  _aiBundle!,
                                ),
                                onOpenConfig: () =>
                                    unawaited(_openAiConfig(aiConfig)),
                                onSend:
                                    (
                                      String message,
                                      List<ChatTurn> history,
                                      List<AiImageAttachment> attachments,
                                      bool deepThinking,
                                    ) => _aiSend(
                                      aiConfig,
                                      _aiBundle!,
                                      message,
                                      history,
                                      attachments,
                                      deepThinking,
                                    ),
                                onQuick:
                                    (
                                      AiQuickAction action,
                                      List<AiImageAttachment> attachments,
                                    ) => _runAiQuick(
                                      aiConfig,
                                      _aiBundle!,
                                      action,
                                      attachments,
                                    ),
                                onPersist: (List<ChatTurn> turns) => ref
                                    .read(
                                      aiChatStoreProvider(widget.workbookId),
                                    )
                                    .save(
                                      widget.workbookId,
                                      _aiBundle!.question.id,
                                      turns,
                                    ),
                                onBack: () => setState(() => _aiOpen = false),
                                onClose: () {
                                  setState(() {
                                    _aiOpen = false;
                                    _panelOpen = false;
                                    _selected = null;
                                  });
                                },
                              ),
                      ),
                    ),
                  ),
                ),
              ),
              // 面板宽度把手（2026-10-24）：贴在面板左缘，只在面板展开时存在。
              //
              // 单独一个 Positioned 而不是包进面板里，是为了不动面板既有的滑入结构；
              // 放在 AI 面板之后 = 永远在最上层，题目区域与问 AI 共用同一个宽度、同一个把手。
              if (_panelOpen)
                Positioned(
                  top: 0,
                  bottom: 0,
                  // 面板左缘在 `screen - panelWidth`。命中区 28dp：400dpi 平板上
                  // 16dp 按不准，"按准"的收益远大于让出的 12dp；中心仍压在左缘上。
                  right: _panelWidth(context) - 14,
                  width: 28,
                  child: PanelResizeHandle(
                    onResizeStart: _onPanelResizeStart,
                    onResize: _onPanelResize,
                    onResizeEnd: _onPanelResizeEnd,
                  ),
                ),
              // 「重框」浮窗（2026-10-24 用户第 3 条）：左上角，只有两个动作。
              if (_adjustTarget != null)
                Positioned(
                  left: ShqSpace.sm,
                  top: 0,
                  child: SafeArea(
                    child: AnswerAdjustBar(
                      label:
                          _adjustTarget!.question.label ??
                          '${_adjustTarget!.question.ordinal}',
                      onBack: () => unawaited(_backToAnswerSheet()),
                      onStay: () => unawaited(_stayInReader()),
                      savedAt: _lastSavedAt,
                      saving: _savingEdits,
                    ),
                  ),
                ),
              // 开发期性能仪表盘（T2.5）：默认关，设置页可开；release 构建里不存在。
              if (ref.watch(debugHudProvider) && _frameStats != null)
                Positioned(
                  left: ShqSpace.sm,
                  top: ShqSpace.sm,
                  child: SafeArea(
                    child: DebugHud(
                      collector: _frameStats!,
                      doc: ref.watch(
                        inkDocProvider(
                          InkPageKey(
                            sessionId,
                            _current,
                            workbookId: widget.workbookId,
                          ),
                        ),
                      ),
                      cache: _cache!,
                    ),
                  ),
                ),
            ],
          ),
        ),
        SafeArea(
          top: false,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              PageIndicator(
                current: _current,
                total: ready.pages.length,
                onTap: () => _scaffoldKey.currentState?.openEndDrawer(),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// AI 后台判题的顶部进度条（2026-10-26 用户：提示用户是否提交 AI 判）。
///
/// 不挡阅读：它只占一行，做完自动消失；「停止」只停后续题，已完成的结果保留。
class _AiGradeBanner extends StatelessWidget {
  const _AiGradeBanner({
    required this.done,
    required this.total,
    required this.onStop,
  });

  final int done;
  final int total;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final double? fraction = total <= 0 ? null : (done / total).clamp(0.0, 1.0);
    return Material(
      color: scheme.secondaryContainer,
      child: SafeArea(
        top: false,
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(ShqSpace.md, 6, ShqSpace.sm, 6),
          child: Row(
            children: <Widget>[
              Icon(
                Icons.auto_awesome,
                size: 16,
                color: scheme.onSecondaryContainer,
              ),
              const SizedBox(width: ShqSpace.sm),
              Text(
                'AI 后台判 $done/$total',
                style: theme.textTheme.labelMedium?.copyWith(
                  color: scheme.onSecondaryContainer,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(width: ShqSpace.md),
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(ShqRadius.pill),
                  child: LinearProgressIndicator(
                    value: fraction,
                    minHeight: 4,
                    backgroundColor: scheme.surfaceContainerHighest,
                  ),
                ),
              ),
              TextButton(
                onPressed: onStop,
                style: TextButton.styleFrom(
                  foregroundColor: scheme.onSecondaryContainer,
                  minimumSize: const Size(0, 32),
                  padding: const EdgeInsets.symmetric(horizontal: ShqSpace.sm),
                ),
                child: const Text('停止'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 一次作答快照：OCR 真正要用的笔迹 + 指纹 + 是否算「有作答」。
///
/// 放在文件末尾而不是某个 State 里：它是纯数据，方法只做派生判断，
/// 不持有 context / ref，便于以后抽到 domain 做单测。
class _AnswerInkSnapshot {
  const _AnswerInkSnapshot({
    required this.entry,
    required this.sheetDocs,
    required this.pageRevision,
    required this.pageStrokes,
    required this.paperPages,
    required this.signature,
  });

  final AnswerSheetEntry entry;
  final List<InkDoc> sheetDocs;
  final int pageRevision;
  final List<InkStroke> pageStrokes;
  final int paperPages;
  final String signature;

  bool get hasSheetInk => sheetDocs.any((InkDoc doc) => doc.strokes.isNotEmpty);

  bool get hasPageInk => pageStrokes.isNotEmpty;

  bool get hasAnyInk => hasSheetInk || hasPageInk;

  /// 与判题/记录的口径一致：识别文字、作答原图、答题卡笔迹、卷面框内笔迹
  /// 任一存在都算「有作答」。
  bool get hasWork => entry.hasText || entry.hasCrop || hasAnyInk;

  int get strokeCount =>
      sheetDocs.fold<int>(0, (int sum, InkDoc doc) => sum + doc.strokeCount) +
      pageStrokes.length;
}
