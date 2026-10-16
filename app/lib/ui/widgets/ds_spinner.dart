/// iOS 风格加载圆环（用户 2026-10-12 第八轮：「加载旋转现在的太丑不符合，改成 iOS 的」）。
///
/// 形状：底下一圈极淡的同色轨迹 + 一段 300° 的「头亮尾淡」拖尾弧，12 点方向起画、
/// 顺时针匀速转，1 秒一圈（参数都是用户 2026-10-12 第八轮问答里定的）。
///
/// **为什么不用 `CupertinoActivityIndicator`**：那个是 iOS 老式的「8 根渐隐辐条」，
/// 用户明确要的是「单圈渐变弧线（Safari / 新 iOS 那种圆环）」，是另一种观感。
///
/// **为什么不用 `CircularProgressIndicator`**：它是 Material 的观感 —— 弧长会在
/// 10°–270° 之间呼吸伸缩、还带一条固定色轨道，跟拖尾弧完全不是一回事。
///
/// 性能：动画走 `CustomPainter(repaint: controller)`，**每帧只重画、不重建 widget**
/// （不 `setState`），外面再包一层 [RepaintBoundary] —— 搜索结果里可能同时挂着
/// 几十个行内转圈，不能让它们把整棵树卷进重绘。
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../theme/tokens.dart';

/// iOS 风格加载圆环。
///
/// 三档尺寸是规范里定好的（用户 2026-10-12 第八轮确认「尺寸照旧」）：
/// [DsSpinner.page] 16px 带底轨、[DsSpinner.inline] 14px、[DsSpinner.button] 13px。
/// 小尺寸**省略底轨**、线宽降到 1.6px：13/14px 下轨迹和弧线挤在一起会糊成一个小饼。
class DsSpinner extends StatefulWidget {
  /// 通用构造（默认 = 页面加载那一档）。
  const DsSpinner({
    super.key,
    this.size = 16,
    this.strokeWidth = 2,
    this.color,
    this.showTrack = true,
  });

  /// 页面加载（`DsLoading`）：16px / 2.0px 线宽 / 带底轨。
  const DsSpinner.page({super.key, this.color})
      : size = 16,
        strokeWidth = 2,
        showTrack = true;

  /// 按钮忙碌态（`NeoButton.busy`）：13px / 1.6px / 无底轨。
  const DsSpinner.button({super.key, this.color})
      : size = 13,
        strokeWidth = 1.6,
        showTrack = false;

  /// 列表行内（搜索结果「点了播放，正在准备」）：14px / 1.6px / 无底轨。
  const DsSpinner.inline({super.key, this.color})
      : size = 14,
        strokeWidth = 1.6,
        showTrack = false;

  /// 转一圈的时长。
  static const Duration period = Duration(seconds: 1);

  /// 拖尾弧占整圈的比例：300°。
  static const double sweepRatio = 300 / 360;

  /// 圆环直径。
  final double size;

  /// 线宽。
  final double strokeWidth;

  /// 弧线颜色；默认 [DsTokens.accent]，两套外观都自动跟。
  final Color? color;

  /// 是否画底下的淡色轨迹（小尺寸默认关，见类文档）。
  final bool showTrack;

  @override
  State<DsSpinner> createState() => _DsSpinnerState();
}

class _DsSpinnerState extends State<DsSpinner> with SingleTickerProviderStateMixin {
  late final AnimationController _spin = AnimationController(
    vsync: this,
    duration: DsSpinner.period,
  );

  /// 第三十轮：**尊重系统「减少动画」**。原来 `..repeat()` 写死在字段初始化里，
  /// 打开「减少动画」照样转（规范 §8.2：所有动画都要能归零）。
  /// 归零时停在 0 度 —— 画出来是一段静态弧，仍然是"在忙"的图形，只是不动。
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final bool reduce = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    if (reduce) {
      _spin.stop();
    } else if (!_spin.isAnimating) {
      // 无限循环的 TickerFuture 永远不会 resolve，这里明确表示"有意丢弃"。
      unawaited(_spin.repeat());
    }
  }

  @override
  void dispose() {
    _spin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final DsTokens t = context.ds;
    final Color c = widget.color ?? t.accent;
    return RepaintBoundary(
      child: SizedBox.square(
        dimension: widget.size,
        child: CustomPaint(
          // 直接拿 controller 当 `repaint`：每帧只重画，不重建 widget。
          painter: _DsSpinnerPainter(
            spin: _spin,
            color: c,
            // 底轨 = 规范 §6 的 `sunken` 槽（第三十轮改：原来是 accent 的 16%/22% 半透明，
            // 那是调色板里没有的混色，也是唯一一个不用 `sunken` 的槽）。
            trackColor: t.sunken,
            strokeWidth: widget.strokeWidth,
            showTrack: widget.showTrack,
          ),
        ),
      ),
    );
  }
}

/// 画一圈淡轨 + 一段头亮尾淡的拖尾弧。
class _DsSpinnerPainter extends CustomPainter {
  const _DsSpinnerPainter({
    required this.spin,
    required this.color,
    required this.trackColor,
    required this.strokeWidth,
    required this.showTrack,
  }) : super(repaint: spin);

  final Animation<double> spin;
  final Color color;
  final Color trackColor;
  final double strokeWidth;
  final bool showTrack;

  @override
  void paint(Canvas canvas, Size size) {
    // 半径按最短边算并减掉半个线宽，笔触才不会画出边界被裁掉。
    final double radius = (size.shortestSide - strokeWidth) / 2;
    if (radius <= 0) return;
    final Offset center = size.center(Offset.zero);
    final Rect arcRect = Rect.fromCircle(center: center, radius: radius);

    if (showTrack) {
      canvas.drawCircle(
        center,
        radius,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = strokeWidth
          ..color = trackColor,
      );
    }

    // 12 点方向起画。Flutter 画布 y 轴朝下，所以正角度就是屏幕上的顺时针。
    const double start = -math.pi / 2;
    final double sweep = 2 * math.pi * DsSpinner.sweepRatio;
    final double head = start + 2 * math.pi * spin.value;
    final Paint arc = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = strokeWidth
      // 头亮尾淡：起点（弧头）是强调色，终点（弧尾）透明度归零。
      ..shader = SweepGradient(
        startAngle: head,
        endAngle: head + sweep,
        colors: <Color>[
          color,
          // 尾端要淡到全透明，但**必须保留色相** —— 用 `Colors.transparent`
          // 那种全透明黑，会在浅色底上给尾端抹出一道灰边。
          color.withValues(alpha: 0),
        ],
      ).createShader(arcRect);
    canvas.drawArc(arcRect, head, sweep, false, arc);
  }

  @override
  bool shouldRepaint(_DsSpinnerPainter old) =>
      old.color != color ||
      old.trackColor != trackColor ||
      old.strokeWidth != strokeWidth ||
      old.showTrack != showTrack;
}
