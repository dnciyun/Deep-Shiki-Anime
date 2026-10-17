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
///   一行行组抬头，点哪一段抬头才画那一段的条目：一屏十几个组名比一屏几行番名好挑，
///   而且「这一组都入队」在收起状态下照样点得到；
/// * 展开之后先露 [kSeedGroupVisibleStep] 条，其余藏在「本组还有 N 条」后面；
/// * 段本身先露 [kSeedVisibleGroups] 个，其余的**再点一次多露一档** [kSeedGroupsStep] 个；
/// * **组名列表的宽窄 = 两颗纯图标按钮**（第四十八轮·补四，用户第三版原话「去掉展开这些文字，
///   多加一个收起按钮，只需要矢量图」）：结果下面那排只有 `unfold_more`（多露一档组名）与
///   `unfold_less`（收起字幕组，退回 [kSeedVisibleGroups] 个）—— **中文只留在悬停提示里，
///   一个文字标签都不画**；两颗**同时都在**（不是一颗按钮变来变去），所以"只要比首屏宽，
///   收起就是亮的"，不会再出现「必须要展开完才能收起」；
///   ⚠️ 它们**不碰每段自己的开合** —— 用户第二版原话：「我说的张开字幕组列表，不是把字幕组也
///   展开了」。哪一段要展开，是用户点**那一段抬头**的事；
/// * 展开那颗是**一次一档**（第四十八轮·补五，用户原话「展开一些加回来」）：一次
///   [kSeedGroupsStep] 个，不再把五十多段一次铺开（那版被退回）；还剩几个写在悬停提示里；
/// * 这一排跟着结果走，画在结果**下面**（第四十八轮·补四：「这些位置也不应该在上面」——
///   控制行挪到上面那一版也被退回了）；
/// * 每一段展开后的末尾另有一颗「收起这一组」：翻完 80 行想收起来时，不用再滚回抬头去点；
/// * **别的版本收在底部**（第四十八轮·补六，用户「详细页会搜到其他版本的，比如第二季 剧场版
///   番外等等」）：本作按字幕组分段照旧，判成"另一版"的条目（`SeedOtherBlock`）默认折在
///   结果下面那行「其他版本（N 条）」里，点开按版本分小节（第三季 / 剧场版 / 更早的版本…），
///   小节里还是按字幕组来 —— **判错也不丢**，最坏只是把一条本作挪进了那一区；
/// * **分页只给「合集」一页**（第四十八轮·补七 / 补八，补八用户原话「只给合集最分页，
///   其他的不要」）：**本作里的整季批量种**（`isSeedBatch`）从本作里切出去，在组名列表
///   **上面**占一页「合集」——本作的条数 / 「这一组都入队」就不会被几条全集顶长；别的版本
///   **不做页**，仍旧收在底部那行折区里。分页条只在真有合集时才画（只剩本作一页时不出）；
/// * **字幕语言过滤**（第四十八轮·补九，用户「加入按钮，点一次只显示简体，再点一次只显示
///   繁体，再点一次恢复」）：结果下面那排多一颗 `语言：全部 / 简体 / 繁体` 按钮，点一下
///   切一档、循环。判据是标题里的语言标记（`[简]`/`简体`/`GB`/`CHS`、`[繁]`/`繁体`/`BIG5`/
///   `CHT`、两边都带的 `简繁`），**没标语言的（生肉 / BDMV / 只写"双语"）在简 / 繁两档下
///   不显示**；过滤只裁显示的行，不重打网络、也不改一条种子属于哪一版（见
///   `domain/seed_language.dart`）；
/// * mikan 番剧页降级成**手动**口（「改搜索词 / 粘链接」里粘地址或 id）—— 它给的东西更完整
///   （整部剧集表 + 每组自己的 RSS），只是不该再当主力，见 `domain/library_seed.dart` 的库注释。
///
/// ## 第四十九轮：这块也挂到「正在追」的订阅详细页（`ui/following_detail.dart`）
///
/// 用户原话：「优化下订阅，详细页订阅的也带有种子」。这一块**一个像素都没为那一页改**——
/// 变化只有两处「数据口径」的构造参数：
/// * [mikanBangumiId]：「正在追」知道这一部的 mikan 番剧 id，传进来之后「已看过」与观看记录
///   按 `mikan:<id>` 归组 —— 订阅里打过的勾在种子块里也显示成「已看过」，在种子块里播的集
///   也记到同一条观看记录上（动漫库详细页没有这个 id，留 null 就照旧按番名归组）；
/// * [coverReferer]：播放时封面要带的 Referer（Bangumi 图床要 `https://bgm.tv/`，
///   主页来的 mikan 封面不需要）—— 留 null 就是原来的默认口径。
///
/// 主体（搜什么词 / 怎么判版本 / 状态键）由 `domain/following_seed.dart` 从追番记录造一条
/// **最小** Bangumi 条目：不联网、不猜，缺 `date` / `eps` 只是让版本判定少一条时间窗。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/aggregate.dart';
import '../../domain/bangumi.dart';
import '../../domain/batch_download.dart';
import '../../domain/episodes.dart';
import '../../domain/error_text.dart';
import '../../domain/following_subscription.dart';
import '../../domain/library_seed.dart';
import '../../domain/models.dart';
import '../../domain/seed_language.dart';
import '../../domain/seed_version.dart' show SeedOtherBlock, kSeedBatchLabel;
import '../../domain/subtitle_groups.dart';
import '../../state/playback.dart';
import '../../state/providers.dart';
import '../../theme/tokens.dart';
import '../widgets/feedback.dart';
import '../widgets/group_subscribe.dart';
import '../widgets/neo.dart';
import '../widgets/search_sections.dart';
import '../widgets/state_views.dart';
import 'hues.dart';

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

/// 「多露一档字幕组」那颗图标（`unfold_more`）。第四十八轮·补四：纯图标，中文只在悬停提示里；
/// 补五（用户「展开一些加回来」）：一次只多露 [kSeedGroupsStep] 个，不再一次全露。
const Key dsDetailSeedsExpandAllKey = Key('library-detail-seeds-expand-all');

/// 「收起字幕组」那颗图标（`unfold_less`）。第四十八轮·补四：与展开那颗**同时都在**。
const Key dsDetailSeedsCollapseKey = Key('library-detail-seeds-collapse');

/// 字幕组那一段（每段一个，key 带组名 —— 用例据此定位某一段）。
Key dsDetailSeedsGroupKey(String key) => ValueKey<String>('seed-group-$key');

/// 那一段的**抬头**（点它 = 展开 / 收起这一段）。
Key dsDetailSeedsGroupToggleKey(String key) =>
    ValueKey<String>('seed-group-toggle-$key');

/// 某一段展开后末尾那颗「收起这一组」（第四十八轮·补四）。
Key dsDetailSeedsGroupCollapseKey(String key) =>
    ValueKey<String>('seed-group-collapse-$key');

/// 某一段的「本组还有 N 条」。
Key dsDetailSeedsGroupMoreKey(String key) =>
    ValueKey<String>('seed-group-more-$key');

/// 「其他版本（N 条）」那一行（第四十八轮·补六；点它 = 展开 / 收起别的版本）。
const Key dsDetailSeedsOtherKey = Key('library-detail-seeds-other');

/// 「其他版本（N 条）」那一行本身（点它 = 展开 / 收起）。
const Key dsDetailSeedsOtherToggleKey = Key('library-detail-seeds-other-toggle');

/// 其他版本里的版本小节（例如「第三季」那一块）。
Key dsDetailSeedsOtherBlockKey(String version) =>
    ValueKey<String>('seed-other-block-$version');

/// 「本作」那一页的页名（分页条第一页；界面 + 用例共用）。
const String kSeedCurrentLabel = '本作';

/// 分页条上的一页（第四十八轮·补七 / 补八）：一组字号组段 + 条目。
///
/// 补八（用户「只给合集最分页，其他的不要」）之后只有两页：`本作` 与 `合集`。
@immutable
class _SeedCategory {
  const _SeedCategory({
    required this.label,
    required this.groups,
    required this.items,
  });

  final String label;
  final List<SeedGroup> groups;
  final List<SourceItemView> items;

  int get count => items.length;

  bool get isCurrent => label == kSeedCurrentLabel;

  String get tooltip => isCurrent
      ? '本作这一版（${groups.length} 个字幕组 · $count 条）'
      : '$label（${groups.length} 个字幕组 · $count 条）';
}

/// 分页条上一页的按钮（点它 = 切到那一页；第四十八轮·补七）。
Key dsDetailSeedsCategoryKey(String label) =>
    ValueKey<String>('seed-category-$label');

/// 分页（`合集` 页）或其他版本折区里某一段字幕组的抬头（[key] = 归一化组名）。
///
/// `version` 传页名 / 版本标签（`合集` / `第三季` / `更早的版本`…）—— 同一家组在不同区
/// 各有一段。
Key dsDetailSeedsOtherGroupKey(String version, String key) =>
    ValueKey<String>('seed-other-group-$version-$key');

/// 分页（`合集` 页）或其他版本折区里某一段的抬头开关。
Key dsDetailSeedsOtherGroupToggleKey(String version, String key) =>
    ValueKey<String>('seed-other-toggle-$version-$key');

/// 分页（`合集` 页）或其他版本折区里某一段末尾的「本组还有 N 条」/「收起这一组」。
Key dsDetailSeedsOtherGroupMoreKey(String version, String key) =>
    ValueKey<String>('seed-other-more-$version-$key');
Key dsDetailSeedsOtherGroupCollapseKey(String version, String key) =>
    ValueKey<String>('seed-other-collapse-$version-$key');

/// 「语言：全部 / 简体 / 繁体」那颗过滤按钮（第四十八轮·补九；点一下切一档）。
///
/// 用户原话：「加入按钮，点一次只显示简体，再点一次只显示繁体，再点一次恢复」。
const Key dsDetailSeedsLanguageKey = Key('library-detail-seeds-language');

/// 语言过滤把这一页裁得一条不剩时那句提示（补九：说清"为什么空"与"去哪儿恢复"）。
const Key dsDetailSeedsLanguageEmptyKey = Key(
  'library-detail-seeds-language-empty',
);

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
    this.mikanBangumiId,
    this.coverReferer,
  });

  final BangumiSubject subject;

  /// 「在搜索页打开」要干什么（由页面给：它已经 import 了 `openRecommendSearch`）。
  final VoidCallback onOpenSearchPage;

  /// 这一部在 mikan 上的番剧 id（第四十九轮）：有它「已看过」与观看记录就按 `mikan:<id>`
  /// 归组，和订阅里打过的勾是**同一套键**。
  ///
  /// 「正在追」点开层知道它（订阅本身就是按这个 id 建的）；动漫库详细页不知道，留 null。
  final String? mikanBangumiId;

  /// 播放时封面带的 Referer（第四十九轮）：Bangumi 图床要 `https://bgm.tv/`，
  /// mikan 封面不需要 —— 留 null 就是原来的 `https://bgm.tv/`。
  final String? coverReferer;

  @override
  ConsumerState<LibrarySeedBlock> createState() => _LibrarySeedBlockState();
}

class _LibrarySeedBlockState extends ConsumerState<LibrarySeedBlock> {
  final Set<String> _selected = <String>{};

  /// 哪几段**展开着**（第四十八轮·补：默认**全收起** —— 进页面先看组名与条数，
  /// 点哪一段看哪一段）。纯界面状态，不落盘、换条目就清。
  ///
  /// 键是**段的 id**：本作区就是归一化组名；其他版本区是 `版本标签\u0000组名`
  /// （同一家字幕组在两区都有，不能撞）。
  final Set<String> _openGroups = <String>{};

  /// 哪几段把「本组还有 N 条」也点开了（= 这一段全露）。收起那一段时一起丢掉，
  /// 再展开又回到"先露 12 条"。（组名列表那两颗图标**不**碰它：它们只管组名列表。）
  final Set<String> _fullGroups = <String>{};

  final TextEditingController _word = TextEditingController();
  final TextEditingController _raw = TextEditingController();
  bool _tools = false;

  /// 分页条上当前选中的页名（null = 本作；第四十八轮·补七）。
  ///
  /// 存**页名**而不是下标：重新搜一次之后页会变（比如合集没了），存下标会指到别的页上。
  String? _categoryLabel;

  /// 「其他版本（N 条）」那一行点开了没有（第四十八轮·补六；默认收起）。
  bool _showOther = false;
  bool _busyGroup = false;
  String? _busyItemId;

  /// 这一页知道的 mikan 番剧 id（第四十九轮；去空白，没有就是 null）。
  String? get _mikanId {
    final String id = (widget.mikanBangumiId ?? '').trim();
    return id.isEmpty ? null : id;
  }

  /// 「已看过」与观看记录按哪个番剧 id 归组：手动锚点 > 这一页给的 mikan id > 番名。
  ///
  /// 最后那一级是既有降级（`watch_history.dart` 对没有 id 的条目按番名归组）——
  /// 动漫库详细页一直走的就是它，第四十九轮一个字没动。
  String _watchBangumiId(LibrarySeedState s) =>
      s.binding?.bangumiId ?? _mikanId ?? widget.subject.displayTitle;

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
    _categoryLabel = null;
    _showOther = false;
    _ensureSoon();
  }

  @override
  void dispose() {
    _word.dispose();
    _raw.dispose();
    super.dispose();
  }

  // ── 动作 ────────────────────────────────────────────────────────────────────

  /// [playlist] 是这一行所在的**那一池**（本作区 = 本作条目；其他版本区 = 那一个版本的条目）。
  /// ⚠️ 必须分开：播完一集「下一集」不该跳到另一季去（第四十八轮·补六）。
  Future<void> _play(
    SourceItemView item,
    LibrarySeedState s,
    String showTitle, {
    List<SourceItemView>? playlist,
  }) async {
    final List<SourceItemView> queue = playlist ?? s.episodes;
    setState(() => _busyItemId = item.id);
    try {
      await ref
          .read(playbackProvider.notifier)
          .playItem(
            item,
            upNext: followingEpisodes(queue, item),
            playlist: queue,
            showTitle: showTitle,
            coverUrl: widget.subject.coverUrl,
            coverReferer: widget.coverReferer ?? 'https://bgm.tv/',
            // 手动锚过番剧页时把它带上（观看记录按 `mikan:<id>` 归组、缺链还能回那一页补）；
            // 没有锚点也没关系 —— `watch_history.dart` 会退回按番名归组。
            // 第四十九轮：「正在追」点开层另外知道 mikan 番剧 id，也带上（见 [_mikanId]）。
            mikanBangumiId: s.binding?.bangumiId ?? _mikanId,
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
      bangumiId: _watchBangumiId(s),
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
        bangumiId: _watchBangumiId(s),
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
    // 分页（第四十八轮·补七 / 补八）：只给「合集」单独一页 —— 本作 / 合集，只列有内容的。
    // 补八用户原话「只给合集最分页，其他的不要」：别的版本不做页，回到下面那行折区。
    final List<_SeedCategory> categories = _categories(s);
    final int categoryAt = _categoryIndex(categories);
    final _SeedCategory? category =
        categories.isEmpty ? null : categories[categoryAt];
    final bool currentPage = category == null || category.isCurrent;

    return Container(
      key: dsDetailSeedsKey,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
      decoration: t.cardDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          NeoSectionHeader(
            title: '种子',
            // 第五十二轮（用户 2026-10-17「整个项目太素」）：卡头用**动漫库身份色**（紫）。
            // 这一块同时挂在动漫库详细页（第四十五轮）与「正在追」订阅详细页（第四十九轮），
            // 本轮统一认「种子块 = 动漫库的一部分」这个身份，不给它再分一套页面色。
            hue: DsHue.violet,
            subtitle: _subtitle(s, category),
            padding: const EdgeInsets.only(bottom: 10),
            trailing: _headerActions(s),
          ),
          _body(
            context,
            s,
            category,
            categories,
            categoryAt,
            showTitle,
            marks,
            jobs,
            torrents,
          ),
          if (_tools) ...<Widget>[const SizedBox(height: 10), _toolsRow(s)],
          if (s.phase == LibrarySeedPhase.ready) ...<Widget>[
            const SizedBox(height: 8),
            // ⚠️ 这一排跟着结果走，画在结果**下面** —— 第四十八轮·补四用户退回过
            // "挪到上面"那一版：「这些位置也不应该在上面」。
            // （分页条在**组名列表上面**，那是补七用户点名要的；这一排没动。）
            Align(
              alignment: Alignment.centerLeft,
              child: _controls(s, currentPage: currentPage),
            ),
          ],
          // 别的版本（第四十八轮·补六；补八起这里是唯一入口）：默认折一行，点开才按版本
          // 分小节 —— 判错的条目也在这区里，一条不删（见 `domain/seed_version.dart` 头部）。
          // 补七那一版把它们做成了分页上的一页页，补八用户退回：「只给合集最分页，其他的不要」。
          if (s.phase == LibrarySeedPhase.ready &&
              s.otherVersions.isNotEmpty) ...<Widget>[
            const SizedBox(height: 4),
            _otherVersions(s, showTitle, marks, jobs, torrents),
          ],
        ],
      ),
    );
  }

  /// 结果下面那一排：多露一档字幕组（图标）/ 收起字幕组（图标）/ 语言过滤 / 改搜索词·粘链接。
  ///
  /// 第四十八轮·补四第三版（用户原话「去掉展开这些文字，多加一个收起按钮，只需要矢量图」）：
  /// 组名列表这一对**只有矢量图标**，中文只留在悬停提示里；而且两颗**同时都在**——
  /// 不再是一颗按钮的标签变来变去，所以"比首屏宽"这件事一眼就能从"收起那颗亮着"看出来
  /// （用户上一版那句「必须要展开完才能收起」就是一颗按钮变标签导致的）。
  ///
  /// 第四十八轮·补五（用户原话「展开一些加回来」）：展开那颗回到**一次一档**
  /// （[kSeedGroupsStep] 个 —— 就是更早那颗文字按钮「显示更多字幕组」的量），
  /// 不再一次把几十段全铺出来；还剩几个、这一次会多露几个，都写在悬停提示里。
  ///
  /// ⚠️ 它们只动**段窗口**（露几个组名），不碰每段自己的开合。
  ///
  /// 补七起：这两颗**只在「本作」那一页**出现 —— 「合集」页是那一版的全部组名
  /// （没有"首屏 4 段"这回事），画出来反而是两颗灰的。
  Widget _controls(LibrarySeedState s, {required bool currentPage}) {
    final LibrarySeedController controller = ref.read(
      librarySeedProvider.notifier,
    );
    // 段数没超过首屏那几个：没有"宽窄"可调，两颗都不画（画了也是两颗灰的）。
    final bool toggleable =
        currentPage && s.groups.length > kSeedVisibleGroups;
    final int remaining = s.remainingGroups;
    final bool wide = s.visibleGroups > kSeedVisibleGroups;
    // 展开那颗的悬停提示：这一下会多露几个 + 还剩几个（最后一档就是"剩下这些"）。
    final String expandTip = remaining <= 0
        ? '字幕组已经全露出来了'
        : remaining <= kSeedGroupsStep
        ? '展开剩下的 $remaining 个字幕组'
        : '展开更多字幕组（一次 $kSeedGroupsStep 个，还有 $remaining 个）';
    return Wrap(
      spacing: 8,
      runSpacing: 6,
      children: <Widget>[
        if (toggleable) ...<Widget>[
          NeoIconButton(
            key: dsDetailSeedsExpandAllKey,
            icon: Icons.unfold_more,
            tooltip: expandTip,
            onPressed: remaining > 0 ? controller.showMoreGroups : null,
          ),
          NeoIconButton(
            key: dsDetailSeedsCollapseKey,
            icon: Icons.unfold_less,
            tooltip: wide
                ? '收起字幕组（回到首屏那 $kSeedVisibleGroups 个）'
                : '已经是首屏那 $kSeedVisibleGroups 个组名',
            onPressed: wide ? controller.collapseGroups : null,
          ),
        ],
        // 字幕语言过滤（补九）：点一下 全部 → 简体 → 繁体 → 全部。
        // 它跟组名列表那两颗图标一样画在**结果下面**，而且每一页都在（过滤是全局的）。
        NeoButton(
          key: dsDetailSeedsLanguageKey,
          label: '语言：${seedLanguageLabel(s.language)}',
          icon: Icons.translate,
          compact: true,
          tooltip: _languageTooltip(s.language),
          onPressed: () {
            // 过滤一换，屏幕上那些勾可能已经看不到了 —— 清掉，免得"下载了没看见的"。
            setState(_selected.clear);
            ref
                .read(librarySeedProvider.notifier)
                .setSeedLanguage(nextSeedLanguage(s.language));
          },
        ),
        NeoButton(
          label: _tools ? '收起工具' : '改搜索词 / 粘链接',
          icon: Icons.tune,
          compact: true,
          onPressed: () => setState(() => _tools = !_tools),
        ),
      ],
    );
  }

  /// 语言按钮的悬停提示：三种状态各说清"这一下会切到哪一档"。
  static String _languageTooltip(SeedLanguage language) => switch (language) {
    SeedLanguage.all => '字幕语言：全部（点一下只看简体，再点只看繁体，再点恢复全部）',
    SeedLanguage.simplified => '只看标了简体字幕的种子（再点只看繁体，再点恢复全部）',
    SeedLanguage.traditional => '只看标了繁体字幕的种子（再点恢复全部）',
  };

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

  /// 抬头那行小字：说清"这一页是哪一版、几个组、几条、用的是哪个词"。
  ///
  /// 分页（补七 / 补八）之后要跟着**当前页**走：切到「合集」时这里的组数与条数必须是那一页的，
  /// 否则用户会拿本作的数字去对另一页。
  String _subtitle(LibrarySeedState s, _SeedCategory? category) =>
      switch (s.phase) {
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
          if (category != null && !category.isCurrent) category.label,
          '${category?.groups.length ?? s.groups.length} 个字幕组',
          '共 ${category?.count ?? s.episodes.length} 条',
          if (s.word case final String word) '用的是「$word」',
        ].join(' · '),
      };

  Widget _body(
    BuildContext context,
    LibrarySeedState s,
    _SeedCategory? category,
    List<_SeedCategory> categories,
    int categoryAt,
    String showTitle,
    Map<String, DateTime> marks,
    List<QueueJobView> jobs,
    List<EngineTorrentView> torrents,
  ) {
    final DsTokens t = context.ds;
    if (s.loading) {
      return DsLoading(
        key: dsDetailSeedsLoadingKey,
        // 第五十二轮：加载态跟卡头同色（动漫库身份色）。
        hue: DsHue.violet,
        label: s.phase == LibrarySeedPhase.fetching
            ? '正在取这张 mikan 番剧页…'
            : '正在各站搜这一部（mikan、动漫花园、ACGNX…）…',
        compact: true,
      );
    }
    if (s.phase == LibrarySeedPhase.failed) return _failure(context, s);

    final _SeedCategory page = category ??
        _SeedCategory(label: kSeedCurrentLabel, groups: s.groups, items: s.episodes);
    final bool currentPage = page.isCurrent;
    final List<SeedGroup> shown = currentPage ? s.shownGroups : page.groups;
    // 段 id：本作页就用归一化组名；「合集」页带页名前缀（同一家组在两页各有一段）。
    String? openKeyOf(SeedGroup group) =>
        currentPage ? null : _categoryOpenKey(page.label, group.key);
    String effectiveKey(SeedGroup group) => openKeyOf(group) ?? group.key;
    // 「全选本页」说的是**现在真看得见**的那些条目：收起着的段一行都没画，
    // 把它算进去就会变成"勾选了一批看不见的东西"（第四十五轮那条纪律的延续）。
    final List<SourceItemView> scope = <SourceItemView>[
      for (final SeedGroup group in shown)
        if (_openGroups.contains(effectiveKey(group)))
          ..._visibleItems(group, openKey: openKeyOf(group)),
    ];
    // 表头（番名 / 大小 / 状态 / 操作 + 全选）只在**第一张展开出来的**表上画一次：
    // 默认全都收着时一张表都没有，也就不该有一条孤零零的表头。
    final int headerAt = shown.indexWhere(
      (SeedGroup g) => _openGroups.contains(effectiveKey(g)),
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
        // 分页条：**组名列表上面**（第四十八轮·补七用户原话「在字幕组上面加入分页」）。
        if (categories.length > 1)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: _categoryTabs(categories, categoryAt),
          ),
        // 语言过滤把这一页裁空了（补九）：说清"为什么空"与"去哪儿恢复"。
        if (page.count == 0 && s.language != SeedLanguage.all)
          Padding(
            key: dsDetailSeedsLanguageEmptyKey,
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              '这一页没有标「${seedLanguageLabel(s.language)}」字幕的种子 —— '
              '点下面的「语言：${seedLanguageLabel(s.language)}」按钮恢复全部',
              style: TextStyle(
                color: t.text3,
                fontSize: DsTypeScale.caption,
                height: 1.6,
              ),
            ),
          ),
        for (int i = 0; i < shown.length; i++) ...<Widget>[
          _groupHeader(
            context,
            s,
            shown[i],
            showTitle,
            marks,
            jobs,
            torrents,
            openKey: openKeyOf(shown[i]),
            versionLabel: currentPage ? null : page.label,
          ),
          if (_openGroups.contains(effectiveKey(shown[i]))) ...<Widget>[
            _groupTable(
              context,
              s,
              shown[i],
              showTitle,
              marks,
              jobs,
              torrents,
              showHeader: i == headerAt,
              scope: scope,
              playlist: currentPage ? s.episodes : page.items,
              openKey: openKeyOf(shown[i]),
            ),
            _groupFoot(
              shown[i],
              t,
              openKey: openKeyOf(shown[i]),
              versionLabel: currentPage ? null : page.label,
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
                        // ⚠️ 用**整池**找勾中的条目：勾选可以发生在任何一页（合集 / 别的版本），
                        // 只扫 `episodes`（本作单集）会点了没反应（第四十八轮·补六/补七）。
                        final List<SourceItemView> picked = <SourceItemView>[
                          for (final SourceItemView item in s.allItems)
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

  /// 一段展开后的那张表（本作区与「其他版本」区共用）。
  ///
  /// 表头（番名 / 大小 / 状态 / 操作 + 全选）只在**最上面那张**上画一次 —— 列宽一样，
  /// 每段都来一行会把版面切碎。
  Widget _groupTable(
    BuildContext context,
    LibrarySeedState s,
    SeedGroup group,
    String showTitle,
    Map<String, DateTime> marks,
    List<QueueJobView> jobs,
    List<EngineTorrentView> torrents, {
    required bool showHeader,
    required List<SourceItemView> scope,
    required List<SourceItemView> playlist,
    String? openKey,
  }) {
    return SearchResultsTable(
      items: _visibleItems(group, openKey: openKey),
      embedded: true,
      showHeader: showHeader,
      selectAllScope: scope,
      engineConnected: ref.watch(engineStatusProvider).isConnected,
      busyItemId: _busyItemId,
      sources: ref.watch(sourceOptionsProvider),
      onPlay: (SourceItemView item) =>
          unawaited(_play(item, s, showTitle, playlist: playlist)),
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
          '这一组都入队（${group.count} 条）',
      onGroupAction: (SourceItemView item) => unawaited(
        _enqueueGroup(group.items, s, showTitle, marks, jobs, torrents),
      ),
    );
  }

  /// 这一段现在该画几条（收起着的段一条都不画；展开了先露 [kSeedGroupVisibleStep] 条）。
  ///
  /// [openKey]：同一家字幕组可能在「本作」「合集」各出现一次，段 id 要能区分
  /// （见 [_categoryOpenKey]）。
  List<SourceItemView> _visibleItems(SeedGroup group, {String? openKey}) {
    final String key = openKey ?? group.key;
    if (_fullGroups.contains(key) || group.count <= kSeedGroupVisibleStep) {
      return group.items;
    }
    return group.items.sublist(0, kSeedGroupVisibleStep);
  }

  /// 一段展开后末尾那行小链接：段内还剩几条可放 + 「收起这一组」。
  ///
  /// 为什么末尾也要一颗"收起"（第四十八轮·补四）：一段 80 行，看完想收起来时不该再滚回
  /// 抬头去点那颗小箭头 —— 用户的原话是「只有展开没有收起」（抬头那颗箭头的"收起"只写在
  /// 悬停提示里，看不出也够不着）。
  Widget _groupFoot(
    SeedGroup group,
    DsTokens t, {
    String? openKey,
    String? versionLabel,
  }) {
    final String key = openKey ?? group.key;
    final int hidden = group.count - _visibleItems(group, openKey: openKey).length;
    Widget link(Key key, String label, VoidCallback onPressed) => TextButton(
      key: key,
      style: TextButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 10),
        minimumSize: const Size(0, 26),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      onPressed: onPressed,
      child: Text(
        label,
        style: TextStyle(color: t.accent, fontSize: DsTypeScale.caption),
      ),
    );
    return Padding(
      padding: const EdgeInsets.only(top: 2, bottom: 4),
      child: Row(
        children: <Widget>[
          if (hidden > 0)
            link(
              versionLabel == null
                  ? dsDetailSeedsGroupMoreKey(group.key)
                  : dsDetailSeedsOtherGroupMoreKey(versionLabel, group.key),
              '本组还有 $hidden 条',
              () => setState(() => _fullGroups.add(key)),
            ),
          link(
            versionLabel == null
                ? dsDetailSeedsGroupCollapseKey(group.key)
                : dsDetailSeedsOtherGroupCollapseKey(versionLabel, group.key),
            '收起这一组',
            () => _toggleGroup(key),
          ),
        ],
      ),
    );
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
  ///
  /// [openKey] / [versionLabel] 只在「其他版本」区给：同一家字幕组在两区都会出现，
  /// 段的 id 与 key 都要带版本前缀（第四十八轮·补六）。
  Widget _groupHeader(
    BuildContext context,
    LibrarySeedState s,
    SeedGroup group,
    String showTitle,
    Map<String, DateTime> watched,
    List<QueueJobView> jobs,
    List<EngineTorrentView> torrents, {
    String? openKey,
    String? versionLabel,
  }) {
    final DsTokens t = context.ds;
    // 源表 = 「源」面板同一份真相：徽标显示的是人看的名字，不是 mikan / dmhy-batch 这种内部 id。
    final List<SourceOption> sources = ref.watch(sourceOptionsProvider);
    final BangumiGroupView? detailGroup = _detailGroupOf(s, group);
    final String key = openKey ?? group.key;
    final bool open = _openGroups.contains(key);
    // 第五十二轮（用户 2026-10-17「整个项目太素」）：**颜色 = 信息编码**。
    // 这一段（一个字幕组）的种子主要来自哪个站，抬头就用那个源的色相（3px 竖条 +
    // 源名徽标 + 条数着色）；同一个源在搜索页结果行里也是这个颜色。
    //
    // ⚠️ 取的是「这一段条目里出现最多的 sourceId」而不是"每源一行"：种子块是按
    // **字幕组**分段的（用户第四十八轮定的形态），跨站同名条目已经合并成一条，
    // 数据层也不给每源结果 —— 硬造一个每源计数会把合并/相关度筛掉的条目算错，
    // 反而可能又报一次假的「源没回来」（第五十一轮刚修过）。各源的真实条数放在
    // 徽标的悬停提示里，用户想看明细时能看到。
    final Map<String, int> sourceCounts = <String, int>{};
    for (final SourceItemView item in group.items) {
      sourceCounts[item.sourceId] = (sourceCounts[item.sourceId] ?? 0) + 1;
    }
    final List<String> sourceIds = sourceCounts.keys.toList()
      ..sort((String a, String b) {
        final int byCount = sourceCounts[b]!.compareTo(sourceCounts[a]!);
        return byCount != 0 ? byCount : a.compareTo(b);
      });
    final String mainSource = sourceIds.isEmpty ? '' : sourceIds.first;
    final DsHue sourceHue = hueOfSource(mainSource);
    final String sourceName = sourceIds.isEmpty ? '未知源' : sourceLabelFor(mainSource, sources);
    final String sourceTip = sourceIds.isEmpty
        ? '这一段的条目没有来源信息'
        : '这一段的种子来自：${sourceIds.map((String id) => '${sourceLabelFor(id, sources)} ${sourceCounts[id]} 条').join(' · ')}';
    return Padding(
      key: versionLabel == null
          ? dsDetailSeedsGroupKey(group.key)
          : dsDetailSeedsOtherGroupKey(versionLabel, group.key),
      padding: const EdgeInsets.only(top: 10, bottom: 6),
      child: Row(
        children: <Widget>[
          Expanded(
            child: InkWell(
              key: versionLabel == null
                  ? dsDetailSeedsGroupToggleKey(group.key)
                  : dsDetailSeedsOtherGroupToggleKey(versionLabel, group.key),
              onTap: () => _toggleGroup(key),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  children: <Widget>[
                    // 源色竖条：这一段的抬头先告诉用户"种子主要来自哪个站"。
                    Container(
                      width: 3,
                      height: 14,
                      decoration: BoxDecoration(
                        color: t.hueFill(sourceHue),
                        borderRadius: BorderRadius.circular(t.radiusPill),
                      ),
                    ),
                    const SizedBox(width: 6),
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
                      // 组名保持原样（"组名（N 条）"是一整句），只把**条数**染成源色：
                      // 数量是这一段"有没有货"的关键数字，颜色与左边竖条同源。
                      child: Text.rich(
                        TextSpan(
                          text: '${group.label}（',
                          children: <InlineSpan>[
                            TextSpan(
                              text: '${group.count}',
                              style: TextStyle(color: t.hueInk(sourceHue)),
                            ),
                            const TextSpan(text: ' 条）'),
                          ],
                        ),
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
          const SizedBox(width: 6),
          // 源名徽标：与左边竖条同色，悬停提示里列出这一段各源的真实条数。
          NeoPill(label: sourceName, hue: sourceHue, tooltip: sourceTip),
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

  /// 其他版本折区里某一段的 id：`版本标签\u0000归一化组名`。
  ///
  /// 同一家字幕组（`桜都`）在本作区与「第三季」区各有一段，两个 Set 不能撞。
  static String _otherKey(String version, String groupKey) =>
      '$version\u0000$groupKey';

  /// 结果下面那行「其他版本（N 条）」+ 展开后的版本小节（第四十八轮·补六 / 补八）。
  ///
  /// 补八（用户「只给合集最分页，其他的不要」）把补七的版本分页撤了，这里是别的版本
  /// **唯一**的入口。为什么默认收起：主列表要干净（用户要的是"打开就看到本作"）；但被判成
  /// "别的版本"的条目**一条都不能丢** —— 判据是标题里的版本标记 + 放送时间窗，必然会有判错
  /// 的时候（见 `domain/seed_version.dart` 头部），折在这里用户随时翻得到、还能直接入队。
  Widget _otherVersions(
    LibrarySeedState s,
    String showTitle,
    Map<String, DateTime> marks,
    List<QueueJobView> jobs,
    List<EngineTorrentView> torrents,
  ) {
    final DsTokens t = context.ds;
    final int total = s.otherCount;
    final String summary = s.otherVersions
        .map((SeedOtherBlock b) => '${b.label} ${b.count}')
        .join(' · ');
    return Column(
      key: dsDetailSeedsOtherKey,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Tooltip(
          message: _showOther ? '收起其他版本' : '展开其他版本（$total 条）',
          child: InkWell(
            key: dsDetailSeedsOtherToggleKey,
            onTap: () => setState(() => _showOther = !_showOther),
            borderRadius: BorderRadius.circular(t.radiusControl),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 2),
              child: Row(
                children: <Widget>[
                  Icon(
                    _showOther
                        ? Icons.keyboard_arrow_down
                        : Icons.keyboard_arrow_right,
                    size: 16,
                    color: t.text3,
                  ),
                  const SizedBox(width: 4),
                  Icon(Icons.layers, size: 13, color: t.text3),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      '其他版本（$total 条）：$summary',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: t.text2,
                        fontSize: DsTypeScale.caption,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        if (_showOther)
          for (final SeedOtherBlock block in s.otherVersions) ...<Widget>[
            _otherBlockHeader(block),
            for (final SeedGroup group in block.groups) ...<Widget>[
              _groupHeader(
                context,
                s,
                group,
                showTitle,
                marks,
                jobs,
                torrents,
                openKey: _otherKey(block.label, group.key),
                versionLabel: block.label,
              ),
              if (_openGroups.contains(
                _otherKey(block.label, group.key),
              )) ...<Widget>[
                _groupTable(
                  context,
                  s,
                  group,
                  showTitle,
                  marks,
                  jobs,
                  torrents,
                  // 表头只在最上面那张画一次；这里是展开区，不重复画。
                  showHeader: false,
                  scope: block.items,
                  playlist: block.items,
                  openKey: _otherKey(block.label, group.key),
                ),
                _groupFoot(
                  group,
                  t,
                  openKey: _otherKey(block.label, group.key),
                  versionLabel: block.label,
                ),
              ],
            ],
          ],
      ],
    );
  }

  /// 其他版本里一个小节的头：版本标签（`第三季` / `剧场版` / `更早的版本`）+ 条数。
  Widget _otherBlockHeader(SeedOtherBlock block) {
    final DsTokens t = context.ds;
    return Padding(
      key: dsDetailSeedsOtherBlockKey(block.label),
      padding: const EdgeInsets.only(top: 10, bottom: 2),
      child: Row(
        children: <Widget>[
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: t.accentSoft,
              borderRadius: BorderRadius.circular(t.radiusPill),
            ),
            child: Text(
              block.label,
              style: TextStyle(
                color: t.accent,
                fontSize: DsTypeScale.caption,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(width: 6),
          Text(
            block.hint == null
                ? '${block.count} 条'
                : '${block.hint} · ${block.count} 条',
            style: TextStyle(color: t.text3, fontSize: DsTypeScale.caption),
          ),
        ],
      ),
    );
  }

  /// 本作页与「合集」页里某一段的 id：`页名\u0000归一化组名`。
  ///
  /// 同一家字幕组（`桜都`）在本作页与「合集」页各有一段，两个 Set 不能撞。
  static String _categoryOpenKey(String label, String groupKey) =>
      '$label\u0000$groupKey';

  /// 当前有哪些页（第四十八轮·补七 / 补八）：只有 `本作` 与 `合集`，只列有内容的。
  ///
  /// 顺序就是界面上的顺序：本作永远第一页（用户打开这一页先看这个），合集第二（本作的
  /// 整季批量种）。**别的版本不做页**（补八「其他的不要」）—— 它们收在底部那行
  /// 「其他版本（N 条）」折区里（[_otherVersions]），不进这里。
  List<_SeedCategory> _categories(LibrarySeedState s) {
    if (s.phase != LibrarySeedPhase.ready) return const <_SeedCategory>[];
    final List<_SeedCategory> all = <_SeedCategory>[
      _SeedCategory(
        label: kSeedCurrentLabel,
        groups: s.groups,
        items: s.episodes,
      ),
      if (s.batchGroups.isNotEmpty)
        _SeedCategory(
          label: kSeedBatchLabel,
          groups: s.batchGroups,
          items: s.batchItems,
        ),
    ];
    return <_SeedCategory>[
      for (final _SeedCategory category in all)
        if (category.count > 0) category,
    ];
  }

  /// 当前选中的是第几页（选中的页没了就退回第一页 —— 重新搜一次之后页会变）。
  int _categoryIndex(List<_SeedCategory> categories) {
    final String? picked = _categoryLabel;
    if (picked == null || categories.isEmpty) return 0;
    final int at = categories.indexWhere(
      (_SeedCategory c) => c.label == picked,
    );
    return at < 0 ? 0 : at;
  }

  /// 分页条：`本作 332` / `合集 120`（补八起只有这两页，且只有真的有合集时才画）。
  ///
  /// 位置在**组名列表上面**（用户补七原话「在字幕组上面加入分页，把合集分进去」）。
  /// 横向滚动留着：以后真要多页也不至于换一次布局。
  Widget _categoryTabs(List<_SeedCategory> categories, int selected) {
    final DsTokens t = context.ds;
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: <Widget>[
          for (int i = 0; i < categories.length; i++)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: Tooltip(
                message: categories[i].tooltip,
                child: InkWell(
                  key: dsDetailSeedsCategoryKey(categories[i].label),
                  onTap: () =>
                      setState(() => _categoryLabel = categories[i].label),
                  borderRadius: BorderRadius.circular(t.radiusPill),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: i == selected ? t.accent : t.base,
                      borderRadius: BorderRadius.circular(t.radiusPill),
                      // 描边只用 token 颜色（规范 §7；守卫测试按行查 `t.`，所以写一行里）。
                      border: Border.all(color: i == selected ? t.accent : t.line),
                    ),
                    child: Text(
                      '${categories[i].label} ${categories[i].count}',
                      style: TextStyle(
                        color: i == selected ? t.onAccent : t.text2,
                        fontSize: DsTypeScale.caption,
                        fontWeight: i == selected
                            ? FontWeight.w600
                            : FontWeight.w400,
                      ),
                    ),
                  ),
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
