/// 动漫库条目详情（第三十三轮；**第三十四轮填内容 · 第三十五轮重排 · 第三十六轮修细节 ·
/// 第三十七轮补两个通栏盒子 · 第四十四轮补"加载/失败反馈"**）。
///
/// 用户原话（第三十三轮）：「点今日推荐也会跳到这里面」+ 问答里选定的：详情展示
/// 封面/评分/简介/放送日/集数，并且能「按这个名字搜种子」和「加入追番」。
/// 用户原话（第三十四轮）：「动漫库点的详细页，太空了优化下」。
/// 用户原话（第三十五轮）：「详细页优化下布局」。
/// 用户原话（第三十六轮）：「详细页细节没处理好，而且左右两边留白不好看，
/// 细节比如封面框有色边」。
/// 用户原话（第三十七轮）：「现在下面又留空太多了，可以参考bangumi那样的布局」。
/// 用户原话（第四十四轮）：「优化详细页反馈。加载关联等没有反馈，是突然出现在下面的」。
///
/// ## 第四十四轮：为什么"没有反馈"不是动画问题，是状态没表达出来
///
/// 那两块（角色 / 关联条目）由两个端点拼出来，而 [BangumiClient] 的限速闸门会把两条请求的
/// **开始时刻**排开 1.1s（Bangumi 的硬要求）—— 也就是说冷启点开一部，这两块**必然**
/// 比详情晚一秒以上才出现。而旧实现这一秒里界面状态是"没有"：`_extra == null` 同时表示
/// "还在拉""没拉到""拉到了但为空"，于是在用户眼里就是"下面本来什么都没有 → 忽然蹦出一大块"，
/// 端点挂了的话则永远是"什么都没有"（连"没拉到"都不说）。
///
/// 现在这三件事分开表达（[_ExtrasState]），并各自有画面：
/// 占位盒（`正在加载角色与关联条目…`）→ 内容盒；失败 ⇒ "没拉到（原因）+ 重试"；
/// 只拉到一半 ⇒ 点名是哪一块没拉到 + 重试。整块外面套 `AnimatedSize`，
/// 高度变化是连续长上去的，不是当帧跳一下。
///
/// 顺带修掉一个"重试没用"的机制问题：`state/bangumi_library.dart` 的 `extras()` 原来
/// **无论成败都进程内缓存**，于是那颗新加的「重试」拿回来的还是内存里那份缺一半的。
/// 现在只有两条都成功才记（内存 + 盘）。
///
/// ## 第三十七轮：为什么"下面留空"不是版面问题，是内容不够
///
/// 2560 屏 @125%（2048×1152 逻辑）下，第三十六轮那版整页只有 **707px**，而可视高度 1152 ——
/// 滚到底之后下面 **445px 全是纯背景**。把某一栏拉高是填不出这种空白的（那只会变成
/// "某一栏里空一大截"），得**加内容**。bangumi 条目页之所以长而不空，正是因为信息块
/// 下面是**通栏盒子**（简介 / 角色 / 制作人员 / 关联条目）。
///
/// 所以照那个形状补了两块真数据（端点形状见 [BangumiCharacter] / [BangumiRelated]）：
/// 「角色」（先 [kDetailCharacterLimit] 位 + 展开全部）与「关联条目」，都在信息块**下面通栏**。
/// 实测：2048×1152 下内容总高 707 → **1239px**（> 窗口 ⇒ 滚到底不再见空背景）；
/// 1280 宽下角色盒 1240×409、关联盒 1240×670。两块都可能为空（实测 #462993 两条端点都回 `[]`），
/// 那时**不画那一块**，也不留一条空盒子。
///
/// ## 为什么以前是空的，第四十轮拿什么填
///
/// 旧版面只有「封面 + 标题 + 一行事实 + 标签 + 简介」—— 短简介的条目在大屏上
/// 右边/下面就是一大片空白。而详情端点（`GET /v0/subjects/{id}`）**本来**还给了三样
/// 能画的东西（按 `tool/round34_subject_probe.py` 本机实测，4 个条目全都有）：
///
/// | 字段 | 实测形状 | 版面落点 |
/// |---|---|---|
/// | `rating.count` | `{"1":129, …, "10":7511}`（10 档票数） | **评分分布**（10 条细条） |
/// | `collection` | `{wish, collect, doing, on_hold, dropped}` | **收藏统计**（5 格） |
/// | `infobox` | 41–61 行 `{key, value}`（话数/放送开始/电视台/原作/监督…） | **资料表**（先 12 行 + 展开） |
///
/// 这三样在第三十四轮之前**根本没解析**（`BangumiSubject` 只取到 score/rank/total），
/// 所以"填满"这一步是从解析开始的 —— 现在它们跟着详情一起落盘缓存，第二次点开是本地读。
///
/// ## 第三十六轮：三处"看出来的"毛病（都有截图取证，`test/library_detail_shot_probe.dart`）
///
/// 这一轮的三个问题是**视觉**的，所以先用探针**出图**再改
/// （`flutter test test/library_detail_shot_probe.dart --update-goldens`
/// → `build/probe-detail/detail_<宽>.png`，真字体 + 图标字体 + 真封面缓存）：
///
/// 1. **左右两边留白**：第三十五轮给整页加了 `ConstrainedBox(maxWidth: 1180)` 并居中，
///    1280 窗里左边空 74px、**2048 逻辑宽（2560 屏 @125% 最大化）里空 434px**，
///    而 AppBar 的标题在 16px —— 两条竖线对不上，两边各空一大条。
///    现在**不留白、铺满窗口**（只留 [kDetailPadding]），宽了靠**加栏**消化：
///    ≥ [kDetailThreeColumnWidth] 三栏、≥ [kDetailRailMinWidth] 两栏、其余单栏
///    （DSAnima 其它页面的既有做法：窗口越宽列越多）；
/// 2. **封面框有色边**：这里原来把 `DsCover` 又套了一层 `t.inset()` + `Padding(1)`，
///    而 `DsCover` **自己**已经画了一条 `sunken` 面 + 1px `line` 描边的凹槽
///    （`cover.dart:160`）⇒ 海报外面是两道颜色边夹着 1px 空隙。动漫库网格是单层，
///    所以那边没毛病 —— 现在这里也交给 `DsCover` 自己那一层；
/// 3. **事实那一行排版**：第三十四/三十五轮是"一条一个 `Text`"横向折行，在 300 宽的左栏里
///    折出"…28 话 / TV 36596 人评分"这种参差的第二行；改成 ` · ` 串一段之后，
///    行尾又会挂一个孤零零的 `·`。现在**一行一条**（话数与形态合成一行）。
///
/// 顺手改掉一处被省略号截掉一半的副标题（标签卡："…从条目上点最"）—— 说不完的就别写。
///
/// ## 版面（三种，按可用宽度选）
///
/// ```
/// 单栏（< 900）        两栏（900…1560）                三栏（≥ 1560）
/// ┌ 海报 + 信息 ─┐     ┌左 300 ─┐ ┌右 flex ┐          ┌左 300 ┐ ┌中 flex┐ ┌右 flex┐
/// │ 评分分布      │     │ 海报    │ │ 标题    │          │ 海报   │ │ 标题   │ │ 资料   │
/// │ 收藏统计      │     │ 分数/事实│ │ 评分分布 │          │ 分数/事实│ │ 评分分布│ │ 标签   │
/// │ 资料 / 标签   │     │ 动作    │ │ 资料    │          │ 动作   │ │ 收藏统计│ │ 简介   │
/// │ 简介          │     │ 收藏统计│ │ 简介    │          └────────┘ └────────┘ └────────┘
/// └───────────────┘     │ 标签    │ └─────────┘          三栏高度实测 525 / 559 / 707
///                       └────────┘  两栏高度实测 882 / 914
/// ```
///
/// * 分栏的依据是**探针量出来的高度**：两栏 882 / 914、三栏 525 / 559 / 707 ——
///   都不出现"一边到底了另一边还空着半个屏"（第三十四轮那版并排卡片就吃过这个亏：
///   收藏统计比评分分布矮，行高被高的那块决定，矮的下面空 144px）；
/// * 窄窗（< 900）：单栏竖排（海报在左、< [kDetailPosterRowWidth] 620 时居中在上），
///   评分分布 / 收藏统计 / 资料 / 标签 / 简介 依次往下；
/// * 资料表的值用 `Text`（可折叠 + 省略号）—— `SelectableText` 一行字也按 `maxLines: 2`
///   占两行（实测 47px/行 → 26px/行）。
///
/// 三件事的分工没变：
/// * 详情数据走 [BangumiLibraryPort.detail]（`GET /v0/subjects/{id}`，进程内 + 落盘缓存）；
/// * 「搜种子」= 把番名丢进搜索页那条既有链路（`openRecommendSearch`）；
/// * 「追番」= 既有 `FollowButton`（本地标记，不建订阅、不自动下载，spec §7.6）；
/// * 标签点一下就**回动漫库按这个标签筛**（Bangumi 没有"标签大全"接口，
///   从真实条目的标签上点是最不容易过时的方式）。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/bangumi.dart';
import '../domain/error_text.dart';
import '../state/library_provider.dart';
import '../state/providers.dart';
import '../theme/motion.dart';
import '../theme/tokens.dart';
import 'home_page.dart' show openRecommendSearch;
import 'widgets/cover.dart';
import 'widgets/follow_button.dart';
import 'widgets/hues.dart';
import 'widgets/library_seed_block.dart';
import 'widgets/neo.dart';
import 'widgets/state_views.dart';

/// 打开条目详情。
Future<void> openLibraryDetail(BuildContext context, BangumiSubject subject) {
  return Navigator.of(context, rootNavigator: true).push<void>(
    MaterialPageRoute<void>(
      builder: (BuildContext context) => LibraryDetailPage(subject: subject),
    ),
  );
}

/// 跳到动漫库并按某个标签筛（详情页的标签胶囊用它）。
///
/// ⚠️ 第四十四轮改成 `copyWith`：旧实现 `patch(BangumiLibraryQuery(tag: tag))` 是**整份换掉**，
/// 于是"在动漫库筛着 2024 年，从详情页点了个标签回来，年份/形态/评分全没了" ——
/// 用户点的是"再加一个条件"，不是"重置之后再筛"。右栏的类型胶囊走的是同一个 setter。
void openLibraryWithTag(WidgetRef ref, String tag) {
  ref.read(libraryQueryProvider.notifier).setTag(tag);
  ref.read(navProvider.notifier).select(ShellTab.library);
}

/// 「左栏（海报 + 事实 + 动作 + 收藏 + 标签）+ 右栏（标题 + 评分分布 + 资料 + 简介）」
/// 的宽度门槛；低于它退回单栏竖排。
const double kDetailRailMinWidth = 900;

/// 「再拆一栏」的宽度门槛：≥ 它时右栏劈成「标题 + 评分分布 + 简介」与「资料 + 标签」两栏。
///
/// 为什么要有这一档（第三十六轮）：把整页限宽居中会在两边留出一条死白（1280 窗 74px、
/// 2048 逻辑宽 **434px**），而**不限宽**又会让一行字横跨 1700px。DSAnima 其它页面的既有做法是
/// **窗口越宽栏越多**（主页网格、动漫库网格都是加列），详情页照这个来：宽了加一栏，
/// 于是既没有死白、单行长度也还在 800 上下。
const double kDetailThreeColumnWidth = 1560;

/// 左栏宽度（海报就按这个宽度画；三栏版面也是它 —— 海报太小会显得这一栏是空的）。
const double kDetailRailWidth = 300;

/// 整页左右内边距。
///
/// 与 AppBar 的返回箭头左缘（16）基本对齐 —— 第三十五轮那个"居中留白"最难看的一点
/// 就是内容左缘在 74px 而标题在 16px，两条竖线对不上。
const double kDetailPadding = 20;

/// 单栏版面里「海报与标题并排」的宽度门槛（低于它海报居中单独一行）。
const double kDetailPosterRowWidth = 620;

/// 资料表先显示几行（其余点「展开全部」才画）。
const int kDetailInfoboxPreviewRows = 12;

/// 角色先显示几位（其余点「展开全部」）。
///
/// 为什么是 16（第三十七轮实测）：`/v0/subjects/400602/characters` 回 **91** 位
/// （EVA 97 位），一屏画不完；bangumi 网页自己也是"先列十几个 + 更多角色"。
/// 16 = 2560 屏（2048 逻辑宽）下**正好铺满一整行**的数：`16 × 112 + 15 × 10 = 1942 ≤ 1976`
/// （盒子内宽 = 2048 − 2×20 页边距 − 2×16 内边距）——12 个的话右边会空出 550px，
/// 一眼就看得出"这一行没排满"。
const int kDetailCharacterLimit = 16;

/// 左栏 / 中栏 / 右栏各自的 key（版面断言按它们看结构，不截图）。
const Key dsDetailRailKey = Key('library-detail-rail');
const Key dsDetailMainKey = Key('library-detail-main');
const Key dsDetailSideKey = Key('library-detail-side');

/// 顶部信息带**下面**两个全宽盒子的 key（第三十七轮：「参考 bangumi 那样的布局」——
/// 角色 / 关联条目在 bangumi 条目页上就是两个通栏盒子，页面靠它们变长、不再底部空一截）。
const Key dsDetailCharactersKey = Key('library-detail-characters');
const Key dsDetailRelatedKey = Key('library-detail-related');

/// 这两块**还在路上 / 没拉到**时的两个占位盒子的 key（第四十四轮，「加载关联等没有反馈」）。
const Key dsDetailExtrasLoadingKey = Key('library-detail-extras-loading');
const Key dsDetailExtrasFailedKey = Key('library-detail-extras-failed');

/// 两块没拉到 / 只拉到一半时，那颗「重试」的 key（两处不会同时出现，但 key 分开更好断言）。
const Key dsDetailExtrasRetryKey = Key('library-detail-extras-retry');
const Key dsDetailExtrasPartialRetryKey = Key('library-detail-extras-partial-retry');

/// 一个角色格子多宽（头像正方形 + 名字两行 + 声优一行）。
const double kDetailCharacterCellWidth = 112;

/// 一条关联条目的格子多宽（小海报按 [kPosterAspect] 开）。
///
/// 112 而不是 96：关联条目的名字是长中文/日文标题（实测「「葬送のフリーレン」BD&DVD Vol.1」），
/// 96 宽下一个字一行地折，截图里是「…BD&DV…」这种半截。112 与角色格子同宽，一行放得下 9 个字。
const double kDetailRelatedCellWidth = 112;

class LibraryDetailPage extends ConsumerStatefulWidget {
  const LibraryDetailPage({super.key, required this.subject});

  /// 列表里那一条（先用它立刻画出封面与标题，详情到了再补齐）。
  final BangumiSubject subject;

  @override
  ConsumerState<LibraryDetailPage> createState() => _LibraryDetailPageState();
}

class _LibraryDetailPageState extends ConsumerState<LibraryDetailPage> {
  /// 详情 future **只建一次**（第三十四轮）。
  ///
  /// 原来它写在 `build` 里（`ref.read(...).detail(id)`）：任何一次重建（换外观、追番状态变化、
  /// 资料表展开…）都会建一个新的 Future，`FutureBuilder` 于是回到"还没有数据"那一帧 ——
  /// 大屏上就是整页内容"闪一下变少再回来"。端口本身有缓存，所以这只是白闪，没有网络代价。
  late Future<BangumiSubject> _detail;

  /// 顶部信息带下面那两块（角色 / 关联条目，第三十七轮）。
  ///
  /// 为什么不用第二个 `FutureBuilder`：这两块是**追加**在信息带下面的，用 setState
  /// 收结果时 `ListView(children:)` 里前面那些 index 一个都不动，已建好的元素（包括
  /// `DsCover` 自己的 state、资料表的"展开"状态）都被复用；套一层 `FutureBuilder`
  /// 反而会让它在两棵树之间来回换。
  ///
  /// ⚠️ 第四十四轮从 `BangumiSubjectExtra?` 换成三态（[_ExtrasState]）：一个 `null`
  /// 同时表示"还在拉""没拉到""拉到了但为空"三件事，界面上就是"下面什么都没有 → 突然
  /// 冒出一大块通栏盒子"（用户原话：「加载关联等没有反馈，是突然出现在下面的」）。
  _ExtrasState _extras = const _ExtrasLoading();

  @override
  void initState() {
    super.initState();
    _detail = ref.read(bangumiLibraryProvider).detail(widget.subject.id);
    _loadExtra(widget.subject.id);
  }

  @override
  void didUpdateWidget(LibraryDetailPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.subject.id != widget.subject.id) {
      _detail = ref.read(bangumiLibraryProvider).detail(widget.subject.id);
      _loadExtra(widget.subject.id);
    }
  }

  /// 拉角色 / 关联条目。**失败了不把整页变成错误页**（端口契约允许各自为空）——
  /// 它们是装饰，主内容的失败提示走 [_note]；但**这两块自己没拉到要如实说**
  /// （[_ExtrasFailed] / [BangumiSubjectExtra.hasFailures]），并且给一颗能真正重来的「重试」。
  ///
  /// 调用点只有 [initState] / [didUpdateWidget]（这两个位置都在 build 之前，直接赋值即可），
  /// 界面上的「重试」走 [_retryExtras]（那条路上要 `setState`）。
  void _loadExtra(int id) {
    _extras = const _ExtrasLoading();
    unawaited(_fetchExtra(id));
  }

  Future<void> _fetchExtra(int id) async {
    try {
      final BangumiSubjectExtra value =
          await ref.read(bangumiLibraryProvider).extras(id);
      // 晚到的结果不许盖掉"已经换了一部"的页面。
      if (!mounted || widget.subject.id != id) return;
      setState(() => _extras = _ExtrasReady(value));
    } catch (error) {
      if (!mounted || widget.subject.id != id) return;
      setState(() => _extras = _ExtrasFailed(error));
    }
  }

  /// 就地重拉这两块（回到占位态 → 结果/失败）。
  ///
  /// 服务层**不缓存缺一半的结果**（见 `state/bangumi_library.dart` 的 `extras`），
  /// 所以这个「重试」是真的再打一次网络，而不是拿回同一份缺的。
  void _retryExtras() {
    setState(() => _extras = const _ExtrasLoading());
    unawaited(_fetchExtra(widget.subject.id));
  }

  @override
  Widget build(BuildContext context) {
    final DsTokens t = context.ds;
    final BangumiSubject subject = widget.subject;
    return Scaffold(
      backgroundColor: t.base,
      appBar: AppBar(
        backgroundColor: t.base,
        elevation: 0,
        // 第五十二轮（用户 2026-10-17「整个项目太素」）：详情页的**身份色 = 紫**，
        // 与侧栏「动漫库」同一个色相（`hueOfTab(ShellTab.library)`）—— 页头标题前
        // 一条 3px 色相竖条 + 标题用色相 ink，与工具条页名、区块头是同一套记号语言。
        title: Row(
          children: <Widget>[
            Container(
              width: 3,
              height: 14,
              decoration: BoxDecoration(
                color: t.hueFill(DsHue.violet),
                borderRadius: BorderRadius.circular(t.radiusPill),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                subject.displayTitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: t.hueInk(DsHue.violet), fontSize: DsTypeScale.title),
              ),
            ),
          ],
        ),
      ),
      // ⚠️ 第三十六轮**去掉了"整页限宽居中"**（用户：「左右两边留白不好看」）：
      // 1280 窗里留 74px、2048 逻辑宽（2560 屏 @125%）里留 **434px**，而 AppBar 的标题在 16px ——
      // 两条竖线对不上，两边还各空一大条。现在整页**铺满**窗口、只留 [kDetailPadding]，
      // 宽了靠**加一栏**（[kDetailThreeColumnWidth]）消化宽度，而不是靠留白。
      body: FutureBuilder<BangumiSubject>(
        future: _detail,
        builder: (BuildContext context, AsyncSnapshot<BangumiSubject> snapshot) {
          // 详情还没到就先用列表里那条（封面/标题/日期都已经有了，不必白屏）。
          final BangumiSubject full = snapshot.data ?? subject;
          final Widget? note = _note(context, snapshot);
          return LayoutBuilder(
            builder: (BuildContext context, BoxConstraints constraints) {
              return ListView(
                padding: const EdgeInsets.fromLTRB(
                  kDetailPadding,
                  12,
                  kDetailPadding,
                  32,
                ),
                children: _layout(context, ref, full, note, constraints.maxWidth),
              );
            },
          );
        },
      ),
    );
  }

  // ── 三种版面（窗口越宽栏越多）──────────────────────────────────────────────

  /// 按可用宽度选版面：≥ 1560 三栏、≥ 900 两栏、其余单栏；
  /// 三种版面**都在末尾接上**「角色 / 关联条目」两个通栏盒子（第三十七轮）。
  List<Widget> _layout(
    BuildContext context,
    WidgetRef ref,
    BangumiSubject full,
    Widget? note,
    double width,
  ) {
    final List<Widget> blocks;
    if (width >= kDetailThreeColumnWidth) {
      blocks = _threeColumn(context, ref, full, note);
    } else if (width >= kDetailRailMinWidth) {
      blocks = _twoColumn(context, ref, full, note);
    } else {
      blocks = _stackedLayout(context, ref, full, note, width);
    }
    return <Widget>[...blocks, _extrasArea(context)];
  }

  /// 信息带下面那两块整体（第四十四轮：三态 + 出现时不再"蹦"一下）。
  ///
  /// 用 `AnimatedSize` 而不是条件抽/插：这两块是**通栏**的（一屏几百像素），
  /// 从"占位"换成"内容"时高度会变很多，`AnimatedSize` 让它在这一个 token 时长里
  /// 连续长上去，而不是当帧跳一下（`DsMotion` 尊重系统「减少动画」——那时时长归零、
  /// 就等于旧行为，这是对的）。
  Widget _extrasArea(BuildContext context) {
    final List<Widget> children = _extraSections(context);
    return AnimatedSize(
      duration: DsMotion.of(context).page,
      curve: DsMotion.pageCurve,
      alignment: Alignment.topCenter,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    );
  }

  /// 信息带下面的两个通栏盒子：角色 / 关联条目（第三十七轮）+ 它们的三种状态（第四十四轮）。
  ///
  /// **为什么加它们**（用户第三十七轮：「现在下面又留空太多了，可以参考bangumi那样的布局」）：
  /// 三栏版面在 2560 屏（2048 逻辑宽）上只有 525/559/707 高，而可视高度约 1050 ——
  /// 也就是说整页比窗口**矮**，滚到底之后下面是一大片纯背景。bangumi 条目页之所以"长"，
  /// 是因为顶部信息块下面还堆着几个**通栏**盒子（简介 / 角色 / 制作人员 / 关联条目）。
  /// 这里照这个形状补上两块：它们通栏、有真实数据（实测 芙莉莲 91 位角色、21 条关联），
  /// 页面自然就比窗口高了 —— 空白不是靠拉高某一块填的，而是真的有内容。
  ///
  /// **三种状态都要画出来**（第四十四轮，用户：「加载关联等没有反馈，是突然出现在下面的」）：
  /// * 还在拉 ⇒ 一块「正在加载角色与关联条目」的占位（形状、位置就是它们将来的位置，
  ///   看完不是"下面什么都没有"，而是"这两块在路上"）；
  /// * 没拉到 ⇒ 一块「没拉到（原因）+ 重试」，**不**把整页变成错误页（上面那些信息是好的）；
  /// * 拉到一半（一条挂一条成）⇒ 挂一条黄色横幅点名**是哪一块**没拉到 + 重试，另一半照常画。
  ///
  /// 数据来源：`GET /v0/subjects/{id}/characters` 与 `/v0/subjects/{id}/subjects`
  /// （实测见 `tool/round37_subject_probe.py`）；两块都能单独为空（实测孤独摇滚两条都回 `[]`），
  /// 为空就不画那一块，也不留一条空盒子。
  List<Widget> _extraSections(BuildContext context) {
    switch (_extras) {
      case _ExtrasLoading():
        return <Widget>[
          const SizedBox(height: 16),
          _card(
            context,
            key: dsDetailExtrasLoadingKey,
            title: '角色与关联条目',
            subtitle: '正在加载…',
            child: const DsLoading(label: '正在问 Bangumi（角色 / 关联条目）…', compact: true),
          ),
        ];
      case _ExtrasFailed(:final Object error):
        return <Widget>[
          const SizedBox(height: 16),
          _card(
            context,
            key: dsDetailExtrasFailedKey,
            title: '角色与关联条目',
            subtitle: '这一块没拉到',
            child: NeoBanner(
              kind: NeoBannerKind.warning,
              text: '${describeFailure(error).message}\n'
                  '这两块是补充内容，上面那些信息不受影响。',
              action: TextButton(
                key: dsDetailExtrasRetryKey,
                onPressed: _retryExtras,
                child: const Text('重试'),
              ),
            ),
          ),
        ];
      case _ExtrasReady(:final BangumiSubjectExtra value):
        if (value.isEmpty && !value.hasFailures) return const <Widget>[];
        return <Widget>[
          const SizedBox(height: 16),
          if (value.hasFailures) ...<Widget>[
            _extrasPartialFailure(context, value),
            if (value.characters.isNotEmpty || value.related.isNotEmpty)
              const SizedBox(height: 12),
          ],
          if (value.characters.isNotEmpty) _charactersCard(context, value.characters),
          if (value.characters.isNotEmpty && value.related.isNotEmpty)
            const SizedBox(height: 12),
          if (value.related.isNotEmpty) _relatedCard(context, value.related),
        ];
    }
  }

  /// 只拉到一半时的那条横幅：**点名**是哪一块没拉到（第四十四轮）。
  ///
  /// 旧实现这种情况下连一句提示都没有：`extras()` 把失败那半边当空表返回，
  /// 页面于是画了角色、没画关联条目 —— 用户看得出"少了点什么"却无从判断
  /// （是这部没有关联条目？还是没拉到？），也没有重试的入口。
  Widget _extrasPartialFailure(BuildContext context, BangumiSubjectExtra value) {
    final List<String> missing = <String>[
      if (value.charactersError != null) '角色',
      if (value.relatedError != null) '关联条目',
    ];
    final Object? first = value.charactersError ?? value.relatedError;
    return NeoBanner(
      kind: NeoBannerKind.warning,
      text: '${missing.join('、')}没拉到（${describeFailure(first!).message}）。'
          '${value.isEmpty ? '这两块这次都没有内容' : '其余照常显示'}；不影响上面的信息。',
      action: TextButton(
        key: dsDetailExtrasPartialRetryKey,
        onPressed: _retryExtras,
        child: const Text('重试'),
      ),
    );
  }

  /// 两栏（默认）：左栏 = 海报 + 分数/事实 + 动作 + 收藏统计 + 标签；
  /// 右栏 = 标题 + 评分分布 + 资料 + 简介。
  ///
  /// 这个分法的依据是**探针量出来的高度**：1280 窗里左栏 882、右栏 914 —— 两栏几乎一样高，
  /// 所以不会出现"一边到底了另一边还空着半个屏"。
  List<Widget> _twoColumn(
    BuildContext context,
    WidgetRef ref,
    BangumiSubject full,
    Widget? note,
  ) {
    return <Widget>[
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: kDetailRailWidth,
            child: Column(
              key: dsDetailRailKey,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                _poster(context, full, kDetailRailWidth),
                const SizedBox(height: 14),
                _facts(context, full),
                const SizedBox(height: 14),
                _actions(context, ref, full),
                const SizedBox(height: 18),
                _collectionCard(context, full),
                if (full.tags.isNotEmpty) ...<Widget>[
                  const SizedBox(height: 12),
                  _tagsCard(context, ref, full),
                ],
              ],
            ),
          ),
          const SizedBox(width: 20),
          Expanded(
            child: Column(
              key: dsDetailMainKey,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                _titleBlock(context, full),
                const SizedBox(height: 14),
                _ratingCard(context, full),
                // ← 种子块（两栏：评分统计之后、资料与简介之前）
                const SizedBox(height: 12),
                _seedBlock(full),
                if (full.infobox.isNotEmpty) ...<Widget>[
                  const SizedBox(height: 12),
                  _infoboxCard(context, full),
                ],
                if ((full.summary ?? '').trim().isNotEmpty) ...<Widget>[
                  const SizedBox(height: 12),
                  _summaryCard(context, full),
                ],
                if (note != null) ...<Widget>[const SizedBox(height: 12), note],
              ],
            ),
          ),
        ],
      ),
    ];
  }

  /// 三栏（≥ 1560）：左栏 = 海报 + 分数/事实 + 动作；
  /// 中栏 = 标题 + 评分分布 + 收藏统计；右栏 = 资料 + 标签 + 简介。
  ///
  /// 三栏怎么分是照**探针量出来的高度**定的（1920 逻辑宽）：525 / 559 / 707 —— 三栏差不到 200。
  /// 第一版把收藏与标签留在左栏、右栏只放资料，量出来 740 / 520 / 550，左栏明显长出一截
  /// （截图上一眼就能看出来）。所以三栏时左栏只留"这一部是谁 + 能干什么"，
  /// 统计跟统计放一起（评分分布 + 收藏统计），详情跟详情放一起（资料 + 标签 + 简介）。
  List<Widget> _threeColumn(
    BuildContext context,
    WidgetRef ref,
    BangumiSubject full,
    Widget? note,
  ) {
    return <Widget>[
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: kDetailRailWidth,
            child: Column(
              key: dsDetailRailKey,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                _poster(context, full, kDetailRailWidth),
                const SizedBox(height: 14),
                _facts(context, full),
                const SizedBox(height: 14),
                _actions(context, ref, full),
              ],
            ),
          ),
          const SizedBox(width: 20),
          Expanded(
            child: Column(
              key: dsDetailMainKey,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                _titleBlock(context, full),
                const SizedBox(height: 14),
                _ratingCard(context, full),
                const SizedBox(height: 12),
                _collectionCard(context, full),
                // ← 种子块（三栏：中栏的统计之后；资料/标签/简介在第三栏，列序仍在它后面）
                const SizedBox(height: 12),
                _seedBlock(full),
                if (note != null) ...<Widget>[const SizedBox(height: 12), note],
              ],
            ),
          ),
          const SizedBox(width: 20),
          Expanded(
            child: Column(
              key: dsDetailSideKey,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                if (full.infobox.isNotEmpty) _infoboxCard(context, full),
                if (full.infobox.isNotEmpty && full.tags.isNotEmpty) const SizedBox(height: 12),
                if (full.tags.isNotEmpty) _tagsCard(context, ref, full),
                if ((full.summary ?? '').trim().isNotEmpty) ...<Widget>[
                  if (full.infobox.isNotEmpty || full.tags.isNotEmpty) const SizedBox(height: 12),
                  _summaryCard(context, full),
                ],
              ],
            ),
          ),
        ],
      ),
    ];
  }

  /// 窄窗：海报（够宽就与标题并排）+ 一摞卡片竖排。
  ///
  /// ⚠️ 第三十五轮**去掉了「评分分布 ∥ 收藏统计」那个并排行**：两块卡片一高一矮时，
  /// 行高由高的那块决定，矮的那块下面就是一整块空白（1280 下实测 144px）。
  List<Widget> _stackedLayout(
    BuildContext context,
    WidgetRef ref,
    BangumiSubject full,
    Widget? note,
    double width,
  ) {
    final bool posterRow = width >= kDetailPosterRowWidth;
    final Widget info = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        _titleBlock(context, full),
        const SizedBox(height: 10),
        _facts(context, full),
        const SizedBox(height: 14),
        _actions(context, ref, full),
      ],
    );
    return <Widget>[
      if (posterRow)
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            _poster(context, full, width >= 1100 ? 232 : 208),
            const SizedBox(width: 20),
            Expanded(child: info),
          ],
        )
      else ...<Widget>[
        Center(child: _poster(context, full, 168)),
        const SizedBox(height: 14),
        info,
      ],
      const SizedBox(height: 16),
      _ratingCard(context, full),
      const SizedBox(height: 12),
      _collectionCard(context, full),
      // ← 种子块（窄窗：统计之后、资料与简介之前）
      const SizedBox(height: 12),
      _seedBlock(full),
      if (full.infobox.isNotEmpty) ...<Widget>[
        const SizedBox(height: 12),
        _infoboxCard(context, full),
      ],
      if (full.tags.isNotEmpty) ...<Widget>[
        const SizedBox(height: 12),
        _tagsCard(context, ref, full),
      ],
      if ((full.summary ?? '').trim().isNotEmpty) ...<Widget>[
        const SizedBox(height: 12),
        _summaryCard(context, full),
      ],
      if (note != null) ...<Widget>[const SizedBox(height: 12), note],
    ];
  }

  /// 详情没拉到时的那条提示 / 正在补详情时的转圈（可空）。
  Widget? _note(BuildContext context, AsyncSnapshot<BangumiSubject> snapshot) {
    if (snapshot.hasError) {
      return NeoBanner(
        kind: NeoBannerKind.warning,
        text: '详情没拉到（${describeFailure(snapshot.error!).message}），'
            '上面这些是列表里已有的信息。',
        // 第四十二轮 UX #22：旧文案让人"再点一次卡片可以重试" —— 可这一屏是**整页
        // push** 进来的，屏幕上根本没有卡片可点（用户只能退回去、再从网格里找回
        // 那一张）。这里就地给一颗「重试」，行为与文案都对得上。
        action: TextButton(
          onPressed: _retryDetail,
          child: const Text('重试'),
        ),
      );
    }
    if (!snapshot.hasData) return const DsLoading(label: '正在补详情…', compact: true);
    return null;
  }

  /// 就地重拉详情（失败**不缓存**，所以重试真的会再打一次网络，见
  /// `bangumi_library.dart` 的 `detail()`：只有成功才进内存/落盘）。
  void _retryDetail() {
    setState(() {
      _detail = ref.read(bangumiLibraryProvider).detail(widget.subject.id);
    });
    _retryExtras();
  }

  // ── 版面零件 ───────────────────────────────────────────────────────────────

  /// 海报。
  ///
  /// ⚠️ 第三十六轮修（用户：「细节比如封面框有色边」）：第三十四/三十五轮这里把 `DsCover`
  /// 又套了一层 `t.inset()` + `Padding(1)` —— 而 `DsCover` 自己**已经**画了一条
  /// `sunken` 面 + 1px `line` 描边的凹槽（`cover.dart:160`）。于是海报外面是**两道颜色边**
  /// 夹着 1px 空隙，凑近看就是"封面框有色边"（动漫库网格里是**单层**，所以那边没问题）。
  /// 现在与网格一致：只让 `DsCover` 自己画那一层，圆角由它接管。
  Widget _poster(BuildContext context, BangumiSubject full, double width) {
    final DsTokens t = context.ds;
    return SizedBox(
      width: width,
      child: AspectRatio(
        aspectRatio: kPosterAspect,
        child: DsCover(
          url: full.coverUrlAt((width * MediaQuery.devicePixelRatioOf(context)).round()),
          referer: bangumiCoverReferer,
          fit: kPosterFit,
          radius: t.radiusCard,
        ),
      ),
    );
  }

  /// 标题 + 原名（两栏版面里它在右栏顶端，与左栏的海报顶对齐）。
  Widget _titleBlock(BuildContext context, BangumiSubject full) {
    final DsTokens t = context.ds;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          full.displayTitle,
          style: TextStyle(
            color: t.text,
            fontSize: DsTypeScale.display,
            fontWeight: FontWeight.w600,
            height: 1.25,
          ),
        ),
        if (full.alternateTitle case final String alt) ...<Widget>[
          const SizedBox(height: 4),
          Text(alt, style: TextStyle(color: t.text3, fontSize: DsTypeScale.body)),
        ],
      ],
    );
  }

  /// 两个动作：按番名搜种子 / 加入追番。
  ///
  /// ⚠️ 第三十七轮修（用户：「点击按这个名字搜种子，详细页不会消失还要手动关一下」）：
  /// 详情页是 `openLibraryDetail` 用 **rootNavigator push** 的**整屏路由**，而
  /// `openRecommendSearch` 只做了「填关键字 + 切 shell 的 tab」—— 路由还压在上面，
  /// 用户看到的就是"点了没走，还得自己按返回"。所以先 `maybePop` 再切
  ///（与下面标签胶囊那条路同一套做法，两条路必须一致）。
  /// ⚠️ **第四十五轮**：原来那颗「按这个名字搜种子」删掉了 —— 现在种子就在本页
  /// （[_seedBlock]），那颗按钮的旧行为（关掉详情页、跳去搜索页）反而成了绕路。
  /// 「去搜索页做跨番搜索」这条路降级成种子块里的一个小链接，没丢。
  Widget _actions(BuildContext context, WidgetRef ref, BangumiSubject full) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: <Widget>[
        // 追番 id 用 `bgm:<id>`（`followingIdFor` 的既定优先级），
        // 从库里追、从今日推荐追会落到**同一条**记录。
        FollowButton(entry: followingEntryFromBangumi(full)),
      ],
    );
  }

  /// 种子块（第四十五轮）：位置按用户选定的「封面 / 评分统计之后、资料与简介之前」，
  /// 三种版面各有一个锚点（见 [_twoColumn] / [_threeColumn] / [_stackedLayout] 里
  /// 那三处 `← 种子块` 注释）。
  Widget _seedBlock(BangumiSubject full) => LibrarySeedBlock(
    subject: full,
    onOpenSearchPage: () {
      // 与旧按钮同一套：先关掉详情页，再切到搜索页并带上这个名字。
      unawaited(Navigator.of(context).maybePop());
      openRecommendSearch(ref, full);
    },
  );

  /// 评分分布（`rating.count`）：10 档细条 + 票数 + 占比。
  ///
  /// 没有分布（搜索端点来的条目、或一部还没人评分的新番）时退回一句话说明，
  /// 不画 10 条空槽（那比空更难懂）。
  Widget _ratingCard(BuildContext context, BangumiSubject full) {
    final DsTokens t = context.ds;
    if (!full.hasRatingBreakdown) {
      return _card(
        context,
        title: '评分',
        hue: DsHue.gold,
        subtitle: 'Bangumi 还没给出分布',
        child: Text(
          full.score == null || full.score! <= 0
              ? '这一部还没有人评分。'
              : '★${full.score!.toStringAsFixed(1)}（暂时只有总分，没有分布数据）。',
          style: TextStyle(color: t.text2, fontSize: DsTypeScale.body, height: 1.5),
        ),
      );
    }
    int max = 1;
    for (final int v in full.ratingCounts.values) {
      if (v > max) max = v;
    }
    final int votes = full.ratingVotes;
    return _card(
      context,
      title: '评分分布',
      hue: DsHue.gold,
      subtitle: '共 $votes 人评分'
          '${full.score != null && full.score! > 0 ? ' · 均分 ${full.score!.toStringAsFixed(1)}' : ''}'
          '${full.rank != null && full.rank! > 0 ? ' · 排名 #${full.rank}' : ''}',
      child: Column(
        children: <Widget>[
          // 从 10 分到 1 分（分数高的在上面，与 Bangumi 页面一致）。
          for (int score = 10; score >= 1; score--)
            Padding(
              key: Key('rating-bar-$score'),
              padding: EdgeInsets.only(bottom: score == 1 ? 0 : 4),
              child: Row(
                children: <Widget>[
                  SizedBox(
                    width: 22,
                    child: Text(
                      '$score',
                      style: TextStyle(
                        color: t.text3,
                        fontSize: DsTypeScale.caption,
                        fontFeatures: DsTokens.tabular,
                      ),
                    ),
                  ),
                  Expanded(
                    child: NeoProgress(
                      value: full.ratingAt(score) / max,
                      height: 8,
                      // 最高分那档用金色（第五十二轮：评分 = 金），其余用二级色 ——
                      // 一眼看出分布形状（不是"全一样"）。
                      hue: score == 10 ? DsHue.gold : null,
                      color: score == 10 ? null : t.text3,
                    ),
                  ),
                  const SizedBox(width: 10),
                  SizedBox(
                    width: 62,
                    child: Text(
                      '${full.ratingAt(score)}',
                      textAlign: TextAlign.right,
                      style: TextStyle(
                        color: t.text2,
                        fontSize: DsTypeScale.caption,
                        fontFeatures: DsTokens.tabular,
                      ),
                    ),
                  ),
                  SizedBox(
                    width: 48,
                    child: Text(
                      votes == 0
                          ? '—'
                          : '${(full.ratingAt(score) * 100 / votes).toStringAsFixed(1)}%',
                      textAlign: TextAlign.right,
                      style: TextStyle(
                        color: t.text3,
                        fontSize: DsTypeScale.caption,
                        fontFeatures: DsTokens.tabular,
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  /// 收藏统计（`collection`）：想看 / 在看 / 看过 / 搁置 / 抛弃。
  ///
  /// ⚠️ 第三十七轮改（截图里看出来的）：原来是「标签一行、数字靠右」的五行 —— 到了
  /// 2048 逻辑宽下中间那一栏有 834 宽，标签和数字被拉开 **800 多像素**，中间全是空的，
  /// 一眼就散架。bangumi 网页这一块本来就是**一排格子**（标签在上、数字在下），
  /// 现在照那个来：每个格子固定 78 宽（3 个 + 2 个间距 = 258 ≤ 左栏内宽 268，正好一行三个），
  /// `Wrap` 排过去，多宽都不会被拉开。
  Widget _collectionCard(BuildContext context, BangumiSubject full) {
    final DsTokens t = context.ds;
    final BangumiCollection? c = full.collection;
    final List<(String, int)> cells = <(String, int)>[
      ('想看', c?.wish ?? 0),
      ('在看', c?.doing ?? 0),
      ('看过', c?.collect ?? 0),
      ('搁置', c?.onHold ?? 0),
      ('抛弃', c?.dropped ?? 0),
    ];
    return _card(
      context,
      title: '收藏统计',
      hue: DsHue.pink,
      subtitle: c == null || c.isEmpty ? '还没有人收藏' : '共 ${c.total} 人',
      child: Wrap(
        spacing: 12,
        runSpacing: 10,
        children: <Widget>[
          for (final (String label, int value) in cells)
            SizedBox(
              key: Key('collection-$label'),
              width: 78,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    label,
                    style: TextStyle(color: t.text3, fontSize: DsTypeScale.caption),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '$value',
                    style: TextStyle(
                      color: t.text,
                      fontSize: DsTypeScale.secondary,
                      fontWeight: FontWeight.w600,
                      fontFeatures: DsTokens.tabular,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  /// 资料表（`infobox`）：先 12 行，点「展开全部」看剩下的。
  Widget _infoboxCard(BuildContext context, BangumiSubject full) {
    return _card(
      context,
      title: '资料',
      hue: DsHue.slate,
      subtitle: '来自 Bangumi 条目（共 ${full.infobox.length} 行）',
      child: _InfoboxTable(items: full.infobox),
    );
  }

  /// 标签：点一个回动漫库按它筛。
  Widget _tagsCard(BuildContext context, WidgetRef ref, BangumiSubject full) {
    return _card(
      context,
      title: '标签',
      hue: DsHue.indigo,
      // 副标题原来写了半句解释（"Bangumi 没有标签大全接口…"），在任何一栏宽度里都被
      // `NeoSectionHeader` 省略号截掉一半（截图里看得见"…从条目上点最"）—— 第三十六轮改短。
      subtitle: '点一个按它回动漫库筛',
      child: Wrap(
        spacing: 6,
        runSpacing: 6,
        children: <Widget>[
          for (final String tag in full.tags.take(24))
            // 第四十四轮：不再自己画一颗 `_TagChip`，改用通用的 [NeoPill]（同一套形态）——
            // 顺带把"鼠标专用"这个毛病一起修了：这里点一下会跳回动漫库，键盘也该做得到。
            // 第五十二轮：每颗标签按 `hueOfTag` 上色（奇幻紫 / 恋爱粉 / 战斗玫红…），
            // 同一部番的同一颗标签每次渲染都是同色 —— 颜色成了"这是什么类型"的信息。
            NeoPill(
              key: Key('library-tag-$tag'),
              label: tag,
              hue: hueOfTag(tag),
              tooltip: '回动漫库按「$tag」筛',
              onTap: () {
                unawaited(Navigator.of(context).maybePop());
                openLibraryWithTag(ref, tag);
              },
            ),
        ],
      ),
    );
  }

  /// 角色（通栏）：头像 + 日文名 + 声优；先 [kDetailCharacterLimit] 位，其余点「展开全部」。
  ///
  /// ⚠️ 名字是**日文原名**（这个端点不给 `name_cn`，实测），第二行是声优（`actors[0].name`，
  /// 中文）—— bangumi 网页上那一行也是这么排的（见 [BangumiCharacter] 的注释）。
  Widget _charactersCard(BuildContext context, List<BangumiCharacter> characters) {
    return _card(
      context,
      key: dsDetailCharactersKey,
      title: '角色',
      hue: DsHue.cyan,
      subtitle: '共 ${characters.length} 位',
      child: _CharacterGrid(characters: characters),
    );
  }

  /// 关联条目（通栏）：续集 / 前传 / 不同版本 / 原声集…；小海报 + 名字 + 关系标签。
  ///
  /// 不做折叠：实测 21 条（EVA 28 条）在 2048 逻辑宽下正好一行多一点，
  /// 比"折叠 + 展开按钮"更省一次点击。
  Widget _relatedCard(BuildContext context, List<BangumiRelated> related) {
    return _card(
      context,
      key: dsDetailRelatedKey,
      title: '关联条目',
      hue: DsHue.orange,
      subtitle: '共 ${related.length} 项',
      child: Wrap(
        spacing: 10,
        runSpacing: 12,
        children: <Widget>[
          for (final BangumiRelated item in related)
            _RelatedCell(
              key: Key('related-${item.subject.id}'),
              related: item,
            ),
        ],
      ),
    );
  }

  /// 简介。
  Widget _summaryCard(BuildContext context, BangumiSubject full) {
    final DsTokens t = context.ds;
    return _card(
      context,
      title: '简介',
      hue: DsHue.teal,
      child: SelectableText(
        full.summary!.trim(),
        style: TextStyle(color: t.text2, fontSize: DsTypeScale.body, height: 1.75),
      ),
    );
  }

  /// 一块带标题的卡片（第三十四轮的版面就靠它把空的地方填成"有内容的分区"）。
  ///
  /// 第五十二轮（用户 2026-10-17「整个项目太素」）：新增 [hue] —— 每个板块一个色相，
  /// 由 `NeoSectionHeader` 画成 3px 竖条 + 色相标题。颜色是**信息**：同一位板块在
  /// 这一页的三种版面里颜色不变，用户二刷时按色就能定位（不靠逐字读标题）。
  Widget _card(
    BuildContext context, {
    required String title,
    required Widget child,
    String? subtitle,
    Key? key,
    DsHue? hue,
  }) {
    final DsTokens t = context.ds;
    return Container(
      key: key,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
      decoration: t.cardDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          NeoSectionHeader(
            title: title,
            subtitle: subtitle,
            hue: hue,
            padding: const EdgeInsets.only(bottom: 10),
          ),
          child,
        ],
      ),
    );
  }

  /// 评分 / 排名 / 放送日 / 话数 / 形态 —— 只画**真的有**的那些（不编数字）。
  ///
  /// 评分那一项做成"胶囊"（强调色实底上的数字），它是这一页最先要被看到的东西；
  /// 其余事实**一行一条**（第三十六轮）—— 原来是"一条一个 `Text` 横向折行"，
  /// 在 300 宽的左栏里折成"…28 话 / TV 36596 人评分"这种参差的第二行；
  /// 改成用 ` · ` 串成一段之后，又出现了"行尾挂着一个孤零零的 `·`"。
  /// 一行一条既没有孤零零的分隔符，扫起来也更快（左栏本来就有纵向空间）。
  Widget _facts(BuildContext context, BangumiSubject subject) {
    final DsTokens t = context.ds;
    final String? eps = subject.eps != null && subject.eps! > 0 ? '${subject.eps} 话' : null;
    final String? platform =
        (subject.platform ?? '').trim().isEmpty ? null : subject.platform!.trim();
    final List<String> lines = <String>[
      if (subject.rank != null && subject.rank! > 0) '排名 #${subject.rank}',
      if (subject.airDateLabel.isNotEmpty) '放送 ${subject.airDateLabel}',
      // 话数与形态合成一行（都短，分开写左栏会更长）。
      if (eps != null && platform != null)
        '$eps · $platform'
      else
        ?(eps ?? platform),
      if (subject.ratingVotes > 0) '${subject.ratingVotes} 人评分',
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        // 评分胶囊：第五十二轮改用金色（评分 = gold）—— 它是这一页最先要被看到的东西，
        // 金色也是「评分分布」板块的色，两处对得上；还没评分时仍用金色，只把文字说成"暂无"。
        Container(
          key: const Key('library-detail-score'),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: t.hueSoft(DsHue.gold),
            borderRadius: BorderRadius.circular(t.radiusPill),
          ),
          child: Text(
            subject.score == null || subject.score! <= 0
                ? '暂无评分'
                : '★${subject.score!.toStringAsFixed(1)}',
            style: TextStyle(
              color: t.hueInk(DsHue.gold),
              fontSize: DsTypeScale.title,
              fontWeight: FontWeight.w600,
              fontFeatures: DsTokens.tabular,
            ),
          ),
        ),
        for (final String line in lines)
          Padding(
            padding: const EdgeInsets.only(top: 3),
            child: Text(
              line,
              style: TextStyle(
                color: t.text2,
                fontSize: DsTypeScale.secondary,
                height: 1.4,
                fontFeatures: DsTokens.tabular,
              ),
            ),
          ),
      ],
    );
  }
}

/// 角色 / 关联条目那两块的状态（第四十四轮，用户：「优化详细页反馈。加载关联等没有反馈，
/// 是突然出现在下面的」）。
///
/// 旧实现只有一个 `BangumiSubjectExtra? _extra`，而 `null` 同时表示三件事：
/// "还在拉""没拉到""拉到了但两块都为空"。于是
/// * 拉的时候下面**什么都没有**（那两块是通栏的、一跳几百像素 ⇒ "突然出现在下面"）；
/// * 两条端点都挂时也是**什么都没有**，用户永远分不出"这部没有角色"与"网络没拉到"。
/// 拆成三态之后：占位 / 内容（部分失败再挂横幅）/ 失败+重试。
sealed class _ExtrasState {
  const _ExtrasState();
}

/// 还在拉（画占位，形状与位置就是将来那两块的位置）。
class _ExtrasLoading extends _ExtrasState {
  const _ExtrasLoading();
}

/// 拿到了（可能是空表，也可能缺一半 —— 缺的那半看 `hasFailures`）。
class _ExtrasReady extends _ExtrasState {
  const _ExtrasReady(this.value);

  final BangumiSubjectExtra value;
}

/// 两条端点都没拿到（端口在这种情况下会抛）。
class _ExtrasFailed extends _ExtrasState {
  const _ExtrasFailed(this.error);

  final Object error;
}

/// 资料表：键 + 值两列；超过 [kDetailInfoboxPreviewRows] 行时折叠，按钮展开。
///
/// ⚠️ 值那一列用 `Text` 而**不是** `SelectableText`（第三十五轮）：`SelectableText` 即使
/// 只有一行字也按 `maxLines: 2` 占**两行**高度（探针实测 42px/行，12 行预览 = 627px）。
/// 代价是资料表里的值不能再拖选复制 —— 简介那一块仍然是 `SelectableText`，
/// 需要复制长文本时从那儿拿。
class _InfoboxTable extends StatefulWidget {
  const _InfoboxTable({required this.items});

  final List<BangumiInfoboxItem> items;

  @override
  State<_InfoboxTable> createState() => _InfoboxTableState();
}

class _InfoboxTableState extends State<_InfoboxTable> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final DsTokens t = context.ds;
    final bool foldable = widget.items.length > kDetailInfoboxPreviewRows;
    final List<BangumiInfoboxItem> shown =
        _expanded || !foldable ? widget.items : widget.items.take(kDetailInfoboxPreviewRows).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        for (final BangumiInfoboxItem item in shown)
          Padding(
            key: Key('infobox-${item.key}'),
            padding: const EdgeInsets.only(bottom: 5),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                SizedBox(
                  width: 96,
                  child: Text(
                    item.key,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: t.text3, fontSize: DsTypeScale.secondary),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    item.text,
                    maxLines: _expanded ? 6 : 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: t.text, fontSize: DsTypeScale.secondary, height: 1.5),
                  ),
                ),
              ],
            ),
          ),
        if (foldable) ...<Widget>[
          const SizedBox(height: 4),
          NeoButton(
            key: const Key('library-detail-infobox-toggle'),
            label: _expanded
                ? '收起'
                : '展开全部（还有 ${widget.items.length - kDetailInfoboxPreviewRows} 行）',
            icon: _expanded ? Icons.expand_less : Icons.expand_more,
            compact: true,
            onPressed: () => setState(() => _expanded = !_expanded),
          ),
        ],
      ],
    );
  }
}

/// 角色网格：先 [kDetailCharacterLimit] 位，其余折叠（第三十七轮）。
///
/// 为什么折叠而不是全画（实测芙莉莲 91 位、EVA 97 位）：全画就是十几行格子，
/// 把"关联条目"顶到几屏之外；bangumi 网页自己也是"先列十几个 + 更多角色"。
class _CharacterGrid extends StatefulWidget {
  const _CharacterGrid({required this.characters});

  final List<BangumiCharacter> characters;

  @override
  State<_CharacterGrid> createState() => _CharacterGridState();
}

class _CharacterGridState extends State<_CharacterGrid> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final bool foldable = widget.characters.length > kDetailCharacterLimit;
    final List<BangumiCharacter> shown = _expanded || !foldable
        ? widget.characters
        : widget.characters.take(kDetailCharacterLimit).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Wrap(
          spacing: 10,
          runSpacing: 12,
          children: <Widget>[
            for (final BangumiCharacter character in shown)
              _CharacterCell(character: character),
          ],
        ),
        if (foldable) ...<Widget>[
          const SizedBox(height: 10),
          NeoButton(
            key: const Key('library-detail-characters-toggle'),
            label: _expanded
                ? '收起'
                : '展开全部（还有 ${widget.characters.length - kDetailCharacterLimit} 位）',
            icon: _expanded ? Icons.expand_less : Icons.expand_more,
            compact: true,
            onPressed: () => setState(() => _expanded = !_expanded),
          ),
        ],
      ],
    );
  }
}

/// 一个角色格子：正方形头像 + 名字（日文原名，最多两行）+ 声优。
class _CharacterCell extends StatelessWidget {
  const _CharacterCell({required this.character});

  final BangumiCharacter character;

  @override
  Widget build(BuildContext context) {
    final DsTokens t = context.ds;
    final String? actor = character.actorName;
    return SizedBox(
      key: Key('character-${character.id}'),
      width: kDetailCharacterCellWidth,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          AspectRatio(
            aspectRatio: 1,
            child: DsCover(
              // `/pic/crt/l/…`：与封面同一套档位，`DsCover` 内部走 [bangumiImageAt] 抬档。
              url: character.avatarUrl,
              referer: bangumiCoverReferer,
              radius: t.radiusControl,
              placeholderLabel: '无头像',
            ),
          ),
          const SizedBox(height: 5),
          Text(
            character.label,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: t.text, fontSize: DsTypeScale.caption, height: 1.3),
          ),
          if (actor != null)
            Text(
              actor,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: t.text3, fontSize: DsTypeScale.caption),
            ),
        ],
      ),
    );
  }
}

/// 一条关联条目：小海报（固定 [kPosterAspect] 槽，`contain` 不裁）+ 名字 + 关系标签。
class _RelatedCell extends StatelessWidget {
  const _RelatedCell({required this.related, super.key});

  final BangumiRelated related;

  @override
  Widget build(BuildContext context) {
    final DsTokens t = context.ds;
    final BangumiSubject subject = related.subject;
    final double dpr = MediaQuery.devicePixelRatioOf(context);
    return SizedBox(
      width: kDetailRelatedCellWidth,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          AspectRatio(
            aspectRatio: kPosterAspect,
            child: DsCover(
              url: subject.coverUrlAt((kDetailRelatedCellWidth * dpr).round()),
              referer: bangumiCoverReferer,
              fit: kPosterFit,
              radius: t.radiusControl,
            ),
          ),
          const SizedBox(height: 5),
          Text(
            subject.displayTitle,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: t.text, fontSize: DsTypeScale.caption, height: 1.3),
          ),
          // 第五十二轮（用户 2026-10-17「整个项目太素」）：关系标签（续集 / 前传 /
          // 原声集…）从一行灰字改成**色相小胶囊** —— 同一关系名每次渲染同色
          //（`hueOfTag` 的稳定哈希兜底），一眼分得清"这是哪一类关联"。
          if (related.relation.isNotEmpty)
            NeoPill(label: related.relation, hue: hueOfTag(related.relation)),
        ],
      ),
    );
  }
}
