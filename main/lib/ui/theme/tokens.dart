import 'package:flutter/material.dart';

/// 设计令牌 —— 全局唯一来源（规格 §10：常量集中在 `ui/theme/tokens.dart`）。
///
/// 规则（写代码时自查）：
/// 1. widget 里**不允许**出现颜色 / 字号 / 间距 / 圆角的字面量，一律从这里取。
/// 2. 新增令牌先想清楚它是不是"真的全局"；只服务于一个页面的数字留在那个页面。
/// 3. 纸色（[ShqPaper]）只影响背景层，不得用于任何前景元素。

/// 间距阶梯。基于 4 的倍数，平板密度下 4 太小、8 太挤，正文区默认 [lg]。
abstract final class ShqSpace {
  static const double xxs = 2;
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double xxl = 32;
  static const double huge = 48;
}

/// 圆角。手写场景尽量少用大圆角，避免和笔迹抢视觉。
abstract final class ShqRadius {
  static const double sm = 6;
  static const double md = 10;
  static const double lg = 16;
  static const double pill = 999;
}

/// 动效时长。
abstract final class ShqMotion {
  /// 背景样式切换（REQ-15：≤100ms）。
  static const Duration instant = Duration(milliseconds: 100);
  static const Duration fast = Duration(milliseconds: 150);
  static const Duration base = Duration(milliseconds: 200);
  static const Duration slow = Duration(milliseconds: 320);
}

/// 字阶。中文正文从 16 起，12 只用于 HUD / 角标这类非阅读文本。
abstract final class ShqType {
  static const double caption = 12;
  static const double bodySmall = 14;
  static const double body = 16;
  static const double title = 20;
  static const double headline = 26;
  static const double display = 34;

  static const double lineHeightTight = 1.25;
  static const double lineHeightBody = 1.6;
}

/// 品牌与语义色。
///
/// 刻意不用"红金"：这是效率工具，不是政务宣传物料。主色取冷静的蓝，
/// 三态色（correct / unclear / wrong）只用于结果页与错题本，不铺到全局。
abstract final class ShqPalette {
  /// 种子色。Material 3 会由它派生整套 colorScheme。
  static const Color seed = Color(0xFF1F6FEB);

  /// 笔迹墨色。不用纯黑（`#000`），纯黑在纸色背景上偏硬。
  static const Color ink = Color(0xFF14161A);

  /// 荧光笔。半透明，保证下方题干可读（REQ-03）。
  static const Color highlighter = Color(0x66FFD54F);

  /// 三态语义色。注意：`unclear` 用琥珀色而不是红色——它不等于"错"（INV-05）。
  static const Color correct = Color(0xFF1B6E3C);
  static const Color unclear = Color(0xFFB26A00);
  static const Color wrong = Color(0xFFB3261E);

  /// 警示（危险操作：删除、覆盖）。
  static const Color danger = Color(0xFFB3261E);
}

/// 纸张预设（§6.9.3）。`original` 为零处理，是可信基线。
abstract final class ShqPaper {
  static const Color warm = Color(0xFFF6EFE3);
  static const Color ivory = Color(0xFFF8F1DC);
  static const Color gray = Color(0xFFF1F1EF);
  static const Color green = Color(0xFFE9F1E7);

  /// 强度上限对应的最大不透明度系数（§6.9.3：α = intensity/100 × 0.35）。
  /// 默认强度 55 的真值在 `domain/reader/reader_prefs.dart`，不在这里重复定义。
  static const double maxAlpha = 0.35;
}

/// 版心。平板竖屏阅读区最大宽度，超过就留白居中，避免长行难读。
abstract final class ShqLayout {
  static const double maxReadingWidth = 880;
  static const double minTouchTarget = 48;
}
