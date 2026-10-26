import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shuaqi/app/favorite/favorite_store.dart';
import 'package:shuaqi/domain/answer/answer_paper.dart';
import 'package:shuaqi/domain/ink/ink_palette.dart';
import 'package:shuaqi/domain/ink/ink_tool.dart';
import 'package:shuaqi/domain/model/favorite.dart';
import 'package:shuaqi/domain/model/favorite_set_plan.dart';
import 'package:shuaqi/domain/reader/panel_metrics.dart';
import 'package:shuaqi/infra/vault/paths.dart';
import 'package:shuaqi/state/app_providers.dart';
import 'package:shuaqi/state/favorite_providers.dart';
import 'package:shuaqi/state/ink_providers.dart';
import 'package:shuaqi/state/ink_tool_provider.dart';
import 'package:shuaqi/state/panel_width_provider.dart';
import 'package:shuaqi/state/redo_context.dart';
import 'package:shuaqi/state/ui_prefs_provider.dart';
import 'package:shuaqi/ui/favorites/favorite_ai_panel.dart';
import 'package:shuaqi/ui/favorites/favorite_card.dart';
import 'package:shuaqi/ui/favorites/favorite_image.dart';
import 'package:shuaqi/ui/panel/answer_paper_painter.dart';
import 'package:shuaqi/ui/panel/answer_paper_sheet.dart';
import 'package:shuaqi/ui/panel/panel_resize_handle.dart';
import 'package:shuaqi/ui/reader/ink_layer.dart';
import 'package:shuaqi/ui/reader/ink_painters.dart';
import 'package:shuaqi/ui/reader/ink_toolbar.dart';
import 'package:shuaqi/ui/router.dart';
import 'package:shuaqi/ui/theme/tokens.dart';
import 'package:shuaqi/ui/widgets/labeled_action.dart';
import 'package:shuaqi/ui/widgets/pressable.dart';

/// 进入「重刷」的入参。
///
/// 单题重刷与组卷连刷走同一个页面：
/// - 单题：`favoriteIds: [id]`、`title: 第 X 题`；
/// - 组卷：`setId` + `favoriteIds`（成员快照，避免进页面时再查一遍）、`title: 卷名`。
class RedoArgs {
  const RedoArgs({
    required this.favoriteIds,
    required this.title,
    this.setId,
    this.initialIndex = 0,
  });

  final List<String> favoriteIds;
  final String title;
  final String? setId;
  final int initialIndex;
}

/// 收藏题「二刷」：题面在上、答题纸在下，就地重写一遍（T8.3b / T8.4）。
///
/// 口径：
/// - **不改原作答**：重刷笔迹单独存 `favorites/<id>/ink/pN.sif`，
///   第一次作答的 `answer.png` 原样保留（那是判题/回看的证据）；
/// - **同一份重刷笔迹**：单题入口和组卷入口写的是同一个文件，
///   刷到一半换个入口还能接着写；
/// - **纸张按收藏记忆**（尺寸/方向/张数/纸样式，`favorites/<id>/paper.json`），
///   换尺寸时旧笔迹按比例搬；`pageIndex` 就是第几张纸；
/// - **笔刷工具**与阅读器共用同一个「固定顶部 / 右下浮钮」开关；
/// - **问 AI** 是右侧面板（与阅读器题目面板同一套宽度与拖拽），历史落快照。
class FavoriteRedoPage extends ConsumerStatefulWidget {
  const FavoriteRedoPage({super.key, required this.args});

  final RedoArgs args;

  @override
  ConsumerState<FavoriteRedoPage> createState() => _FavoriteRedoPageState();
}

class _FavoriteRedoPageState extends ConsumerState<FavoriteRedoPage> {

  /// 文字模式（2026-10-26 用户第 15 条）：顶栏动作旁显示功能文字。
  bool get _showLabels =>
      ref.watch(iconLabelsProvider) &&
      labelsFitWidth(
        width: MediaQuery.sizeOf(context).width,
        actionCount: 5,
      );
  final TransformationController _zoom = TransformationController();
  final Map<String, FavoriteImage?> _stems = <String, FavoriteImage?>{};
  final Set<String> _upgrading = <String>{};
  final Map<String, AnswerPaper> _papers = <String, AnswerPaper>{};
  List<Favorite> _items = <Favorite>[];
  int _index = 0;
  int _paperIndex = 0;
  bool _loading = true;
  bool _panMode = false;
  bool _collapsed = false;
  bool _aiOpen = false;

  /// 拖动中的面板宽度（null = 用全局记忆值）。
  double? _dragPanelWidth;
  double _dragStartPanelWidth = 0;

  Favorite? get _current => _items.isEmpty ? null : _items[_index];

  AnswerPaper get _paper {
    final Favorite? favorite = _current;
    if (favorite == null) {
      return AnswerPaper.defaults;
    }
    return _papers[favorite.id] ?? AnswerPaper.defaults;
  }

  InkPageKey _inkKeyOf(Favorite favorite) =>
      InkPageKey(favoriteRedoSessionId(favorite.id), _paperIndex);

  @override
  void initState() {
    super.initState();
    // 告诉记录层"这次重刷是从哪儿进来的"（组卷 / 单题），
    // 打点时据此写 origin 与组卷名（2026-10-26 用户第 9/16 条）。
    ref
        .read(redoContextProvider.notifier)
        .enter(
          RedoContext(title: widget.args.title, setId: widget.args.setId),
        );
    unawaited(_load());
  }

  @override
  void dispose() {
    ref.read(redoContextProvider.notifier).leave();
    _zoom.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final List<Favorite> items = await _loadItems();
    if (!mounted) {
      return;
    }
    final int index = items.isEmpty
        ? 0
        : widget.args.initialIndex.clamp(0, items.length - 1);
    setState(() {
      _items = items;
      _index = index;
      _loading = false;
    });
    if (items.isNotEmpty) {
      await _loadPaperOf(items[index]);
      unawaited(_ensureStem(items[index]));
    }
  }

  Future<List<Favorite>> _loadItems() async {
    final FavoriteStore store = ref.read(favoriteStoreProvider);
    final String? setId = widget.args.setId;
    if (setId != null && setId.isNotEmpty) {
      final List<Favorite> fromSet = await store.itemsOfSet(setId);
      if (fromSet.isNotEmpty) {
        return fromSet;
      }
    }
    final List<Favorite> out = <Favorite>[];
    for (final String id in widget.args.favoriteIds) {
      final Favorite? favorite = await store.byId(id);
      if (favorite != null) {
        out.add(favorite);
      }
    }
    return out;
  }

  Future<void> _loadPaperOf(Favorite favorite) async {
    if (_papers.containsKey(favorite.id)) {
      return;
    }
    final AnswerPaper paper = await ref
        .read(favoriteRedoPaperStoreProvider)
        .load(favorite.id);
    if (!mounted) {
      return;
    }
    setState(() {
      _papers[favorite.id] = paper;
      _paperIndex = _paperIndex.clamp(0, paper.pages - 1);
    });
  }

  /// 先显示已有题面图，再后台补一张高清的（老收藏可能只有 1024px 宽）。
  Future<void> _ensureStem(Favorite favorite) async {
    if (_upgrading.contains(favorite.id)) {
      return;
    }
    final File file = ref
        .read(vaultProvider)
        .file(VaultPaths.favoriteStem(favorite.id));
    final FavoriteImage? existing = await loadFavoriteImage(file);
    if (!mounted) {
      return;
    }
    if (existing != null || !_stems.containsKey(favorite.id)) {
      setState(() => _stems[favorite.id] = existing);
    }
    _upgrading.add(favorite.id);
    final Uint8List? bytes = await ref
        .read(favoriteStemServiceProvider)
        .ensure(
          favoriteId: favorite.id,
          workbookId: favorite.workbookId,
          pageIndex: favorite.pageIndex,
          rect: favorite.rect,
        );
    if (bytes == null || !mounted) {
      return;
    }
    final FavoriteImage? upgraded = await decodeFavoriteImage(bytes);
    if (upgraded != null && mounted) {
      setState(() => _stems[favorite.id] = upgraded);
    }
  }

  Future<void> _goTo(int index) async {
    if (index < 0 || index >= _items.length || index == _index) {
      return;
    }
    await _flushCurrent();
    if (!mounted) {
      return;
    }
    setState(() {
      _index = index;
      _paperIndex = 0;
      _panMode = false;
    });
    _zoom.value = Matrix4.identity();
    final Favorite favorite = _items[index];
    await _loadPaperOf(favorite);
    unawaited(_ensureStem(favorite));
  }

  Future<void> _setPaperIndex(int value) async {
    final Favorite? favorite = _current;
    if (favorite == null) {
      return;
    }
    final AnswerPaper paper = _paper;
    if (value < 0 || value >= paper.pages || value == _paperIndex) {
      return;
    }
    await _flushCurrent();
    if (!mounted) {
      return;
    }
    setState(() => _paperIndex = value);
    _zoom.value = Matrix4.identity();
  }

  /// 画布右侧的「＋」：加一张并跳过去（与答题卡同一套操作）。
  Future<void> _addPaper() async {
    final Favorite? favorite = _current;
    if (favorite == null) {
      return;
    }
    final AnswerPaper paper = _paper;
    if (paper.pages >= AnswerPaper.maxPages) {
      return;
    }
    await _flushCurrent();
    if (!mounted) {
      return;
    }
    final AnswerPaper next = paper.copyWith(pages: paper.pages + 1);
    await ref.read(favoriteRedoPaperStoreProvider).save(favorite.id, next);
    if (!mounted) {
      return;
    }
    setState(() {
      _papers[favorite.id] = next;
      _paperIndex = next.pages - 1;
    });
    _zoom.value = Matrix4.identity();
  }

  Future<void> _flushCurrent() async {
    final Favorite? favorite = _current;
    if (favorite == null) {
      return;
    }
    await ref.read(inkEditProvider(_inkKeyOf(favorite)).notifier).flushSave();
  }

  /// 换纸张：先落盘当前笔迹 → 存配置 → 让所有已载入的纸按新尺寸重读
  /// （store 会按 `scaleInkDoc` 等比搬旧笔迹）。
  Future<void> _openPaperSheet() async {
    final Favorite? favorite = _current;
    if (favorite == null) {
      return;
    }
    final AnswerPaper paper = _paper;
    final AnswerPaperChange? change = await showAnswerPaperSheet(
      context,
      current: paper,
      questionLabel: favorite.label,
      showApplyAll: false,
      showPages: true,
    );
    if (change == null || !mounted) {
      return;
    }
    await _flushCurrent();
    if (!mounted) {
      return;
    }
    await ref
        .read(favoriteRedoPaperStoreProvider)
        .save(favorite.id, change.paper);
    if (!mounted) {
      return;
    }
    setState(() {
      _papers[favorite.id] = change.paper;
      _paperIndex = _paperIndex.clamp(0, change.paper.pages - 1);
    });
    _invalidateInk(favorite);
    _tip('答题纸：${change.paper.summary}');
  }

  void _invalidateInk(Favorite favorite) {
    final String session = favoriteRedoSessionId(favorite.id);
    for (int i = 0; i < AnswerPaper.maxPages; i++) {
      final InkPageKey key = InkPageKey(session, i);
      ref.invalidate(inkStoreForKeyProvider(key));
      ref.invalidate(inkEditProvider(key));
    }
  }

  Future<void> _finish() async {
    await _flushCurrent();
    if (!mounted) {
      return;
    }
    final NavigatorState navigator = Navigator.of(context);
    final int total = _items.length;
    await showDialog<void>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('本轮刷完'),
        content: Text(
          total <= 1
              ? '这道题的重刷已保存。原作答不受影响，回去还能接着写。'
              : '本轮 $total 道题都翻过了，重刷笔迹已逐题保存。原作答不受影响。',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('再看看'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(context);
              navigator.maybePop();
            },
            child: const Text('完成'),
          ),
        ],
      ),
    );
  }

  Future<void> _clearCurrent() async {
    final Favorite? favorite = _current;
    if (favorite == null) {
      return;
    }
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('清空这张纸的重刷'),
        content: Text(
          '只清空重刷笔迹（当前第 ${_paperIndex + 1} 张纸），'
          '收藏时的原作答与判题不受影响。',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) {
      return;
    }
    ref.read(inkEditProvider(_inkKeyOf(favorite)).notifier).clearPage();
    await ref.read(inkEditProvider(_inkKeyOf(favorite)).notifier).flushSave();
    if (mounted) {
      _tip('已清空这张纸的重刷笔迹');
    }
  }

  void _openSource(Favorite favorite) {
    unawaited(
      Navigator.of(context).pushNamed(
        AppRoutes.reader,
        arguments: ReaderRouteArgs(
          workbookId: favorite.workbookId,
          initialQuestionId: favorite.questionId,
        ),
      ),
    );
  }

  void _tip(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          duration: const Duration(milliseconds: 1800),
          behavior: SnackBarBehavior.floating,
        ),
      );
  }

  // ---- 右侧面板宽度（与阅读器题目面板同一套记忆与拖拽） ----

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

  /// 题目列表：组卷连刷时快速跳题（顺序即卷内题序）。
  Future<void> _openQuestionList() async {
    final int? picked = await showModalBottomSheet<int>(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(ShqRadius.lg)),
      ),
      builder: (BuildContext context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(
                ShqSpace.lg,
                ShqSpace.md,
                ShqSpace.lg,
                ShqSpace.sm,
              ),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      widget.args.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  Text(
                    '${_items.length} 题',
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: _items.length,
                itemBuilder: (BuildContext context, int i) {
                  final Favorite favorite = _items[i];
                  final bool current = i == _index;
                  return ListTile(
                    dense: true,
                    selected: current,
                    leading: CircleAvatar(
                      radius: 13,
                      backgroundColor: current
                          ? Theme.of(context).colorScheme.primaryContainer
                          : Theme.of(context).colorScheme.surfaceContainerHigh,
                      child: Text(
                        '${i + 1}',
                        style: Theme.of(context).textTheme.labelSmall,
                      ),
                    ),
                    title: Text('第 ${favorite.label} 题'),
                    subtitle: Text(
                      '${favorite.workbookTitle} · '
                      '${favoriteKindLabel(favorite.kind)}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: current
                        ? const Icon(Icons.play_arrow, size: 18)
                        : null,
                    onTap: () => Navigator.pop(context, i),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
    if (picked != null) {
      await _goTo(picked);
    }
  }

  @override
  Widget build(BuildContext context) {
    final Favorite? favorite = _current;
    final ThemeData theme = Theme.of(context);
    final bool exists = favorite != null;
    final bool pinned = ref.watch(inkToolbarPinnedProvider);
    ref.watch(panelWidthProvider);
    final double panelWidth = exists && _aiOpen ? _panelWidth(context) : 0;
    return PopScope(
      // 返回前把当前笔迹落盘：500ms 防抖还没到就退出去也不会丢。
      onPopInvokedWithResult: (bool didPop, Object? result) {
        if (didPop) {
          unawaited(_flushCurrent());
        }
      },
      child: Scaffold(
        appBar: AppBar(
          titleSpacing: 0,
          title: _title(theme, favorite),
          actions: <Widget>[
            if (!pinned && exists) ...<Widget>[
              LabeledAction(
                icon: Icons.undo,
                label: '撤销',
                tooltip: '撤销',
                showLabel: _showLabels,
                onPressed: () =>
                    ref.read(inkEditProvider(_inkKeyOf(favorite)).notifier).undo(),
              ),
              LabeledAction(
                icon: Icons.redo,
                label: '重做',
                tooltip: '重做',
                showLabel: _showLabels,
                onPressed: () =>
                    ref.read(inkEditProvider(_inkKeyOf(favorite)).notifier).redo(),
              ),
            ],
            if (exists)
              LabeledAction(
                icon: Icons.description_outlined,
                label: '答题纸',
                tooltip: '答题纸设置',
                showLabel: _showLabels,
                onPressed: () => unawaited(_openPaperSheet()),
              ),
            if (exists)
              IconButton.filledTonal(
                tooltip: _aiOpen ? '收起 AI' : '问 AI',
                isSelected: _aiOpen,
                icon: const Icon(Icons.auto_awesome_outlined),
                selectedIcon: const Icon(Icons.auto_awesome),
                onPressed: () => setState(() => _aiOpen = !_aiOpen),
              ),
            if (_items.length > 1)
              LabeledAction(
                icon: Icons.list_alt,
                label: '列表',
                tooltip: '题目列表',
                showLabel: _showLabels,
                onPressed: _openQuestionList,
              ),
            if (exists)
              PopupMenuButton<String>(
                tooltip: '更多',
                onSelected: (String value) {
                  switch (value) {
                    case 'source':
                      _openSource(favorite);
                    case 'clear':
                      unawaited(_clearCurrent());
                    case 'toolbar':
                      unawaited(
                        ref
                            .read(inkToolbarPinnedProvider.notifier)
                            .set(!pinned),
                      );
                  }
                },
                itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
                  PopupMenuItem<String>(
                    value: 'source',
                    enabled: !favorite.sourceDeleted,
                    child: const Text('回到出处'),
                  ),
                  const PopupMenuItem<String>(
                    value: 'clear',
                    child: Text('清空这张纸的重刷'),
                  ),
                  PopupMenuItem<String>(
                    value: 'toolbar',
                    child: Text(pinned ? '笔刷缩小为浮钮' : '笔刷固定到顶部'),
                  ),
                ],
              ),
          ],
          bottom: favorite != null && pinned
              ? PreferredSize(
                  preferredSize: const Size.fromHeight(52),
                  child: _RedoToolbar(inkKey: _inkKeyOf(favorite)),
                )
              : null,
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : !exists
            ? _EmptyRedo(onBack: () => Navigator.of(context).maybePop())
            : Stack(
                children: <Widget>[
                  Positioned.fill(
                    child: AnimatedPadding(
                      duration: ShqMotion.base,
                      curve: ShqMotion.curveStandard,
                      padding: EdgeInsets.only(right: panelWidth),
                      child: SafeArea(
                        top: false,
                        child: Column(
                          children: <Widget>[
                            _QuestionStrip(
                              favorite: favorite,
                              image: _stems[favorite.id],
                              pageLabel: _items.length > 1
                                  ? '第 ${_index + 1} / ${_items.length} 题'
                                  : null,
                              collapsed: _collapsed,
                              onToggle: () =>
                                  setState(() => _collapsed = !_collapsed),
                            ),
                            Expanded(
                              child: _RedoCanvas(
                                inkKey: _inkKeyOf(favorite),
                                paper: _paper,
                                zoom: _zoom,
                                panMode: _panMode,
                                showInkFab: !pinned,
                                onPanMode: () =>
                                    setState(() => _panMode = !_panMode),
                                onPrevPaper: _paperIndex > 0
                                    ? () => _setPaperIndex(_paperIndex - 1)
                                    : null,
                                onNextPaper: _paperIndex < _paper.pages - 1
                                    ? () => _setPaperIndex(_paperIndex + 1)
                                    : null,
                                onAddPaper:
                                    _paperIndex >= _paper.pages - 1 &&
                                        _paper.pages < AnswerPaper.maxPages
                                    ? () => unawaited(_addPaper())
                                    : null,
                              ),
                            ),
                            _RedoBottomBar(
                              index: _index,
                              total: _items.length,
                              paperIndex: _paperIndex,
                              paperPages: _paper.pages,
                              onPrev: _index > 0 ? () => _goTo(_index - 1) : null,
                              onNext: _index < _items.length - 1
                                  ? () => _goTo(_index + 1)
                                  : null,
                              onPrevPaper: _paperIndex > 0
                                  ? () => _setPaperIndex(_paperIndex - 1)
                                  : null,
                              onNextPaper: _paperIndex < _paper.pages - 1
                                  ? () => _setPaperIndex(_paperIndex + 1)
                                  : null,
                              onFinish: _finish,
                            ),
                          ],
                        ),
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
                        child: FavoriteAiPanel(
                          key: ValueKey<String>('redo-ai-${favorite.id}'),
                          favorite: favorite,
                          width: panelWidth,
                          onClose: () => setState(() => _aiOpen = false),
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
      ),
    );
  }

  Widget _title(ThemeData theme, Favorite? favorite) {
    final String subtitle;
    if (favorite == null) {
      subtitle = '';
    } else if (_items.length > 1) {
      subtitle =
          '${redoProgressLabel(index: _index, total: _items.length)}'
          ' · 第 ${favorite.label} 题'
          '${_paper.pages > 1 ? ' · 纸 ${_paperIndex + 1}/${_paper.pages}' : ''}';
    } else {
      subtitle =
          '${favorite.workbookTitle} · ${favoriteKindLabel(favorite.kind)}'
          '${_paper.pages > 1 ? ' · 纸 ${_paperIndex + 1}/${_paper.pages}' : ''}';
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(
          widget.args.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.titleMedium,
        ),
        if (subtitle.isNotEmpty)
          Text(
            subtitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
      ],
    );
  }
}

/// 空卷兜底（成员都被取消收藏时）。
class _EmptyRedo extends StatelessWidget {
  const _EmptyRedo({required this.onBack});

  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(
            Icons.edit_off_outlined,
            size: 44,
            color: theme.colorScheme.outline,
          ),
          const SizedBox(height: ShqSpace.md),
          Text('这份题集里没有可刷的题', style: theme.textTheme.titleSmall),
          const SizedBox(height: ShqSpace.xs),
          Text(
            '题目可能已被取消收藏，回到收藏夹重新组卷即可。',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: ShqSpace.lg),
          FilledButton.tonal(onPressed: onBack, child: const Text('返回')),
        ],
      ),
    );
  }
}

/// 题面条：可收起、点图看大图。占据的是**布局**空间（不压画布）。
class _QuestionStrip extends StatelessWidget {
  const _QuestionStrip({
    required this.favorite,
    required this.image,
    required this.pageLabel,
    required this.collapsed,
    required this.onToggle,
  });

  final Favorite favorite;
  final FavoriteImage? image;
  final String? pageLabel;
  final bool collapsed;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final double cap = math.min(MediaQuery.sizeOf(context).height * 0.24, 240);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        ShqSpace.md,
        ShqSpace.sm,
        ShqSpace.md,
        0,
      ),
      child: Material(
        color: scheme.surfaceContainerHigh.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(ShqRadius.md),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            InkWell(
              onTap: onToggle,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(
                  ShqSpace.md,
                  ShqSpace.xs,
                  ShqSpace.sm,
                  ShqSpace.xs,
                ),
                child: Row(
                  children: <Widget>[
                    Icon(
                      Icons.help_outline,
                      size: 16,
                      color: scheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: ShqSpace.sm),
                    Text(
                      '第 ${favorite.label} 题',
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(width: ShqSpace.sm),
                    Text(
                      favoriteKindLabel(favorite.kind),
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    if (pageLabel != null) ...<Widget>[
                      const SizedBox(width: ShqSpace.sm),
                      Text(
                        pageLabel!,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                    const Spacer(),
                    if (image != null)
                      Text(
                        '点图放大',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: scheme.outline,
                        ),
                      ),
                    Icon(
                      collapsed ? Icons.expand_more : Icons.expand_less,
                      size: 20,
                      color: scheme.onSurfaceVariant,
                    ),
                  ],
                ),
              ),
            ),
            if (!collapsed)
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  ShqSpace.sm,
                  0,
                  ShqSpace.sm,
                  ShqSpace.sm,
                ),
                child: FavoriteImageView(
                  image: image,
                  title: '第 ${favorite.label} 题题面',
                  emptyHint: favorite.sourceDeleted
                      ? '原卷已删除，收藏时也没有存下题面图'
                      : '题面图暂时无法生成，可回原卷查看',
                  maxHeight: cap,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 答题纸 + 笔迹层 + 缩放 + 纸张翻页。
class _RedoCanvas extends ConsumerWidget {
  const _RedoCanvas({
    required this.inkKey,
    required this.paper,
    required this.zoom,
    required this.panMode,
    required this.showInkFab,
    required this.onPanMode,
    required this.onPrevPaper,
    required this.onNextPaper,
    this.onAddPaper,
  });

  final InkPageKey inkKey;
  final AnswerPaper paper;
  final TransformationController zoom;
  final bool panMode;
  final bool showInkFab;
  final VoidCallback onPanMode;
  final VoidCallback? onPrevPaper;
  final VoidCallback? onNextPaper;

  /// 最后一页时的「＋」：加一张并跳过去（与答题卡一致）。
  final VoidCallback? onAddPaper;

  void _zoomBy(double factor) {
    final double current = zoom.value.getMaxScaleOnAxis();
    final double next = (current * factor).clamp(0.6, 4.0);
    zoom.value = Matrix4.identity()..scaleByDouble(next, next, 1, 1);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final brush = ref.watch(inkToolProvider);
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints viewport) {
        const double gutter = 10;
        final double fit = math.max(
          0.1,
          math.min(
            (viewport.maxWidth - gutter * 2) / paper.widthPt,
            (viewport.maxHeight - gutter * 2) / paper.heightPt,
          ),
        );
        final double canvasWidth = paper.widthPt * fit;
        final double canvasHeight = paper.heightPt * fit;
        return Stack(
          children: <Widget>[
            Positioned.fill(
              child: ColoredBox(
                color: scheme.surfaceContainerLowest,
                child: InteractiveViewer(
                  transformationController: zoom,
                  panEnabled: panMode,
                  scaleEnabled: true,
                  minScale: 0.6,
                  maxScale: 4,
                  boundaryMargin: const EdgeInsets.all(160),
                  child: Center(
                    child: SizedBox(
                      width: canvasWidth,
                      height: canvasHeight,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: ShqPaper.base,
                          borderRadius: BorderRadius.circular(ShqRadius.md),
                          border: Border.all(color: scheme.outlineVariant),
                          boxShadow: <BoxShadow>[
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.10),
                              blurRadius: 16,
                              offset: const Offset(0, 4),
                            ),
                          ],
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(ShqRadius.md),
                          child: Stack(
                            children: <Widget>[
                              Positioned.fill(
                                child: CustomPaint(
                                  painter: AnswerPaperPainter(
                                    color: scheme.outlineVariant.withValues(
                                      alpha: 0.32,
                                    ),
                                    rule: paper.rule,
                                    widthPt: paper.widthPt,
                                    heightPt: paper.heightPt,
                                  ),
                                ),
                              ),
                              Positioned.fill(
                                child: InkLayer(
                                  inkKey: inkKey,
                                  pageWidthPt: paper.widthPt,
                                  width: canvasWidth,
                                  darkPaper: false,
                                  tool: brush.tool,
                                  colorIndex: brush.colorIndex,
                                  brushWidth: brush.brushWidth,
                                  enabled: !panMode,
                                  inkTouch: !panMode,
                                ),
                              ),
                              Positioned(
                                left: ShqSpace.sm,
                                top: ShqSpace.xs,
                                child: IgnorePointer(
                                  child: Text(
                                    panMode
                                        ? '拖动查看 · 双指缩放'
                                        : '单指书写 · 双指缩放',
                                    style: theme.textTheme.labelSmall?.copyWith(
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
            if (onPrevPaper != null)
              Positioned(
                left: 2,
                top: 0,
                bottom: 0,
                child: Center(
                  child: _CanvasArrow(
                    icon: Icons.chevron_left,
                    tooltip: '上一张纸',
                    onTap: onPrevPaper!,
                  ),
                ),
              ),
            if (onNextPaper != null || onAddPaper != null)
              Positioned(
                right: 2,
                top: 0,
                bottom: 0,
                child: Center(
                  child: _CanvasArrow(
                    icon: onNextPaper != null ? Icons.chevron_right : Icons.add,
                    tooltip: onNextPaper != null ? '下一张纸' : '加一张',
                    highlight: onNextPaper == null,
                    onTap: onNextPaper ?? onAddPaper!,
                  ),
                ),
              ),
            if (showInkFab)
              const Positioned(
                right: 8,
                bottom: 56,
                child: InkFab(darkPaper: false),
              ),
            Positioned(
              right: 10,
              bottom: 6,
              child: _CanvasZoomBar(
                zoom: zoom,
                panMode: panMode,
                onPanMode: onPanMode,
                onZoomOut: () => _zoomBy(1 / 1.25),
                onZoomIn: () => _zoomBy(1.25),
                onFit: () => zoom.value = Matrix4.identity(),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _CanvasArrow extends StatelessWidget {
  const _CanvasArrow({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.highlight = false,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    return highlight
        ? IconButton.filled(
            tooltip: tooltip,
            onPressed: onTap,
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints.tightFor(width: 34, height: 34),
            icon: Icon(icon, size: 20),
          )
        : IconButton.filledTonal(
            tooltip: tooltip,
            onPressed: onTap,
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints.tightFor(width: 34, height: 34),
            icon: Icon(icon, size: 20),
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
  });

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
          ],
        ),
      ),
    );
  }
}

/// 顶部工具带：工具 / 颜色 / 粗细 / 撤销重做 / 缩小为浮钮。
class _RedoToolbar extends ConsumerWidget {
  const _RedoToolbar({required this.inkKey});

  final InkPageKey inkKey;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final brush = ref.watch(inkToolProvider);
    final InkToolController tools = ref.read(inkToolProvider.notifier);
    final InkEditState edit = ref.watch(inkEditProvider(inkKey));
    final InkEditController editor = ref.read(inkEditProvider(inkKey).notifier);
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final ThemeData theme = Theme.of(context);
    return Container(
      height: 52,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        border: Border(bottom: BorderSide(color: scheme.outlineVariant)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: ShqSpace.sm),
      child: Row(
        children: <Widget>[
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: <Widget>[
                  for (final InkTool tool in InkTool.values)
                    _ToolChip(
                      tool: tool,
                      selected: brush.tool == tool,
                      onTap: () => tools.selectTool(tool),
                    ),
                  _ToolbarDivider(color: scheme.outlineVariant),
                  if (!brush.isEraser)
                    for (
                      int i = 0;
                      i < InkPalette.countFor(brush.strokeStyle);
                      i++
                    )
                      _ColorChip(
                        color: previewColorOf(
                          style: brush.strokeStyle,
                          colorIndex: i,
                          darkPaper: false,
                        ),
                        selected: brush.colorIndex == i,
                        onTap: () => tools.selectColor(i),
                      ),
                  if (!brush.isEraser)
                    _ToolbarDivider(color: scheme.outlineVariant),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: SizedBox(
                      width: 132,
                      child: Row(
                        children: <Widget>[
                          Icon(
                            brush.isEraser
                                ? Icons.circle_outlined
                                : Icons.line_weight,
                            size: 15,
                            color: scheme.onSurfaceVariant,
                          ),
                          Expanded(
                            child: Slider(
                              value: brush.brushWidth.toDouble(),
                              min: 0,
                              max: 100,
                              onChanged: (double value) =>
                                  tools.selectWidth(value.round()),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          IconButton(
            tooltip: '撤销',
            onPressed: edit.canUndo ? editor.undo : null,
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.undo, size: 20),
          ),
          IconButton(
            tooltip: '重做',
            onPressed: edit.canRedo ? editor.redo : null,
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.redo, size: 20),
          ),
          IconButton(
            tooltip: '缩小为浮钮',
            onPressed: () => unawaited(
              ref.read(inkToolbarPinnedProvider.notifier).set(false),
            ),
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.picture_in_picture_alt_outlined, size: 18),
          ),
          Tooltip(
            message: '当前笔：${brush.tool.label}',
            child: Icon(
              iconOfTool(brush.tool),
              size: 16,
              color: theme.colorScheme.outline,
            ),
          ),
          const SizedBox(width: ShqSpace.xs),
        ],
      ),
    );
  }
}

class _ToolChip extends StatelessWidget {
  const _ToolChip({
    required this.tool,
    required this.selected,
    required this.onTap,
  });

  final InkTool tool;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Pressable(
        onTap: onTap,
        scale: 0.94,
        haptic: true,
        child: AnimatedContainer(
          duration: ShqMotion.instant,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          decoration: BoxDecoration(
            color: selected ? scheme.secondaryContainer : Colors.transparent,
            borderRadius: BorderRadius.circular(ShqRadius.pill),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(
                iconOfTool(tool),
                size: 17,
                color: selected
                    ? scheme.onSecondaryContainer
                    : scheme.onSurfaceVariant,
              ),
              const SizedBox(width: 4),
              Text(
                tool.label,
                style: theme.textTheme.labelSmall?.copyWith(
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                  color: selected
                      ? scheme.onSecondaryContainer
                      : scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ColorChip extends StatelessWidget {
  const _ColorChip({
    required this.color,
    required this.selected,
    required this.onTap,
  });

  final Color color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      selected: selected,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 8),
          child: AnimatedContainer(
            duration: ShqMotion.instant,
            width: 20,
            height: 20,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
              border: Border.all(
                color: selected ? scheme.primary : scheme.outlineVariant,
                width: selected ? 2.5 : 1,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ToolbarDivider extends StatelessWidget {
  const _ToolbarDivider({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 1,
      height: 20,
      margin: const EdgeInsets.symmetric(horizontal: ShqSpace.sm),
      color: color,
    );
  }
}

/// 底部：上一题 / 进度 / 纸张切换 / 下一题（最后一题为「完成」）。
class _RedoBottomBar extends StatelessWidget {
  const _RedoBottomBar({
    required this.index,
    required this.total,
    required this.paperIndex,
    required this.paperPages,
    required this.onPrev,
    required this.onNext,
    required this.onPrevPaper,
    required this.onNextPaper,
    required this.onFinish,
  });

  final int index;
  final int total;
  final int paperIndex;
  final int paperPages;
  final VoidCallback? onPrev;
  final VoidCallback? onNext;
  final VoidCallback? onPrevPaper;
  final VoidCallback? onNextPaper;
  final VoidCallback onFinish;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    return Container(
      height: 54,
      padding: const EdgeInsets.symmetric(horizontal: ShqSpace.md),
      decoration: BoxDecoration(
        color: scheme.surface,
        border: Border(top: BorderSide(color: scheme.outlineVariant)),
      ),
      child: Row(
        children: <Widget>[
          IconButton(
            tooltip: '上一题',
            onPressed: onPrev,
            icon: const Icon(Icons.chevron_left),
          ),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                Text(
                  redoProgressLabel(index: index, total: total),
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 3),
                ClipRRect(
                  borderRadius: BorderRadius.circular(ShqRadius.pill),
                  child: LinearProgressIndicator(
                    value: total <= 0 ? 0 : (index + 1) / total,
                    minHeight: 3,
                    backgroundColor: scheme.surfaceContainerHighest,
                  ),
                ),
              ],
            ),
          ),
          if (paperPages > 1) ...<Widget>[
            IconButton(
              tooltip: '上一张纸',
              onPressed: onPrevPaper,
              visualDensity: VisualDensity.compact,
              constraints: const BoxConstraints.tightFor(width: 32, height: 34),
              icon: const Icon(Icons.chevron_left, size: 18),
            ),
            Text(
              '纸 ${paperIndex + 1}/$paperPages',
              style: theme.textTheme.labelSmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            IconButton(
              tooltip: '下一张纸',
              onPressed: onNextPaper,
              visualDensity: VisualDensity.compact,
              constraints: const BoxConstraints.tightFor(width: 32, height: 34),
              icon: const Icon(Icons.chevron_right, size: 18),
            ),
            const SizedBox(width: ShqSpace.sm),
          ],
          if (onNext != null)
            IconButton(
              tooltip: '下一题',
              onPressed: onNext,
              icon: const Icon(Icons.chevron_right),
            )
          else
            Padding(
              padding: const EdgeInsets.only(left: ShqSpace.sm),
              child: FilledButton.icon(
                onPressed: onFinish,
                icon: const Icon(Icons.check, size: 18),
                label: const Text('完成'),
              ),
            ),
        ],
      ),
    );
  }
}
