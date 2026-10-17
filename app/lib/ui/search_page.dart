/// 搜索页（spec §7.4 渲染图基线）：
/// 顶部查询条 → 「搜索结果」表格（一页 20 条 + 底部页码条）。
///
/// **默认不加载**（用户 2026-10-12：「搜索页改成默认不加载，只有个搜索，搜索后才有」）：
/// 进页面只给一个输入框和一句提示，回车/点「搜索」或点「最新」才会打网络。
/// 底部**只有页码条，没有「加载更多」**（同一天用户：「加载更多去掉，不应该有」）。
///
/// **聚合搜索**（用户 2026-10-12 第十四轮：「添加聚合搜索，聚合全部源，默认为聚合源，
/// 可切换聚合 动漫和全集，设置中切换回单独源模式」）：
/// * 默认模式 = **聚合**：顶部三颗 chip「聚合 / 动漫 / 全集」切档，一次搜索把这一档的
///   源全问一遍（合并去重见 `domain/aggregate.dart`）；
/// * 设置里切成「单独源模式」→ 回到本页以前的样子：右侧那个源下拉选一个源。
/// 两条路的取数都在 `SearchQueryController` 里（`_fetchSourcePage` 分叉）。
///
/// 三态齐全：loading / empty / error，错误带「怎么办」，绝不拿假数据充数。
///
/// 视觉（新拟态规范 `docs/specs/2026-10-10-dsanima-neo-theme.md`）：查询条 = 凹槽输入框
/// （形态由 Material 主题统一铺底）+ `NeoButton`；结果表格按决策 A43 由
/// `SearchResultsTable` 实现（无斑马纹、无竖线，表头 11px，行悬停 sunken 半透明）；
/// 语义色只以小面积出现（决策 A18）。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/aggregate.dart';
import '../domain/batch_download.dart';
import '../domain/episodes.dart';
import '../domain/error_text.dart';
import '../domain/format.dart';
import '../domain/models.dart';
import '../domain/ports.dart';
import '../domain/subtitle_groups.dart';
import '../state/playback.dart';
import '../state/providers.dart';
import '../state/search_history_provider.dart';
import '../theme/motion.dart';
import '../theme/tokens.dart';
import 'widgets/ds_cards.dart';
import 'widgets/feedback.dart';
import 'widgets/hues.dart';
import 'widgets/neo.dart';
import 'widgets/neo_dropdown.dart';
import 'widgets/search_history_bar.dart';
import 'widgets/search_sections.dart';
import 'widgets/state_views.dart';

/// 「源 N/M」那颗按钮的 key（测试用：面板开关一大堆，靠 key 才点得准）。
const Key dsSourcePanelChipKey = ValueKey<String>('ds-source-panel-chip');

/// 勾选面板对话框的 key。
const Key dsSourcePanelKey = ValueKey<String>('ds-source-panel');

/// 「字幕组」筛选 chip 的 key（第四十五轮）。
const Key dsGroupFilterChipKey = ValueKey<String>('ds-group-filter-chip');

/// 字幕组面板对话框的 key。
const Key dsGroupFilterPanelKey = ValueKey<String>('ds-group-filter-panel');

/// 面板里那个搜索框的 key。
const Key dsGroupFilterSearchKey = ValueKey<String>('ds-group-filter-search');

class SearchPage extends ConsumerStatefulWidget {
  const SearchPage({super.key});

  @override
  ConsumerState<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends ConsumerState<SearchPage> {
  final TextEditingController _keyword = TextEditingController();

  /// 关键字输入框的焦点（第四十五轮）：空态里那颗「换关键字」要把光标送回去。
  final FocusNode _keywordFocus = FocusNode();
  String? _busyItemId;

  /// 批量下载勾选的条目 id（用户 2026-10-12 第二十三轮：「搜索页批量选择下载」）。
  ///
  /// 跨页保留（翻页勾的还在），但**只保留当前池子里还有的条目** ——
  /// 换一轮搜索/刷新后，旧条目的行已经不在了，留着它等于"下载一个看不见的东西"。
  /// 收窄放在 `_body` 里做（那里才拿得到 `state.fetched`）。
  final Set<String> _selected = <String>{};

  /// 批量加入队列的进度（`_batchTotal == 0` = 没在跑）。
  bool _batchBusy = false;
  int _batchDone = 0;
  int _batchTotal = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // 只把上次的关键字填回输入框。**这里不再自动拉取**（用户 2026-10-12：
      // 「搜索页改成默认不加载，只有个搜索，搜索后才有」）—— 进页面不该打网络，
      // 也不该让用户看到一份"我没要过"的结果。
      _keyword.text = ref.read(searchProvider).keyword;
    });
  }

  @override
  void dispose() {
    _keyword.dispose();
    _keywordFocus.dispose();
    super.dispose();
  }

  /// 勾选的字幕组的展示名（`桜都字幕组 / LoliHouse`）。
  ///
  /// 顺序排一下再拼：Set 的迭代顺序不稳定，筛同一批组却显示成两种顺序会显得界面在抖。
  String _groupNames(SearchState state) {
    final List<String> keys = state.groupFilter.toList()..sort();
    return keys.map((String key) => subtitleGroupLabel(key, state.fetched)).join(' / ');
  }

  Future<void> _play(SourceItemView item, List<SourceItemView> items) async {
    setState(() => _busyItemId = item.id);
    try {
      await ref
          .read(playbackProvider.notifier)
          .playItem(
            item,
            upNext: followingEpisodes(items, item),
            // 播放列表按「同名同压制组」从**这一批搜索结果**里归组（用户 2026-10-11：
            // 「我要的播放列表为什么没有，按照我播放的同名同压制组」）。
            // mikan 上一集一个种子，只看单个种子永远凑不出列表。
            playlist: items,
          );
      final DsFailure? failure = ref.read(playbackProvider).failure;
      if (failure != null) {
        // 起播失败（引擎未连接 / 无磁力链 / …）：**不进播放页**，就地说明原因。
        // 统一走 `showFailure`（`NeoBanner`：12% 底 + 左侧 2px 语义色条 + 「怎么办」）。
        // 第三十轮改：原来整条铺 `t.dangerSoft` 是大面积语义色（F16/§2 只允许小面积）。
        if (mounted) showFailure(context, failure);
      }
      // 起播成功即已弹出播放窗口（用户 2026-10-10：只有弹窗播放，
      // 主窗口不切页、也没有播放面），这里不再做任何跳转。
    } catch (error, stackTrace) {
      // 统一走反馈通道（第四十二轮 UX #14：这里原来是自拼的 dangerSoft 底裸 SnackBar）。
      if (!mounted) return;
      showFailure(context, describeFailure(error, stackTrace: stackTrace));
    } finally {
      if (mounted) setState(() => _busyItemId = null);
    }
  }

  /// 勾选一条 / 取消勾选。
  void _toggleSelect(SourceItemView item) {
    setState(() {
      if (!_selected.remove(item.id)) _selected.add(item.id);
    });
  }

  /// 表头那颗勾：勾上本页**可下载的**全部，或取消本页勾选。
  ///
  /// 只动本页：别的页已经勾好的不该被这一下清掉（翻页是"再看看"，不是"重选"）。
  void _toggleSelectPage(List<SourceItemView> pageItems, bool select) {
    setState(() {
      for (final SourceItemView item in pageItems) {
        if (!canBatchDownload(item)) continue;
        if (select) {
          _selected.add(item.id);
        } else {
          _selected.remove(item.id);
        }
      }
    });
  }

  /// 批量加入下载队列：勾选的那一批，一次点完。
  ///
  /// 串行 + 每条单独兜错（见 `domain/batch_download.dart`）；结果用一条 SnackBar
  /// 说清"成功几条 / 跳过几条 / 第一条失败是什么"。
  Future<void> _downloadSelected(List<SourceItemView> pool) async {
    final List<SourceItemView> picked = <SourceItemView>[
      for (final SourceItemView item in pool)
        if (_selected.contains(item.id)) item,
    ];
    if (picked.isEmpty || _batchBusy) return;
    final QueuePort port = ref.read(queuePortProvider);
    setState(() {
      _batchBusy = true;
      _batchDone = 0;
      _batchTotal = picked.length;
    });
    try {
      final BatchDownloadResult result = await enqueueDownloads(
        port.enqueueDownload,
        picked,
        onProgress: (int done, int total) {
          if (mounted) {
            setState(() {
              _batchDone = done;
              _batchTotal = total;
            });
          }
        },
      );
      if (!mounted) return;
      // 加完就清空勾选：留着的话下一次点"下载选中"会重复入队（队列会复用同一条，
      // 但用户会以为按钮坏了）。
      //
      // 第四十二轮 UX #32：**失败的那几条要留着勾**。旧实现无条件 `_selected.clear()`，
      // 而失败提示里又写着"失败的条目可以只勾那几条再下一次" —— 用户回到表格里发现
      // 勾全没了，只能凭记忆一条条找回来（20 条里找 3 条）。
      setState(() {
        _selected
          ..clear()
          ..addAll(result.failedItems.map((SourceItemView i) => i.id));
      });
      final String summary = batchDownloadSummary(result);
      if (result.failures.isEmpty) {
        showSuccess(context, summary, seconds: 5);
      } else {
        showFailure(
          context,
          DsFailure(
            summary,
            hint: '失败的那 ${result.failedItems.length} 条已经替你留着勾，'
                '再点一次「下载选中」就是重试它们；已入队的在队列页里',
          ),
        );
      }
    } catch (error, stackTrace) {
      // `enqueueDownloads` 自己不抛；走到这儿说明是别的意外（例如端口没接通）。
      // 也走统一失败通道（第四十二轮 UX #14：这里原来自己拼了一条 dangerSoft 底色的
      // 裸 SnackBar，与全仓那套"凸起面 + 左侧语义色条 + 怎么办"不是一套）。
      if (!mounted) return;
      showFailure(context, describeFailure(error, stackTrace: stackTrace));
    } finally {
      if (mounted) {
        setState(() {
          _batchBusy = false;
          _batchTotal = 0;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final DsTokens t = context.ds;
    final SearchState state = ref.watch(searchProvider);
    final List<SourceOption> sources = ref.watch(sourceOptionsProvider);
    // 输入框为空时才有「最近搜索」那一块（打字时它只是噪音）。
    // 第四十二轮 UX #50：这一块**常驻**在树里、靠 `AnimatedSize` 收起展开，
    // 不再整块抽/插（旧写法会让输入框与结果区在打第一个字时齐刷刷跳一下）。
    final List<String> recentSearches = _keyword.text.trim().isEmpty
        ? ref.watch(searchHistoryProvider).of(SearchHistoryScope.torrents)
        : const <String>[];
    final EngineStatus engineStatus = ref.watch(engineStatusProvider);
    // 第五十二轮（用户 2026-10-17「整个项目太素」）：搜索页身份色 = 青
    // （侧栏 / 页头 / 页面洗色都用 `hueOfTab(ShellTab.search)`；本页的焦点态、
    // 分页条、空态也统一取它 —— 一处定义，整页一个色）。
    final DsHue pageHue = hueOfTab(ShellTab.search);

    // 设置页把「聚合 / 单独源」改掉后当场跟着切（用户 2026-10-12 第十四轮：
    // 「设置中切换回单独源模式」）。只盯这一个字段：设置页有 20 多项、
    // 第十六轮起还是**手动保存**（点「保存并生效」才写），整对象 listen 会在
    // 保存那一刻把搜索结果清空一次。
    ref.listen<SearchMode>(
      settingsProvider.select((AppSettings s) => s.searchMode),
      (SearchMode? previous, SearchMode next) =>
          ref.read(searchProvider.notifier).setMode(next),
    );

    SearchQueryController controller() => ref.read(searchProvider.notifier);
    final bool aggregate = state.mode == SearchMode.aggregate;
    // 这一轮**实际会问**几个源（勾选 ∩ 能搜关键字）。提示文案与失败文案都用它。
    final bool needSearch = state.keyword.trim().isNotEmpty;
    final int askedCount =
        selectedSources(sources, state.excludedSourceIds, needSearch: needSearch).length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: EdgeInsets.fromLTRB(t.spacing, t.spacing, t.spacing, 0),
          child: Row(
            children: <Widget>[
              Expanded(
                child: TextField(
                  controller: _keyword,
                  focusNode: _keywordFocus,
                  textInputAction: TextInputAction.search,
                  style: TextStyle(color: t.text, fontSize: DsTypeScale.body),
                  decoration: InputDecoration(
                    hintText: sources.isEmpty
                        ? '源未接通：先看下方提示'
                        : aggregate
                        ? '关键字（留空 = 看这一档的最新）。例如：葬送的芙莉莲'
                        : '关键字（留空 = 看最新）。例如：葬送的芙莉莲',
                    // 第五十二轮（用户 2026-10-17「整个项目太素」）：搜索页身份色 = 青。
                    // 全局输入框焦点态是 accent（橙），这里按**页面身份**换成青色：
                    // 8 个页面各有自己的色相，同一套焦点语义在不同页面不串色。
                    prefixIcon: Icon(Icons.search, size: 15, color: t.hueInk(pageHue)),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(t.radiusControl),
                      borderSide: BorderSide(color: t.hueInk(pageHue), width: 2),
                    ),
                  ),
                  // 打字时只重建这一层（用来决定"最近搜索"那一行要不要显示）。
                  onChanged: (String _) => setState(() {}),
                  onSubmitted: (String value) {
                    controller().setKeyword(value);
                    _rememberKeyword(ref, value);
                    unawaited(runGuarded(context, action: controller().refresh));
                  },
                ),
              ),
              const SizedBox(width: 7),
              // 第五十二轮：搜索页的主按钮用**页面身份色**（青），不再占用全局 accent ——
              // 「按下去会发生什么」由位置决定，颜色只负责"这是搜索页"。
              NeoButton(
                label: '搜索',
                icon: Icons.search,
                kind: NeoButtonKind.primary,
                hue: pageHue,
                onPressed: () => runGuarded(
                  context,
                  action: () async {
                    controller().setKeyword(_keyword.text);
                    _rememberKeyword(ref, _keyword.text);
                    await controller().refresh();
                  },
                ),
              ),
              const SizedBox(width: 6),
              NeoButton(
                label: '最新',
                icon: Icons.new_releases_outlined,
                onPressed: () => runGuarded(
                  context,
                  action: () async {
                    _keyword.clear();
                    controller().setKeyword('');
                    await controller().refresh();
                  },
                ),
              ),
              // 聚合模式：三颗 chip 是**快捷全选**（第十五轮）——「聚合」= 全部勾上、
              // 「动漫」= 只勾动漫分区、「全集」= 只勾合集分区；旁边那颗「源 N/M」
              // 打开勾选面板，可以再手动加减（sukebei 就在那个面板的「其它」组里）。
              // 单独源模式：回到本页以前的样子 —— 源下拉选一个源。
              if (aggregate && sources.isNotEmpty) ...<Widget>[
                const SizedBox(width: 12),
                for (final SearchScope scope in SearchScope.values) ...<Widget>[
                  _ScopeChip(
                    scope: scope,
                    current: scope == state.scope,
                    count: controller().scopeSourceCount(scope),
                    onPressed: () => runGuarded(
                      context,
                      action: () async {
                        if (!controller().applyScopePreset(scope)) return;
                        await controller().refresh();
                      },
                    ),
                  ),
                  const SizedBox(width: 5),
                ],
                _SourcePanelChip(
                  sources: sources,
                  excludedSourceIds: state.excludedSourceIds,
                  needSearch: needSearch,
                  onPressed: () => showDialog<void>(
                    context: context,
                    builder: (BuildContext context) => const _SourceSelectionDialog(),
                  ),
                ),
              ] else if (sources.isNotEmpty) ...<Widget>[
                const SizedBox(width: 10),
                SearchSourcePicker(
                  sources: sources,
                  value: state.sourceId,
                  onChanged: (String id) {
                    controller().setSource(id);
                    unawaited(runGuarded(context, action: controller().refresh));
                  },
                ),
              ],
              // 字幕组筛选（第四十五轮）：聚合与单独源两种模式下**都**在 ——
              // 它筛的是已经取到的池子，与"问哪些源"无关。
              // 一直显示（哪怕还没勾）：落盘的筛选必须在脸上看得见，否则用户会遇到
              // "结果怎么这么少"却找不到原因。
              const SizedBox(width: 10),
              _GroupFilterChip(
                pool: state.fetched,
                selected: state.groupFilter,
                filtered: state.filtering ? state.visible.length : null,
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (BuildContext context) => const _GroupFilterDialog(),
                ),
              ),
            ],
          ),
        ),
        // 第三十三轮：最近搜过的词（点一下 = 填进去并立刻搜）。
        // 只在输入框为空时显示 —— 正在打字时它只是噪音；有内容时上面那条提示也够长了。
        //
        // 第四十二轮 UX #50：它原来是在 `if` 里**整块**抽/插的（含一段 `SizedBox(8)`），
        // 于是打第一个字的那一瞬间输入框与整片结果区齐刷刷往上跳 30 多像素。
        // 现在这一块**常驻**、由 `AnimatedSize` 在 token 时长里收起/展开：
        // 布局变化还是有，但它是连续的、看得出"这里收起来了"，而不是抽一下。
        AnimatedSize(
          duration: DsMotion.of(context).hover,
          curve: DsMotion.hoverCurve,
          alignment: Alignment.topCenter,
          child: recentSearches.isEmpty
              ? const SizedBox(width: double.infinity)
              : Padding(
                  padding: EdgeInsets.fromLTRB(t.spacing, 8, t.spacing, 0),
                  child: SearchHistoryBar(
                    keyPrefix: 'torrent-history',
                    // 第五十二轮：历史胶囊 = 青色淡底（搜索页身份色）。
                    hue: pageHue,
                    history: recentSearches,
                    onPick: (String word) {
                      _keyword.text = word;
                      setState(() {});
                      controller().setKeyword(word);
                      _rememberKeyword(ref, word);
                      unawaited(runGuarded(context, action: controller().refresh));
                    },
                    onForget: (String word) => unawaited(ref
                        .read(searchHistoryProvider.notifier)
                        .forget(SearchHistoryScope.torrents, word)),
                    onClear: () => unawaited(ref
                        .read(searchHistoryProvider.notifier)
                        .clear(SearchHistoryScope.torrents)),
                  ),
                ),
        ),
        const SizedBox(height: 11),
        // 用户 2026-10-10 第 3 轮问答：搜索页的「继续观看」行与底部「订阅更新」面板
        // 都删掉 —— 前者属于主页，后者「订阅」页已经有一份。
        Expanded(child: _body(state, sources, engineStatus, askedCount)),
        SizedBox(height: t.spacing),
      ],
    );
  }

  /// 记一笔搜索历史（第三十三轮）。空词不记 —— 那是"看最新"，不是一次搜索。
  void _rememberKeyword(WidgetRef ref, String keyword) {
    if (keyword.trim().isEmpty) return;
    unawaited(ref
        .read(searchHistoryProvider.notifier)
        .remember(SearchHistoryScope.torrents, keyword));
  }

  /// 结果表格上面那条「批量下载」：已选几条 / 下载选中 / 全选本页 / 清空勾选。
  ///
  /// 只在**这一页有可下载条目**时出现（池子里一条磁力都没有时不摆一条用不了的工具条）。
  Widget _batchBar(SearchState state, List<SourceItemView> pageItems, int poolSelectable) {
    final DsTokens t = context.ds;
    final int picked = _selected.length;
    final int pageSelectable = pageItems.where(canBatchDownload).length;
    final bool disabled = picked == 0 || _batchBusy;
    return Padding(
      padding: EdgeInsets.fromLTRB(t.spacing, 0, t.spacing, 7),
      child: Row(
        children: <Widget>[
          DsChip(
            label: '已选 $picked 条',
            tone: picked == 0 ? t.text3 : t.accent,
            icon: Icons.checklist,
          ),
          const SizedBox(width: 8),
          NeoButton(
            label: _batchBusy ? '加入中 $_batchDone/$_batchTotal' : '下载选中 $picked 条',
            icon: Icons.download,
            kind: NeoButtonKind.primary,
            busy: _batchBusy,
            onPressed: disabled ? null : () => _downloadSelected(state.visible),
          ),
          const SizedBox(width: 6),
          NeoButton(
            label: '全选本页',
            icon: Icons.select_all,
            compact: true,
            onPressed: _batchBusy ? null : () => _toggleSelectPage(pageItems, true),
          ),
          const SizedBox(width: 6),
          NeoButton(
            label: '清空勾选',
            icon: Icons.deselect,
            compact: true,
            onPressed: picked == 0 || _batchBusy ? null : () => setState(_selected.clear),
          ),
          const SizedBox(width: 10),
          Flexible(
            child: Text(
              // 第四十二轮 UX #39：这里原来写「本页 N 条可下载」，而 N 取的是**整个池子**
              // （翻页攒下的全都算进来），同一条里的「全选本页」却只勾本页 —— 两个说法
              // 各说各话。现在分别说清"本页几条 / 池子里共几条"。
              '勾选多条一起加入下载队列（本页 $pageSelectable 条可下载'
              '${poolSelectable > pageSelectable ? '，池子里共 $poolSelectable 条' : ''}）；'
              '真正同时下几条由「队列」页的「一起下载」决定',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: t.text3, fontSize: DsTypeScale.caption),
            ),
          ),
        ],
      ),
    );
  }

  Widget _body(
    SearchState state,
    List<SourceOption> sources,
    EngineStatus engineStatus,
    int askedCount,
  ) {
    final DsTokens t = context.ds;
    final bool aggregate = state.mode == SearchMode.aggregate;
    // 第五十二轮：空态也带页面身份色（青），不再是一个全灰圆盘。
    final DsHue pageHue = hueOfTab(ShellTab.search);
    if (state.loading) {
      // 聚合：说清"在等几个源"，而不是含糊的"正在拉取"。
      return DsLoading(
        hue: pageHue,
        label: aggregate
            ? '正在从 $askedCount 个源拉取…'
            : '正在从 ${_sourceLabel(sources, state.sourceId)} 拉取…',
      );
    }
    if (!state.loaded) {
      // 还没搜过：这一屏只有一句"该干什么"。**不预拉最新**（用户 2026-10-12：
      // 「默认不加载，只有个搜索，搜索后才有」）——「最新」是那颗按钮，不是默认动作。
      return DsEmpty(
        icon: Icons.search,
        hue: pageHue,
        title: '在搜索框里输入番名，回车或点「搜索」',
        message: aggregate
            ? '当前是聚合模式：一次搜索会同时问勾选的 $askedCount 个源（默认全开，'
                  '点右上角「${selectionSummary(sources, state.excludedSourceIds)}」可以只勾几个，'
                  'sukebei 在「其它」那组里）。结果合并去重后按时间从新到旧排。'
                  '想只问一个源，到「设置 → 网络 · 限速 · 做种」改成单独源模式。'
            : '搜索页不再自动拉取。'
                  '想直接看某个源的最新更新，点右边那颗「最新」；'
                  '源下拉只影响搜索，随时可换。',
      );
    }
    if (state.failure != null && state.fetched.isEmpty) {
      // 只有"整轮刷新失败、池子里一条都没有"才让错误面板占满整页。翻页失败时
      // 池子里还留着已经拿到的结果，不该把用户正在看的那 20 条换成错误面板
      //（那种失败走下面表格上方的横幅）。
      return SingleChildScrollView(
        child: DsErrorPanel(
          failure: state.failure!,
          title: aggregate
              ? '拉取失败：勾选的 $askedCount 个源都没回来'
              : '拉取失败：${_sourceLabel(sources, state.sourceId)}',
          onRetry: () => runGuarded(context, action: ref.read(searchProvider.notifier).refresh),
        ),
      );
    }
    // 第四十五轮：池子里**有**结果，但勾的字幕组一条都没命中。
    //
    // 与下面那条「什么都没搜到」**分开说**：两句提示给的动作完全不同 —— 这里该
    // 「继续加载更多结果」或「清空筛选」，那里该换关键字。第四十四轮的教训：
    // 空态必须说清是哪种空、并给出下一步（否则用户只会以为页面坏了）。
    if (state.filtering && state.visible.isEmpty) {
      final SearchQueryController c = ref.read(searchProvider.notifier);
      final String names = _groupNames(state);
      if (state.loadingPage) {
        return DsLoading(hue: pageHue, label: '正在按「$names」继续往后拉取…');
      }
      return DsEmpty(
        icon: Icons.filter_alt_off_outlined,
        hue: pageHue,
        title: '这批结果里没有「$names」的条目',
        message: state.hasMoreSource
            ? '已经拿到 ${state.fetched.length} 条结果，但都不是这几个字幕组。'
                  '可以继续往后拉源站的结果，或者把筛选放宽。'
            : '已经拿到 ${state.fetched.length} 条结果，源那边也没有更多了，'
                  '都不是这几个字幕组。换一个关键字，或者把筛选放宽。',
        action: Wrap(
          spacing: 8,
          runSpacing: 8,
          alignment: WrapAlignment.center,
          children: <Widget>[
            if (state.hasMoreSource)
              NeoButton(
                label: '继续加载更多结果',
                icon: Icons.expand_more,
                kind: NeoButtonKind.primary,
                onPressed: () => unawaited(
                  runGuarded(context, action: c.loadMoreForFilter),
                ),
              ),
            NeoButton(
              label: '清空筛选',
              icon: Icons.filter_alt_off,
              onPressed: c.clearGroupFilter,
            ),
            NeoButton(
              label: '换关键字',
              icon: Icons.search,
              onPressed: () => _keywordFocus.requestFocus(),
            ),
          ],
        ),
      );
    }
    if (state.isEmpty) {
      return DsEmpty(
        icon: Icons.search_off,
        hue: pageHue,
        title: state.keyword.isEmpty
            ? (aggregate ? '勾选的源现在没有内容' : '这个源现在没有内容')
            : '没有匹配「${state.keyword}」的结果',
        message: state.keyword.isEmpty
            ? (aggregate
                  ? '打开右上角「源」面板多勾几个站，或换个关键字'
                  : '换个关键字，或点右边那颗「最新」看看这个源最近的更新')
            : aggregate
                  ? '已经问了勾选的 $askedCount 个源，都没有。试试日文原名 / 罗马音 / 去掉季数，'
                        '例如「Frieren」；或打开右上角「${selectionSummary(sources, state.excludedSourceIds)}」'
                        '把没勾的站也勾上'
                  : '试试日文原名 / 罗马音 / 去掉季数，例如「Frieren」',
      );
    }
    // 表格只渲染**当前显示页**的 20 条（用户 2026-10-11：「按照一页20条」）；
    // 播放列表却要拿**池子**（`state.visible`：开了字幕组筛选时就是筛过的那一份）：
    // 按「同名同压制组」归组时，跨页的集数必须还在手里，否则翻到第 2 页播第 21 条
    // 就只剩它自己了。
    final List<SourceItemView> pageItems = state.items;
    // 勾选只保留**现在还看得见**的条目：换一轮搜索/刷新、或者换一次字幕组筛选后，
    // 被筛掉的行已经不在屏幕上了，留着它等于"批量下载一个看不见的东西"
    // （第四十五轮：筛选变化必须顺手收窄勾选）。
    final Set<String> poolIds = <String>{
      for (final SourceItemView item in state.visible) item.id,
    };
    _selected.removeWhere((String id) => !poolIds.contains(id));
    final int selectableCount = state.visible.where(canBatchDownload).length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (state.failure != null)
          Padding(
            padding: EdgeInsets.fromLTRB(t.spacing, 0, t.spacing, 7),
            child: DsBanner(
              kind: DsBannerKind.error,
              // 翻页失败：池子里的结果照旧显示，只说明"刚才那一页没取到"。
              text: state.failure!.hint == null
                  ? state.failure!.message
                  : '${state.failure!.message}（${state.failure!.hint}）',
              // 第四十二轮 UX #21：**必须给一个重试入口**。旧实现只有这一行文字，
              // 用户唯一能试的是"再点一次那个页码"，而 `goToPage` 的
              // `target == state.page` 闸门在"池子凑不出这一页"时会把它吞掉 ——
              // 点了没反应，只能干看着。这里直接走 `retryFailedPage()`（绕开那个闸门）。
              action: NeoButton(
                label: '重试',
                icon: Icons.refresh,
                kind: NeoButtonKind.primary,
                onPressed: () => unawaited(
                  ref.read(searchProvider.notifier).retryFailedPage(),
                ),
              ),
            ),
          ),
        if (state.fromCache)
          Padding(
            padding: EdgeInsets.fromLTRB(t.spacing, 0, t.spacing, 7),
            child: DsBanner(
              // 第四十二轮 UX #10：只有**过期回落**（网络真的失败过）才报"抓取失败"。
              // 新鲜命中（默认 TTL 300 秒内，重搜同一个词必然命中）根本没发过网络请求，
              // 旧实现把它也画成「网络抓取失败」，用户会以为网络一直在坏。
              kind: state.staleFallback
                  ? DsBannerKind.warning
                  : DsBannerKind.info,
              text: state.staleFallback
                  ? '网络抓取失败，显示的是缓存结果（缓存写入于 '
                      '${formatRelative(state.fetchedAt)}）'
                  : '这是缓存结果（写入于 ${formatRelative(state.fetchedAt)}）：'
                      '这一段时间内重搜同一个词不会重新联网',
            ),
          ),
        // 聚合：**部分**源没回来（用户 2026-10-12 第十四轮选定"警告带 + 其余照常显示"）。
        // 不静默跳过：静默会让用户以为"聚合了全部源"，而真相是少看了几个站。
        if (state.aggregateWarning case final String warning)
          Padding(
            padding: EdgeInsets.fromLTRB(t.spacing, 0, t.spacing, 7),
            child: DsBanner(kind: DsBannerKind.warning, text: warning),
          ),
        // 字幕组筛选生效时的那一行（第四十五轮）：说清"正在按谁筛、命中几条"，
        // 并给一颗就地关掉的出口。为什么必须有这一行 —— 筛选是**落盘**的，
        // 用户下次打开 app 会带着它，没有这行提示就只剩"结果怎么这么少"。
        if (state.filtering)
          Padding(
            padding: EdgeInsets.fromLTRB(t.spacing, 0, t.spacing, 7),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    '正在按字幕组筛选：${_groupNames(state)}'
                    '（命中 ${state.visible.length} 条 / 共 ${state.fetched.length} 条）'
                    '${state.loadingPage ? ' · 正在继续往后拉取…' : ''}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: t.text2, fontSize: DsTypeScale.caption),
                  ),
                ),
                const SizedBox(width: 8),
                NeoButton(
                  label: '清空筛选',
                  icon: Icons.filter_alt_off,
                  compact: true,
                  onPressed: ref.read(searchProvider.notifier).clearGroupFilter,
                ),
              ],
            ),
          ),
        // 批量下载条（用户 2026-10-12 第二十三轮：「搜索页批量选择下载」）。
        // 放在结果表格**上面**：勾选是"我要下这一批"的前一步，按钮得在旁边看得见，
        // 而不是等用户把一页 20 条一条条点完。
        if (selectableCount > 0) _batchBar(state, pageItems, selectableCount),
        Expanded(
          child: SearchResultsTable(
            items: pageItems,
            engineConnected: engineStatus.isConnected,
            busyItemId: _busyItemId,
            onPlay: (SourceItemView item) => _play(item, state.visible),
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
            onToggleSelect: _toggleSelect,
            onToggleSelectAll: (bool select) => _toggleSelectPage(pageItems, select),
            // 结果行那个"来源"要写人看的名字（第四十二轮 UX #16）。
            sources: sources,
          ),
        ),
        _footer(state),
      ],
    );
  }

  /// 底部页码条：`‹ 1 2 … ›   第 X 页`。
  ///
  /// 用户 2026-10-12：「搜索页的加载更多去掉，不应该有」—— 那颗按钮整个删掉。
  /// 一页仍然是 20 条（`kSearchPageSize`），要继续看就点页码或 `›`：
  /// 两套入口本来就都落到 `goToPage`，删掉其中一个不等于少一种能力。
  ///
  /// 用户 2026-10-12 第八轮：「为什么只有 50 页，不要固定页数，加载出数据就加一页」——
  /// 所以页脚**不再显示总页数**（`第 X / Y 页` → `第 X 页`，`共 N 页` 整句删掉），
  /// 页码条也不再画末页数字（见 `searchPageNumbers`）。
  Widget _footer(SearchState state) {
    final DsTokens t = context.ds;
    // 第五十二轮：分页条属于搜索页身份 → 青（当前页、页数文字、翻页箭头同色）。
    final DsHue pageHue = hueOfTab(ShellTab.search);
    final SearchQueryController controller = ref.read(searchProvider.notifier);
    // 翻页的"正在取数"标记：表格留在原地，只在底部提示。
    if (state.loadingPage) {
      return DsLoading(hue: pageHue, label: '正在取下一页…', compact: true);
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              _pager(state, controller),
              const SizedBox(width: 12),
              Text(
                '第 ${state.page} 页',
                style: TextStyle(
                  color: t.hueInk(pageHue),
                  fontSize: DsTypeScale.caption,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          if (!state.canGoNext)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                '— 没有更多了 —',
                style: TextStyle(color: t.text3, fontSize: DsTypeScale.caption),
              ),
            ),
        ],
      ),
    );
  }

  /// 页码条 `‹ 1 2 … ›`：当前页高亮，没有更早/更晚时箭头禁用。
  ///
  /// 右边那个「…」是**只有提示、没有数字**的（用户 2026-10-12 第八轮）：末页数字要
  /// 真翻到才会出现，这样"页数"看起来就是随数据长出来的，而不是一开始就定死一个总数。
  Widget _pager(SearchState state, SearchQueryController controller) {
    final DsTokens t = context.ds;
    // 第五十二轮：翻页箭头也走页面身份色（禁用态仍由 NeoIconButton 退回 text3）。
    final Color pageInk = t.hueInk(hueOfTab(ShellTab.search));
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        NeoIconButton(
          icon: Icons.chevron_left,
          size: 24,
          tooltip: '上一页',
          color: pageInk,
          onPressed: state.canGoPrevious
              ? () => runGuarded(context, action: () => controller.goToPage(state.page - 1))
              : null,
        ),
        for (final int? p in searchPageNumbers(page: state.page, pageCount: state.pageCount))
          if (p == null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: Text('…', style: TextStyle(color: t.text3, fontSize: DsTypeScale.caption)),
            )
          else
            _PageChip(
              page: p,
              current: p == state.page,
              // 当前页不给点（点了也是原地不动），灰掉比"可点但没反应"诚实。
              onPressed: p == state.page
                  ? null
                  : () => runGuarded(context, action: () => controller.goToPage(p)),
            ),
        NeoIconButton(
          icon: Icons.chevron_right,
          size: 24,
          tooltip: '下一页',
          color: pageInk,
          onPressed: state.canGoNext
              ? () => runGuarded(context, action: () => controller.goToPage(state.page + 1))
              : null,
        ),
      ],
    );
  }

  String _sourceLabel(List<SourceOption> sources, String id) {
    for (final SourceOption s in sources) {
      if (s.id == id) return s.displayName;
    }
    return id;
  }
}

/// 聚合档的一颗 chip（「聚合 / 动漫 / 全集」）。
///
/// 第 15 轮起它是**快捷全选**：点它 = 按分区把源勾成"这一档"的样子，随后还能在
/// 「源 N/M」面板里手动加减。所以 [current] 的含义是"勾选正好等于这一档的预设"，
/// 用户改过一个源它就会全部灭掉（那时真相在面板里，不在 chip 上）。
///
/// 为什么用 `NeoActionChip` 而不是 `NeoButton`：这是**切换**不是提交，三颗并排
/// 长得像"分段选择器"更贴切；当前档靠 `labelWidget` 换字色/字重区分
/// （`NeoActionChip` 的默认标签永远是强调色，看不出"我在这一档"）。
/// tooltip 里带上"这一档有几个源"——用户问过"聚合到底聚合了几个"，这一颗就说清。
class _ScopeChip extends StatelessWidget {
  const _ScopeChip({
    required this.scope,
    required this.current,
    required this.count,
    required this.onPressed,
  });

  final SearchScope scope;
  final bool current;
  final int count;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final DsTokens t = context.ds;
    // 这一档里一个源都没有（或都不能搜关键字）→ 点它只会把源全排掉，所以禁用。
    final bool enabled = count > 0;
    return NeoActionChip(
      label: scope.label,
      tooltip: !enabled
          ? '「${scope.label}」这一档现在没有可搜索的源'
          : current
          ? '当前档：${scope.label}（这一档有 $count 个源；可以在「源」面板里再改）'
          : '把源勾成「${scope.label}」这一档（$count 个源）',
      // 当前档不给点（点了也是原地重搜一次），chip 自己会退化成"不可点"。
      onTap: (current || !enabled) ? null : () async => onPressed(),
      // 第三十轮：原来当前档是**中性字色**、其余档是 chip 默认的 accent 色
      // ⇒ 看着像"没选中的才是选中的"。现在当前 = accent + 加粗（规范 §2/§6：选中靠颜色），
      // 其余 = 中性字色（它们是"点了会跳过去"的动作）。
      labelWidget: Text(
        scope.label,
        style: TextStyle(
          color: current ? t.accent : t.text2,
          fontSize: DsTypeScale.caption,
          fontWeight: current ? FontWeight.w700 : FontWeight.w500,
        ),
      ),
    );
  }
}

/// 聚合搜索的「源 N/M」按钮：打开勾选面板（第 15 轮）。
///
/// N/M = 勾上的 / 注册表里全部源。用户要的就是"我到底在问几个站"，所以数字直接写在
/// 脸上，而不是藏进设置页；tooltip 再把**勾上的名字**逐个列出来 —— 聚合搜索最怕的
/// 一件事就是"我以为是全部源，其实某个站没在问"。
class _SourcePanelChip extends StatelessWidget {
  const _SourcePanelChip({
    required this.sources,
    required this.excludedSourceIds,
    required this.needSearch,
    required this.onPressed,
  });

  final List<SourceOption> sources;
  final Set<String> excludedSourceIds;
  final bool needSearch;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final DsTokens t = context.ds;
    final int selected = selectedSourceCount(sources, excludedSourceIds);
    // 手动改过 → 三颗 chip 都不高亮，这里补一句"已自定义"，免得像"什么都没选"。
    final bool custom = activeScopePreset(sources, excludedSourceIds) == null;
    return NeoActionChip(
      key: dsSourcePanelChipKey,
      label: selectionSummary(sources, excludedSourceIds),
      tooltip: '${selectionDetail(sources, excludedSourceIds, needSearch: needSearch)}\n'
          '点开可以只勾几个源（默认全开）${custom ? '；当前是自定义勾选' : ''}',
      labelWidget: Text(
        selectionSummary(sources, excludedSourceIds),
        style: TextStyle(
          color: selected == 0 ? t.danger : (custom ? t.accent : t.text2),
          fontSize: DsTypeScale.caption,
          fontWeight: custom ? FontWeight.w700 : FontWeight.w500,
        ),
      ),
      // 块体而不是 `() async => onPressed()`：后者会把 `showDialog` 的 Future 当返回值
      // 一路 await 下去，于是整个面板打开期间这颗 chip 一直显示「处理中…」（撒谎）。
      // 打开面板是纯 UI 动作，不需要忙态。
      onTap: () async {
        onPressed();
      },
    );
  }
}

/// 源勾选面板：默认全开，可以把不想问的站关掉（第 15 轮）。
///
/// 三条规则（都来自第一轮问答）：
/// 1. **默认全开** —— 新出现的源（刚打开的 sukebei、新加的自定义 RSS）自动算勾上，
///    所以面板里不需要"添加源"这种动作，只有开关；
/// 2. **开启 sukebei 时也能勾选** —— 它按分区分在「其它」那一组，和动漫源一样是一个开关；
/// 3. **至少留一个源** —— 最后一个勾着的源取消不掉（开关变灰 + 一句说明），
///    否则下一次搜索必然报错。
class _SourceSelectionDialog extends ConsumerWidget {
  const _SourceSelectionDialog();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final DsTokens t = context.ds;
    final SearchState state = ref.watch(searchProvider);
    final List<SourceOption> sources = ref.watch(sourceOptionsProvider);
    final SearchQueryController controller = ref.read(searchProvider.notifier);
    final bool needSearch = state.keyword.trim().isNotEmpty;
    final int selected = selectedSourceCount(sources, state.excludedSourceIds);
    final List<SourceGroup> groups = sourceGroups(sources);

    return AlertDialog(
      key: dsSourcePanelKey,
      title: const Text('聚合搜索：问哪几个源'),
      content: SizedBox(
        width: 470,
        height: 430,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(
              '${selectionSummary(sources, state.excludedSourceIds)} · '
              '${selectionDetail(sources, state.excludedSourceIds, needSearch: needSearch)}',
              style: TextStyle(color: t.text3, fontSize: DsTypeScale.caption, height: 1.5),
            ),
            const SizedBox(height: 10),
            Expanded(
              child: groups.isEmpty
                  ? const DsEmpty(
                      icon: Icons.hub_outlined,
                      hue: DsHue.cyan,
                      title: '还没有可选的源',
                      message: '源未接通（core 的 sources/ 尚未注入），或订阅源已被全部删除。',
                    )
                  : ListView(
                      children: <Widget>[
                        for (final SourceGroup group in groups) ...<Widget>[
                          Padding(
                            padding: const EdgeInsets.only(top: 6, bottom: 2),
                            child: Text(
                              '${partitionLabel(group.partition)}（${group.sources.length}）',
                              style: TextStyle(
                                color: t.text3,
                                fontSize: DsTypeScale.caption,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          for (final SourceOption s in group.sources)
                            _SourceToggleRow(
                              source: s,
                              selected: !state.excludedSourceIds.contains(s.id),
                              // 最后一个勾着的源：开关变灰（见类注释第 3 条）。
                              blocked: blocksUnselect(
                                sources: sources,
                                excludedSourceIds: state.excludedSourceIds,
                                id: s.id,
                              ),
                              needSearch: needSearch,
                              onChanged: (bool value) {
                                final bool ok = controller.toggleSource(s.id);
                                if (!ok) {
                                  showFailure(
                                    context,
                                    const DsFailure(
                                      '至少留一个源',
                                      hint: '搜索总得问点什么：先把别的源勾上，再取消这一个',
                                    ),
                                  );
                                }
                              },
                            ),
                        ],
                      ],
                    ),
            ),
            const SizedBox(height: 8),
            Row(
              children: <Widget>[
                NeoButton(
                  label: '全选（默认）',
                  icon: Icons.select_all,
                  // 已经全勾时不给点：点了也是原地不动。
                  onPressed: selected == sources.length
                      ? null
                      : () => controller.selectAllSources(),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '取消掉的源不会再被搜；勾选记在设置里，下次启动照旧。'
                    '新出现的源（刚打开的 sukebei、新加的 RSS）默认是勾上的。'
                    '至少留一个源。',
                    style: TextStyle(color: t.text3, fontSize: DsTypeScale.caption, height: 1.5),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
      actions: <Widget>[
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('完成'),
        ),
      ],
    );
  }
}

/// 面板里的一行：源名 + 一个开关。
class _SourceToggleRow extends StatelessWidget {
  const _SourceToggleRow({
    required this.source,
    required this.selected,
    required this.blocked,
    required this.needSearch,
    required this.onChanged,
  });

  final SourceOption source;
  final bool selected;
  final bool blocked;
  final bool needSearch;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final DsTokens t = context.ds;
    final String? note = needSearch && !source.supportsSearch
        ? '只提供「最新」，不参与关键字搜索'
        : (source.partition == SourcePartition.other ? '其它分区（例如 sukebei）' : null);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  source.displayName,
                  style: TextStyle(
                    color: selected ? t.text : t.text3,
                    fontSize: DsTypeScale.body,
                  ),
                ),
                if (note != null)
                  Text(note, style: TextStyle(color: t.text3, fontSize: DsTypeScale.caption)),
              ],
            ),
          ),
          const SizedBox(width: 10),
          NeoSwitch(
            key: ValueKey<String>('ds-source-toggle-${source.id}'),
            value: selected,
            // 最后一个勾着的源：onChanged 传 null → 开关自己会变灰（用户点不动）。
            onChanged: blocked ? null : onChanged,
            tooltip: blocked ? '至少留一个源：最后一个勾着的源不能取消' : null,
          ),
        ],
      ),
    );
  }
}

/// 搜索页的源选择器（用户 2026-10-10 第 2 轮问答：「源下拉只在搜索页」）。
///
/// 从主窗口工具条搬过来的：源只影响**搜索**，工具条是全局位置，放那里等于
/// 让"页面级设置"变成"窗口级设置"；搬进来之后工具条只剩页名与窗口按钮。
class SearchSourcePicker extends StatelessWidget {
  const SearchSourcePicker({
    super.key,
    required this.sources,
    required this.value,
    required this.onChanged,
  });

  final List<SourceOption> sources;
  final String value;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final bool hasValue = sources.any((SourceOption s) => s.id == value);
    // 存的源不在了：优先落回 mikan（默认源），没有 mikan 才用列表第一个。
    final String fallback = sources.any((SourceOption s) => s.id == 'mikan')
        ? 'mikan'
        : sources.first.id;
    final String active = hasValue ? value : fallback;
    return NeoDropdown<String>(
      width: 190,
      tooltip: '数据源（搜索/下载都走它）',
      // 第五十二轮：单独源模式下这颗下拉**就是当前源的身份色**（hueOfSource）——
      // 同一个源在结果行、种子块、这里永远同色，切源时颜色跟着变。
      hue: hueOfSource(active),
      value: active,
      label: sources.firstWhere((SourceOption s) => s.id == active).displayName,
      items: <NeoDropdownItem<String>>[
        for (final SourceOption s in sources) NeoDropdownItem<String>(s.id, s.displayName),
      ],
      onSelected: onChanged,
    );
  }
}

/// 页码条上的一颗页码。
///
/// 为什么不用 `NeoButton`：页码是"标签"不是"动作"，一页一个按钮会把底部撑得又高又吵；
/// 用 `NeoActionChip` 的凹槽形态与其它小控件同一手感，当前页靠 [current] 换字色/字重
/// 区分（`NeoActionChip` 的默认标签永远是强调色，看不出"我在这一页"）。
class _PageChip extends StatelessWidget {
  const _PageChip({required this.page, required this.current, this.onPressed});

  final int page;
  final bool current;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final DsTokens t = context.ds;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: NeoActionChip(
        label: '$page',
        tooltip: current ? '当前第 $page 页' : '跳到第 $page 页',
        // 当前页传 null：chip 自己会退化成"不可点"，不需要额外禁用逻辑。
        onTap: onPressed == null ? null : () async => onPressed!(),
        labelWidget: Text(
          '$page',
          style: TextStyle(
            // 第五十二轮：当前页 = 搜索页身份色（青），翻页条与页面同色。
            color: current ? t.hueInk(hueOfTab(ShellTab.search)) : t.text2,
            fontSize: DsTypeScale.caption,
            fontWeight: current ? FontWeight.w700 : FontWeight.w500,
          ),
        ),
      ),
    );
  }
}

/// 字幕组筛选 chip（第四十五轮）：`字幕组` / `字幕组 · 2`。
///
/// 数字 = **勾了几个组**，不是命中几条：命中数会随后台续拉一直变，写在 chip 上会让人
/// 觉得"数字自己在跳"；命中数放在结果区那一行里说（见 `_body` 的提示行）。
class _GroupFilterChip extends StatelessWidget {
  const _GroupFilterChip({
    required this.pool,
    required this.selected,
    required this.filtered,
    required this.onPressed,
  });

  final List<SourceItemView> pool;
  final Set<String> selected;

  /// 筛出几条（没开筛选时为 null，tooltip 里就不提这一句）。
  final int? filtered;

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final DsTokens t = context.ds;
    final bool on = selected.isNotEmpty;
    final List<String> keys = selected.toList()..sort();
    final String names = keys.map((String k) => subtitleGroupLabel(k, pool)).join(' / ');
    final String label = on ? '字幕组 · ${selected.length}' : '字幕组';
    return NeoActionChip(
      key: dsGroupFilterChipKey,
      label: label,
      tooltip: on
          ? '正在只看：$names${filtered == null ? '' : '（命中 $filtered 条）'}\n点开可以改'
          : '按字幕组筛这批结果（筛的是已经取到的结果，不重新发请求；勾选会记住）',
      labelWidget: Text(
        label,
        style: TextStyle(
          color: on ? t.accent : t.text2,
          fontSize: DsTypeScale.caption,
          fontWeight: on ? FontWeight.w700 : FontWeight.w500,
        ),
      ),
      // 块体而不是 `() async => onPressed()`：后者会把 showDialog 的 Future 当返回值
      // 一路 await 下去，面板打开期间这颗 chip 会一直显示「处理中…」（撒谎）。
      onTap: () async {
        onPressed();
      },
    );
  }
}

/// 字幕组筛选面板（第四十五轮）。
///
/// 口径（用户第四十五轮逐条选定）：
/// * 多选 = **并集**（勾两家 = 两家的都显示）；它与源/档位/关键字之间才是 AND；
/// * 候选 = 预置 33 家 + 本批结果里动态出现的组，「最近用过的」排前面；
/// * 「未知组」单列一项（组名解析不出来的条目，实测占 4~6%）；预置但这一批 0 命中的
///   照列、显示 0 条 —— 用户要的是"知道有这个组、这次它没有资源"，而不是它凭空消失；
/// * 勾一下就**立刻生效**，不用点"应用"：这个面板是 state 的视图，不是表单。
class _GroupFilterDialog extends ConsumerStatefulWidget {
  const _GroupFilterDialog();

  @override
  ConsumerState<_GroupFilterDialog> createState() => _GroupFilterDialogState();
}

class _GroupFilterDialogState extends ConsumerState<_GroupFilterDialog> {
  final TextEditingController _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final DsTokens t = context.ds;
    final SearchState state = ref.watch(searchProvider);
    final AppSettings settings = ref.watch(settingsProvider);
    final SearchQueryController controller = ref.read(searchProvider.notifier);
    final String needle = _search.text.trim().toLowerCase();
    // ⚠️ 计数必须拿**未筛的池子**（`state.fetched`）：拿 `state.visible` 的话，勾完一家
    // 之后其余每一家的计数都会变成 0（它们都被筛掉了），面板会当场自相矛盾。
    final List<SubtitleGroupOption> all = buildSubtitleGroupOptions(
      pool: state.fetched,
      selected: state.groupFilter,
      recent: settings.recentSubtitleGroups,
    );
    final List<SubtitleGroupOption> options = <SubtitleGroupOption>[
      for (final SubtitleGroupOption o in all)
        if (o.isUnknown ||
            needle.isEmpty ||
            o.label.toLowerCase().contains(needle) ||
            o.key.contains(needle))
          o,
    ];

    return AlertDialog(
      key: dsGroupFilterPanelKey,
      title: const Text('按字幕组筛这批结果'),
      content: SizedBox(
        width: 470,
        height: 460,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(
              state.fetched.isEmpty
                  ? '还没有结果：先在搜索页搜一次，再回来按字幕组筛。'
                  : '池子里 ${state.fetched.length} 条 · 已勾 ${state.groupFilter.length} 个组'
                        '（多选 = 并集：勾两家就是两家的都显示）',
              style: TextStyle(color: t.text3, fontSize: DsTypeScale.caption, height: 1.5),
            ),
            const SizedBox(height: 8),
            TextField(
              key: dsGroupFilterSearchKey,
              controller: _search,
              style: TextStyle(color: t.text, fontSize: DsTypeScale.body),
              decoration: const InputDecoration(
                hintText: '在候选里找组名…',
                prefixIcon: Icon(Icons.search, size: 15),
              ),
              onChanged: (String _) => setState(() {}),
            ),
            const SizedBox(height: 6),
            Expanded(
              child: options.isEmpty
                  ? const DsEmpty(
                      icon: Icons.search_off,
                      hue: DsHue.cyan,
                      title: '候选里没有这个组名',
                      message: '换几个字试试；长尾里的组要等它出现在结果里才会进候选。',
                    )
                  : ListView(
                      children: <Widget>[
                        for (final SubtitleGroupOption o in options)
                          _GroupToggleRow(
                            option: o,
                            onChanged: () => controller.toggleGroup(o.key),
                          ),
                      ],
                    ),
            ),
            const SizedBox(height: 8),
            Row(
              children: <Widget>[
                NeoButton(
                  label: '全清',
                  icon: Icons.filter_alt_off,
                  // 一个都没勾时不给点：点了也是原地不动。
                  onPressed: state.groupFilter.isEmpty ? null : controller.clearGroupFilter,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '筛选只作用于已经取到的结果（不重新发请求）；不够一页时会自动往后拉，'
                    '页数按筛选后的条数算。勾选记在设置里，下次启动照旧。',
                    style: TextStyle(color: t.text3, fontSize: DsTypeScale.caption, height: 1.5),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
      actions: <Widget>[
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('完成'),
        ),
      ],
    );
  }
}

/// 面板里的一行：组名 + 命中条数 + 一个开关。
class _GroupToggleRow extends StatelessWidget {
  const _GroupToggleRow({required this.option, required this.onChanged});

  final SubtitleGroupOption option;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final DsTokens t = context.ds;
    final bool zero = option.count == 0;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  option.label,
                  style: TextStyle(
                    color: option.selected ? t.text : (zero ? t.text3 : t.text2),
                    fontSize: DsTypeScale.body,
                    fontWeight: option.selected ? FontWeight.w600 : FontWeight.w400,
                  ),
                ),
                Text(
                  option.isUnknown
                      ? '${option.count} 条 · 组名没解析出来'
                      : '${option.count} 条${option.preset ? ' · 预置' : ''}',
                  style: TextStyle(color: t.text3, fontSize: DsTypeScale.caption),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          NeoSwitch(
            key: ValueKey<String>('ds-group-toggle-${option.key}'),
            value: option.selected,
            onChanged: (bool _) => onChanged(),
          ),
        ],
      ),
    );
  }
}
