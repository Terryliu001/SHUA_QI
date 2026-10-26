import 'dart:math' as math;

import 'package:flutter/gestures.dart'
    show
        GestureDisposition,
        OneSequenceGestureRecognizer,
        PointerDeviceKind,
        PointerDownEvent,
        PointerEvent,
        PointerUpEvent,
        PointerCancelEvent;
import 'package:flutter/material.dart';
import 'package:shuaqi/domain/ink/ink_tool.dart';
import 'package:shuaqi/domain/model/wb_page.dart';
import 'package:shuaqi/domain/reader/reader_prefs.dart';
import 'package:shuaqi/ui/reader/page_image_cache.dart';
import 'package:shuaqi/ui/reader/page_layer.dart';
import 'package:shuaqi/ui/reader/region_overlay.dart';
import 'package:shuaqi/ui/theme/tokens.dart';

/// 分页模式：一屏一页 + 页内自由缩放（1.0–4.0）+ 左右边缘 15% 点击翻页 + 双击缩放。
///
/// **每页各自持有一个 [TransformationController]，绝不中途重挂。**
/// 之前是"只给当前页挂同一个控制器"，翻页时控制器从旧页摘下再挂到新页，
/// 正在进行的捏合会被打断——表现就是「翻页后第一次放大不跟手」。
///
/// 为丝滑做的另两件事：预渲染前后页；只在手势结束时换高倍率图。
class PagedReaderView extends StatefulWidget {
  const PagedReaderView({
    super.key,
    required this.pages,
    required this.cache,
    required this.initialPage,
    required this.onPageChanged,
    this.style = PaperStyle.original,
    this.intensity = ReaderPrefs.defaultIntensity,
    this.sessionId,
    this.inkTool = InkTool.pen,
    this.inkColorIndex = 0,
    this.inkbrushWidth = 1,
    this.regionMarksByPage = const <int, List<RegionMark>>{},
    this.regionConfig,
    this.regionEditing = false,
    this.fingerWrites = true,
  });

  final List<WbPage> pages;
  final PageImageCache cache;
  final int initialPage;
  final ValueChanged<int> onPageChanged;
  final PaperStyle style;
  final int intensity;

  /// 当前 draft 会话 id。null = 不挂墨迹层。
  final String? sessionId;

  /// 当前颜色（调色板索引）与粗细档。只影响之后落下的笔。
  final int inkColorIndex;
  final int inkbrushWidth;

  /// 当前笔刷（工具栏选中项）。
  final InkTool inkTool;

  /// 每页的题目区域框（T3.5 检查视角）。空 Map = 不画。
  final Map<int, List<RegionMark>> regionMarksByPage;

  /// 叠加层的编辑配置（null = 只读）。
  final RegionOverlayConfig? regionConfig;

  /// 正在调框（「题目区域」面板打开）：墨迹层只画不收笔，手写笔用来调框。
  final bool regionEditing;

  /// 书写模式：单指/笔写字，双指平移缩放。
  /// false = 手势模式：**手指只平移缩放，笔仍然写字**（2026-10-24 用户口径）。
  /// 两者的差别只在「手指算不算笔」；笔永远优先给墨迹层，除非正在调框。
  final bool fingerWrites;

  @override
  State<PagedReaderView> createState() => PagedReaderViewState();
}

class PagedReaderViewState extends State<PagedReaderView> {
  late final PageController _pageController;

  /// 每页一个缩放控制器。绝不跨页复用——跨页复用会打断正在进行的捏合手势。
  final Map<int, TransformationController> _controllers =
      <int, TransformationController>{};

  late int _current;
  int _renderScale = 1;
  bool _zoomed = false;
  Size _viewport = Size.zero;
  String _prefetched = '';

  @override
  void initState() {
    super.initState();
    _current = widget.initialPage.clamp(
      0,
      math.max(0, widget.pages.length - 1),
    );
    _pageController = PageController(initialPage: _current);
  }

  @override
  void dispose() {
    for (final TransformationController controller in _controllers.values) {
      controller.dispose();
    }
    _controllers.clear();
    _pageController.dispose();
    super.dispose();
  }

  TransformationController _controllerFor(int index) {
    return _controllers.putIfAbsent(index, () {
      return TransformationController()..addListener(() => _onZoomTick(index));
    });
  }

  /// 手势过程中只更新"当前页是否已放大"（用来切 PageView 的 physics）。
  /// **不**在这里换高分辨率图——那会触发重渲染，缩放直接卡。
  void _onZoomTick(int index) {
    if (index != _current) {
      return;
    }
    final bool zoomed = _controllerFor(index).value.getMaxScaleOnAxis() > 1.05;
    if (zoomed != _zoomed) {
      setState(() {
        _zoomed = zoomed;
      });
    }
  }

  void _commitScale(int index) {
    if (index != _current) {
      return;
    }
    final double scale = _controllerFor(index).value.getMaxScaleOnAxis();
    final int bucket = scale <= 1.05 ? 1 : scale.round().clamp(1, 4);
    if (bucket != _renderScale) {
      setState(() {
        _renderScale = bucket;
      });
    }
  }

  void _setScale(double target) {
    if (_viewport.isEmpty) {
      return;
    }
    final TransformationController controller = _controllerFor(_current);
    if (target <= 1.0) {
      controller.value = Matrix4.identity();
    } else {
      final Offset center = _viewport.center(Offset.zero);
      controller.value = Matrix4.identity()
        ..translateByDouble(center.dx, center.dy, 0, 1)
        ..scaleByDouble(target, target, target, 1)
        ..translateByDouble(-center.dx, -center.dy, 0, 1);
    }
    _commitScale(_current);
  }

  void _goTo(int delta) {
    final int next = _current + delta;
    if (next < 0 || next >= widget.pages.length) {
      return;
    }
    _pageController.animateToPage(
      next,
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
    );
  }

  void _prefetchNeighbours(double dpr) {
    if (widget.pages.isEmpty) {
      return;
    }
    final WbPage page = widget.pages[_current];
    final double fit = math.min(
      _viewport.width / page.width,
      _viewport.height / page.height,
    );
    final int widthPx = (page.width * fit * dpr).round();
    final String token = '$_current/$widthPx';
    if (token == _prefetched) {
      return;
    }
    _prefetched = token;
    for (final int offset in <int>[-1, 1, 2]) {
      final int index = _current + offset;
      if (index >= 0 && index < widget.pages.length) {
        widget.cache.prefetch(index, widthPx);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final double dpr = MediaQuery.devicePixelRatioOf(context);
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        _viewport = Size(constraints.maxWidth, constraints.maxHeight);
        _prefetchNeighbours(dpr);

        final Widget pager = PageView.builder(
          controller: _pageController,
          // 翻页只走左右按钮与缩略图，页面区域完全留给缩放。
          // 之前用"边缘点击 + 滑动翻页"，会和捏合/平移在手势竞技场里互相抢，
          // 表现就是"放大后第一次操作不跟手"。
          physics: const NeverScrollableScrollPhysics(),
          itemCount: widget.pages.length,
          onPageChanged: (int index) {
            final TransformationController controller = _controllerFor(index);
            final double scale = controller.value.getMaxScaleOnAxis();
            setState(() {
              _current = index;
              _zoomed = scale > 1.05;
              _renderScale = scale <= 1.05 ? 1 : scale.round().clamp(1, 4);
            });
            widget.onPageChanged(index);
          },
          itemBuilder: (BuildContext context, int index) {
            final WbPage page = widget.pages[index];
            final double fit = math.min(
              constraints.maxWidth / page.width,
              constraints.maxHeight / page.height,
            );
            final double displayWidth = page.width * fit;
            final TransformationController controller = _controllerFor(index);
            final bool zoomed = controller.value.getMaxScaleOnAxis() > 1.05;

            return GestureDetector(
              behavior: HitTestBehavior.translucent,
              // 双击等页面手势只收 touch：stylus 的拖动交给墨迹层
              //（规格 §6.9.1「笔写、指滚」）。
              supportedDevices: const <PointerDeviceKind>{
                PointerDeviceKind.touch,
              },
              // 双击：fit-width ↔ 2 倍。书写模式关掉双击——单指点两下
              // 会先落两个墨点再缩放，和"单指书写"冲突。
              onDoubleTap: widget.fingerWrites
                  ? null
                  : () {
                      if (index != _current) {
                        return;
                      }
                      final double scale = controller.value.getMaxScaleOnAxis();
                      _setScale(scale > 1.5 ? 1.0 : 2.0);
                    },
              child: _TouchPanGate(
                fingerWrites: widget.fingerWrites,
                builder: (bool panEnabled) {
                  final Widget viewer = InteractiveViewer(
                    minScale: 1,
                    maxScale: 4,
                    // 每页始终挂着自己的控制器，不再中途重挂
                    transformationController: controller,
                    // 缩放后单指平移才有意义；1x 时不开，避免和平移/翻页抢手势。
                    // 书写模式下单指只写字：panEnabled 由 _TouchPanGate 按
                    // "是否已有第二根手指"动态控制；双指才放行平移/缩放。
                    panEnabled:
                        panEnabled && (index == _current ? _zoomed : zoomed),
                    scaleEnabled: true,
                    onInteractionEnd: (ScaleEndDetails details) =>
                        _commitScale(index),
                    child: Center(
                      child: PageLayer(
                        cache: widget.cache,
                        page: page,
                        width: displayWidth,
                        renderScale: index == _current
                            ? _renderScale.toDouble()
                            : 1,
                        style: widget.style,
                        intensity: widget.intensity,
                        sessionId: widget.sessionId,
                        // **放大状态下也允许书写**（2026-10-22 用户反馈推翻 T2.1 的取舍）：
                        // 墨迹层在 IV 的变换子树里，指针事件的 localPosition 会被
                        // IV 的矩阵自动逆变换到页面局部坐标，写哪儿落在哪儿；
                        // stylus 不会平移页面——那由 [StylusGestureGuard] 挡住。
                        inkEnabled:
                            widget.sessionId != null && index == _current,
                        // 手形/手势模式与书写模式都收笔：笔始终是笔。
                        // 区别只在手指是否落墨（inkTouch）；调框模式才整层禁用。
                        inkInteractive: !widget.regionEditing,
                        inkTouch: !widget.regionEditing && widget.fingerWrites,
                        inkTool: widget.inkTool,
                        inkColorIndex: widget.inkColorIndex,
                        inkbrushWidth: widget.inkbrushWidth,
                        regionMarks:
                            widget.regionMarksByPage[page.index] ??
                            const <RegionMark>[],
                        regionConfig: widget.regionConfig,
                      ),
                    ),
                  );
                  // 守卫拦的始终是"笔"：笔要写字，不能被 IV 的 pan/scale 抢走。
                  // 调框模式是唯一例外——那时笔要优先给框。
                  return !widget.regionEditing
                      ? StylusGestureGuard(child: viewer)
                      : viewer;
                },
              ),
            );
          },
        );

        return Stack(
          children: <Widget>[
            Positioned.fill(child: pager),
            Positioned(
              left: ShqSpace.xs,
              top: 0,
              bottom: 0,
              child: Center(child: _navButton(-1)),
            ),
            Positioned(
              right: ShqSpace.xs,
              top: 0,
              bottom: 0,
              child: Center(child: _navButton(1)),
            ),
          ],
        );
      },
    );
  }

  /// 左右翻页按钮。首/末页置灰（不可点），不做隐藏 —— 隐藏会让页面宽度跳动。
  Widget _navButton(int delta) {
    final int target = _current + delta;
    final bool enabled = target >= 0 && target < widget.pages.length;
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return AnimatedOpacity(
      duration: const Duration(milliseconds: 150),
      opacity: enabled ? 1 : 0.25,
      child: Material(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.92),
        shape: const CircleBorder(),
        elevation: 2,
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: enabled ? () => _goTo(delta) : null,
          child: SizedBox(
            width: 52,
            height: 52,
            child: Icon(
              delta < 0 ? Icons.chevron_left : Icons.chevron_right,
              size: 30,
              color: scheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }

  /// 供父级"跳到某页"用（缩略图抽屉）。
  void jumpTo(int index) {
    if (index < 0 || index >= widget.pages.length) {
      return;
    }
    _pageController.jumpToPage(index);
  }
}

/// 顶部页码条。1-based 显示，库里存 0-based。
class PageIndicator extends StatelessWidget {
  const PageIndicator({
    super.key,
    required this.current,
    required this.total,
    this.onTap,
  });

  final int current;
  final int total;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    return TextButton(
      onPressed: onTap,
      style: TextButton.styleFrom(
        minimumSize: const Size(0, 38),
        padding: const EdgeInsets.symmetric(horizontal: ShqSpace.md),
        foregroundColor: scheme.onSurfaceVariant,
        backgroundColor: scheme.surfaceContainerHigh,
        shape: StadiumBorder(side: BorderSide(color: scheme.outlineVariant)),
        visualDensity: VisualDensity.compact,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(
            Icons.grid_view_rounded,
            size: 16,
            color: scheme.onSurfaceVariant,
          ),
          const SizedBox(width: ShqSpace.sm),
          AnimatedSwitcher(
            duration: ShqMotion.fast,
            switchInCurve: ShqMotion.curveStandard,
            switchOutCurve: ShqMotion.curveExit,
            transitionBuilder: (Widget child, Animation<double> animation) =>
                FadeTransition(opacity: animation, child: child),
            child: Text(
              '${current + 1} / $total',
              // 页码变时做一次淡入淡出，避免数字硬跳（尤其是快速翻页）。
              key: ValueKey<String>('$current/$total'),
              style: theme.textTheme.labelLarge?.copyWith(
                color: scheme.onSurfaceVariant,
                fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 单指书写、双指平移/缩放的"动态 panEnabled"门。
///
/// [InteractiveViewer] 的 `panEnabled` 是整段手势的布尔值，不会按 pointerCount
/// 自己变。书写模式下：
/// - 只有一根手指 → panEnabled=false：IV 不抢单指，墨迹层写字；
/// - 第二根手指落下 → panEnabled=true：IV 接管双指平移/缩放。
///
/// 墨迹层在第二根手指落下时会取消当前笔画（见 `InkLayer._cancelForMultiTouch`），
/// 所以不会出现"缩放时留下半条线"。
class _TouchPanGate extends StatefulWidget {
  const _TouchPanGate({required this.fingerWrites, required this.builder});

  final bool fingerWrites;
  final Widget Function(bool panEnabled) builder;

  @override
  State<_TouchPanGate> createState() => _TouchPanGateState();
}

class _TouchPanGateState extends State<_TouchPanGate> {
  final Set<int> _touches = <int>{};

  bool get _panEnabled => !widget.fingerWrites || _touches.length >= 2;

  @override
  void didUpdateWidget(covariant _TouchPanGate oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.fingerWrites != widget.fingerWrites) {
      _touches.clear();
    }
  }

  void _down(PointerDownEvent event) {
    if (event.kind != PointerDeviceKind.touch) {
      return;
    }
    setState(() => _touches.add(event.pointer));
  }

  void _up(PointerEvent event) {
    if (event.kind != PointerDeviceKind.touch) {
      return;
    }
    if (_touches.remove(event.pointer)) {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: _down,
      onPointerUp: _up,
      onPointerCancel: _up,
      child: widget.builder(_panEnabled),
    );
  }
}

/// 只认笔的"竞技场守卫"：笔一落屏就**立刻**接受手势。
///
/// ## 为什么需要它
/// [InteractiveViewer] 内部是普通 `GestureDetector`（没有设备过滤）。
/// 放大状态下它允许单指平移，而笔的拖动会被它的 `ScaleGestureRecognizer`
/// 当成平移——表现就是"放大后一落笔页面就跑，字没法写"。
/// 本守卫在 `PointerDownEvent` 派发期间就 `resolve(accepted)`，
/// 把 IV 的识别器挤出竞技场（竞技场在 DOWN 派发结束时 sweep，
/// 那时未决的竞技场会判给**第一个**成员——也就是 IV，所以必须抢在 sweep 前）。
///
/// touch 不在允许列表里：手指的缩放/平移照常走 IV，双击照常走外层
/// GestureDetector——"笔写、指滚"（§6.9.1）在放大状态下依然成立。
/// 墨迹层的 `Listener` 不是竞技场成员，照常收到笔事件用于书写。
class StylusGestureGuard extends StatelessWidget {
  const StylusGestureGuard({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return RawGestureDetector(
      // translucent：只加入命中结果，不拦 touch 的命中链。
      behavior: HitTestBehavior.translucent,
      gestures:
          <Type, GestureRecognizerFactoryWithHandlers<_StylusGuardRecognizer>>{
            _StylusGuardRecognizer:
                GestureRecognizerFactoryWithHandlers<_StylusGuardRecognizer>(
                  () => _StylusGuardRecognizer(
                    supportedDevices: const <PointerDeviceKind>{
                      PointerDeviceKind.stylus,
                      PointerDeviceKind.invertedStylus,
                    },
                  ),
                  (_StylusGuardRecognizer instance) {},
                ),
          },
      child: child,
    );
  }
}

class _StylusGuardRecognizer extends OneSequenceGestureRecognizer {
  _StylusGuardRecognizer({super.supportedDevices});

  @override
  void addAllowedPointer(PointerDownEvent event) {
    startTrackingPointer(event.pointer, event.transform);
    // 立刻接受：IV 的 pan/scale 识别器随即被 reject，本次笔划不再平移页面。
    resolve(GestureDisposition.accepted);
  }

  @override
  void handleEvent(PointerEvent event) {
    if (event is PointerUpEvent || event is PointerCancelEvent) {
      stopTrackingPointer(event.pointer);
    }
  }

  @override
  void didStopTrackingLastPointer(int pointer) {
    // 已 resolve(accepted)，这里复位识别器状态；arena 侧的重复 resolve 是 no-op。
    resolve(GestureDisposition.rejected);
  }

  @override
  String get debugDescription => 'stylusGuard';
}
