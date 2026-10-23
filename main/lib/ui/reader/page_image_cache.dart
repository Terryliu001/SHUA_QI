import 'dart:collection';
import 'dart:ui' as ui;

import 'package:shuaqi/infra/pdf/pdfrx_source.dart';

/// 页位图缓存：存 `ui.Image`，按**字节数**做 LRU 淘汰。
///
/// 为什么不用 PNG、也不按"页数"定容量（T0.4 实测结论）：
/// - pdfium 渲染一页只要 3–12ms，但编成 PNG 要 120ms。屏显根本不需要 PNG。
/// - 一页 A4 在 fit-width（约 1500px 宽）下是 1500×2100×4 ≈ 12MB；
///   400% 时同理是 6000×8400×4 ≈ 200MB。所以"缓存 6 页"在 1x 时合理、在 4x 时直接 OOM。
///   按字节淘汰能同时照顾两种情形：1x 缓 16 页，4x 自动只剩 1 页。
///
/// 交付约定（很重要）：[obtain] 返回的是 **clone**，调用方负责 `dispose()`。
/// 这样即使原图被淘汰释放，正在显示的 widget 手里的那份仍然有效。
class PageImageCache {
  PageImageCache({required this.source, this.maxBytes = 320 * 1024 * 1024});

  final PdfrxSource source;

  /// 缓存上限（字节）。
  ///
  /// 200MB → 320MB（2026-10-23 实测调整）：这一代平板一页 A4 在 3000px 宽下是
  /// 51MB，"视口 2 页 + 预热 1 页 + 刚离开还没丢的 1 页"正好 204MB —— 卡在 200MB
  /// 上限上就是**每一帧都在淘汰与上传纹理**，HUD 抓到单帧 30ms 的顿挫。
  /// 320MB 能把常用工作集（约 5–6 页）完整装下，整机峰值仍远低于 600MB 预算。
  final int maxBytes;

  final LinkedHashMap<String, _CachedImage> _entries =
      LinkedHashMap<String, _CachedImage>();
  final Map<String, Future<ui.Image?>> _inflight = <String, Future<ui.Image?>>{};

  int _bytes = 0;

  /// 运动期间**暂停淘汰**（2026-10-23 加）。
  ///
  /// 为什么：一页 A4 在 3000px 宽下是 51MB，200MB 缓存只装得下 3–4 页。
  /// 滑动时新页不断进来，边进边淘汰 → 每一页都要 `dispose()` 旧的纹理 +
  /// 上传新的 51MB 纹理，实测出现单帧 30ms 的顿挫（HUD 数据见日志 025）。
  /// 运动期间不淘汰，等停手再一次性 trim：中间多占几十 MB，
  /// 换来的是一整段滑动里零纹理churn。
  bool deferEviction = false;

  int get usedBytes => _bytes;

  int get length => _entries.length;

  /// 取一页在指定像素宽度下的位图。**返回 clone，调用方负责 dispose。**
  ///
  /// `widthPx` 用像素而不是比例：调用方本来就按 devicePixelRatio 算过，
  /// 缓存键直接用它，避免浮点误差导致同一页反复渲染。
  Future<ui.Image?> obtain(int pageIndex, int widthPx) {
    final String key = _keyOf(pageIndex, widthPx);
    final _CachedImage? hit = _entries.remove(key);
    if (hit != null) {
      // 命中：移到队尾（最近使用）
      _entries[key] = hit;
      return Future<ui.Image?>.value(hit.image.clone());
    }
    // 单飞：同一页同一宽度并发请求只渲染一次
    return _inflight.putIfAbsent(key, () async {
      try {
        final ui.Image? image = await _render(pageIndex, widthPx);
        if (image == null) {
          return null;
        }
        _store(key, image);
        return image.clone();
      } finally {
        _inflight.remove(key)?.ignore();
      }
    });
  }

  Future<ui.Image?> _render(int pageIndex, int widthPx) async {
    if (pageIndex < 0 || pageIndex >= source.pageCount) {
      return null;
    }
    final ui.Image? image = await source.renderUiImage(pageIndex, widthPx: widthPx);
    return image;
  }

  void _store(String key, ui.Image image) {
    final int size = image.width * image.height * 4;
    _entries[key] = _CachedImage(image, size);
    _bytes += size;
    _evictIfNeeded();
  }

  void _evictIfNeeded() {
    if (deferEviction) {
      // 运动期间先攒着，停手后由 [trim] 统一收敛。
      return;
    }
    _trim();
  }

  /// 立刻按上限收敛（停手 / 落笔 / 退出时调用）。
  void trim() {
    _trim();
  }

  void _trim() {
    // 至少保留 1 份，否则"正在看的那页"会被自己挤掉
    while (_bytes > maxBytes && _entries.length > 1) {
      final String oldestKey = _entries.keys.first;
      final _CachedImage? dropped = _entries.remove(oldestKey);
      if (dropped == null) {
        continue;
      }
      _bytes -= dropped.bytes;
      dropped.image.dispose();
    }
  }

  /// 预渲染一页并放进缓存，**不返回 clone**（调用方不需要图，只是加热缓存）。
  ///
  /// 这是"翻页丝滑"的关键：不预热的话，翻到新一页才渲染 → 12ms 渲染 + 解码 + 首帧，
  /// 每次翻页都会有一下顿挫。翻当前页时就顺手把前后页烘好，翻过去直接命中。
  void prefetch(int pageIndex, int widthPx) {
    final String key = _keyOf(pageIndex, widthPx);
    if (_entries.containsKey(key) || _inflight.containsKey(key)) {
      return;
    }
    final Future<ui.Image?> task = _inflight.putIfAbsent(key, () async {
      try {
        final ui.Image? image = await _render(pageIndex, widthPx);
        if (image == null) {
          return null;
        }
        _store(key, image);
        return image;
      } finally {
        _inflight.remove(key)?.ignore();
      }
    });
    // 预热失败不影响使用，只是下次还要现渲染
    task.ignore();
  }

  /// 清空并释放。页面退出时调用。
  void dispose() {
    for (final _CachedImage entry in _entries.values) {
      entry.image.dispose();
    }
    _entries.clear();
    _bytes = 0;
  }

  static String _keyOf(int pageIndex, int widthPx) => '$pageIndex@$widthPx';
}

class _CachedImage {
  const _CachedImage(this.image, this.bytes);

  final ui.Image image;
  final int bytes;
}
