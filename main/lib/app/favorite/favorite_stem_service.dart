import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:shuaqi/domain/region/region_rect.dart';
import 'package:shuaqi/infra/pdf/pdfrx_source.dart';
import 'package:shuaqi/infra/vault/paths.dart';
import 'package:shuaqi/infra/vault/vault.dart';

/// 收藏题面图的**按需高清重渲染**（2026-10-25，用户："点开后清晰一点"）。
///
/// 背景：收藏那一刻的题面图按 1.6 倍 pt 裁切（上限 1024×1600）。平板横屏下
/// 看题页要把图铺到 ~1100dp 宽、物理 2800px，1024px 的源图必然发虚；
/// 更早迁移来的老收藏干脆没有 `stem.png`。
///
/// 这里在原卷还在时**从 source.pdf 重新裁一张高清图**，写回同一个
/// `favorites/<id>/stem.png`（路径与数据契约不变）：
/// - 现有图已经够宽（≥ [minWidth]）就什么都不做，返回 null；
/// - 原卷已删/PDF 打不开/渲染失败也只返回 null，调用方继续用旧图，不打断阅读；
/// - 覆盖写走 Vault 的原子写，半截 PNG 不会出现。
///
/// 为什么放 app 层：它要碰 pdfrx（PDF），但不需要任何 Widget；
/// 渲染用 `dart:ui` 的 PictureRecorder，和 reader 的裁图口径一致。
class FavoriteStemService {
  const FavoriteStemService({required this.vault});

  final Vault vault;

  /// 低于这个宽度就认为"看不清"，值得重渲染。
  static const int minWidth = 1400;

  /// 重渲染的输出上限（宽 × 高）。
  static const int maxWidth = 2400;
  static const int maxHeight = 3400;

  /// 每 pt 出多少像素：A4 题面宽度约 500pt → 约 1400px，平板上 1:1 清晰。
  static const double pixelPerPt = 3.2;

  /// 确保 `stem.png` 足够清晰；发生了重渲染返回新字节，否则 null。
  Future<Uint8List?> ensure({
    required String favoriteId,
    required String workbookId,
    required int pageIndex,
    required RegionRect rect,
  }) async {
    if (favoriteId.isEmpty ||
        workbookId.isEmpty ||
        pageIndex < 0 ||
        rect.isEmpty ||
        rect.width <= 0 ||
        rect.height <= 0) {
      return null;
    }
    final File stem = vault.file(VaultPaths.favoriteStem(favoriteId));
    if (stem.existsSync()) {
      try {
        final Uint8List existing = await stem.readAsBytes();
        if (pngWidthOf(existing) >= minWidth) {
          return null;
        }
      } on Object {
        // 读旧图失败：当成"需要重渲染"，继续。
      }
    }
    final File source = vault.file(VaultPaths.sourcePdf(workbookId));
    if (!source.existsSync()) {
      return null;
    }
    int outWidth = (rect.width * pixelPerPt).round().clamp(720, maxWidth);
    int outHeight = (outWidth * rect.height / rect.width).round();
    if (outHeight > maxHeight) {
      outHeight = maxHeight;
      outWidth = (outHeight * rect.width / rect.height).round().clamp(480, maxWidth);
    }
    if (outHeight < 1) {
      return null;
    }

    PdfrxSource? pdf;
    ui.Image? pageImage;
    ui.Picture? picture;
    ui.Image? outImage;
    try {
      pdf = await PdfrxSource.openFile(source.path);
      if (pageIndex >= pdf.pageCount) {
        return null;
      }
      final ui.Size pageSize = pdf.pageSize(pageIndex);
      if (pageSize.width <= 0 || pageSize.height <= 0) {
        return null;
      }
      pageImage = await pdf.renderUiImage(
        pageIndex,
        widthPx: (outWidth * 1.2).round().clamp(720, 2400),
      );
      final ui.Image? loaded = pageImage;
      if (loaded == null) {
        return null;
      }
      final ui.PictureRecorder recorder = ui.PictureRecorder();
      final ui.Canvas canvas = ui.Canvas(
        recorder,
        ui.Rect.fromLTWH(0, 0, outWidth.toDouble(), outHeight.toDouble()),
      );
      canvas.scale(outWidth / rect.width);
      canvas.translate(-rect.left, -rect.top);
      canvas.drawImageRect(
        loaded,
        ui.Rect.fromLTWH(0, 0, loaded.width.toDouble(), loaded.height.toDouble()),
        ui.Rect.fromLTWH(0, 0, pageSize.width, pageSize.height),
        ui.Paint()..filterQuality = ui.FilterQuality.high,
      );
      picture = recorder.endRecording();
      outImage = await picture.toImage(outWidth, outHeight);
      final ByteData? data = await outImage.toByteData(
        format: ui.ImageByteFormat.png,
      );
      if (data == null) {
        return null;
      }
      final Uint8List bytes = data.buffer.asUint8List();
      await vault.writeAtomically(VaultPaths.favoriteStem(favoriteId), bytes);
      return bytes;
    } on Object {
      return null;
    } finally {
      outImage?.dispose();
      picture?.dispose();
      pageImage?.dispose();
      await pdf?.dispose();
    }
  }

  /// 从 PNG 头里读宽度（IHDR 就在固定偏移，不用解码整张图）。
  ///
  /// 非 PNG / 字节不足返回 0 —— 调用方据此走"需要重渲染"。
  static int pngWidthOf(Uint8List bytes) {
    if (bytes.length < 24) {
      return 0;
    }
    const List<int> signature = <int>[137, 80, 78, 71, 13, 10, 26, 10];
    for (int i = 0; i < signature.length; i++) {
      if (bytes[i] != signature[i]) {
        return 0;
      }
    }
    return (bytes[16] << 24) |
        (bytes[17] << 16) |
        (bytes[18] << 8) |
        bytes[19];
  }
}
