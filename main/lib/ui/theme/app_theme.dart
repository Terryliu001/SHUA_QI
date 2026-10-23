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
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      // 手写场景：触控目标略大，减少误触。
      visualDensity: VisualDensity.comfortable,
      scaffoldBackgroundColor: scheme.surface,
      textTheme: _textTheme(scheme),
      // 2026-10-23 设计升级：**去掉水波纹**。
      // 理由有二：① 笔尖点按钮时水波纹会盖住笔迹、显得脏；
      // ② "灵动简约"的方向是"元素自己缩一下"（见 Pressable），而不是刷一层光。
      splashFactory: NoSplash.splashFactory,
      highlightColor: Colors.transparent,
      // 页面切换：淡入 + 2% 上移（共享轴），比默认的平台转场更安静。
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: <TargetPlatform, PageTransitionsBuilder>{
          TargetPlatform.android: _FadeThroughTransitionsBuilder(),
          TargetPlatform.iOS: _FadeThroughTransitionsBuilder(),
          TargetPlatform.windows: _FadeThroughTransitionsBuilder(),
          TargetPlatform.macOS: _FadeThroughTransitionsBuilder(),
          TargetPlatform.linux: _FadeThroughTransitionsBuilder(),
        },
      ),
      appBarTheme: AppBarTheme(
        centerTitle: false,
        elevation: 0,
        toolbarHeight: 60,
        // 顶栏与内容同色、不投影：靠 1px 发丝线分层（见 divider/卡片），
        // 这是 ColorOS / iOS 现在的做法（顶栏是"容器"而不是"盖子"）。
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
        titleTextStyle: TextStyle(
          fontSize: ShqType.title,
          fontWeight: FontWeight.w600,
          color: scheme.onSurface,
          letterSpacing: 0.2,
        ),
      ),
      dividerTheme: DividerThemeData(
        space: ShqSpace.lg,
        thickness: 1,
        color: scheme.outlineVariant,
      ),
      // 卡片：两套主题统一"浅一档的表面 + 发丝描边 + 极浅阴影"，
      // 不再"暗色无阴影、浅色有阴影"两套逻辑（那种差异会让暗色显得更平）。
      cardTheme: CardThemeData(
        elevation: 0,
        color: scheme.surfaceContainerLow,
        surfaceTintColor: Colors.transparent,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(ShqRadius.lg),
          side: BorderSide(color: scheme.outlineVariant),
        ),
      ),
      chipTheme: ChipThemeData(
        shape: StadiumBorder(side: BorderSide(color: scheme.outlineVariant)),
        backgroundColor: scheme.surfaceContainerHigh,
        selectedColor: scheme.secondaryContainer,
        labelStyle: TextStyle(color: scheme.onSurfaceVariant),
        side: BorderSide.none,
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: scheme.surface,
        indicatorColor: scheme.secondaryContainer,
        indicatorShape: const StadiumBorder(),
        selectedIconTheme: IconThemeData(color: scheme.onSecondaryContainer),
        unselectedIconTheme: IconThemeData(color: scheme.onSurfaceVariant),
        selectedLabelTextStyle: TextStyle(
          color: scheme.onSurface,
          fontWeight: FontWeight.w600,
          fontSize: ShqType.caption,
        ),
        unselectedLabelTextStyle: TextStyle(
          color: scheme.onSurfaceVariant,
          fontSize: ShqType.caption,
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        height: 68,
        backgroundColor: scheme.surface,
        surfaceTintColor: Colors.transparent,
        indicatorColor: scheme.secondaryContainer,
        indicatorShape: const StadiumBorder(),
        labelTextStyle: WidgetStateProperty.resolveWith<TextStyle>(
          (Set<WidgetState> states) => TextStyle(
            fontSize: ShqType.caption,
            fontWeight: states.contains(WidgetState.selected)
                ? FontWeight.w600
                : FontWeight.w400,
            color: states.contains(WidgetState.selected)
                ? scheme.onSurface
                : scheme.onSurfaceVariant,
          ),
        ),
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

/// 页面转场：**淡入 + 2% 上移**（Material 3 的 shared-axis 手感）。
///
/// 为什么不用默认的平台转场：阅读器/设置/书架之间是"同一份内容的不同视图"，
/// 推拉的横滑更像"打开了一个新应用"；淡入 + 极短位移更安静，也更接近
/// iOS 的 sheet 感与 ColorOS 的"轻量切换"。
class _FadeThroughTransitionsBuilder extends PageTransitionsBuilder {
  const _FadeThroughTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final Animation<double> curved = CurvedAnimation(
      parent: animation,
      curve: ShqMotion.curveEmphasized,
      reverseCurve: ShqMotion.curveExit,
    );
    return FadeTransition(
      opacity: curved,
      child: SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0, 0.02),
          end: Offset.zero,
        ).animate(curved),
        child: child,
      ),
    );
  }
}
