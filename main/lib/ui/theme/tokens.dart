import 'package:flutter/material.dart';
import 'package:shuaqi/domain/reader/paper_tint.dart';

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

  /// 底部浮层（bottom sheet）的顶部圆角。独立于 lg：浮层是"从屏幕边缘
  /// 长出来的面板"，比卡片更需要宣告自己的边界。
  static const double xl = 24;
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
///
/// 颜色值唯一来源在 `domain/reader/paper_tint.dart` 的 [PaperRgb]，这里只包成 Color，
/// 避免同一色值两处各写一遍而漂移。
abstract final class ShqPaper {
  /// 页底。PDF 页本身是白纸；纸感滤镜只染它，导出永远绕开（REQ-15）。
  static const Color base = Color(0xFFFFFFFF);

  static const Color warm = Color(PaperRgb.warm);
  static const Color ivory = Color(PaperRgb.ivory);
  static const Color gray = Color(PaperRgb.gray);
  static const Color green = Color(PaperRgb.green);

  /// 强度上限对应的最大不透明度系数（§6.9.3：α = intensity/100 × 0.35）。
  /// 默认强度 55 的真值在 `domain/reader/reader_prefs.dart`，不在这里重复定义。
  static const double maxAlpha = 0.35;

  /// 浅色模式下页面的投影（0.18 黑）。纸是"浮"在阅读区上的，轻投影就够。
  static const Color lightPageShadow = Color(0x2E000000);

  /// 噪点纹理的不透明度上限（§6.9.3：≤3%）。只做"纸感"的细腻颗粒，不抢内容。
  static const double noiseOpacity = 0.03;
}

/// 夜读（暗色模式）专用色（T1.6 升级：暗色遮罩 → duotone 夜读）。
///
/// 与 [ShqDark]（app 骨架的冷灰）刻意分开：**页面是暖的，界面是冷的**。
/// 暖黑纸 + 暖白墨延续浅色模式"纸感暖色 / 墨色"的基因，冷灰骨架让纸浮出来；
/// 两头都低饱和，长时间看不累。
abstract final class ShqNight {
  /// 夜读纸色：duotone 暗端，白纸 → 它（`NightRgb.paper` 的 Color 形态）。
  static const Color paper = Color(0xFF191612);

  /// 夜读墨色：duotone 亮端，黑字 → 它（`NightRgb.ink` 的 Color 形态）。
  static const Color ink = Color(0xFFE9E3D5);

  /// 页面发丝边：暗色下页面与背景只差亮度，一圈极淡亮边让"纸"显形。
  static const Color pageEdge = Color(0x0FFFFFFF);

  /// 页面投影：暗背景里投影要更淡更暖，否则显脏。
  static const Color pageShadow = Color(0x59000000);
}

/// 暗色表面阶梯（app 骨架：书架 / AppBar / 抽屉 / 浮层）。
///
/// 手调而非 seed 派生：seed 蓝派生的暗色偏紫灰，与"冷灰骨架 + 暖纸"不搭。
/// 层次只靠亮度差（Material 3 的 elevation 用表面色表达的理念），
/// 全部低饱和；描边用发丝线（[outlineVariant]）而不是阴影（iOS 的优雅简练）。
abstract final class ShqDark {
  static const Color surface = Color(0xFF0E1317);
  static const Color surfaceContainerLowest = Color(0xFF080C0F);
  static const Color surfaceContainerLow = Color(0xFF141B21);
  static const Color surfaceContainer = Color(0xFF19232A);
  static const Color surfaceContainerHigh = Color(0xFF222E36);
  static const Color surfaceContainerHighest = Color(0xFF2B3941);

  static const Color onSurface = Color(0xFFE3E9EE);
  static const Color onSurfaceVariant = Color(0xFFA6B3BD);

  /// 发丝线：暗底下要比浅色更亮才看得见，但仍保持"线"而不是"条"。
  static const Color outline = Color(0xFF5D6B76);
  static const Color outlineVariant = Color(0xFF35424B);

  /// 主色提亮（暗色下的可点元素要够亮），配深蓝 on 色。
  static const Color primary = Color(0xFF8CB8F4);
  static const Color onPrimary = Color(0xFF0A2A52);
  static const Color primaryContainer = Color(0xFF204470);
  static const Color onPrimaryContainer = Color(0xFFD4E3FB);

  /// 错误色按暗色对比度重调（M3 暗色错误是淡红，不是正红）。
  static const Color error = Color(0xFFF2B8B5);
  static const Color onError = Color(0xFF601410);
  static const Color errorContainer = Color(0xFF8C1D18);
  static const Color onErrorContainer = Color(0xFFF9DEDC);
}

/// 版心。平板竖屏阅读区最大宽度，超过就留白居中，避免长行难读。
abstract final class ShqLayout {
  static const double maxReadingWidth = 880;
  static const double minTouchTarget = 48;
}
