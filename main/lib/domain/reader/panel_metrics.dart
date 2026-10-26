/// 右侧面板（题目区域 / 问 AI）的宽度几何 —— 纯 Dart，可单测。
///
/// 为什么要单独一个文件：面板宽度同时被阅读区留白、题面预览宽度、AI 面板宽度
/// 三处使用，任何一处自己算 `screen * 0.42` 都会在拖宽之后彼此错位。
/// 这里只回答两个问题：**默认多宽**、**允许拖到多宽**。
///
/// 口径（2026-10-24 用户拍板）：
/// - 最小 = 现在的宽度（宽屏 320dp，窄屏屏宽的 42%）；
/// - 最大 = 横向屏幕的 1/2（看板要能并排放下"列表 + 预览"）；
/// - 记住的是**一个全局值**，不是每卷一份。
library;

abstract final class PanelMetrics {
  /// 宽屏下的默认/最小宽度（dp）。
  static const double minWidth = 320;

  /// 窄屏（手机竖屏一类）的默认/最小宽度占比。
  static const double narrowFraction = 0.42;

  /// 窄屏判定：与本项目既有的"平板 / 窄屏"口径一致（<760dp 视为窄屏）。
  static const double narrowBreakpoint = 760;

  /// 拖动上限：横向屏幕的 1/2。
  static const double maxScreenFraction = 0.5;

  /// 该屏宽下的最小宽度。
  static double minFor(double screenWidth) {
    if (screenWidth < narrowBreakpoint) {
      return screenWidth * narrowFraction;
    }
    return minWidth;
  }

  /// 该屏宽下的最大宽度。
  static double maxFor(double screenWidth) => screenWidth * maxScreenFraction;

  /// 没存过偏好时的默认宽度。
  static double defaultFor(double screenWidth) => minFor(screenWidth);

  /// 把任意输入收敛到 `[minFor, maxFor]`。
  ///
  /// 屏幕窄到 min 已经 >= max 时返回 min：宁可面板占满也不返回负数。
  static double clampWidth(double desired, double screenWidth) {
    if (screenWidth <= 0) {
      return minWidth;
    }
    final double min = minFor(screenWidth);
    final double max = maxFor(screenWidth);
    if (max <= min) {
      return min;
    }
    return desired.clamp(min, max);
  }
}
