import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';

/// 相机：把"内容坐标系"（整卷拼起来的那张长纸）映射到视口。
///
/// `offset` 是内容原点在视口里的位置（负值 = 内容向上/向左移出去），
/// `scale` 是放大倍率。**只有这一个可变状态**：手势与甩动每帧只改它。
@immutable
class Camera {
  const Camera(this.offset, this.scale);

  final Offset offset;
  final double scale;

  @override
  bool operator ==(Object other) =>
      other is Camera && other.offset == offset && other.scale == scale;

  @override
  int get hashCode => Object.hash(offset, scale);

  @override
  String toString() => 'Camera($offset ×$scale)';
}

/// 相机视口：`SizedBox(视口) > ClipRect > Stack > Positioned > Transform > 内容`。
///
/// ## 为什么不是 `ClipRect > Transform > 内容`（2026-10-22 真机 bug 的根因）
///
/// 视口必须撑满父级（否则裁剪边界会退化成内容宽度，见项目日志 015），
/// 于是 `SizedBox(视口)` 给下面的是**紧约束**。紧约束沿着代理链一路传下去，
/// `SizedBox(整卷高)` 里的内容尺寸会被 `BoxConstraints.enforce` **压回视口高度**：
///
/// ```text
/// 内容要 848 × 12000，父级给 848 × 1050 的紧约束 → 实际 848 × 1050
/// ```
///
/// 绘制不受影响（`Stack` 的 `clipBehavior: Clip.none` 照样把页面画在
/// `Positioned.top` 上），但**命中测试被这 1050 卡住了**：
/// `RenderBox.hitTest` 第一件事就是 `size.contains(position)`，
/// 内容坐标 y > 1050 的落笔全部被丢弃 —— 表现为"滚动模式下只能写第一页上半屏，
/// 后面的页面看得到、写不上"。这一点用宿主机 widget 测试量过：
/// 内容盒 5000 被压成 600（默认画布高），远处落笔命中 0 次。
///
/// 修法：让 `Transform` 自己就是"整卷尺寸"，再把它放进一个视口尺寸的 `Stack`。
/// `Positioned` 只给 `left/top`（不给 `width/height`）时，子节点拿到的是
/// **无界约束**，内容盒子因此保持整卷尺寸；`Stack` 自己是视口尺寸，
/// 指针位置永远落在它内部 → 命中链一路走到内容坐标系里的正确位置。
/// 裁剪交给外层 `ClipRect`（只裁显示，不裁命中范围——这正是要的）。
///
/// 回归测试：`test/camera_viewport_test.dart`。
class CameraViewport extends StatelessWidget {
  const CameraViewport({
    super.key,
    required this.viewport,
    required this.camera,
    required this.content,
  });

  /// 视口尺寸（逻辑像素）。本 widget 会撑满它。
  final Size viewport;

  /// 唯一的相机状态源。只重建 `Transform` 一个 renderObject，元素树不动。
  final ValueListenable<Camera> camera;

  /// 内容坐标系里的整卷（宽 = 视口宽，高 = 各页高度之和 + 页间距）。
  final Widget content;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: viewport.width,
      height: viewport.height,
      child: ClipRect(
        child: Stack(
          clipBehavior: Clip.none,
          children: <Widget>[
            Positioned(
              left: 0,
              top: 0,
              // 只给 left/top：**故意**不给 width/height，让子节点拿到无界约束，
              // 内容盒子才能保持整卷尺寸（命中测试才覆盖整卷）。见类注释。
              child: ValueListenableBuilder<Camera>(
                valueListenable: camera,
                builder: (BuildContext context, Camera cam, Widget? child) {
                  return Transform(
                    alignment: Alignment.topLeft,
                    transform: Matrix4.identity()
                      ..translateByDouble(cam.offset.dx, cam.offset.dy, 0, 1)
                      ..scaleByDouble(cam.scale, cam.scale, 1, 1),
                    child: child,
                  );
                },
                child: content,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
