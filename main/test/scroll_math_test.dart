import 'package:flutter_test/flutter_test.dart';
import 'package:shuaqi/domain/reader/scroll_math.dart';

/// `ScrollMath` 纯函数单测（宿主机秒级，不碰真机）。
///
/// 覆盖滚动模式最易错的三处：A4/A3 混排的主可见页、夹紧边界、
/// 可见区间的 early-break 行为。
void main() {
  group('visibleRange', () {
    test('空布局返回 null', () {
      expect(
        ScrollMath.visibleRange(const <double>[], const <double>[], 0, 100),
        isNull,
      );
    });

    test('视口跨页时返回相交区间', () {
      final (int first, int last) =
          ScrollMath.visibleRange(const <double>[0, 300, 600], const <double>[
            300,
            300,
            300,
          ], 350, 650)!;
      expect(first, 1);
      expect(last, 2);
    });

    test('视口内只有一页', () {
      final (int first, int last) =
          ScrollMath.visibleRange(const <double>[0, 300, 600], const <double>[
            300,
            300,
            300,
          ], 100, 200)!;
      expect(first, 0);
      expect(last, 0);
    });

    test('整卷都在视口上方时跳过（early continue）', () {
      final (int first, int last) =
          ScrollMath.visibleRange(const <double>[0, 300, 600], const <double>[
            300,
            300,
            300,
          ], 400, 500)!;
      expect(first, 1);
      expect(last, 1);
    });

    test('可见区完全落在内容之外返回 null', () {
      expect(
        ScrollMath.visibleRange(const <double>[0, 300], const <double>[
          300,
          300,
        ], 1000, 1100),
        isNull,
      );
    });
  });

  group('mainVisiblePage', () {
    test('A4/A3 混排：按重叠高度判，而不是 offset / 页高', () {
      // 页 0 是 A3（高 1000），页 1 是 A4（高 500）
      const List<double> tops = <double>[0, 1000];
      const List<double> heights = <double>[1000, 500];

      // 视口 400..900：与页 0 重叠 500，页 1 还不相交
      expect(ScrollMath.mainVisiblePage(tops, heights, 400, 900), 0);

      // 视口 950..1400：页 0 只剩 50，页 1 重叠 400 → 页 1
      expect(ScrollMath.mainVisiblePage(tops, heights, 950, 1400), 1);
    });

    test('空列表返回 0（调用方保证非空）', () {
      expect(
        ScrollMath.mainVisiblePage(const <double>[], const <double>[], 0, 100),
        0,
      );
    });
  });

  group('clampOffset', () {
    test('内容窄于视口：横向居中、纵向顶端对齐', () {
      final (double x, double y) = ScrollMath.clampOffset(
        offsetX: 100,
        offsetY: -300,
        scale: 1,
        contentWidth: 800,
        contentHeight: 500,
        viewportWidth: 1200,
        viewportHeight: 800,
      );
      expect(x, 200); // (1200-800)/2
      expect(y, 0);
    });

    test('1 倍 = fit-width：横向正好铺满，不露黑边', () {
      final (double x, double y) = ScrollMath.clampOffset(
        offsetX: 999,
        offsetY: -50,
        scale: 1,
        contentWidth: 1200,
        contentHeight: 3000,
        viewportWidth: 1200,
        viewportHeight: 800,
      );
      expect(x, 0); // 内容正好等于视口宽 → 居中即铺满
      expect(y, -50); // 纵向是合法滚动位，原样保留
    });

    test('放大后横向夹紧，不许把内容推过头', () {
      // 2 倍：内容宽 2400 > 视口 1200 → x ∈ [-1200, 0]
      final (double x1, double y1) = ScrollMath.clampOffset(
        offsetX: 500,
        offsetY: 100,
        scale: 2,
        contentWidth: 1200,
        contentHeight: 3000,
        viewportWidth: 1200,
        viewportHeight: 800,
      );
      expect(x1, 0); // 正的偏移被夹回 0
      expect(y1, 0);

      final (double x2, double y2) = ScrollMath.clampOffset(
        offsetX: -5000,
        offsetY: -6000,
        scale: 2,
        contentWidth: 1200,
        contentHeight: 3000,
        viewportWidth: 1200,
        viewportHeight: 800,
      );
      expect(x2, -1200); // 过头被夹到最左
      expect(y2, -5200); // 6000 高的内容，最底 = 800-6000
    });
  });
}
