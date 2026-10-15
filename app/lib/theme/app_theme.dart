/// 组装外壳的 [ThemeData]：把新拟态规范（`docs/specs/2026-10-10-dsanima-neo-theme.md` §7）
/// 落到 Material 组件主题上。
///
/// 原则：
/// * **elevation 一律 0** —— 深度由 `DsTokens.shadows()` 负责，不用 Material 的 elevation；
/// * **无硬边框** —— 去掉旧的 `BorderSide(color: line)`，只留焦点态 2px 强调色描边；
/// * Material 默认控件（开关/滑块/按钮/输入/卡片/弹窗/提示）全部改成凹槽 + 凸起形态，
///   这样宿主 17 个页面里**已经在用**的 Material 控件会整体跟着变，不必逐处重写。
library;

import 'package:flutter/material.dart';

import 'tokens.dart';

ThemeData buildDsanimaTheme({DsTokens tokens = DsTokens.whiteInk}) {
  final bool dark = tokens.isDark;
  final ColorScheme scheme = ColorScheme.fromSeed(
    seedColor: tokens.accent,
    brightness: dark ? Brightness.dark : Brightness.light,
  ).copyWith(
    surface: tokens.raised,
    onSurface: tokens.text,
    primary: tokens.accent,
    onPrimary: dark ? tokens.base : Colors.white,
    secondary: tokens.accent,
    error: tokens.danger,
    onError: dark ? tokens.base : Colors.white,
    outline: tokens.line,
    surfaceContainerHighest: tokens.sunken,
    surfaceContainerHigh: tokens.raised,
    surfaceContainer: tokens.raised,
    surfaceContainerLow: tokens.base,
    surfaceContainerLowest: tokens.base,
  );

  TextStyle num(TextStyle s) => s.copyWith(
        fontFeatures: DsTokens.tabular,
        height: s.height ?? 1.45,
      );

  // 凹槽输入框：sunken 面 + 1px line 描边（页面侧用 DsInset；这里给 Material 的兜底形态）。
  OutlineInputBorder border(Color c, [double w = 1]) => OutlineInputBorder(
        borderRadius: BorderRadius.circular(tokens.radiusControl),
        borderSide: BorderSide(color: c, width: w),
      );

  final RoundedRectangleBorder controlShape = RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(tokens.radiusControl),
  );
  final RoundedRectangleBorder cardShape = RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(tokens.radiusCard),
  );
  /// 卡片专用：**带 1px `line` 描边**（规范 §3）。悬浮层不加描边（规范 §7），所以
  /// `cardShape` 本身不带边，弹窗/底部弹层继续用它。
  final RoundedRectangleBorder cardShapeLined = RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(tokens.radiusCard),
    side: BorderSide(color: tokens.line, width: 1),
  );

  return ThemeData(
    useMaterial3: true,
    brightness: dark ? Brightness.dark : Brightness.light,
    fontFamily: dsFontFamily,
    fontFamilyFallback: dsFontFallback,
    scaffoldBackgroundColor: tokens.base,
    canvasColor: tokens.base,
    // 桌面高密度：不强制 48px 点击目标，控件按 controlHeight 走。
    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    visualDensity: VisualDensity.compact,
    colorScheme: scheme,
    // 新拟态不用 Material 阴影。
    shadowColor: Colors.transparent,
    splashFactory: NoSplash.splashFactory,
    highlightColor: Colors.transparent,
    hoverColor: tokens.raised,
    dividerColor: tokens.line,
    dividerTheme: DividerThemeData(
      color: tokens.divider,
      space: 1,
      thickness: 1,
    ),
    extensions: <ThemeExtension<dynamic>>[tokens],
    textTheme: TextTheme(
      // 5 档字号阶梯（决策 A35）：11 / 12 / 13 / 15 / 20。
      displaySmall: num(TextStyle(
          fontSize: DsTypeScale.display,
          fontWeight: FontWeight.w600,
          color: tokens.text,
          height: 1.25)),
      titleMedium: num(TextStyle(
          fontSize: DsTypeScale.title,
          fontWeight: FontWeight.w600,
          color: tokens.text,
          height: 1.25)),
      titleSmall: num(TextStyle(
          fontSize: DsTypeScale.body,
          fontWeight: FontWeight.w600,
          color: tokens.text)),
      bodyMedium:
          num(TextStyle(fontSize: DsTypeScale.body, color: tokens.text)),
      bodySmall:
          num(TextStyle(fontSize: DsTypeScale.secondary, color: tokens.text2)),
      labelLarge: num(TextStyle(
          fontSize: DsTypeScale.body,
          fontWeight: FontWeight.w600,
          color: tokens.text)),
      labelMedium:
          num(TextStyle(fontSize: DsTypeScale.caption, color: tokens.text2)),
    ),
    // 卡片（规范 §3）：`raised` 面 + 1px `line` 描边 + 圆角 12，**零阴影**。
    cardTheme: CardThemeData(
      color: tokens.raised,
      elevation: 0,
      shadowColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      margin: EdgeInsets.zero,
      shape: cardShapeLined,
    ),
    inputDecorationTheme: InputDecorationTheme(
      isDense: true,
      filled: true,
      fillColor: tokens.sunken, // 凹槽底色
      hintStyle:
          TextStyle(color: tokens.text3, fontSize: DsTypeScale.secondary),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      // 扁平化（规范 §6）：输入框 = `sunken` 面 + 1px `line` 描边；焦点 = 强调色 2px。
      border: border(tokens.line, 1),
      enabledBorder: border(tokens.line, 1),
      focusedBorder: border(tokens.accent, 2), // 焦点态：强调色 2px（规范 §7）
      errorBorder: border(tokens.danger, 1.5),
      focusedErrorBorder: border(tokens.danger, 2),
      disabledBorder: border(tokens.line, 1),
    ),
    // 主按钮（规范 §6）：**accent 实底 + onAccent 文字**（不再是"凸起 + 强调色描边"）。
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: tokens.accent,
        foregroundColor: tokens.onAccent,
        disabledBackgroundColor: tokens.sunken,
        disabledForegroundColor: tokens.text3,
        elevation: 0,
        minimumSize: Size(0, tokens.controlHeight),
        side: BorderSide.none,
        shape: controlShape,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        textStyle: TextStyle(
            fontSize: DsTypeScale.body, fontWeight: FontWeight.w600),
      ),
    ),
    // 次按钮：只凹凸，无边框。
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        backgroundColor: tokens.raised,
        foregroundColor: tokens.text,
        disabledBackgroundColor: tokens.sunken,
        disabledForegroundColor: tokens.text3,
        elevation: 0,
        minimumSize: Size(0, tokens.controlHeight),
        side: BorderSide(color: tokens.line, width: 1),
        shape: controlShape,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        textStyle: TextStyle(fontSize: DsTypeScale.body),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: tokens.accent,
        disabledForegroundColor: tokens.text3,
        minimumSize: Size(0, tokens.controlHeight),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        shape: controlShape,
        textStyle: TextStyle(fontSize: DsTypeScale.body),
      ),
    ),
    iconTheme: IconThemeData(color: tokens.text2, size: 16),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(
        foregroundColor: tokens.text2,
        highlightColor: Colors.transparent,
        shape: controlShape,
      ),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: tokens.accent,
      linearTrackColor: tokens.sunken,
      circularTrackColor: tokens.sunken,
    ),
    // 滑块（规范 §6）：轨道走凹槽色、填充走强调色，圆钮**accent 实心**。
    sliderTheme: SliderThemeData(
      activeTrackColor: tokens.accent,
      inactiveTrackColor: tokens.sunken,
      thumbColor: tokens.accent,
      overlayColor: Colors.transparent,
      trackHeight: 4,
    ),
    // 开关（规范 §6）：关 = sunken 轨道，开 = **accent 实底**轨道，圆钮 raised。
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((Set<WidgetState> s) =>
          s.contains(WidgetState.selected) ? tokens.raised : tokens.raised),
      trackColor: WidgetStateProperty.resolveWith((Set<WidgetState> s) =>
          s.contains(WidgetState.selected) ? tokens.accent : tokens.sunken),
      trackOutlineColor: WidgetStateProperty.all<Color>(Colors.transparent),
      overlayColor: WidgetStateProperty.all<Color>(Colors.transparent),
    ),
    checkboxTheme: CheckboxThemeData(
      fillColor: WidgetStateProperty.resolveWith((Set<WidgetState> s) =>
          s.contains(WidgetState.selected) ? tokens.accent : tokens.sunken),
      checkColor: WidgetStateProperty.all<Color>(tokens.onAccent),
      side: BorderSide(color: tokens.line, width: 1),
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(tokens.radiusControl * 0.35)),
    ),
    radioTheme: RadioThemeData(
      fillColor: WidgetStateProperty.resolveWith((Set<WidgetState> s) =>
          s.contains(WidgetState.selected) ? tokens.accent : tokens.text3),
      overlayColor: WidgetStateProperty.all<Color>(Colors.transparent),
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: tokens.raised,
        borderRadius: BorderRadius.circular(tokens.radiusControl),
        boxShadow: tokens.shadows(NeoShadowLevel.high),
      ),
      textStyle: TextStyle(color: tokens.text, fontSize: DsTypeScale.secondary),
    ),
    // ── 悬浮层（规范 §7）：唯一允许阴影的层，高度统一走 `overlayElevation` ──────
    snackBarTheme: SnackBarThemeData(
      backgroundColor: tokens.raised,
      contentTextStyle:
          TextStyle(color: tokens.text, fontSize: DsTypeScale.body),
      behavior: SnackBarBehavior.floating,
      elevation: tokens.overlayElevation,
      shape: controlShape,
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: tokens.raised,
      surfaceTintColor: Colors.transparent,
      shadowColor: tokens.shadowDark,
      elevation: tokens.overlayElevation,
      shape: cardShape,
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: tokens.raised,
      surfaceTintColor: Colors.transparent,
      elevation: tokens.overlayElevation,
      shape: cardShape,
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: tokens.raised,
      surfaceTintColor: Colors.transparent,
      shadowColor: tokens.shadowDark,
      elevation: tokens.overlayElevation,
      shape: controlShape,
      textStyle: TextStyle(color: tokens.text, fontSize: DsTypeScale.body),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: tokens.sunken,
      selectedColor: tokens.accentSoft,
      side: BorderSide(color: Colors.transparent),
      labelStyle: TextStyle(color: tokens.text, fontSize: DsTypeScale.secondary),
      secondaryLabelStyle:
          TextStyle(color: tokens.text2, fontSize: DsTypeScale.secondary),
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(tokens.radiusPill)),
    ),
    scrollbarTheme: ScrollbarThemeData(
      thumbColor: WidgetStateProperty.all<Color>(
          tokens.line.withValues(alpha: 0.9)),
      trackColor: WidgetStateProperty.all<Color>(Colors.transparent),
      thickness: WidgetStateProperty.all<double>(6),
      radius: const Radius.circular(3),
    ),
    tabBarTheme: TabBarThemeData(
      labelColor: tokens.text,
      unselectedLabelColor: tokens.text3,
      indicatorColor: tokens.accent,
      indicatorSize: TabBarIndicatorSize.label,
      dividerColor: Colors.transparent,
      labelStyle:
          TextStyle(fontSize: DsTypeScale.body, fontWeight: FontWeight.w600),
      unselectedLabelStyle: TextStyle(fontSize: DsTypeScale.body),
    ),
    listTileTheme: ListTileThemeData(
      iconColor: tokens.text2,
      textColor: tokens.text,
      selectedTileColor: tokens.accentSoft,
      shape: controlShape,
      dense: true,
    ),
    // 表格（决策 A43）：无斑马纹、无竖线，表头 11px + 字距。
    dataTableTheme: DataTableThemeData(
      headingRowColor: WidgetStateProperty.all<Color>(Colors.transparent),
      dataRowColor: WidgetStateProperty.all<Color>(Colors.transparent),
      headingTextStyle: dsTableHeaderStyle(tokens),
      dataTextStyle: TextStyle(
          color: tokens.text,
          fontSize: DsTypeScale.body,
          fontFeatures: DsTokens.tabular),
      dividerThickness: 1,
      horizontalMargin: 12,
    ),
  );
}
