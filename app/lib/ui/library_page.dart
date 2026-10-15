/// 「动漫库」（第三十三轮）：调 Bangumi 全库，带筛选浏览 + 关键词搜索。
///
/// 用户原话：「添加新页面，名为动漫库，调用bangumi，有筛选，详细可通过问答」+
/// 问答里选定的能力：类型/放送形态、年份、季度、排序（热度·评分·排名）、标签（用条目
/// 自带的标签区点着筛）、评分下限、关键词搜索、点开详情、详情里能搜种子/加入追番；
/// 入口「排在主页下面」。
///
/// ## 为什么是这些筛选、这些参数
///
/// 全部照**本机实测**（`tool/round33_bangumi_probe*.py`，表格见
/// `domain/bangumi_library.dart`）：
/// * 排序只发 `heat`/`score`/`rank`（`date` 在 POST 端点会 **400 sort not supported**）；
/// * 评分下限必须发**字符数组** `[">=7"]`；
/// * 放送形态服务端**没有** platform 参数（加了等于没加），所以用 `tag` 粗筛 +
///   本地按 `platform` 精确筛（`state/bangumi_library.dart` 里做）；
/// * 翻页走查询串，且游标由端口回传 —— 本地过滤会让页与页之间不等长。
///
/// ## 页面结构
///
/// `Column[ 筛选条 · 搜索历史（输入框为空时） · Expanded(结果) ]` —— 与搜索页同构：
/// 外壳给的是 `Expanded`，页面自己管滚动（用户 2026-10-12 第十四轮的教训：
/// 页面里再套一个自带滚动的区域会出现两条滚动条）。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/bangumi.dart';
import '../domain/bangumi_library.dart';
import '../domain/error_text.dart';
import '../state/library_provider.dart';
import '../state/search_history_provider.dart';
import '../theme/motion.dart';
import '../theme/tokens.dart';
import 'library_detail_page.dart';
import 'widgets/cover.dart';
import 'widgets/ds_stagger.dart';
import 'widgets/neo.dart';
import 'widgets/neo_dropdown.dart';
import 'widgets/search_history_bar.dart';
import 'widgets/state_views.dart';

/// 网格几何：与主页海报墙同一套（决策 F22/F23：0.705 真海报比例、卡片宽度封顶）。
const double _gridPad = 18;
const double _gridGap = 16;

/// 卡片里海报之下那一块（标题两行）的高度 + 一点余量。
///
/// ⚠️ 这个余量不是随手加的：海报槽带 1px 描边，`AspectRatio` 拿到的是**减去描边**的宽度，
/// 整块高度 = `w/0.705 − 0.84`，而 `mainAxisExtent` 是拿 `w/0.705` 算的 —— 不留余量时
/// 卡片 Column 会正好差 0.16px 溢出（真机上就是一条黄黑斜纹）。
const double _cardTextHeight = 40;

/// 每列**目标**宽度（只用来决定"排几列"；真正的高度按每列实际宽度算，见 [_evenWidth]）。
const double _maxCardWidth = 168;

class LibraryPage extends ConsumerStatefulWidget {
  const LibraryPage({super.key});

  @override
  ConsumerState<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends ConsumerState<LibraryPage> {
  final TextEditingController _keyword = TextEditingController();

  @override
  void initState() {
    super.initState();
    // 首次进入：把当前筛选条件里的关键词填进输入框（从历史/详情页跳进来时不为空）。
    _keyword.text = ref.read(libraryQueryProvider).keyword;
  }

  @override
  void dispose() {
    _keyword.dispose();
    super.dispose();
  }

  void _submit(String value) {
    final String word = value.trim();
    ref.read(libraryQueryProvider.notifier).submitKeyword(word);
    if (word.isNotEmpty) {
      unawaited(ref
          .read(searchHistoryProvider.notifier)
          .remember(SearchHistoryScope.library, word));
    }
  }

  @override
  Widget build(BuildContext context) {
    final DsTokens t = context.ds;
    final BangumiLibraryQuery query = ref.watch(libraryQueryProvider);
    final LibraryView view = ref.watch(libraryResultsProvider);
    final List<String> history = ref
        .watch(searchHistoryProvider)
        .of(SearchHistoryScope.library);

    // 外部（今日推荐 / 其它页面）改了关键词：输入框跟着走，别让两者各说各话。
    ref.listen<BangumiLibraryQuery>(libraryQueryProvider,
        (BangumiLibraryQuery? previous, BangumiLibraryQuery next) {
      if (next.keyword != _keyword.text) _keyword.text = next.keyword;
    });

    // ⚠️ 第三十四轮（用户：「动漫库缺少6个才填满一页」）：一页的条数必须**跟着列数走**，
    // 否则最后一行必然缺几个 —— 写死 24 条时，1920 窗是 9 列（24 = 2 整行 + 6 条，缺 3），
    // 2048 逻辑宽（2560 屏 @125%）是 10 列（缺 6）。列数只有布局期知道，所以量宽度这一层
    // 放在**最外面**：加载中/错误态也一样量（第一次查询就是在这里发起的，
    // 见 `LibraryResultsController.setPageSize`），这样"进页面"只查一次、尺寸还是对的。
    // 改 provider 状态要排在 build 之后 ⇒ 走 post-frame。
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final int cols = _columnsFor(constraints.maxWidth, _maxCardWidth);
        final double cardWidth = _evenWidth(constraints.maxWidth, cols);
        final int wantSize = libraryPageSize(cols);
        // ⚠️ 条件里必须有 `!view.started`：**第一次查询是这里发起的**，而当量出来的
        // 每页条数恰好等于兜底值（6 列 = 24 条）时"尺寸没变"——只看尺寸就会一次都不发，
        // 页面永远停在加载态（外壳测试 1400 宽 `pumpAndSettle` 收不住就是这个）。
        if (!view.started || wantSize != view.pageSize) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) {
              ref.read(libraryResultsProvider.notifier).setPageSize(wantSize);
            }
          });
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Padding(
              padding: EdgeInsets.fromLTRB(t.spacing, t.spacing, t.spacing, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: TextField(
                          controller: _keyword,
                          textInputAction: TextInputAction.search,
                          style: TextStyle(color: t.text, fontSize: DsTypeScale.body),
                          decoration: InputDecoration(
                            hintText: '搜 Bangumi 条目（留空 = 按下面的条件浏览全库）'
                                '。例如：葬送的芙莉莲',
                            prefixIcon: Icon(Icons.search, size: 15, color: t.text3),
                          ),
                          // 打字时只重建这一层（用来决定"最近搜索"那一行要不要显示）。
                          onChanged: (String _) => setState(() {}),
                          onSubmitted: _submit,
                        ),
                      ),
                      const SizedBox(width: 8),
                      NeoButton(
                        label: '搜索',
                        icon: Icons.search,
                        kind: NeoButtonKind.primary,
                        onPressed: () => _submit(_keyword.text),
                      ),
                      if (!query.isDefault) ...<Widget>[
                        const SizedBox(width: 8),
                        NeoButton(
                          label: '重置',
                          icon: Icons.restart_alt,
                          onPressed: () {
                            _keyword.clear();
                            ref.read(libraryQueryProvider.notifier).reset();
                          },
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 10),
                  _FilterBar(query: query),
                  if (_keyword.text.trim().isEmpty && history.isNotEmpty) ...<Widget>[
                    const SizedBox(height: 8),
                    SearchHistoryBar(
                      keyPrefix: 'library-history',
                      history: history,
                      onPick: (String word) {
                        // 程序化改字不会触发 `onChanged`，要自己重建一次：
                        // 否则"输入框里已经有词了"这个判断不会更新，历史条不消失。
                        setState(() => _keyword.text = word);
                        _submit(word);
                      },
                      onForget: (String word) => unawaited(ref
                          .read(searchHistoryProvider.notifier)
                          .forget(SearchHistoryScope.library, word)),
                      onClear: () => unawaited(ref
                          .read(searchHistoryProvider.notifier)
                          .clear(SearchHistoryScope.library)),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 11),
            Expanded(child: _body(view, cols: cols, cardWidth: cardWidth)),
            SizedBox(height: t.spacing),
          ],
        );
      },
    );
  }

  Widget _body(LibraryView view, {required int cols, required double cardWidth}) {
    if (view.isLoadingFirstPage) return const DsLoading(label: '正在问 Bangumi…');
    if (view.error case final Object error) {
      return DsErrorPanel(
        failure: describeFailure(error),
        onRetry: () => unawaited(ref.read(libraryResultsProvider.notifier).loadFirstPage()),
      );
    }
    if (view.items.isEmpty) {
      return DsEmpty(
        title: '这一档没有条目',
        icon: Icons.travel_explore_outlined,
        message: view.query.isDefault
            ? 'Bangumi 这次没给出条目（网络或站点抖动都可能）。稍后重试，或换个条件。'
            : '条件：${view.query.description}。'
                'Bangumi 的口径比较细：换个年份/季度、把放送形态调回「全部」，'
                '或把评分下限降一档再试。',
        action: NeoButton(
          label: '重置筛选',
          onPressed: () => ref.read(libraryQueryProvider.notifier).reset(),
        ),
      );
    }
    return _results(view, cols: cols, cardWidth: cardWidth);
  }

  Widget _results(LibraryView view, {required int cols, required double cardWidth}) {
    final DsTokens t = context.ds;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(_gridPad, 0, _gridPad, 8),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  '${view.query.description} · ${view.query.sortLabel} · '
                  '共 ${view.total} 部（Bangumi 这个接口最多给到 $kLibraryTotalCap）',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: t.text3, fontSize: DsTypeScale.caption),
                ),
              ),
              if (view.loading)
                Padding(
                  padding: const EdgeInsets.only(right: 10),
                  child: Text(
                    '正在加载…',
                    style: TextStyle(color: t.text3, fontSize: DsTypeScale.caption),
                  ),
                ),
              Text(
                '第 ${view.pageNumber} 页',
                style: TextStyle(
                  color: t.text2,
                  fontSize: DsTypeScale.caption,
                  fontFeatures: DsTokens.tabular,
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: GridView.builder(
            padding: const EdgeInsets.fromLTRB(_gridPad, 0, _gridPad, 8),
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: cols,
              crossAxisSpacing: _gridGap,
              mainAxisSpacing: _gridGap,
              // ⚠️ 高度必须按**每列真实宽度**算：`crossAxisCount` 只是把可用宽度均分，
              // 封顶宽度（168）并不能让每列变窄 —— 拿封顶宽度算高度就会矮一截（overflow）。
              mainAxisExtent: cardWidth / kPosterAspect + _cardTextHeight,
            ),
            itemCount: view.items.length,
            itemBuilder: (BuildContext context, int index) {
              final BangumiSubject subject = view.items[index];
              return DsStaggerFade(
                index: index,
                child: _LibraryCard(
                  subject: subject,
                  onTap: () => openLibraryDetail(context, subject),
                ),
              );
            },
          ),
        ),
        _pager(view),
      ],
    );
  }

  Widget _pager(LibraryView view) {
    final DsTokens t = context.ds;
    final LibraryResultsController controller = ref.read(libraryResultsProvider.notifier);
    return Padding(
      padding: const EdgeInsets.fromLTRB(_gridPad, 2, _gridPad, 6),
      child: Row(
        children: <Widget>[
          NeoButton(
            label: '上一页',
            icon: Icons.chevron_left,
            compact: true,
            onPressed: view.canGoBack && !view.loading
                ? () => unawaited(controller.previousPage())
                : null,
          ),
          const SizedBox(width: 8),
          NeoButton(
            label: '下一页',
            icon: Icons.chevron_right,
            compact: true,
            onPressed: view.canGoForward
                ? () => unawaited(controller.nextPage())
                : null,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              // ⚠️ 第三十四轮：这句话原来写的是「每页条数会略有出入」—— 用户看到的正是
              // "最后一行缺几个"。现在一页 = 列数 × [kLibraryRows]（整行），所以先把
              // 这一页有多少条说清楚；本地精确筛万一凑不满（服务端一次最多 20 条、
              // 形态标签有串味），再照实说明。
              '每页 ${view.pageSize} 条（${view.pageSize ~/ kLibraryRows} 列 × $kLibraryRows 行）'
              '${view.page?.hasMore ?? false ? '；放送形态是本地精确筛的（Bangumi 没这个参数），极少数页可能略少。' : '；已经到底了。'}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: t.text3, fontSize: DsTypeScale.caption),
            ),
          ),
        ],
      ),
    );
  }
}

/// 筛选条：年份 / 季度 / 放送形态 / 排序 / 评分下限。
class _FilterBar extends ConsumerWidget {
  const _FilterBar({required this.query});

  final BangumiLibraryQuery query;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final LibraryQueryController controller = ref.read(libraryQueryProvider.notifier);
    final int thisYear = DateTime.now().year;
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: <Widget>[
        NeoDropdown<int>(
          key: const Key('library-year'),
          label: query.year == null ? '年份：全部' : '年份：${query.year}',
          width: 132,
          tooltip: '按放送日期筛（Bangumi 的 air_date 区间）',
          value: query.year ?? 0,
          items: <NeoDropdownItem<int>>[
            const NeoDropdownItem<int>(0, '全部年份'),
            for (int y = thisYear + 1; y >= 1960; y--)
              NeoDropdownItem<int>(y, '$y 年'),
          ],
          onSelected: (int value) => controller.setYear(value == 0 ? null : value),
        ),
        NeoDropdown<int>(
          key: const Key('library-quarter'),
          label: '季度：${kLibraryQuarterLabels[query.quarter.clamp(0, 4)]}',
          width: 118,
          tooltip: '没有年份时「季度」不起作用（先选年份）',
          value: query.quarter,
          items: <NeoDropdownItem<int>>[
            for (int q = 0; q < kLibraryQuarterLabels.length; q++)
              NeoDropdownItem<int>(q, kLibraryQuarterLabels[q]),
          ],
          onSelected: controller.setQuarter,
        ),
        NeoDropdown<BangumiLibraryForm>(
          key: const Key('library-form'),
          label: '形态：${query.form.label}',
          width: 118,
          tooltip: '服务端只能用标签近似（platform 参数实测被忽略），'
              '这里会再按条目自带的 platform 精确过一遍',
          value: query.form,
          items: <NeoDropdownItem<BangumiLibraryForm>>[
            for (final BangumiLibraryForm form in BangumiLibraryForm.values)
              NeoDropdownItem<BangumiLibraryForm>(form, form.label),
          ],
          onSelected: controller.setForm,
        ),
        NeoDropdown<BangumiLibrarySort>(
          key: const Key('library-sort'),
          label: query.trimmedKeyword.isEmpty
              ? '排序：${query.sort.label}'
              : '排序：相关度',
          width: 118,
          tooltip: '有关键词时按相关度（Bangumi 的 match）；浏览时可选热度/评分/排名',
          value: query.sort,
          items: <NeoDropdownItem<BangumiLibrarySort>>[
            for (final BangumiLibrarySort sort in BangumiLibrarySort.values)
              NeoDropdownItem<BangumiLibrarySort>(sort, sort.label),
          ],
          onSelected: controller.setSort,
        ),
        NeoDropdown<double>(
          key: const Key('library-score'),
          label: query.minScore == null
              ? '评分：不限'
              : '评分：≥${_scoreText(query.minScore!)}',
          width: 122,
          tooltip: '评分下限（Bangumi 的 rating 过滤）',
          value: query.minScore ?? 0,
          items: <NeoDropdownItem<double>>[
            const NeoDropdownItem<double>(0, '不限评分'),
            for (final double score in kLibraryMinScoreChoices)
              NeoDropdownItem<double>(score, '≥${_scoreText(score)} 分'),
          ],
          onSelected: (double value) =>
              controller.setMinScore(value == 0 ? null : value),
        ),
      ],
    );
  }
}

/// 一张库内卡片：海报 + 标题 + 一行「年份 · 评分 · 形态」。
class _LibraryCard extends StatefulWidget {
  const _LibraryCard({required this.subject, required this.onTap});

  final BangumiSubject subject;
  final VoidCallback onTap;

  @override
  State<_LibraryCard> createState() => _LibraryCardState();
}

class _LibraryCardState extends State<_LibraryCard> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final DsTokens t = context.ds;
    final BangumiSubject subject = widget.subject;
    final double dpr = MediaQuery.devicePixelRatioOf(context);
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        key: Key('library-card-${subject.id}'),
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            AnimatedContainer(
              duration: DsMotion.of(context).hover,
              curve: DsMotion.hoverCurve,
              transform: Matrix4.diagonal3Values(
                _hovered ? 1.01 : 1.0,
                _hovered ? 1.01 : 1.0,
                1,
              ),
              transformAlignment: Alignment.center,
              decoration: BoxDecoration(
                color: _hovered ? t.sunken : t.raised,
                borderRadius: BorderRadius.circular(t.radiusControl * 0.67),
                border: Border.all(color: t.line, width: 1),
              ),
              child: AspectRatio(
                aspectRatio: kPosterAspect,
                child: Stack(
                  fit: StackFit.expand,
                  children: <Widget>[
                    // 固定按真海报比例开的槽 → `contain`：任何比例的封面都不裁。
                    DsCover(
                      url: subject.coverUrlAt((160 * dpr).round()),
                      referer: bangumiCoverReferer,
                      fit: kPosterFit,
                    ),
                    if (subject.platform case final String platform
                        when platform.trim().isNotEmpty)
                      Positioned(left: 5, top: 5, child: _Pill(text: platform)),
                    if (subject.score != null && subject.score! > 0)
                      Positioned(
                        right: 5,
                        bottom: 5,
                        child: _Pill(text: '★${subject.score!.toStringAsFixed(1)}'),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 5),
            SizedBox(
              height: 30,
              child: Text(
                subject.displayTitle,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: t.text,
                  fontSize: DsTypeScale.secondary,
                  height: 1.35,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 封面角上的小胶囊（形态 / 评分）——与主页日期 chip 同一套形态。
class _Pill extends StatelessWidget {
  const _Pill({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final DsTokens t = context.ds;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
      decoration: BoxDecoration(
        color: t.base.withValues(alpha: 0.86),
        borderRadius: BorderRadius.circular(t.radiusPill),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: t.text2,
          fontSize: DsTypeScale.caption * 0.92,
          fontFeatures: DsTokens.tabular,
        ),
      ),
    );
  }
}

/// 每列的真实宽度（可用宽度均分）。
double _evenWidth(double maxWidth, int cols) {
  final double avail = maxWidth - _gridPad * 2;
  if (cols <= 1) return avail;
  final double even = (avail - _gridGap * (cols - 1)) / cols;
  return even < 1 ? 1 : even;
}

/// 列数由可用宽度决定（`repeat(auto-fill, Npx)` 的等价物）。
int _columnsFor(double maxWidth, double cardWidth) {
  final double avail = maxWidth - _gridPad * 2;
  final int cols = ((avail + _gridGap) / (cardWidth + _gridGap)).floor();
  return cols < 1 ? 1 : cols;
}

String _scoreText(double score) =>
    score == score.roundToDouble() ? score.toStringAsFixed(0) : score.toStringAsFixed(1);
