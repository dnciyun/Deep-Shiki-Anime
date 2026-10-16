/// 动作反馈：把成功 / 警告 / 失败统一呈现（失败一定带「怎么办」）。
///
/// 三个出口的分工（第四十二轮 UX #34：原来只有成功/失败两个，于是"警告"只能
/// 挤进成功通道 —— 拿绿色画一句"引擎那边没删掉"，一眼扫过去就漏了）：
/// * [showSuccess]：做成了；
/// * [showWarning]：**做了一半**（记录删了、引擎那一步没成功）；
/// * [showFailure]：没做成，附带「怎么办」。
///
/// 视觉：新拟态规范 §7 —— SnackBar 走凸起面 + `raisedHigh` 阴影，语义色只以小面积出现
/// （原来的「整条 danger 18% 底色」违反决策 A18：不用大面积语义色块）。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../domain/error_text.dart';
import '../../theme/tokens.dart';
import 'neo.dart';

/// 展示一条反馈：凸起面 + 左侧语义色细条 + 图标。
void _show(
  BuildContext context, {
  required NeoBannerKind kind,
  required String text,
  int seconds = 6,
  Widget? action,
}) {
  final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
  final DsTokens t = context.ds;
  messenger.showSnackBar(SnackBar(
    backgroundColor: t.raised,
    padding: EdgeInsets.zero,
    duration: Duration(seconds: seconds),
    content: NeoBanner(kind: kind, text: text, action: action),
  ));
}

/// 直接展示一条失败（带「怎么办」）。
void showFailure(BuildContext context, DsFailure failure) {
  _show(
    context,
    kind: NeoBannerKind.error,
    text: '${failure.message}'
        '${failure.hint == null ? '' : '\n怎么办：${failure.hint}'}',
  );
}

/// 轻提示（成功）。[seconds] 默认 2 秒；批量动作（一次 20 条）要留长一点，
/// 否则用户还没读完就没了。
void showSuccess(BuildContext context, String message, {int seconds = 2}) {
  _show(context, kind: NeoBannerKind.success, text: message, seconds: seconds);
}

/// 警告类反馈：**事情做了一半**，不是成功也不是纯失败。
///
/// 典型场合：队列记录删掉了、但引擎那一步没成功（文件可能还在）。这种情况下报
/// "已删除"是撒谎，报一条失败又过了 —— 用户需要的是"做完了哪一半、还差哪一半"。
void showWarning(
  BuildContext context,
  String message, {
  String? hint,
  int seconds = 8,
}) {
  _show(
    context,
    kind: NeoBannerKind.warning,
    text: '$message${hint == null ? '' : '\n$hint'}',
    seconds: seconds,
  );
}

/// 展示一条「已经做了，但你可以反悔」的成功提示，带「撤销」。
///
/// 第四十二轮 UX #20 的收口：单条观看记录是**不可逆**删除，但它属于"低摩擦"那一类
/// （同「删一条搜索历史」的既定口径：为一次点错弹一次确认框，代价比收益大）。
/// 正确做法不是加确认框，而是让它可撤销 —— 这就是那个出口。
/// 撤销本身失败也走统一失败通道（不许静默）。
void showUndo(
  BuildContext context,
  String message, {
  required Future<void> Function() onUndo,
  int seconds = 8,
}) {
  final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
  final DsTokens t = context.ds;
  messenger.showSnackBar(SnackBar(
    backgroundColor: t.raised,
    padding: EdgeInsets.zero,
    duration: Duration(seconds: seconds),
    content: NeoBanner(
      kind: NeoBannerKind.success,
      text: message,
      action: TextButton(
        onPressed: () {
          messenger.hideCurrentSnackBar();
          unawaited(runGuarded(context, action: onUndo, success: '已撤销'));
        },
        child: const Text('撤销'),
      ),
    ),
  ));
}

/// 跑一个可能失败的动作：成功给轻提示，失败给可行动文案。
Future<void> runGuarded(
  BuildContext context, {
  required Future<void> Function() action,
  String? success,
}) async {
  try {
    await action();
    if (success != null && context.mounted) {
      showSuccess(context, success);
    }
  } catch (error, stackTrace) {
    if (!context.mounted) return;
    showFailure(context, describeFailure(error, stackTrace: stackTrace));
  }
}

/// 同 [runGuarded]，但把"成没成"回给调用方（失败照样会画出来）。
///
/// 给"成功了才该做下一步"的动作用：例如批量打勾成功之后才提示
/// "合集条目已跳过"，失败就不要再补一句无关的话盖住错误横幅。
Future<bool> runGuardedBool(
  BuildContext context, {
  required Future<void> Function() action,
  String? success,
}) async {
  try {
    await action();
    if (success != null && context.mounted) {
      showSuccess(context, success);
    }
    return true;
  } catch (error, stackTrace) {
    if (context.mounted) {
      showFailure(context, describeFailure(error, stackTrace: stackTrace));
    }
    return false;
  }
}
