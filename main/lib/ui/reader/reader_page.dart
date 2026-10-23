import 'dart:async';

import 'package:flutter/foundation.dart' show kReleaseMode;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shuaqi/app/reader/reader_prefs_store.dart';
import 'package:shuaqi/domain/ink/ink_brush.dart';
import 'package:shuaqi/domain/reader/reader_prefs.dart';
import 'package:shuaqi/state/ink_providers.dart';
import 'package:shuaqi/state/ink_tool_provider.dart';
import 'package:shuaqi/state/reader_prefs_providers.dart';
import 'package:shuaqi/state/reader_providers.dart';
import 'package:shuaqi/ui/reader/debug_hud.dart';
import 'package:shuaqi/ui/reader/ink_toolbar.dart';
import 'package:shuaqi/ui/reader/page_image_cache.dart';
import 'package:shuaqi/ui/reader/paged_view.dart';
import 'package:shuaqi/ui/reader/paper_style_sheet.dart';
import 'package:shuaqi/ui/reader/scroll_view.dart';
import 'package:shuaqi/ui/reader/thumb_drawer.dart';
import 'package:shuaqi/ui/theme/tokens.dart';

/// 阅读器（T1.5）：**只读**的 PDF 视图，双模式 + 缩放 + 翻页 + 记进度。
///
/// 第 2 周的墨迹层会叠在 `PageLayer` 上，这一版刻意不碰笔。
class ReaderPage extends ConsumerStatefulWidget {
  const ReaderPage({super.key, required this.workbookId});

  final String workbookId;

  @override
  ConsumerState<ReaderPage> createState() => _ReaderPageState();
}

class _ReaderPageState extends ConsumerState<ReaderPage> {
  static const List<double> _scrollZoomSteps = <double>[1, 1.25, 1.5, 2];

  final GlobalKey<PagedReaderViewState> _pagedKey =
      GlobalKey<PagedReaderViewState>();
  final GlobalKey<ScrollReaderViewState> _scrollKey =
      GlobalKey<ScrollReaderViewState>();
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

  PageImageCache? _cache;
  ReaderHandle? _handle;
  int _current = 0;

  /// 阅读偏好（mode / style / intensity）。null 表示还没从库加载完成，
  /// 期间用 [ReaderPrefs.defaults] 渲染，加载完再无缝替换。
  ReaderPrefs? _prefs;
  ReaderPrefsStore? _store;
  Timer? _prefsSaveTimer;
  bool _prefsDirty = false;

  /// 滚动模式的档位缩放（分页模式用双指捏合，不使用它）
  double _scrollZoom = 1;

  /// 切模式时的落点。null 表示还没定（首帧从会话进度恢复）。
  int? _initialPage;
  Timer? _progress;

  ViewMode get _mode => _prefs?.mode ?? ViewMode.paged;
  PaperStyle get _style => _prefs?.style ?? PaperStyle.original;
  int get _intensity => _prefs?.intensity ?? ReaderPrefs.defaultIntensity;

  /// 性能 HUD 的帧耗时采集（T2.5）。release 构建不创建，不产生任何开销。
  FrameStatsCollector? _frameStats;

  @override
  void initState() {
    super.initState();
    if (!kReleaseMode) {
      _frameStats = FrameStatsCollector();
    }
  }

  @override
  void dispose() {
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
    final ReaderPrefs next = (_prefs ?? ReaderPrefs.defaults)
        .copyWith(mode: _mode == ViewMode.paged ? ViewMode.scroll : ViewMode.paged);
    setState(() {
      _initialPage = _current;
    });
    _updatePrefs(next);
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
        _initialPage = ready.session.lastPage.clamp(
          0,
          ready.pages.length - 1,
        );
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

    // 撤销/重做看的是**当前页**的历史（滚到第 3 页撤的是第 3 页的笔）。
    final InkPageKey pageKey = InkPageKey(
      ready?.session.id ?? '',
      _current,
    );
    final bool pinnedToolbar = ref.watch(inkToolbarPinnedProvider);
    final bool canUndo = ready != null &&
        ref.watch(inkEditProvider(pageKey).select((InkEditState s) => s.canUndo));
    final bool canRedo = ready != null &&
        ref.watch(inkEditProvider(pageKey).select((InkEditState s) => s.canRedo));

    return Scaffold(
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
        actions: <Widget>[
          // 撤销/重做放在顶栏：高频动作，必须一次点击可达，不藏进工具面板。
          IconButton(
            tooltip: '撤销',
            onPressed: canUndo
                ? () => ref.read(inkEditProvider(pageKey).notifier).undo()
                : null,
            icon: const Icon(Icons.undo),
          ),
          IconButton(
            tooltip: '重做',
            onPressed: canRedo
                ? () => ref.read(inkEditProvider(pageKey).notifier).redo()
                : null,
            icon: const Icon(Icons.redo),
          ),
          IconButton(
            tooltip: _mode == ViewMode.paged ? '切换到连续滚动' : '切换到分页',
            onPressed: ready == null ? null : _switchMode,
            icon: Icon(
              _mode == ViewMode.paged
                  ? Icons.view_day_outlined
                  : Icons.auto_stories_outlined,
            ),
          ),
          if (_mode == ViewMode.scroll && ready != null)
            PopupMenuButton<double>(
              tooltip: '缩放',
              initialValue: _scrollZoom,
              // 只调 setScale，标签由 onZoomChanged 回调更新 —— 单一数据源，
              // 避免"菜单显示 200% 但画面已经是 100%"这种不同步。
              onSelected: (double value) =>
                  _scrollKey.currentState?.setScale(value),
              itemBuilder: (BuildContext context) => <PopupMenuEntry<double>>[
                for (final double zoom in _scrollZoomSteps)
                  PopupMenuItem<double>(
                    value: zoom,
                    child: Text('${(zoom * 100).round()}%'),
                  ),
              ],
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: ShqSpace.sm),
                child: Row(
                  children: <Widget>[
                    const Icon(Icons.zoom_in, size: 20),
                    Text(
                      '${(_scrollZoom * 100).round()}%',
                      style: theme.textTheme.labelLarge,
                    ),
                  ],
                ),
              ),
            ),
          IconButton(
            tooltip: '显示设置',
            onPressed: ready == null ? null : _openDisplaySheet,
            icon: const Icon(Icons.palette_outlined),
          ),
          IconButton(
            tooltip: '缩略图',
            onPressed: _cache == null
                ? null
                : () => _scaffoldKey.currentState?.openEndDrawer(),
            icon: const Icon(Icons.grid_view_outlined),
          ),
        ],
      ),
      endDrawer: (ready == null || _cache == null)
          ? null
          : ThumbDrawer(
              pages: ready.pages,
              cache: _cache!,
              currentPage: _current,
              onSelected: _jumpTo,
            ),
      body: _buildBody(theme, async, ready, brush, darkPaper),
    );
  }

  Widget _buildBody(
    ThemeData theme,
    AsyncValue<ReaderHandle> async,
    ReaderHandle? ready,
    InkBrush brush,
    bool darkPaper,
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
    return Column(
      // 必须 stretch：Column 默认 center 会把阅读视图按"自身宽度"居中，
      // 阅读视图一旦不撑满宽度，它的裁剪边界就变成内容边界（实测会裁掉右侧内容）。
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Expanded(
          child: Stack(
            children: <Widget>[
              Positioned.fill(
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
                        inkWidthLevel: brush.widthLevel,
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
                        inkWidthLevel: brush.widthLevel,
                        // 这一笔没落在纸上：给一句明确的话，别让用户干瞪眼。
                        onPenMissed: _showPenMissed,
                        // 双指缩放改了倍率后，把 AppBar 的百分比同步过来
                        onZoomChanged: (double value) => setState(() {
                          _scrollZoom = value;
                        }),
                      ),
              ),
              // 浮钮形态（默认）：收起时只有一个圆，展开才是完整笔刷面板。
              // 固定形态时工具带在 AppBar.bottom，这里就不画了。
              if (!ref.watch(inkToolbarPinnedProvider))
                Positioned(
                  right: ShqSpace.md,
                  bottom: ShqSpace.sm,
                  child: SafeArea(
                    top: false,
                    child: InkFab(darkPaper: darkPaper),
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
                        inkDocProvider(InkPageKey(sessionId, _current)),
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
