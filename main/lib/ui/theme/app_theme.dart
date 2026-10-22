import 'package:flutter/material.dart';
import 'package:shuaqi/ui/theme/tokens.dart';

/// 主题的唯一构造点（T1.1「主题单点生效」）。
///
/// 除这里以外，任何 widget 都不许自己拼 `ThemeData` 或写颜色字面量；
/// 需要语义色时用 `Theme.of(context).colorScheme` 或 [ShqPalette] 的具名常量。
///
/// ## 暗色为什么是手调的（T1.6 升级）
///
/// `ColorScheme.fromSeed(brightness: dark)` 派生的暗色偏紫灰，与产品要的
/// "冷灰骨架 + 暖纸"不搭。所以暗色改为：seed 只做底，表面阶梯 / 描边 /
/// 主色 / 错误色全部用手调值覆盖（值在 [ShqDark]）。浅色保持 seed 派生
/// （已验证可用，不动）。
abstract final class ShqTheme {
  static ThemeData light() => _build(_lightScheme());

  static ThemeData dark() => _build(_darkScheme());

  static ColorScheme _lightScheme() =>
      ColorScheme.fromSeed(seedColor: ShqPalette.seed, brightness: Brightness.light);

  static ColorScheme _darkScheme() {
    final ColorScheme base = ColorScheme.fromSeed(
      seedColor: ShqPalette.seed,
      brightness: Brightness.dark,
    );
    return base.copyWith(
      surface: ShqDark.surface,
      surfaceContainerLowest: ShqDark.surfaceContainerLowest,
      surfaceContainerLow: ShqDark.surfaceContainerLow,
      surfaceContainer: ShqDark.surfaceContainer,
      surfaceContainerHigh: ShqDark.surfaceContainerHigh,
      surfaceContainerHighest: ShqDark.surfaceContainerHighest,
      onSurface: ShqDark.onSurface,
      onSurfaceVariant: ShqDark.onSurfaceVariant,
      outline: ShqDark.outline,
      outlineVariant: ShqDark.outlineVariant,
      primary: ShqDark.primary,
      onPrimary: ShqDark.onPrimary,
      primaryContainer: ShqDark.primaryContainer,
      onPrimaryContainer: ShqDark.onPrimaryContainer,
      error: ShqDark.error,
      onError: ShqDark.onError,
      errorContainer: ShqDark.errorContainer,
      onErrorContainer: ShqDark.onErrorContainer,
    );
  }

  static ThemeData _build(ColorScheme scheme) {
    final bool isDark = scheme.brightness == Brightness.dark;
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      // 手写场景：触控目标略大，减少误触。
      visualDensity: VisualDensity.comfortable,
      scaffoldBackgroundColor: scheme.surface,
      textTheme: _textTheme(scheme),
      appBarTheme: AppBarTheme(
        centerTitle: false,
        elevation: 0,
        // 暗色：滚动时用 2dp 的"色高差"分层（surfaceTint 关掉，不用紫色罩）；
        // 浅色：保持 0（平板纯色顶栏，够干净）。
        scrolledUnderElevation: isDark ? 2 : 0,
        surfaceTintColor: isDark ? Colors.transparent : null,
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
      ),
      dividerTheme: DividerThemeData(
        space: ShqSpace.lg,
        thickness: 1,
        color: scheme.outlineVariant,
      ),
      // 暗色下卡片取消投影（阴影在暗底显脏），改用表面色分层；
      // 浅色保留默认投影——白纸上"浮起"的卡片靠阴影更自然。
      cardTheme: isDark
          ? CardThemeData(
              elevation: 0,
              color: scheme.surfaceContainerLow,
              margin: EdgeInsets.zero,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(ShqRadius.md),
              ),
            )
          : null,
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(0, ShqLayout.minTouchTarget),
          padding: const EdgeInsets.symmetric(horizontal: ShqSpace.lg),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(ShqRadius.md),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(0, ShqLayout.minTouchTarget),
          padding: const EdgeInsets.symmetric(horizontal: ShqSpace.lg),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(ShqRadius.md),
          ),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(ShqRadius.md),
        ),
      ),
    );
  }

  /// 字阶在这里落地成 TextTheme。行高对中文比字号更影响可读性，所以逐级写死。
  static TextTheme _textTheme(ColorScheme scheme) {
    TextStyle base(double size, {FontWeight weight = FontWeight.w400}) {
      return TextStyle(
        fontSize: size,
        fontWeight: weight,
        height: ShqType.lineHeightBody,
        color: scheme.onSurface,
      );
    }

    return TextTheme(
      displaySmall: base(ShqType.display, weight: FontWeight.w600),
      headlineSmall: base(ShqType.headline, weight: FontWeight.w600),
      titleLarge: base(ShqType.title, weight: FontWeight.w600),
      titleMedium: base(ShqType.body, weight: FontWeight.w600),
      bodyLarge: base(ShqType.body),
      bodyMedium: base(ShqType.bodySmall),
      bodySmall: base(ShqType.caption),
      labelLarge: base(ShqType.bodySmall, weight: FontWeight.w600),
      labelSmall: base(ShqType.caption),
    );
  }
}
