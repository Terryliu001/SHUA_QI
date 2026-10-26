/// 色系（2026-10-26 用户："设置里主题下面加一行色系选择，现在这版保留，再加几个选项"）。
///
/// ## 色系只管"强调色"
/// 强调色 = 可点的东西（主按钮 / 选中态 / 链接 / 开关 / 导航指示）。
/// 它**不碰**三样东西：
/// 1. 界面灰阶（`ShqLight` / `ShqDark` 的表面阶梯、描边）——那是"暖白纸感 +
///    冷灰骨架"的基因，换色不该把它一起换掉；
/// 2. 判题三态色（对 / 存疑 / 错）与切题框色——语义色，换色会让用户误读；
/// 3. 记录页热力图的绿色阶。
///
/// ## 为什么浅色靠种子派生、深色手写
/// 浅色的 primary / container 全部由 [seedArgb] 经 Material 3（tonalSpot）
/// 派生：同一色系内的深浅自动和谐，也省得手调一堆十六进制。
/// 深色的 primary 族**手写**：fromSeed 的暗色主色偏紫灰，与手调的冷灰骨架
/// 不搭（同一原因见 `app_theme.dart` 顶部注释），而且暗色下强调色必须够亮
/// 才看得见，亮度得自己定。
///
/// ## 淡雅口径（用户 2026-10-26："颜色都有点艳了，可以淡雅一点"）
/// 种子一律取**低饱和**（chroma 20–40）的中明度色，落到浅色主题就是
/// 现在的 `#465D91` 那一档哑色，不会出现"荧光按钮"。
enum ShqAccent {
  /// 默认，与 2026-10-24 定稿的色系完全一致（深色值原样保留）。
  azure(
    label: '靛蓝',
    hint: '默认 · 冷静清晰',
    seedArgb: 0xFF1F6FEB,
    darkPrimaryArgb: 0xFF8CB8F4,
    darkOnPrimaryArgb: 0xFF0A2A52,
    darkPrimaryContainerArgb: 0xFF204470,
    darkOnPrimaryContainerArgb: 0xFFD4E3FB,
  ),

  /// 青瓷：偏青的绿，清透但不抢眼。
  celadon(
    label: '青瓷',
    hint: '清新 · 克制',
    seedArgb: 0xFF3D7E74,
    darkPrimaryArgb: 0xFF9ACBC2,
    darkOnPrimaryArgb: 0xFF08302A,
    darkPrimaryContainerArgb: 0xFF1C443C,
    darkOnPrimaryContainerArgb: 0xFFCFE7E1,
  ),

  /// 紫藤：低饱和的紫，文艺、安静。
  iris(
    label: '紫藤',
    hint: '柔和 · 文艺',
    seedArgb: 0xFF6F639C,
    darkPrimaryArgb: 0xFFC3B8E2,
    darkOnPrimaryArgb: 0xFF241C4A,
    darkPrimaryContainerArgb: 0xFF37305C,
    darkOnPrimaryContainerArgb: 0xFFE3DEF4,
  ),

  /// 赭陶：暖砖色，和纸感最贴。
  clay(
    label: '赭陶',
    hint: '温暖 · 贴纸感',
    seedArgb: 0xFF9A7860,
    darkPrimaryArgb: 0xFFDCC0A8,
    darkOnPrimaryArgb: 0xFF3A2416,
    darkPrimaryContainerArgb: 0xFF483324,
    darkOnPrimaryContainerArgb: 0xFFF1E3D6,
  ),

  /// 石墨：几乎无彩，最"工具"的一套。
  graphite(
    label: '石墨',
    hint: '极简 · 无彩色',
    seedArgb: 0xFF646E78,
    darkPrimaryArgb: 0xFFC0C8D1,
    darkOnPrimaryArgb: 0xFF20272E,
    darkPrimaryContainerArgb: 0xFF333B43,
    darkOnPrimaryContainerArgb: 0xFFDDE3E9,
  );

  const ShqAccent({
    required this.label,
    required this.hint,
    required this.seedArgb,
    required this.darkPrimaryArgb,
    required this.darkOnPrimaryArgb,
    required this.darkPrimaryContainerArgb,
    required this.darkOnPrimaryContainerArgb,
  });

  /// 设置页显示名（两字，横向排得下）。
  final String label;

  /// 一句说明，只在设置页当副标题用。
  final String hint;

  /// Material 3 种子色。浅色主题的 primary / container 由它派生。
  final int seedArgb;

  /// 深色主题的主色族（手写，见类注释）。
  final int darkPrimaryArgb;
  final int darkOnPrimaryArgb;
  final int darkPrimaryContainerArgb;
  final int darkOnPrimaryContainerArgb;
}

/// 色系的持久化编解码。
///
/// 存的是 [ShqAccent.name]（`azure` / `celadon` …），**不是序号**：
/// 以后调整枚举顺序不会把用户的选择换成别的颜色。
/// 未知值（旧版本 / 脏数据）一律回落 [ShqAccent.azure]，不抛异常。
abstract final class ShqAccentCodec {
  static ShqAccent decode(String? raw) {
    if (raw != null) {
      for (final ShqAccent accent in ShqAccent.values) {
        if (accent.name == raw) {
          return accent;
        }
      }
    }
    return ShqAccent.azure;
  }

  static String encode(ShqAccent accent) => accent.name;
}
