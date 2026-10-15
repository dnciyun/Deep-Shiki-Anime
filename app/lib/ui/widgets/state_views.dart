/// 通用三态视图：loading / empty / error。
///
/// 规则（task-4 硬要求，未变）：
/// * 每个网络/引擎调用都必须能显示这三种状态；
/// * error 必须给出**可行动**信息（发生了什么 + 去哪里改什么），不是「出错了」；
/// * 永远不用假数据把错误藏起来。
///
/// 视觉：新拟态规范 `docs/specs/2026-10-10-dsanima-neo-theme.md` §7
/// （空态 = 凸起图标圆盘 + 大留白；错误面板 = 凸起面 + 语义色细条，**无硬边框**）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/error_text.dart';
import '../../theme/tokens.dart';
import 'ds_spinner.dart';
import 'neo.dart';

/// 加载中（一行转圈 + 中文说明）。
class DsLoading extends StatelessWidget {
  const DsLoading({super.key, this.label = '加载中…', this.compact = false});

  final String label;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final DsTokens t = context.ds;
    return Padding(
      padding: EdgeInsets.symmetric(vertical: compact ? 12 : 32, horizontal: 16),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          // iOS 风格圆环（用户 2026-10-12 第八轮：Material 那个转圈"太丑不符合"）。
          const DsSpinner.page(),
          const SizedBox(width: 10),
          Text(label,
              style: TextStyle(color: t.text2, fontSize: DsTypeScale.body)),
        ],
      ),
    );
  }
}

/// 空状态（有明确下一步动作）。
class DsEmpty extends StatelessWidget {
  const DsEmpty({
    super.key,
    required this.title,
    this.icon = Icons.inbox_outlined,
    this.message,
    this.action,
  });

  final String title;
  final IconData icon;
  final String? message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final DsTokens t = context.ds;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            // 凸起圆盘托住图标：新拟态的「空态」不用扁平大图标。
            Container(
              width: 72,
              height: 72,
              alignment: Alignment.center,
              decoration: t.cardDecoration(
                radius: t.radiusPill,
              ),
              child: Icon(icon, size: 32, color: t.text3),
            ),
            const SizedBox(height: 16),
            Text(title,
                style: TextStyle(
                    color: t.text,
                    fontSize: DsTypeScale.title,
                    fontWeight: FontWeight.w600)),
            if (message case final String text) ...<Widget>[
              const SizedBox(height: 8),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Text(text,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        color: t.text2,
                        fontSize: DsTypeScale.body,
                        height: 1.5)),
              ),
            ],
            if (action case final Widget widget) ...<Widget>[
              const SizedBox(height: 18),
              widget,
            ],
          ],
        ),
      ),
    );
  }
}

/// 错误面板：发生了什么 + 怎么办 + 重试。
class DsErrorPanel extends StatelessWidget {
  const DsErrorPanel({
    super.key,
    required this.failure,
    this.title,
    this.onRetry,
    this.retryLabel = '重试',
  });

  final DsFailure failure;
  final String? title;
  final VoidCallback? onRetry;
  final String retryLabel;

  @override
  Widget build(BuildContext context) {
    final DsTokens t = context.ds;
    final String? hint = failure.hint;
    final String? detail = failure.detail;
    return Container(
      margin: const EdgeInsets.all(16),
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
      decoration: BoxDecoration(
        color: t.raised,
        borderRadius: BorderRadius.circular(t.radiusCard),
        // 语义色只以小面积出现：左侧 3px 细条。
        border: Border(left: BorderSide(color: t.danger, width: 3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(Icons.error_outline, size: 18, color: t.danger),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title ?? failure.message,
                  style: TextStyle(
                      color: t.text,
                      fontSize: DsTypeScale.title,
                      fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
          if (title != null) ...<Widget>[
            const SizedBox(height: 6),
            Text(failure.message,
                style: TextStyle(
                    color: t.text2,
                    fontSize: DsTypeScale.secondary,
                    height: 1.5)),
          ],
          if (hint != null) ...<Widget>[
            const SizedBox(height: 10),
            DsInset(
              padding: const EdgeInsets.all(10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Icon(Icons.lightbulb_outline, size: 15, color: t.warning),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text('怎么办：$hint',
                        style: TextStyle(
                            color: t.text,
                            fontSize: DsTypeScale.secondary,
                            height: 1.5)),
                  ),
                ],
              ),
            ),
          ],
          if (detail != null) ...<Widget>[
            const SizedBox(height: 8),
            SelectableText(
              detail,
              maxLines: 4,
              style: TextStyle(
                  color: t.text3, fontSize: DsTypeScale.caption, height: 1.45),
            ),
          ],
          if (onRetry != null) ...<Widget>[
            const SizedBox(height: 14),
            Align(
              alignment: Alignment.centerLeft,
              child: NeoButton(
                label: retryLabel,
                icon: Icons.refresh,
                kind: NeoButtonKind.primary,
                onPressed: onRetry,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 提示条（信息/警告/成功），用于「已保存但未生效」这类非致命状态。
enum DsBannerKind { info, warning, success, error }

class DsBanner extends StatelessWidget {
  const DsBanner({
    super.key,
    required this.text,
    this.kind = DsBannerKind.info,
    this.action,
  });

  final String text;
  final DsBannerKind kind;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final NeoBannerKind k = switch (kind) {
      DsBannerKind.info => NeoBannerKind.info,
      DsBannerKind.warning => NeoBannerKind.warning,
      DsBannerKind.success => NeoBannerKind.success,
      DsBannerKind.error => NeoBannerKind.error,
    };
    return NeoBanner(text: text, kind: k, action: action);
  }
}

/// 把 `AsyncValue` 渲染成三态（有数据优先渲染数据，避免刷新时闪白）。
class DsAsync<T> extends ConsumerWidget {
  const DsAsync({
    super.key,
    required this.value,
    required this.builder,
    this.loadingLabel = '加载中…',
    this.onRetry,
    this.isEmpty,
    this.empty,
  });

  final AsyncValue<T> value;
  final Widget Function(BuildContext context, T data) builder;
  final String loadingLabel;
  final VoidCallback? onRetry;
  final bool Function(T data)? isEmpty;
  final Widget? empty;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final T? data = value.value;
    if (data != null) {
      if (isEmpty?.call(data) ?? false) {
        return empty ?? const DsEmpty(title: '这里还没有内容');
      }
      return builder(context, data);
    }
    if (value.isLoading) return DsLoading(label: loadingLabel);
    final Object? error = value.error;
    return DsErrorPanel(
      failure: describeFailure(error ?? '未知错误'),
      onRetry: onRetry,
    );
  }
}
