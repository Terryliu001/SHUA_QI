import 'package:flutter_test/flutter_test.dart';
import 'package:shuaqi/domain/ink/ink_compress.dart';
import 'package:shuaqi/domain/ink/ink_doc.dart';

InkPoint _p(double x, double y, {double pressure = 0.5, int t = 0}) =>
    InkPoint(x: x, y: y, pressure: pressure, t: t);

/// `InkCompressor` 单测（宿主机秒级）。
///
/// 重点盯两条：**不够密的点被丢掉**（体积）与**末点必须补回**（笔画不短一截）。
void main() {
  group('add 最小间距过滤', () {
    test('第一个点永远保留', () {
      final InkCompressor c = InkCompressor();
      expect(c.add(_p(10, 10)), isTrue);
      expect(c.points.length, 1);
    });

    test('间距小于阈值被丢弃，大于阈值被保留', () {
      final InkCompressor c = InkCompressor(minDistancePt: 1);
      expect(c.add(_p(0, 0)), isTrue);
      expect(c.add(_p(0.2, 0)), isFalse); // 0.2 < 1
      expect(c.add(_p(1.5, 0)), isTrue); // 距 (0,0) 1.5 > 1
      expect(c.add(_p(1.6, 0)), isFalse); // 距 (1.5,0) 0.1 < 1
      expect(c.points.length, 2);
    });

    test('判定基于"最后一个保留点"，不是原始上一点（长斜线逐步收敛）', () {
      final InkCompressor c = InkCompressor(minDistancePt: 1);
      expect(c.add(_p(0, 0)), isTrue);
      // 沿 x 每步 +0.6：每步都 <1 被丢，但相对保留点的距离在累积
      expect(c.add(_p(0.6, 0)), isFalse); // 距 (0,0) 0.6
      expect(c.add(_p(1.2, 0)), isTrue); // 距 (0,0) 1.2 → 保留，基准前移
      expect(c.add(_p(1.8, 0)), isFalse); // 距 (1.2,0) 0.6
      expect(c.points.length, 2);
      expect(c.points.last.x, closeTo(1.2, 1e-9));
    });
  });

  group('finish 补回末点', () {
    test('末点与保留点距离可感知时强制补回（停笔那一下不丢）', () {
      final InkCompressor c = InkCompressor(minDistancePt: 1);
      c.add(_p(0, 0));
      c.add(_p(5, 0));
      // 停笔前最后一小段 0.6 < 1 会被 add 丢掉，finish 按 1/4 阈值补回
      expect(c.add(_p(5.6, 0)), isFalse);
      final List<InkPoint> result = c.finish(_p(5.6, 0));
      expect(result.length, 3);
      expect(result.last.x, closeTo(5.6, 1e-9));
    });

    test('末点与保留点几乎重合时不补（避免零长线段）', () {
      final InkCompressor c = InkCompressor(minDistancePt: 1);
      c.add(_p(0, 0));
      c.add(_p(5, 0));
      final List<InkPoint> result = c.finish(_p(5.02, 0));
      expect(result.length, 2);
    });

    test('单点笔画：点一下也是一个点，不当噪声丢', () {
      final InkCompressor c = InkCompressor();
      c.add(_p(3, 3));
      expect(c.finish(_p(3, 3)).length, 1);
    });
  });
}
