import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:shuaqi/domain/ink/ink_tool.dart';
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
    this.inkTool = InkTool.pen,
    this.inkColorIndex = 0,
    this.inkbrushWidth = 1,
    this.onPenDown,
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

  /// 当前笔刷。只影响之后画的笔。
  final InkTool inkTool;

  /// 当前颜色（调色板索引）与粗细档。只影响之后落下的笔。
  final int inkColorIndex;
  final int inkbrushWidth;

  /// 笔落屏时通知外层（滚动模式用来停惯性滚动）。见 [InkLayer.onPenDown]。
  final VoidCallback? onPenDown;

  @override
  State<PageLayer> createState() => _PageLayerState();
}

class _PageLayerState extends State<PageLayer> {
  ui.Image? _image;
  int _request = 0;

  /// 这张图彻底拿不到（渲染失败 / 返回 null）。**不能永远转圈**：
  /// 用户看到的应该是"这一页没显示出来，点一下重试"，而不是一个转不完的菊花。
  bool _failed = false;

  /// 自动重试次数：只自动重试一次（瞬时失败很常见，比如一次内存抖动），
  /// 再失败就交给用户点按，避免在 OOM 时反复点火。
  int _attempt = 0;
  Timer? _retryTimer;

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
      _retryTimer?.cancel();
      _attempt = 0;
      _failed = false;
      unawaited(_load());
    }
  }

  Future<void> _load() async {
    _retryTimer?.cancel();
    final double dpr = MediaQuery.devicePixelRatioOf(context);
    final int widthPx =
        widget.qualityWidth ??
        (widget.width * dpr * widget.renderScale).round();
    final int request = ++_request;
    if (_failed && mounted) {
      setState(() => _failed = false); // 回到转圈态，表示"在重试"
    }
    ui.Image? image;
    Object? error;
    try {
      image = await widget.cache.obtain(widget.page.index, widthPx);
    } on Object catch (e) {
      error = e;
    }
    if (!mounted || request != _request) {
      // 过期结果：自己拿到的那份 clone 要还回去，否则泄漏
      image?.dispose();
      return;
    }
    if (image == null) {
      _onLoadFailed(request, error, widthPx);
      return;
    }
    _attempt = 0;
    final ui.Image? previous = _image;
    setState(() {
      _image = image;
      _failed = false;
    });
    previous?.dispose();
  }

  /// 取图失败：先自动重试一次，仍失败就显示可点按的重试态。
  void _onLoadFailed(int request, Object? error, int widthPx) {
    if (!mounted || request != _request) {
      return;
    }
    if (_attempt < 1) {
      _attempt++;
      _retryTimer = Timer(const Duration(milliseconds: 450), () {
        if (mounted && request == _request) {
          unawaited(_load());
        }
      });
      return;
    }
    setState(() => _failed = true);
    // 只记录，不吞掉信息：真机上排查"某页空白"时需要这一行。
    debugPrint(
      'PageLayer 取图失败 page=${widget.page.index} '
      'width=$widthPx error=${error ?? 'null image'}',
    );
  }

  @override
  void dispose() {
    _request++; // 让在途请求的结果失效
    _retryTimer?.cancel();
    _image?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final double height = widget.width * widget.page.height / widget.page.width;
    final ui.Image? image = _image;

    // 纸是暗的还是亮的，只看**纸样式**（`PaperStyle.isDarkPaper`），
    // 不看 App 主题：深色界面下看白底黑字的卷子是正常组合（2026-10-22 拍板）。
    final bool darkPaper = widget.style.isDarkPaper;

    // 背景层：PaperEffect 只染这一棵树。
    //
    // **RepaintBoundary 是滚动模式丝滑的关键**（2026-10-22）：
    // 相机矩阵每帧在变，`RenderTransform` 只有在其子树
    // `needsCompositing` 时才会推一个真正的合成层（TransformLayer），
    // 否则就把矩阵压进 canvas —— 那一层的整页位图 + 噪点会被逐帧
    // 重新光栅化（2 页 A4 ≈ 12.8MP/帧的填充），120Hz 必掉帧。
    // 加一层 boundary 后，平移只是合成器搬一张缓存贴图。
    // 它同时把"墨迹层每帧重绘"与"PDF 位图"隔开：写字时不重画背景。
    //
    // 层次：**边框与投影在滤镜外层**。它们在滤镜里会被 duotone 一起反色
    // （黑投影 → 暖白发光），夜读纸上就会出现一圈脏光。
    final Widget paper = RepaintBoundary(
      child: SizedBox(
        width: widget.width,
        height: height,
        child: DecoratedBox(
          decoration: BoxDecoration(
            // 页面底色（位图未就绪时的底）：暗纸用夜读纸色，其余用白纸。
            color: darkPaper ? ShqNight.paper : ShqPaper.base,
            // 暗纸在暗背景里只差亮度，一圈极淡亮边让"纸"显形。
            border: darkPaper ? Border.all(color: ShqNight.pageEdge) : null,
            boxShadow: const <BoxShadow>[
              BoxShadow(
                color: ShqPaper.lightPageShadow,
                blurRadius: 6,
                offset: Offset(0, 2),
              ),
            ],
          ),
          child: PaperEffect(
            style: widget.style,
            intensity: widget.intensity,
            child: image == null
                ? (_failed
                      ? _PageLoadFailed(
                          onRetry: () => unawaited(_load()),
                          roomy: widget.width >= 220,
                        )
                      : Center(
                          child: SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ))
                : RawImage(
                    image: image,
                    fit: BoxFit.fill,
                    // low 而不是 medium：放大绘制时 medium 会走更贵的重采样，
                    // 缩放过程中明显掉帧。反正松手后会用更高倍率重渲染，画的瞬间不需要精致。
                    filterQuality: FilterQuality.low,
                  ),
          ),
        ),
      ),
    );

    // 没有墨迹层：背景自己就带确定尺寸（width/height 已写死），直接返回。
    final String? sessionId = widget.sessionId;
    if (sessionId == null || !widget.inkEnabled) {
      return paper;
    }
    // 墨迹层：PaperEffect 的兄弟节点（T1.6 红线），只吃自己的 stylus 手势。
    //
    // **必须用 SizedBox 把 Stack 钉在页面尺寸上**：Stack 若只有 Positioned 子节点，
    // 会撑满父级给的约束——分页模式里父级是 `Center`（松散约束 = 整个视口），
    // 于是页面被拉成视口比例（A4 变方形、题干变形）。这是 T2.1 引入的真实缺陷。
    return SizedBox(
      width: widget.width,
      height: height,
      child: Stack(
        children: <Widget>[
          Positioned.fill(child: paper),
          Positioned.fill(
            // **墨迹层必须自己是一个合成层**（2026-10-23 实测）：
            // 相机矩阵每帧都在变，`RenderTransform` 换矩阵时会把整棵非边界子树
            // 重新 paint —— 墨迹层的 CustomPaint 不是 RepaintBoundary，
            // 于是"每一帧滚动都把这一页所有笔画重画一遍"（写满的页就是几百次
            // drawPath/帧）。包一层 boundary 后，滚动时墨迹层直接复用缓存图层。
            child: RepaintBoundary(
              child: InkLayer(
                inkKey: InkPageKey(
                  sessionId,
                  widget.page.index,
                  workbookId: widget.page.workbookId,
                ),
                pageWidthPt: widget.page.width,
                width: widget.width,
                // 墨色跟纸配对（不是跟界面主题配对）：夜读纸 → 提亮的取色表。
                darkPaper: widget.style.isDarkPaper,
                tool: widget.inkTool,
                colorIndex: widget.inkColorIndex,
                brushWidth: widget.inkbrushWidth,
                onPenDown: widget.onPenDown,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 一页取图失败时的占位：**明确告知 + 可重试**，而不是永远转圈。
///
/// 为什么要有：真机上渲染失败可能来自瞬时内存压力，"刷新了但没显示"
/// 如果只留一个菊花，用户只能干等；一个可点按的刷新至少给了一条恢复路径。
class _PageLoadFailed extends StatelessWidget {
  const _PageLoadFailed({required this.onRetry, required this.roomy});

  final VoidCallback onRetry;

  /// 宽页（正文）显示完整文案；缩略图那种小格子只放一个刷新钮。
  final bool roomy;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    if (!roomy) {
      return Center(
        child: IconButton(
          onPressed: onRetry,
          tooltip: '这一页没显示出来，点按重试',
          icon: Icon(Icons.refresh, size: 22, color: scheme.onSurfaceVariant),
        ),
      );
    }
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(
            Icons.broken_image_outlined,
            size: 28,
            color: scheme.onSurfaceVariant,
          ),
          const SizedBox(height: ShqSpace.xs),
          Text(
            '这一页没显示出来',
            style: theme.textTheme.labelSmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: ShqSpace.xxs),
          TextButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh, size: 16),
            label: const Text('重试'),
            style: TextButton.styleFrom(
              minimumSize: const Size(0, 36),
              padding: const EdgeInsets.symmetric(horizontal: ShqSpace.md),
            ),
          ),
        ],
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
