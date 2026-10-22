import 'package:flutter_test/flutter_test.dart';
import 'package:shuaqi/domain/reader/night_tint.dart';

/// `NightTint` duotone 单测（宿主机秒级）。
///
/// 关键断言：白→纸、黑→墨、中间调单调且偏暖、矩阵与 apply 一致、
/// alpha 行恒等（夜读不能改变透明度，否则会露出阅读器底色）。
void main() {
  int channel(int argb, int shift) => (argb >> shift) & 0xFF;

  test('白纸映射到暖黑纸', () {
    final (double r, double g, double b) = NightTint.apply(1, 1, 1);
    expect((r * 255).round(), channel(NightRgb.paper, 16));
    expect((g * 255).round(), channel(NightRgb.paper, 8));
    expect((b * 255).round(), channel(NightRgb.paper, 0));
  });

  test('黑字映射到暖白墨', () {
    final (double r, double g, double b) = NightTint.apply(0, 0, 0);
    expect((r * 255).round(), channel(NightRgb.ink, 16));
    expect((g * 255).round(), channel(NightRgb.ink, 8));
    expect((b * 255).round(), channel(NightRgb.ink, 0));
  });

  test('中间灰是两端中点，且偏暖（R > B，延续浅色纸感的暖色基因）', () {
    final (double r, double g, double b) = NightTint.apply(0.5, 0.5, 0.5);
    expect(r, closeTo((NightTint.apply(0, 0, 0).$1 + NightTint.apply(1, 1, 1).$1) / 2, 1e-9));
    expect(r, greaterThan(b));
    expect(r, greaterThan(g));
    expect(g, greaterThan(b));
  });

  test('输入越亮输出越暗（duotone 翻转单调，文字对比度因此保住）', () {
    final double dark = NightTint.apply(0.15, 0.15, 0.15).$1;
    final double bright = NightTint.apply(0.85, 0.85, 0.85).$1;
    expect(bright, lessThan(dark));
  });

  test('彩色输入落回纸-墨之间，且保持暖偏（R > B）', () {
    // 红印章：亮度中低 → 映射为暖调中间灰（双色化），不发散、不变冷
    final (double r, double g, double b) = NightTint.apply(0.8, 0.1, 0.1);
    final double inkR = NightTint.apply(0, 0, 0).$1;
    final double paperR = NightTint.apply(1, 1, 1).$1;
    expect(r, lessThanOrEqualTo(inkR + 1e-9));
    expect(r, greaterThanOrEqualTo(paperR - 1e-9));
    expect(r, greaterThan(b));
    expect(g, greaterThan(b));
  });

  test('矩阵 20 参数，alpha 行恒等', () {
    expect(NightTint.matrix.length, 20);
    expect(NightTint.matrix[15], 0);
    expect(NightTint.matrix[16], 0);
    expect(NightTint.matrix[17], 0);
    expect(NightTint.matrix[18], 1);
    expect(NightTint.matrix[19], 0);
  });

  test('矩阵与 apply 数值一致（同一映射的两条路径）', () {
    const double r = 0.3;
    const double g = 0.6;
    const double b = 0.9;
    final (double ar, double ag, double ab) = NightTint.apply(r, g, b);
    final List<double> m = NightTint.matrix;
    expect(m[0] * r + m[1] * g + m[2] * b + m[4], closeTo(ar, 1e-9));
    expect(m[5] * r + m[6] * g + m[7] * b + m[9], closeTo(ag, 1e-9));
    expect(m[10] * r + m[11] * g + m[12] * b + m[14], closeTo(ab, 1e-9));
  });
}
