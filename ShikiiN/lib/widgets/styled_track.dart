import 'package:flutter/material.dart';

/// 进度/音量条轨道高（视觉基准，内联常量：主题预设系统已删）。
const double kTrackHeight = 4;

/// 按极简新拟态渲染的进度/音量条视觉：凹槽轨道 + 强调色填充 + 悬停胶囊拖钮。
/// 只负责画；手势（拖拽/点击）由外层处理。
class StyledTrack extends StatelessWidget {
  /// 0..1
  final double fraction;
  /// 填充与拖钮外圈色（强调色）。
  final Color accent;
  /// 凹槽轨道色。
  final Color track;
  /// 拖钮内芯色；null = 用 [accent]。
  final Color? thumbColor;
  /// 轨道高度（默认 4，悬停时 +1）。
  final double trackHeight;
  /// 0..1 悬停/拖动进度。
  final double hoverT;
  /// 绘制与命中区高度。
  final double height;

  const StyledTrack({
    super.key,
    required this.fraction,
    required this.accent,
    required this.track,
    this.thumbColor,
    this.trackHeight = kTrackHeight,
    this.hoverT = 0,
    this.height = 20,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, cons) {
      final w = cons.maxWidth.isFinite ? cons.maxWidth : 0.0;
      final h = trackHeight + hoverT;
      final f = fraction.clamp(0.0, 1.0);
      // 直角轨道：用户 2026-10-10「进度条那一栏的内圆角去掉」。
      // 原来这里给的是 `BorderRadius.circular(trackHeight)` —— 4px 高的轨道配 4px 半径
      // 就是胶囊，于是**填充块的右端在轨道里留一个半圆内圆角**。改成零半径。
      const BorderRadius radius = BorderRadius.zero;

      return SizedBox(
        height: height,
        width: double.infinity,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            // 凹槽轨道
            Positioned.fill(
              child: Center(
                child: Container(
                  height: h,
                  decoration: BoxDecoration(borderRadius: radius, color: track),
                ),
              ),
            ),
            // 已播放填充
            Positioned(
              left: 0,
              top: 0,
              bottom: 0,
              width: f * w,
              child: Center(
                child: Container(
                  height: h,
                  decoration: BoxDecoration(borderRadius: radius, color: accent),
                ),
              ),
            ),
            // 拖钮：平时隐藏，悬停/拖动时升起（胶囊，外圈强调色 + 内芯面色）。
            if (hoverT > 0)
              Positioned(
                left: f * w,
                top: 0,
                bottom: 0,
                width: 0,
                child: Center(
                  // 零宽锚点 + OverflowBox：让拖钮以进度位置为「中心」并可溢出边缘。
                  child: OverflowBox(
                    maxWidth: double.infinity,
                    maxHeight: double.infinity,
                    child: Opacity(
                      opacity: hoverT.clamp(0.0, 1.0),
                      child: Container(
                        width: 15,
                        height: 11,
                        padding: const EdgeInsets.all(2),
                        decoration: BoxDecoration(
                          color: accent,
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: thumbColor ?? accent,
                            borderRadius: BorderRadius.circular(999),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      );
    });
  }
}
