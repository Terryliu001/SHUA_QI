import 'package:flutter_test/flutter_test.dart';
import 'package:shuaqi/domain/reader/paper_tint.dart';
import 'package:shuaqi/domain/reader/reader_prefs.dart';

void main() {
  group('PaperTint（乘法纸感）', () {
    test('original 恒为恒等（零处理，可信基线）', () {
      for (final int intensity in <int>[0, 30, 55, 100]) {
        final PaperTint tint = PaperTint.forStyle(PaperStyle.original, intensity);
        expect(tint.isIdentity, isTrue);
      }
    });

    test('强度 0 = 恒等（任何样式都不变色）', () {
      for (final PaperStyle style in PaperStyle.values) {
        expect(PaperTint.forStyle(style, 0).isIdentity, isTrue);
      }
    });

    test('强度 100 = 白底完全变成纸色，黑字保持黑', () {
      final PaperTint warm = PaperTint.forStyle(PaperStyle.warm, 100);
      // 白(255) × gain = 纸色通道；黑(0) × gain = 0
      expect((255 * warm.r).round(), (PaperRgb.warm >> 16) & 0xFF);
      expect((255 * warm.g).round(), (PaperRgb.warm >> 8) & 0xFF);
      expect((255 * warm.b).round(), PaperRgb.warm & 0xFF);
    });

    test('强度越高增益越小（纸感越重），且在 (0,1] 区间内单调', () {
      final PaperTint low = PaperTint.forStyle(PaperStyle.green, 20);
      final PaperTint high = PaperTint.forStyle(PaperStyle.green, 80);
      expect(high.r, lessThan(low.r));
      expect(high.g, lessThan(low.g));
      expect(high.b, lessThan(low.b));
      // 增益不会落到 0 以下（不会把白底染成负值）
      expect(high.r, greaterThan(0));
    });

    test('强度越界被收敛到 0..100，不抛异常', () {
      expect(PaperTint.forStyle(PaperStyle.warm, -5).isIdentity, isTrue);
      final PaperTint maxed = PaperTint.forStyle(PaperStyle.warm, 500);
      final PaperTint full = PaperTint.forStyle(PaperStyle.warm, 100);
      expect(maxed.r, closeTo(full.r, 1e-9));
    });
  });
}
