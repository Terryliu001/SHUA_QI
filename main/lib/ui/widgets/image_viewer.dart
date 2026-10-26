import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:shuaqi/ui/theme/tokens.dart';

/// 图片操作项（长按后浮窗里的一项）。
///
/// [onSelected] 返回一句**给用户看的结果**（如"已保存到相册"）；返回 null 表示
/// 不需要反馈。浮窗会先显示处理中，再显示这句话，然后自己收起。
class ImageAction {
  const ImageAction({
    required this.label,
    required this.icon,
    required this.onSelected,
    this.subtitle,
  });

  final String label;
  final String? subtitle;
  final IconData icon;
  final Future<String?> Function() onSelected;
}

/// 全屏图片查看器（2026-10-24 用户第 2 条：预览必须独立弹窗，尺寸比例不能错）。
///
/// 三条硬口径：
/// 1. **比例永远真实**：按图片真实宽高比 + "可用框"算显示尺寸，绝不拉伸；
/// 2. **长图不顶满**：高度受上限约束 → 自动缩窄并居中；**宽图占满横向**上限；
/// 3. **再点一下关掉**（回到面板原来的大小），双指可缩放拖动看细节，长按出侧边浮窗。
///
/// 为什么不用 `Dialog` 包 `InteractiveViewer`：`Dialog` 自带内边距与约束，
/// "可用框"变得不可预测，图片只能在里面再套 `FittedBox`，长图会被缩得很小；
/// 这里自己算尺寸，边界唯一、可解释。
Future<void> showImageViewer(
  BuildContext context, {
  required String title,
  required double aspectRatio,
  required Widget Function(BuildContext context, Size size) builder,
  List<ImageAction> actions = const <ImageAction>[],
}) {
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: '关闭图片',
    barrierColor: Colors.transparent,
    transitionDuration: ShqMotion.base,
    pageBuilder:
        (
          BuildContext context,
          Animation<double> animation,
          Animation<double> secondaryAnimation,
        ) => _ImageViewer(
          title: title,
          aspectRatio: aspectRatio,
          builder: builder,
          actions: actions,
        ),
    transitionBuilder:
        (
          BuildContext context,
          Animation<double> animation,
          Animation<double> secondaryAnimation,
          Widget child,
        ) {
          final Animation<double> fade = CurvedAnimation(
            parent: animation,
            curve: ShqMotion.curveStandard,
            reverseCurve: ShqMotion.curveExit,
          );
          return FadeTransition(
            opacity: fade,
            child: ScaleTransition(
              // 从 0.96 起：只是"浮起来"，不做花哨缩放入场。
              scale: Tween<double>(begin: 0.96, end: 1).animate(fade),
              child: child,
            ),
          );
        },
  );
}

class _ImageViewer extends StatefulWidget {
  const _ImageViewer({
    required this.title,
    required this.aspectRatio,
    required this.builder,
    required this.actions,
  });

  final String title;
  final double aspectRatio;
  final Widget Function(BuildContext context, Size size) builder;
  final List<ImageAction> actions;

  @override
  State<_ImageViewer> createState() => _ImageViewerState();
}

class _ImageViewerState extends State<_ImageViewer> {
  final TransformationController _zoom = TransformationController();
  final GlobalKey _imageKey = GlobalKey();
  double _scale = 1;

  @override
  void initState() {
    super.initState();
    _zoom.addListener(_onZoom);
  }

  @override
  void dispose() {
    _zoom
      ..removeListener(_onZoom)
      ..dispose();
    super.dispose();
  }

  void _onZoom() {
    final double next = _zoom.value.getMaxScaleOnAxis();
    if ((next - _scale).abs() > 0.01) {
      setState(() => _scale = next);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool hasActions = widget.actions.isNotEmpty;
    // 用不透明的 Scaffold 而不是 Material(transparency) + ColoredBox：
    // 后者的背景在 `showGeneralDialog` 里没有铺满（实测遮罩缺失、标题与阅读器顶栏重叠），
    // Scaffold 一定铺满整屏，且 AppBar 自带状态栏内边距。
    return Scaffold(
      backgroundColor: ShqScrim.backdrop,
      // 不用 AppBar：它的背景恒为"透明→下层透出"，遮罩做到 97% 时仍能看到下面
      // 阅读器顶栏的白色图标轮廓（真机实测"两页叠在一起"）。改成 body 内自绘一行标题，
      // 背景就完全由 Scaffold 的遮罩色决定，一处颜色、一处边界。
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(
                ShqSpace.lg,
                ShqSpace.xs,
                ShqSpace.xs,
                ShqSpace.xs,
              ),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      widget.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelLarge?.copyWith(
                        color: ShqScrim.foreground,
                      ),
                    ),
                  ),
                  if (_scale > 1.01)
                    Padding(
                      padding: const EdgeInsets.only(right: ShqSpace.sm),
                      child: Text(
                        '${(_scale * 100).round()}%',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: ShqScrim.foregroundMuted,
                        ),
                      ),
                    ),
                  IconButton(
                    tooltip: '关闭',
                    onPressed: () => Navigator.of(context).maybePop(),
                    icon: const Icon(Icons.close),
                    color: ShqScrim.foreground,
                  ),
                ],
              ),
            ),
            Expanded(
              child: Stack(
                children: <Widget>[
                  Positioned.fill(
                    child: GestureDetector(
                      // 再点一下 = 回到面板原来的大小（用户原话）。
                      onTap: () => Navigator.of(context).maybePop(),
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(
                          ShqSpace.xl,
                          ShqSpace.md,
                          ShqSpace.xl,
                          ShqSpace.md,
                        ),
                        child: LayoutBuilder(
                          builder: (BuildContext context, BoxConstraints c) {
                            final Size size = _fitted(c.maxWidth, c.maxHeight);
                            return Center(
                              child: SizedBox(
                                key: _imageKey,
                                width: size.width,
                                height: size.height,
                                child: GestureDetector(
                                  behavior: HitTestBehavior.opaque,
                                  onTap: () => Navigator.of(context).maybePop(),
                                  onLongPress: hasActions
                                      ? () => _openActions(context)
                                      : null,
                                  child: InteractiveViewer(
                                    transformationController: _zoom,
                                    minScale: 1,
                                    maxScale: 5,
                                    // 只有放大后才允许单指拖动：否则和"点一下关闭"打架。
                                    panEnabled: _scale > 1.01,
                                    boundaryMargin: const EdgeInsets.all(48),
                                    child: widget.builder(context, size),
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    ),
                  ),
                  if (hasActions)
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: ShqSpace.xs,
                      child: IgnorePointer(
                        child: Text(
                          '双指缩放看细节 · 长按保存',
                          textAlign: TextAlign.center,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: ShqScrim.foregroundMuted,
                            fontSize: ShqType.caption,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 按真实宽高比把图片装进可用框：高度受限 → 缩窄居中；宽度受限 → 占满横向。
  Size _fitted(double maxWidth, double maxHeight) {
    final double aspect =
        widget.aspectRatio.isFinite && widget.aspectRatio > 0.05
        ? widget.aspectRatio
        : 1;
    if (maxWidth <= 0 || maxHeight <= 0) {
      return const Size(1, 1);
    }
    if (maxWidth / maxHeight > aspect) {
      final double height = maxHeight;
      return Size(height * aspect, height);
    }
    final double width = maxWidth;
    return Size(width, width / aspect);
  }

  void _openActions(BuildContext context) {
    final RenderBox? box =
        _imageKey.currentContext?.findRenderObject() as RenderBox?;
    final Offset anchor = box == null
        ? Offset(MediaQuery.sizeOf(context).width, 80)
        : box.localToGlobal(Offset(box.size.width, 0));
    unawaited(
      showImageActions(context, anchor: anchor, actions: widget.actions),
    );
  }
}

/// 长按图片后的**侧边浮窗**（2026-10-24 用户第 7 条：长按不要直接保存，
/// 要贴着图片给一个浮窗，把"存哪一种 / 存好了没有"说清楚）。
///
/// 位置固定在屏幕右侧、与 [anchor] 垂直对齐 —— 手指按在图上，眼睛不用来回找。
/// 点空白处关闭；执行动作时就地显示"处理中 → 已保存"，不弹 SnackBar。
Future<void> showImageActions(
  BuildContext context, {
  required Offset anchor,
  required List<ImageAction> actions,
}) {
  if (actions.isEmpty) {
    return Future<void>.value();
  }
  final OverlayState overlay = Overlay.of(context, rootOverlay: true);
  final Completer<void> done = Completer<void>();
  late OverlayEntry entry;
  entry = OverlayEntry(
    builder: (BuildContext context) => _ImageActionLayer(
      anchor: anchor,
      actions: actions,
      onClosed: () {
        if (entry.mounted) {
          entry.remove();
        }
        if (!done.isCompleted) {
          done.complete();
        }
      },
    ),
  );
  overlay.insert(entry);
  return done.future;
}

class _ImageActionLayer extends StatefulWidget {
  const _ImageActionLayer({
    required this.anchor,
    required this.actions,
    required this.onClosed,
  });

  final Offset anchor;
  final List<ImageAction> actions;
  final VoidCallback onClosed;

  @override
  State<_ImageActionLayer> createState() => _ImageActionLayerState();
}

class _ImageActionLayerState extends State<_ImageActionLayer> {
  int? _busy;
  String? _result;
  bool _failed = false;
  Timer? _closeTimer;

  @override
  void dispose() {
    _closeTimer?.cancel();
    super.dispose();
  }

  Future<void> _run(int index) async {
    if (_busy != null) {
      return;
    }
    setState(() => _busy = index);
    String? message;
    bool failed = false;
    try {
      message = await widget.actions[index].onSelected();
    } on Object catch (error) {
      message = '保存失败：$error';
      failed = true;
    }
    if (!mounted) {
      return;
    }
    setState(() {
      _busy = null;
      _result = message ?? '完成';
      _failed = failed;
    });
    _closeTimer = Timer(const Duration(milliseconds: 1400), () {
      if (mounted) {
        widget.onClosed();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final Size screen = MediaQuery.sizeOf(context);
    const double width = 212;
    const double margin = ShqSpace.lg;
    const double estimatedHeight = 132;
    final double top = (widget.anchor.dy - 24).clamp(
      margin + 24,
      math.max(margin + 24, screen.height - margin - estimatedHeight),
    );
    return Stack(
      children: <Widget>[
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onClosed,
            child: const ColoredBox(color: ShqScrim.backdropSoft),
          ),
        ),
        Positioned(
          right: margin,
          top: top,
          width: width,
          child: TweenAnimationBuilder<double>(
            tween: Tween<double>(begin: 0, end: 1),
            duration: ShqMotion.fast,
            curve: ShqMotion.curveStandard,
            builder: (BuildContext context, double t, Widget? child) => Opacity(
              opacity: t,
              child: Transform.translate(
                offset: Offset(12 * (1 - t), 0),
                child: child,
              ),
            ),
            child: Material(
              elevation: 8,
              color: scheme.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(ShqRadius.md),
              clipBehavior: Clip.antiAlias,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: ShqSpace.xs),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    if (_result != null)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(
                          ShqSpace.md,
                          ShqSpace.sm,
                          ShqSpace.md,
                          ShqSpace.sm,
                        ),
                        child: Row(
                          children: <Widget>[
                            Icon(
                              _failed
                                  ? Icons.error_outline
                                  : Icons.check_circle_outline,
                              size: 16,
                              color: _failed ? scheme.error : scheme.primary,
                            ),
                            const SizedBox(width: ShqSpace.sm),
                            Expanded(
                              child: Text(
                                _result!,
                                style: theme.textTheme.labelMedium,
                              ),
                            ),
                          ],
                        ),
                      )
                    else
                      for (int i = 0; i < widget.actions.length; i++)
                        _ActionRow(
                          action: widget.actions[i],
                          busy: _busy == i,
                          onTap: () => unawaited(_run(i)),
                        ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _ActionRow extends StatelessWidget {
  const _ActionRow({
    required this.action,
    required this.busy,
    required this.onTap,
  });

  final ImageAction action;
  final bool busy;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    return InkWell(
      onTap: busy ? null : onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: ShqSpace.md,
          vertical: ShqSpace.sm,
        ),
        child: Row(
          children: <Widget>[
            if (busy)
              const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else
              Icon(action.icon, size: 18, color: scheme.onSurfaceVariant),
            const SizedBox(width: ShqSpace.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(action.label, style: theme.textTheme.labelLarge),
                  if (action.subtitle != null)
                    Text(
                      action.subtitle!,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: scheme.outline,
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
