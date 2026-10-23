import 'dart:collection';
import 'dart:ui' as ui;

import 'package:shuaqi/infra/pdf/pdf_source.dart';

/// 页位图缓存：存 `ui.Image`，按**字节数**做 LRU 淘汰。
///
/// 为什么不用 PNG、也不按"页数"定容量（T0.4 实测结论）：
/// - pdfium 渲染一页只要 3–12ms，但编成 PNG 要 120ms。屏显根本不需要 PNG。
/// - 一页 A4 在 fit-width（约 1500px 宽）下是 1500×2100×4 ≈ 12MB；
///   400% 时同理是 6000×8400×4 ≈ 200MB。所以"缓存 6 页"在 1x 时合理、在 4x 时直接 OOM。
///   按字节淘汰能同时照顾两种情形：1x 缓 16 页，4x 自动只剩 1 页。
///
/// ## 交付契约（2026-10-23 修，**不能再破坏**）
///
/// [obtain] 返回的**每一份**都是独立句柄（`clone`），调用方负责 `dispose()`：
/// - 缓存自己始终持有原图；
/// - 调用方销毁自己的句柄，不会影响缓存、也不会影响别的调用方；
/// - 预热（[prefetch]）与取图（[obtain]）撞在同一个在途请求上时，
///   两者**绝不能拿到同一个 `ui.Image` 实例**。
///
/// 为什么这条契约是红线：旧实现里 `prefetch` 把缓存原图直接作为在途 future
/// 的结果返回，`obtain` 撞上时拿到的就是原图本身。PageLayer 离开可见集时
/// `dispose()` 了它 → 缓存里留下**一张已销毁的图** → 再翻回来时
/// "页面刷新了却一直显示不出来"（真机症状）。回归测试：`test/page_image_cache_test.dart`。
class PageImageCache {
  PageImageCache({required this.source, this.maxBytes = 320 * 1024 * 1024});

  final PageBitmapSource source;

  /// 缓存上限（字节）。
  ///
  /// 200MB → 320MB（2026-10-23 实测调整）：这一代平板一页 A4 在 3000px 宽下是
  /// 51MB，"视口 2 页 + 预热 1 页 + 刚离开还没丢的 1 页"正好 204MB —— 卡在 200MB
  /// 上限上就是**每一帧都在淘汰与上传纹理**，HUD 抓到单帧 30ms 的顿挫。
  /// 320MB 能把常用工作集（约 5–6 页）完整装下，整机峰值仍远低于 600MB 预算。
  final int maxBytes;

  final LinkedHashMap<String, _CachedImage> _entries =
      LinkedHashMap<String, _CachedImage>();

  /// 在途渲染：值为**缓存原图**（不是给调用方的句柄）。所有调用方等到后各自 clone。
  final Map<String, Future<ui.Image?>> _inflight =
      <String, Future<ui.Image?>>{};

  int _bytes = 0;
  bool _disposed = false;

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

  /// 取一页在指定像素宽度下的位图。**返回独立 clone，调用方负责 dispose。**
  ///
  /// `widthPx` 用像素而不是比例：调用方本来就按 devicePixelRatio 算过，
  /// 缓存键直接用它，避免浮点误差导致同一页反复渲染。
  Future<ui.Image?> obtain(int pageIndex, int widthPx) =>
      _obtain(pageIndex, widthPx, retried: false);

  Future<ui.Image?> _obtain(
    int pageIndex,
    int widthPx, {
    required bool retried,
  }) async {
    if (_disposed) {
      return null;
    }
    final String key = _keyOf(pageIndex, widthPx);

    // 命中：移到队尾（最近使用），并给出**新的句柄**。
    final _CachedImage? hit = _entries.remove(key);
    if (hit != null) {
      final ui.Image? clone = _cloneQuietly(hit.image);
      if (clone != null) {
        _entries[key] = hit;
        return clone;
      }
      // 极少见：缓存里是一张已销毁的图（旧版本遗留 / 外部误用）。
      // 丢掉它并重新渲染，保证"这一页还能显示"。
      _bytes -= hit.bytes;
      _disposeQuietly(hit.image);
    }

    // 单飞：同一页同一宽度并发请求只渲染一次。
    final Future<ui.Image?> load = _inflight.putIfAbsent(
      key,
      () => _renderAndStore(pageIndex, widthPx, key),
    );
    final ui.Image? cached = await load;
    if (_disposed || cached == null) {
      return null;
    }
    final _CachedImage? entry = _entries[key];
    if (entry == null) {
      // 在途结果刚进缓存就被别的页挤掉了（上限很小 / 同时载入很多页）。
      // 原图可能已经销毁，不能 clone；重来一次即可（不会形成长循环：
      // trim 至少保留 1 条，刚渲染的这条正常情况下就是那一条）。
      if (!retried) {
        return _obtain(pageIndex, widthPx, retried: true);
      }
      return null;
    }
    return _cloneQuietly(entry.image);
  }

  Future<ui.Image?> _renderAndStore(
    int pageIndex,
    int widthPx,
    String key,
  ) async {
    try {
      final ui.Image? image = await _render(pageIndex, widthPx);
      if (image == null) {
        return null;
      }
      if (_disposed) {
        _disposeQuietly(image);
        return null;
      }
      _store(key, image);
      return image;
    } finally {
      // 只做映射清理：结果由所有等待者各自 clone，不在这里交出句柄。
      _inflight.remove(key)?.ignore();
    }
  }

  Future<ui.Image?> _render(int pageIndex, int widthPx) async {
    if (pageIndex < 0 || pageIndex >= source.pageCount) {
      return null;
    }
    return source.renderUiImage(pageIndex, widthPx: widthPx);
  }

  void _store(String key, ui.Image image) {
    if (_disposed) {
      _disposeQuietly(image);
      return;
    }
    // 同一键重复装载（理论上单飞已避免）：旧的必须释放，否则内存只增不减。
    final _CachedImage? old = _entries.remove(key);
    if (old != null) {
      _bytes -= old.bytes;
      _disposeQuietly(old.image);
    }
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
    if (_disposed) {
      return;
    }
    // 至少保留 1 份，否则"正在看的那页"会被自己挤掉
    while (_bytes > maxBytes && _entries.length > 1) {
      final String oldestKey = _entries.keys.first;
      final _CachedImage? dropped = _entries.remove(oldestKey);
      if (dropped == null) {
        continue;
      }
      _bytes -= dropped.bytes;
      _disposeQuietly(dropped.image);
    }
  }

  /// 预渲染一页并放进缓存，**不交出任何句柄**（调用方不需要图，只是加热缓存）。
  ///
  /// 这是"翻页丝滑"的关键：不预热的话，翻到新一页才渲染 → 12ms 渲染 + 解码 + 首帧，
  /// 每次翻页都会有一下顿挫。翻当前页时就顺手把前后页烘好，翻过去直接命中。
  void prefetch(int pageIndex, int widthPx) {
    if (_disposed) {
      return;
    }
    final String key = _keyOf(pageIndex, widthPx);
    if (_entries.containsKey(key) || _inflight.containsKey(key)) {
      return;
    }
    final Future<ui.Image?> task = _inflight.putIfAbsent(
      key,
      () => _renderAndStore(pageIndex, widthPx, key),
    );
    // 预热失败不影响使用，只是下次还要现渲染
    task.ignore();
  }

  /// 清空并释放。页面退出时调用。
  void dispose() {
    if (_disposed) {
      return;
    }
    _disposed = true;
    for (final _CachedImage entry in _entries.values) {
      _disposeQuietly(entry.image);
    }
    _entries.clear();
    _inflight.clear();
    _bytes = 0;
  }

  static ui.Image? _cloneQuietly(ui.Image image) {
    try {
      return image.clone();
    } on Object {
      // 已销毁的图不能 clone —— 让调用方看到 null，走"重试/占位"路径，
      // 而不是把异常抛进 build。
      return null;
    }
  }

  static void _disposeQuietly(ui.Image image) {
    try {
      image.dispose();
    } on Object {
      // 重复 dispose / 已销毁：吞掉。清理路径不该因为一张图把整页搞崩。
    }
  }

  static String _keyOf(int pageIndex, int widthPx) => '$pageIndex@$widthPx';
}

class _CachedImage {
  const _CachedImage(this.image, this.bytes);

  final ui.Image image;
  final int bytes;
}
