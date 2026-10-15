/// 「订阅」这一组（第二十七轮）—— 字幕组旁边那颗按钮。
///
/// 用户原话：「在字幕组的旁边，可以直接订阅」。订阅的实体就是 mikan 番剧页上那一组自己的
/// RSS（`/RSS/Bangumi?bangumiId=…&subgroupid=…`），所以这里只需要
/// （番剧 id / 番名 / 组名 / 组 id / 组 RSS 地址）就能建出来，
/// 不需要用户去填地址、也不需要先有「订阅页」。
///
/// 订阅之后：条目会进「正在追」点开层按字幕组列出，可以逐集打勾「已看过」、
/// 单集下载或「下载全部（跳过已看过）」。取消订阅在点开层里做（那里的按钮带删确认）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/following_subscription.dart';
import '../../domain/models.dart';
import '../../state/providers.dart';
import '../../theme/tokens.dart';
import 'feedback.dart';
import 'neo.dart';

class GroupSubscribeButton extends ConsumerStatefulWidget {
  const GroupSubscribeButton({
    super.key,
    required this.bangumiId,
    required this.showTitle,
    required this.group,
  });

  final String bangumiId;
  final String showTitle;
  final BangumiGroupView group;

  @override
  ConsumerState<GroupSubscribeButton> createState() => _GroupSubscribeButtonState();
}

class _GroupSubscribeButtonState extends ConsumerState<GroupSubscribeButton> {
  bool _busy = false;

  Future<void> _subscribe() async {
    final String? rss = widget.group.rssUrl;
    if (rss == null || rss.trim().isEmpty) return;
    final String stamp = DateTime.now().microsecondsSinceEpoch.toString();
    final SubscriptionView sub = buildGroupSubscription(
      id: 'sub-$stamp',
      ruleId: 'rule-$stamp',
      bangumiId: widget.bangumiId,
      groupName: widget.group.name,
      groupId: widget.group.id,
      showTitle: widget.showTitle,
      feedUrl: rss.trim(),
    );
    setState(() => _busy = true);
    try {
      await runGuarded(
        context,
        action: () => ref.read(subsPortProvider).upsert(sub),
        success: '已订阅「${widget.group.name}」：到「正在追」里看这一组的剧集',
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final DsTokens t = context.ds;
    final List<SubscriptionView> subs =
        ref.watch(subscriptionsProvider).value ?? const <SubscriptionView>[];
    final SubscriptionView? existing = subscriptionForGroup(
      subs,
      bangumiId: widget.bangumiId,
      groupName: widget.group.name,
    );
    if (existing != null) {
      return Tooltip(
        message: '已订阅这一组的 RSS：到「正在追」点开这一部，可以逐集打勾与下载',
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.check_circle_outline, size: 13, color: t.success),
            const SizedBox(width: 4),
            Text(
              '已订阅',
              style: TextStyle(color: t.success, fontSize: DsTypeScale.caption),
            ),
          ],
        ),
      );
    }
    if (!widget.group.canSubscribe) {
      return Tooltip(
        message: 'mikan 这一组没有给 RSS 地址，订阅不了（可以照旧逐集下载）',
        child: Text(
          '无 RSS',
          style: TextStyle(color: t.text3, fontSize: DsTypeScale.caption),
        ),
      );
    }
    return NeoButton(
      label: _busy ? '订阅中…' : '订阅',
      icon: Icons.rss_feed,
      compact: true,
      onPressed: _busy ? null : () => _subscribe(),
    );
  }
}
