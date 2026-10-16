/// 「正在追」页（spec §7.6；第二十七轮按用户要求重做）。
///
/// 用户这一轮的原话：
/// > 移除订阅，功能同步至正在追。优化正在追，直接调用 mikan 的 rss 订阅，在字幕组的旁边，
/// > 可以直接订阅，订阅可在正在追内标记已看过，已看过的在旁边打上勾。正在追封面改为同已完成，
/// > 去除继续观看，点开后，仅显示订阅的字幕组，并在上面可直接下载全部或单集下载，
/// > 下载全部跳过已看过的。
///
/// 所以这一页现在是**封面卡网格**（形态照抄「已完成」的 2:3 封面卡）：
/// * 卡片 = 一部番：封面 + 番名 + 状态 + 「已订阅 N 个字幕组」+ 已看过的集数；
/// * **右上角的总勾**：这一部番**订阅到的所有剧集**都打过「已看过」时才出现
///   （用户选定的口径；只有部分看过时显示 `✓ 已看过 N 集`，不假装"全看完"）；
/// * 没有「继续观看」按钮了（用户：「去除继续观看」）—— 整张卡点开就是点开层，
///   那里才挑集；
/// * 点开层 = `ui/following_detail.dart`：只列订阅的字幕组、可打勾、可单集/全部下载。
///
/// 视觉（新拟态规范 `docs/specs/2026-10-10-dsanima-neo-theme.md`）：卡片 = 凸起面 +
/// listSafe 阴影（无硬边框）；筛选仍走 `NeoDropdown`。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/following_store.dart';
import '../domain/following_subscription.dart';
import '../domain/following_view.dart';
import '../domain/models.dart';
import '../state/providers.dart';
import '../theme/tokens.dart';
import 'following_detail.dart';
import 'widgets/cover.dart';
import 'widgets/ds_stagger.dart';
import 'widgets/neo.dart';
import 'widgets/neo_dropdown.dart';
import 'widgets/state_views.dart';

/// 卡片几何（**与「已完成」同一档**：同列宽上限、同格高、同间距 —— 两页并排看一致）。
///
/// 封面用 `Expanded` 铺满剩下的空间（与 `completed_page.dart` 的 `_CompletedGridCard`
/// 同一套排布），所以这里**没有**固定封面尺寸的常量：固定 96×136 那版在 232 高的格子里
/// 溢出 3.0px（独立复核用临时探针抓到），而且槽变窄时封面不会跟着变、与「已完成」不一致。
/// `following_test` 里有一条用例**在网格槽尺寸下**跑一遍并断言零 overflow。
const double kFollowingGridMaxExtent = 200;
const double kFollowingGridExtent = 360;
const double kFollowingGridSpacing = 12;

class FollowingPage extends ConsumerStatefulWidget {
  const FollowingPage({super.key});

  @override
  ConsumerState<FollowingPage> createState() => _FollowingPageState();
}

class _FollowingPageState extends ConsumerState<FollowingPage> {
  FollowingFilter _filter = FollowingFilter.all;

  @override
  Widget build(BuildContext context) {
    final DsTokens t = context.ds;
    final List<FollowingEntry> entries = ref.watch(followingProvider);
    final AsyncValue<ScheduleView> scheduleValue = ref.watch(scheduleProvider);
    final ScheduleView? schedule = scheduleValue.value;
    final AsyncValue<List<QueueJobView>> jobsValue = ref.watch(queueJobsProvider);
    final List<QueueJobView> jobs = jobsValue.value ?? const <QueueJobView>[];
    final AsyncValue<List<EngineTorrentView>> torrentsValue =
        ref.watch(engineTorrentsProvider);
    final List<EngineTorrentView> torrents =
        torrentsValue.value ?? const <EngineTorrentView>[];
    final AsyncValue<List<SubscriptionView>> subsValue =
        ref.watch(subscriptionsProvider);
    final List<SubscriptionView> subs =
        subsValue.value ?? const <SubscriptionView>[];
    final DateTime now = ref.watch(todayProvider);
    final int todayDow = ref.watch(todayDowProvider);

    // 取数失败必须说出来（第四十二轮 UX #4，二级）：卡片上的「今天有更新 / 下载到几成」
    // 由这四个 provider 拼出来，旧实现一律 `?? const []`（`schedule` 直接可空）——
    // mikan 追番表拉取失败时页面照常渲染成"今天没有更新"，用户不会想到是没读到。
    final List<String> staleSources = <String>[
      if (scheduleValue.error != null && !scheduleValue.isLoading) '更新表（mikan）',
      if (subsValue.error != null && !subsValue.isLoading) '订阅列表',
      if (jobsValue.error != null && !jobsValue.isLoading) '下载队列',
      if (torrentsValue.error != null && !torrentsValue.isLoading) '引擎进度',
    ];

    final List<FollowingCard> all = buildFollowingCards(
      entries: entries,
      schedule: schedule,
      jobs: jobs,
      torrents: torrents,
      now: now,
      todayDow: todayDow,
    );
    final List<FollowingCard> cards = buildFollowingCards(
      entries: entries,
      schedule: schedule,
      jobs: jobs,
      torrents: torrents,
      now: now,
      todayDow: todayDow,
      filter: _filter,
    );
    final int updatedCount = all.where((FollowingCard c) => c.hasUpdate).length;
    final int subscribed = entries
        .where((FollowingEntry e) => subscriptionsOf(e, subs).isNotEmpty)
        .length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 12, 18, 10),
          child: Row(
            children: <Widget>[
              Text(
                '${all.length} 部 · $updatedCount 部有更新',
                style: TextStyle(color: t.text2, fontSize: DsTypeScale.secondary),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '点卡片进去挑字幕组：订阅、打勾已看过、下载全部（跳过已看过）'
                  '（共 $subscribed 部订了字幕组）',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: t.text3, fontSize: DsTypeScale.caption),
                ),
              ),
              NeoDropdown<FollowingFilter>(
                width: 128,
                height: 26,
                fontSize: DsTypeScale.caption,
                value: _filter,
                tooltip: '筛选正在追',
                label: '筛选 · ${_filter.label}',
                items: <NeoDropdownItem<FollowingFilter>>[
                  for (final FollowingFilter f in FollowingFilter.values)
                    NeoDropdownItem<FollowingFilter>(f, '筛选 · ${f.label}'),
                ],
                onSelected: (FollowingFilter f) => setState(() => _filter = f),
              ),
            ],
          ),
        ),
        if (staleSources.isNotEmpty) ...<Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 0, 18, 8),
            child: DsBanner(
              kind: DsBannerKind.error,
              text: '${staleSources.join('、')} 没读出来：卡片上的"今天有更新 / 下载到几成"'
                  '会显示成没有 —— 那是没读到，不是真的没有。',
              action: NeoButton(
                label: '重试',
                icon: Icons.refresh,
                kind: NeoButtonKind.primary,
                onPressed: () {
                  if (scheduleValue.error != null) {
                    ref.invalidate(scheduleProvider);
                  }
                  if (subsValue.error != null) {
                    ref.invalidate(subscriptionsProvider);
                  }
                  if (jobsValue.error != null) {
                    ref.invalidate(queueJobsProvider);
                  }
                  if (torrentsValue.error != null) {
                    ref.invalidate(engineTorrentsProvider);
                  }
                },
              ),
            ),
          ),
        ],
        Expanded(
          child: entries.isEmpty ? _empty() : (cards.isEmpty ? _filteredEmpty() : _grid(cards)),
        ),
      ],
    );
  }

  Widget _empty() => DsEmpty(
    icon: Icons.favorite_border,
    title: '还没有追番',
    message:
        '到「主页」的海报卡、或「搜索」的结果里点「＋追番」，就会收进这里。'
        '追番只是本地标记（不会自动下载）；订阅字幕组要进卡片里点「订阅」。',
    action: NeoButton(
      label: '去主页看看',
      icon: Icons.home_outlined,
      kind: NeoButtonKind.primary,
      onPressed: () => ref.read(navProvider.notifier).select(ShellTab.home),
    ),
  );

  Widget _filteredEmpty() => DsEmpty(
    icon: Icons.filter_alt_off_outlined,
    title: '「${_filter.label}」下没有番',
    message: '换一个筛选，或点「全部」看所有追番。',
    action: NeoButton(label: '看全部', onPressed: () => setState(() => _filter = FollowingFilter.all)),
  );

  Widget _grid(List<FollowingCard> cards) => GridView.builder(
    padding: const EdgeInsets.fromLTRB(18, 14, 18, 18),
    gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
      maxCrossAxisExtent: kFollowingGridMaxExtent,
      mainAxisExtent: kFollowingGridExtent,
      mainAxisSpacing: kFollowingGridSpacing,
      crossAxisSpacing: kFollowingGridSpacing,
    ),
    itemCount: cards.length,
    itemBuilder: (BuildContext context, int index) => DsStaggerFade(index: index, child: FollowingGridCard(card: cards[index])),
  );
}

/// 一张「正在追」封面卡（形态与「已完成」的卡一致：2:3 封面 + 下面两行文字）。
class FollowingGridCard extends ConsumerWidget {
  const FollowingGridCard({super.key, required this.card});

  final FollowingCard card;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final DsTokens t = context.ds;
    final FollowingEntry entry = card.entry;
    final List<SubscriptionView> subs =
        ref.watch(subscriptionsProvider).value ?? const <SubscriptionView>[];
    final List<SubscriptionView> mine = subscriptionsOf(entry, subs);
    final Map<String, DateTime> marks = ref.watch(watchedMarksProvider);

    // 「已看过」的账：把这一部番**订阅到的剧集**的键合起来看。
    // 订阅条目是异步抓的（`subscriptionItemsProvider`）——这里 `watch` 会让它开始抓，
    // 这正是"正在追 = 订阅中枢"该有的行为；core 的源缓存兜住重复请求。
    int watchedCount = 0;
    bool allLoaded = mine.isNotEmpty;
    final List<String> allKeys = <String>[];
    for (final SubscriptionView sub in mine) {
      final AsyncValue<List<SourceItemView>> value =
          ref.watch(subscriptionItemsProvider(sub.id));
      final List<SourceItemView>? items = value.value;
      if (items == null) {
        allLoaded = false;
        continue;
      }
      final List<String> keys = subscriptionItemWatchKeys(
        bangumiId: entry.mikanBangumiId ?? entry.title,
        title: entry.title,
        group: subscriptionGroupName(sub) ?? sub.name,
        items: items,
      );
      allKeys.addAll(keys);
    }
    for (final String key in allKeys) {
      if (marks.containsKey(key)) watchedCount++;
    }
    final bool allWatched = allLoaded && allKeys.isNotEmpty && watchedCount == allKeys.length;

    final String? stateLine = card.stateText ?? card.nextUpdate;
    return NeoSurface(
      radius: t.radiusCard,
      padding: const EdgeInsets.all(8),
      onTap: () => openFollowingDetail(context, entry),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          // 封面铺满剩下的空间（与「已完成」的 `_CompletedGridCard` 同一套排布）：
          // 这样槽宽变窄时封面跟着变，两页的比例才一致。
          Expanded(
            child: Stack(
              fit: StackFit.expand,
              children: <Widget>[
                DsCover(url: entry.coverUrl, referer: entry.coverReferer),
                Positioned(left: 5, top: 5, child: _StatusBadge(status: card.status)),
                // 右上角：总勾（订阅到的集全看过）/ 看过几集。
                if (allWatched)
                  Positioned(
                    right: 5,
                    top: 5,
                    child: _CornerMark(
                      icon: Icons.check_circle,
                      color: t.success,
                      label: '全看过',
                      tooltip: '这一部订阅到的剧集都打过「已看过」的勾',
                    ),
                  )
                else if (watchedCount > 0)
                  Positioned(
                    right: 5,
                    top: 5,
                    child: _CornerMark(
                      icon: Icons.check_circle_outline,
                      color: t.success,
                      label: '$watchedCount',
                      tooltip: '已看过 $watchedCount 集（订阅到的剧集还没全看完）',
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          Text(
            entry.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: t.text,
              fontSize: DsTypeScale.secondary,
              fontWeight: FontWeight.w600,
              height: 1.25,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            <String>[
              mine.isEmpty ? '未订阅字幕组 · 点开挑' : '已订阅 ${mine.length} 个字幕组',
              if (entry.score != null) '★${entry.score!.toStringAsFixed(1)}',
            ].join(' · '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: mine.isEmpty ? t.warning : t.text2,
              fontSize: DsTypeScale.caption,
            ),
          ),
          if ((stateLine ?? '').trim().isNotEmpty) ...<Widget>[
            const SizedBox(height: 2),
            Text(
              stateLine!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: card.hasUpdate ? t.accent : t.text3,
                fontSize: DsTypeScale.caption,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 封面角上的小标记（凸起面 + 图标 + 文字，压得住任意画面）。
class _CornerMark extends StatelessWidget {
  const _CornerMark({
    required this.icon,
    required this.color,
    required this.label,
    required this.tooltip,
  });

  final IconData icon;
  final Color color;
  final String label;
  final String tooltip;

  @override
  Widget build(BuildContext context) {
    final DsTokens t = context.ds;
    return Tooltip(
      message: tooltip,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
        decoration: t.cardDecoration(
          radius: t.radiusPill,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(icon, size: 12, color: color),
            const SizedBox(width: 3),
            Text(
              label,
              style: TextStyle(color: color, fontSize: DsTypeScale.caption),
            ),
          ],
        ),
      ),
    );
  }
}

/// 状态徽标：**凸起胶囊 + 着色文字**（语义色只以小面积出现，决策 A18）。
class _StatusBadge extends StatelessWidget {
  const _StatusBadge({required this.status});

  final FollowingStatus status;

  @override
  Widget build(BuildContext context) {
    final DsTokens t = context.ds;
    final (Color tone, IconData icon) = switch (status) {
      FollowingStatus.downloading => (t.success, Icons.downloading),
      FollowingStatus.watching => (t.accent, Icons.visibility_outlined),
      FollowingStatus.queued => (t.text3, Icons.schedule),
    };
    // 第三十轮：外面原来还套了一层 `cardDecoration(radiusPill)` —— 它给的是
    // `raised` 面 + 1px `line` 描边，而里面那颗 `NeoPill` 自己就是一整颗胶囊
    // ⇒ 白底上多出一圈描边，小徽标看着像"套了两层"。交回 `NeoPill` 一个人画。
    return NeoPill(label: status.label, icon: icon, color: tone, selected: true);
  }
}
