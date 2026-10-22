import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shuaqi/ui/reader/camera_viewport.dart';

/// `CameraViewport` 的结构不变量：**内容盒子必须保持整卷尺寸，命中区覆盖整卷**。
///
/// 这条不变量在 2026-10-22 的真机上被打破过：视口给的是紧约束，内容盒子被
/// `BoxConstraints.enforce` 压回视口高度，绘制照旧（`Clip.none`），但命中测试
/// `size.contains(position)` 全灭 —— 表现就是"滚动模式下只能写第一页上半屏"。
/// 下面第二组用例是那个事故的定点回归：内容坐标 y=2300 处必须能收到落笔。
void main() {
  const Size viewport = Size(800, 600); // flutter_test 默认画布
  const double contentHeight = 5000;

  int hits = 0;

  /// 一整卷：宽 = 视口宽，高 5000，其中 y∈[2000,4000] 有一块"纸"。
  Widget buildContent() {
    return SizedBox(
      width: viewport.width,
      height: contentHeight,
      child: Stack(
        clipBehavior: Clip.none,
        children: <Widget>[
          Positioned(
            left: 0,
            top: 2000,
            width: viewport.width,
            height: 2000,
            child: Listener(
              behavior: HitTestBehavior.opaque,
              onPointerDown: (PointerDownEvent _) => hits++,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> pumpWithCamera(WidgetTester tester, Camera camera) async {
    hits = 0;
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: CameraViewport(
          viewport: viewport,
          camera: ValueNotifier<Camera>(camera),
          content: buildContent(),
        ),
      ),
    );
  }

  Size contentBoxSize(WidgetTester tester) => tester.getSize(
    find.byWidgetPredicate(
      (Widget w) => w is SizedBox && w.height == contentHeight,
    ),
  );

  testWidgets('内容盒子保持整卷尺寸，不被视口紧约束压扁', (WidgetTester tester) async {
    await pumpWithCamera(tester, const Camera(Offset.zero, 1));
    expect(contentBoxSize(tester), const Size(800, contentHeight));
  });

  testWidgets('1 倍：内容 y=2300 处能收到落笔（事故回归点）', (WidgetTester tester) async {
    await pumpWithCamera(tester, const Camera(Offset(0, -2000), 1));
    final TestGesture gesture = await tester.startGesture(const Offset(400, 300));
    await tester.pump();
    await gesture.up();
    expect(hits, 1, reason: '屏幕 (400,300) → 内容 (400,2300)，必须命中');
  });

  testWidgets('2 倍：缩放后命中位置按矩阵换算，同样覆盖整卷', (WidgetTester tester) async {
    // 屏幕 (400,300) → 内容 ((400-0)/2, (300+4000)/2) = (200, 2150)
    await pumpWithCamera(tester, const Camera(Offset(0, -4000), 2));
    final TestGesture gesture = await tester.startGesture(const Offset(400, 300));
    await tester.pump();
    await gesture.up();
    expect(hits, 1);
  });

  testWidgets('内容之外（纸外）不产生命中，交给上层提示', (WidgetTester tester) async {
    // 内容高 5000，相机上移 4600 → 屏幕 y=500 对应内容 y=5100（纸外）
    await pumpWithCamera(tester, const Camera(Offset(0, -4600), 1));
    final TestGesture gesture = await tester.startGesture(const Offset(400, 500));
    await tester.pump();
    await gesture.up();
    expect(hits, 0);
  });

  testWidgets('相机变了只改矩阵：内容 widget 实例不变', (WidgetTester tester) async {
    final ValueNotifier<Camera> camera = ValueNotifier<Camera>(
      const Camera(Offset.zero, 1),
    );
    addTearDown(camera.dispose);
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: CameraViewport(
          viewport: viewport,
          camera: camera,
          content: buildContent(),
        ),
      ),
    );
    final Element before = tester.element(
      find.byWidgetPredicate(
        (Widget w) => w is SizedBox && w.height == contentHeight,
      ),
    );
    camera.value = const Camera(Offset(0, -500), 1);
    await tester.pump();
    final Element after = tester.element(
      find.byWidgetPredicate(
        (Widget w) => w is SizedBox && w.height == contentHeight,
      ),
    );
    expect(identical(before, after), isTrue, reason: '内容子树不该重建');
  });
}
