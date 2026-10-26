import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shuaqi/infra/pdf/pdfrx_source.dart';
import 'package:shuaqi/infra/vault/paths.dart';
import 'package:shuaqi/state/app_providers.dart';

/// 书架缩略图的"缺图重建"（2026-10-26 用户第 3 条）。
///
/// ## 为什么需要它
/// 缩略图只在导入时生成；清缓存会删掉 `workbooks/<id>/thumb/`，
/// 从"清缓存之后导出的备份"恢复时也可能没有缩略图。
/// 没有重建的话，书架就整排占位图标（068 真机截图 26 复现）。
///
/// ## 设计
/// - 有图：直接读字节 → `Image.memory`（不依赖 FileImage 的路径缓存）；
/// - 缺图：用 pdfrx 渲染第 0 页缩略图，原子写回 `thumb/`；
/// - **串行队列**：5 张卡同时缺图时不要同时开 5 个 PDF；
/// - 失败缓存为 null，避免每次 rebuild 都重试；清缓存/恢复后 bump 版本重试。
final NotifierProvider<ThumbnailEpoch, int> thumbnailEpochProvider =
    NotifierProvider<ThumbnailEpoch, int>(ThumbnailEpoch.new);

class ThumbnailEpoch extends Notifier<int> {
  @override
  int build() => 0;

  /// 清缓存 / 恢复备份 / 导入后调用：所有书架卡重新取图。
  void bump() => state = state + 1;
}

final FutureProvider<Uint8List?> Function(String) workbookThumbnailProvider =
    FutureProvider.family<Uint8List?, String>((Ref ref, String workbookId) async {
      ref.watch(thumbnailEpochProvider);
      final vault = ref.watch(vaultProvider);
      final thumb = vault.file(VaultPaths.thumb(workbookId, 0));
      if (thumb.existsSync() && thumb.lengthSync() > 0) {
        try {
          return await thumb.readAsBytes();
        } on Object {
          // 读失败就当缺图，下面重建。
        }
      }

      final workbook = await ref.watch(workbookDaoProvider).byId(workbookId);
      if (workbook == null) {
        return null;
      }
      final source = vault.file(workbook.sourcePath);
      if (!source.existsSync()) {
        return null; // 文件缺失：由书架"健康态"提示，不在 build 里反复重试。
      }

      try {
        final Uint8List bytes = await _thumbQueue.run(() async {
          final PdfrxSource pdf = await PdfrxSource.openFile(source.path);
          try {
            return await pdf.renderThumb(0, widthPx: 240);
          } finally {
            await pdf.dispose();
          }
        });
        if (bytes.isEmpty) {
          return null;
        }
        await vault.writeAtomically(VaultPaths.thumb(workbookId, 0), bytes);
        return bytes;
      } on Object {
        return null;
      }
    });

/// 串行缩略图重建：同一时刻只开一个 PDF。
final _ThumbQueue _thumbQueue = _ThumbQueue();

class _ThumbQueue {
  Future<void> _tail = Future<void>.value();

  Future<T> run<T>(Future<T> Function() task) {
    final Completer<T> completer = Completer<T>();
    _tail = _tail.then((_) async {
      try {
        completer.complete(await task());
      } on Object catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }
}
