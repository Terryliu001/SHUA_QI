import 'package:shuaqi/domain/reader/reader_prefs.dart';

/// 纸感颜色的**唯一来源**（RGB 以 0xRRGGBB 存成纯 int，domain 不允许碰 Flutter 的 Color）。
///
/// `ui/theme/tokens.dart` 里的 [ShqPaper] 从这里取值再包成 `Color`，
/// 这样"warm 到底是多少"只在一处定义，不会因为两处各写一遍而漂移。
abstract final class PaperRgb {
  static const int warm = 0xFFF6EFE3;
  static const int ivory = 0xFFF8F1DC;
  static const int gray = 0xFFF1F1EF;
  static const int green = 0xFFE9F1E7;

  /// [PaperStyle.original] 没有颜色，返回 null。
  ///
  /// [PaperStyle.night] 也返回 null：夜读不是"乘法染纸"（乘法只能把白纸压暗，
  /// 黑字会留在暗纸上变成 5:1 对比度），它走 `NightTint` 的 duotone 反色。
  static int? of(PaperStyle style) {
    switch (style) {
      case PaperStyle.warm:
        return warm;
      case PaperStyle.ivory:
        return ivory;
      case PaperStyle.gray:
        return gray;
      case PaperStyle.green:
        return green;
      case PaperStyle.original:
      case PaperStyle.night:
        return null;
    }
  }
}

/// 纸感**乘法**增益（纯数学，可单测）。
///
/// 为什么用乘法而不是半透明叠色：
/// - 叠色（`ColoredBox.withOpacity`）是"蒙一层"，黑字会跟着变灰，对比度下降；
/// - 乘法把"白 → 纸色、黑 → 黑"线性映射，文字保持墨色，只有白底被染成纸色，
///   这才是纸该有的样子，也是最能"让内容优先"的做法。
///
/// ```text
/// out_c = src_c × gain_c
/// gain_c = 1 - (1 - paper_c/255) × t      t = intensity/100
/// ```
class PaperTint {
  const PaperTint(this.r, this.g, this.b);

  /// 每通道增益，1.0 = 不变。
  final double r;
  final double g;
  final double b;

  static const PaperTint identity = PaperTint(1, 1, 1);

  bool get isIdentity => r == 1 && g == 1 && b == 1;

  static PaperTint forStyle(PaperStyle style, int intensity) {
    final int? rgb = PaperRgb.of(style);
    if (rgb == null) {
      return identity;
    }
    final double t = intensity.clamp(0, 100) / 100.0;
    double gain(int channel) => 1.0 - (1.0 - channel / 255.0) * t;
    return PaperTint(
      gain((rgb >> 16) & 0xFF),
      gain((rgb >> 8) & 0xFF),
      gain(rgb & 0xFF),
    );
  }
}
