/// 动漫库详细页的「种子」块（第四十五轮起，第四十八轮换过引擎）。
///
/// 用户原话（第四十五轮）：「能实现动漫库中直接显示种子吗，就像主页那样」—— 也就是**主页卡片
/// 点进去那一页**（`ui/bangumi_detail.dart`：按字幕组列剧集 + 每集磁力）的数据，直接落到
/// 动漫库的条目详细页上，不用再跑去搜索页重搜一遍。
///
/// 用户原话（第四十八轮）：
/// > 「我自己去 mikan 搜都搜索得到，这里就搜不到了，修复一下，然后改为主流搜索当引擎，
/// >   按字幕组分隔，不同搜索引擎同名字就按合并」
///
/// 所以这一块的形态是：
/// * **引擎 = 主流站点的关键字搜索**（用户勾选的那些源，聚合搜番名；`LibrarySeedController`）；
/// * 结果**按字幕组分段**（一段一行抬头，列宽与搜索页完全一致，表头只在最上面画一次）；
/// * **跨站同名合并**成一条（合并过的行会带一个"别的站也有"的小标记，别让用户以为少看了一个站）；
/// * 每段抬头：组名 · 条数 · 「订阅」（只有拿得到那张 mikan 番剧页时才有）·「这一组都入队」；
/// * **每一段默认收起**（第四十八轮·补，用户「把搜索结果默认收起形态」）—— 进页面只看到
///   一行行组抬头，点哪一段抬头（或底下那颗「展开全部」）才画那一段的条目：
///   一屏十几个组名比一屏几行番名好挑，而且「这一组都入队」在收起状态下照样点得到；
/// * 展开之后先露 [kSeedGroupVisibleStep] 条，其余藏在「本组还有 N 条」后面；
/// * 段本身先露 [kSeedVisibleGroups] 个，其余的走「显示更多字幕组」；
/// * mikan 番剧页降级成**手动**口（「改搜索词 / 粘链接」里粘地址或 id）—— 它给的东西更完整
///   （整部剧集表 + 每组自己的 RSS），只是不该再当主力，见 `domain/library_seed.dart` 的库注释。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/bangumi.dart';
import '../../domain/batch_download.dart';
import '../../domain/episodes.dart';
import '../../domain/error_text.dart';
import '../../domain/following_subscription.dart';
import '../../domain/library_seed.dart';
import '../../domain/models.dart';
import '../../domain/subtitle_groups.dart';
import '../../state/playback.dart';
import '../../state/providers.dart';
import '../../theme/tokens.dart';
import '../widgets/feedback.dart';
import '../widgets/group_subscribe.dart';
import '../widgets/neo.dart';
import '../widgets/search_sections.dart';
import '../widgets/state_views.dart';

/// 整块的 key（版面断言看它）。
const Key dsDetailSeedsKey = Key('library-detail-seeds');

/// 正在找 / 正在取时的占位 key。
const Key dsDetailSeedsLoadingKey = Key('library-detail-seeds-loading');

/// 整块没成（空 / 网络失败）时的 key。
const Key dsDetailSeedsFailedKey = Key('library-detail-seeds-failed');

/// 失败态那颗「重新搜一次」。
const Key dsDetailSeedsRetryKey = Key('library-detail-seeds-retry');

/// 「在搜索页打开」那颗小链接。
const Key dsDetailSeedsSearchPageKey = Key('library-detail-seeds-search-page');

/// 结果表（整块的外壳 key）。
const Key dsDetailSeedsTableKey = Key('library-detail-seeds-table');

/// 「显示更多字幕组」。
const Key dsDetailSeedsMoreKey = Key('library-detail-seeds-more');

/// 「展开全部 / 收起全部」（第四十八轮·补：每段默认收起，这颗是一次全开）。
const Key dsDetailSeedsExpandAllKey = Key('library-detail-seeds-expand-all');

/// 字幕组那一段（每段一个，key 带组名 —— 用例据此定位某一段）。
Key dsDetailSeedsGroupKey(String key) => ValueKey<String>('seed-group-$key');

/// 那一段的**抬头**（点它 = 展开 / 收起这一段）。
Key dsDetailSeedsGroupToggleKey(String key) =>
    ValueKey<String>('seed-group-toggle-$key');

/// 某一段的「本组还有 N 条」。
Key dsDetailSeedsGroupMoreKey(String key) =>
    ValueKey<String>('seed-group-more-$key');

/// 工具行（改搜索词 / 粘链接）。
const Key dsDetailSeedsQueryFieldKey = Key('library-detail-seeds-query');
const Key dsDetailSeedsRawFieldKey = Key('library-detail-seeds-raw');
const Key dsDetailSeedsApplyQueryKey = Key('library-detail-seeds-apply-query');
const Key dsDetailSeedsApplyRawKey = Key('library-detail-seeds-apply-raw');

class LibrarySeedBlock extends ConsumerStatefulWidget {
  const LibrarySeedBlock({
    super.key,
    required this.subject,
    required this.onOpenSearchPage,
  });

  final BangumiSubject subject;

  /// 「在搜索页打开」要干什么（由页面给：它已经 import 了 `openRecommendSearch`）。
  final VoidCallback onOpenSearchPage;

  @override
  ConsumerState<LibrarySeedBlock> createState() => _LibrarySeedBlockState();
}

class _LibrarySeedBlockState extends ConsumerState<LibrarySeedBlock> {
  final Set<String> _selected = <String>{};

  /// 哪几段**展开着**（第四十八轮·补：默认**全收起** —— 进页面先看组名与条数，
  /// 点哪一段看哪一段）。纯界面状态，不落盘、换条目就清。
  final Set<String> _openGroups = <String>{};

  /// 哪几段把「本组还有 N 条」也点开了（= 这一段全露）。收起那一段时一起丢掉，
  /// 再展开又回到"先露 12 条"。
  final Set<String> _fullGroups = <String>{};

  final TextEditingController _word = TextEditingController();
  final TextEditingController _raw = TextEditingController();
  bool _tools = false;
  bool _busyGroup = false;
  String? _busyItemId;

  @override
  void initState() {
    super.initState();
    // 进页面就开始解析（用户第四十五轮：进入就抓）。
    _ensureSoon();
  }

  /// 延到首帧之后再去动 provider。
  ///
  /// ⚠️ 不能在 `initState` / `didUpdateWidget` 里直接调：那两个位置**正在建/更新组件树**，
  /// Riverpod 会当场抛「Tried to modify a provider while the widget tree was building」
  /// （第一版就是这么把 15 个既有用例打红的）。
  void _ensureSoon() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(librarySeedProvider.notifier).ensure(widget.subject);
    });
  }

  @override
  void didUpdateWidget(LibrarySeedBlock oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.subject.id == widget.subject.id) return;
    _selected.clear();
    _openGroups.clear();
    _fullGroups.clear();
    _ensureSoon();
  }

  @override
  void dispose() {
    _word.dispose();
    _raw.dispose();
    super.dispose();
  }

  // ── 动作 ────────────────────────────────────────────────────────────────────

  Future<void> _play(
    SourceItemView item,
    LibrarySeedState s,
    String showTitle,
  ) async {
    setState(() => _busyItemId = item.id);
    try {
      await ref
          .read(playbackProvider.notifier)
          .playItem(
            item,
            upNext: followingEpisodes(s.episodes, item),
            playlist: s.episodes,
            showTitle: showTitle,
            coverUrl: widget.subject.coverUrl,
            coverReferer: 'https://bgm.tv/',
            // 手动锚过番剧页时把它带上（观看记录按 `mikan:<id>` 归组、缺链还能回那一页补）；
            // 没有锚点也没关系 —— `watch_history.dart` 会退回按番名归组。
            mikanBangumiId: s.binding?.bangumiId,
          );
      final DsFailure? failure = ref.read(playbackProvider).failure;
      if (failure != null && mounted) showFailure(context, failure);
    } catch (error, stackTrace) {
      if (mounted) {
        showFailure(context, describeFailure(error, stackTrace: stackTrace));
      }
    } finally {
      if (mounted) setState(() => _busyItemId = null);
    }
  }

  /// 「这一组都入队」：跳过已看过 / 已在队列 / 已完成的。
  ///
  /// ⚠️ [group] 是**这一段自己的条目**，不是"按组名去整个池子里捞"（第四十八轮改）：
  /// 协作署名的条目（`喵萌奶茶屋&LoliHouse`）在归段时只落一段，而"按组名捞"会用**并集**
  /// 把别的段里的条目也拉进来 —— 那样按钮上写的"（N 条）"和下进去的对不上。
  Future<void> _enqueueGroup(
    List<SourceItemView> group,
    LibrarySeedState s,
    String showTitle,
    Map<String, DateTime> watched,
    List<QueueJobView> jobs,
    List<EngineTorrentView> torrents,
  ) async {
    final List<SourceItemView> all = group
        .where(canBatchDownload)
        .toList(growable: false);
    final Set<String> inQueue = <String>{
      for (final QueueJobView j in jobs) j.item.dedupeKey,
    };
    final Set<String> done = <String>{
      for (final EngineTorrentView t in torrents)
        if (t.finished || t.progress >= 1) t.infoHash.toLowerCase(),
    };
    String keyOf(SourceItemView e) => subscriptionItemWatchKey(
      bangumiId: s.binding?.bangumiId ?? widget.subject.displayTitle,
      title: showTitle,
      group: e.group ?? '',
      item: e,
    );
    final List<SourceItemView> todo = <SourceItemView>[
      for (final SourceItemView e in all)
        if (!watched.containsKey(keyOf(e)) &&
            !inQueue.contains(e.dedupeKey) &&
            !(e.infoHash != null && done.contains(e.infoHash!.toLowerCase())))
          e,
    ];
    final int skipped = all.length - todo.length;
    if (todo.isEmpty) {
      showSuccess(
        context,
        '这一组 ${all.length} 条都看过了（或已在队列里），没有要下的',
        seconds: 4,
      );
      return;
    }
    setState(() => _busyGroup = true);
    try {
      final BatchDownloadResult result = await enqueueDownloads(
        ref.read(queuePortProvider).enqueueDownload,
        todo,
      );
      ref.invalidate(queueJobsProvider);
      if (!mounted) return;
      final String summary = batchDownloadSummary(result);
      final String extra = skipped == 0
          ? ''
          : '（另跳过 $skipped 条：已看过 / 已在队列 / 已完成）';
      if (result.failures.isEmpty) {
        showSuccess(context, '$summary$extra');
      } else {
        showFailure(
          context,
          DsFailure(
            '$summary$extra',
            hint: '再点一次「这一组都入队」会按 id 去重，只补失败的',
          ),
        );
      }
    } catch (error, stackTrace) {
      if (mounted) {
        showFailure(context, describeFailure(error, stackTrace: stackTrace));
      }
    } finally {
      if (mounted) setState(() => _busyGroup = false);
    }
  }

  /// 行尾的状态标记：已看过 / 在队列 / 已完成 / 别的站也有这一条。
  List<Widget> _marks(
    SourceItemView item,
    LibrarySeedState s,
    String showTitle, {
    required Map<String, DateTime> watched,
    required List<QueueJobView> jobs,
    required List<EngineTorrentView> torrents,
  }) {
    final bool seen = watched.containsKey(
      subscriptionItemWatchKey(
        bangumiId: s.binding?.bangumiId ?? widget.subject.displayTitle,
        title: showTitle,
        group: item.group ?? '',
        item: item,
      ),
    );
    final QueueJobView? job = jobs
        .where((QueueJobView j) => j.item.dedupeKey == item.dedupeKey)
        .firstOrNull;
    final String? hash = item.infoHash?.toLowerCase();
    final bool done =
        hash != null &&
        hash.isNotEmpty &&
        torrents.any(
          (EngineTorrentView t) =>
              t.infoHash.toLowerCase() == hash && (t.finished || t.progress >= 1),
        );
    final List<String> alsoOn = seedAlsoOn(item);
    return <Widget>[
      if (seen) _mark(Icons.check_box, '已看过', context.ds.success),
      if (job != null) _mark(Icons.downloading, job.state.label, context.ds.accent),
      if (done) _mark(Icons.check_circle, '已完成', context.ds.success),
      if (alsoOn.isNotEmpty)
        _mark(
          Icons.layers,
          '另外 ${alsoOn.length} 个站也有这一条（同名合并成了一条）',
          context.ds.text2,
        ),
    ];
  }

  Widget _mark(IconData icon, String tooltip, Color color) => Tooltip(
    message: tooltip,
    child: Padding(
      padding: const EdgeInsets.only(left: 4),
      child: Icon(icon, size: 14, color: color),
    ),
  );

  // ── 段的开合（第四十八轮·补） ────────────────────────────────────────────────

  /// 点某一段的抬头：收着的 → 展开；展开的 → 收起来（收起时顺手关掉段内的"全露"，
  /// 下次再点开仍然先露 12 条 —— 否则它会记住一个用户已经不看了的滚动位置）。
  void _toggleGroup(String key) => setState(() {
    if (_openGroups.remove(key)) {
      _fullGroups.remove(key);
    } else {
      _openGroups.add(key);
    }
  });

  /// 「展开全部 / 收起全部」：**只对现在露出来的这些段**动手（没露出来的那些
  /// 走「显示更多字幕组」，展开它们等于凭空长出一屏内容）。
  void _toggleAllGroups(List<SeedGroup> shown) => setState(() {
    if (_openGroups.isEmpty) {
      for (final SeedGroup group in shown) {
        _openGroups.add(group.key);
      }
    } else {
      _openGroups.clear();
      _fullGroups.clear();
    }
  });

  // ── 渲染 ────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final DsTokens t = context.ds;
    final LibrarySeedState watched = ref.watch(librarySeedProvider);
    // 换了一部番时，provider 里还留着上一部的状态 —— 先按"正在找"画，别把别人的种子
    // 摆在这一页上（第四十四轮同一条纪律：晚到的结果不许上屏）。
    final LibrarySeedState s = watched.subjectId == widget.subject.id
        ? watched
        : LibrarySeedState(
            subjectId: widget.subject.id,
            phase: LibrarySeedPhase.searching,
          );
    final Map<String, DateTime> marks = ref.watch(watchedMarksProvider);
    // ⚠️ 用**安全快照**（见 `state/providers.dart` 的 `queueJobsSnapshotProvider`）：
    // 直接 watch 那两个流，在"未装配"环境下会让 Riverpod 排一条自动重试计时器。
    final List<QueueJobView> jobs = ref.watch(queueJobsSnapshotProvider);
    final List<EngineTorrentView> torrents = ref.watch(
      engineTorrentsSnapshotProvider,
    );
    final String showTitle =
        (s.detail?.displayTitle ?? widget.subject.displayTitle).trim();

    return Container(
      key: dsDetailSeedsKey,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
      decoration: t.cardDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          NeoSectionHeader(
            title: '种子',
            subtitle: _subtitle(s),
            padding: const EdgeInsets.only(bottom: 10),
            trailing: _headerActions(s),
          ),
          _body(context, s, showTitle, marks, jobs, torrents),
          if (_tools) ...<Widget>[const SizedBox(height: 10), _toolsRow(s)],
          if (s.phase == LibrarySeedPhase.ready) ...<Widget>[
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: Wrap(
                spacing: 8,
                runSpacing: 6,
                children: <Widget>[
                  if (s.remainingGroups > 0)
                    NeoButton(
                      key: dsDetailSeedsMoreKey,
                      label:
                          '显示更多字幕组（还有 ${s.remainingGroups} 个）',
                      icon: Icons.expand_more,
                      compact: true,
                      onPressed: ref
                          .read(librarySeedProvider.notifier)
                          .showMoreGroups,
                    ),
                  // 每段默认收起，所以给一颗"一次全开"：想通览条目的人不用一段段点。
                  // 段数多的时候它只开**现在露出来的这些**（见 `_toggleAllGroups`）。
                  if (s.shownGroups.isNotEmpty)
                    NeoButton(
                      key: dsDetailSeedsExpandAllKey,
                      label: _openGroups.isEmpty ? '展开全部' : '收起全部',
                      icon: _openGroups.isEmpty
                          ? Icons.unfold_more
                          : Icons.unfold_less,
                      compact: true,
                      onPressed: () => _toggleAllGroups(s.shownGroups),
                    ),
                  NeoButton(
                    label: _tools ? '收起工具' : '改搜索词 / 粘链接',
                    icon: Icons.tune,
                    compact: true,
                    onPressed: () => setState(() => _tools = !_tools),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// 抬头右下角那两颗：重新搜一次 + 在搜索页打开。
  Widget _headerActions(LibrarySeedState s) {
    final DsTokens t = context.ds;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        NeoIconButton(
          key: dsDetailSeedsRetryKey,
          icon: Icons.refresh,
          size: 26,
          tooltip: '重新搜一遍（绕开 30 分钟缓存）',
          onPressed: s.loading
              ? null
              : () => unawaited(ref.read(librarySeedProvider.notifier).retry()),
        ),
        const SizedBox(width: 2),
        TextButton(
          key: dsDetailSeedsSearchPageKey,
          onPressed: widget.onOpenSearchPage,
          style: TextButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            minimumSize: const Size(0, 28),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          child: Text(
            '在搜索页打开',
            style: TextStyle(color: t.accent, fontSize: DsTypeScale.caption),
          ),
        ),
      ],
    );
  }

  /// 抬头那行小字：说清"这批种子是怎么来的、用的是哪个词"。
  String _subtitle(LibrarySeedState s) => switch (s.phase) {
    LibrarySeedPhase.idle ||
    LibrarySeedPhase.searching => s.word == null
        ? '正在各站找这一部…'
        : '正在各站搜「${s.word}」…',
    LibrarySeedPhase.fetching => '正在取这张 mikan 番剧页…',
    LibrarySeedPhase.failed => switch (s.problem) {
      LibrarySeedProblem.notFound => '各站都没搜到这一部',
      LibrarySeedProblem.noMagnet => '搜到了条目，但没有可下的种子',
      LibrarySeedProblem.network => '这一轮没取回来',
      LibrarySeedProblem.badInput => '这串里没有番剧 id',
      LibrarySeedProblem.none => '没找到',
    },
    LibrarySeedPhase.ready => <String>[
      '${s.groups.length} 个字幕组',
      '共 ${s.episodes.length} 条',
      if (s.word case final String word) '用的是「$word」',
    ].join(' · '),
  };

  Widget _body(
    BuildContext context,
    LibrarySeedState s,
    String showTitle,
    Map<String, DateTime> marks,
    List<QueueJobView> jobs,
    List<EngineTorrentView> torrents,
  ) {
    final DsTokens t = context.ds;
    if (s.loading) {
      return DsLoading(
        key: dsDetailSeedsLoadingKey,
        label: s.phase == LibrarySeedPhase.fetching
            ? '正在取这张 mikan 番剧页…'
            : '正在各站搜这一部（mikan、动漫花园、ACGNX…）…',
        compact: true,
      );
    }
    if (s.phase == LibrarySeedPhase.failed) return _failure(context, s);

    final List<SeedGroup> shown = s.shownGroups;
    // 「全选本页」说的是**现在真看得见**的那些条目：收起着的段一行都没画，
    // 把它算进去就会变成"勾选了一批看不见的东西"（第四十五轮那条纪律的延续）。
    final List<SourceItemView> scope = <SourceItemView>[
      for (final SeedGroup group in shown)
        if (_openGroups.contains(group.key)) ..._visibleItems(group),
    ];
    final bool connected = ref.watch(engineStatusProvider).isConnected;
    final List<SourceOption> sources = ref.watch(sourceOptionsProvider);
    // 表头（番名 / 大小 / 状态 / 操作 + 全选）只在**第一张展开出来的**表上画一次：
    // 默认全都收着时一张表都没有，也就不该有一条孤零零的表头。
    final int headerAt = shown.indexWhere(
      (SeedGroup g) => _openGroups.contains(g.key),
    );

    return Column(
      key: dsDetailSeedsTableKey,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (s.warning case final String warning)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: DsBanner(kind: DsBannerKind.warning, text: warning),
          ),
        for (int i = 0; i < shown.length; i++) ...<Widget>[
          _groupHeader(context, s, shown[i], showTitle, marks, jobs, torrents),
          if (_openGroups.contains(shown[i].key)) ...<Widget>[
            SearchResultsTable(
              items: _visibleItems(shown[i]),
              embedded: true,
              // 表头只在最上面画一次（列宽一样，每段都来一行会把版面切碎）。
              showHeader: i == headerAt,
              selectAllScope: scope,
              engineConnected: connected,
              busyItemId: _busyItemId,
              sources: sources,
              onPlay: (SourceItemView item) =>
                  unawaited(_play(item, s, showTitle)),
              onDownload: (SourceItemView item) => runGuarded(
                context,
                action: () => ref.read(queuePortProvider).enqueueDownload(item),
                success: '已加入下载队列',
              ),
              onSubscribe: (SourceItemView item) => runGuarded(
                context,
                action: () => ref.read(queuePortProvider).attachToSubsRule(item),
                success: '已加入订阅过滤',
              ),
              selectedIds: _selected,
              onToggleSelect: (SourceItemView item) => setState(() {
                if (!_selected.remove(item.id)) _selected.add(item.id);
              }),
              onToggleSelectAll: (bool select) => setState(() {
                for (final SourceItemView item in scope) {
                  if (!canBatchDownload(item)) continue;
                  if (select) {
                    _selected.add(item.id);
                  } else {
                    _selected.remove(item.id);
                  }
                }
              }),
              marksOf: (SourceItemView item) => _marks(
                item,
                s,
                showTitle,
                watched: marks,
                jobs: jobs,
                torrents: torrents,
              ),
              groupActionLabel: (SourceItemView item) =>
                  '这一组都入队（${shown[i].count} 条）',
              onGroupAction: (SourceItemView item) => unawaited(
                _enqueueGroup(
                  shown[i].items,
                  s,
                  showTitle,
                  marks,
                  jobs,
                  torrents,
                ),
              ),
            ),
            if (_visibleItems(shown[i]).length < shown[i].count)
              Padding(
                padding: const EdgeInsets.only(top: 2, bottom: 4),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    key: dsDetailSeedsGroupMoreKey(shown[i].key),
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      minimumSize: const Size(0, 26),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    onPressed: () => setState(
                      () => _fullGroups.add(shown[i].key),
                    ),
                    child: Text(
                      '本组还有 ${shown[i].count - _visibleItems(shown[i]).length} 条',
                      style: TextStyle(
                        color: t.accent,
                        fontSize: DsTypeScale.caption,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ],
        if (_selected.isNotEmpty) ...<Widget>[
          const SizedBox(height: 8),
          Row(
            children: <Widget>[
              NeoButton(
                label: _busyGroup ? '加入中…' : '下载选中 ${_selected.length} 条',
                icon: Icons.download,
                kind: NeoButtonKind.primary,
                compact: true,
                busy: _busyGroup,
                onPressed: _busyGroup
                    ? null
                    : () async {
                        final List<SourceItemView> picked = <SourceItemView>[
                          for (final SourceItemView item in s.episodes)
                            if (_selected.contains(item.id)) item,
                        ];
                        if (picked.isEmpty) return;
                        setState(() => _busyGroup = true);
                        try {
                          final BatchDownloadResult result =
                              await enqueueDownloads(
                                ref.read(queuePortProvider).enqueueDownload,
                                picked,
                              );
                          ref.invalidate(queueJobsProvider);
                          if (!context.mounted) return;
                          final String summary = batchDownloadSummary(result);
                          if (result.failures.isEmpty) {
                            showSuccess(context, summary);
                          } else {
                            showFailure(
                              context,
                              DsFailure(summary, hint: '再点一次会按 id 去重'),
                            );
                          }
                        } finally {
                          if (mounted) setState(() => _busyGroup = false);
                        }
                      },
              ),
              const SizedBox(width: 8),
              NeoButton(
                label: '清空勾选',
                icon: Icons.deselect,
                compact: true,
                onPressed: () => setState(_selected.clear),
              ),
            ],
          ),
        ],
      ],
    );
  }

  /// 这一段现在该画几条（收起着的段一条都不画；展开了先露 [kSeedGroupVisibleStep] 条）。
  List<SourceItemView> _visibleItems(SeedGroup group) {
    if (_fullGroups.contains(group.key) ||
        group.count <= kSeedGroupVisibleStep) {
      return group.items;
    }
    return group.items.sublist(0, kSeedGroupVisibleStep);
  }

  /// 一张 mikan 番剧页里跟这一段同名的那个组（拿 RSS 地址用；没有就画不出「订阅」）。
  ///
  /// 比对走 `normalizeGroupKey`：番剧页给的是站点上的原始写法（`桜都字幕组`），
  /// 而段的 key 是归一化过的（`桜都`），直接比字符串永远对不上。
  BangumiGroupView? _detailGroupOf(LibrarySeedState s, SeedGroup group) {
    final BangumiDetailView? detail = s.detail;
    if (detail == null) return null;
    for (final BangumiGroupView it in detail.groups) {
      if (normalizeGroupKey(it.name) == group.key) return it;
    }
    return null;
  }

  /// 一段的抬头：`▸/▾` 组名（N 条）·（拿得到番剧页时）「订阅」·「这一组都入队」。
  ///
  /// 抬头本身是**这一段的开关**（第四十八轮·补：默认全收起）—— 点它才画条目。
  /// 「这一组都入队」与「订阅」留在收起态里：这两件事本来就不需要先看见每一行
  /// （想整组下的人正是最不想翻那 90 行的人）。
  Widget _groupHeader(
    BuildContext context,
    LibrarySeedState s,
    SeedGroup group,
    String showTitle,
    Map<String, DateTime> watched,
    List<QueueJobView> jobs,
    List<EngineTorrentView> torrents,
  ) {
    final DsTokens t = context.ds;
    final BangumiGroupView? detailGroup = _detailGroupOf(s, group);
    final bool open = _openGroups.contains(group.key);
    return Padding(
      key: dsDetailSeedsGroupKey(group.key),
      padding: const EdgeInsets.only(top: 10, bottom: 6),
      child: Row(
        children: <Widget>[
          Expanded(
            child: InkWell(
              key: dsDetailSeedsGroupToggleKey(group.key),
              onTap: () => _toggleGroup(group.key),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  children: <Widget>[
                    Tooltip(
                      message: open
                          ? '收起这一组'
                          : '展开这一组（${group.count} 条）',
                      child: Icon(
                        open
                            ? Icons.keyboard_arrow_down
                            : Icons.keyboard_arrow_right,
                        size: 16,
                        color: t.text3,
                      ),
                    ),
                    const SizedBox(width: 4),
                    Flexible(
                      child: Text(
                        '${group.label}（${group.count} 条）',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: dsTableHeaderStyle(
                          t,
                        ).copyWith(fontSize: DsTypeScale.secondary),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (detailGroup != null && s.binding != null) ...<Widget>[
            GroupSubscribeButton(
              bangumiId: s.binding!.bangumiId,
              showTitle: showTitle,
              group: detailGroup,
            ),
            const SizedBox(width: 6),
          ],
          NeoButton(
            label: '这一组都入队',
            icon: Icons.playlist_add,
            compact: true,
            busy: _busyGroup,
            onPressed: _busyGroup
                ? null
                : () => unawaited(
                    _enqueueGroup(
                      group.items,
                      s,
                      showTitle,
                      watched,
                      jobs,
                      torrents,
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  /// 空 / 坏（每一种空各给对应动作）。
  Widget _failure(BuildContext context, LibrarySeedState s) {
    final DsTokens t = context.ds;
    final LibrarySeedController controller = ref
        .read(librarySeedProvider.notifier);
    final String word = s.word ?? widget.subject.displayTitle;
    final int sourceCount = seedSourceTargetsFor(
      ref.watch(sourceOptionsProvider),
      ref.watch(searchProvider).excludedSourceIds,
    ).length;
    final (String title, String message) = switch (s.problem) {
      LibrarySeedProblem.notFound => (
        '各站都没搜到「$word」',
        '在勾选的 $sourceCount 个站上都问过了，一条沾边的都没有。冷门番与老番常见 —— '
            '换个词试试（日文原名 / 罗马音往往比中文名好使），'
            '或者直接粘一个 mikan 番剧页的地址（下面「改搜索词 / 粘链接」）。',
      ),
      LibrarySeedProblem.noMagnet => (
        '搜到了条目，但没有一条能下',
        '一共 ${s.episodes.length} 条，都没有磁力/直链 —— 可能是刚开播还没放源，'
            '或者站点那边临时缺。稍后再点一次「重新搜一遍」。',
      ),
      LibrarySeedProblem.network || LibrarySeedProblem.none => (
        '这一步没取回来',
        s.failure?.hint ?? s.failure?.message ?? '网络或源站那边的问题，重试一下。',
      ),
      LibrarySeedProblem.badInput => (
        '这串里没有 mikan 番剧 id',
        '粘 `https://mikanani.me/Home/Bangumi/2833` 这样的地址，或者直接写 `2833`。',
      ),
    };
    return Column(
      key: dsDetailSeedsFailedKey,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(title, style: TextStyle(color: t.text, fontSize: DsTypeScale.secondary)),
        const SizedBox(height: 4),
        Text(
          message,
          style: TextStyle(color: t.text3, fontSize: DsTypeScale.caption, height: 1.6),
        ),
        if (s.warning case final String warning)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: DsBanner(kind: DsBannerKind.warning, text: warning),
          ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 6,
          children: <Widget>[
            NeoButton(
              label: '重新搜一遍',
              icon: Icons.refresh,
              kind: NeoButtonKind.primary,
              compact: true,
              onPressed: () => unawaited(controller.retry()),
            ),
            NeoButton(
              label: '改搜索词 / 粘链接',
              icon: Icons.tune,
              compact: true,
              onPressed: () => setState(() => _tools = !_tools),
            ),
          ],
        ),
      ],
    );
  }

  /// 工具行：改搜索词 / 粘 mikan 链接或 id。
  Widget _toolsRow(LibrarySeedState s) {
    final DsTokens t = context.ds;
    final LibrarySeedController controller = ref
        .read(librarySeedProvider.notifier);
    final String? word = s.word;
    if (_word.text.isEmpty && word != null) _word.text = word;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: TextField(
                key: dsDetailSeedsQueryFieldKey,
                controller: _word,
                style: TextStyle(color: t.text, fontSize: DsTypeScale.secondary),
                decoration: const InputDecoration(
                  hintText: '换个搜索词（例如日文原名 / 罗马音）',
                  isDense: true,
                ),
                onSubmitted: (String value) =>
                    unawaited(controller.useQuery(widget.subject, value)),
              ),
            ),
            const SizedBox(width: 6),
            NeoButton(
              key: dsDetailSeedsApplyQueryKey,
              label: '搜这个词',
              icon: Icons.search,
              compact: true,
              onPressed: () =>
                  unawaited(controller.useQuery(widget.subject, _word.text)),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Row(
          children: <Widget>[
            Expanded(
              child: TextField(
                key: dsDetailSeedsRawFieldKey,
                controller: _raw,
                style: TextStyle(color: t.text, fontSize: DsTypeScale.secondary),
                decoration: const InputDecoration(
                  hintText: '粘 mikan 番剧页地址或 id（例如 2833）：把它并进这里',
                  isDense: true,
                ),
                onSubmitted: (String value) =>
                    unawaited(controller.bindRaw(widget.subject, value)),
              ),
            ),
            const SizedBox(width: 6),
            NeoButton(
              key: dsDetailSeedsApplyRawKey,
              label: '用它',
              icon: Icons.link,
              compact: true,
              onPressed: () =>
                  unawaited(controller.bindRaw(widget.subject, _raw.text)),
            ),
          ],
        ),
      ],
    );
  }
}
