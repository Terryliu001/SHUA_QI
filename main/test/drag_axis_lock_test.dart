import 'package:flutter_test/flutter_test.dart';
import 'package:shuaqi/domain/reader/scroll_math.dart';

/// 连续滚动的拖动轴（纯 Dart，宿主机秒级）。
///
/// 2026-10-23 第二轮用户口径："上下、左右都要能滑，也要能斜着滑"。
/// 规则按**可滚方向**决定，而不是按手指角度猜：
/// - 横竖都可滚 → free（斜向 1:1）；
/// - 只有单轴可滚 → 锁那一轴（避免另一轴被夹紧吃掉，造成"滑了没走"）。
void main() {
  group('DragAxisLock.decide', () {
    test('横竖都有余量 → 自由二维平移（可斜滑）', () {
      expect(
        DragAxisLock.decide(allowHorizontal: true, allowVertical: true),
        DragAxis.free,
      );
    });

    test('只有竖能滚 → 竖轴（默认阅读场景）', () {
      expect(
        DragAxisLock.decide(allowHorizontal: false, allowVertical: true),
        DragAxis.vertical,
      );
    });

    test('只有横能滚 → 横轴（很矮的页面/特殊版式）', () {
      expect(
        DragAxisLock.decide(allowHorizontal: true, allowVertical: false),
        DragAxis.horizontal,
      );
    });

    test('两轴都不能滚 → 仍返回竖轴（没有位移，方向无意义）', () {
      expect(
        DragAxisLock.decide(allowHorizontal: false, allowVertical: false),
        DragAxis.vertical,
      );
    });
  });

  group('DragAxisLock.project', () {
    test('自由模式：两个分量都保留（斜滑核心）', () {
      final (double dx, double dy) = DragAxisLock.project(
        120,
        -80,
        axis: DragAxis.free,
      );
      expect(dx, 120);
      expect(dy, -80);
    });

    test('锁竖轴：丢弃横向分量（页面不再左右晃）', () {
      final (double dx, double dy) = DragAxisLock.project(
        120,
        -80,
        axis: DragAxis.vertical,
      );
      expect(dx, 0);
      expect(dy, -80);
    });

    test('锁横轴：丢弃纵向分量', () {
      final (double dx, double dy) = DragAxisLock.project(
        120,
        -80,
        axis: DragAxis.horizontal,
      );
      expect(dx, 120);
      expect(dy, 0);
    });

    test('单轴投影后竖滑位移与手指竖直位移 1:1', () {
      final (double dx, double dy) = DragAxisLock.project(
        100,
        100,
        axis: DragAxis.vertical,
      );
      expect(dx, 0);
      expect(dy, 100);
    });
  });

  group('ScrollMath.clampOffset（自由模式仍要正确夹紧）', () {
    test('内容宽高都大于视口 → 两轴都夹在可视范围', () {
      final (double x, double y) = ScrollMath.clampOffset(
        offsetX: -999,
        offsetY: -1e6,
        scale: 2,
        contentWidth: 595,
        contentHeight: 842 * 4,
        viewportWidth: 848,
        viewportHeight: 1200,
      );
      expect(x, 848 - 595 * 2);
      expect(y, 1200 - 842 * 4 * 2);
    });

    test('内容窄于视口 → 横向居中；内容高 → 纵向夹紧', () {
      final (double x, double y) = ScrollMath.clampOffset(
        offsetX: -999,
        offsetY: -1e6,
        scale: 0.86,
        contentWidth: 595,
        contentHeight: 842 * 4,
        viewportWidth: 848,
        viewportHeight: 1200,
      );
      expect(x, closeTo((848 - 595 * 0.86) / 2, 0.01));
      expect(y, 1200 - 842 * 4 * 0.86);
    });
  });
}
