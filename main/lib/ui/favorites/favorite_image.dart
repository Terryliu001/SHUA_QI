import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:shuaqi/ui/theme/tokens.dart';
import 'package:shuaqi/ui/widgets/image_viewer.dart';

/// 收藏快照图片（题面/作答）的加载与展示（T8.3b 抽出来共用）。
///
/// 为什么不用 `Image.file`：
/// 1. **清晰度**：`Image.file` 解码后按显示尺寸缩放，但外部按需重渲染
///    （`FavoriteStemService`）会**覆盖同一个文件**，`FileImage` 的缓存会继续
///    显示旧图。用内存字节 + `gaplessPlayback`，重渲染完换一份字节即可立即清晰。
/// 2. **能拿到真实宽高**：全屏查看器要求按图片真实比例算尺寸（不能拉伸），
///    顺便给了「点开放大」的可用性。
class FavoriteImage {
  const FavoriteImage({
    required this.bytes,
    required this.width,
    required this.height,
  });

  final Uint8List bytes;
  final int width;
  final int height;

  /// 宽高比（宽/高），非法时为 1。
  double get aspectRatio =>
      width > 0 && height > 0 ? width / height : 1.0;

  Size get size => Size(width.toDouble(), height.toDouble());
}

/// 读一张收藏快照图并解码尺寸；不存在/损坏返回 null。
Future<FavoriteImage?> loadFavoriteImage(File file) async {
  if (!file.existsSync()) {
    return null;
  }
  try {
    final Uint8List bytes = await file.readAsBytes();
    if (bytes.isEmpty) {
      return null;
    }
    final ui.Codec codec = await ui.instantiateImageCodec(bytes);
    final ui.FrameInfo frame = await codec.getNextFrame();
    final ui.Image image = frame.image;
    final FavoriteImage out = FavoriteImage(
      bytes: bytes,
      width: image.width,
      height: image.height,
    );
    image.dispose();
    codec.dispose();
    return out;
  } on Object {
    return null;
  }
}

/// 把收藏快照图解码成 [FavoriteImage]（新的字节，用于替换旧图）。
Future<FavoriteImage?> decodeFavoriteImage(Uint8List bytes) async {
  if (bytes.isEmpty) {
    return null;
  }
  try {
    final ui.Codec codec = await ui.instantiateImageCodec(bytes);
    final ui.FrameInfo frame = await codec.getNextFrame();
    final ui.Image image = frame.image;
    final FavoriteImage out = FavoriteImage(
      bytes: bytes,
      width: image.width,
      height: image.height,
    );
    image.dispose();
    codec.dispose();
    return out;
  } on Object {
    return null;
  }
}

/// 全屏看大图（双指缩放看细节，点一下关掉）。
Future<void> showFavoriteImage(
  BuildContext context, {
  required String title,
  required FavoriteImage image,
}) {
  return showImageViewer(
    context,
    title: title,
    aspectRatio: image.aspectRatio,
    builder: (BuildContext context, Size size) => Image.memory(
      image.bytes,
      width: size.width,
      height: size.height,
      fit: BoxFit.contain,
      filterQuality: FilterQuality.medium,
      gaplessPlayback: true,
    ),
  );
}

/// 快照图面板：纸色底 + `contain` 完整呈现 + 点击全屏放大。
///
/// [maxHeight] 为 null 时不额外限高（由外层滚动容器裁）；给了高度就在其中居中。
class FavoriteImageView extends StatelessWidget {
  const FavoriteImageView({
    super.key,
    required this.image,
    required this.title,
    this.emptyHint = '暂无图片',
    this.maxHeight,
    this.maxWidth,
    this.onTap,
  });

  final FavoriteImage? image;
  final String title;
  final String emptyHint;
  final double? maxHeight;

  /// 最大显示宽度（null = 铺满可用宽）。宽图（如 5:3 的空白作答纸）用它
  /// 限制成"一张纸"而不是一条横带，两侧透出页面底色。
  final double? maxWidth;

  /// 自定义点击行为（默认全屏看大图）。
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final FavoriteImage? shown = image;
    if (shown == null) {
      return Container(
        width: double.infinity,
        height: 120,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(ShqRadius.md),
        ),
        child: Text(
          emptyHint,
          textAlign: TextAlign.center,
          style: Theme.of(
            context,
          ).textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
        ),
      );
    }
    final double? cap = maxHeight;
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints c) {
        final double available = c.maxWidth.isFinite
            ? c.maxWidth
            : MediaQuery.sizeOf(context).width;
        final double width = maxWidth == null
            ? available
            : math.min(available, maxWidth!);
        final double natural = width / shown.aspectRatio;
        final double height = cap == null ? natural : math.min(natural, cap);
        // 限高时按比例收窄并居中，左右用纸色填充——
        // 用户口径是"完整呈现，比例不对就填充同颜色背景"。
        final double drawWidth = height * shown.aspectRatio;
        return Align(
          alignment: Alignment.center,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(ShqRadius.md),
            child: SizedBox(
              width: width,
              height: height,
              child: ColoredBox(
                color: ShqPaper.base,
                child: Stack(
                  children: <Widget>[
                    Positioned.fill(
                      child: Center(
                        child: SizedBox(
                          width: drawWidth,
                          height: height,
                          child: Image.memory(
                            shown.bytes,
                            fit: BoxFit.contain,
                            filterQuality: FilterQuality.medium,
                            gaplessPlayback: true,
                            errorBuilder:
                                (
                                  BuildContext context,
                                  Object error,
                                  StackTrace? stackTrace,
                                ) => Center(
                                  child: Text(
                                    emptyHint,
                                    style: Theme.of(context)
                                        .textTheme
                                        .bodyMedium
                                        ?.copyWith(
                                          color: scheme.onSurfaceVariant,
                                        ),
                                  ),
                                ),
                          ),
                        ),
                      ),
                    ),
                    Positioned(
                      right: ShqSpace.sm,
                      bottom: ShqSpace.sm,
                      child: IgnorePointer(
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: ShqSpace.sm,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.42),
                            borderRadius: BorderRadius.circular(ShqRadius.pill),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: <Widget>[
                              const Icon(
                                Icons.zoom_out_map,
                                size: 13,
                                color: Colors.white,
                              ),
                              const SizedBox(width: 4),
                              Text(
                                '点开放大',
                                style: Theme.of(context).textTheme.labelSmall
                                    ?.copyWith(
                                      color: Colors.white,
                                      fontSize: 10.5,
                                    ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    // 整块可点：别让用户去猜"只能点图片中间"。
                    Positioned.fill(
                      child: Material(
                        color: Colors.transparent,
                        child: InkWell(
                          onTap:
                              onTap ??
                              () => showFavoriteImage(
                                context,
                                title: title,
                                image: shown,
                              ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
