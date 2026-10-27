import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:shuaqi/ui/theme/tokens.dart';

/// 裁剪窗（2026-10-26 用户第 3 条：头像 / 背景图上传后能自己裁一块）。
///
/// ## 为什么自己做
/// 依赖白名单里没有裁剪库（`image_cropper` 之类要改文档 + 加包），
/// 而"取景框 + 缩放平移"用自管矩阵比 `InteractiveViewer` 更可控：
/// 缩放中心必须跟着手指、图必须始终盖住取景框，这两点都要自己算。
///
/// ## 2026-10-26 重做：整图可见 + 绝不挤压（用户报"原图被挤压，框不准"）
///
/// 现象：上传后预览里的原图被明显拉扁，没法按意图框选。
///
/// 根因（两个，叠在一起）：
/// 1. **约束把图夹回视口**：图被 `Positioned.fill` 的紧约束包着，
///    `SizedBox(width: base.width, ...)` 会走 `BoxConstraints.enforce`
///    被夹成视口尺寸，于是 `RawImage(fit: BoxFit.fill)` 把图按视口宽高比
///    硬拉 —— 这才叫"挤压"。修法：用 [OverflowBox] 解除上界，
///    再 `ClipRect` 裁掉溢出部分，`BoxFit.contain` 兜底（尺寸对不上时
///    宁可留边也绝不拉伸）。
/// 2. **一进来就 cover 到视口**：图被放到"刚好盖满视口"，竖构图只看得到
///    中间一条，用户看不到全图自然框不准。修法见下。
///
/// 现在的口径（用户明确："底层要是原图的完整展示"）：
/// - 底层恒为 **contain**：整张原图完整落在视口里，`scale = 1` 就是全图；
/// - 取景框按目标比例**内接在图里**（不是内接在屏幕里），所以 `scale = 1`
///   时框一定被图盖满，**任何时刻都不会裁出空白**；
/// - 缩放范围 `1×..8×`，放大后以手指为中心、四边夹住不让拖出框；
/// - 拖动 / 双指缩放是直接跟手的（不走手势竞技场）；按钮与「重置」走
///   220ms 缓动，手感才是"灵动"而不是瞬移。
///
/// ## 输出
/// 按 [CropKind.outWidth] × [CropKind.outputHeight] 输出 PNG，
/// 比例恒等于取景框比例（封面不再被压扁）。
class CropKind {
  const CropKind({
    required this.title,
    required this.aspectRatio,
    required this.outWidth,
    this.outHeight,
    this.circular = false,
  });

  /// 头像：正方形；最终显示是圆形，所以取景框也画圆。
  const CropKind.avatar()
    : title = '裁剪头像',
      aspectRatio = 1,
      outWidth = 512,
      outHeight = 512,
      circular = true;

  /// 封面：横幅。比例由调用方按页首实宽算（`宽 / 230`）。
  const CropKind.cover({required this.aspectRatio})
    : title = '裁剪封面',
      outWidth = 1600,
      outHeight = null,
      circular = false;

  final String title;

  /// 取景框的宽 / 高。
  final double aspectRatio;

  final int outWidth;

  /// 显式输出高度；null = 按宽与比例算。
  final int? outHeight;

  /// 头像最终显示为圆形；预览框也画圆形，避免"方框裁完变圆"的错觉。
  final bool circular;

  /// 输出高度：显式给了就用；否则按比例算（封面不再被压扁）。
  int get outputHeight => outHeight ?? (outWidth / aspectRatio).round();
}

/// 打开裁剪窗。返回裁好的 PNG 字节；取消返回 null。
Future<Uint8List?> showImageCropSheet(
  BuildContext context, {
  required Uint8List bytes,
  required CropKind kind,
}) {
  return Navigator.of(context).push<Uint8List>(
    MaterialPageRoute<Uint8List>(
      fullscreenDialog: true,
      builder: (BuildContext context) => _CropPage(bytes: bytes, kind: kind),
    ),
  );
}

class _CropPage extends StatefulWidget {
  const _CropPage({required this.bytes, required this.kind});

  final Uint8List bytes;
  final CropKind kind;

  @override
  State<_CropPage> createState() => _CropPageState();
}

class _CropPageState extends State<_CropPage>
    with SingleTickerProviderStateMixin {
  ui.Image? _image;
  String? _error;

  // 显示变换：图左上角 = [_offset]，尺寸 = [_base] × [_scale]。
  // 自己管矩阵而不是 `InteractiveViewer`：裁剪换算与显示矩形用同一口径，
  // 不会出现"看到的和裁出来的不是一块"。
  double _scale = 1;
  Offset _offset = Offset.zero;

  /// `scale = 1` 时的图片显示尺寸（**contain** 进视口，保持原图宽高比）。
  Size _base = Size.zero;

  /// 取景框在视口里的位置（大小由目标比例 + 图在 1× 时能盖住多少决定）。
  Rect _frame = Rect.zero;

  Size _viewport = Size.zero;

  /// 本次布局是否已经初始化过缩放/平移。
  bool _layoutReady = false;

  /// 下限 1 = 整张原图完整可见；上限给到 8×（再大就是看像素颗粒了）。
  static const double _minScale = 1;
  static const double _maxScale = 8;

  /// 用户是否已经动过图（第一次动之后提示语淡出）。
  bool _touched = false;

  /// 按钮/重置的缓动，避免"瞬移"。
  late final AnimationController _zoomCtl = AnimationController(
    vsync: this,
    duration: ShqMotion.base,
  )..addListener(_onZoomTick);
  double _fromScale = 1;
  double _toScale = 1;
  Offset _fromOffset = Offset.zero;
  Offset _toOffset = Offset.zero;

  // 手势起点快照。
  double _startScale = 1;
  Offset _startOffset = Offset.zero;
  Offset _startImagePoint = Offset.zero;

  /// 原始指针：不用 GestureDetector 的竞技场，单指平移 / 双指缩放自己算。
  /// （用户反馈"双指缩放没反应"，自己接管最稳，也不和父层手势抢。）
  final Map<int, Offset> _pointers = <int, Offset>{};
  double _pinchStartDistance = 1;
  Offset? _lastPan;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _zoomCtl.dispose();
    _image?.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final ui.Codec codec = await ui.instantiateImageCodec(widget.bytes);
      final ui.FrameInfo frame = await codec.getNextFrame();
      if (!mounted) {
        frame.image.dispose();
        return;
      }
      setState(() {
        _image = frame.image;
        _layoutReady = false;
      });
    } on Object catch (error) {
      if (mounted) {
        setState(() => _error = '这张图读不出来：$error');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final ui.Image? image = _image;
    final bool ready = image != null && _frame.width > 0;
    return Scaffold(
      backgroundColor: ShqScrim.backdrop,
      appBar: AppBar(
        backgroundColor: ShqScrim.backdrop,
        foregroundColor: ShqScrim.foreground,
        title: Text(
          widget.kind.title,
          style: theme.textTheme.titleMedium?.copyWith(
            color: ShqScrim.foreground,
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            style: TextButton.styleFrom(foregroundColor: ShqScrim.foreground),
            child: const Text('取消'),
          ),
          const SizedBox(width: ShqSpace.sm),
        ],
      ),
      body: _error != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(ShqSpace.xl),
                child: Text(
                  _error!,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: ShqScrim.foreground,
                  ),
                ),
              ),
            )
          : image == null
          ? const Center(child: CircularProgressIndicator())
          : _cropArea(image),
      bottomNavigationBar: SafeArea(
        top: false,
        child: Container(
          color: ShqScrim.backdrop,
          padding: const EdgeInsets.fromLTRB(
            ShqSpace.lg,
            ShqSpace.sm,
            ShqSpace.lg,
            ShqSpace.md,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Row(
                children: <Widget>[
                  IconButton(
                    tooltip: '缩小',
                    onPressed: ready
                        ? () => _zoomBy(1 / 1.25)
                        : null,
                    icon: const Icon(
                      Icons.remove,
                      color: ShqScrim.foreground,
                      size: 20,
                    ),
                  ),
                  Expanded(
                    child: Slider(
                      value: ready ? _scale.clamp(_minScale, _maxScale) : 1,
                      min: _minScale,
                      max: _maxScale,
                      onChanged: ready
                          ? (double value) =>
                                _setScaleAround(_frame.center, value)
                          : null,
                    ),
                  ),
                  IconButton(
                    tooltip: '放大',
                    onPressed: ready ? () => _zoomBy(1.25) : null,
                    icon: const Icon(
                      Icons.add,
                      color: ShqScrim.foreground,
                      size: 20,
                    ),
                  ),
                  TextButton(
                    onPressed: ready ? _reset : null,
                    style: TextButton.styleFrom(
                      foregroundColor: ShqScrim.foreground,
                    ),
                    child: const Text('重置'),
                  ),
                ],
              ),
              const SizedBox(height: ShqSpace.xs),
              Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      '缩放 ${_scale.toStringAsFixed(1)}× · '
                      '输出 ${widget.kind.outWidth} × '
                      '${widget.kind.outputHeight}',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: ShqScrim.foregroundMuted,
                      ),
                    ),
                  ),
                  FilledButton.icon(
                    onPressed: image == null ? null : () => _confirm(image),
                    icon: const Icon(Icons.check, size: 18),
                    label: const Text('使用这张'),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(0, 46),
                      backgroundColor: scheme.primary,
                      foregroundColor: scheme.onPrimary,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _cropArea(ui.Image image) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final Size viewport = Size(constraints.maxWidth, constraints.maxHeight);
        if (viewport.width <= 0 || viewport.height <= 0) {
          return const SizedBox.shrink();
        }
        // 视口内留一点边：图贴到屏幕边缘时，取景框四角会看不清。
        final Rect fitBox = (Offset.zero & viewport).deflate(ShqSpace.md);
        if (fitBox.width <= 0 || fitBox.height <= 0) {
          return const SizedBox.shrink();
        }

        // ① 基础尺寸 = **contain**：整张原图完整落在视口里（不裁、不挤压）。
        final double containScale = math.min(
          fitBox.width / image.width,
          fitBox.height / image.height,
        );
        final Size base = Size(
          image.width * containScale,
          image.height * containScale,
        );

        // ② 取景框 = 目标比例的最大矩形，且**必须内接在图里**。
        //    这样 scale = 1（全图）时框一定被盖满，任何时刻都不会裁出空白，
        //    用户也不必先放大才能裁。
        double frameW = math.min(
          fitBox.width,
          fitBox.height * widget.kind.aspectRatio,
        );
        double frameH = frameW / widget.kind.aspectRatio;
        if (frameW > base.width) {
          frameW = base.width;
          frameH = frameW / widget.kind.aspectRatio;
        }
        if (frameH > base.height) {
          frameH = base.height;
          frameW = frameH * widget.kind.aspectRatio;
        }
        final Rect frame = Rect.fromCenter(
          center: viewport.center(Offset.zero),
          width: frameW,
          height: frameH,
        );

        final bool layoutChanged =
            _viewport != viewport || _frame != frame || _base != base;
        _viewport = viewport;
        _frame = frame;
        _base = base;

        // 布局第一次就位 / 旋转 / 尺寸变化：回到"全图居中"。
        // 在 build 里不能 setState，直接赋值后本帧的 Transform 就生效。
        if (!_layoutReady || layoutChanged) {
          _layoutReady = true;
          _zoomCtl.stop();
          _resetInternal();
        } else {
          _scale = _scale.clamp(_minScale, _maxScale);
          _offset = _clampOffset(_offset, _scale);
        }

        return Stack(
          children: <Widget>[
            // 图在底层铺满整个视口（超出部分裁掉，不参与布局测量）。
            //
            // **OverflowBox + ClipRect 是修"挤压"的关键**：
            // 直接 `Positioned.fill` 会把 SizedBox 夹成视口尺寸，
            // 再 `fill` 就是按视口比例拉伸。放开上界后 SizedBox 才是
            // 真实尺寸，contain 也就永远不会变形。
            Positioned.fill(
              child: Listener(
                behavior: HitTestBehavior.opaque,
                onPointerDown: _onPointerDown,
                onPointerMove: _onPointerMove,
                onPointerUp: _onPointerUp,
                onPointerCancel: _onPointerUp,
                child: ClipRect(
                  child: OverflowBox(
                    alignment: Alignment.topLeft,
                    minWidth: 0,
                    maxWidth: double.infinity,
                    minHeight: 0,
                    maxHeight: double.infinity,
                    child: Transform(
                      transform: Matrix4.identity()
                        ..translateByDouble(_offset.dx, _offset.dy, 0, 1)
                        ..scaleByDouble(_scale, _scale, 1, 1),
                      alignment: Alignment.topLeft,
                      child: SizedBox(
                        width: base.width,
                        height: base.height,
                        child: RawImage(
                          image: image,
                          // contain：尺寸万一算错也只留边，绝不拉伸。
                          fit: BoxFit.contain,
                          filterQuality: FilterQuality.medium,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            // 取景框 + 四周遮罩 + 三分线。**必须 IgnorePointer**：
            // 它盖在输入层上方，否则会吃掉拖动/双指手势（真机踩到）。
            Positioned.fill(
              child: IgnorePointer(
                child: CustomPaint(
                  painter: _FramePainter(frame, circular: widget.kind.circular),
                ),
              ),
            ),
            // 提示语：第一次动过就淡出，不常驻抢视线。
            Positioned(
              left: ShqSpace.lg,
              right: ShqSpace.lg,
              bottom: ShqSpace.md,
              child: IgnorePointer(
                child: AnimatedOpacity(
                  opacity: _touched ? 0 : 1,
                  duration: ShqMotion.fast,
                  child: Center(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: ShqSpace.md,
                        vertical: ShqSpace.xs,
                      ),
                      decoration: BoxDecoration(
                        color: ShqScrim.backdrop.withValues(alpha: 0.66),
                        borderRadius: BorderRadius.circular(ShqRadius.pill),
                      ),
                      child: Text(
                        '整张图都在这里 · 双指放大后拖动框位',
                        style: Theme.of(context).textTheme.labelSmall
                            ?.copyWith(color: ShqScrim.foregroundMuted),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  void _onPointerDown(PointerDownEvent event) {
    _zoomCtl.stop();
    if (!_touched) {
      setState(() => _touched = true);
    }
    _pointers[event.pointer] = event.localPosition;
    if (_pointers.length >= 2) {
      final List<Offset> pts = _pointers.values.toList();
      _startScale = _scale;
      _startOffset = _offset;
      final Offset focal = (pts[0] + pts[1]) / 2;
      _pinchStartDistance = (pts[0] - pts[1]).distance;
      _startImagePoint = (focal - _startOffset) / _startScale;
      _lastPan = null;
    } else {
      _lastPan = event.localPosition;
    }
  }

  void _onPointerMove(PointerMoveEvent event) {
    if (!_pointers.containsKey(event.pointer)) {
      return;
    }
    _pointers[event.pointer] = event.localPosition;
    if (_pointers.length >= 2) {
      final List<Offset> pts = _pointers.values.toList();
      final double distance = (pts[0] - pts[1]).distance;
      if (distance <= 0 || _pinchStartDistance <= 0) {
        return;
      }
      final double nextScale = (_startScale * distance / _pinchStartDistance)
          .clamp(_minScale, _maxScale);
      final Offset focal = (pts[0] + pts[1]) / 2;
      final Offset nextOffset = focal - _startImagePoint * nextScale;
      setState(() {
        _scale = nextScale;
        _offset = _clampOffset(nextOffset, nextScale);
      });
      return;
    }
    final Offset? previous = _lastPan;
    _lastPan = event.localPosition;
    if (previous == null) {
      return;
    }
    final Offset nextOffset = _offset + (event.localPosition - previous);
    setState(() {
      _offset = _clampOffset(nextOffset, _scale);
    });
  }

  void _onPointerUp(PointerEvent event) {
    _pointers.remove(event.pointer);
    if (_pointers.length == 1) {
      _lastPan = _pointers.values.first;
    } else if (_pointers.isEmpty) {
      _lastPan = null;
    }
  }

  void _reset() {
    if (!_layoutReady) {
      return;
    }
    _animateTo(_minScale, _offsetForScale(_minScale));
  }

  void _resetInternal() {
    _scale = _minScale;
    _offset = _offsetForScale(_scale);
  }

  /// `scale` 下"图居中于取景框"的偏移。
  Offset _offsetForScale(double scale) {
    return _clampOffset(
      Offset(
        _frame.center.dx - _base.width * scale / 2,
        _frame.center.dy - _base.height * scale / 2,
      ),
      scale,
    );
  }

  void _zoomBy(double factor) {
    _setScaleAround(_frame.center, _scale * factor, animate: true);
  }

  void _setScaleAround(Offset focal, double nextScale, {bool animate = false}) {
    final double scale = nextScale.clamp(_minScale, _maxScale);
    if ((scale - _scale).abs() < 0.0001) {
      return;
    }
    final Offset imagePoint = (focal - _offset) / _scale;
    final Offset nextOffset = focal - imagePoint * scale;
    if (animate) {
      _animateTo(scale, nextOffset);
    } else {
      setState(() {
        _scale = scale;
        _offset = _clampOffset(nextOffset, scale);
      });
    }
  }

  void _animateTo(double scale, Offset offset) {
    final double target = scale.clamp(_minScale, _maxScale);
    _fromScale = _scale;
    _toScale = target;
    _fromOffset = _offset;
    _toOffset = _clampOffset(offset, target);
    _zoomCtl.forward(from: 0);
  }

  void _onZoomTick() {
    final double t = ShqMotion.curveStandard.transform(_zoomCtl.value);
    setState(() {
      _scale = _fromScale + (_toScale - _fromScale) * t;
      _offset = Offset.lerp(_fromOffset, _toOffset, t)!;
    });
  }

  /// 图必须始终盖住取景框：offset 是图左上角，框在 [offset, offset+图尺寸] 内。
  Offset _clampOffset(Offset offset, double scale) {
    final double width = _base.width * scale;
    final double height = _base.height * scale;
    final double minX = _frame.right - width;
    final double maxX = _frame.left;
    final double minY = _frame.bottom - height;
    final double maxY = _frame.top;
    return Offset(
      offset.dx.clamp(math.min(minX, maxX), math.max(minX, maxX)),
      offset.dy.clamp(math.min(minY, maxY), math.max(minY, maxY)),
    );
  }

  /// 确认：把取景框里的内容裁出来。
  Future<void> _confirm(ui.Image image) async {
    final Rect frame = _frame;
    if (frame.width <= 0 || frame.height <= 0) {
      return;
    }

    final double scale = _scale;
    final Offset translation = _offset;
    final Size base = _base;
    if (base.width <= 0 || base.height <= 0 || scale <= 0) {
      return;
    }
    // 图在视口里的实际位置与大小（平移 + 缩放）。
    final Rect displayed = Rect.fromLTWH(
      translation.dx,
      translation.dy,
      base.width * scale,
      base.height * scale,
    );
    // 取景框在图上的位置（换算回图片像素）。
    final double sx =
        ((frame.left - displayed.left) / displayed.width) * image.width;
    final double sy =
        ((frame.top - displayed.top) / displayed.height) * image.height;
    final double sw = (frame.width / displayed.width) * image.width;
    final double sh = (frame.height / displayed.height) * image.height;
    final Rect source = Rect.fromLTWH(sx, sy, sw, sh).intersect(
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
    );
    if (source.width <= 0 || source.height <= 0) {
      return;
    }

    final ui.PictureRecorder recorder = ui.PictureRecorder();
    final Canvas canvas = Canvas(recorder);
    final double outW = widget.kind.outWidth.toDouble();
    final double outH = widget.kind.outputHeight.toDouble();
    // 2026-10-27 用户：「头像框里还能看到矩形的裁切边」。
    //
    // 头像最终永远以圆形出现（页首 / 预览浮层）。这里直接把输出也**裁成圆**，
    // 圆外是透明像素 —— 就算未来某个界面漏了 ClipOval，也只会在圆的范围内
    // 有内容，不会再露出方形边界。封面仍然是直角矩形（页首是矩形）。
    if (widget.kind.circular) {
      canvas.clipPath(Path()..addOval(Rect.fromLTWH(0, 0, outW, outH)));
    }
    canvas.drawImageRect(
      image,
      source,
      Rect.fromLTWH(0, 0, outW, outH),
      Paint()..filterQuality = FilterQuality.high,
    );
    final ui.Picture picture = recorder.endRecording();
    final ui.Image out = await picture.toImage(
      widget.kind.outWidth,
      widget.kind.outputHeight,
    );
    final ByteData? data = await out.toByteData(format: ui.ImageByteFormat.png);
    out.dispose();
    picture.dispose();
    if (!mounted || data == null) {
      return;
    }
    Navigator.of(context).pop(data.buffer.asUint8List());
  }
}

/// 取景框画笔：框内不遮，框外压暗；带三分线与四角标记。
class _FramePainter extends CustomPainter {
  const _FramePainter(this.frame, {required this.circular});

  final Rect frame;
  final bool circular;

  @override
  void paint(Canvas canvas, Size size) {
    final Paint shade = Paint()
      ..color = ShqScrim.backdrop.withValues(alpha: 0.55);
    final Path outside = Path()
      ..addRect(Offset.zero & size)
      ..fillType = PathFillType.evenOdd;
    if (circular) {
      outside.addOval(frame);
    } else {
      outside.addRect(frame);
    }
    canvas.drawPath(outside, shade);

    if (!circular) {
      final Paint thin = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.8
        ..color = ShqScrim.foreground.withValues(alpha: 0.22);
      for (int i = 1; i <= 2; i += 1) {
        final double x = frame.left + frame.width * i / 3;
        final double y = frame.top + frame.height * i / 3;
        canvas.drawLine(Offset(x, frame.top), Offset(x, frame.bottom), thin);
        canvas.drawLine(Offset(frame.left, y), Offset(frame.right, y), thin);
      }
    }

    // 描边：先压一层半透明黑再压白线，亮图（试卷白纸）上白线才看得出来。
    final Paint borderShadow = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.6
      ..color = ShqScrim.backdrop.withValues(alpha: 0.35);
    final Paint border = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6
      ..color = ShqScrim.foreground;
    if (circular) {
      canvas.drawOval(frame, borderShadow);
      canvas.drawOval(frame, border);
    } else {
      canvas.drawRect(frame, borderShadow);
      canvas.drawRect(frame, border);
    }

    if (!circular) {
      // 四角短粗线：让"框在哪"更明确，同时不盖住内容。
      final Paint corner = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4
        ..strokeCap = StrokeCap.round
        ..color = ShqScrim.foreground;
      const double len = 16;
      final List<(Offset, Offset)> corners = <(Offset, Offset)>[
        (frame.topLeft, frame.topLeft + const Offset(len, 0)),
        (frame.topLeft, frame.topLeft + const Offset(0, len)),
        (frame.topRight, frame.topRight - const Offset(len, 0)),
        (frame.topRight, frame.topRight + const Offset(0, len)),
        (frame.bottomLeft, frame.bottomLeft + const Offset(len, 0)),
        (frame.bottomLeft, frame.bottomLeft - const Offset(0, len)),
        (frame.bottomRight, frame.bottomRight - const Offset(len, 0)),
        (frame.bottomRight, frame.bottomRight + const Offset(0, len)),
      ];
      for (final (Offset a, Offset b) in corners) {
        canvas.drawLine(a, b, corner);
      }
    }
  }

  @override
  bool shouldRepaint(_FramePainter old) =>
      old.frame != frame || old.circular != circular;
}
