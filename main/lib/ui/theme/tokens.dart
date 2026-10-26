import 'package:flutter/material.dart';
import 'package:shuaqi/domain/app/accent.dart';
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
///
/// 2026-10-23 整体放大一档（10/14/20）：配合"灵动现代简约"——
/// 更圆的外形 + 发丝描边 + 极浅阴影，是 ColorOS / iOS 近两年的共同语言。
abstract final class ShqRadius {
  static const double sm = 10;
  static const double md = 14;
  static const double lg = 20;

  /// 底部浮层（bottom sheet）的顶部圆角。独立于 lg：浮层是"从屏幕边缘
  /// 长出来的面板"，比卡片更需要宣告自己的边界。
  static const double xl = 28;
  static const double pill = 999;
}

/// 动效时长与曲线（2026-10-23 统一）。
///
/// 三条纪律：
/// 1. **入场慢、出场快**（iOS 的默认直觉）：进 200–240ms，退 140–160ms；
/// 2. 按压这类**直接反馈**要快（90ms），否则会觉得"没反应"；
/// 3. 位移类一律用减速曲线（`easeOutCubic`），只有强调场合才用轻微回弹。
abstract final class ShqMotion {
  /// 背景样式切换 / 按压反馈（REQ-15：≤100ms）。
  static const Duration instant = Duration(milliseconds: 90);
  static const Duration fast = Duration(milliseconds: 150);
  static const Duration base = Duration(milliseconds: 220);
  static const Duration slow = Duration(milliseconds: 340);

  /// 标准减速：几乎所有位移 / 淡入。
  static const Curve curveStandard = Curves.easeOutCubic;

  /// 强调：前后各留一点缓冲（Material 3 的 emphasized）。
  static const Cubic curveEmphasized = Cubic(0.2, 0.0, 0.0, 1.0);

  /// 退场：比入场快，且加速离开（不拖泥带水）。
  static const Curve curveExit = Curves.easeInCubic;
}

/// 字阶。中文正文从 16 起，12 只用于 HUD / 角标这类非阅读文本。
///
/// 2026-10-23 设计收尾：补齐到 15 级，且**每一级都写死行高**。
/// 中文的行高比字号更影响可读性：正文 1.65、标题 1.3、标签 1.3；
/// 行高一律 `even` 分布（`TextLeadingDistribution.even`），
/// 中英混排时数字/英文的基线不会比汉字飘高半行。
abstract final class ShqType {
  static const double caption = 12;
  static const double bodySmall = 14;
  static const double body = 16;
  static const double titleSmall = 15;
  static const double title = 20;
  static const double headline = 26;
  static const double display = 34;

  static const double lineHeightTight = 1.25;
  static const double lineHeightTitle = 1.3;
  static const double lineHeightBody = 1.65;

  /// 标题的轻微字距：中文大字距过大会散，0.2 只是让字面透气。
  static const double letterSpacingTitle = 0.2;
  static const double letterSpacingLabel = 0.4;
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

/// 题目区域框的三色与形态（T3.5 检查视角）。
///
/// 与 [ShqPalette] 的 correct/unclear/wrong **分开**：那三个是"答案对错"的语义色，
/// 这里的绿/黄/红只表示"这个框可信不可信"。两者混用会让用户以为红色框 = 做错了。
///
/// 取值刻意低饱和：框是叠加在题面上的，颜色一艳就抢题干。描边透明度 0.75、
/// 填充只有 0.055，保证"能看见框、看得清字"。
///
/// ## 2026-10-23 形态重做（用户拍板："粗圆角，像搜题软件"）
/// 旧形态是 1.2px 细线 + 5px 小圆角 + 未选中时四角四个小圆点。真机上看着"碎"：
/// 细线在扫描卷的灰底上不明显，四个圆点又像调试标记。现在的口径：
/// - **整框**是主角：2px 上下、14px 大圆角、半透明填充，一眼看出"这一块是一道题"；
/// - 四角圆点只在**选中后**以手柄形态出现（它是操作元件，不是装饰）；
/// - 角标题号做成胶囊，贴在框内左上角。
abstract final class ShqRegion {
  /// 切题框的**中性色**（2026-10-23 用户口径）。
  ///
  /// 绿/黄/红三色留给**后续判题**（对 / 存疑 / 错），切题置信度不能占用它们：
  /// 框体一旦按置信度染色，用户会把"这个框不确定"误读成"这道题做错了"。
  static const Color auto = Color(0xFF5B6B7C);

  /// 夜读纸上的提亮版中性色。
  static const Color autoOnDark = Color(0xFFA9B8C7);

  /// 判题预留色（当前**不用于画框**，后续判题结果再用）。
  static const Color green = Color(0xFF2F7A55);
  static const Color yellow = Color(0xFFA9761A);
  static const Color red = Color(0xFFB03A2E);

  /// 夜读纸上的提亮版：原色在 `#191612` 上几乎看不出。
  static const Color greenOnDark = Color(0xFF7FC79E);
  static const Color yellowOnDark = Color(0xFFE0B45C);
  static const Color redOnDark = Color(0xFFF09A8D);

  /// 用户手画的框：用主色，和"自动切出来的中性框"区分开。
  static const Color manual = Color(0xFF1F6FEB);
  static const Color manualOnDark = Color(0xFF8CB8F4);

  /// 作答框：紫色虚线。与切题框（中性）、手画框（蓝）、判题三色都不冲突。
  static const Color answer = Color(0xFF7A5AF8);
  static const Color answerOnDark = Color(0xFFC3B4FF);

  /// 框的圆角（逻辑 px，不随缩放变化）。太小就回到"线框"，太大就像卡片。
  static const double radius = 14;

  /// 框线粗细（逻辑 px）：只读态 / 选中态。
  ///
  /// **选中态只靠"更粗更实"表达**（2026-10-23 用户拍板，不再画手柄）：
  /// 3.0 与 1.8 的差在卷面上足够明显，且完全不遮挡题面。
  static const double strokeWidth = 1.8;
  static const double strokeSelected = 3;

  /// 框内填充透明度：只读 / 选中。
  static const double fillAlpha = 0.055;
  static const double fillAlphaSelected = 0.12;

  /// 题号胶囊：高度、圆角、字号。
  static const double labelHeight = 18;
  static const double labelRadius = 9;
  static const double labelSize = 10.5;

  /// 缩放把手的**命中区**（没有视觉形态：选中态只画更粗的边）。
  ///
  /// 四角 30dp、四边中点 26dp——手指点得中，但界面上看不见它们，
  /// 所以不会因为"四个方块"抢题面（2026-10-23 第二轮定稿）。
  static const double handleHit = 30;
  static const double edgeHandleHit = 26;
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

/// 夜读纸样式专用色（`PaperStyle.night`，与 App 主题无关）。
///
/// 与 [ShqDark]（app 骨架的冷灰）刻意分开：**纸是暖的，界面是冷的**。
/// 暖黑纸 + 暖白墨延续浅色模式"纸感暖色 / 墨色"的基因，冷灰骨架让纸浮出来；
/// 两头都低饱和，长时间看不累。
abstract final class ShqNight {
  /// 夜读纸色：duotone 暗端，白纸 → 它（`NightRgb.paper` 的 Color 形态）。
  static const Color paper = Color(0xFF191612);

  /// 夜读墨色：duotone 亮端，黑字 → 它（`NightRgb.ink` 的 Color 形态）。
  /// 同时也是夜读纸上的笔迹墨色（[inkColorFor]）。
  static const Color ink = Color(0xFFE9E3D5);

  /// 页面发丝边：暗纸与背景只差亮度，一圈极淡亮边让"纸"显形。
  ///
  /// 注意它画在**滤镜之外**：被 duotone 再反一次色就成了一块脏光。
  static const Color pageEdge = Color(0x0FFFFFFF);
}

/// 浅色表面阶梯（app 骨架）。
///
/// 2026-10-23 设计收尾：不再直接用 seed 派生的表面色。派生色带一层冷紫，
/// 与产品"纸感 / 暖白"的基因相冲。这里改成一组**中性偏暖的灰白**：
/// 白纸是暖的、界面是安静的，卷子浮在上面才不会像贴在一块冷色玻璃上。
/// 主色仍由 seed 派生（蓝色只负责"可点"与"选中"，不参与大面积铺底）。
abstract final class ShqLight {
  static const Color surface = Color(0xFFFAF9F7);
  static const Color surfaceContainerLowest = Color(0xFFFFFFFF);
  static const Color surfaceContainerLow = Color(0xFFF6F4F1);
  static const Color surfaceContainer = Color(0xFFF1EEEB);
  static const Color surfaceContainerHigh = Color(0xFFEBE7E3);
  static const Color surfaceContainerHighest = Color(0xFFE4DFDA);

  static const Color onSurface = Color(0xFF1A1C1E);
  static const Color onSurfaceVariant = Color(0xFF5C6066);

  static const Color outline = Color(0xFF8A8F95);
  static const Color outlineVariant = Color(0xFFD9D4CE);
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
  ///
  /// 2026-10-26：主色族改由「色系」持有（`domain/app/accent.dart`），
  /// 这里不再留一份固定值，避免同一个颜色两处维护、换色时漏改。
  /// 靛蓝那套的值与 2026-10-24 定稿完全一致。

  /// 错误色按暗色对比度重调（M3 暗色错误是淡红，不是正红）。
  static const Color error = Color(0xFFF2B8B5);
  static const Color onError = Color(0xFF601410);
  static const Color errorContainer = Color(0xFF8C1D18);
  static const Color onErrorContainer = Color(0xFFF9DEDC);
}

/// 记录页热力图的绿色阶（阶段 9）。
///
/// 为什么允许出现一套"绿色系"：热力图是**唯一**用绿色表达"密度"的地方
/// （用户明确要求 GitHub 式绿），而绿色在本产品里已经另有语义（判对）。
/// 两者不会同屏出现——热力图只出现在记录页页首，判定点在卡片/看板上用
/// [ShqPalette.correct]。取色刻意低饱和，和纸感暖灰不打架。
///
/// 档位口径（`domain/records/records_stats.dart` 的 `heatLevel`）：
/// 0 = 无记录，1 = 1–2 题，2 = 3–5，3 = 6–9，4 = 10–15，5 = 16+。
abstract final class ShqHeat {
  /// 浅色主题的 5 档（1→5）。第 1 档要浅到"存在但不抢"，第 5 档要深到一眼看出。
  static const List<Color> light = <Color>[
    Color(0xFFD8EBDD),
    Color(0xFFA9D8B9),
    Color(0xFF6FBF8E),
    Color(0xFF3E9668),
    Color(0xFF1F6B47),
  ];

  /// 暗色主题的 5 档：低档靠"暗绿"存在，高档靠"亮绿"突出（暗底上提亮才看得见）。
  static const List<Color> dark = <Color>[
    Color(0xFF1E3A2B),
    Color(0xFF2D5B41),
    Color(0xFF3F8158),
    Color(0xFF58A976),
    Color(0xFF83D2A2),
  ];

  /// 取某一档的颜色。[level] 0 返回 null（由调用方画"空底色"，跟主题走）。
  static Color? level(int level, {required bool dark}) {
    if (level <= 0) {
      return null;
    }
    final List<Color> ramp = dark ? ShqHeat.dark : ShqHeat.light;
    return ramp[(level - 1).clamp(0, ramp.length - 1)];
  }

  /// 热力图格子边长与间隙（逻辑 dp）：26 列在 2/5 栏里刚好放下。
  static const double cell = 10.5;
  static const double gap = 3;
}

/// 版心。平板竖屏阅读区最大宽度，超过就留白居中，避免长行难读。
abstract final class ShqLayout {
  static const double maxReadingWidth = 880;

  /// 设置 / 详情类页面：比阅读区窄一档，单列扫读更稳。
  static const double maxFormWidth = 720;

  /// 空态 / 介绍类页面的正文宽度。
  static const double maxNarrativeWidth = 560;

  static const double minTouchTarget = 48;

  /// 设置分组卡片的横向内边距（与分组标题共用同一条竖线）。
  static const double gutter = 16;
}

/// 全屏遮罩层（图片预览 / 长按浮窗）的固定配色。
///
/// 这一层**永远压在图片上**，背景是深色遮罩而不是主题表面：所以前景恒为浅色，
/// 不跟 `Theme.of(context).brightness` 走（浅色主题下用 onSurface 会变成深字，
/// 压在黑遮罩上直接看不见）。这是本项目里少数"与主题解耦"的颜色。
abstract final class ShqScrim {
  /// 图片预览的遮罩：**纯黑**。看过 86% 与 97% 两档，下层页面的白色标题
  /// 总能透出轮廓（视觉上"两页叠在一起"），看图场景不需要这层信息，索性全黑。
  static const Color backdrop = Color(0xFF000000);

  /// 长按浮窗的轻遮罩（只压一层，视觉上不抢图片）。
  static const Color backdropSoft = Color(0x33000000);

  /// 遮罩上的主要文字/图标。
  static const Color foreground = Color(0xFFF3EFE7);

  /// 遮罩上的次要说明。
  static const Color foregroundMuted = Color(0x8FF3EFE7);
}

/// 色系 → 颜色的**唯一转换点**。
///
/// 十六进制值放在 `domain/app/accent.dart`（那是用户偏好数据，必须能脱离
/// Flutter 单测）；这里负责把它们变成 `Color`，widget 侧只认这套 getter，
/// 从而继续满足"颜色只在 tokens.dart 出现"的纪律。
extension ShqAccentColors on ShqAccent {
  /// 种子色：设置页的色点、以及浅色主题 `ColorScheme.fromSeed` 的输入。
  Color get seed => Color(seedArgb);

  Color get darkPrimary => Color(darkPrimaryArgb);
  Color get darkOnPrimary => Color(darkOnPrimaryArgb);
  Color get darkPrimaryContainer => Color(darkPrimaryContainerArgb);
  Color get darkOnPrimaryContainer => Color(darkOnPrimaryContainerArgb);
}

/// 光感（2026-10-26 用户："可以适度在一些位置增加一点光感"）。
///
/// 口径写死在这里，避免每个页面各写一个 `BoxShadow`：
/// - **只给"能按的东西"发光**：主按钮、FAB、当前选中项、浮起的面板；
/// - 光是**强调色的低透明投影**，不是白色高光；暗色主题下同样有效
///   （暗底上的彩色投影比黑色投影更"亮"，这正是想要的那点光）；
/// - 透明度上限 0.32：再高就成了霓虹，与"简约"冲突；
/// - 只用一层投影（blur ≤ 22）。多层叠加在低端机上肉眼无差，却要多次离屏合成。
abstract final class ShqGlow {
  /// 主按钮 / 主行动点。
  static const double actionAlpha = 0.26;
  static const double actionBlur = 16;
  static const double actionLift = 3;

  /// 悬浮按钮：比主按钮再亮一点点，因为它是"浮"在内容上的。
  static const double fabAlpha = 0.32;
  static const double fabBlur = 22;
  static const double fabLift = 5;

  /// 当前选中项（书架卡、收藏卡、分段按钮）的呼吸光。
  static const double selectedAlpha = 0.18;
  static const double selectedBlur = 14;

  /// 浮层（底部面板 / 对话框）投影：中性黑，只负责"离开页面"。
  static const double sheetAlpha = 0.16;
  static const double sheetBlur = 28;

  /// 一圈"呼吸光"。返回 `null` 表示不需要（例如暗色下的中性投影）。
  static List<BoxShadow>? ring(
    Color color, {
    double alpha = selectedAlpha,
    double blur = selectedBlur,
    Offset offset = Offset.zero,
  }) {
    return <BoxShadow>[
      BoxShadow(
        color: color.withValues(alpha: alpha),
        blurRadius: blur,
        offset: offset,
      ),
    ];
  }
}
