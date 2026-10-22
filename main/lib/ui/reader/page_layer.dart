import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:shuaqi/domain/model/wb_page.dart';
import 'package:shuaqi/domain/reader/reader_prefs.dart';
import 'package:shuaqi/state/ink_providers.dart';
import 'package:shuaqi/ui/reader/ink_layer.dart';
import 'package:shuaqi/ui/reader/page_image_cache.dart';
import 'package:shuaqi/ui/theme/tokens.dart';
import 'package:shuaqi/ui/widgets/paper_effect.dart';

/// 单页图层：白纸 + 页位图（+ 第 2 周起的墨迹层）。
///
/// [renderScale] 用来提高"放大后"的清晰度：显示尺寸不变，但按 `dpr × renderScale`
/// 出图。T0.4 实测 4× 倍率下一块 200×120pt 只要 4ms，所以放大时重渲染是划算的；
/// 反过来若一直用 1× 的图去放大，4 倍时就是一片糊。
///
/// ## 墨迹层的位置（T1.6 立下的红线）
/// 墨迹层是 [PaperEffect] 的**兄弟节点**（叠在它上面），绝不是子节点——
/// 否则笔迹会被纸感滤镜 / 夜读 duotone 染色（REQ-15）。
class PageLayer extends StatefulWidget {
  const PageLayer({
    super.key,
    required this.cache,
    required this.page,
    required this.width,
    this.renderScale = 1,
    this.qualityWidth,
    this.style = PaperStyle.original,
    this.intensity = ReaderPrefs.defaultIntensity,
    this.sessionId,
    this.inkEnabled = false,
  });

  final PageImageCache cache;
  final WbPage page;

  /// 逻辑宽度（屏幕像素/逻辑像素，不含 dpr）。
  final double width;

  /// 出图倍率，1 表示只按屏幕 dpr 出图。
  final double renderScale;

  /// 直接指定位图的像素宽（优先级高于 [renderScale]）。
  ///
  /// 滚动模式的双指缩放必须用它：缩放过程中布局宽每帧都在变，
  /// 如果位图宽度跟着变，每一帧都会向缓存请求一张全新尺寸的图
  /// （一次捏合 60 帧 ≈ 60 张 12–50MB 位图），缓存被反复冲刷 → 闪烁、卡顿、内存暴涨。
  /// 所以缩放期间**冻结**这个值，停手后再升级一次。
  final int? qualityWidth;

  /// 纸感样式与强度。**只作用背景层**，第 2 周的墨迹层是兄弟节点，不吃这个滤镜。
  final PaperStyle style;
  final int intensity;

  /// 所属会话（draft session id）。null = 不挂墨迹层（缩略图等场景）。
  final String? sessionId;

  /// 这一页此刻是否接受落笔（分页模式放大中用 touch 平移，不写字）。
  final bool inkEnabled;

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
        oldWidget.renderScale != widget.renderScale ||
        oldWidget.qualityWidth != widget.qualityWidth) {
      unawaited(_load());
    }
  }

  Future<void> _load() async {
    final double dpr = MediaQuery.devicePixelRatioOf(context);
    final int widthPx =
        widget.qualityWidth ??
        (widget.width * dpr * widget.renderScale).round();
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
    final bool isDark = theme.brightness == Brightness.dark;
    final double height = widget.width * widget.page.height / widget.page.width;
    final ui.Image? image = _image;

    final Widget paper = PaperEffect(
      style: widget.style,
      intensity: widget.intensity,
      child: Container(
        width: widget.width,
        height: height,
        decoration: BoxDecoration(
          color: ShqPaper.base,
          // 暗色下页面与背景只差亮度，一圈极淡亮边让"纸"从近黑背景里显形；
          // 投影同时换得更淡更暖（暗底里重投影显脏）。
          border: isDark ? Border.all(color: ShqNight.pageEdge) : null,
          boxShadow: <BoxShadow>[
            BoxShadow(
              color: isDark ? ShqNight.pageShadow : ShqPaper.lightPageShadow,
              blurRadius: isDark ? 10 : 6,
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
      ),
    );

    // 墨迹层：PaperEffect 的兄弟节点（T1.6 红线），只吃自己的 stylus 手势
    final String? sessionId = widget.sessionId;
    if (sessionId == null || !widget.inkEnabled) {
      return paper;
    }
    return Stack(
      children: <Widget>[
        Positioned.fill(child: paper),
        Positioned.fill(
          child: InkLayer(
            inkKey: InkPageKey(sessionId, widget.page.index),
            pageWidthPt: widget.page.width,
            width: widget.width,
          ),
        ),
      ],
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
