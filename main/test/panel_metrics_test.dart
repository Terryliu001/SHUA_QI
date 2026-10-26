import 'package:flutter_test/flutter_test.dart';
import 'package:shuaqi/domain/reader/panel_metrics.dart';

/// 面板宽度几何（2026-10-24 A1）：默认值、上下限、越界收敛。
///
/// 只测纯函数——真正"拖动是否掉帧"要在真机上量，宿主机测不出来。
void main() {
  group('PanelMetrics.defaultFor', () {
    test('宽屏（>=760dp）默认 320', () {
      expect(PanelMetrics.defaultFor(1200), PanelMetrics.minWidth);
      expect(PanelMetrics.defaultFor(760), PanelMetrics.minWidth);
    });

    test('窄屏按 42% 屏宽', () {
      expect(PanelMetrics.defaultFor(600), closeTo(252, 0.01));
    });
  });

  group('PanelMetrics.clampWidth', () {
    test('小于下限 → 抬到下限', () {
      expect(PanelMetrics.clampWidth(120, 1200), 320);
    });

    test('不超过横向屏幕的一半', () {
      expect(PanelMetrics.clampWidth(900, 1200), 600);
      expect(PanelMetrics.clampWidth(600, 1200), 600, reason: '正好一半是允许的');
    });

    test('区间内的值原样保留', () {
      expect(PanelMetrics.clampWidth(420, 1200), 420);
    });

    test('窄屏下下限是 42%、上限是 50%', () {
      expect(PanelMetrics.clampWidth(100, 700), closeTo(294, 0.01));
      expect(PanelMetrics.clampWidth(999, 700), closeTo(350, 0.01));
    });

    test('屏幕宽度非法时不返回负数', () {
      expect(PanelMetrics.clampWidth(400, 0), PanelMetrics.minWidth);
      expect(PanelMetrics.clampWidth(400, -100), PanelMetrics.minWidth);
    });
  });
}
