/// 列表/网格首次出现的**逐次淡入**（决策 F12 / 规范 §8.3 第 3 条）。
///
/// * 第 `index` 项延迟 `index * 20ms`，再花 `DsMotion.list`（180ms）淡入；
/// * **最多前 6 项**参与（`DsMotion.staggerMax`），第 7 项起直接显示 —— 长列表滚动时
///   不重放动画，也不给每项挂一个动画控制器；
/// * 只在**首次挂载**时播一次（重建不重播）；
/// * 系统「减少动画」打开时（`DsMotion.none`）直接显示，不动画。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../theme/motion.dart';

class DsStaggerFade extends StatefulWidget {
  const DsStaggerFade({super.key, required this.index, required this.child});

  /// 它在列表里的序号（0 起）。
  final int index;

  final Widget child;

  @override
  State<DsStaggerFade> createState() => _DsStaggerFadeState();
}

class _DsStaggerFadeState extends State<DsStaggerFade> {
  /// 第 7 项起（index >= staggerMax）不参与淡入：一开始就是「已显示」。
  late bool _shown = widget.index >= DsMotion.staggerMax;

  Timer? _timer;

  @override
  void initState() {
    super.initState();
    if (_shown) return;
    _timer = Timer(DsMotion.staggerDelay(widget.index), () {
      if (mounted) setState(() => _shown = true);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _timer = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final DsMotion m = DsMotion.of(context);
    // 减少动画：不包 AnimatedOpacity（时长 0 的透明度动画在测试里也会多一帧）。
    if (m.list == Duration.zero) return widget.child;
    return AnimatedOpacity(
      opacity: _shown ? 1 : 0,
      duration: m.list,
      curve: DsMotion.listCurve,
      child: widget.child,
    );
  }
}
