import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shuaqi/domain/model/wb_page.dart';
import 'package:shuaqi/infra/pdf/pdf_source.dart';
import 'package:shuaqi/ui/reader/page_image_cache.dart';
import 'package:shuaqi/ui/reader/page_layer.dart';

/// PageLayer 的"取不到图"路径：**不能永远转圈**，要给出可点按的重试，
/// 且重试成功后必须真的把图画出来（2026-10-23 "翻了页只刷新不显示"的兜底）。
void main() {
  testWidgets('渲染失败 → 显示重试入口；点重试成功后恢复显示', (WidgetTester tester) async {
    final _FlakySource source = _FlakySource(failures: 2);
    final PageImageCache cache = PageImageCache(source: source);
    addTearDown(cache.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: PageLayer(
              cache: cache,
              page: const WbPage(
                id: 'p0',
                workbookId: 'w0',
                index: 0,
                width: 600,
                height: 800,
              ),
              width: 300,
              qualityWidth: 200,
            ),
          ),
        ),
      ),
    );

    // 第一次失败（5ms）→ 自动重试（450ms）→ 第二次失败 → 进入可重试态。
    // 时间线：pump 推进时钟后才处理上一段 await，所以重试定时器落在下一次 pump 里。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();
    expect(find.text('这一页没显示出来'), findsOneWidget);

    // 第三次（用户点重试）成功
    await tester.tap(find.text('重试'));
    await tester.pump();
    await tester.pump();
    expect(find.byType(RawImage), findsOneWidget);
    expect(find.text('这一页没显示出来'), findsNothing);
  });
}

class _FlakySource implements PageBitmapSource {
  _FlakySource({required this.failures});

  /// 前 N 次渲染返回 null（模拟瞬时失败）。
  int failures;

  @override
  int get pageCount => 4;

  @override
  Future<ui.Image?> renderUiImage(int index, {required int widthPx}) async {
    if (failures > 0) {
      failures--;
      await Future<void>.delayed(const Duration(milliseconds: 5));
      return null;
    }
    final ui.PictureRecorder recorder = ui.PictureRecorder();
    final Canvas canvas = Canvas(recorder);
    canvas.drawRect(
      Rect.fromLTWH(0, 0, widthPx.toDouble(), 260),
      Paint()..color = const Color(0xFFFFFFFF),
    );
    final ui.Picture picture = recorder.endRecording();
    final ui.Image image = await picture.toImage(widthPx, 260);
    picture.dispose();
    return image;
  }
}
