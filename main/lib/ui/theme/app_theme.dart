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
/// 主色 / 错误色全部用手调值覆盖（值在 [ShqDark]）。
///
/// ## 浅色为什么也手调（2026-10-23 设计收尾）
///
/// 同理：seed 派生的浅色表面带冷紫，与"暖白纸感"相冲。表面阶梯换成
/// 中性偏暖的灰白（[ShqLight]），主色仍由 seed 派生（蓝只负责可点/选中）。
///
/// ## 2026-10-23 设计 v3：组件主题一次收口
///
/// 这一版不再逐页写样式，而是把 **输入框 / 对话框 / 浮层 / 菜单 / 列表行 /
/// 分段按钮 / 滑块 / 进度 / 滚动条 / FAB / Tooltip** 全部在 ThemeData 里定一次。
/// 页面上只允许写"布局"，不允许写"皮肤"。
abstract final class ShqTheme {
  static ThemeData light() => _build(_lightScheme());

  static ThemeData dark() => _build(_darkScheme());

  static ColorScheme _lightScheme() {
    final ColorScheme base = ColorScheme.fromSeed(
      seedColor: ShqPalette.seed,
      brightness: Brightness.light,
    );
    return base.copyWith(
      surface: ShqLight.surface,
      surfaceContainerLowest: ShqLight.surfaceContainerLowest,
      surfaceContainerLow: ShqLight.surfaceContainerLow,
      surfaceContainer: ShqLight.surfaceContainer,
      surfaceContainerHigh: ShqLight.surfaceContainerHigh,
      surfaceContainerHighest: ShqLight.surfaceContainerHighest,
      onSurface: ShqLight.onSurface,
      onSurfaceVariant: ShqLight.onSurfaceVariant,
      outline: ShqLight.outline,
      outlineVariant: ShqLight.outlineVariant,
    );
  }

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
    final bool dark = scheme.brightness == Brightness.dark;
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
        iconTheme: IconThemeData(color: scheme.onSurfaceVariant, size: 22),
        titleTextStyle: TextStyle(
          fontSize: ShqType.title,
          fontWeight: FontWeight.w600,
          color: scheme.onSurface,
          letterSpacing: ShqType.letterSpacingTitle,
          height: ShqType.lineHeightTitle,
          leadingDistribution: TextLeadingDistribution.even,
        ),
      ),
      dividerTheme: DividerThemeData(
        space: ShqSpace.lg,
        thickness: 1,
        color: scheme.outlineVariant,
      ),
      // 卡片：两套主题统一"浅一档的表面 + 发丝描边 + 零投影"，
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
        shape: const StadiumBorder(),
        backgroundColor: scheme.surfaceContainerHigh,
        selectedColor: scheme.secondaryContainer,
        labelStyle: TextStyle(
          color: scheme.onSurfaceVariant,
          fontSize: ShqType.caption,
          height: 1.2,
          leadingDistribution: TextLeadingDistribution.even,
        ),
        side: BorderSide.none,
        padding: const EdgeInsets.symmetric(horizontal: ShqSpace.sm),
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
          letterSpacing: 0.2,
        ),
        unselectedLabelTextStyle: TextStyle(
          color: scheme.onSurfaceVariant,
          fontSize: ShqType.caption,
          letterSpacing: 0.2,
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
            letterSpacing: 0.2,
            fontWeight: states.contains(WidgetState.selected)
                ? FontWeight.w600
                : FontWeight.w400,
            color: states.contains(WidgetState.selected)
                ? scheme.onSurface
                : scheme.onSurfaceVariant,
          ),
        ),
      ),
      // 列表行：图标降为主色不抢眼的 onSurfaceVariant，标题/说明的字号与行高
      // 跟字阶一致（之前 ListTile 在不同页面长得不一样，就是没定这里）。
      listTileTheme: ListTileThemeData(
        iconColor: scheme.onSurfaceVariant,
        textColor: scheme.onSurface,
        titleTextStyle: TextStyle(
          fontSize: ShqType.body,
          height: 1.35,
          color: scheme.onSurface,
          leadingDistribution: TextLeadingDistribution.even,
        ),
        subtitleTextStyle: TextStyle(
          fontSize: ShqType.caption,
          height: 1.45,
          color: scheme.onSurfaceVariant,
          leadingDistribution: TextLeadingDistribution.even,
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: ShqSpace.lg),
        horizontalTitleGap: ShqSpace.md,
        minLeadingWidth: 24,
        minVerticalPadding: ShqSpace.md,
        titleAlignment: ListTileTitleAlignment.center,
      ),
      // 输入框：胶囊/圆角的填充式。搜索框、重命名、标签都用同一套。
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surfaceContainerHigh,
        isDense: true,
        hintStyle: TextStyle(
          color: scheme.onSurfaceVariant,
          fontSize: ShqType.bodySmall,
        ),
        labelStyle: TextStyle(color: scheme.onSurfaceVariant),
        helperStyle: TextStyle(
          color: scheme.onSurfaceVariant,
          fontSize: ShqType.caption,
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: ShqSpace.lg,
          vertical: ShqSpace.md,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(ShqRadius.md),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(ShqRadius.md),
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(ShqRadius.md),
          borderSide: BorderSide(color: scheme.primary, width: 1.4),
        ),
      ),
      // 对话框：比卡片再圆一档，背景用 High 而不是 Low —— 浮在内容之上。
      dialogTheme: DialogThemeData(
        backgroundColor: scheme.surfaceContainerHigh,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(ShqRadius.xl),
          side: BorderSide(color: scheme.outlineVariant),
        ),
        titleTextStyle: TextStyle(
          fontSize: ShqType.title,
          fontWeight: FontWeight.w600,
          color: scheme.onSurface,
          height: ShqType.lineHeightTitle,
          leadingDistribution: TextLeadingDistribution.even,
        ),
        contentTextStyle: TextStyle(
          fontSize: ShqType.bodySmall,
          height: ShqType.lineHeightBody,
          color: scheme.onSurfaceVariant,
          leadingDistribution: TextLeadingDistribution.even,
        ),
      ),
      // 浮层：背景透明，由页面自己的容器画圆角与把手（两处浮层都这么干）。
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: Colors.transparent,
        modalBackgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(ShqRadius.xl),
          ),
        ),
      ),
      // 菜单：高对比表面 + 16 圆角 + 很浅的阴影；禁用项自然变灰。
      popupMenuTheme: PopupMenuThemeData(
        color: scheme.surfaceContainerHigh,
        surfaceTintColor: Colors.transparent,
        elevation: 3,
        shadowColor: Colors.black.withValues(alpha: dark ? 0.45 : 0.12),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(ShqRadius.md),
          side: BorderSide(color: scheme.outlineVariant),
        ),
        textStyle: TextStyle(
          fontSize: ShqType.bodySmall,
          color: scheme.onSurface,
          height: 1.35,
        ),
        labelTextStyle: WidgetStateProperty.resolveWith<TextStyle?>(
          (Set<WidgetState> states) => TextStyle(
            fontSize: ShqType.bodySmall,
            color: states.contains(WidgetState.disabled)
                ? scheme.outline
                : scheme.onSurface,
          ),
        ),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          visualDensity: VisualDensity.standard,
          textStyle: const WidgetStatePropertyAll<TextStyle>(
            TextStyle(
              fontSize: ShqType.bodySmall,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.2,
            ),
          ),
          shape: const WidgetStatePropertyAll<OutlinedBorder>(StadiumBorder()),
          side: WidgetStatePropertyAll<BorderSide>(
            BorderSide(color: scheme.outlineVariant),
          ),
          backgroundColor: WidgetStateProperty.resolveWith<Color>(
            (Set<WidgetState> states) => states.contains(WidgetState.selected)
                ? scheme.secondaryContainer
                : Colors.transparent,
          ),
          foregroundColor: WidgetStateProperty.resolveWith<Color>(
            (Set<WidgetState> states) => states.contains(WidgetState.selected)
                ? scheme.onSecondaryContainer
                : scheme.onSurfaceVariant,
          ),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(0, ShqLayout.minTouchTarget),
          padding: const EdgeInsets.symmetric(horizontal: ShqSpace.lg),
          elevation: 0,
          textStyle: const TextStyle(
            fontSize: ShqType.bodySmall,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.2,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(ShqRadius.md),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(0, ShqLayout.minTouchTarget),
          padding: const EdgeInsets.symmetric(horizontal: ShqSpace.lg),
          side: BorderSide(color: scheme.outlineVariant),
          textStyle: const TextStyle(
            fontSize: ShqType.bodySmall,
            fontWeight: FontWeight.w600,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(ShqRadius.md),
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          textStyle: const TextStyle(
            fontSize: ShqType.bodySmall,
            fontWeight: FontWeight.w600,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(ShqRadius.sm),
          ),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: ButtonStyle(
          iconSize: const WidgetStatePropertyAll<double>(22),
          foregroundColor: WidgetStateProperty.resolveWith<Color>(
            (Set<WidgetState> states) => states.contains(WidgetState.disabled)
                ? scheme.outlineVariant
                : scheme.onSurfaceVariant,
          ),
          shape: const WidgetStatePropertyAll<OutlinedBorder>(CircleBorder()),
        ),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        elevation: 1,
        focusElevation: 1,
        hoverElevation: 1,
        highlightElevation: 2,
        backgroundColor: scheme.primaryContainer,
        foregroundColor: scheme.onPrimaryContainer,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(ShqRadius.lg),
        ),
        extendedTextStyle: const TextStyle(
          fontSize: ShqType.bodySmall,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.2,
        ),
      ),
      sliderTheme: SliderThemeData(
        trackHeight: 3,
        activeTrackColor: scheme.primary,
        inactiveTrackColor: scheme.surfaceContainerHighest,
        thumbColor: scheme.primary,
        overlayColor: scheme.primary.withValues(alpha: 0.12),
        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 8),
        overlayShape: const RoundSliderOverlayShape(overlayRadius: 18),
        valueIndicatorColor: scheme.inverseSurface,
        showValueIndicator: ShowValueIndicator.never,
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: scheme.primary,
        linearTrackColor: scheme.surfaceContainerHighest,
        circularTrackColor: Colors.transparent,
      ),
      scrollbarTheme: ScrollbarThemeData(
        thickness: const WidgetStatePropertyAll<double>(4),
        radius: const Radius.circular(ShqRadius.pill),
        thumbColor: WidgetStatePropertyAll<Color>(
          scheme.onSurfaceVariant.withValues(alpha: 0.35),
        ),
        trackColor: const WidgetStatePropertyAll<Color>(Colors.transparent),
        trackVisibility: const WidgetStatePropertyAll<bool>(false),
      ),
      textSelectionTheme: TextSelectionThemeData(
        cursorColor: scheme.primary,
        selectionColor: scheme.primary.withValues(alpha: 0.24),
        selectionHandleColor: scheme.primary,
      ),
      // 提示条 / 工具提示：**暗色下不能用 `inverseSurface`**。
      //
      // 2026-10-24 实测根因：M3 的 `inverseSurface` 在**暗色**主题里是**浅色**
      // （它按定义就是"surface 的反色"，暗色 surface 的反面是浅色），
      // 所以直接用它做底色 → 暗色界面里弹出一条**白底**小横条，
      // 在暖黑纸面上格外刺眼（用户 2026-10-24 报"提示条都是白的"）。
      //
      // 改法：暗色走**表面阶梯**（`surfaceContainerHighest` = #2B3941 深灰）
      // + `onSurface`（#E3E9EE 浅字）；浅色保持 `inverseSurface`（深底浅字）。
      // 两套主题都是"深底浅字"，心智模型统一。
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: dark
            ? scheme.surfaceContainerHighest
            : scheme.inverseSurface,
        contentTextStyle: TextStyle(
          color: dark ? scheme.onSurface : scheme.onInverseSurface,
          fontSize: ShqType.bodySmall,
          height: 1.4,
        ),
        // 暗色下"深灰底 + 深灰界面"边界弱，补一道发丝线让浮层显形
        // （浅色下 inverseSurface 与页面差异够大，不需要）。
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(ShqRadius.md),
          side: dark
              ? BorderSide(color: scheme.outlineVariant)
              : BorderSide.none,
        ),
      ),
      // 工具提示同源问题：暗色下 inverseSurface 同样是浅色，一并改掉。
      tooltipTheme: TooltipThemeData(
        waitDuration: const Duration(milliseconds: 500),
        decoration: BoxDecoration(
          color: dark ? scheme.surfaceContainerHighest : scheme.inverseSurface,
          borderRadius: BorderRadius.circular(ShqRadius.sm),
          border: dark ? Border.all(color: scheme.outlineVariant) : null,
        ),
        textStyle: TextStyle(
          color: dark ? scheme.onSurface : scheme.onInverseSurface,
          fontSize: ShqType.caption,
          height: 1.3,
        ),
        padding: const EdgeInsets.symmetric(
          horizontal: ShqSpace.md,
          vertical: ShqSpace.sm,
        ),
      ),
      // Switch 的统一尺寸：默认轨道偏小，平板手指点起来不够明确。
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith<Color>(
          (Set<WidgetState> states) => states.contains(WidgetState.selected)
              ? scheme.onPrimary
              : scheme.outline,
        ),
        trackColor: WidgetStateProperty.resolveWith<Color>(
          (Set<WidgetState> states) => states.contains(WidgetState.selected)
              ? scheme.primary
              : scheme.surfaceContainerHighest,
        ),
        trackOutlineColor: WidgetStateProperty.resolveWith<Color>(
          (Set<WidgetState> states) => states.contains(WidgetState.selected)
              ? Colors.transparent
              : scheme.outlineVariant,
        ),
      ),
    );
  }

  /// 字阶在这里落地成 TextTheme。行高对中文比字号更影响可读性，所以逐级写死。
  ///
  /// 2026-10-23 补齐 15 级：之前只定义了 9 级，`titleSmall` / `labelMedium`
  /// 落到 Material 默认值（Roboto 的字面大小与字重），中英混排时明显"不是一套字"。
  static TextTheme _textTheme(ColorScheme scheme) {
    final List<String> fallback = <String>[
      'Noto Sans CJK SC',
      'Noto Sans SC',
      'Source Han Sans SC',
      'PingFang SC',
      'Microsoft YaHei',
    ];

    TextStyle base(
      double size, {
      FontWeight weight = FontWeight.w400,
      double height = ShqType.lineHeightBody,
      double letterSpacing = 0,
    }) {
      return TextStyle(
        fontSize: size,
        fontWeight: weight,
        height: height,
        letterSpacing: letterSpacing,
        color: scheme.onSurface,
        fontFamilyFallback: fallback,
        // 中英混排：让行盒按字形平均分布，数字/英文不会比汉字飘高半行。
        leadingDistribution: TextLeadingDistribution.even,
      );
    }

    return TextTheme(
      displayLarge: base(
        48,
        weight: FontWeight.w700,
        height: 1.12,
        letterSpacing: -0.5,
      ),
      displayMedium: base(
        40,
        weight: FontWeight.w700,
        height: 1.15,
        letterSpacing: -0.3,
      ),
      displaySmall: base(
        ShqType.display,
        weight: FontWeight.w600,
        height: 1.18,
        letterSpacing: -0.2,
      ),
      headlineLarge: base(
        30,
        weight: FontWeight.w600,
        height: ShqType.lineHeightTitle,
      ),
      headlineMedium: base(
        ShqType.headline,
        weight: FontWeight.w600,
        height: ShqType.lineHeightTitle,
      ),
      headlineSmall: base(
        22,
        weight: FontWeight.w600,
        height: ShqType.lineHeightTitle,
      ),
      titleLarge: base(
        ShqType.title,
        weight: FontWeight.w600,
        height: ShqType.lineHeightTitle,
        letterSpacing: ShqType.letterSpacingTitle,
      ),
      titleMedium: base(ShqType.body, weight: FontWeight.w600, height: 1.4),
      titleSmall: base(
        ShqType.titleSmall,
        weight: FontWeight.w600,
        height: 1.4,
      ),
      bodyLarge: base(ShqType.body),
      bodyMedium: base(ShqType.bodySmall),
      bodySmall: base(ShqType.caption, height: 1.55),
      labelLarge: base(
        ShqType.bodySmall,
        weight: FontWeight.w600,
        height: 1.3,
        letterSpacing: ShqType.letterSpacingTitle,
      ),
      labelMedium: base(
        ShqType.caption,
        weight: FontWeight.w500,
        height: 1.3,
        letterSpacing: ShqType.letterSpacingLabel,
      ),
      labelSmall: base(
        11,
        weight: FontWeight.w500,
        height: 1.3,
        letterSpacing: ShqType.letterSpacingTitle,
      ),
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
