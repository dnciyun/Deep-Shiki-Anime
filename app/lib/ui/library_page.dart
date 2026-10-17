/// 「动漫库」（第三十三轮）：调 Bangumi 全库，带筛选浏览 + 关键词搜索。
///
/// 用户原话（第三十三轮）：「添加新页面，名为动漫库，调用bangumi，有筛选，详细可通过问答」+
/// 问答里选定的能力：类型/放送形态、年份、季度、排序（热度·评分·排名）、标签（用条目
/// 自带的标签区点着筛）、评分下限、关键词搜索、点开详情、详情里能搜种子/加入追番；
/// 入口「排在主页下面」。
/// 用户原话（第四十四轮）：「优化动漫库，把搜索与筛选移到右侧，并加入类型的筛选，
/// 比如异世界 玄幻 校园这些」——**本文件当前的结构就是这一版**。
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
/// ## 第四十四轮：为什么整页翻成「左边结果 · 右边筛选」
///
/// 旧版面是 `Column[ 筛选条 · 历史 · Expanded(结果) ]`：一整条筛选条压在结果**上面**，
/// 于是 1920 窗里那行控件折成三排、又高又散，抬头行被挤成一条，网格顶部还跟着筛选条
/// 的折行数上下跳（改一个条件整片结果位移几十像素）。
///
/// 现在改成 `Row[ Expanded(结果) · 右栏(搜索 + 类型 + 其它筛选) ]`：
/// * 结果区独占左半边，抬头行一整行都是它自己的，网格从第一像素起就是稳定的；
/// * 右栏是**筛选面板**的形状（与 bangumi / 各类图库站一致）：搜索框在最上、类型胶囊
///   在中、年份等下拉在最后，整栏自己是 `SingleChildScrollView`（窗口矮的时候它滚，
///   **不动结果区**）；
/// * 右栏那一列与左栏顶部对齐，右缘与网格的右内边距对齐（[_gridPad]），
///   窗宽不够时左栏先瘦（列数由左栏宽度算 —— 见下面那段 LayoutBuilder 的注释）。
///
/// 布局的测量点也随之搬了：**列数按左栏宽度算**（不是整窗宽），所以"一页 = 列数 ×
/// [kLibraryRows]"这条规矩在窄了 248+px 之后仍然成立（不然末行又会缺几个）。
///
/// ## 第五十轮：番名为什么会被切掉半行 / 卡片右上角为什么多一颗 ♥
///
/// 用户原话（第五十轮）：「名字过长就会出现显示不全的问题，然后动漫库右上角应该加个
/// 订阅按钮同主页的那样」；问答里选定的是「动漫库每张海报卡的右上角：悬停出现 ♥（追番），
/// 和主页海报卡一样」，并且「名字显示不全」点名了**动漫库网格卡 + 主页今日更新卡**两处。
///
/// * **被切掉半行不是省略号**：番名区原来是 `SizedBox(height: 30)`，而 14 号字 × 1.35 = 18.9
///   ⇒ `TextPainter` 实测 **一行 19px、两行 38px**（字体度量取整，不是 37.8）—— 盒子只有 30
///   ⇒ 第二行**被切掉半截**（出图 `build/probe-cards/library_1400_before.png`；修复后
///   `library_1400_after.png`）。现在 [kLibraryCardTitleHeight] = 38，两行整行看得见；
///   再长的名字（>2 行）收成省略号，**鼠标停在标题上**看完整番名（`Tooltip`）。
/// * 卡片右上角那颗 ♥ 与主页海报卡是**同一个** `FollowButton(compact: true)`：悬停出现、
///   已追的常驻（不悬停也不挤封面角）。点了只写本地追番标记，**不建订阅、不下载**
///   （spec §7.6 的口径没变）。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/bangumi.dart';
import '../domain/bangumi_library.dart';
import '../domain/error_text.dart';
import '../domain/following_store.dart';
import '../state/following_provider.dart';
import '../state/library_provider.dart';
import '../state/search_history_provider.dart';
import '../theme/motion.dart';
import '../theme/tokens.dart';
import 'library_detail_page.dart';
import 'widgets/cover.dart';
import 'widgets/ds_stagger.dart';
import 'widgets/follow_button.dart';
import 'widgets/neo.dart';
import 'widgets/neo_dropdown.dart';
import 'widgets/search_history_bar.dart';
import 'widgets/state_views.dart';

/// 网格几何：与主页海报墙同一套（决策 F22/F23：0.705 真海报比例、卡片宽度封顶）。
const double _gridPad = 18;
const double _gridGap = 16;

/// 右栏**内容**宽度（第四十四轮）。
///
/// 248 是量出来的：类型胶囊里最长的是三个汉字（「异世界」），NeoPill 左右各 10 内边距
/// ⇒ 一颗约 62 宽 ⇒ 一行三颗还有余量；两列下拉（每格 116 + 间距 12 = 244）也正好落在里面。
/// 再宽就只是让结果区变窄（列数少一列 = 一页少 4 条）。
const double kLibraryRailWidth = 248;

/// 右栏里每一格下拉的宽度（两格 + 间距 = 244 ≤ 248）。
const double _railFieldWidth = 116;

/// 结果区与右栏之间的间距。
const double _railGap = 8;

/// 整页上内边距（右栏的搜索框与左栏的抬头行都从这条线起）。
const double _pageTop = 10;

/// 番名区：**两行**（第五十轮；用户点名「名字过长就会出现显示不全」）。
///
/// ⚠️ 行高**不是** 14 × 1.35 = 18.9：真字体（微软雅黑）的度量会取整到 **19px**
/// （`TextPainter` 实测，探针 `test/card_title_probe.dart`）—— 所以两行要 **38**，
/// 不是 37.8。盒子给 30（旧值）时第二行会被切掉半截，看着像"名字显示不全"。
const int kLibraryCardTitleLines = 2;
const double kLibraryCardTitleHeight = 38;

/// 卡片里海报之下那一块：5（间距）+ 番名区两行 38。
///
/// ⚠️ 这个余量不是随手加的：海报槽带 1px 描边，`AspectRatio` 拿到的是**减去描边**的宽度，
/// 整块高度 = `w/0.705 − 0.84`，而 `mainAxisExtent` 是拿 `w/0.705` 算的 —— 不留余量时
/// 卡片 Column 会正好差 0.16px 溢出（真机上就是一条黄黑斜纹）。
/// 第五十轮：番名区 30 → [kLibraryCardTitleHeight]，末尾余量仍是原来的 5（总高 40 → 48）。
const double _cardTextHeight = 5 + kLibraryCardTitleHeight + 5;

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

  /// 「重置」：输入框与筛选条件一起回到默认（全部动画）。
  void _reset() {
    _keyword.clear();
    ref.read(libraryQueryProvider.notifier).reset();
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

    return Padding(
      padding: EdgeInsets.only(top: _pageTop, bottom: t.spacing),
      // 右栏宽度按窗口收一档：Windows 侧**没有设最小窗口尺寸**，用户可以把窗口拖得很窄，
      // 而"固定 266 + 结果区"这种排法在窄到 274 以下时整行就会撑出边界（黄黑斜纹）。
      // 900 以下才收（0.38 × 900 = 342 ⇒ 已经被上限夹住，所以 900…700 之间其实没变），
      // 收到底 180（内容 162）也仍然放得下 116 宽的下拉格。
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints page) {
          final double railWidth = page.maxWidth < 900
              ? (page.maxWidth * 0.38).clamp(180.0, kLibraryRailWidth + _gridPad)
              : kLibraryRailWidth + _gridPad;
          return Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              // ⚠️ 第三十四轮（用户：「动漫库缺少6个才填满一页」）+ 第四十四轮（筛选挪到右栏）：
              // 一页的条数必须**跟着列数走**，否则最后一行必然缺几个 —— 而列数只有布局期才知道。
              // 第四十四轮之后"可用宽度"是**左栏**的宽度（右栏占掉 248 + 24），所以量宽这一层
              // 必须留在左栏**里面**：放到 Row 外面量到的是整窗，列数会多算一列 ⇒ 末行缺 4 个。
              // 加载中/错误态也一样量（第一次查询就是在这里发起的，见
              // `LibraryResultsController.setPageSize`），这样"进页面"只查一次、尺寸还是对的。
              // 改 provider 状态要排在 build 之后 ⇒ 走 post-frame。
              Expanded(
                child: LayoutBuilder(
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
                    return _body(view, cols: cols, cardWidth: cardWidth);
                  },
                ),
              ),
              const SizedBox(width: _railGap),
              SizedBox(
                width: railWidth,
                child: Padding(
                  padding: const EdgeInsets.only(right: _gridPad),
                  child: _rail(query, history),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  // ── 右栏：搜索 + 类型 + 其它筛选（第四十四轮）────────────────────────────────

  /// 右栏整体（用户：「把搜索与筛选移到右侧」）。
  ///
  /// 自己是可滚的：矮窗口（720 默认窗高）里 33 颗类型胶囊 + 5 格下拉放不下，
  /// 让**这一栏**滚而不是让整页滚/挤 —— 结果区的滚动条与它互不影响。
  Widget _rail(BangumiLibraryQuery query, List<String> history) {
    final bool showHistory = _keyword.text.trim().isEmpty && history.isNotEmpty;
    return SingleChildScrollView(
      key: const Key('library-rail'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _searchBlock(query),
          if (showHistory) ...<Widget>[
            const SizedBox(height: 16),
            _railLabel('最近搜索'),
            const SizedBox(height: 6),
            SearchHistoryBar(
              keyPrefix: 'library-history',
              // 右栏自己已经有一行「最近搜索」小标题了：条里那半截标签在 248 宽里
              // 会把胶囊挤成"每行一颗"（旧版面是通栏的，不觉得）。
              showLabel: false,
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
          const SizedBox(height: 18),
          _genreBlock(query),
          const SizedBox(height: 18),
          _filterBlock(query),
        ],
      ),
    );
  }

  /// 搜索框 + 搜索/重置。
  Widget _searchBlock(BangumiLibraryQuery query) {
    final DsTokens t = context.ds;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        TextField(
          key: const Key('library-search-field'),
          controller: _keyword,
          textInputAction: TextInputAction.search,
          style: TextStyle(color: t.text, fontSize: DsTypeScale.body),
          decoration: InputDecoration(
            // 右栏只有 248 宽：旧提示（「搜 Bangumi 条目（留空 = 按下面的条件浏览全库）。
            // 例如：葬送的芙莉莲」）在这儿被截成「…葬送的芙莉…」（出图量过：248 − 左图标
            // 44 − 内边距 24 = 180px ≈ 12 个汉字）。说不完的就别写
            //（第三十六轮同一条教训）；「留空 = 浏览全库」那半句挪到了下面一行。
            hintText: '搜条目，例如：芙莉莲',
            prefixIcon: Icon(Icons.search, size: 15, color: t.text3),
          ),
          // 打字时只重建这一层（用来决定"最近搜索"那一块要不要显示）。
          onChanged: (String _) => setState(() {}),
          onSubmitted: _submit,
        ),
        const SizedBox(height: 8),
        Row(
          children: <Widget>[
            Expanded(
              child: NeoButton(
                label: '搜索',
                icon: Icons.search,
                kind: NeoButtonKind.primary,
                expand: true,
                onPressed: () => _submit(_keyword.text),
              ),
            ),
            if (!query.isDefault) ...<Widget>[
              const SizedBox(width: 8),
              NeoButton(
                label: '重置',
                icon: Icons.restart_alt,
                tooltip: '清空关键词与全部筛选条件',
                onPressed: _reset,
              ),
            ],
          ],
        ),
        const SizedBox(height: 6),
        Text(
          // 把"当前这一档是什么"写在这儿：右栏的每颗控件只显示自己那一格的值，
          // 而结果抬头上那行（`view.query.description`）才是完整的条件串。
          '留空搜索框 = 按下面的条件浏览全库',
          style: TextStyle(color: t.text3, fontSize: DsTypeScale.caption),
        ),
      ],
    );
  }

  /// 类型（= Bangumi 的用户标签，清单见 [kLibraryGenreTags]）。
  ///
  /// 单选：点一下筛这一档、再点一下取消（点「全部」也一样）。清单外的标签
  /// （从条目详情页的标签点进来的，如「公路片」）会**补一颗胶囊显示出来** ——
  /// 否则结果被筛过、右栏却看不到是哪一条在起作用。
  Widget _genreBlock(BangumiLibraryQuery query) {
    final LibraryQueryController controller = ref.read(libraryQueryProvider.notifier);
    final String? tag = (query.tag ?? '').trim().isEmpty ? null : query.tag!.trim();
    final List<String> genres = <String>[
      ...kLibraryGenreTags,
      if (tag != null && !isLibraryGenre(tag)) tag,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        _railLabel('类型'),
        const SizedBox(height: 7),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: <Widget>[
            NeoPill(
              key: const Key('library-genre-all'),
              label: '全部',
              selected: tag == null,
              tooltip: '不按类型筛',
              onTap: () => controller.setTag(null),
            ),
            for (final String genre in genres)
              NeoPill(
                key: Key('library-genre-$genre'),
                label: genre,
                selected: genre == tag,
                tooltip: genre == tag
                    ? '再点一下取消（回到全部类型）'
                    : isLibraryGenre(genre)
                        ? '按「$genre」筛（Bangumi 的用户标签）'
                        : '从条目详情页的标签点进来的（不在推荐类型里）',
                onTap: () => controller.toggleTag(genre),
              ),
          ],
        ),
      ],
    );
  }

  /// 年份 / 季度 / 放送形态 / 排序 / 评分下限 —— 两列，每格"小标题 + 下拉"。
  Widget _filterBlock(BangumiLibraryQuery query) {
    final LibraryQueryController controller = ref.read(libraryQueryProvider.notifier);
    final int thisYear = DateTime.now().year;
    return Wrap(
      spacing: 12,
      runSpacing: 12,
      children: <Widget>[
        _railField(
          '年份',
          NeoDropdown<int>(
            key: const Key('library-year'),
            // 小标题已经在上面一行了，触发器里只留**值**（旧版是「年份：全部」，
            // 118 宽装不下「年份：2024 年」这种长值，会被省略号截掉）。
            label: query.year == null ? '全部' : '${query.year} 年',
            width: _railFieldWidth,
            tooltip: '按放送日期筛（Bangumi 的 air_date 区间）',
            value: query.year ?? 0,
            items: <NeoDropdownItem<int>>[
              const NeoDropdownItem<int>(0, '全部年份'),
              for (int y = thisYear + 1; y >= 1960; y--)
                NeoDropdownItem<int>(y, '$y 年'),
            ],
            onSelected: (int value) => controller.setYear(value == 0 ? null : value),
          ),
        ),
        _railField(
          '季度',
          NeoDropdown<int>(
            key: const Key('library-quarter'),
            label: kLibraryQuarterLabels[query.quarter.clamp(0, 4)],
            width: _railFieldWidth,
            tooltip: '没有年份时「季度」不起作用（先选年份）',
            value: query.quarter,
            items: <NeoDropdownItem<int>>[
              for (int q = 0; q < kLibraryQuarterLabels.length; q++)
                NeoDropdownItem<int>(q, kLibraryQuarterLabels[q]),
            ],
            onSelected: controller.setQuarter,
          ),
        ),
        _railField(
          '放送形态',
          NeoDropdown<BangumiLibraryForm>(
            key: const Key('library-form'),
            label: query.form.label,
            width: _railFieldWidth,
            tooltip: '服务端只能用标签近似（platform 参数实测被忽略），'
                '这里会再按条目自带的 platform 精确过一遍',
            value: query.form,
            items: <NeoDropdownItem<BangumiLibraryForm>>[
              for (final BangumiLibraryForm form in BangumiLibraryForm.values)
                NeoDropdownItem<BangumiLibraryForm>(form, form.label),
            ],
            onSelected: controller.setForm,
          ),
        ),
        _railField(
          '排序',
          NeoDropdown<BangumiLibrarySort>(
            key: const Key('library-sort'),
            label: query.trimmedKeyword.isEmpty ? query.sort.label : '相关度',
            width: _railFieldWidth,
            tooltip: '有关键词时按相关度（Bangumi 的 match）；浏览时可选热度/评分/排名',
            value: query.sort,
            items: <NeoDropdownItem<BangumiLibrarySort>>[
              for (final BangumiLibrarySort sort in BangumiLibrarySort.values)
                NeoDropdownItem<BangumiLibrarySort>(sort, sort.label),
            ],
            onSelected: controller.setSort,
          ),
        ),
        _railField(
          '评分下限',
          NeoDropdown<double>(
            key: const Key('library-score'),
            label: query.minScore == null ? '不限' : '≥${_scoreText(query.minScore!)} 分',
            width: _railFieldWidth,
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
        ),
      ],
    );
  }

  /// 右栏的一小段标题（「类型」「最近搜索」）。
  Widget _railLabel(String text) {
    final DsTokens t = context.ds;
    return Text(
      text,
      style: TextStyle(
        color: t.text3,
        fontSize: DsTypeScale.caption,
        fontWeight: FontWeight.w600,
        letterSpacing: DsTypeScale.caption * 0.08,
      ),
    );
  }

  /// 一格「小标题 + 下拉」。
  Widget _railField(String caption, Widget dropdown) => SizedBox(
        width: _railFieldWidth,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            _railLabel(caption),
            const SizedBox(height: 5),
            dropdown,
          ],
        ),
      );

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
                'Bangumi 的口径比较细：换个年份/季度、把放送形态调回「全部」、'
                '换一个类型、或把评分下限降一档再试。',
        action: NeoButton(
          label: '重置筛选',
          onPressed: _reset,
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
            // 第四十二轮 UX #38：「上一页」有 `!view.loading` 门禁，这一颗漏了 ——
            // 在途请求期间点它会被 `nextPage()` 里的闸门**静默吃掉**（按钮看着能点、
            // 点了没反应）。两颗按钮的可用条件必须一致。
            onPressed: view.canGoForward && !view.loading
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

/// 一张库内卡片：海报 + 番名两行（悬停看全名）+ 封面右上角的追番 ♥（第五十轮）。
class _LibraryCard extends ConsumerStatefulWidget {
  const _LibraryCard({required this.subject, required this.onTap});

  final BangumiSubject subject;
  final VoidCallback onTap;

  @override
  ConsumerState<_LibraryCard> createState() => _LibraryCardState();
}

class _LibraryCardState extends ConsumerState<_LibraryCard> {
  bool _hovered = false;

  /// 追番记录（id 走 `followingIdFor` 的 bgm 段：`bgm:<Bangumi 条目 id>`）。
  ///
  /// 与动漫库详细页 `_actions` 里那颗 `FollowButton` 用的是**同一条**记录 —— 在卡片上追了，
  /// 点进详情页看到的就是「已追」，两边不会各记一份。
  FollowingEntry get _followEntry => followingEntryFromBangumi(widget.subject);

  /// 已追的卡在**不悬停**时也把那颗 ♥ 留在角上（与主页海报卡同一条规矩）。
  bool get _followed => ref
      .watch(followingProvider)
      .any((FollowingEntry e) => e.id == _followEntry.id);

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
                    // 第五十轮（用户：「动漫库右上角应该加个订阅按钮同主页的那样」）：
                    // 与主页海报卡同一颗 `FollowButton(compact: true)` —— 悬停出现、
                    // 已追的常驻。点击在按钮自己的命中区里吃掉，不会连带打开详情页。
                    if (_hovered || _followed)
                      Positioned(
                        right: 5,
                        top: 5,
                        child: FollowButton(entry: _followEntry, compact: true),
                      ),
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
            // 第五十轮：**两行整行**看得见（盒子 = 两行 38，不是旧值的 30）；
            // 超过两行的名字收省略号，鼠标停在标题上看完整番名。
            Tooltip(
              message: subject.displayTitle,
              child: SizedBox(
                height: kLibraryCardTitleHeight,
                child: Text(
                  subject.displayTitle,
                  maxLines: kLibraryCardTitleLines,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: t.text,
                    fontSize: DsTypeScale.secondary,
                    height: 1.35,
                  ),
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
