import 'package:flutter/material.dart';

import 'package:shuaqi/ui/theme/tokens.dart';

/// `#RRGGBB` → Color（非法值退回主题主色）。
///
/// 文件夹颜色、标签颜色都以字符串存在库里（domain 层不认识 Flutter 的
/// `Color`），到 UI 这一层才转成 `Color` —— 转换只有这一处。
Color shqHexColor(String hex) {
  final String value = hex.replaceFirst('#', '');
  if (value.length != 6) {
    return ShqPalette.seed;
  }
  final int? rgb = int.tryParse(value, radix: 16);
  return rgb == null ? ShqPalette.seed : Color(0xFF000000 | rgb);
}
