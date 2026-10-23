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

class _ReaderPageState extends ConsumerState<ReaderPage>
    with WidgetsBindingObserver {
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
  double _scrollZoom = ScrollReaderView.defaultScale;

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
    WidgetsBinding.instance.addObserver(this);
    if (!kReleaseMode) {
      _frameStats = FrameStatsCollector();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // T2.4：切后台/被系统杀之前把待写页落盘。paused 已经可能来不及，
    // 所以防抖仍然是第一道保险，这里是最后一道。
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      unawaited(
        ref.read(inkWriterProvider(widget.workbookId)).flushAll(),
      );
    }
  }

  /// 立刻落一页（切页 / 切模式时调用）。
  void _flushInk(int page) {
    final session = _handle?.session;
    if (session == null) {
      return;
    }
    unawaited(
      ref
          .read(inkWriterProvider(widget.workbookId))
          .flush(session.id, page),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    // 退出阅读器前把 500ms 防抖窗口里的内容也写掉。
    unawaited(ref.read(inkWriterProvider(widget.workbookId)).flushAll());
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
          const _ActionDivider(),
          if (_mode == ViewMode.scroll && ready != null)
            _ZoomPill(
              value: _scrollZoom,
              onSelected: (double value) =>
                  _scrollKey.currentState?.setScale(value),
            ),
          IconButton(
            tooltip: '显示设置',
            onPressed: ready == null ? null : _openDisplaySheet,
            icon: const Icon(Icons.palette_outlined),
          ),
          // 低频动作（切模式 / 缩略图）收进一个菜单：顶栏只留高频动作，
          // 也避免窄屏上六个图标把标题挤没。
          PopupMenuButton<String>(
            tooltip: '更多',
            icon: const Icon(Icons.more_horiz),
            onSelected: (String value) {
              switch (value) {
                case 'mode':
                  _switchMode();
                  break;
                case 'thumbnails':
                  _scaffoldKey.currentState?.openEndDrawer();
                  break;
              }
            },
            itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
              PopupMenuItem<String>(
                value: 'mode',
                enabled: ready != null,
                child: _MenuItem(
                  icon: _mode == ViewMode.paged
                      ? Icons.view_day_outlined
                      : Icons.auto_stories_outlined,
                  label: _mode == ViewMode.paged ? '切换到连续滚动' : '切换到分页',
                ),
              ),
              const PopupMenuDivider(),
              PopupMenuItem<String>(
                value: 'thumbnails',
                enabled: _cache != null,
                child: const _MenuItem(
                  icon: Icons.grid_view_outlined,
                  label: '缩略图',
                ),
              ),
            ],
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
                        inkbrushWidth: brush.brushWidth,
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

/// 顶栏里的分组细线：把"文档动作（撤销/重做）"与"视图动作"分开。
class _ActionDivider extends StatelessWidget {
  const _ActionDivider();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: ShqSpace.xs),
      child: Center(
        child: Container(
          width: 1,
          height: 22,
          color: Theme.of(context).colorScheme.outlineVariant,
        ),
      ),
    );
  }
}

/// 连续滚动模式的缩放胶囊：**当前倍率本身就是按钮**。
///
/// 之前是"图标 + 文字"直接塞在 actions 里，宽度大、和图标不成一组。
/// 现在做成一颗有底色的胶囊，倍率一眼可见，点开是档位菜单。
class _ZoomPill extends StatelessWidget {
  const _ZoomPill({required this.value, required this.onSelected});

  final double value;
  final ValueChanged<double> onSelected;

  static const List<double> _steps = <double>[0.6, 0.86, 1, 1.5, 2, 3];

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    // 窄屏（手机竖屏）只露图标：4 个顶栏动作 + 百分比会把标题挤没。
    final bool compact = MediaQuery.sizeOf(context).width < 600;
    return PopupMenuButton<double>(
      tooltip: '缩放 ${(value * 100).round()}%',
      initialValue: value,
      onSelected: onSelected,
      itemBuilder: (BuildContext context) => <PopupMenuEntry<double>>[
        for (final double zoom in _steps)
          PopupMenuItem<double>(
            value: zoom,
            child: Row(
              children: <Widget>[
                SizedBox(
                  width: 22,
                  child: (zoom - value).abs() < 0.01
                      ? Icon(Icons.check, size: 16, color: scheme.primary)
                      : null,
                ),
                Text('${(zoom * 100).round()}%'),
              ],
            ),
          ),
      ],
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: ShqSpace.xxs),
        padding: const EdgeInsets.symmetric(
          horizontal: ShqSpace.sm,
          vertical: 5,
        ),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(ShqRadius.pill),
          border: Border.all(color: scheme.outlineVariant),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.zoom_in, size: 15, color: scheme.onSurfaceVariant),
            if (!compact) ...<Widget>[
              const SizedBox(width: 4),
              Text(
                '${(value * 100).round()}%',
                style: theme.textTheme.labelMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _MenuItem extends StatelessWidget {
  const _MenuItem({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Row(
      children: <Widget>[
        Icon(icon, size: 19, color: scheme.onSurfaceVariant),
        const SizedBox(width: ShqSpace.md),
        Text(label),
      ],
    );
  }
}
