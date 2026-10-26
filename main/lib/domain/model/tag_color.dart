/// 标签 → 颜色（纯 Dart，只出 `#RRGGBB` 字符串）。
///
/// 为什么标签要有颜色（2026-10-24 用户第 7 条）：卡片右上角做成书签之后，
/// 书签的**颜色就是分类**——扫一眼书架先看到色块，再看到字。
/// 颜色必须稳定：同一个标签在任何一卷上都是同一个色，否则分类就失去意义。
library;

/// 8 色板（低饱和，和主题不打架）。与文件夹共用同一组，
/// 这样"蓝色文件夹 / 蓝色标签"视觉上是同一套语言。
const List<String> kTagPalette = <String>[
  '#1F6FEB',
  '#1B6E3C',
  '#B26A00',
  '#B3261E',
  '#7A5AF8',
  '#0F766E',
  '#9A3412',
  '#334155',
];

/// 没被用户指定过的标签，按名字**稳定地**落到一个色。
///
/// 用码位求和而不是 `String.hashCode`：后者不保证跨版本/跨平台稳定，
/// 一旦变了，同一批标签会整体换色。求和是确定的，而且零成本。
String defaultTagHex(String tag) {
  if (tag.isEmpty) {
    return kTagPalette.first;
  }
  int sum = 0;
  for (final int unit in tag.codeUnits) {
    sum += unit;
  }
  return kTagPalette[sum % kTagPalette.length];
}
