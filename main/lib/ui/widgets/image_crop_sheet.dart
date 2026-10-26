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
/// 而"取景框 + 缩放平移"这件事用 `InteractiveViewer` + 一次
/// `drawImageRect` 就能做出来，还不用引原生代码。
///
/// ## 交互
/// - 暗色遮罩 + 中间一个**固定取景框**：框里的部分就是要留下的；
/// - 图可以拖动、双指缩放（框不动，图在框下滑）；
/// - 「取消 / 使用这张」两个按钮，取消不写任何东西。
///
/// ## 输出
/// 按 [outWidth] × [outHeight] 输出 PNG（等比取景框，比例由调用方给）。
class CropKind {
  const CropKind({
    required this.title,
    required this.aspectRatio,
    required this.outWidth,
    required this.outHeight,
  });

  /// 头像：正方形。
  const CropKind.avatar()
    : title = '裁剪头像',
      aspectRatio = 1,
      outWidth = 512,
      outHeight = 512;

  /// 封面：横幅。比例由调用方按页首实宽算（`宽 / 230`）。
  const CropKind.cover({required this.aspectRatio})
    : title = '裁剪封面',
      outWidth = 1600,
      outHeight = 1600;

  final String title;

  /// 取景框的宽 / 高。
  final double aspectRatio;

  final int outWidth;
  final int outHeight;
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

  // 缩放与平移**自己管**：InteractiveViewer 的矩阵 API 在新版 vector_math 里
  // 语义变了（translateByDouble 会把已缩放的矩阵再乘一遍），算出来的变换不对；
  // 自己算反而更直白：显示矩形 = (offset, base * scale)。
  double _scale = 1;
  Offset _offset = Offset.zero;

  /// 手势开始时的快照（缩放起点 / 平移起点 / 手指位置）。
  double _startScale = 1;
  Offset _startOffset = Offset.zero;
  Offset _startFocal = Offset.zero;
  String? _error;

  /// 图片在视口里的**基础尺寸**（未缩放时）。
  Size _base = Size.zero;

  /// 取景框在视口里的位置（build 时算好，确认时直接用——避免两处算不一致）。
  Rect _frame = Rect.zero;

  /// 初始变换（把图放大到**填满取景框**）是否已设置过。
  bool _initialised = false;

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
      setState(() => _image = frame.image);
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
              child: Text(
                _error!,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: ShqScrim.foreground,
                ),
              ),
            )
          : image == null
          ? const Center(child: CircularProgressIndicator())
          : _cropArea(image),
      bottomNavigationBar: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.all(ShqSpace.md),
          child: FilledButton.icon(
            onPressed: image == null ? null : () => _confirm(image),
            icon: const Icon(Icons.check, size: 18),
            label: const Text('使用这张'),
            style: FilledButton.styleFrom(
              minimumSize: const Size(0, 48),
              backgroundColor: scheme.primary,
              foregroundColor: scheme.onPrimary,
            ),
          ),
        ),
      ),
    );
  }

  Widget _cropArea(ui.Image image) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final Size viewport = Size(constraints.maxWidth, constraints.maxHeight);
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
        _frame = frame;
        // 图片的基础尺寸：等比缩到能放进视口。
        final double scaleBase = _fitScale(image, viewport);
        final Size base = Size(
          image.width.toDouble() * scaleBase,
          image.height.toDouble() * scaleBase,
        );
        _base = base;
        // 初始就把图放大到**填满取景框**（cover）：否则用户看到的框里
        // 大半是遮罩，裁出来是一张很小的图。
        _applyInitialTransform(frame, base);
        return Stack(
          children: <Widget>[
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onScaleStart: (ScaleStartDetails details) {
                  _startScale = _scale;
                  _startOffset = _offset;
                  _startFocal = details.localFocalPoint;
                },
                onScaleUpdate: (ScaleUpdateDetails details) {
                  setState(() {
                    _scale = (_startScale * details.scale).clamp(0.5, 8);
                    _offset =
                        _startOffset +
                        (details.localFocalPoint - _startFocal);
                  });
                },
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
            // 取景框 + 四周遮罩。
            Positioned.fill(child: CustomPaint(painter: _FramePainter(frame))),
            // 提示语放在**最上层**：压在图上时图可能把它盖住（真机踩到）。
            Positioned(
              left: 0,
              right: 0,
              bottom: 12,
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: ShqSpace.md,
                    vertical: ShqSpace.xs,
                  ),
                  decoration: BoxDecoration(
                    color: ShqScrim.backdrop.withValues(alpha: 0.62),
                    borderRadius: BorderRadius.circular(ShqRadius.pill),
                  ),
                  child: Text(
                    '拖动或双指缩放，把要留下的部分放进框里',
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: ShqScrim.foreground,
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

  /// 把图缩放到**刚好填满取景框**，并让图心与框心重合。
  void _applyInitialTransform(Rect frame, Size base) {
    if (_initialised || base.width <= 0 || base.height <= 0) {
      return;
    }
    _initialised = true;
    final double scale = math.max(
      frame.width / base.width,
      frame.height / base.height,
    );
    // 直接赋值（**不能 setState**：这里在 build 里）。
    // 后面的 Transform 就是用这两个新值构造的，所以这一帧就生效。
    _scale = scale;
    _offset = Offset(
      frame.center.dx - base.width * scale / 2,
      frame.center.dy - base.height * scale / 2,
    );
  }

  static double _fitScale(ui.Image image, Size viewport) {
    if (image.width <= 0 || image.height <= 0) {
      return 1;
    }
    final double sx = viewport.width / image.width;
    final double sy = viewport.height / image.height;
    return sx < sy ? sx : sy;
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
    final double sx = ((frame.left - displayed.left) / displayed.width) *
        image.width;
    final double sy = ((frame.top - displayed.top) / displayed.height) *
        image.height;
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
        widget.kind.outHeight.toDouble(),
      ),
      Paint(),
    );
    final ui.Picture picture = recorder.endRecording();
    final ui.Image out = await picture.toImage(
      widget.kind.outWidth,
      widget.kind.outHeight,
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

/// 取景框画笔：框内不遮，框外压暗。
class _FramePainter extends CustomPainter {
  const _FramePainter(this.frame);

  final Rect frame;

  @override
  void paint(Canvas canvas, Size size) {
    final Paint shade = Paint()..color = ShqScrim.backdrop.withValues(alpha: 0.55);
    final Path outside = Path()
      ..addRect(Offset.zero & size)
      ..addRRect(RRect.fromRectAndRadius(frame, const Radius.circular(8)))
      ..fillType = PathFillType.evenOdd;
    canvas.drawPath(outside, shade);
    final Paint border = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..color = ShqScrim.foreground;
    canvas.drawRRect(
      RRect.fromRectAndRadius(frame, const Radius.circular(8)),
      border,
    );
  }

  @override
  bool shouldRepaint(_FramePainter old) => old.frame != frame;
}
