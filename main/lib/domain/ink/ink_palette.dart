import 'package:shuaqi/domain/ink/ink_doc.dart';

/// 墨色调色板（纯 Dart：`0xAARRGGBB` 纯 int，domain 不碰 Flutter 的 Color）。
///
/// ## 为什么是"语义索引"而不是自由取色
/// 1. **入库只要 1 字节**：SIF 每个 stroke 存的是 [索引]，不是 ARGB；
///    5000 笔的差异是 0KB vs 20KB，更重要的是"颜色是有限集合"这件事进了契约，
///    导出 PDF、夜间可读性、以后的主题化都只需要维护这张表。
/// 2. **暗纸可读性由表保证**：夜读纸（暖黑）上墨黑是不可见的，
///    每个索引都有一份"暗纸版"（同色相提亮），选色时不用用户操心。
///
/// ## 索引稳定性
/// 索引是数据契约的一部分：**只能追加，不能重排、不能删除**。
/// 0 号必须永远是"墨黑"（老数据默认 0），否则历史笔迹会换颜色。
abstract final class InkPalette {
  /// 钢笔/圆珠笔可选颜色数。
  static const int penCount = 6;

  /// 荧光笔可选颜色数（荧光只有"透光色"，没有黑白）。
  static const int highlighterCount = 4;

  /// 亮纸（白/暖白/象牙…）上的墨色。
  /// 0 墨黑 · 1 蓝 · 2 红 · 3 绿 · 4 橙 · 5 紫
  static const List<int> penOnLight = <int>[
    0xFF14161A, // 墨黑（不用纯黑：纸色背景上纯黑偏硬）
    0xFF1558C0, // 蓝（判题、批注主色）
    0xFFC62828, // 红（改错）
    0xFF1B6E3C, // 绿（对勾）
    0xFFB26A00, // 橙（疑问）
    0xFF6A3AB2, // 紫（补充说明）
  ];

  /// 暗纸（夜读）上的墨色：同色相提亮，保证在暖黑纸上有足够对比度。
  static const List<int> penOnDark = <int>[
    0xFFE9E3D5,
    0xFF8CB8F4,
    0xFFF2B8B5,
    0xFF7BC79B,
    0xFFF0B667,
    0xFFC3A6F0,
  ];

  /// 荧光笔（半透明、乘算/滤色合成）。0 黄 · 1 绿 · 2 粉 · 3 蓝
  static const List<int> highlighterOnLight = <int>[
    0x66FFD54F,
    0x664CD98A,
    0x66FF8AA8,
    0x6680B8FF,
  ];

  /// 暗纸上荧光笔稍微提亮一点（乘算在暗底上会压黑，改走滤色，见 [BlendMode])。
  static const List<int> highlighterOnDark = <int>[
    0x66FFD54F,
    0x6657E39A,
    0x66FF9FB8,
    0x6674B6FF,
  ];

  /// 这种笔刷有几种颜色可选。
  static int countFor(InkStrokeStyle style) =>
      style == InkStrokeStyle.highlighter ? highlighterCount : penCount;

  /// 取色：越界一律收敛到 0（回落墨黑，绝不抛）。
  static int argb({
    required InkStrokeStyle style,
    required int index,
    required bool darkPaper,
  }) {
    final List<int> table = style == InkStrokeStyle.highlighter
        ? (darkPaper ? highlighterOnDark : highlighterOnLight)
        : (darkPaper ? penOnDark : penOnLight);
    final int i = index.clamp(0, table.length - 1);
    return table[i];
  }

  static int clampIndex(InkStrokeStyle style, int index) =>
      index.clamp(0, countFor(style) - 1);
}
