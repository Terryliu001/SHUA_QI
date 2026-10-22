import 'package:flutter/material.dart';
import 'package:shuaqi/ui/theme/tokens.dart';

/// 主题的唯一构造点（T1.1「主题单点生效」）。
///
/// 除这里以外，任何 widget 都不许自己拼 `ThemeData` 或写颜色字面量；
/// 需要语义色时用 `Theme.of(context).colorScheme` 或 [ShqPalette] 的具名常量。
abstract final class ShqTheme {
  static ThemeData light() => _build(Brightness.light);

  static ThemeData dark() => _build(Brightness.dark);

  static ThemeData _build(Brightness brightness) {
    final ColorScheme scheme = ColorScheme.fromSeed(
      seedColor: ShqPalette.seed,
      brightness: brightness,
    );

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
        scrolledUnderElevation: 0,
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
      ),
      dividerTheme: DividerThemeData(
        space: ShqSpace.lg,
        thickness: 1,
        color: scheme.outlineVariant,
      ),
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
