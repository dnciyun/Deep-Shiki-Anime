/// 主页（spec §7.5 + §7.7，设计基线 `docs/theme-preview/shots/home_A_acc_1.png`）。
///
/// **三层结构**（用户 2026-10-12 第十一轮：删掉顶栏那一行）：
/// ```
/// ① 今日推荐 今日推荐                                          (⤨)
///            [148×197 ×5]   ← 全局内容，跟星期几无关
/// ② 更新区头 今日更新  周一 周二 周三 … 周日 剧场版 OVA          (⟳)
/// ③ 当日网格 [208 大图封面 ×N]
/// ```
/// * 原来最上面还有一行顶栏（`今晚想看点什么` + 同一行的「刷新」按钮）；
///   用户第十一轮要求**整行删掉**，「刷新」挪到**星期切换旁边**（更新区头行内）。
/// * ⚠️ 星期切换**只作用于「今日更新」这一块**（放在更新区头行内），
///   既不是页面级筛选器，也不影响推荐。
///
/// ⚠️ **2026-10-14 第二十八轮**（用户原话：「主页日期改成，在今日更新旁边一排
/// 周一到周日+剧场版+ova，细体淡色；优化刷新和换一批，改为圆形按钮，仅保留矢量图，
/// 去除文字」）：
/// * 星期切换从**下拉**改回**一排**：`周一…周日 + 剧场版 + OVA` 共 9 项，
///   细体淡色（caption 字号 + w300 + 三级色），选中项走强调色 —— 见 [_DayTabItem]。
/// * 「刷新」与「换一批」各自成了 [NeoCircleButton]：**只有矢量图，没有文字**，
///   原来写在按钮上的字改由 tooltip 承载。
///
/// ⚠️ **第五十轮**（用户：「名字过长就会出现显示不全的问题，然后动漫库右上角应该加个
/// 订阅按钮同主页的那样」）：海报卡下面那行番名原来装在 32px 高的盒子里，而两行字实际
/// 要 **38px**（14 × 1.35，真字体度量取整到 19/行）—— 长番名第二行被**切掉半截**。
/// 现在 [kHomeCardTitleHeight] = 38（两行整行看得见），再长的悬停标题看全名；
/// 卡片总高 [kHomeCardTextHeight] 不变。
///
/// ⚠️ **第五十二轮**（用户 2026-10-17 原话：「整个项目太素」）：给主页加「标识色相」。
/// 主页的身份色 = **橙**（[DsHue.orange]），颜色只用来编码信息、不做装饰：
/// * 区头 = 3px 色相竖条 + `hueInk` 标题（[今日推荐] 用橙；[今日更新] 跟着**选中的那天**走，
///   与星期切换那一项同色 —— 切星期时标题颜色本身就在说明"现在看的是哪一天"）；
/// * 星期切换每一格一个色相（[hueOfWeekday]，剧场版紫 / OVA 靛），选中/悬停走该色相的
///   18% 淡底 + 色相 ink；
/// * 封面角标/日期/评分小胶囊按语义上色：今日更新 = emerald、已缓存 = blue、
///   已订阅 = pink（侧栏「正在追」的身份色）、更新日期 = emerald、评分 = gold；
/// * 空态统一 [DsEmpty] + 橙。颜色只从 `context.ds` 的 hue API 取，不写任何颜色字面量。
///
/// 三条硬约束：
/// 1. 星期切换**不重新拉数据**（一次 `schedule()` 拿全周）；
/// 2. 首页条目**没有磁力**：点卡片进番剧详情，再由剧集入队播放，不硬凑可播项；
/// 3. 封面尺寸固定 + 列数由可用宽度决定（等价 CSS `repeat(auto-fill, Npx)`），
///    **不按条目数算列数**（那会把 8 部排成 7+1 的孤儿行）。
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/bangumi.dart';
import '../domain/error_text.dart';
import '../domain/following_store.dart';
import '../domain/models.dart';
import '../domain/title_match.dart';
import '../state/carousel_provider.dart';
import '../state/providers.dart';
import '../theme/motion.dart';
import '../theme/tokens.dart';
import 'bangumi_detail.dart';
import 'library_detail_page.dart';
import 'widgets/cover.dart';
import 'widgets/ds_carousel.dart';
import 'widgets/ds_stagger.dart';
import 'widgets/follow_button.dart';
import 'widgets/hues.dart';
import 'widgets/neo.dart';
import 'widgets/state_views.dart';

// ─────────────────────────────────────────────────────────────────────────────
// 尺寸常量（直接抄 `docs/theme-preview/build_home.py` 的 CSS 值）
// ─────────────────────────────────────────────────────────────────────────────

/// 卡片间距（CSS `gap:14px`）。
const double kHomeGridGap = 14;

/// 封面下的文字块高度（卡片总高 = 封面高 + 它）。
///
/// ⚠️ 现在的卡片文字块只有「6(间距) + 番名两行 38」= 44，[kHomeCardTextHeight] 56 是
/// **留了 12 的余量**。对外保持 56 不动：第三十四轮起"一页 = 列数 × 行数"、封面高度都
/// 按它算（`home_page_test` 也拿它反推封面高）。第五十轮只把番名盒子 32 → 38
/// （见 [kHomeCardTitleHeight]），那点余量正好装得下，卡片总高不变。
const double kHomeCardTextHeight = 56;

/// 番名区高度（第五十轮）：**两行**，一行 19px。
///
/// 用户原话（第五十轮）：「名字过长就会出现显示不全的问题，然后动漫库右上角应该加个
/// 订阅按钮同主页的那样」—— 问答里点名了**主页今日更新**也中招。原来是 32：14 号字 ×
/// 1.35 = 18.9 ⇒ `TextPainter` 实测一行 **19**、两行 **38** —— 32 装不下第二行，
/// 长番名**被切掉半截**（探针出图 `build/probe-cards/home_1600_before.png`）。
/// 超过两行的名字收省略号，鼠标停在番名上看完整名字（`Tooltip`，第五十轮加的）。
const double kHomeCardTitleHeight = 38;

/// 内容区左右内边距（CSS `padding: … 18px`）。
const double kHomeGridPadding = 18;

/// 推荐卡：148×197 竖版 3:4 封面（spec §7.7）。
const double kRecommendCardWidth = 148;
const double kRecommendCoverHeight = 197;
const double kRecommendGap = 12;

/// 当天封面的**目标宽度上限**。
///
/// 用户 2026-10-10 第 4–20 轮清单：固定一档，不再按当天部数在三档里跳
/// （244/272/300 会让逐日翻看时尺寸在跳）。
///
/// 用户 2026-10-11：「今日更新里的图太大了」。上一版固定 272 只决定了**列数**，
/// 而卡片宽度是按可用宽度**均分**出来的 —— 窗口一宽、或当天部数少导致列数少，
/// 封面就被撑到 400–500。所以现在这个值同时是**上限**：均分结果超过它就封顶，
/// 整行左对齐留白（见 [_DayGrid] 里的 `math.min`）。
const double kHomeCoverMaxWidth = 208;

/// 当天封面尺寸（固定一档；真实宽度 = min(均分宽度, [kHomeCoverMaxWidth])）。
double coverSizeForDay(int count) => kHomeCoverMaxWidth;

/// 更新区头那一排的**日序**：`周一…周日` + mikan 的两个专档（7 = 剧场版、8 = OVA）。
///
/// ⚠️ 2026-10-14 第二十八轮：这一排是**固定 9 项**（用户点名「周一到周日+剧场版+OVA」）。
/// 改版前 7/8 只在"当天有内容"时才出现在下拉里 —— 现在它们照站点口径常驻，
/// 点开没有内容时给的是空态文案（「剧场版没有更新的番剧」），不是一条假数据。
const List<int> kHomeDayTabs = <int>[1, 2, 3, 4, 5, 6, 0, 7, 8];

/// 「今日更新」这一排每一项的色相（第五十二轮）：周一…周日走 [hueOfWeekday] 的色环，
/// mikan 的两个专档按 `hues.dart` 的标签色 —— **剧场版 = 紫、OVA = 靛**。
///
/// ⚠️ mikan 的星期键是 `0 = 周日 … 6 = 周六`（见 [dsWeekdayLabel]），而 [hueOfWeekday]
/// 的入参是 `0 = 周一` —— 差一天，必须换算；不能把 dow 直接塞进去（否则周日会拿到周一的
/// 蓝色、往后全错一格）。
///
/// 纯函数（可单测）：`hueForDayTab(3)` = 周三 = teal、`hueForDayTab(4)` = 周四 = emerald。
DsHue hueForDayTab(int dow) => switch (dow) {
      0 => hueOfWeekday(6), // 周日 = 色环最后一格（粉）
      7 => DsHue.violet, // 剧场版
      8 => DsHue.indigo, // OVA
      _ => hueOfWeekday(dow - 1), // 周一 = 0 … 周六 = 5
    };

class HomePage extends ConsumerWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<ScheduleView> async = ref.watch(scheduleProvider);
    final ScheduleView? view = async.value;
    // ⚠️ 第二十五轮（用户）：「把今日推荐和今日更新做成一体的」—— 整页**一条**滚动条，
    // 推荐跟着一起往上滚（滚出屏幕后不再占位置；问答选定的是这一档，而不是"推荐钉住
    // 只有网格滚动"）。做法：一个 [CustomScrollView]，推荐区 / 更新区头 / 网格全是它的
    // sliver —— 网格**不再自带滚动**，否则页里会套出两条滚动条。
    //
    // 列数/卡片宽度仍然由**可用宽度**算（不是按条目数硬算列数）：宽度在 CustomScrollView
    // 之上拿不到，所以这里多一层 [LayoutBuilder]。
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        // 封面宽度封顶来自设置页「封面大小」（决策 F23）；列数仍按可用宽度算。
        final double cap = ref.watch(homeCoverSizeProvider).maxWidth;
        final double cardWidth = homeCardWidthFor(constraints.maxWidth, cap);
        final int cols = homeGridColumns(constraints.maxWidth, cardWidth);
        // 网格自身宽度 = 刚好放下 cols 张卡；右边留白（而不是把卡片撑宽）——
        // 与改造前 `Align(left) + SizedBox(gridWidth)` 的效果完全一致，只是改成
        // 由 sliver 的右内边距表达。
        final double gridWidth = cardWidth * cols + kHomeGridGap * (cols - 1);
        final double rightPad = math.max(
          kHomeGridPadding,
          constraints.maxWidth - kHomeGridPadding - gridWidth,
        );
        return CustomScrollView(
          slivers: <Widget>[
            // ① 今日推荐：全局内容，页面最上面（顶栏已按用户第十一轮要求整行删除）
            const SliverToBoxAdapter(child: _RecommendRail()),
            // ② 今日更新 区头（行内：星期切换 + 刷新）
            SliverToBoxAdapter(child: _UpdateHeader(view: view)),
            ..._body(ref, async, view, cols: cols, cardWidth: cardWidth, rightPad: rightPad),
          ],
        );
      },
    );
  }

  /// 页面下半部分：能用就给网格，不能用就给能读懂的说明（都是 sliver）。
  List<Widget> _body(
    WidgetRef ref,
    AsyncValue<ScheduleView> async,
    ScheduleView? view, {
    required int cols,
    required double cardWidth,
    required double rightPad,
  }) {
    if (view == null) {
      if (async.isLoading) {
        return <Widget>[
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(kHomeGridPadding, 18, kHomeGridPadding, 12),
              child: const DsLoading(label: '正在从 mikan 拉取追番表…'),
            ),
          ),
        ];
      }
      return <Widget>[
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(kHomeGridPadding, 6, kHomeGridPadding, 12),
            child: DsErrorPanel(
              failure: describeFailure(async.error ?? '追番表拉取失败'),
              title: '追番表拉取失败',
              onRetry: () => ref.invalidate(scheduleProvider),
            ),
          ),
        ),
      ];
    }
    if (view.total == 0) {
      // 0 条不是「今天没更新」——那是站点没给数据，必须说实话。
      // 第五十二轮：空态走 [DsEmpty] 并带上主页身份色（橙），图标圆盘不再是全灰。
      return const <Widget>[
        SliverToBoxAdapter(
          child: DsEmpty(
            title: '追番表是空的',
            icon: Icons.cloud_off_outlined,
            hue: DsHue.orange,
            message:
                'mikan 追番表返回了 0 条番剧。可以点「刷新」立即重试；'
                '若一直为空，多半是站点结构变了（core 的 mikan_schedule 解析器需要更新）。',
          ),
        ),
      ];
    }
    return <Widget>[_UpdateGrid(view: view, cols: cols, cardWidth: cardWidth, rightPad: rightPad)];
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// ③ 当天的大图封面网格（1.1.0 M1/T2：从 HomePage.build 里抽成独立 ConsumerWidget）
// ─────────────────────────────────────────────────────────────────────────────

/// 「今日更新」的封面网格（一个 [SliverGrid]，接在推荐区与更新区头下面）。
///
/// **为什么抽成独立 widget**（1.1.0 M1/T2）：它 watch 的都是**会单独变化**的数据源 ——
/// 引擎快照（2Hz）、订阅表、追番表。以前这堆 watch 写在 `HomePage.build` 调用的
/// `_grid()` 方法里，等于每次引擎一帧就重建**整页**（推荐轮播 + 区头 + 八张卡）。
/// 抽出来之后，引擎帧最多只惊动这一块（而且名字集合没变时连这一块都不重建，
/// 见 `cachedNormalizedTorrentNamesProvider`）。
class _UpdateGrid extends ConsumerWidget {
  const _UpdateGrid({
    required this.view,
    required this.cols,
    required this.cardWidth,
    required this.rightPad,
  });

  final ScheduleView view;
  final int cols;
  final double cardWidth;
  final double rightPad;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final int selected = ref.watch(selectedDayProvider);
    final int today = ref.watch(todayDowProvider);
    final DateTime now = ref.watch(todayProvider);
    final List<ScheduleEntryView> items = view.day(selected);
    if (items.isEmpty) {
      // 第五十二轮：空态带主页身份色（橙）—— 图标圆盘 + 色相图标，不再是全灰一句话。
      return SliverToBoxAdapter(
        child: DsEmpty(
          title: '这一档没有更新',
          icon: Icons.event_busy_outlined,
          hue: DsHue.orange,
          message: homeEmptyText(selected, today),
        ),
      );
    }

    // 「已缓存」/「已订阅」角标的真实依据：引擎里已下完的 torrent 名 + 本机订阅名。
    // 缓存名走**归一化集合**（M1/T2）：引擎帧不会把它抖成新值，归一化也只做一次。
    final List<String> cachedNames = ref.watch(cachedNormalizedTorrentNamesProvider);
    final List<SubscriptionView> subs =
        ref.watch(subscriptionsProvider).value ?? const <SubscriptionView>[];
    // 追番状态在这一层算成 id 集合，卡片只收一个 bool —— 以前是**每张卡**各 watch 一遍
    // `followingProvider`，追番一次变更就有 N 个订阅者各重建一次。
    final Set<String> followedIds = <String>{
      for (final FollowingEntry e in ref.watch(followingProvider)) e.id,
    };

    return SliverPadding(
      padding: EdgeInsets.fromLTRB(kHomeGridPadding, 14, rightPad, 16),
      sliver: SliverGrid(
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: cols,
          crossAxisSpacing: kHomeGridGap,
          mainAxisSpacing: kHomeGridGap,
          // 绝对高度：封面按**真海报比例**（决策 F22：0.705，高 = 宽 ÷ 0.705），
          // 不再是正方框（正方会把竖版海报裁掉约 30%）。
          mainAxisExtent: cardWidth / kPosterAspect + kHomeCardTextHeight,
        ),
        delegate: SliverChildBuilderDelegate(
          (BuildContext context, int index) {
            final ScheduleEntryView entry = items[index];
            // 首屏逐次淡入（决策 F12：20ms 错峰、最多 6 项，其余直接显示）。
            return DsStaggerFade(
              index: index,
              child: _PosterCard(
                entry: entry,
                badge: scheduleBadgeFor(
                  entry: entry,
                  // 「今日更新」= mikan 给的更新日期就是今天（真的更了新一集），
                  // 而不是「当前这个 tab 是今天」——否则当天每张卡都挂同一个角标。
                  updatedToday: isSameCalendarDay(entry.updatedAt, now),
                  cached: anyNormalizedTitleContains(cachedNames, entry.title),
                  subscribed: isSubscribedScheduleEntry(entry, subs),
                ),
                followed: followedIds.contains(
                  followingIdFor(
                    mikanBangumiId: entry.bangumiId,
                    title: entry.title,
                  ),
                ),
                onTap: () => openBangumiDetail(context, entry),
              ),
            );
          },
          childCount: items.length,
        ),
      ),
    );
  }
}

/// 封顶后的卡片宽度：均分宽度与 `cap` 取小（用户 2026-10-11「图太大」）。
///
/// 纯函数（可单测）。`cap` = 设置页「封面大小」（决策 F23：小 172 / 中 208 / 大 250），
/// 不传就按中档（= 旧行为，老调用点不用改）。
double homeCardWidthFor(double maxWidth, [double cap = kHomeCoverMaxWidth]) {
  final double avail = math.max(0, maxWidth - kHomeGridPadding * 2);
  final int cols = homeGridColumns(maxWidth, cap);
  final double even = cols <= 1 ? avail : (avail - kHomeGridGap * (cols - 1)) / cols;
  return math.min(even, cap);
}

/// 列数由**可用宽度**决定（等价 CSS `repeat(auto-fill, Npx)`），不按条目数算 ——
/// 后者会把 8 部排成 7+1 的孤儿行（见回归用例）。
int homeGridColumns(double maxWidth, double cardWidth) {
  final double avail = math.max(0, maxWidth - kHomeGridPadding * 2);
  return math.max(1, ((avail + kHomeGridGap) / (cardWidth + kHomeGridGap)).floor());
}

/// 本机是否已经订阅这部番：mikan 自己给的标记，或某个订阅名对得上。
bool isSubscribedScheduleEntry(ScheduleEntryView entry, List<SubscriptionView> subs) {
  if (entry.subscribed) return true;
  final String show = normalizeTitleForMatch(entry.title);
  if (show.length < minMatchableTitleLength) return false;
  for (final SubscriptionView sub in subs) {
    final String subName = normalizeTitleForMatch(sub.name);
    if (subName.length < minMatchableTitleLength) continue;
    if (subName.contains(show) || show.contains(subName)) return true;
  }
  return false;
}

/// 空态文案（spec §7.5 指定原文）。
String homeEmptyText(int selectedDay, int todayDow) => selectedDay == todayDow
    ? '今天没有更新的番剧。可以点上方的星期切换看看其它日子。'
    : '${dsWeekdayLabel(selectedDay)}没有更新的番剧。可以点上方的星期切换看看其它日子。';

/// 区块标题（第五十二轮）：3px 色相竖条 + 色相 ink 标题。
///
/// 和设置页 `DsSection` 的记号同一套语言（一行标题前一条 3px 色相竖条）。这里不直接用
/// [NeoSectionHeader]：它自带 padding/trailing 的取法会改主页这两处区头的行内布局
///（今日推荐是 Column 里的裸标题、今日更新要跟星期切换和刷新按钮同处一行）。
class _SectionTitle extends StatelessWidget {
  const _SectionTitle({required this.text, required this.hue});

  final String text;
  final DsHue hue;

  @override
  Widget build(BuildContext context) {
    final DsTokens t = context.ds;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Container(
          width: 3,
          height: 12,
          decoration: BoxDecoration(
            color: t.hueFill(hue),
            borderRadius: BorderRadius.circular(t.radiusPill),
          ),
        ),
        const SizedBox(width: 8),
        Text(
          text,
          style: TextStyle(
            color: t.hueInk(hue),
            fontSize: DsTypeScale.title,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.3,
          ),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 刷新（挂在「今日更新」区头行内、星期切换旁边）
// ─────────────────────────────────────────────────────────────────────────────

/// 「刷新」：到点自动重拉追番表（30 分钟）；点一下可以立即刷新。
///
/// ⚠️ 位置是用户 2026-10-12 第十一轮定的：原来它跟「今晚想看点什么」同处页面最上面
/// 那一行顶栏，用户要求**整行删掉**、把刷新挪到**星期切换旁边**（更新区头行内）——
/// 那颗按钮动的就是「今日更新」这块的数据，跟星期切换本来就是同一件事的两个入口。
///
/// 用户 2026-10-10 第 1 轮问答：这里原来还显示「数据 3 分钟前」「下次刷新 MM:SS 后」
/// 两处时间（同一屏两个时间）→ 时间信息全删，只留这颗按钮；**自动刷新照旧**。
class _RefreshCountdown extends ConsumerStatefulWidget {
  const _RefreshCountdown();

  @override
  ConsumerState<_RefreshCountdown> createState() => _RefreshCountdownState();
}

class _RefreshCountdownState extends ConsumerState<_RefreshCountdown> {
  /// 追番表的自动刷新间隔（core 侧缓存 TTL 是 300s，这里给一个更省事的长周期）。
  static const Duration interval = Duration(minutes: 30);

  Timer? _ticker;
  DateTime _nextAt = DateTime.now().add(interval);

  @override
  void initState() {
    super.initState();
    // 只服务"到点自动重拉"；倒计时不再显示（用户 2026-10-10：时间信息全删）。
    // 一分钟一跳就够了，不必每秒刷新界面。
    _ticker = Timer.periodic(const Duration(seconds: 20), (_) => _tick());
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _ticker = null;
    super.dispose();
  }

  void _tick() {
    if (!mounted) return;
    final DateTime now = DateTime.now();
    if (!now.isBefore(_nextAt)) {
      _nextAt = now.add(interval);
      // 到点自动重拉（切星期不会走到这里：那只换选中项）。
      // 倒计时文本已经不显示了（用户 2026-10-10：时间信息全删），但**自动刷新照旧**。
      ref.invalidate(scheduleProvider);
    }
  }

  void _refreshNow() {
    _nextAt = DateTime.now().add(interval);
    ref.invalidate(scheduleProvider);
  }

  @override
  Widget build(BuildContext context) {
    // 追番表在拉 → 这颗按钮进入忙态（用户 2026-10-10：按下去没反应，其实在拉数据）。
    final bool loading = ref.watch(scheduleProvider).isLoading;
    // ⚠️ 2026-10-14 第二十八轮（用户：「刷新和换一批改为圆形按钮，仅保留矢量图，
    // 去除文字」）：这里原来是一颗凹槽胶囊（图标 + 「刷新」两个字 + 忙态文案），
    // 现在只剩一个圆形图标按钮 —— 文字只在 tooltip 里。忙态不再换文案（按钮上没字了），
    // 改为**面沉下去 + 图标降为三级色**（静态，不转圈，理由见 NeoCircleButton 文档）。
    return NeoCircleButton(
      icon: Icons.refresh,
      size: 28,
      busy: loading,
      // 第五十二轮：主页身份色（橙）—— 这颗圆钮是主页的"单动作"，跟着页面色走。
      hue: DsHue.orange,
      tooltip: '追番表每 ${interval.inMinutes} 分钟自动刷新；点这里立即刷新',
      busyTooltip: '正在刷新追番表…',
      onPressed: loading ? null : _refreshNow,
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// ① 今日推荐（Bangumi 全年代随机 5 部）—— 页面最上面（顶栏已删）
// ─────────────────────────────────────────────────────────────────────────────

/// ① 今日推荐（决策 F13/F14/F21）：**当天固定、不可刷新**，以首页轮播呈现。
///
/// * 区头**只有标题**：没有「换一批」按钮、没有说明文字（F13/F16）；
/// * 轮播形态 A（主卡 + 两侧半露邻卡，规范 §9.3），几何来自设置里的「轮播封面 / 轮播大小」；
/// * 失败/空态**没有手动重试**（F15）：进主页时若上次是失败态，静默重试一次；
/// * 自动播放开关来自 `carouselAutoPlayProvider`（测试里 override 成 false）。
class _RecommendRail extends ConsumerStatefulWidget {
  const _RecommendRail();

  @override
  ConsumerState<_RecommendRail> createState() => _RecommendRailState();
}

class _RecommendRailState extends ConsumerState<_RecommendRail> {
  /// 每个挂载周期只静默重试一次（决策 F15）。
  bool _retried = false;

  @override
  Widget build(BuildContext context) {
    final DsTokens t = context.ds;
    final AsyncValue<List<BangumiSubject>> async = ref.watch(recommendProvider);
    final List<BangumiSubject>? items = async.value;
    final DsCarouselGeometry geometry = DsCarouselGeometry.forShape(
      ref.watch(carouselShapeProvider),
      ref.watch(carouselSizeProvider),
    );

    // 上次是失败态 → 静默重试一次（不显示骨架，也不给"点右上角重试"的文案）。
    if (async.hasError && !_retried) {
      _retried = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) ref.invalidate(recommendProvider);
      });
    }

    return Padding(
      // ⚠️ 2026-10-15 第三十二轮（用户：「今日推荐和今日更新的间距增加一点点」）：
      // 底部留白 13 → **18**。它与下一块（`_UpdateHeader`）自带的顶部 12 相加，才是这两区
      // 之间**真正**的间距：25 → **30**（+5，见 §17.3）。只动这一处 —— 12 是全区头统一的
      // 上边距基准（`_UpdateHeader` 自己那 12 不动）。
      padding: const EdgeInsets.fromLTRB(kHomeGridPadding, 12, kHomeGridPadding, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          // 第五十二轮：区头带页面身份色（主页 = 橙）的 3px 竖条 + 色相标题。
          const _SectionTitle(text: '今日推荐', hue: DsHue.orange),
          const SizedBox(height: 9),
          if (items == null)
            _RecommendSkeleton(geometry: geometry)
          else if (items.isEmpty)
            _RecommendEmpty(geometry: geometry)
          else
            DsCarousel(
              itemCount: items.length,
              geometry: geometry,
              autoPlay: ref.watch(carouselAutoPlayProvider),
              itemBuilder: (BuildContext c, int i) => _RecommendCover(
                subject: items[i],
                geometry: geometry,
              ),
              // 文字块也吃点击（与主卡同一个动作）：点标题去搜索源找种子更符合直觉。
              // 文字块也吃点击，与主卡同一个落点（第三十三轮：打开动漫库详情）。
              captionBuilder: (BuildContext c, int i) => GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => openLibraryDetail(context, items[i]),
                child: _RecommendCaption(subject: items[i]),
              ),
            ),
          if (async.hasError && items == null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                '推荐拉取失败：${describeFailure(async.error ?? '未知错误').message}'
                '（明天会自动重试；不联网时主页其它部分照常可用）',
                style: TextStyle(color: t.warning, fontSize: DsTypeScale.caption),
              ),
            ),
        ],
      ),
    );
  }
}

/// 空态：**没有手动重试**（决策 F15），只说清"明天会自动重试"。
class _RecommendEmpty extends StatelessWidget {
  const _RecommendEmpty({required this.geometry});

  final DsCarouselGeometry geometry;

  @override
  Widget build(BuildContext context) {
    final DsTokens t = context.ds;
    return SizedBox(
      height: geometry.blockHeight * 0.4,
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(
          'Bangumi 这次没给出可用的推荐条目（明天会自动重试）。',
          // 第五十二轮：空态文字用主页身份色（橙）—— 这一块高度只有轮播的 40%，
          // 塞不下 [DsEmpty] 的图标圆盘，所以只取它的色相。
          style: TextStyle(color: t.hueInk(DsHue.orange), fontSize: DsTypeScale.secondary),
        ),
      ),
    );
  }
}

/// 拉取中的占位：**静态**（不转圈 —— 无限动画会让 widget 测试的 `pumpAndSettle` 永不
/// settle，骨架当初就是因此做成静态的）。形状与真轮播一致：主卡那块 `sunken` 面 + 两条文字条。
///
/// ⚠️ 2026-10-15 第三十二轮：文字条原来靠 `(窗口宽 − 主卡宽) / 2` 当左内边距自己算居中。
/// 主卡默认变宽（460 → 552）后，窄窗（520px 用例）下这个值成了**负数**，
/// `Padding` 当场断言失败（`padding.isNonNegative`）。现在改成与真轮播同构：
/// 整块撑满可用宽 → `Center` + `SizedBox(width: main.width)`（真轮播的 caption 就是这么放的）。
class _RecommendSkeleton extends StatelessWidget {
  const _RecommendSkeleton({required this.geometry});

  final DsCarouselGeometry geometry;

  @override
  Widget build(BuildContext context) {
    final DsTokens t = context.ds;
    return SizedBox(
      width: double.infinity,
      height: geometry.blockHeight,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Align(
            child: SizedBox(
              width: geometry.main.width,
              height: geometry.main.height,
              child: DecoratedBox(decoration: t.inset(radius: t.radiusCard)),
            ),
          ),
          SizedBox(height: 12 * geometry.k),
          Center(
            child: SizedBox(
              width: geometry.main.width,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Container(
                    width: geometry.main.width * 0.6,
                    height: 12,
                    decoration: t.inset(radius: t.radiusBadge),
                  ),
                  const SizedBox(height: 6),
                  Container(
                    width: geometry.main.width * 0.35,
                    height: 10,
                    decoration: t.inset(radius: t.radiusBadge),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// **用番名去搜索源找种子**（spec §7.7 的那条链路）。
///
/// ⚠️ 第三十三轮起，今日推荐的主卡/文字块**不再直接调它** —— 用户的
/// 「点今日推荐也会跳到这里面」把落点改成了动漫库详情页，详情页里再放这个按钮。
/// 函数本身留着：它是"番名 → 搜索页"这条链路的**唯一入口**（详情页、后续页面都走它），
/// 免得各处自己拼 `setKeyword + select(ShellTab.search) + refresh` 三件套。
void openRecommendSearch(WidgetRef ref, BangumiSubject subject) {
  ref.read(searchProvider.notifier).setKeyword(subject.displayTitle);
  ref.read(navProvider.notifier).select(ShellTab.search);
  unawaited(ref.read(searchProvider.notifier).refresh());
}

/// 轮播主卡（邻卡复用同一个 builder）：封面 + 点击去搜索源找种子（spec §7.7 的行为不变）。
///
/// 主卡与邻卡的尺寸由 `DsCarousel` 给定（`geometry.main` / `geometry.neighbour`），
/// 这里只负责画封面与点击；封面取档按**显示宽度 × 设备倍率**（规范 §9.3）。
class _RecommendCover extends ConsumerWidget {
  const _RecommendCover({required this.subject, required this.geometry});

  final BangumiSubject subject;
  final DsCarouselGeometry geometry;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final DsTokens t = context.ds;
    final double dpr = MediaQuery.devicePixelRatioOf(context);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        // ⚠️ 第三十三轮（用户：「点今日推荐也会跳到这里面」）：主卡现在打开**动漫库详情**，
        // 不再是"直接拿番名去搜种子" —— 详情页里有「按这个名字搜种子」按钮，
        // 路一样短，而且先给用户看到评分/简介/标签。邻卡仍然是切页（F29 不变）。
        onTap: () => openLibraryDetail(context, subject),
        child: DsCover(
          // `coverUrlAt` 收 int：主卡显示宽 × 设备倍率后取整（规范 §9.3：1.5x 屏取 800 档）。
          url: subject.coverUrlAt((geometry.main.width * dpr).round()),
          referer: bangumiCoverReferer,
          radius: t.radiusCard,
          // ⚠️ 第三十三轮（用户：「轮播切换时会闪烁」）：**取档必须钉在主卡这一档上**。
          // 同一张卡在切换动画里宽度从邻卡 264 连续长到主卡 552，若让 `DsCover` 按自己
          // 此刻的宽度取档，中途会跳一档（400 → 800）= 换 URL = 重新查缓存 + 重新解码，
          // 中间空一帧 —— 逐帧探针实测那一帧就是用户看到的闪。主卡宽是这一段动画里唯一
          // 不变的尺寸，拿它取档则整段切换 URL 一个字节都不变（静止时邻卡用的也是这一档，
          // 反正这一部迟早要当主卡，不多花一次请求）。
          tierDevicePixels: (geometry.main.width * dpr).round(),
        ),
      ),
    );
  }
}

/// 主卡下方的文字块（规范 §9.3：番名 + 一行「年份 · 话数 · 前两个标签」+ 右侧评分胶囊）。
class _RecommendCaption extends StatelessWidget {
  const _RecommendCaption({required this.subject});

  final BangumiSubject subject;

  @override
  Widget build(BuildContext context) {
    final DsTokens t = context.ds;
    final String meta = <String>[
      if (subject.airDateLabel.isNotEmpty) subject.airDateLabel,
      if (subject.eps != null) '${subject.eps} 话',
      ...subject.tags.take(2),
    ].join(' · ');
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                subject.displayTitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: t.text,
                  fontSize: DsTypeScale.title,
                  fontWeight: FontWeight.w600,
                  // 行高写死（规范 §4）：40px 的文字块只有这点余量，交给字体默认行高会溢出。
                  height: 1.25,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                meta,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: t.text3,
                  fontSize: DsTypeScale.caption,
                  fontWeight: FontWeight.w300,
                  height: 1.3,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 10),
        // 第五十二轮：评分 = gold 色相胶囊（评分是"信息"，不是强调色）；「暂无评分」保持
        // 中性 —— 不把"没有"装成"有一档颜色"。
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: subject.score == null
              ? t.inset(radius: t.radiusPill)
              : BoxDecoration(
                  color: t.hueSoft(DsHue.gold),
                  borderRadius: BorderRadius.circular(t.radiusPill),
                ),
          child: Text(
            subject.score == null
                ? '暂无评分'
                : '★${subject.score!.toStringAsFixed(1)}',
            style: TextStyle(
              color: subject.score == null ? t.text3 : t.hueInk(DsHue.gold),
              fontSize: DsTypeScale.caption,
              fontFeatures: DsTokens.tabular,
            ),
          ),
        ),
      ],
    );
  }
}

/// 推荐卡左上角的「看 Bangumi 介绍」按钮。
///
/// 它叠在封面图上，**不能**用凸起面（会和整页新拟态打架）：改用极淡的
/// `base` 半透明底 + `radiusPill`，保证在任何封面图上都看得清。
class _CoverInfoButton extends StatefulWidget {
  const _CoverInfoButton({required this.onTap});

  final VoidCallback onTap;

  @override
  State<_CoverInfoButton> createState() => _CoverInfoButtonState();
}

class _CoverInfoButtonState extends State<_CoverInfoButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final DsTokens t = context.ds;
    return Tooltip(
      message: '看 Bangumi 介绍',
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: DsMotion.of(context).hover,
            curve: DsMotion.hoverCurve,
            width: 22,
            height: 22,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: t.base.withValues(alpha: _hover ? 0.95 : 0.8),
              borderRadius: BorderRadius.circular(t.radiusPill),
            ),
            child: Icon(Icons.info_outline, size: 13, color: t.text2),
          ),
        ),
      ),
    );
  }
}

/// Bangumi 条目介绍（推荐卡的「去 Bangumi 详情」入口；不跳外网浏览器）。
Future<void> showBangumiSubjectSheet(BuildContext context, BangumiSubject s) {
  final DsTokens t = context.ds;
  return showDialog<void>(
    context: context,
    builder: (BuildContext context) => AlertDialog(
      title: Text(
        s.displayTitle,
        style: TextStyle(color: t.text, fontSize: DsTypeScale.body, fontWeight: FontWeight.w600),
      ),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  SizedBox(
                    width: 96,
                    height: 132,
                    child: DsCover(
                      url: s.coverUrl,
                      referer: bangumiCoverReferer,
                      radius: t.radiusControl * 0.5,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        if (s.alternateTitle case final String en)
                          Text(
                            en,
                            style: TextStyle(color: t.text3, fontSize: DsTypeScale.caption),
                          ),
                        const SizedBox(height: 4),
                        Text(
                          <String>[
                            if (s.airDateLabel.isNotEmpty) s.airDateLabel,
                            if (s.eps != null) '共 ${s.eps} 话',
                            if (s.platform != null) s.platform!,
                            s.score == null
                                ? '暂无评分'
                                : '★${s.score!.toStringAsFixed(1)}'
                                      '${s.ratingTotal == null ? '' : '（${s.ratingTotal} 人评分）'}',
                          ].join(' · '),
                          style: TextStyle(color: t.text2, fontSize: DsTypeScale.secondary),
                        ),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: <Widget>[
                            // 标签用胶囊（凹槽底、无边框）而不是「灰底 + 1px 描边」。
                            for (final String tag in s.tags.take(12)) NeoPill(label: tag),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              if ((s.summary ?? '').trim().isNotEmpty) ...<Widget>[
                const SizedBox(height: 12),
                Text(
                  s.summary!.trim(),
                  maxLines: 8,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: t.text2, fontSize: DsTypeScale.secondary, height: 1.5),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('关闭')),
      ],
    ),
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// ② 今日更新 区头（行内：一排日期 + 圆形刷新按钮）
// ─────────────────────────────────────────────────────────────────────────────

class _UpdateHeader extends ConsumerWidget {
  const _UpdateHeader({required this.view});

  final ScheduleView? view;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final int selected = ref.watch(selectedDayProvider);
    final int today = ref.watch(todayDowProvider);
    // 选中项万一不在这一排里（旧数据/越界值）→ 高亮回落到今天，不出现"一个都没选中"。
    final int current = kHomeDayTabs.contains(selected) ? selected : today;

    return Padding(
      padding: const EdgeInsets.fromLTRB(kHomeGridPadding, 12, kHomeGridPadding, 8),
      child: Row(
        children: <Widget>[
          // 第五十二轮：区头的色相跟着**当前选中的那一天**走 —— 与右边那一排切换项同一个
          // 色相，切星期时竖条/标题颜色跟着换（颜色本身就在说明"现在看的是哪一天"）。
          _SectionTitle(
            text: selected == today ? '今日更新' : '${dsWeekdayLabel(selected)}更新',
            hue: hueForDayTab(current),
          ),
          const SizedBox(width: 12),
          // ⚠️ 2026-10-14 第二十八轮（用户：「主页日期改成，在今日更新旁边一排
          // 周一到周日+剧场版+ova，细体淡色」）：
          // * 位置：**就贴在「今日更新」右边**（原来是靠 Spacer 推到行尾的下拉）；
          // * 形态：`周一…周日 + 剧场版 + OVA` 共 9 项一条平铺（见 [kHomeDayTabs]），
          //   细体淡色 = caption(12) + w300 + 三级色，**选中项才走该天的色相**（第五十二轮）；
          // * 只作用于「今日更新」这一块，不筛选推荐（用户第十一轮定的硬约束）。
          //
          // 用 [Expanded] + [Wrap] 而不是 `Row`：窗口窄到放不下 9 项时它会折成两行，
          // 而不是抛 RenderFlex overflow（横向滚动条在桌面端不跟滚轮走，折行更稳）。
          // 常见宽度下就是一行 —— 这一排的可用宽度 = 整行减去标题与刷新按钮。
          Expanded(
            child: Wrap(
              spacing: 2,
              runSpacing: 2,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: <Widget>[
                for (final int dow in kHomeDayTabs)
                  _DayTabItem(
                    label: dsWeekdayLabel(dow),
                    // 第五十二轮：每一格一个色相（周一…周日走色环，剧场版紫 / OVA 靛）。
                    hue: hueForDayTab(dow),
                    // ⚠️ 没有数据时 `count` 是 **null**，不是 0：把"追番表还没到/拿不到"
                    // 说成「周一 · 0 部」就是编了一个数字（spec 口径：拿不到就说拿不到）。
                    count: view?.day(dow).length,
                    selected: dow == current,
                    today: dow == today,
                    onTap: () => ref.read(selectedDayProvider.notifier).select(dow),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          // 刷新就贴在这一排的右端（用户 2026-10-12 第十一轮：从顶栏挪过来）。
          const _RefreshCountdown(),
        ],
      ),
    );
  }
}

/// 这一排里的一项：**只有星期/专档名，没有部数**（用户 2026-10-14：细体淡色）。
///
/// * 细体淡色：caption 字号 + `FontWeight.w300` + 三级色；选中项走**该天的色相**
///   （18% 淡底 + `hueInk` 文字 + w500，第五十二轮）；悬停同样给该色相淡底；
/// * 「今天」用名字底下那颗 3px 小圆点表达 —— 不写「（今天）」，那一项会被撑得
///   比别的宽一截，一排就对不齐了；圆点用该天的 `hueFill`（同一份颜色信息编码）；
/// * 部数没丢：挂在 tooltip 里（`周三（今天） · 8 部`），计数仍是"没有数据就不写"。
class _DayTabItem extends StatefulWidget {
  const _DayTabItem({
    required this.label,
    required this.hue,
    required this.count,
    required this.selected,
    required this.today,
    required this.onTap,
  });

  final String label;

  /// 这天的标识色相（第五十二轮）：周一…周日走 [hueOfWeekday] 的色环，
  /// 剧场版 = 紫 / OVA = 靛（见 [hueForDayTab]）。
  final DsHue hue;

  /// 这天的番剧数；null = 还没有数据（不许当成 0）。
  final int? count;

  final bool selected;
  final bool today;
  final VoidCallback onTap;

  @override
  State<_DayTabItem> createState() => _DayTabItemState();
}

class _DayTabItemState extends State<_DayTabItem> {
  bool _hover = false;

  /// tooltip 文案 = 原来的下拉文案（触发器与菜单项同一句，避免来回跳）。
  String get _tip => '${widget.label}${widget.today ? '（今天）' : ''}'
      '${widget.count == null ? '' : ' · ${widget.count} 部'}';

  @override
  Widget build(BuildContext context) {
    final DsTokens t = context.ds;
    final DsHue hue = widget.hue;
    // 第五十二轮：选中项 = 该天色相淡底 + 色相 ink（对比度由 token 保证）；悬停也给
    // 同一色相的淡底 —— "这一排很淡"的观感不变，但扫一眼就知道每一格是哪个色相。
    final bool lit = widget.selected || _hover;
    final Color fg = lit ? t.hueInk(hue) : t.text3;
    return Tooltip(
      message: _tip,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: DsMotion.of(context).hover,
            curve: DsMotion.hoverCurve,
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
            decoration: BoxDecoration(
              // 第五十二轮：选中/悬停 = 色相 18% 淡底（这是"淡"的一排，不做凹槽也不做 pill）。
              color: lit ? t.hueSoft(hue) : Colors.transparent,
              borderRadius: BorderRadius.circular(t.radiusBadge),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  widget.label,
                  style: TextStyle(
                    color: fg,
                    fontSize: DsTypeScale.caption,
                    fontWeight: widget.selected ? FontWeight.w500 : FontWeight.w300,
                    height: 1.2,
                  ),
                ),
                const SizedBox(height: 2),
                // 「今天」的小圆点：不占文字宽度，也不改这一排的基线。
                Container(
                  width: 3,
                  height: 3,
                  decoration: BoxDecoration(
                    color: widget.today ? t.hueFill(hue) : Colors.transparent,
                    shape: BoxShape.circle,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// ③ 当天的大图封面网格
//
// ⚠️ 第二十五轮：原来这里的 `_DayGrid` 是一个**自带滚动**的 `GridView`（占 `Expanded`
// 的下半屏），推荐区钉在上面。用户要求「今日推荐和今日更新做成一体的」，问答选定
// 「整页一条滚动条，推荐跟着一起滚」——于是网格搬进 [HomePage] 的 `CustomScrollView`
// 里成了 `SliverGrid`（见 `HomePage._grid`），列数/封顶宽度抽成纯函数
// [homeGridColumns] / [homeCardWidthFor]。
// ─────────────────────────────────────────────────────────────────────────────

/// 封面左上角角标（spec §7.5）。一次只显示最值得说的那个。
enum ScheduleBadge { subscribed, cached, today }

/// 角标优先级：已订阅 > 已缓存 > 今日更新。
///
/// 纯函数（可单测）。三个判据都是**真实信号**：
/// `updatedToday` 来自 mikan 的更新日期、`subscribed` 来自站点标记或本机订阅名、
/// `cached` 来自引擎里已下完的 torrent 名（见 `domain/title_match.dart`）。
/// 都不成立就不显示角标——不为了好看编一个。
ScheduleBadge? scheduleBadgeFor({
  required ScheduleEntryView entry,
  required bool updatedToday,
  required bool cached,
  required bool subscribed,
}) {
  if (subscribed) return ScheduleBadge.subscribed;
  if (cached) return ScheduleBadge.cached;
  if (updatedToday) return ScheduleBadge.today;
  return null;
}

/// 一张海报卡：封面在上（真海报比例、圆角、柔光内边）+ 番名两行 + 悬停时的追番 ♥。
///
/// 第五十轮：番名区按两行给足高度（[kHomeCardTitleHeight]），**不再切掉第二行**；
/// 悬停番名会弹 tooltip 显示完整名字（名字超过两行时截成省略号）。
class _PosterCard extends StatefulWidget {
  const _PosterCard({
    required this.entry,
    required this.badge,
    required this.followed,
    required this.onTap,
  });

  final ScheduleEntryView entry;
  final ScheduleBadge? badge;

  /// 这部番是不是已经在追了（由 [_UpdateGrid] 统一算好传进来）。
  ///
  /// 1.1.0 M1/T2：以前这里每张卡各 `ref.watch(followingProvider)` 再 `any()` 一遍 ——
  /// 八张卡 = 八个订阅者，追番表一变就八个按钮各自重建。现在只有一个 watch。
  final bool followed;
  final VoidCallback onTap;

  @override
  State<_PosterCard> createState() => _PosterCardState();
}

class _PosterCardState extends State<_PosterCard> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final DsTokens t = context.ds;
    final ScheduleEntryView entry = widget.entry;
    final String date = entry.updateLabel;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            // 悬停反馈：阴影升一档 + 1px 柔光内边（规范 §5 允许的「线」之一），
            // 不再用 1px line 描边（那属于硬边框）。
            // 扁平（规范 §2 第 2 条 / §8.3 第 2 条）：悬停 = 面沉一档 + **1.01 倍缩放**，
            // 零阴影（旧的「阴影升一档」随新拟态一起删掉）。
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
                // 凸起面 + 1px 柔光内边（规范 §5 例外 2）。
                // 第五十二轮：悬停的描边换成主页身份色（橙）的 1px 色相线 —— 不加剧烈
                // 阴影（规范只允许 1px 彩色线），一眼能看出"这张卡是活的"。
                // ⚠️ 写法必须让 `t.` 与 `Border.all(` 同行：`neo_guard_test` 的描边守卫
                // 只看单行（拆行会被当成"没有 token 的硬边框"）。
                border: Border.all(color: _hovered ? t.hueLine(DsHue.orange) : t.line, width: 1),
              ),
              child: AspectRatio(
                aspectRatio: kPosterAspect,
                child: Stack(
                  fit: StackFit.expand,
                  children: <Widget>[
                    // 固定按真海报比例开的槽 → `contain`：任何比例的封面都不裁
                    // （用户 2026-10-15：「今日更新的封面图还是显示不全」，见 kPosterFit）。
                    DsCover(url: entry.coverUrl, fit: kPosterFit),
                    if (widget.badge case final ScheduleBadge badge)
                      Positioned(left: 6, top: 6, child: _BadgeDot(badge: badge)),
                    // 追番按钮：悬停出现，已追的常驻（spec §7.6 要求海报卡能追番，
                    // 但 8 张卡都常驻一个按钮会把基线图的封面角挤满）。
                    if (_hovered || widget.followed)
                      Positioned(
                        right: 5,
                        top: 5,
                        child: FollowButton(
                          entry: followingEntryFromSchedule(entry),
                          compact: true,
                        ),
                      ),
                    if (date.isNotEmpty)
                      Positioned(right: 5, bottom: 5, child: _DateChip(text: date)),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 6),
            // 第五十轮：番名盒子按**两行**给足（38），第二行不再被切掉半截；
            // 超过两行的名字收省略号，悬停标题看完整番名。
            Tooltip(
              message: entry.displayTitle,
              child: SizedBox(
                height: kHomeCardTitleHeight,
                child: Text(
                  entry.displayTitle,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: t.text, fontSize: DsTypeScale.secondary, height: 1.35),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 封面左上角的 **6px 色点**（决策 F17：文字胶囊 → 色点 + tooltip）。
///
/// 优先级不变（已订阅 > 已缓存 > 今日更新，判据见 [scheduleBadgeFor]）。
/// 色点叠在封面图上，所以带一圈 1px 的底色描边 —— 浅色封面下也看得见。
///
/// 第五十二轮：三种状态改成**语义色相**（点用 `hueFill`，不承载文字）——
/// 今日更新 = emerald、已订阅 = pink（侧栏「正在追」的身份色）、已缓存 = blue，
/// 和别的页面上同意义的角标保持同一个色相。
class _BadgeDot extends StatelessWidget {
  const _BadgeDot({required this.badge});

  final ScheduleBadge badge;

  @override
  Widget build(BuildContext context) {
    final DsTokens t = context.ds;
    final (Color color, String label) = switch (badge) {
      ScheduleBadge.today => (t.hueFill(DsHue.emerald), '今日更新'),
      ScheduleBadge.subscribed => (t.hueFill(DsHue.pink), '已订阅'),
      ScheduleBadge.cached => (t.hueFill(DsHue.blue), '已缓存'),
    };
    return Tooltip(
      message: label,
      child: Semantics(
        label: label,
        child: Container(
          key: Key('badge-${badge.name}'),
          width: 6,
          height: 6,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            border: Border.all(color: t.base.withValues(alpha: 0.85), width: 1),
          ),
        ),
      ),
    );
  }
}

class _DateChip extends StatelessWidget {
  const _DateChip({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final DsTokens t = context.ds;
    // 第五十二轮：日期块 = 「更新」语义 → emerald 色相淡底 + 色相 ink。
    // 这里仍然要做「图上覆盖层」：封面可能是任意亮度的图，所以用 `hueSoftOn(膜, base)`
    // 一块**不透明**的淡底压住封面（原来是半透明黑底），色相 ink 在它上面有对比度保证。
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: t.hueSoftOn(DsHue.emerald, t.base),
        borderRadius: BorderRadius.circular(t.radiusPill),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: t.hueInk(DsHue.emerald),
          fontSize: DsTypeScale.caption,
          fontFeatures: DsTokens.tabular,
        ),
      ),
    );
  }
}
