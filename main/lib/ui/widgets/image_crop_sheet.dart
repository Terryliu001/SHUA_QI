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
/// ## 交互
/// - 暗色遮罩 + 固定取景框：框里的部分就是要留下的；
/// - 单指拖动、双指缩放，**以手指为中心**；图始终盖住框，不会拖出空白；
/// - 底部缩放滑条 / 重置 / 「使用这张」；
/// - 取消不写任何东西。
///
/// ## 输出
/// 按 [CropKind.outWidth] × [CropKind.outHeight] 输出 PNG。
/// 封面的高由 `宽 / 比例` 算，不再写死正方形（横向封面会被压扁）。
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

class _CropPageState extends State<_CropPage> {
  ui.Image? _image;
  String? _error;

  // 缩放与平移自己管：显示矩形 = (offset, base * scale)。
  // 不依赖 InteractiveViewer 的矩阵语义，裁剪换算与显示矩形同一口径。
  double _scale = 1;
  Offset _offset = Offset.zero;

  /// 图片在视口里"scale = 1"时的尺寸（按 cover 铺满视口）。
  Size _base = Size.zero;

  /// 取景框在视口里的位置。
  Rect _frame = Rect.zero;

  Size _viewport = Size.zero;

  /// 本次布局是否已经初始化过缩放/平移。
  bool _layoutReady = false;

  double _minScale = 1;
  double _maxScale = 8;

  // 手势起点快照。
  double _startScale = 1;
  Offset _startOffset = Offset.zero;
  Offset _startFocal = Offset.zero;
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
                        ? () => _setScaleAround(
                            _frame.center,
                            (_scale / 1.25).clamp(_minScale, _maxScale),
                          )
                        : null,
                    icon: const Icon(
                      Icons.zoom_out,
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
                    onPressed: ready
                        ? () => _setScaleAround(
                            _frame.center,
                            (_scale * 1.25).clamp(_minScale, _maxScale),
                          )
                        : null,
                    icon: const Icon(
                      Icons.zoom_in,
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
              const SizedBox(height: 4),
              Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      '输出 ${widget.kind.outWidth} × ${widget.kind.outputHeight}',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: ShqScrim.foreground.withValues(alpha: 0.62),
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
        // 取景框：按比例，尽量占满视口（留边）。
        double frameW = viewport.width - 32;
        double frameH = frameW / widget.kind.aspectRatio;
        if (frameH > viewport.height - 32) {
          frameH = viewport.height - 32;
          frameW = frameH * widget.kind.aspectRatio;
        }
        final Rect frame = Rect.fromCenter(
          center: viewport.center(Offset.zero),
          width: frameW,
          height: frameH,
        );

        // 基础尺寸按 **cover** 铺满视口：图不会在框里露出空白。
        final double coverScale = math.max(
          viewport.width / image.width,
          viewport.height / image.height,
        );
        final Size base = Size(
          image.width * coverScale,
          image.height * coverScale,
        );
        final double minScale = math.max(
          frame.width / base.width,
          frame.height / base.height,
        );
        final double maxScale = math.max(8.0, minScale * 6);
        final bool layoutChanged =
            _viewport != viewport || _frame != frame || _base != base;
        _viewport = viewport;
        _frame = frame;
        _base = base;
        _minScale = minScale;
        _maxScale = maxScale;

        // 布局第一次就位 / 旋转 / 尺寸变化：把图放大到刚好填满取景框。
        // 这里在 build 里，不能 setState；直接赋值后本帧的 Transform 就生效。
        if (!_layoutReady || layoutChanged) {
          _layoutReady = true;
          _resetInternal();
        } else {
          _scale = _scale.clamp(_minScale, _maxScale);
          _offset = _clampOffset(_offset, _scale);
        }

        return Stack(
          children: <Widget>[
            Positioned.fill(
              child: Listener(
                behavior: HitTestBehavior.opaque,
                onPointerDown: _onPointerDown,
                onPointerMove: _onPointerMove,
                onPointerUp: _onPointerUp,
                onPointerCancel: _onPointerUp,
                child: Transform(
                  transform: Matrix4.identity()
                    ..translateByDouble(_offset.dx, _offset.dy, 0, 1)
                    ..scaleByDouble(_scale, _scale, 1, 1),
                  alignment: Alignment.topLeft,
                  child: SizedBox(
                    width: base.width,
                    height: base.height,
                    child: RawImage(image: image, fit: BoxFit.fill),
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
            // 提示语放在最上层：压在图上时图可能把它盖住（真机踩到）。
            Positioned(
              left: 0,
              right: 0,
              bottom: 12,
              child: IgnorePointer(
                child: Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: ShqSpace.md,
                      vertical: ShqSpace.xs,
                    ),
                    decoration: BoxDecoration(
                      color: ShqScrim.backdrop.withValues(alpha: 0.72),
                      borderRadius: BorderRadius.circular(ShqRadius.pill),
                    ),
                    child: Text(
                      '拖动或双指缩放，把要留下的部分放进框里',
                      style: Theme.of(context).textTheme.labelSmall
                          ?.copyWith(color: ShqScrim.foreground),
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
    _pointers[event.pointer] = event.localPosition;
    if (_pointers.length >= 2) {
      final List<Offset> pts = _pointers.values.toList();
      _startScale = _scale;
      _startOffset = _offset;
      _startFocal = (pts[0] + pts[1]) / 2;
      _pinchStartDistance = (pts[0] - pts[1]).distance;
      _startImagePoint = (_startFocal - _startOffset) / _startScale;
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
    setState(_resetInternal);
  }

  void _resetInternal() {
    _scale = _minScale;
    _offset = _clampOffset(
      Offset(
        _frame.center.dx - _base.width * _scale / 2,
        _frame.center.dy - _base.height * _scale / 2,
      ),
      _scale,
    );
  }

  void _setScaleAround(Offset focal, double nextScale) {
    final double scale = nextScale.clamp(_minScale, _maxScale);
    if ((scale - _scale).abs() < 0.0001) {
      return;
    }
    final Offset imagePoint = (focal - _offset) / _scale;
    final Offset nextOffset = focal - imagePoint * scale;
    setState(() {
      _scale = scale;
      _offset = _clampOffset(nextOffset, scale);
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
    canvas.drawImageRect(
      image,
      source,
      Rect.fromLTWH(
        0,
        0,
        widget.kind.outWidth.toDouble(),
        widget.kind.outputHeight.toDouble(),
      ),
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
      ..color = ShqScrim.backdrop.withValues(alpha: 0.58);
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
        ..color = ShqScrim.foreground.withValues(alpha: 0.28);
      for (int i = 1; i <= 2; i += 1) {
        final double x = frame.left + frame.width * i / 3;
        final double y = frame.top + frame.height * i / 3;
        canvas.drawLine(Offset(x, frame.top), Offset(x, frame.bottom), thin);
        canvas.drawLine(Offset(frame.left, y), Offset(frame.right, y), thin);
      }
    }

    final Paint border = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..color = ShqScrim.foreground;
    if (circular) {
      canvas.drawOval(frame, border);
    } else {
      canvas.drawRect(frame, border);
    }

    if (!circular) {
      // 四角短粗线：让"框在哪"更明确，同时不盖住内容。
      final Paint corner = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4
        ..strokeCap = StrokeCap.round
        ..color = ShqScrim.foreground;
      const double len = 18;
      final List<(Offset, Offset)> corners = <(Offset, Offset)>[
        (frame.topLeft, frame.topLeft + const Offset(len, 0)),
        (frame.topLeft, frame.topLeft + const Offset(0, len)),
        (frame.topRight, frame.topRight - const Offset(len, 0)),
        (frame.topRight, frame.topRight + const Offset(0, len)),
        (frame.bottomLeft, frame.bottomLeft + const Offset(len, 0)),
        (frame.bottomLeft, frame.bottomLeft - const Offset(0, len)),
        (frame.bottomRight, frame.bottomRight - const Offset(len, 0)),
        (frame.bottomRight, frame.bottomRight - const Offset(0, len)),
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
