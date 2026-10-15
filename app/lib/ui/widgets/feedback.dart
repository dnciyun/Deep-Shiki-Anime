/// 动作反馈：把成功/失败统一呈现（失败一定带「怎么办」）。
///
/// 视觉：新拟态规范 §7 —— SnackBar 走凸起面 + `raisedHigh` 阴影，语义色只以小面积出现
/// （原来的「整条 danger 18% 底色」违反决策 A18：不用大面积语义色块）。
library;

import 'package:flutter/material.dart';

import '../../domain/error_text.dart';
import '../../theme/tokens.dart';
import 'neo.dart';

/// 展示一条反馈：凸起面 + 左侧语义色细条 + 图标。
void _show(
  BuildContext context, {
  required DsFailure? failure,
  String? success,
  int seconds = 6,
}) {
  final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
  final DsTokens t = context.ds;
  messenger.showSnackBar(SnackBar(
    backgroundColor: t.raised,
    padding: EdgeInsets.zero,
    duration: Duration(seconds: seconds),
    content: NeoBanner(
      kind: failure == null ? NeoBannerKind.success : NeoBannerKind.error,
      text: failure == null
          ? (success ?? '完成')
          : '${failure.message}'
              '${failure.hint == null ? '' : '\n怎么办：${failure.hint}'}',
    ),
  ));
}

/// 直接展示一条失败（带「怎么办」）。
void showFailure(BuildContext context, DsFailure failure) {
  _show(context, failure: failure);
}

/// 轻提示（成功）。[seconds] 默认 2 秒；批量动作（一次 20 条）要留长一点，
/// 否则用户还没读完就没了。
void showSuccess(BuildContext context, String message, {int seconds = 2}) {
  _show(context, failure: null, success: message, seconds: seconds);
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
