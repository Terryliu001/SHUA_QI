import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shuaqi/infra/pdf/pdf_source.dart';
import 'package:shuaqi/ui/reader/page_image_cache.dart';

/// 页位图缓存的**交付契约**：`obtain` 返回的每一份句柄互相独立，
/// 调用方 `dispose()` 自己的那份，绝不影响缓存里的原图或其他调用方。
///
/// 这条契约在 2026-10-23 被打破过：预热的 `_inflight` future 与 `obtain`
/// 共享同一个 `ui.Image` 实例（预热路径返回的是缓存原图、不是 clone）。
/// PageLayer 离开可见集时 dispose 掉它 → 缓存里留下一张**已销毁的图** →
/// 再翻回来时"页面刷新了却永远显示不出来"。下面两组用例就是那个事故的定点回归。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('预热与取图重叠时，调用方 dispose 不影响缓存里的原图', () async {
    final _FakeBitmapSource source = _FakeBitmapSource(
      delay: const Duration(milliseconds: 30),
    );
    final PageImageCache cache = PageImageCache(source: source);
    addTearDown(cache.dispose);

    // 1) 滚动时先预热下一页（模拟 build 里的 _maybePrefetch）。
    cache.prefetch(3, 240);
    // 2) 30ms 内用户翻到了这一页：obtain 会加入同一个在途 future。
    final ui.Image? borrowed = await cache.obtain(3, 240);
    expect(borrowed, isNotNull);

    // 3) 这一页离开可见集，PageLayer 释放自己那份。
    borrowed!.dispose();

    // 4) 再翻回来：缓存必须还能给出一张可绘制的图。
    final ui.Image? again = await cache.obtain(3, 240);
    expect(again, isNotNull);
    expect(
      await _bytesOf(again!),
      isNotEmpty,
      reason: '第二次取到的图必须还能绘制（缓存里的原图没被调用方销毁）',
    );
    again.dispose();
  });

  test('并发 obtain 各自拿到独立句柄，销毁一份不影响另一份', () async {
    final _FakeBitmapSource source = _FakeBitmapSource(
      delay: const Duration(milliseconds: 30),
    );
    final PageImageCache cache = PageImageCache(source: source);
    addTearDown(cache.dispose);

    // 同一页同一宽度并发请求（PageLayer 重建 / 缩略图与正文同时要图）。
    final Future<ui.Image?> a = cache.obtain(1, 200);
    final Future<ui.Image?> b = cache.obtain(1, 200);
    final List<ui.Image?> images = await Future.wait(<Future<ui.Image?>>[a, b]);
    expect(images[0], isNotNull);
    expect(images[1], isNotNull);
    expect(
      identical(images[0], images[1]),
      isFalse,
      reason: '两个调用方不能共享同一个 ui.Image 实例（否则一方 dispose 会毁掉另一方）',
    );

    images[0]!.dispose();
    expect(
      await _bytesOf(images[1]!),
      isNotEmpty,
      reason: '一份句柄被销毁后，另一份必须仍然可绘制',
    );
    images[1]!.dispose();
  });

  test('缓存返回的图与缓存内部原图是不同句柄（不能 dispose 到缓存头上）', () async {
    final _FakeBitmapSource source = _FakeBitmapSource();
    final PageImageCache cache = PageImageCache(source: source);
    addTearDown(cache.dispose);

    final ui.Image? first = await cache.obtain(0, 120);
    expect(first, isNotNull);
    first!.dispose();

    final ui.Image? second = await cache.obtain(0, 120);
    expect(second, isNotNull);
    expect(await _bytesOf(second!), isNotEmpty);
    second.dispose();

    // 命中缓存不该再渲染（同一页同一宽度只渲染一次）。
    expect(source.renderCount, 1);
  });
}

Future<Uint8List> _bytesOf(ui.Image image) async {
  final ByteData? data = await image.toByteData(
    format: ui.ImageByteFormat.rawRgba,
  );
  return data?.buffer.asUint8List() ?? Uint8List(0);
}

class _FakeBitmapSource implements PageBitmapSource {
  _FakeBitmapSource({this.delay = Duration.zero});

  final Duration delay;
  int renderCount = 0;

  @override
  int get pageCount => 16;

  @override
  Future<ui.Image?> renderUiImage(int index, {required int widthPx}) async {
    renderCount++;
    if (delay > Duration.zero) {
      await Future<void>.delayed(delay);
    }
    final ui.PictureRecorder recorder = ui.PictureRecorder();
    final Canvas canvas = Canvas(recorder);
    canvas.drawRect(
      Rect.fromLTWH(0, 0, widthPx.toDouble(), 160),
      Paint()..color = const Color(0xFFF2F2F2),
    );
    final ui.Picture picture = recorder.endRecording();
    final ui.Image image = await picture.toImage(widthPx, 160);
    picture.dispose();
    return image;
  }
}
