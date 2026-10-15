/// **Circular Reveal 换外观**（第三十三轮，用户：「点击外观直接转换，不用点保存，
/// 使用动画Circular Reveal」）。
///
/// ## 为什么不是"给颜色做插值"
///
/// 原来换外观走 `MaterialApp.themeAnimationDuration`，`DsTokens.lerp` 把两套色表**线性插值**
/// 240ms。用户报的「处于白色系时点击黑白，会出现黑白字消失的问题，可能是颜色混一起了」，
/// 真身就是这个插值：白底黑字 ⇄ 黑底白字，`Color.lerp(白, 黑, 0.5)` **两边都是中灰** ——
/// 文字与背景在中点**同色**，于是"字消失了"。
///
/// 现在换外观**不做颜色插值**（[DsThemeRevealHost] 之外的 `themeAnimationDuration` = 0）：
/// 新配色一步到位，旧界面以**一张快照**的形式被一个从点击处张开的圆逐步"揭开"。
/// 因为任何一个像素在任何一帧都只有"旧"或"新"两种配色之一，中间态不存在 ⇒ 那条
/// 对比度塌陷的路径被**结构性地**删掉了，不是被调参掩盖。
///
/// ## 快照是怎么来的
///
/// `RepaintBoundary.toImage()` 把**当前这一帧的整窗**拍成一张位图（一次性、用户点击时才做）。
/// 揭开过程里：圆外画这张快照（看上去还是旧界面，只是静止的），圆内是真的新界面。
/// 这就是 Android `ViewAnimationUtils.createCircularReveal` 的语义 —— 圆外是"之前那一屏"。
///
/// ## 三条硬约束
///
/// 1. **绝不重建整棵树**：快照层是 Stack 里的一个**兄弟**，动画结束只是把它换成空盒子，
///    第一子永远是业务树（换成 ClipPath 包住整棵树的做法会让整棵树重新挂载 ——
///    状态丢失 + 闪一下，`app.dart` 的老注释里记着这次教训）；
/// 2. **失败就退回"直接换"**：拍不到快照（首帧未画、无 GPU 边界、测试环境）或系统开了
///    「减少动画」时，不演直接生效 —— 宁可没有动画，也不要黑屏一下；
/// 3. 快照 `ui.Image` 用完 `dispose()`（整窗位图，别让它留在内存里）。
library;

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;

import '../../theme/motion.dart';

/// 包住整个界面、负责"圆形揭开"的那一层。
///
/// 用法：任何后代拿到 context 后
/// `context.findAncestorStateOfType<DsThemeRevealHostState>()?.revealFrom(...)`。
/// 取不到宿主（比如把页面单独挂在测试里）= 不演动画、直接生效。
class DsThemeRevealHost extends StatefulWidget {
  const DsThemeRevealHost({super.key, required this.child});

  final Widget child;

  @override
  State<DsThemeRevealHost> createState() => DsThemeRevealHostState();
}

class DsThemeRevealHostState extends State<DsThemeRevealHost>
    with SingleTickerProviderStateMixin {
  final GlobalKey _boundaryKey = GlobalKey();

  late final AnimationController _anim = AnimationController(
    vsync: this,
    duration: DsMotion.themeBase,
  );

  ui.Image? _snapshot;
  Offset? _origin;
  double _radius = 0;
  bool _busy = false;

  /// 测试用：揭开是否正在演（`ds_theme_reveal_test.dart` 靠它断言"演过 / 没演"）。
  bool get isRevealing => _snapshot != null;

  @override
  void initState() {
    super.initState();
    _anim.addListener(() {
      final Offset? origin = _origin;
      if (origin == null) return;
      setState(() => _radius = _maxRadius(origin) * _anim.value);
    });
  }

  @override
  void dispose() {
    _snapshot?.dispose();
    _snapshot = null;
    _anim.dispose();
    super.dispose();
  }

  /// 从 [origin]（全局坐标）揭开，并在**同一帧**里执行 [apply]（真正换配色）。
  ///
  /// [apply] 必须是同步生效的（改内存里的主题 provider 就是同步的；落盘可以在它内部异步做）。
  Future<void> revealFrom({
    required Offset origin,
    required VoidCallback apply,
  }) async {
    if (_busy || !mounted) {
      apply();
      return;
    }
    _busy = true;
    final bool animate = DsMotion.of(context).theme > Duration.zero;
    ui.Image? shot;
    if (animate) {
      shot = await _capture();
    }
    if (!mounted) {
      shot?.dispose();
      _busy = false;
      return;
    }
    apply(); // 换配色（同步生效）
    if (shot == null || !animate) {
      shot?.dispose();
      _busy = false;
      return;
    }
    _anim.duration = DsMotion.of(context).theme;
    setState(() {
      _snapshot?.dispose();
      _snapshot = shot;
      _origin = origin;
      _radius = 0;
    });
    try {
      await _anim.forward(from: 0);
    } finally {
      if (mounted) {
        setState(() {
          _snapshot?.dispose();
          _snapshot = null;
          _origin = null;
        });
      } else {
        _snapshot?.dispose();
        _snapshot = null;
      }
      _busy = false;
    }
  }

  /// 拍下当前这一帧。失败（未布局/未画/无边界）返回 null —— 调用方退回"直接换"。
  Future<ui.Image?> _capture() async {
    try {
      final RenderObject? object = _boundaryKey.currentContext?.findRenderObject();
      if (object is! RenderRepaintBoundary || object.debugNeedsPaint) return null;
      final double dpr = MediaQuery.maybeDevicePixelRatioOf(context) ?? 1.0;
      return await object.toImage(pixelRatio: dpr <= 0 ? 1.0 : dpr);
    } catch (_) {
      // 拍不到就不演（不抛给用户：换外观本身绝不能失败）。
      return null;
    }
  }

  /// 从 [origin] 到四个角的最远距离（圆要能盖满整窗）。
  double _maxRadius(Offset origin) {
    final Size size = MediaQuery.maybeSizeOf(context) ??
        (context.findRenderObject() as RenderBox?)?.size ??
        Size.zero;
    double best = 0;
    for (final Offset corner in <Offset>[
      Offset.zero,
      Offset(size.width, 0),
      Offset(0, size.height),
      Offset(size.width, size.height),
    ]) {
      best = math.max(best, (corner - origin).distance);
    }
    return best <= 0 ? 1 : best;
  }

  @override
  Widget build(BuildContext context) {
    final ui.Image? shot = _snapshot;
    final Offset? origin = _origin;
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        // ⚠️ 第一子**永远是**业务树（同类型同位置）—— 动画起止都不换包裹 widget，
        // 所以整棵树一次都不重建（老注释里那次教训）。
        RepaintBoundary(key: _boundaryKey, child: widget.child),
        if (shot != null && origin != null)
          Positioned.fill(
            child: IgnorePointer(
              child: ClipPath(
                key: const Key('ds-theme-reveal-veil'),
                clipper: _OutsideCircleClipper(center: origin, radius: _radius),
                child: RawImage(
                  image: shot,
                  fit: BoxFit.fill,
                  // 位图按设备像素比拍的，这里按逻辑尺寸铺满整窗。
                  filterQuality: FilterQuality.low,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// 只画**圆外**那部分（圆内露出新界面）。
class _OutsideCircleClipper extends CustomClipper<Path> {
  const _OutsideCircleClipper({required this.center, required this.radius});

  final Offset center;
  final double radius;

  @override
  Path getClip(Size size) {
    final Path full = Path()..addRect(Offset.zero & size);
    if (radius <= 0) return full;
    final Path hole = Path()
      ..addOval(Rect.fromCircle(center: center, radius: radius));
    return Path.combine(PathOperation.difference, full, hole);
  }

  @override
  bool shouldReclip(_OutsideCircleClipper oldClipper) =>
      oldClipper.center != center || oldClipper.radius != radius;
}
