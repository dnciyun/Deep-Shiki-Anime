/// 动效 token（规范 §8：**分层时长 + 尊重系统「减少动画」**）。
///
/// 只有这一处定义时长：业务代码**不得**再写 `duration: Duration(milliseconds: …)`
/// （由 `test/neo_guard_test.dart` 的守卫钉住）。动画必须**有限**且可被打断，
/// 禁止 `repeat()`（无限动画会让整页 widget 测试的 `pumpAndSettle` 永远不 settle）。
///
/// 唯一例外是轮播的自动播放，它必须带测试逃生门（`carouselAutoPlayProvider`）。
library;

import 'package:flutter/material.dart';

@immutable
class DsMotion {
  const DsMotion({
    required this.hover,
    required this.press,
    required this.page,
    required this.list,
    required this.overlay,
    required this.carousel,
    required this.theme,
  });

  /// 悬停底色、tooltip 出现。
  final Duration hover;

  /// 按下底色（最短：要「当帧感」）。
  final Duration press;

  /// 页面/标签切换交叉淡入。
  final Duration page;

  /// 列表/网格逐次淡入（每项 +20ms 错峰，最多 [staggerMax] 项）。
  final Duration list;

  /// 弹窗/菜单出现（缩放 0.98→1 + 淡入）。
  final Duration overlay;

  /// 轮播滑动（自动与手动同一条曲线）。
  final Duration carousel;

  /// 切换外观时的颜色插值。
  final Duration theme;

  // ── 基值（规范 §8.1 的表）──────────────────────────────────────────────────
  static const Duration hoverBase = Duration(milliseconds: 90);
  static const Duration pressBase = Duration(milliseconds: 60);
  static const Duration pageBase = Duration(milliseconds: 180);
  static const Duration listBase = Duration(milliseconds: 180);
  static const Duration overlayBase = Duration(milliseconds: 180);
  static const Duration carouselBase = Duration(milliseconds: 320);
  static const Duration themeBase = Duration(milliseconds: 240);

  // ── 曲线（减少动画时时长归零，**曲线不变**）────────────────────────────────
  static const Curve hoverCurve = Curves.easeOut;
  static const Curve pressCurve = Curves.easeOut;
  static const Curve pageCurve = Curves.easeOutCubic;
  static const Curve listCurve = Curves.easeOutCubic;
  static const Curve overlayCurve = Curves.easeOutCubic;
  static const Curve carouselCurve = Curves.easeInOutCubic;
  static const Curve themeCurve = Curves.easeInOut;

  // ── 逐次淡入（决策 F12）────────────────────────────────────────────────────
  /// 每项错峰步长（毫秒）。
  static const double staggerStepMs = 20;

  /// 参与淡入的最大项数：第 [staggerMax] 项起**直接显示**（防滚动卡顿）。
  static const int staggerMax = 6;

  /// 标准时长。
  static const DsMotion standard = DsMotion(
    hover: hoverBase,
    press: pressBase,
    page: pageBase,
    list: listBase,
    overlay: overlayBase,
    carousel: carouselBase,
    theme: themeBase,
  );

  /// 系统「减少动画」下的时长：全为 0。
  static const DsMotion none = DsMotion(
    hover: Duration.zero,
    press: Duration.zero,
    page: Duration.zero,
    list: Duration.zero,
    overlay: Duration.zero,
    carousel: Duration.zero,
    theme: Duration.zero,
  );

  /// 取当前动效设置：`MediaQuery.disableAnimations` 为真 → [none]。
  static DsMotion of(BuildContext context) =>
      (MediaQuery.maybeOf(context)?.disableAnimations ?? false) ? none : standard;

  /// 第 [index] 项的错峰延迟；`>= staggerMax` 的项没有延迟（也不参与淡入）。
  static Duration staggerDelay(int index) => index >= staggerMax
      ? Duration.zero
      : Duration(milliseconds: (index * staggerStepMs).round());
}
