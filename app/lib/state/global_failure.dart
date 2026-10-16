/// 全局未捕获异常的**用户可见**出口（第四十二轮 `docs/ROUND42-UX.md` §2.1）。
///
/// 背景（这条是 14 个"失败不浮出"缺陷的共同前提）：`main.dart` 的
/// `FlutterError.onError` / `PlatformDispatcher.instance.onError` 原来**只写 stderr**，
/// 注释写明那是给"白窗排查"用的开发者通道。于是任何漏包的 `await` 一旦抛错，
/// 用户侧完全静默 —— 不弹东西、界面停在原处、按钮也不灰。修完 14 处仍会复发，
/// 因为漏网点是**不可预知**的；这里补的就是那层兜底。
///
/// 职责边界：这里只负责"把异常变成一条 [DsFailure] 并广播出去"，**怎么显示**由
/// `ui/widgets/global_failure_listener.dart` 决定（走全仓统一的失败反馈通道）。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../domain/error_text.dart';

/// 最近一条"没人接住"的异常；`null` = 现在没有要说的。
///
/// 它是**事件**不是状态：监听方展示完就调 [clearGlobalFailure] 清空。
final ValueNotifier<DsFailure?> globalFailure = ValueNotifier<DsFailure?>(null);

/// 同一条错误在这个窗口内重复上报只留一条。
///
/// 必要性：帧回调 / 流监听里的异常会**每帧重抛**，不去重就会把用户刷屏
/// （而且每一条都要弹一次提示）。
const Duration kGlobalFailureDedupe = Duration(seconds: 5);

String? _lastKey;
DateTime? _lastAt;

/// 记录一次未捕获异常（由 `main.dart` 的两个全局钩子调用）。
///
/// ⚠️ 本函数**自己绝不能抛**：它是在"已经没有别人能接住"的位置被调用的，
/// 它再抛出来就是错误处理递归/死循环。
void reportGlobalFailure(Object error, StackTrace stackTrace) {
  try {
    final DsFailure failure = describeFailure(error, stackTrace: stackTrace);
    final String key = '${failure.message}|${failure.detail}';
    final DateTime now = DateTime.now();
    final DateTime? at = _lastAt;
    if (key == _lastKey &&
        at != null &&
        now.difference(at) < kGlobalFailureDedupe) {
      return;
    }
    _lastKey = key;
    _lastAt = now;
    // 推后一拍再广播：`FlutterError.onError` 会在**构建过程中**被调用，当场通知
    // 监听者会撞上 "setState() called during build" —— 那正是上面说的死循环。
    scheduleMicrotask(() {
      globalFailure.value = failure;
    });
  } catch (_) {
    // 兜底提示自己坏了不能反过来把进程带走。这里静默是**安全**的：调用方
    // （`main.dart` 的两个钩子）在调本函数**之前**已经把原始异常写进 stderr 了。
  }
}

/// 展示完就清空（由监听方调用）。
void clearGlobalFailure() {
  _lastKey = null;
  _lastAt = null;
  globalFailure.value = null;
}
