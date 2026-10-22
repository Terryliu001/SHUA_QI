import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:shuaqi/domain/model/wb_page.dart';
import 'package:shuaqi/ui/reader/page_image_cache.dart';
import 'package:shuaqi/ui/theme/tokens.dart';

/// 单页图层：白纸 + 页位图。
///
/// 第 2 周的墨迹层会叠在它上面（所以这里刻意只管背景，不碰手势）。
///
/// [renderScale] 用来提高"放大后"的清晰度：显示尺寸不变，但按 `dpr × renderScale`
/// 出图。T0.4 实测 4× 倍率下一块 200×120pt 只要 4ms，所以放大时重渲染是划算的；
/// 反过来若一直用 1× 的图去放大，4 倍时就是一片糊。
class PageLayer extends StatefulWidget {
  const PageLayer({
    super.key,
    required this.cache,
    required this.page,
    required this.width,
    this.renderScale = 1,
  });

  final PageImageCache cache;
  final WbPage page;

  /// 逻辑宽度（屏幕像素/逻辑像素，不含 dpr）。
  final double width;

  /// 出图倍率，1 表示只按屏幕 dpr 出图。
  final double renderScale;

  @override
  State<PageLayer> createState() => _PageLayerState();
}

class _PageLayerState extends State<PageLayer> {
  ui.Image? _image;
  int _request = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    unawaited(_load());
  }

  @override
  void didUpdateWidget(covariant PageLayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.page.index != widget.page.index ||
        oldWidget.width != widget.width ||
        oldWidget.renderScale != widget.renderScale) {
      unawaited(_load());
    }
  }

  Future<void> _load() async {
    final double dpr = MediaQuery.devicePixelRatioOf(context);
    final int widthPx = (widget.width * dpr * widget.renderScale).round();
    final int request = ++_request;
    final ui.Image? image = await widget.cache.obtain(
      widget.page.index,
      widthPx,
    );
    if (!mounted || request != _request) {
      // 过期结果：自己拿到的那份 clone 要还回去，否则泄漏
      image?.dispose();
      return;
    }
    final ui.Image? previous = _image;
    setState(() {
      _image = image;
    });
    previous?.dispose();
  }

  @override
  void dispose() {
    _request++; // 让在途请求的结果失效
    _image?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final double height = widget.width * widget.page.height / widget.page.width;
    final ui.Image? image = _image;

    return Container(
      width: widget.width,
      height: height,
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.18),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: image == null
          ? Center(
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            )
          : RawImage(
              image: image,
              fit: BoxFit.fill,
              // low 而不是 medium：放大绘制时 medium 会走更贵的重采样，
              // 缩放过程中明显掉帧。反正松手后会用更高倍率重渲染，画的瞬间不需要精致。
              filterQuality: FilterQuality.low,
            ),
    );
  }
}

/// 阅读区背景（阅读器自己的一层，不是纸感滤镜——滤镜在 T1.6）。
class ReaderBackdrop extends StatelessWidget {
  const ReaderBackdrop({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Theme.of(context).colorScheme.surfaceContainerLowest,
      child: Padding(padding: const EdgeInsets.all(ShqSpace.sm), child: child),
    );
  }
}
