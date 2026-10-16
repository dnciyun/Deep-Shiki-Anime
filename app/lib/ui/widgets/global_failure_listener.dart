/// 把 [globalFailure] 变成用户看得见的一条失败提示（第四十二轮 UX §2.1）。
///
/// 挂在 `MaterialApp.builder` 上（`app.dart`）：那个位置在 `ScaffoldMessenger`
/// **之内**、在业务树与所有弹层**之外**，所以首启向导页与主外壳都覆盖得到，
/// 也不会因为某个页面重建而丢监听。
library;

import 'package:flutter/material.dart';

import '../../domain/error_text.dart';
import '../../state/global_failure.dart';
import 'feedback.dart';

class DsGlobalFailureListener extends StatefulWidget {
  const DsGlobalFailureListener({super.key, required this.child});

  final Widget child;

  @override
  State<DsGlobalFailureListener> createState() => _DsGlobalFailureListenerState();
}

class _DsGlobalFailureListenerState extends State<DsGlobalFailureListener> {
  @override
  void initState() {
    super.initState();
    globalFailure.addListener(_onFailure);
  }

  @override
  void dispose() {
    globalFailure.removeListener(_onFailure);
    super.dispose();
  }

  void _onFailure() {
    final DsFailure? failure = globalFailure.value;
    if (failure == null) return;
    // 推到这一帧之后再弹：异常可能就是在**构建过程中**抛出来的，
    // 那时 showSnackBar 会在 build 里改状态（framework 会直接报错）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final DsFailure? pending = globalFailure.value;
      if (pending == null) return;
      // 文案前缀说清"这不是你刚点的那个动作失败了"，否则用户会去找自己刚干过什么。
      showFailure(
        context,
        DsFailure(
          '出了个没预料到的问题：${pending.message}',
          hint: pending.hint ??
              '这一步已经中断，界面可能停在半路。可以再试一次；'
                  '反复出现就带上下面的细节报给开发者',
          detail: pending.detail,
        ),
      );
      // 展示过就清空：它是事件不是状态（见 global_failure.dart 的说明）。
      clearGlobalFailure();
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
