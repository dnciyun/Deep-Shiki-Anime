/// 「正在追」的**点开层**（第二十七轮）：一部番的订阅字幕组 + 它们的剧集。
///
/// 用户原话：「优化正在追，直接调用 mikan 的 rss 订阅，在字幕组的旁边，可以直接订阅，
/// 订阅可在正在追内标记已看过，已看过的在旁边打上勾。……点开后，仅显示订阅的字幕组，
/// 并在上面可直接下载全部或单集下载，下载全部跳过已看过的。」
///
/// 所以这一页做四件事：
/// 1. **只列订阅的字幕组**：剧集来自订阅那一组的 RSS（`subscriptionItemsProvider`，
///    不套规则 —— 见 `HostDataRuntime.subscriptionItems`），不是整页 HTML；
/// 2. 还没订阅的组列在下面（点「订阅」直接订，不必再去番剧页）；
/// 3. 每一集旁边一个「已看过」的勾（`watchedMarksProvider`，与观看记录同一套键），
///    进度播到 90% 会自动打上（设置里可关「记录观看进度」）；
/// 4. 「下载全部」**跳过已打勾的**，也可以单集下载 / 播放。
///
/// ## 第四十九轮：页头下面多一块「种子」（用户「优化下订阅，详细页订阅的也带有种子」）
///
/// 订阅详细页原来只能看到**订阅的那几组**的 RSS 剧集：想找别的组 / 别的站的版本，得退回
/// 「正在追」、再进「动漫库」翻同一部番。现在这一页直接挂上动漫库详细页那块「种子」
/// （`ui/widgets/library_seed_block.dart`，**同一个组件、同一套引擎**：主流站点关键字搜索、
/// 按字幕组分段、合集单独一页、别的版本折在底部、语言过滤），位置在**封面/标题下面、
/// 订阅字幕组上面** —— 一进这一页就看得见，不用先翻过几十集。
///
/// * 订阅区**一个字没动**：剧集列表、打勾、下载全部、刷新、规则、命中预览、取消订阅照旧；
/// * 种子块的主体（搜什么词 / 怎么判版本 / 状态键）由 `domain/following_seed.dart` 从这条
///   追番记录造一条**最小** Bangumi 条目：Bangumi 来的记录直接用 `bgmId`（和动漫库详细页
///   共用同一份种子状态），主页来的只有 mikan 番剧 id 与番名 —— 不联网、不猜；
/// * 「已看过」与观看记录按**这一部的 mikan 番剧 id** 归组（`LibrarySeedBlock.mikanBangumiId`）：
///   订阅里打过的勾，种子块里也显示成「已看过」；在种子块里播的集也记到同一条观看记录上。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/bangumi.dart';
import '../domain/batch_download.dart';
import '../domain/episodes.dart' show episodeNumber;
import '../domain/error_text.dart';
import '../domain/following_seed.dart';
import '../domain/following_store.dart';
import '../domain/following_subscription.dart';
import '../domain/format.dart';
import '../domain/models.dart';
import '../state/playback.dart';
import '../state/providers.dart';
import '../theme/tokens.dart';
import 'home_page.dart' show openRecommendSearch;
import 'widgets/cover.dart';
import 'widgets/ds_cards.dart';
import 'widgets/ds_spinner.dart';
import 'widgets/feedback.dart';
import 'widgets/follow_button.dart';
import 'widgets/group_subscribe.dart';
import 'widgets/library_seed_block.dart';
import 'widgets/neo.dart';
import 'widgets/neo_dropdown.dart';
import 'widgets/state_views.dart';

/// 打开某一部番的点开层。
Future<void> openFollowingDetail(BuildContext context, FollowingEntry entry) =>
    Navigator.of(context, rootNavigator: true).push<void>(
      MaterialPageRoute<void>(builder: (BuildContext context) => FollowingDetailPage(entry: entry)),
    );

class FollowingDetailPage extends ConsumerStatefulWidget {
  const FollowingDetailPage({super.key, required this.entry});

  final FollowingEntry entry;

  @override
  ConsumerState<FollowingDetailPage> createState() => _FollowingDetailPageState();
}

class _FollowingDetailPageState extends ConsumerState<FollowingDetailPage> {
  bool _batchBusy = false;

  /// 顶部「刷新」在跑（原来它**没有任何可观察状态**：点完既没转圈也没提示）。
  bool _refreshing = false;

  String get _bangumiId => (widget.entry.mikanBangumiId ?? '').trim();

  /// 下拉刷新：番剧详情（有哪些组）+ 每个订阅的条目（RSS）。
  ///
  /// 第四十二轮 UX #23：旧实现 `invalidate` 完就 `await 50ms` 然后**什么都不做** ——
  /// 没有 loading、没有结果提示。未订阅字幕组时下面的列表根本不存在，用户点完
  /// 完全看不出发生什么，只能猜。现在：按钮进忙态，并**等这一轮重取真的落地**，
  /// 成功/失败都明说一句。
  Future<void> _refresh(List<SubscriptionView> mine) async {
    if (_refreshing) return;
    setState(() => _refreshing = true);
    try {
      if (_bangumiId.isNotEmpty) {
        ref.invalidate(bangumiDetailProvider(_bangumiId));
      }
      for (final SubscriptionView sub in mine) {
        ref.invalidate(subscriptionItemsProvider(sub.id));
      }
      // 等真的拉完再报结果：失败会从这里抛出来（不再"点完没反应"）。
      if (_bangumiId.isNotEmpty) {
        await ref.read(bangumiDetailProvider(_bangumiId).future);
      }
      for (final SubscriptionView sub in mine) {
        await ref.read(subscriptionItemsProvider(sub.id).future);
      }
      if (!mounted) return;
      showSuccess(
        context,
        mine.isEmpty
            ? '已重新拉取这一部的字幕组'
            : '已重新拉取 ${mine.length} 个字幕组的剧集',
      );
    } catch (error, stackTrace) {
      if (!mounted) return;
      showFailure(context, describeFailure(error, stackTrace: stackTrace));
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final DsTokens t = context.ds;
    final List<SubscriptionView> subs =
        ref.watch(subscriptionsProvider).value ?? const <SubscriptionView>[];
    final List<SubscriptionView> mine = subscriptionsOf(widget.entry, subs);
    final AsyncValue<BangumiDetailView>? detail = _bangumiId.isEmpty
        ? null
        : ref.watch(bangumiDetailProvider(_bangumiId));
    // 种子块的主体（第四十九轮）：这条追番记录 → 一条最小的 Bangumi 条目
    // （有 bgmId 就直接用它，和动漫库详细页共用同一份种子状态；否则按 mikan id / 番名
    // 造一个稳定负数 id，见 `domain/following_seed.dart`）。
    final BangumiSubject seedSubject = seedSubjectFromFollowing(widget.entry);

    return Scaffold(
      backgroundColor: t.base,
      appBar: AppBar(
        backgroundColor: t.surface,
        elevation: 0,
        toolbarHeight: t.barHeight,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, size: 16),
          tooltip: '返回「正在追」',
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        titleSpacing: 0,
        title: Text(
          widget.entry.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: t.text,
            fontSize: DsTypeScale.body,
            fontWeight: FontWeight.w600,
          ),
        ),
        actions: <Widget>[
          FollowButton(entry: widget.entry),
          const SizedBox(width: 8),
          IconButton(
            icon: _refreshing
                ? const DsSpinner.inline()
                : const Icon(Icons.refresh, size: 16),
            tooltip: _refreshing ? '正在重新拉取…' : '重新拉取字幕组与订阅的剧集',
            onPressed: _refreshing ? null : () => unawaited(_refresh(mine)),
          ),
          const SizedBox(width: 6),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: <Widget>[
          _Header(entry: widget.entry, subscribedGroups: mine.length),
          const SizedBox(height: 14),
          if (mine.isEmpty)
            const DsBanner(
              kind: DsBannerKind.warning,
              text: '还没有订阅任何字幕组：下面「这一部的字幕组」里点「订阅」，'
                  '这一组的剧集就会按组列在这里（可以逐集打勾、单集下载或下载全部）。',
            ),
          // 第四十九轮（用户「优化下订阅，详细页订阅的也带有种子」）：订阅详细页也能直接看
          // 全站种子 —— 与动漫库详细页是**同一个**种子块；放在页头下面、订阅字幕组上面，
          // 一进这一页就看得见。订阅区一个字没动（见文件头）。
          const SizedBox(height: 12),
          LibrarySeedBlock(
            subject: seedSubject,
            // 这一部在 mikan 上的番剧 id：种子块的「已看过」/观看记录与订阅用同一套键。
            mikanBangumiId: _bangumiId,
            // 主页来的封面是 mikan 图床（不需要 Bangumi 的 Referer），传这一条自己的。
            coverReferer: widget.entry.coverReferer,
            onOpenSearchPage: () {
              // 与动漫库详细页同一套：先关掉这一页，再去搜索页按番名搜（不叠两层路由）。
              unawaited(Navigator.of(context).maybePop());
              openRecommendSearch(ref, seedSubject);
            },
          ),
          for (final SubscriptionView sub in mine) ...<Widget>[
            const SizedBox(height: 12),
            _SubscriptionSection(
              entry: widget.entry,
              subscription: sub,
              batchBusy: _batchBusy,
              onBatchBusy: (bool v) => setState(() => _batchBusy = v),
            ),
          ],
          const SizedBox(height: 18),
          _AvailableGroups(
            entry: widget.entry,
            bangumiId: _bangumiId,
            detail: detail,
            subscribed: mine,
          ),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.entry, required this.subscribedGroups});

  final FollowingEntry entry;
  final int subscribedGroups;

  @override
  Widget build(BuildContext context) {
    final DsTokens t = context.ds;
    final List<String> parts = <String>[
      if (entry.totalEpisodes != null) '共 ${entry.totalEpisodes} 话',
      if (subscribedGroups > 0) '已订阅 $subscribedGroups 个字幕组' else '还没有订阅字幕组',
      if (entry.score != null) '★${entry.score!.toStringAsFixed(1)}',
      if (entry.airDate != null) '开播 ${entry.airDate}',
    ];
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        SizedBox(
          width: 96,
          height: 96 / kPosterAspect,
          child: DsCover(
              url: entry.coverUrl,
              referer: entry.coverReferer,
              radius: t.radiusBadge,
              // 96 × (96 ÷ 0.705) 固定海报槽 → 不裁（见 kPosterFit）。
              fit: kPosterFit),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                entry.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: t.text,
                  fontSize: DsTypeScale.title,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if ((entry.titleEn ?? '').trim().isNotEmpty) ...<Widget>[
                const SizedBox(height: 4),
                Text(
                  entry.titleEn!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: t.text3, fontSize: DsTypeScale.caption),
                ),
              ],
              const SizedBox(height: 6),
              Text(
                parts.join(' · '),
                style: TextStyle(color: t.text2, fontSize: DsTypeScale.caption),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// 一个已订阅字幕组：管理按钮 + 这一组的剧集（打勾 / 下载 / 播放）。
class _SubscriptionSection extends ConsumerStatefulWidget {
  const _SubscriptionSection({
    required this.entry,
    required this.subscription,
    required this.batchBusy,
    required this.onBatchBusy,
  });

  final FollowingEntry entry;
  final SubscriptionView subscription;
  final bool batchBusy;
  final ValueChanged<bool> onBatchBusy;

  @override
  ConsumerState<_SubscriptionSection> createState() => _SubscriptionSectionState();
}

class _SubscriptionSectionState extends ConsumerState<_SubscriptionSection> {
  bool _busy = false;

  /// 「下载全部」的进度文案（`加入中 3/8`）；不在批量下载时为 null。
  String? _progress;

  String get _groupName =>
      subscriptionGroupName(widget.subscription) ?? widget.subscription.name;

  Future<void> _downloadAll(List<SourceItemView> items) async {
    final Map<String, DateTime> marks = ref.read(watchedMarksProvider);
    final String group = _groupName;
    final List<SourceItemView> todo = <SourceItemView>[
      for (final SourceItemView item in items)
        if (!marks.containsKey(subscriptionItemWatchKey(
          bangumiId: widget.entry.mikanBangumiId ?? widget.entry.title,
          title: widget.entry.title,
          group: group,
          item: item,
        )))
          item,
    ];
    final int skipped = items.length - todo.length;
    if (todo.isEmpty) {
      // 第四十二轮 UX #14：统一走反馈通道（原来是自己拼的裸 SnackBar，
      // 与全仓"凸起面 + 左侧语义色细条 + 图标"那套不是一套）。这不是失败，
      // 只是"没有要做的" —— 用成功形态说清就好。
      showSuccess(
        context,
        '这一组 ${items.length} 集都看过了，没有要下的',
        seconds: 4,
      );
      return;
    }
    widget.onBatchBusy(true);
    setState(() => _busy = true);
    try {
      final BatchDownloadResult result = await enqueueDownloads(
        ref.read(queuePortProvider).enqueueDownload,
        todo,
        // 一次 20 条是串行的（避免并发打同一个站被当抓取器），所以必须有进度，
        // 否则按钮一直是「加入中…」，用户不知道卡住了还是在跑（UX #24）。
        onProgress: (int done, int total) {
          if (!mounted) return;
          setState(() => _progress = '加入中 $done/$total');
        },
      );
      if (!mounted) return;
      ref.invalidate(queueJobsProvider);
      final String summary = '${batchDownloadSummary(result)}（跳过已看过 $skipped 集）';
      // 有失败就按**失败**画（带「怎么办」），不能混成一条普通提示 —— 否则
      // "13 条失败：第一条…" 看起来跟"已加入 13 条"是同一种东西（UX #24）。
      if (result.failures.isEmpty) {
        showSuccess(context, summary, seconds: 6);
      } else {
        showFailure(
          context,
          DsFailure(
            summary,
            hint: '再点一次「下载全部」只会补没进队列的那些（已在队列里的按 id 去重）',
          ),
        );
      }
    } catch (error, stackTrace) {
      // 旧实现只有 `finally` 没有 `catch`：异常从 async 回调里逃出去，静默消失。
      if (!mounted) return;
      showFailure(context, describeFailure(error, stackTrace: stackTrace));
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _progress = null;
        });
        widget.onBatchBusy(false);
      }
    }
  }

  Future<void> _markAll(List<SourceItemView> items, bool watched) async {
    // ⚠️ **合集/全集条目（`isBatch`）不参与批量打勾**（第二十七轮复核抓到的真实缺陷）：
    // 用户要跳过的是"看过的**集**"；把一条没看过的合集标成已看过之后，
    // 「下载全部」会**永远跳过它**，而用户并不知道自己刚把合集标掉了。
    final List<SourceItemView> episodes =
        items.where((SourceItemView i) => !i.isBatch).toList(growable: false);
    final int skippedBatch = items.length - episodes.length;
    final String group = _groupName;
    final List<String> keys = subscriptionItemWatchKeys(
      bangumiId: widget.entry.mikanBangumiId ?? widget.entry.title,
      title: widget.entry.title,
      group: group,
      items: episodes,
    );
    // 勾是**要落盘**的：写盘失败必须报出来，否则用户看到勾上了、重启后没了
    //（第四十二轮 UX #5）。
    final bool ok = await runGuardedBool(
      context,
      action: () async {
        final WatchedMarksController marks =
            ref.read(watchedMarksProvider.notifier);
        // 用户动作：`byUser: true` —— 手动打勾会解掉"用户取消过"的抑制，
        // 手动取消会记进抑制表。
        if (watched) {
          await marks.mark(keys, byUser: true);
        } else {
          await marks.unmark(keys, byUser: true);
        }
      },
    );
    if (!ok || !mounted) return;
    if (skippedBatch > 0) {
      // 第四十二轮 UX #14：统一走反馈通道。这是"有一部分没按你说的做" = 警告，
      // 不是成功也不是失败。
      showWarning(
        context,
        '合集/全集条目不计入批量打勾（跳过 $skippedBatch 条）',
        hint: '它们不在「下载全部」的跳过判据里 —— 要排除整季打包，去「设置」的省流量列表加一条规则',
      );
    }
  }

  Future<void> _remove() async {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Text('取消订阅「$_groupName」？'),
        content: const Text('只删订阅与它的规则，已经下载的文件、看过的勾都不受影响。'),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('取消订阅')),
        ],
      ),
    );
    if (ok != true) return;
    if (!mounted) return;
    await runGuarded(
      context,
      action: () => ref.read(subsPortProvider).remove(widget.subscription.id),
      success: '已取消订阅「$_groupName」',
    );
  }

  Future<void> _refresh() async {
    setState(() => _busy = true);
    try {
      await runGuarded(
        context,
        action: () async {
          final SubsRefreshResult result =
              await ref.read(subsPortProvider).refresh(widget.subscription.id);
          ref.invalidate(subscriptionItemsProvider(widget.subscription.id));
          if (!mounted) return;
          // 第四十二轮 UX #14：统一走反馈通道（原来是裸 SnackBar）。
          showSuccess(
            context,
            result.seeded
                ? '首次抓取：只做已读标记（${result.fetched} 条），未入队历史剧集'
                : '刷新完成：抓到 ${result.fetched} 条，命中 ${result.matched} 条，入队 ${result.queued} 条',
            seconds: 5,
          );
        },
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _preview() async {
    final String id = widget.subscription.id;
    await showDialog<void>(
      context: context,
      builder: (BuildContext context) => _PreviewDialog(subscriptionId: id, name: _groupName),
    );
  }

  Future<void> _editRule() async {
    final SubscriptionView sub = widget.subscription;
    final List<SubsRuleView>? rules = await showDialog<List<SubsRuleView>>(
      context: context,
      builder: (BuildContext context) => _RuleEditorDialog(rules: sub.rules),
    );
    if (rules == null || !mounted) return;
    await runGuarded(
      context,
      action: () => ref.read(subsPortProvider).upsert(sub.copyWith(rules: rules)),
      success: '已保存「$_groupName」的规则',
    );
  }

  @override
  Widget build(BuildContext context) {
    final DsTokens t = context.ds;
    final SubscriptionView sub = widget.subscription;
    final AsyncValue<List<SourceItemView>> items =
        ref.watch(subscriptionItemsProvider(sub.id));
    final String group = _groupName;
    final String bangumiId = widget.entry.mikanBangumiId ?? widget.entry.title;
    final Map<String, DateTime> marks = ref.watch(watchedMarksProvider);

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      decoration: t.cardDecoration(
        radius: t.radiusCard,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(Icons.groups_outlined, size: 15, color: t.accent),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  group,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: t.text,
                    fontSize: DsTypeScale.body,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              NeoButton(
                label: _busy ? '刷新中…' : '刷新',
                icon: Icons.refresh,
                compact: true,
                onPressed: _busy ? null : _refresh,
              ),
              const SizedBox(width: 6),
              NeoButton(
                label: '规则',
                icon: Icons.tune,
                compact: true,
                onPressed: _editRule,
              ),
              const SizedBox(width: 6),
              NeoButton(
                label: '命中预览',
                icon: Icons.filter_alt_outlined,
                compact: true,
                onPressed: _preview,
              ),
              const SizedBox(width: 6),
              NeoIconButton(
                icon: Icons.delete_outline,
                tooltip: '取消订阅这一组（不影响已下载的文件）',
                // 同 #36：批量动作在跑时不许并发改订阅。
                onPressed: _busy ? null : () => unawaited(_remove()),
              ),
            ],
          ),
          const SizedBox(height: 8),
          DsAsync<List<SourceItemView>>(
            value: items,
            loadingLabel: '正在抓取「$group」的 RSS…',
            onRetry: () => ref.invalidate(subscriptionItemsProvider(sub.id)),
            isEmpty: (List<SourceItemView> list) => list.isEmpty,
            empty: const DsEmpty(
              icon: Icons.rss_feed,
              title: '这一组的 RSS 里暂无条目',
              message: 'mikan 这一组可能还没发布剧集，或者地址已失效（可到番剧页重新订阅）。',
            ),
            builder: (BuildContext context, List<SourceItemView> list) {
              final List<String> keys = subscriptionItemWatchKeys(
                bangumiId: bangumiId,
                title: widget.entry.title,
                group: group,
                items: list,
              );
              int watched = 0;
              for (final String k in keys) {
                if (marks.containsKey(k)) watched++;
              }
              final bool allWatched = keys.isNotEmpty && watched == keys.length;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Text(
                        '${list.length} 集 · 已看过 $watched 集',
                        style: TextStyle(color: t.text2, fontSize: DsTypeScale.caption),
                      ),
                      const Spacer(),
                      NeoButton(
                        label: _busy
                            ? (_progress ?? '加入中…')
                            : '下载全部（跳过已看过）',
                        icon: Icons.download,
                        kind: NeoButtonKind.primary,
                        compact: true,
                        busy: _busy,
                        onPressed: _busy ? null : () => _downloadAll(list),
                      ),
                      const SizedBox(width: 6),
                      NeoButton(
                        label: allWatched ? '取消全看过' : '全部标记已看过',
                        icon: allWatched ? Icons.remove_done : Icons.done_all,
                        compact: true,
                        // 忙的时候一并禁掉（同页「刷新」「下载全部」早就禁了）——否则
                        // 「下载全部」正在读勾、这边同时在改勾，两边看到的是不同世界
                        //（第四十二轮 UX #36）。
                        onPressed: _busy ? null : () => _markAll(list, !allWatched),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  for (final SourceItemView item in list)
                    _EpisodeRow(
                      item: item,
                      watched: marks.containsKey(subscriptionItemWatchKey(
                        bangumiId: bangumiId,
                        title: widget.entry.title,
                        group: group,
                        item: item,
                      )),
                      // 单集那个勾也要能报错：勾是落盘的，写盘失败以前完全静默
                      //（第四十二轮 UX #5）。成功不必提示 —— 勾变了本身就是反馈。
                      onToggleWatched: () => runGuarded(
                        context,
                        action: () => ref
                            .read(watchedMarksProvider.notifier)
                            .toggle(subscriptionItemWatchKey(
                              bangumiId: bangumiId,
                              title: widget.entry.title,
                              group: group,
                              item: item,
                            )),
                      ),
                      onDownload: () => runGuarded(
                        context,
                        action: () => ref.read(queuePortProvider).enqueueDownload(item),
                        success: '已加入下载队列',
                      ),
                      onPlay: () => _play(item, list),
                    ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  Future<void> _play(SourceItemView item, List<SourceItemView> all) async {
    final NavigatorState navigator = Navigator.of(context);
    await ref.read(playbackProvider.notifier).playItem(
          item,
          upNext: followingEpisodesOf(all, item),
          playlist: all,
          showTitle: widget.entry.title,
          showTitleEn: widget.entry.titleEn,
          coverUrl: widget.entry.coverUrl,
          coverReferer: widget.entry.coverReferer,
          mikanBangumiId: widget.entry.mikanBangumiId,
        );
    final DsFailure? failure = ref.read(playbackProvider).failure;
    if (failure != null) {
      if (mounted) showFailure(context, failure);
      return;
    }
    if (navigator.canPop()) navigator.pop();
  }
}

/// 「同一组里集数更大的那些」（自动下一集的素材）；与 `domain/episodes.dart` 同一口径。
List<SourceItemView> followingEpisodesOf(List<SourceItemView> all, SourceItemView base) {
  final int? baseEpisode = episodeNumber(base);
  if (baseEpisode == null) return const <SourceItemView>[];
  final List<SourceItemView> out = <SourceItemView>[
    for (final SourceItemView item in all)
      if (item.id != base.id && (episodeNumber(item) ?? -1) > baseEpisode) item,
  ];
  out.sort((SourceItemView a, SourceItemView b) =>
      (episodeNumber(a) ?? 0).compareTo(episodeNumber(b) ?? 0));
  return out;
}

/// 剧目行：勾 + 标题 + 大小 + 下载 / 播放。
class _EpisodeRow extends StatelessWidget {
  const _EpisodeRow({
    required this.item,
    required this.watched,
    required this.onToggleWatched,
    required this.onDownload,
    required this.onPlay,
  });

  final SourceItemView item;
  final bool watched;
  final VoidCallback onToggleWatched;
  final VoidCallback onDownload;
  final VoidCallback onPlay;

  @override
  Widget build(BuildContext context) {
    final DsTokens t = context.ds;
    final String? label = episodeLabelOf(item);
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      // 扁平化（第三十轮）：整行 `successSoft` 是大面积语义色（规范 F16/§2 只允许小面积），
      // 改成和其它凹槽面一样的 `sunken` + 1px `line`；「已看过」用小面积 success 12% 表达。
      decoration: watched
          ? t.inset(radius: t.radiusControl, color: t.success.withValues(alpha: 0.12))
          : t.inset(radius: t.radiusControl),
      child: Row(
        children: <Widget>[
          // 「已看过」的勾：点一下切换（用户：「订阅可在正在追内标记已看过，
          // 已看过的在旁边打上勾」）。
          Tooltip(
            message: watched ? '已看过（再点一下取消）' : '标记为已看过',
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: onToggleWatched,
                child: Icon(
                  watched ? Icons.check_box : Icons.check_box_outline_blank,
                  size: 17,
                  color: watched ? t.success : t.text3,
                ),
              ),
            ),
          ),
          const SizedBox(width: 9),
          SizedBox(
            width: 46,
            child: Text(
              label ?? '—',
              style: TextStyle(
                color: watched ? t.success : t.accent,
                fontSize: DsTypeScale.caption,
                fontWeight: FontWeight.w600,
                fontFeatures: DsTokens.tabular,
              ),
            ),
          ),
          Expanded(
            child: Text(
              item.displayTitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: t.text, fontSize: DsTypeScale.caption),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            formatBytes(item.sizeBytes),
            style: TextStyle(
              color: t.text3,
              fontSize: DsTypeScale.caption,
              fontFeatures: DsTokens.tabular,
            ),
          ),
          const SizedBox(width: 8),
          NeoButton(
            label: '下载',
            icon: Icons.download,
            compact: true,
            onPressed: item.canDownload ? onDownload : null,
          ),
          const SizedBox(width: 6),
          NeoButton(
            label: '播放',
            icon: Icons.play_arrow,
            kind: NeoButtonKind.primary,
            compact: true,
            onPressed: onPlay,
          ),
        ],
      ),
    );
  }
}

/// 这一部番还有哪些字幕组没订阅（从 mikan 番剧页取；点「订阅」直接订）。
class _AvailableGroups extends ConsumerWidget {
  const _AvailableGroups({
    required this.entry,
    required this.bangumiId,
    required this.detail,
    required this.subscribed,
  });

  final FollowingEntry entry;
  final String bangumiId;
  final AsyncValue<BangumiDetailView>? detail;
  final List<SubscriptionView> subscribed;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final DsTokens t = context.ds;
    if (bangumiId.isEmpty) {
      return const DsBanner(
        kind: DsBannerKind.warning,
        text: '这条追番记录没有 mikan 番剧 id：列不出字幕组。'
            '到「主页」点这一部，或在「搜索」页按番名找这一部再订阅。',
      );
    }
    final AsyncValue<BangumiDetailView>? value = detail;
    if (value == null) return const SizedBox.shrink();
    final List<BangumiGroupView> groups = value.value?.groups ?? const <BangumiGroupView>[];
    final List<BangumiGroupView> rest = <BangumiGroupView>[
      for (final BangumiGroupView g in groups)
        if (subscriptionForGroup(subscribed, bangumiId: bangumiId, groupName: g.name) == null) g,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text('这一部的字幕组', style: dsTableHeaderStyle(t)),
        const SizedBox(height: 6),
        if (value.isLoading && groups.isEmpty)
          const DsLoading(label: '正在拉取这一部的字幕组…')
        else if (groups.isEmpty)
          Text(
            'mikan 没解析出字幕组（可能是新番未开播）。',
            style: TextStyle(color: t.text3, fontSize: DsTypeScale.caption),
          )
        else if (rest.isEmpty)
          Text(
            '所有字幕组都订阅了。',
            style: TextStyle(color: t.text3, fontSize: DsTypeScale.caption),
          )
        else
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              for (final BangumiGroupView g in rest)
                Container(
                  padding: const EdgeInsets.fromLTRB(10, 6, 6, 6),
                  // 第三十轮：手搓的 sunken 胶囊少了 1px `line` —— 同一套面色的
                  // `NeoPill` / `DsInset` 都带那条线，这里走 `t.inset()` 补齐。
                  decoration: t.inset(radius: t.radiusPill),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Text(
                        g.name,
                        style: TextStyle(color: t.text2, fontSize: DsTypeScale.caption),
                      ),
                      const SizedBox(width: 8),
                      GroupSubscribeButton(
                        bangumiId: bangumiId,
                        showTitle: entry.title,
                        group: g,
                      ),
                    ],
                  ),
                ),
            ],
          ),
      ],
    );
  }
}

/// 命中预览（订阅规则会下哪些）。原来的「订阅」页里有它，第二十七轮搬到这里。
class _PreviewDialog extends ConsumerWidget {
  const _PreviewDialog({required this.subscriptionId, required this.name});

  final String subscriptionId;
  final String name;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final DsTokens t = context.ds;
    final AsyncValue<List<SourceItemView>> preview =
        ref.watch(subsPreviewProvider(subscriptionId));
    return AlertDialog(
      title: Text('命中预览 · $name'),
      content: SizedBox(
        width: 640,
        height: 420,
        child: DsAsync<List<SourceItemView>>(
          value: preview,
          loadingLabel: '正在按规则匹配（会抓取一次这一组的 RSS）…',
          onRetry: () => ref.invalidate(subsPreviewProvider(subscriptionId)),
          isEmpty: (List<SourceItemView> items) => items.isEmpty,
          empty: const DsEmpty(
            icon: Icons.filter_alt_off,
            title: '这条规则当前没有命中任何条目',
            message: '点这个字幕组那一行的「规则」可以把 include 留空 = 全部；'
                '体积/分辨率限制也会过滤掉条目',
          ),
          builder: (BuildContext context, List<SourceItemView> items) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  '命中 ${items.length} 条（不会真的下载；自动下载要规则里打开「命中即入队」）',
                  style: TextStyle(color: t.text2, fontSize: DsTypeScale.secondary),
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: ListView.builder(
                    itemCount: items.length,
                    itemBuilder: (BuildContext context, int index) {
                      final SourceItemView item = items[index];
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: Container(
                          padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
                          decoration: t.cardDecoration(
                            radius: t.radiusControl,
                          ),
                          child: Row(
                            children: <Widget>[
                              Expanded(
                                child: Text(
                                  item.displayTitle,
                                  maxLines: 2,
                                  style: TextStyle(color: t.text, fontSize: DsTypeScale.body),
                                ),
                              ),
                              const SizedBox(width: 8),
                              DsChip(label: formatBytes(item.sizeBytes)),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            );
          },
        ),
      ),
      actions: <Widget>[
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('关闭')),
      ],
    );
  }
}

/// 规则编辑器（第二十七轮从「订阅」页搬来）：include / exclude / 体积 / 分辨率 / 自动下载。
class _RuleEditorDialog extends StatefulWidget {
  const _RuleEditorDialog({required this.rules});

  final List<SubsRuleView> rules;

  @override
  State<_RuleEditorDialog> createState() => _RuleEditorDialogState();
}

class _RuleEditorDialogState extends State<_RuleEditorDialog> {
  late List<SubsRuleView> _rules = <SubsRuleView>[...widget.rules];

  String _newRuleId() => 'rule-${DateTime.now().microsecondsSinceEpoch}';

  @override
  Widget build(BuildContext context) {
    final DsTokens t = context.ds;
    return AlertDialog(
      title: const Text('订阅规则'),
      content: SizedBox(
        width: 720,
        height: 480,
        child: ListView(
          children: <Widget>[
            Text(
              '这些规则决定「命中预览」与「命中即入队」看哪些条目。'
              '刚订阅时给的是空规则（include 与 exclude 都留空 = 这一组的集全要）—— '
              '默认排除模式里有 HEVC 10bit，照它过滤会把这一组的 HEVC 集藏起来。',
              style: TextStyle(color: t.text2, fontSize: DsTypeScale.secondary, height: 1.5),
            ),
            const SizedBox(height: 12),
            for (int i = 0; i < _rules.length; i++)
              _RuleCard(
                key: ValueKey<String>(_rules[i].id),
                rule: _rules[i],
                onChanged: (SubsRuleView next) => setState(() => _rules[i] = next),
                onRemove: _rules.length == 1 ? null : () => setState(() => _rules.removeAt(i)),
              ),
            const SizedBox(height: 6),
            Align(
              alignment: Alignment.centerLeft,
              child: NeoButton(
                label: '添加规则',
                icon: Icons.add,
                compact: true,
                onPressed: () => setState(() {
                  _rules = <SubsRuleView>[
                    ..._rules,
                    SubsRuleView(id: _newRuleId(), name: '规则 ${_rules.length + 1}'),
                  ];
                }),
              ),
            ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('取消')),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_rules),
          child: const Text('保存规则'),
        ),
      ],
    );
  }
}

class _RuleCard extends StatefulWidget {
  const _RuleCard({super.key, required this.rule, required this.onChanged, this.onRemove});

  final SubsRuleView rule;
  final ValueChanged<SubsRuleView> onChanged;
  final VoidCallback? onRemove;

  @override
  State<_RuleCard> createState() => _RuleCardState();
}

class _RuleCardState extends State<_RuleCard> {
  late final TextEditingController _name = TextEditingController(text: widget.rule.name);
  late final TextEditingController _include =
      TextEditingController(text: widget.rule.includeRegex);
  late final TextEditingController _exclude =
      TextEditingController(text: widget.rule.excludeRegex);
  late final TextEditingController _seeders =
      TextEditingController(text: '${widget.rule.minSeeders ?? 0}');
  late final TextEditingController _minSize =
      TextEditingController(text: '${widget.rule.minSizeMB}');
  late final TextEditingController _maxSize =
      TextEditingController(text: '${widget.rule.maxSizeMB}');

  @override
  void dispose() {
    _name.dispose();
    _include.dispose();
    _exclude.dispose();
    _seeders.dispose();
    _minSize.dispose();
    _maxSize.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final DsTokens t = context.ds;
    final SubsRuleView r = widget.rule;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(10),
      decoration: t.cardDecoration(
        radius: t.radiusCard,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: TextField(
                  controller: _name,
                  decoration: const InputDecoration(labelText: '规则名'),
                  style: TextStyle(color: t.text, fontSize: DsTypeScale.body),
                  onChanged: (String v) => widget.onChanged(r.copyWith(name: v)),
                ),
              ),
              const SizedBox(width: 10),
              Text(
                '命中即入队',
                style: TextStyle(color: t.text2, fontSize: DsTypeScale.secondary),
              ),
              const SizedBox(width: 8),
              NeoSwitch(
                value: r.autoDownload,
                onChanged: (bool v) => widget.onChanged(r.copyWith(autoDownload: v)),
              ),
              if (widget.onRemove != null)
                NeoIconButton(
                  icon: Icons.delete_outline,
                  tooltip: '删除这条规则',
                  onPressed: widget.onRemove,
                ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: <Widget>[
              Expanded(
                child: TextField(
                  controller: _include,
                  decoration: const InputDecoration(labelText: 'include 正则', hintText: '留空 = 全部'),
                  style: TextStyle(color: t.text, fontSize: DsTypeScale.body),
                  onChanged: (String v) => widget.onChanged(r.copyWith(includeRegex: v)),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: TextField(
                  controller: _exclude,
                  decoration: const InputDecoration(
                    labelText: 'exclude 正则',
                    hintText: '留空 = 不排除',
                  ),
                  style: TextStyle(color: t.text, fontSize: DsTypeScale.body),
                  onChanged: (String v) => widget.onChanged(r.copyWith(excludeRegex: v)),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: <Widget>[
              SizedBox(
                width: 110,
                child: TextField(
                  controller: _seeders,
                  decoration: const InputDecoration(labelText: '最少做种'),
                  style: TextStyle(color: t.text, fontSize: DsTypeScale.body),
                  onChanged: (String v) => widget.onChanged(
                    r.copyWith(minSeeders: int.tryParse(v.trim()) ?? 0),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              SizedBox(
                width: 100,
                child: TextField(
                  controller: _minSize,
                  decoration: const InputDecoration(labelText: '最小 MB'),
                  style: TextStyle(color: t.text, fontSize: DsTypeScale.body),
                  onChanged: (String v) => widget.onChanged(
                    r.copyWith(minSizeMB: int.tryParse(v.trim()) ?? 0),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              SizedBox(
                width: 100,
                child: TextField(
                  controller: _maxSize,
                  decoration: const InputDecoration(labelText: '最大 MB'),
                  style: TextStyle(color: t.text, fontSize: DsTypeScale.body),
                  onChanged: (String v) => widget.onChanged(
                    r.copyWith(maxSizeMB: int.tryParse(v.trim()) ?? 0),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Text(
                '偏好分辨率',
                style: TextStyle(color: t.text2, fontSize: DsTypeScale.secondary),
              ),
              const SizedBox(width: 8),
              NeoDropdown<int?>(
                width: 104,
                value: r.preferResolution,
                tooltip: '命中多条时优先选这一档',
                label: r.preferResolution == null ? '不限' : '${r.preferResolution}p',
                items: const <NeoDropdownItem<int?>>[
                  NeoDropdownItem<int?>(null, '不限'),
                  NeoDropdownItem<int?>(720, '720p'),
                  NeoDropdownItem<int?>(1080, '1080p'),
                  NeoDropdownItem<int?>(2160, '2160p'),
                ],
                onSelected: (int? v) => widget.onChanged(
                  r.preferResolution == v
                      ? r
                      : r.copyWith(preferResolution: v, clearPreferResolution: v == null),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
