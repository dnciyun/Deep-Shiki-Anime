/// 「追番」按钮（spec §7.6）：`＋追番` ⇄ `✓ 已追`。
///
/// 轻量本地标记 —— 点一下只写本地列表，**不建订阅、不触发下载**。
/// 出现在主页海报卡与番剧详情页头部。
///
/// 视觉：新拟态规范 §7 —— 胶囊形状（原来圆角 4 + 1px 硬边框，已按规范去掉边框）。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/following_store.dart';
import '../../domain/following_subscription.dart';
import '../../domain/models.dart';
import '../../domain/ports.dart';
import '../../state/providers.dart';
import '../../theme/tokens.dart';
import 'feedback.dart';

/// 取消追番时，那一部的字幕组订阅怎么处理（第四十二轮 UX #27）。
enum _UnfollowChoice { cancel, followOnly, withSubscriptions }

class FollowButton extends ConsumerWidget {
  const FollowButton({
    super.key,
    required this.entry,
    this.compact = false,
  });

  /// 要追的番（由调用方按来源构造，见 `state/following_provider.dart`）。
  final FollowingEntry entry;

  /// 紧凑形态：只显示 `＋` / `✓` 图标（海报卡角上用）。
  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final DsTokens t = context.ds;
    final bool following = ref
        .watch(followingProvider)
        .any((FollowingEntry e) => e.id == entry.id);
    final Color fg = following ? t.accent : t.text2;
    final String label = following ? '已追' : '追番';

    return Tooltip(
      message: following ? '已加入「正在追」；再点一次取消' : '加入「正在追」（只做本地标记，不建订阅）',
      child: Material(
        color: following ? t.accentSoft : t.base.withValues(alpha: 0.82),
        borderRadius: BorderRadius.circular(t.radiusPill),
        child: InkWell(
          borderRadius: BorderRadius.circular(t.radiusPill),
          // 第四十二轮 UX #5 / #14：原来这里 `await toggle()` 裸奔 —— 落盘失败
          // （写 Hive 抛异常）时异常从 async 回调逃出去，用户看到的是**点了没反应**；
          // 成功那条又走裸 SnackBar，与全仓统一反馈不是一套。现在统一走 runGuarded。
          onTap: () => unawaited(_tap(context, ref)),
          child: Container(
            padding: EdgeInsets.symmetric(
                horizontal: compact ? 6 : 10, vertical: compact ? 3 : 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Icon(following ? Icons.favorite : Icons.favorite_border,
                    size: compact ? 11 : 13, color: fg),
                if (!compact) ...<Widget>[
                  const SizedBox(width: 5),
                  Text(label,
                      style: TextStyle(
                          color: fg, fontSize: DsTypeScale.caption)),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _tap(BuildContext context, WidgetRef ref) async {
    final bool following =
        ref.read(followingProvider).any((FollowingEntry e) => e.id == entry.id);
    if (!following) {
      await runGuarded(
        context,
        action: () async {
          await ref.read(followingProvider.notifier).toggle(entry);
          if (!context.mounted) return;
          showSuccess(context, '已加入「正在追」：${entry.title}');
        },
      );
      return;
    }
    // 取消追番**不是**纯粹的本地动作：这一部可能还挂着几个字幕组订阅，它们会继续
    // 每 30 分钟在后台刷新，而「正在追」里已经看不到这部番了 —— 用户既不知道、
    // 也没地方管（第四十二轮 UX #27）。
    //
    // 订阅列表现成的：主页常驻（`home_page.dart:203` 一直在 watch 它），所以这里
    // `read` 到的就是已经到货的那一份。取不到（端口未接通 / 列表还没加载）就当"没有
    // 订阅"——端口未接通时确实一个订阅都建不出来。
    //
    // ⚠️ 刻意**不**在这个按钮里 watch/listen 它：`UnavailableSubsPort` 的流是"永远
    // 失败"，一订阅就会让 riverpod 的自动重试挂上一个退避 Timer（组件测试里表现为
    // "a Timer is still pending"），而首页/详情页这些只有一颗追番按钮的地方不该背
    // 这个轮询 —— 订阅列表"谁来看"已经有明确归属（主页与「正在追」）。
    final List<SubscriptionView> subs = subscriptionsOf(
      entry,
      ref.read(subscriptionsProvider).value ?? const <SubscriptionView>[],
    );
    _UnfollowChoice choice = _UnfollowChoice.followOnly;
    if (subs.isNotEmpty) {
      if (!context.mounted) return;
      final _UnfollowChoice? picked = await showDialog<_UnfollowChoice>(
        context: context,
        builder: (BuildContext context) => AlertDialog(
          title: Text('取消追番「${entry.title}」？'),
          content: Text(
            '这一部还留着 ${subs.length} 个字幕组订阅，它们每 30 分钟在后台刷新。\n'
            '只取消追番的话，这些订阅会继续跑，但「正在追」里看不到这部番、也就管不了它们。',
            style: TextStyle(
              color: context.ds.text2,
              fontSize: DsTypeScale.body,
              height: 1.5,
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(_UnfollowChoice.cancel),
              child: const Text('取消'),
            ),
            OutlinedButton(
              onPressed: () =>
                  Navigator.of(context).pop(_UnfollowChoice.followOnly),
              child: const Text('只取消追番'),
            ),
            FilledButton(
              onPressed: () =>
                  Navigator.of(context).pop(_UnfollowChoice.withSubscriptions),
              child: const Text('连订阅一起取消'),
            ),
          ],
        ),
      );
      if (picked == null) return;
      choice = picked;
    }
    if (choice == _UnfollowChoice.cancel) return;
    if (!context.mounted) return;
    await runGuarded(
      context,
      action: () async {
        if (choice == _UnfollowChoice.withSubscriptions) {
          final SubsPort subsPort = ref.read(subsPortProvider);
          for (final SubscriptionView sub in subs) {
            await subsPort.remove(sub.id);
          }
        }
        await ref.read(followingProvider.notifier).toggle(entry);
        if (!context.mounted) return;
        showSuccess(
          context,
          choice == _UnfollowChoice.withSubscriptions
              ? '已取消追番，并停掉 ${subs.length} 个字幕组订阅'
              : '已从「正在追」移除：${entry.title}'
                  '${subs.isEmpty ? '' : '（${subs.length} 个订阅还在后台刷新）'}',
        );
      },
    );
  }
}
