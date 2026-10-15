/// 「追番」按钮（spec §7.6）：`＋追番` ⇄ `✓ 已追`。
///
/// 轻量本地标记 —— 点一下只写本地列表，**不建订阅、不触发下载**。
/// 出现在主页海报卡与番剧详情页头部。
///
/// 视觉：新拟态规范 §7 —— 胶囊形状（原来圆角 4 + 1px 硬边框，已按规范去掉边框）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/following_store.dart';
import '../../state/providers.dart';
import '../../theme/tokens.dart';

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
          onTap: () async {
            final bool now =
                await ref.read(followingProvider.notifier).toggle(entry);
            if (!context.mounted) return;
            ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
              content: Text(
                now ? '已加入「正在追」：${entry.title}' : '已从「正在追」移除：${entry.title}',
                style: TextStyle(color: t.text),
              ),
              duration: const Duration(seconds: 2),
            ));
          },
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
}
