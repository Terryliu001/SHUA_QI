import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shuaqi/domain/reader/reader_prefs.dart';
import 'package:shuaqi/state/reader_providers.dart';
import 'package:shuaqi/ui/reader/page_image_cache.dart';
import 'package:shuaqi/ui/reader/paged_view.dart';
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
  ViewMode _mode = ViewMode.paged;
  int _current = 0;

  /// 滚动模式的档位缩放（分页模式用双指捏合，不使用它）
  double _scrollZoom = 1;

  /// 切模式时的落点。null 表示还没定（首帧从会话进度恢复）。
  int? _initialPage;
  Timer? _progress;

  @override
  void dispose() {
    _progress?.cancel();
    _cache?.dispose();
    super.dispose();
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
    setState(() {
      _initialPage = _current;
      _mode = _mode == ViewMode.paged ? ViewMode.scroll : ViewMode.paged;
    });
  }

  void _jumpTo(int index) {
    _onPageChanged(index);
    if (_mode == ViewMode.paged) {
      _pagedKey.currentState?.jumpTo(index);
    } else {
      _scrollKey.currentState?.jumpTo(index);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
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

    return Scaffold(
      key: _scaffoldKey,
      appBar: AppBar(
        title: Text(
          ready?.workbook.title ?? '阅读器',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: <Widget>[
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
              onSelected: (double value) => setState(() {
                _scrollZoom = value;
              }),
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
      body: _buildBody(theme, async, ready),
    );
  }

  Widget _buildBody(
    ThemeData theme,
    AsyncValue<ReaderHandle> async,
    ReaderHandle? ready,
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
    return Column(
      children: <Widget>[
        Expanded(
          child: _mode == ViewMode.paged
              ? PagedReaderView(
                  key: _pagedKey,
                  pages: ready.pages,
                  cache: _cache!,
                  initialPage: initial,
                  onPageChanged: _onPageChanged,
                )
              : ScrollReaderView(
                  key: _scrollKey,
                  pages: ready.pages,
                  cache: _cache!,
                  initialPage: initial,
                  onPageChanged: _onPageChanged,
                  zoom: _scrollZoom,
                  // 双指缩放改了倍率后，把 AppBar 的百分比同步过来
                  onZoomChanged: (double value) => setState(() {
                    _scrollZoom = value;
                  }),
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
