/// 动漫库详细页的「种子」块（第四十五轮）。
///
/// 用户原话：「能实现动漫库中直接显示种子吗，就像主页那样」—— 也就是**主页卡片点进去
/// 那一页**（`ui/bangumi_detail.dart`：按字幕组列剧集 + 每集磁力）的数据，直接落到动漫库
/// 的条目详细页上，不用再跑去搜索页重搜一遍。
///
/// 口径全部来自第四十五轮的问答（见 `domain/library_seed.dart` 与
/// `state/providers.dart` 的 `LibrarySeedController`）：
/// * **进入就抓**，两段式文案：「正在 mikan 找这一部…」→「正在取字幕组与剧集…」；
/// * 主路径 = mikan 番剧页（整部、按字幕组），对应关系**落盘记住**；
/// * 拿不准时**列出候选番剧页**让用户点，还可以手打搜索词 / 粘 mikan 链接或 id；
/// * 落空 = **手动**「用其他源再搜一次」（不自动打聚合）；
/// * 三种空分开写；有结果时**复用搜索页那张结果表**（同样的勾选列、同样的动作），
///   额外加：每行的「已看过 / 在队列 / 已完成」标记、右键「这一组都入队（N 集）」、
///   每个字幕组旁边的「订阅」（和主页那页一致）；
/// * 旧的「按这个名字搜种子」按钮删掉，降级成这里的一个「在搜索页打开」小链接。
library;

import 'dart:async';
import 'dart:math' as math;

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

/// 正在找 / 正在取（两段式）时的占位 key。
const Key dsDetailSeedsLoadingKey = Key('library-detail-seeds-loading');

/// 整块没成（三种空 / 网络失败）时的 key。
const Key dsDetailSeedsFailedKey = Key('library-detail-seeds-failed');

/// 失败态那颗「重新搜一次」。
const Key dsDetailSeedsRetryKey = Key('library-detail-seeds-retry');

/// 失败态那颗「用其他源再搜一次」（手动降级）。
const Key dsDetailSeedsOtherSourcesKey = Key('library-detail-seeds-other-sources');

/// 「在搜索页打开」那颗小链接（旧按钮的降级形态）。
const Key dsDetailSeedsSearchPageKey = Key('library-detail-seeds-search-page');

/// 拿不准时的候选番剧页列表。
const Key dsDetailSeedsPickKey = Key('library-detail-seeds-pick');

/// 结果表。
const Key dsDetailSeedsTableKey = Key('library-detail-seeds-table');

/// 「显示更多」。
const Key dsDetailSeedsMoreKey = Key('library-detail-seeds-more');

/// 字幕组那一排（每个组旁边一颗「订阅」）。
const Key dsDetailSeedsGroupsKey = Key('library-detail-seeds-groups');

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
    _ensureSoon();
  }

  @override
  void dispose() {
    _word.dispose();
    _raw.dispose();
    super.dispose();
  }

  // ── 动作 ────────────────────────────────────────────────────────────────────

  Future<void> _play(SourceItemView item, LibrarySeedState s, String showTitle) async {
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
            mikanBangumiId: s.binding?.bangumiId,
          );
      final DsFailure? failure = ref.read(playbackProvider).failure;
      if (failure != null && mounted) showFailure(context, failure);
    } catch (error, stackTrace) {
      if (mounted) showFailure(context, describeFailure(error, stackTrace: stackTrace));
    } finally {
      if (mounted) setState(() => _busyItemId = null);
    }
  }

  /// 这一条属于哪一组（协作署名的条目两边都算，与筛选面板同一口径）。
  List<SourceItemView> _groupItems(SourceItemView item, LibrarySeedState s) {
    final Set<String> keys = groupKeysOf(item.group).toSet();
    if (keys.isEmpty) return <SourceItemView>[item];
    return <SourceItemView>[
      for (final SourceItemView other in s.episodes)
        if (groupKeysOf(other.group).any(keys.contains)) other,
    ];
  }

  /// 「这一组都入队（N 集）」：跳过已看过 / 已在队列 / 已完成的。
  Future<void> _enqueueGroup(
    SourceItemView item,
    LibrarySeedState s,
    String showTitle,
    Map<String, DateTime> watched,
    List<QueueJobView> jobs,
    List<EngineTorrentView> torrents,
  ) async {
    final List<SourceItemView> all =
        _groupItems(item, s).where(canBatchDownload).toList(growable: false);
    final Set<String> inQueue = <String>{for (final QueueJobView j in jobs) j.item.dedupeKey};
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
        '这一组 ${all.length} 集都看过了（或已在队列里），没有要下的',
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
      final String extra = skipped == 0 ? '' : '（另跳过 $skipped 集：已看过 / 已在队列 / 已完成）';
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
      if (mounted) showFailure(context, describeFailure(error, stackTrace: stackTrace));
    } finally {
      if (mounted) setState(() => _busyGroup = false);
    }
  }

  /// 行尾的状态标记：已看过 / 在队列 / 已完成（与「正在追」同一套判据）。
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
    final bool done = hash != null &&
        hash.isNotEmpty &&
        torrents.any(
          (EngineTorrentView t) =>
              t.infoHash.toLowerCase() == hash && (t.finished || t.progress >= 1),
        );
    return <Widget>[
      if (seen) _mark(Icons.check_box, '已看过', context.ds.success),
      if (job != null) _mark(Icons.downloading, job.state.label, context.ds.accent),
      if (done) _mark(Icons.check_circle, '已完成', context.ds.success),
    ];
  }

  Widget _mark(IconData icon, String tooltip, Color color) => Tooltip(
    message: tooltip,
    child: Padding(
      padding: const EdgeInsets.only(left: 4),
      child: Icon(icon, size: 14, color: color),
    ),
  );

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
    final List<EngineTorrentView> torrents = ref.watch(engineTorrentsSnapshotProvider);
    final String showTitle = (s.detail?.displayTitle ?? widget.subject.displayTitle).trim();

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
                  if (s.remaining > 0)
                    NeoButton(
                      key: dsDetailSeedsMoreKey,
                      label: '显示更多（还有 ${s.remaining} 条）',
                      icon: Icons.expand_more,
                      compact: true,
                      onPressed: ref.read(librarySeedProvider.notifier).showMore,
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
          tooltip: '重新搜一次（绕开 30 分钟缓存与记住的番剧页）',
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

  /// 抬头那行小字：说清"这批种子是从哪来的、用的是哪个词"。
  String _subtitle(LibrarySeedState s) => switch (s.phase) {
    LibrarySeedPhase.idle || LibrarySeedPhase.searching => '正在 mikan 找这一部…',
    LibrarySeedPhase.fetching => '正在取字幕组与剧集…',
    LibrarySeedPhase.needsPick => 'mikan 上有几个可能，挑一个',
    LibrarySeedPhase.failed => switch (s.problem) {
      LibrarySeedProblem.mikanNotFound => 'mikan 上没找到这一部',
      LibrarySeedProblem.noMagnet => '找到了番剧页，但里面没有可下的种子',
      LibrarySeedProblem.allSourcesEmpty => '其他源也没有',
      LibrarySeedProblem.badInput => '这串里没有番剧 id',
      LibrarySeedProblem.network => '这一轮没取回来',
      LibrarySeedProblem.none => '没找到',
    },
    LibrarySeedPhase.ready => <String>[
      if (s.fromAggregate) '来自其他源'
      else 'mikan 番剧页 · ${s.groupNames.length} 个字幕组',
      '共 ${s.episodes.length} 集',
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
        label: s.phase == LibrarySeedPhase.searching
            ? '正在 mikan 找这一部（第 1 步 / 共 2 步）…'
            : '正在取字幕组与剧集（第 2 步 / 共 2 步）…',
        compact: true,
      );
    }
    if (s.phase == LibrarySeedPhase.needsPick) {
      return Column(
        key: dsDetailSeedsPickKey,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            '这些页面里有一个是这一部，点了就用它（拿不准时我不替你猜）：',
            style: TextStyle(color: t.text3, fontSize: DsTypeScale.caption),
          ),
          const SizedBox(height: 6),
          for (final MikanSeedCandidate c in s.candidates)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      '${c.title}（mikan #${c.bangumiId}）',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: t.text, fontSize: DsTypeScale.secondary),
                    ),
                  ),
                  const SizedBox(width: 8),
                  NeoButton(
                    label: '用这一页',
                    compact: true,
                    onPressed: () => unawaited(
                      ref
                          .read(librarySeedProvider.notifier)
                          .pickCandidate(widget.subject, c),
                    ),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 4),
          Text(
            '都不对？展开下面的「改搜索词 / 粘链接」。',
            style: TextStyle(color: t.text3, fontSize: DsTypeScale.caption),
          ),
        ],
      );
    }
    if (s.phase == LibrarySeedPhase.failed) {
      return _failure(context, s);
    }
    return Column(
      key: dsDetailSeedsTableKey,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (s.fromAggregate)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: DsBanner(
              kind: DsBannerKind.info,
              text: '这些不是 mikan 番剧页给的（mikan 上没找到这一部），'
                  '是「${s.word ?? widget.subject.displayTitle}」在其他源上的搜索结果。',
            ),
          ),
        if (s.warning case final String warning)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: DsBanner(kind: DsBannerKind.warning, text: warning),
          ),
        if (s.detail case final BangumiDetailView detail) ...<Widget>[
          _groups(context, detail, showTitle, s),
          const SizedBox(height: 10),
        ],
        SearchResultsTable(
          items: s.shown,
          embedded: true,
          engineConnected: ref.watch(engineStatusProvider).isConnected,
          busyItemId: _busyItemId,
          sources: ref.watch(sourceOptionsProvider),
          onPlay: (SourceItemView item) => unawaited(_play(item, s, showTitle)),
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
            for (final SourceItemView item in s.shown) {
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
              '这一组都入队（${_groupItems(item, s).length} 集）',
          onGroupAction: (SourceItemView item) => unawaited(
            _enqueueGroup(item, s, showTitle, marks, jobs, torrents),
          ),
        ),
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
                          for (final SourceItemView item in s.shown)
                            if (_selected.contains(item.id)) item,
                        ];
                        if (picked.isEmpty) return;
                        setState(() => _busyGroup = true);
                        try {
                          final BatchDownloadResult result = await enqueueDownloads(
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

  /// 字幕组那一排：每个组一颗「订阅」（和主页那页一致）。
  Widget _groups(
    BuildContext context,
    BangumiDetailView detail,
    String showTitle,
    LibrarySeedState s,
  ) {
    final DsTokens t = context.ds;
    if (detail.groups.isEmpty) return const SizedBox.shrink();
    return Column(
      key: dsDetailSeedsGroupsKey,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          '字幕组（${detail.groups.length}）',
          style: TextStyle(
            color: t.text3,
            fontSize: DsTypeScale.caption,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 6),
        LayoutBuilder(
          builder: (BuildContext context, BoxConstraints c) {
            final double width = math.min(320, c.maxWidth);
            return Wrap(
              spacing: 12,
              runSpacing: 6,
              children: <Widget>[
                for (final BangumiGroupView group in detail.groups)
                  SizedBox(
                    width: width,
                    child: Row(
                      children: <Widget>[
                        Expanded(
                          child: Text(
                            group.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(color: t.text2, fontSize: DsTypeScale.secondary),
                          ),
                        ),
                        const SizedBox(width: 6),
                        GroupSubscribeButton(
                          bangumiId: detail.bangumiId,
                          showTitle: showTitle,
                          group: group,
                        ),
                      ],
                    ),
                  ),
              ],
            );
          },
        ),
      ],
    );
  }

  /// 三种空 + 网络失败（用户第四十五轮：**分开写**，各给对应动作）。
  Widget _failure(BuildContext context, LibrarySeedState s) {
    final DsTokens t = context.ds;
    final LibrarySeedController controller = ref.read(librarySeedProvider.notifier);
    final String word = s.word ?? widget.subject.displayTitle;
    final (String title, String message) = switch (s.problem) {
      LibrarySeedProblem.mikanNotFound => (
        'mikan 上没找到「$word」',
        'mikan 的搜索是整串匹配（多一个字就 0 行），冷门番与老番经常没有番剧页'
            '（实测成功率 62%）。可以展开下面改个搜索词、粘一个 mikan 链接，'
            '或者去其他源搜一次。',
      ),
      LibrarySeedProblem.noMagnet => (
        '番剧页拿到了，但一集可下的种子都没有',
        'mikan 那一页给了 ${s.episodes.length} 集，但都没有磁力/直链 —— '
            '可能是刚开播还没放源，或者站点那边临时缺。',
      ),
      LibrarySeedProblem.allSourcesEmpty => (
        '其他源也没有这一部',
        '已经在勾选的源上都搜过「$word」，一条都没有 —— 冷门番常见，'
            '不是搜索坏了。换个词（试试日文原名/罗马音）再看看。',
      ),
      LibrarySeedProblem.badInput => (
        '这串里没有 mikan 番剧 id',
        '粘 `https://mikanani.me/Home/Bangumi/2833` 这样的地址，或者直接写 `2833`。',
      ),
      LibrarySeedProblem.network || LibrarySeedProblem.none => (
        '这一步没取回来',
        s.failure?.hint ?? s.failure?.message ?? '网络或源站那边的问题，重试一下。',
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
        if (s.bindingStale)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: DsBanner(
              kind: DsBannerKind.warning,
              text: '记住的那个番剧页取不回来了（可能被删或改名），已经自动重搜过一次。',
            ),
          ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 6,
          children: <Widget>[
            NeoButton(
              label: '重新搜一次',
              icon: Icons.refresh,
              kind: NeoButtonKind.primary,
              compact: true,
              onPressed: () => unawaited(controller.retry()),
            ),
            NeoButton(
              key: dsDetailSeedsOtherSourcesKey,
              label: '用其他源再搜一次',
              icon: Icons.travel_explore,
              compact: true,
              onPressed: () => unawaited(controller.searchEverywhere(widget.subject)),
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
    final LibrarySeedController controller = ref.read(librarySeedProvider.notifier);
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
                  hintText: '粘 mikan 番剧页地址或 id（例如 2833）',
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
