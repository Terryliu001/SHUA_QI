import 'package:flutter_test/flutter_test.dart';
import 'package:shuaqi/domain/reader/scroll_math.dart';

/// 轴向锁定（纯 Dart，宿主机秒级）。
///
/// 背景（2026-10-23，用户反馈"上下滑动有些迟钝"）：手指画不出直线，
/// 想竖滑时轨迹总有 10°–30° 的横向分量。旧实现两个分量都收下，
/// 横向那部分被夹紧/被橡皮筋弹回 → 主观就是"滑了很长距离只走了一点"。
/// 现在一次手势只认一个轴，且**偏向竖轴**（阅读器里竖滑是绝对主诉求）。
void main() {
  group('DragAxisLock.decide', () {
    test('位移太小先不判轴（避免抖动误判）', () {
      expect(DragAxisLock.decide(0, 0), isNull);
      expect(DragAxisLock.decide(3, 4), isNull); // 距离 5 < 6
      expect(DragAxisLock.decide(5, 5), isNull);
    });

    test('纯竖 / 纯横', () {
      expect(DragAxisLock.decide(0, 100), isTrue);
      expect(DragAxisLock.decide(0, -100), isTrue);
      expect(DragAxisLock.decide(100, 0), isFalse);
      expect(DragAxisLock.decide(-100, 0), isFalse);
    });

    test('斜着滑：偏 55° 以内都算竖滑（这是用户的实际手感）', () {
      // 26° 偏离：100 竖 + 50 横 → 竖
      expect(DragAxisLock.decide(50, 100), isTrue);
      // 35° 偏离：100 竖 + 70 横 → 仍算竖
      expect(DragAxisLock.decide(70, 100), isTrue);
      // 45°：100/100 → 按竖轴处理（阅读器里"手歪一点"远比"想横向平移"常见）
      expect(DragAxisLock.decide(100, 100), isTrue);
      // 60° 偏离（横向明显更多）→ 判横
      expect(DragAxisLock.decide(170, 100), isFalse);
      expect(DragAxisLock.decide(150, 60), isFalse);
    });

    test('横向推不动时直接锁竖轴（不用等阈值）', () {
      expect(DragAxisLock.decide(0, 0, allowHorizontal: false), isTrue);
      expect(DragAxisLock.decide(100, 0, allowHorizontal: false), isTrue);
      expect(DragAxisLock.decide(500, 10, allowHorizontal: false), isTrue);
    });
  });

  group('DragAxisLock.project', () {
    test('锁竖轴时丢弃横向分量（页面不再左右晃）', () {
      final (double dx, double dy) = DragAxisLock.project(
        120,
        -80,
        vertical: true,
      );
      expect(dx, 0);
      expect(dy, -80);
    });

    test('锁横轴时丢弃纵向分量', () {
      final (double dx, double dy) = DragAxisLock.project(
        120,
        -80,
        vertical: false,
      );
      expect(dx, 120);
      expect(dy, 0);
    });

    test('投影后竖滑位移与手指竖直位移 1:1（不被横向分量稀释）', () {
      // 手指走了 100 竖 + 100 横（斜线长 141），锁定竖轴后应得到完整 100 竖。
      final (double dx, double dy) = DragAxisLock.project(
        100,
        100,
        vertical: true,
      );
      expect(dx, 0);
      expect(dy, 100);
    });
  });

  group('ScrollMath.clampOffset（锁定轴收紧后仍要成立）', () {
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
