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

  // ── 下面三条是"暗色整页死黑"事故的回归测试（2026-10-22）────────────────
  // ColorFilter.matrix 的输入与偏移都是 0..255。旧实现把归一化的 ink 当偏移，
  // 白纸算出来 ≈ -207 → 钳到 0 → 全黑；归一化口径的测试完全看不出来。

  test('矩阵作用在字节通道上：白纸 → 夜读纸色（不是黑）', () {
    final (double r, double g, double b) = NightTint.applyByte(255, 255, 255);
    expect(r.round(), channel(NightRgb.paper, 16));
    expect(g.round(), channel(NightRgb.paper, 8));
    expect(b.round(), channel(NightRgb.paper, 0));
    expect(r, greaterThan(8), reason: '纸色必须可见；0 就是"整页死黑"');
  });

  test('矩阵作用在字节通道上：黑字 → 暖白墨', () {
    final (double r, double g, double b) = NightTint.applyByte(0, 0, 0);
    expect(r.round(), channel(NightRgb.ink, 16));
    expect(g.round(), channel(NightRgb.ink, 8));
    expect(b.round(), channel(NightRgb.ink, 0));
    expect(r, greaterThan(200), reason: '黑字必须翻成亮墨，否则暗色下看不见字');
  });

  test('矩阵与归一化 apply 同源（两条路径只差通道尺度）', () {
    const double r = 0.3;
    const double g = 0.6;
    const double b = 0.9;
    final (double ar, double ag, double ab) = NightTint.apply(r, g, b);
    final (double br, double bg, double bb) = NightTint.applyByte(
      r * 255,
      g * 255,
      b * 255,
    );
    expect(br / 255, closeTo(ar, 1e-9));
    expect(bg / 255, closeTo(ag, 1e-9));
    expect(bb / 255, closeTo(ab, 1e-9));
  });
}
