/// 宿主主外壳（按 spec §7.4 渲染图定稿的形态；§7.5/§7.6 追加主页与正在追；第二十一轮去掉「已缓存」；
/// **第二十七轮**：「订阅」页整页删掉、新增「观看记录」页；**第二十七轮补记**：「观看记录」
/// 从顶部导航列表搬到左下角 = 设置那一行的上面）：
///
/// ```
/// ┌───────────┬──────────────────────────────────────────────┐
/// │ DSAnima   │ 工具条：页名 + 源切换 + 窗口按钮              │
/// │ 主页       ├──────────────────────────────────────────────┤
/// │ 搜索       │ 内容（IndexedStack：播放器常驻不丢请求）      │
/// │ 正在追     │                                              │
/// │ 队列       │                                              │
/// │ 已完成     │                                              │
/// │           │                                              │
/// │ 观看记录   ├──────────────────────────────────────────────┤
/// │ 设置（左下角，整行）│ 底部状态条：引擎/速率/对等/磁盘        │
/// └───────────┴──────────────────────────────────────────────┘
/// ```
/// （「观看记录」与「正在播放 / 继续播放」都在左下角那一块、设置上面：在播时从上到下是
/// 观看记录 → 正在播放 → 设置，不在播时就只剩 观看记录 → 设置。）
///
/// 播放页自带 ShikiiN 的标题栏（含窗口拖动与窗口按钮），所以**只在非播放页**
/// 渲染宿主自己的工具条，避免一条窗口里出现两条标题栏。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:window_manager/window_manager.dart';

import '../domain/error_text.dart';
import '../domain/models.dart';
import '../domain/ports.dart';
import '../state/playback.dart';
import '../state/providers.dart';
import '../theme/tokens.dart';
import 'completed_page.dart';
import 'following_page.dart';
import 'history_page.dart';
import 'home_page.dart';
import 'library_page.dart';
import 'queue_page.dart';
import 'search_page.dart';
import 'settings_page.dart';
import 'widgets/brand_icon.dart';
import 'widgets/neo.dart';

class DsShell extends ConsumerStatefulWidget {
  const DsShell({super.key});

  @override
  ConsumerState<DsShell> createState() => _DsShellState();
}

/// 内容区 [IndexedStack] 的 key（测试用来精确定位「当前在哪一页」）。
///
/// 不能用 `find.byType(IndexedStack).first`：工具条里的源下拉是 `DropdownButton`，
/// 它内部也用了 `IndexedStack`，而且在树里排在内容区**前面**。
const ValueKey<String> dsShellContentKey = ValueKey<String>('ds-shell-content');

/// 状态栏那颗引擎点的 key（用户 2026-10-11 第 8 项：点它弹小面板）。
///
/// 测试用它当锚点，而不是 `find.byTooltip`：tooltip 文本随连接状态与目录提示变，
/// 侧栏底部还有一个同样挂着状态 tooltip 的引擎块，整串匹配会一次命中两个。
const ValueKey<String> dsEngineDotKey = ValueKey<String>('ds-engine-dot');

/// 侧栏左下角那颗设置齿轮的 key（第 14 轮：设置入口从导航列表搬到左下角）。
///
/// 同样给测试当锚点：齿轮只有一个，但按 icon 找会撞上设置页里的一堆齿轮图标。
const ValueKey<String> dsSettingsGearKey = ValueKey<String>('ds-settings-gear');

/// 侧栏**左下角那一块**（设置上面）里某一项那一行的 key —— 现在只有「观看记录」。
///
/// ⚠️ **第二十七轮补记**（用户：「观看记录改到左下角设置的上面」）：测试拿它当锚点，
/// 确认那一行真的在侧栏里、在设置那一行的**上面**，而且已经不在顶部导航列表里
/// （`shellNavTabs` 里没有 `history` 了）。命名与渲染处的 key 由这个函数统一给出，
/// 免得测试里再抄一遍字符串。
ValueKey<String> dsSidebarFooterRowKey(ShellTab tab) =>
    ValueKey<String>('ds-sidebar-footer-${tab.name}');

class _DsShellState extends ConsumerState<DsShell> {
  /// 已通知过的任务 id（本轮会话；避免同一集反复弹通知）。
  static final Set<String> _notified = <String>{};

  /// 本会话开始时刻：**只有在这个时刻之后创建的任务才算"刚刚命中"**。
  ///
  /// 用户 2026-10-11：「订阅是订阅下载是下载，每次启动队列有东西就会弹订阅已命中」——
  /// 队列是从 Hive 恢复的，上次会话入队的订阅任务重启后会被当成"刚刚命中"再通知一遍，
  /// 于是**每启动一次弹一次**。判据必须落在"任务是什么时候建的"上，而不是"我第一次
  /// 看到这个列表是什么时候"：后者会把启动期间真的新命中的那一集也一起吞掉。
  final DateTime _sessionStart = DateTime.now();

  StreamSubscription<String>? _notificationClicks;

  @override
  void initState() {
    super.initState();
    // 点系统通知 → 跳到播放：payload 是 `job:<id>`（spec §7.3 Q16）。
    // 通知端口未接通时是空流，什么都不做。
    _notificationClicks = ref.read(notificationPortProvider).clicks.listen(_onNotificationClick);
  }

  @override
  void dispose() {
    unawaited(_notificationClicks?.cancel());
    super.dispose();
  }

  Future<void> _onNotificationClick(String payload) async {
    if (!payload.startsWith('job:')) return;
    final String jobId = payload.substring(4);
    final List<QueueJobView>? jobs = ref.read(queueJobsProvider).value;
    QueueJobView? job;
    for (final QueueJobView j in jobs ?? const <QueueJobView>[]) {
      if (j.id == jobId) job = j;
    }
    if (job == null) return;
    await ref.read(playbackProvider.notifier).playItem(job.item);
    // 起播即弹播放窗口（用户 2026-10-10：只有弹窗播放），主窗口不切页。
  }

  /// 新集数命中订阅 → 系统通知（spec §7.3 Q16）。
  ///
  /// 通知端口未接通时静默降级，但「发生了什么」始终留在队列页，
  /// 不假装通知成功。
  ///
  /// ⚠️ **只通知本会话新入队的**（用户 2026-10-11：「每次启动队列有东西就会弹订阅已命中」）：
  /// 恢复出来的旧任务先按"已读"标掉，不弹。判据是任务的 `createdAt`（随任务持久化），
  /// 所以启动期间真的新命中的那一集照样会弹。
  void _onJobs(List<QueueJobView>? jobs) {
    if (jobs == null) return;
    final NotificationPort port = ref.read(notificationPortProvider);
    if (!port.isAvailable) return;
    for (final QueueJobView job in jobs) {
      if (_notified.contains(job.id)) continue;
      if (!job.createdAt.isAfter(_sessionStart)) {
        // 上次会话就躺在队列里的（或本次启动前建的）：标成已读，不弹。
        _notified.add(job.id);
        continue;
      }
      if (job.subscriptionId.isEmpty || !job.state.isActive) continue;
      _notified.add(job.id);
      unawaited(
        port.notify(
          title: '订阅命中：${job.item.group ?? job.subscriptionId}',
          body: job.displayTitle,
          payload: 'job:${job.id}',
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final DsTokens t = context.ds;
    final ShellTab tab = ref.watch(navProvider);
    // 只能在 build 里注册 listen（Riverpod 3 的断言）。
    ref.listen<AsyncValue<List<QueueJobView>>>(
      queueJobsProvider,
      (AsyncValue<List<QueueJobView>>? previous, AsyncValue<List<QueueJobView>> next) =>
          _onJobs(next.value),
    );
    return Scaffold(
      backgroundColor: t.base,
      // ⚠️ **第二十九轮：底部状态条整条删除**（决策 F3/F16/F20）。引擎状态改成侧栏
      // 左下角一个 6px 状态点（`_EngineDot`，文字只在 tooltip 里），窗口底部不再占一条；
      // 播放入口本来就在侧栏（`_ResumePlayingRow`，第十七轮搬过去的）。
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                const _Sidebar(),
                Expanded(
                  child: Column(
                    children: <Widget>[
                      const _Toolbar(),
                      Expanded(
                        // Key 是给测试用的：工具条里的源下拉（DropdownButton 内部也有
                        // IndexedStack）会让 `find.byType(IndexedStack).first` 抓错控件。
                        child: IndexedStack(
                          key: dsShellContentKey,
                          index: tab.index,
                          // ⚠️ 顺序必须与 `ShellTab.values` 一一对应（`tab.index` 就是下标）。
                          children: const <Widget>[
                            HomePage(),
                            LibraryPage(),
                            SearchPage(),
                            FollowingPage(),
                            QueuePage(),
                            CompletedPage(),
                            HistoryPage(),
                            SettingsPage(),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 左侧栏
// ─────────────────────────────────────────────────────────────────────────────

class _Sidebar extends ConsumerWidget {
  const _Sidebar();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final DsTokens t = context.ds;
    final ShellTab active = ref.watch(navProvider);
    final QueueSummary summary = ref.watch(queueSummaryProvider);
    final int followingCount = ref.watch(followingCountProvider);
    return Container(
      width: 184,
      // 侧栏与内容的分区不用 1px 硬边框（规范 §5）：凸起面 + 柔光内边 + 右侧浅阴影。
      decoration: BoxDecoration(
        color: t.surface,
        border: Border.all(color: t.line, width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onPanStart: (_) => windowManager.startDragging(),
            child: SizedBox(
              height: t.barHeight,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(
                  children: <Widget>[
                    // 品牌位 = 播放器那张图标（用户 2026-10-10：图标统一）。
                    // 不再是「DS 字样方块」：字形块只在侧栏出现过一次，
                    // 与任务栏/托盘/exe 的图标不是同一个东西，看着像两个产品。
                    const DsBrandIcon(size: 22),
                    const SizedBox(width: 8),
                    Text(
                      'DSAnima',
                      style: TextStyle(
                        color: t.text,
                        fontSize: DsTypeScale.title,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.2,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          // 第二十九轮（决策 F16）：侧栏标题下那条分隔线删掉 —— 分区改由 24 的间距表达。
          const SizedBox(height: 6),
          // 导航项里**没有「设置」**（[shellNavTabs] 已把它排除）：用户 2026-10-12
          // 第十四轮「主窗口的设置改为右下角」，随后更正为**左下角** ——
          // 设置入口在侧栏最底下那颗齿轮里（见下面的 _SettingsGear）。
          // ⚠️ 第三十三轮：顶部导航区改成**可压缩 + 可滚动**（原来是 `Spacer` 兜着）。
          // 加了「动漫库」这一项之后，用户把窗口压到 400px 高时这一列直接
          // `RenderFlex overflowed by 20 pixels`（用例 `shell_widget_test` 钉着矮窗口不溢出）。
          // 现在：导航区吃掉剩余高度（窗口高 = 导航项自然排布 + 底部那块固定在下面），
          // 高不够时它自己滚 —— 底部那块（观看记录 / 继续播放 / 设置 / 引擎点）位置不变。
          Expanded(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  for (final ShellTab tab in shellNavTabs)
                    _NavItem(
                      tab: tab,
                      selected: tab == active,
                      badge: switch (tab) {
                        ShellTab.queue when (summary.active + summary.queued) > 0 =>
                          '${summary.active + summary.queued}',
                        ShellTab.following when followingCount > 0 =>
                          '$followingCount',
                        _ => null,
                      },
                      onTap: () => unawaited(_selectTab(ref, context, tab)),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 10),
          // 左下角那一块（用户 2026-10-11 第 1 轮问答之后只剩引擎点；第十四轮把设置入口
          // 挪到它旁边；**第十七轮**把「继续播放」也搬到齿轮正上方）。
          // ⚠️ **第二十四轮**：原来齿轮旁边那颗引擎点（链接图标 + 小圆点）删掉了 ——
          // 用户：「去除最左边的小绿点，换成右边那个仅保留一个」，随后补充
          // 「把状态栏那颗移到左边」。现在唯一的引擎点在**窗口最左下角**那条
          // 铺满整窗的状态栏里（见本文件 build 的结构与 `_StatusBar`）。
          //
          // ⚠️ **第二十七轮补记**（用户：「观看记录改到左下角设置的上面」）：
          // 「观看记录」原来被当成第 6 个导航项排在**顶部列表最后** —— 顶部列表底下隔着一个
          // `Spacer()` 才是设置入口，于是它离设置有一大段空白，根本不是"设置的上面"。
          // 现在它跟设置一样落在**左下角这一块**：设置在最底下（齿轮那一行不动），
          // 「观看记录」在它上面。中间夹着的 `_ResumePlayingRow` 是第十七轮用户点名要
          // "设置上面"的那一行，位置照旧（只在播时渲染，不渲染时 观看记录 就直接贴着设置）。
          for (final ShellTab tab in shellFooterTabs)
            _NavItem(
              key: dsSidebarFooterRowKey(tab),
              tab: tab,
              selected: tab == active,
              onTap: () => unawaited(_selectTab(ref, context, tab)),
            ),
          const _ResumePlayingRow(),
          // ⚠️ 第二十六轮：设置入口从"左下角一颗按钮"搬成**与导航项同形态的一整行**，
          // 所以这里不再套外层 Row（那样会给无界宽度，见 `_SettingsGear` 的说明）——
          // 只留底部外边距，由 `_SettingsGear` 自己带与 `_NavItem` 相同的 4px 内边距。
          Padding(
            // ⚠️ **第三十一轮**（用户：「侧边栏的小绿点放到设置下面」）：引擎状态点从
            // "设置上面"挪到了**最下面**，所以这里不再留 12 的底部外边距 ——
            // 那一块底部间距现在归 `_EngineDot` 自己带。
            padding: const EdgeInsets.only(bottom: 2),
            child: _SettingsGear(selected: active == ShellTab.settings),
          ),
          // 引擎状态点：**侧栏最下面**（第二十九轮从窗口底部那条状态栏搬过来；
          // 第三十一轮按用户要求从"设置上面"挪到"设置下面"）。
          const Padding(padding: EdgeInsets.only(bottom: 10), child: _EngineDot()),
        ],
      ),
    );
  }
}

/// 侧栏左下角的设置入口（用户 2026-10-12 第十四轮：「主窗口的设置改为左下角」）。
///
/// 为什么不是列表里的第 8 项：设置不是"一个常驻目的地"，它是低频的配置入口；
/// 原来它跟着其它 7 项排在最上面，和「主页/搜索」这些天天点的东西同权重。
/// 挪到底部那一排之后，导航列表回到 7 项、设置也有了自己的位置。
///
/// ⚠️ **第二十六轮**（用户：「设置按钮改为跟其他的按钮一样的形态」）：
/// 以前这里是「一颗 30×30 凸起方块图标按钮 + 右边悬空的两个字」—— 那颗方块和
/// 侧栏里任何一颗导航项都不是一种东西（一个是凸起按钮，其它是有色的整行命中区），
/// 所以它看起来像"贴上去的第三样控件"。现在改成**和 7 个导航项完全同一套形态**：
/// 图标 16 + 文字 + 整行 `GestureDetector`，悬停实色 `sunken`、选中 `sunkenDecoration`
/// 且图标与文字都走强调色（用户第二十五轮定的"鼠标在上面就黑着"的实色规则照旧）。
/// 命中区是**整行**：图标、文字、行距全都可点，不再只有那 30×30 的一小块。
///
/// 位置（左下角、状态栏之上）**没动**：那几处布局约定是 `shell_widget_test` 与
/// 用户前几轮明确钉过的。⚠️ 第二十七轮补记之后，它**上面**多了「观看记录」那一行
/// （用户：「观看记录改到左下角设置的上面」）；再往上是只在播时渲染的
/// `_ResumePlayingRow`，然后是导航列表、`Spacer()`。
/// ⚠️ **第三十一轮**：它**下面**又多了引擎状态点（用户：「侧边栏的小绿点放到设置下面」）
/// —— 设置仍然是"从下面数第二行"，只是底下不再是窗口边，而是那颗点。
class _SettingsGear extends ConsumerStatefulWidget {
  const _SettingsGear({required this.selected});

  final bool selected;

  @override
  ConsumerState<_SettingsGear> createState() => _SettingsGearState();
}

class _SettingsGearState extends ConsumerState<_SettingsGear> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final DsTokens t = context.ds;
    final bool selected = widget.selected;
    final Color fg = selected ? t.accent : (_hover ? t.text : t.text2);
    // 与 `_NavItem` 同一套：选中 = 凹槽实色；悬停 = 实色 `sunken`（不做过渡动画，
    // 免得又出现第二十五轮那种"半透明底色的 lerp 中间帧"黑一下）。
    // 扁平（规范 §11.6）：选中 = **accent 12% 底 + accent 图标与文字**（不再是"凹槽实色"）。
    final Decoration bg = BoxDecoration(
      color: selected ? t.accentSoft : (_hover ? t.sunken : Colors.transparent),
      borderRadius: BorderRadius.circular(t.radiusControl),
    );
    return Padding(
      // 与 `_NavItem` 完全相同的外层内边距（4）—— 侧栏里这两行的左边界因此对齐。
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => unawaited(_selectTab(ref, context, ShellTab.settings)),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Container(
              // 内层同 `_NavItem`：`horizontal: 8` 让图标与文字落在同一列。
              // ⚠️ 这一行**必须是侧栏 Column 的直接子级**（外面只能有 Padding）。
              // 第二十六轮踩过：为了"内容居中"把它包进一个 `mainAxisSize.min` 的 Row，
              // 那个 Row 会给子级**无界宽度**，于是这里的 `Expanded` 直接抛
              // `RenderFlex children have non-zero flex but incoming width constraints are
              // unbounded`（改用 `Flexible` 则高亮缩到内容宽 ~64px，与导航项不一致；
              // `SizedBox(width: double.infinity)` 又会传 `w=Infinity` 硬约束）。
              // 作为 `crossAxisAlignment.stretch` 的 Column 的直接子级，宽度就是侧栏宽，
              // `Expanded` 正常、高亮与 7 个导航项**同宽**（`shell_widget_test` 钉住）。
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
              decoration: bg,
              child: Row(
                children: <Widget>[
                  // key 仍挂在**齿轮图标**上（`shell_widget_test` 的锚点：拿它的 Rect
                  // 与「设置」两个字比位置，还要求它排在引擎点/状态栏之上）。
                  Icon(
                    key: dsSettingsGearKey,
                    Icons.settings_outlined,
                    size: 16,
                    color: fg,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      ShellTab.settings.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: fg,
                        fontSize: DsTypeScale.secondary,
                        fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 侧栏左下角那一行「继续播放」的 key（回归测试用它确认**搬到了设置上面**）。
const ValueKey<String> dsResumePlayingKey = ValueKey<String>('ds-resume-playing');

/// 切页：设置页有未保存的改动时**先拦一下**（2026-10-12 第十六轮：手动保存）。
///
/// 为什么收在这里：导航列表的 7 项与左下角那颗设置齿轮都要走同一条判断。
/// 只有"当前就在设置页"才需要问 —— 页面在 `IndexedStack` 里一直活着，而草稿只可能在
/// 用户看着设置页时变脏（离开它本来就得先过这一问）。
Future<void> _selectTab(WidgetRef ref, BuildContext context, ShellTab tab) async {
  if (tab == ref.read(navProvider)) return;
  if (ref.read(navProvider) == ShellTab.settings) {
    final bool ok = await resolveUnsavedSettings(ref.read(settingsDraftGuardProvider), context);
    if (!ok) return;
  }
  ref.read(navProvider.notifier).select(tab);
}

/// 一个导航项（顶部导航区与左下角那一块共用同一个形态）。
///
/// 每个 [ShellTab] 的 label 文本是回归测试盯着的（每一项都必须可见）；
/// 视觉改造只动观感：选中 = 凹进去 + 强调色（决策 A40），
/// 未选中 = 透明 + `text2`（规范 §7 导航项）。
///
/// ⚠️ 它现在被用在**两处**：顶部导航区（`shellNavTabs`）与左下角那一块
/// （`shellFooterTabs`，第二十七轮补记之后 = 只有「观看记录」一行，在设置上面）。
/// `key` 由调用方给（左下角那块用 `dsSidebarFooterRowKey`，测试靠它定位）。
class _NavItem extends StatefulWidget {
  const _NavItem({
    super.key,
    required this.tab,
    required this.selected,
    required this.onTap,
    this.badge,
  });

  final ShellTab tab;
  final bool selected;
  final VoidCallback onTap;
  final String? badge;

  @override
  State<_NavItem> createState() => _NavItemState();
}

class _NavItemState extends State<_NavItem> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final DsTokens t = context.ds;
    final ShellTab tab = widget.tab;
    final bool selected = widget.selected;
    final IconData icon = switch (tab) {
      ShellTab.home => Icons.home_outlined,
      ShellTab.library => Icons.collections_bookmark_outlined,
      ShellTab.search => Icons.search,
      ShellTab.following => Icons.favorite_border,
      ShellTab.queue => Icons.downloading,
      ShellTab.completed => Icons.task_alt,
      ShellTab.history => Icons.history,
      ShellTab.settings => Icons.settings_outlined,
    };
    final Color fg = selected ? t.accent : (_hover ? t.text : t.text2);
    // ⚠️ 第二十五轮（用户：「鼠标拖动到主页 搜索 正在追…时黑一下，改成鼠标在上面就黑着，
    // 符合逻辑」）。根因是悬停底色原来写的是 `t.raised.withValues(alpha: 0.55)`：
    // 侧栏底色**就是** `t.raised`，那层半透明底色静止时等于看不见；而 AnimatedContainer
    // 从 `Colors.transparent`（= 全透明黑）渐变到它时，中间帧是**先乘 alpha 的暗色**
    // （深色主题下最明显）—— 于是"黑一下"就出现了。
    // 现在：悬停底色用**实色** `t.sunken`（凹槽色；深色主题里它就是更黑的那一档），
    // 且**不做过渡动画** —— 指针在上面就一直黑着，不会忽明忽暗。
    // 扁平（规范 §11.6）：选中 = **accent 12% 底 + accent 图标与文字**（不再是"凹槽实色"）。
    final Decoration bg = BoxDecoration(
      color: selected ? t.accentSoft : (_hover ? t.sunken : Colors.transparent),
      borderRadius: BorderRadius.circular(t.radiusControl),
    );
    return Padding(
      // ⚠️ 侧栏固定 184px（回归测试盯着这个宽度）。四条中文 label（「正在播放」）在
      // 12px 字号下离边界只有几像素余量 —— 真机实测会折行。这里把导航项左右内边距
      // 收到 8px 换回余量（改为写在下面的内层内边距里）。
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        // 命中区覆盖**整行**（连行距一起）：原来那 3px 垂直内边距在 MouseRegion **外面**，
        // 指针从「主页」滑到「搜索」时会先离开再进入 → 高亮闪一下。现在行距放进命中区，
        // 只让里面那层负责视觉上的分开。
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
              decoration: bg,
              child: Row(
                children: <Widget>[
                  Icon(icon, size: 16, color: fg),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      tab.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: fg,
                        fontSize: DsTypeScale.secondary,
                        fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                      ),
                    ),
                  ),
                  if (widget.badge case final String badge) ...<Widget>[
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                      decoration: BoxDecoration(
                        color: t.accentSoft,
                        borderRadius: BorderRadius.circular(t.radiusPill),
                      ),
                      child: Text(
                        badge,
                        style: TextStyle(
                          color: t.accent,
                          fontSize: DsTypeScale.caption,
                          fontFeatures: DsTokens.tabular,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 引擎状态（用户 2026-10-10 第 1 轮问答：「压成一个小圆点 + tooltip」）。
///
/// ⚠️ **第二十四轮删掉了侧栏这一块**（原来在设置齿轮右边：链接图标 + 小圆点）。
/// 用户原话：「去除最左边的小绿点，换成右边那个仅保留一个」，追问后是
/// 「让状态栏铺到侧栏下面，点在窗口最左下角」—— 于是全窗口只剩
/// [dsEngineDotKey] 那一颗点（在铺满整窗的状态栏里，点它弹引擎小面板）。
/// 这块连同它的"点一下去设置页"一起删掉：同一个状态两处入口，本来就没必要。
/// 相关布局见 `_DsShellState.build` 与 `_StatusBar`。

// ─────────────────────────────────────────────────────────────────────────────
// 工具条（非播放页）
// ─────────────────────────────────────────────────────────────────────────────

class _Toolbar extends ConsumerWidget {
  const _Toolbar();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final DsTokens t = context.ds;
    final ShellTab tab = ref.watch(navProvider);
    final List<SourceOption> sources = ref.watch(sourceOptionsProvider);
    return Container(
      height: t.barHeight,
      // 扁平（规范 §3/§7）：工具条 = `raised` 面，**零阴影、零描边** —— 与内容的
      // 分区靠色差（base 底 vs raised 条）。
      decoration: BoxDecoration(color: t.surface),
      child: Row(
        children: <Widget>[
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onPanStart: (_) => windowManager.startDragging(),
              onDoubleTap: () async {
                if (await windowManager.isMaximized()) {
                  await windowManager.unmaximize();
                } else {
                  await windowManager.maximize();
                }
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14),
                child: Align(
                  alignment: Alignment.centerLeft,
                  // 用户 2026-10-10 第 4–20 轮清单：页名旁那句小字说明（tab.subtitle）
                  // 删掉 —— 页名本身已经说清楚，副标题只是在重复（`ShellTab.subtitle`
                  // 仍留着：它现在只用于测试与未来的搜索/命令面板）。
                  child: Text(
                    tab.label,
                    style: TextStyle(
                      color: t.text,
                      fontSize: DsTypeScale.title,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ),
          ),
          // 源选择搬到搜索页了（用户 2026-10-10 第 2 轮问答：「工具条只留页名 +
          // 窗口按钮，源下拉只在搜索页」）。这里只在源未接通时留一个警告。
          if (tab == ShellTab.search && sources.isEmpty)
            const Padding(padding: EdgeInsets.only(right: 10), child: _SourceUnavailableChip()),
          const Padding(padding: EdgeInsets.only(right: 6), child: _WindowButtons()),
        ],
      ),
    );
  }
}

class _SourceUnavailableChip extends StatelessWidget {
  const _SourceUnavailableChip();

  @override
  Widget build(BuildContext context) {
    final DsTokens t = context.ds;
    return Tooltip(
      message: '源未接通：core 的 sources/ 尚未注入'
          '（nyaa / mikan / dmhy / acgrip / acgnx / bangumi.moe / 自定义 RSS）',
      child: Container(
        padding: const EdgeInsets.fromLTRB(8, 6, 11, 6),
        // 语义色只以小面积出现（规范 §2.3）：左侧 2px 警告色细条 + 无边框凸起面。
        decoration: t.cardDecoration(
          radius: t.radiusControl,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Container(
              width: 3,
              height: 14,
              decoration: BoxDecoration(
                color: t.warning,
                borderRadius: BorderRadius.circular(t.radiusPill),
              ),
            ),
            const SizedBox(width: 7),
            Icon(Icons.link_off, size: 12, color: t.warning),
            const SizedBox(width: 6),
            Text(
              '源未接通',
              style: TextStyle(color: t.warning, fontSize: DsTypeScale.caption),
            ),
          ],
        ),
      ),
    );
  }
}

class _WindowButtons extends StatelessWidget {
  const _WindowButtons();

  @override
  Widget build(BuildContext context) {
    return const Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        _WindowButton(icon: Icons.remove, tooltip: '最小化', kind: _WinKind.min),
        _WindowButton(icon: Icons.crop_square, tooltip: '最大化 / 还原', kind: _WinKind.max),
        _WindowButton(icon: Icons.close, tooltip: '关闭', kind: _WinKind.close),
      ],
    );
  }
}

enum _WinKind { min, max, close }

class _WindowButton extends StatelessWidget {
  const _WindowButton({required this.icon, required this.tooltip, required this.kind});

  final IconData icon;
  final String tooltip;
  final _WinKind kind;

  @override
  Widget build(BuildContext context) {
    final DsTokens t = context.ds;
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: () async {
          switch (kind) {
            case _WinKind.min:
              await windowManager.minimize();
            case _WinKind.max:
              if (await windowManager.isMaximized()) {
                await windowManager.unmaximize();
              } else {
                await windowManager.maximize();
              }
            case _WinKind.close:
              await windowManager.close();
          }
        },
        child: SizedBox(
          width: 38,
          height: t.barHeight,
          child: Icon(icon, size: 14, color: kind == _WinKind.close ? t.danger : t.text2),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 引擎状态点（侧栏左下角）与小面板
// ─────────────────────────────────────────────────────────────────────────────

/// 侧栏**最下面**的**引擎状态点**（决策 F20 / 规范 §10）：6px 的点 + 22×22 命中区，
/// 文字只在 tooltip 里；颜色：已连接 `success` / 连接中 `warning` / 未连接 `text3`。
///
/// ⚠️ 第二十九轮从「窗口底部整条状态栏」搬到这里（状态栏整条删除）：真正一眼要看的
/// 只有"引擎通不通"，其余数字要看时去设置页（引擎 / 磁盘）与队列页（速率）。
/// ⚠️ **第三十一轮**：从"设置上面"挪到"**设置下面**"（用户：「侧边栏的小绿点放到设置
/// 下面」）—— 现在它就是侧栏里最底部那一样东西。点它弹出的引擎小面板贴在它**上方**
/// （下面没空间了，见 [openEnginePanel]）。
class _EngineDot extends ConsumerWidget {
  const _EngineDot();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final DsTokens t = context.ds;
    final EngineStatus status = ref.watch(engineStatusProvider);
    final AppSettings settings = ref.watch(settingsProvider);
    final (Color dot, String text) = switch (status.kind) {
      EngineStatusKind.connected => (t.success, '引擎已连接'),
      EngineStatusKind.connecting => (t.warning, '引擎连接中'),
      EngineStatusKind.error => (t.text3, '引擎未连接'),
    };
    final String? dir = settings.downloadDir;
    final String tip = <String>[
      (status.hint ?? '').trim().isEmpty ? text : status.hint!.trim(),
      if (dir == null || dir.trim().isEmpty) '下载目录未设置：到「设置 → 引擎」选择下载目录',
      '点一下看详情（端口 / 重启边车）',
    ].join('\n');

    return Padding(
      // 与导航项同一套左右内边距，让点与图标落在同一列上。
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Tooltip(
          key: dsEngineDotKey,
          message: tip,
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => openEnginePanel(context, ref),
              // 7px 的点太小，给一个 22×22 的命中区（看上去仍是一个点）。
              child: SizedBox(
                width: 22,
                height: 22,
                child: Center(child: NeoDot(color: dot, size: 6)),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 点引擎点 → 锚在它正上方的小面板：**连通状态 / 端口 / 引擎路径 / 下载目录 / 重启边车**。
///
/// 用 `showMenu`（与本项目所有下拉同一套浮层语言）：菜单项本身 `enabled: false`，
/// 里面的按钮自己吃点击。面板是低频排障入口，不该占常驻界面。
///
/// 第二十九轮：从 `_StatusBar` 的私有方法提成顶层函数（状态栏删了，但面板要留着）。
Future<void> openEnginePanel(BuildContext context, WidgetRef ref) async {
    final RenderBox? box = context.findRenderObject() as RenderBox?;
    final OverlayState? overlay = Overlay.maybeOf(context);
    final RenderBox? overlayBox = overlay?.context.findRenderObject() as RenderBox?;
    if (box == null || overlayBox == null) return;
    final Offset topLeft = box.localToGlobal(Offset.zero, ancestor: overlayBox);
    final DsTokens t = context.ds;
    await showMenu<void>(
      context: context,
      position: RelativeRect.fromLTRB(
        topLeft.dx,
        // 面板贴在引擎点**上方**（它现在在侧栏最下面，下面没空间）。
        topLeft.dy - 320,
        overlayBox.size.width - topLeft.dx,
        overlayBox.size.height - topLeft.dy,
      ),
      color: t.raised,
      elevation: t.overlayElevation,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(t.radiusControl),
      ),
      constraints: const BoxConstraints(minWidth: 320, maxWidth: 360),
      items: <PopupMenuEntry<void>>[
        PopupMenuItem<void>(enabled: false, padding: EdgeInsets.zero, child: const _EnginePanel()),
      ],
    );
}

/// 引擎小面板的内容（点侧栏左下角那颗引擎点弹出）。
class _EnginePanel extends ConsumerWidget {
  const _EnginePanel();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final DsTokens t = context.ds;
    final EngineStatus status = ref.watch(engineStatusProvider);
    final EngineBootstrapState engine = ref.watch(engineBootstrapProvider);
    final EngineHealthView? health = ref.watch(engineHealthProvider).value;
    final AppSettings settings = ref.watch(settingsProvider);
    final Directory? support = ref.watch(supportDirProvider);

    final String port;
    final String? base = engine.baseUrl;
    if (base == null || base.isEmpty) {
      port = '—';
    } else {
      final Uri? uri = Uri.tryParse(base);
      port = '${uri?.port ?? '—'}（$base）';
    }

    TextStyle label() => TextStyle(color: t.text3, fontSize: DsTypeScale.caption);
    TextStyle value() => TextStyle(color: t.text, fontSize: DsTypeScale.secondary);

    Widget row(String name, String text) => Padding(
      padding: const EdgeInsets.only(bottom: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(width: 66, child: Text(name, style: label())),
          Expanded(child: SelectableText(text, style: value())),
        ],
      ),
    );

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(
            status.label,
            style: TextStyle(
              color: switch (status.kind) {
                EngineStatusKind.connected => t.success,
                EngineStatusKind.connecting => t.warning,
                EngineStatusKind.error => t.danger,
              },
              fontSize: DsTypeScale.body,
              fontWeight: FontWeight.w600,
            ),
          ),
          if ((status.hint ?? '').trim().isNotEmpty) ...<Widget>[
            const SizedBox(height: 3),
            Text(status.hint!.trim(), style: label()),
          ],
          const SizedBox(height: 8),
          row('端口', port),
          row('版本', (health?.version ?? '').isEmpty ? '—' : 'v${health!.version}'),
          row('会话', '${health?.sessions ?? 0} 个 torrent'),
          row('下载目录', (settings.downloadDir ?? '').trim().isEmpty ? '未设置' : settings.downloadDir!),
          row('引擎', (engine.exePath ?? '').trim().isEmpty ? '未启动' : engine.exePath!),
          if (engine.lastStartup != null) row('上次启动', '${engine.lastStartup!.inMilliseconds} ms'),
          if (support != null) row('日志', p.join(support.path, 'engine', 'engine.log')),
          const SizedBox(height: 4),
          Row(
            children: <Widget>[
              if (engine.busy)
                Text('正在启动…', style: label())
              else
                OutlinedButton.icon(
                  onPressed: () => unawaited(_restart(context, ref)),
                  icon: const Icon(Icons.restart_alt, size: 15),
                  label: const Text('重启边车'),
                ),
              const SizedBox(width: 8),
              TextButton(
                onPressed: () => ref.invalidate(engineHealthProvider),
                child: const Text('重新测连通'),
              ),
              const Spacer(),
              TextButton(
                onPressed: () {
                  Navigator.of(context).pop();
                  ref.read(navProvider.notifier).select(ShellTab.settings);
                },
                child: const Text('设置页'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 重启边车：复用**设置页那条真实链路**（`applySettings`），不另写一套启动逻辑。
  Future<void> _restart(BuildContext context, WidgetRef ref) async {
    final AppSettings settings = ref.read(settingsProvider);
    try {
      await ref.read(lifecyclePortProvider).applySettings(settings);
      if (context.mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(const SnackBar(content: Text('边车已重启')));
      }
    } catch (error) {
      final DsFailure failure = describeFailure(error);
      if (context.mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(content: Text('重启失败：${failure.message}｜怎么办：${failure.hint ?? '—'}')),
        );
      }
    }
  }
}

/// 侧栏左下角的「继续播放」：**主窗口唯一的播放入口/指示**。
///
/// 用户 2026-10-10 第 3 轮问答：「只留一个播放图标（悬停看标题）」——
/// 那时它挂在**底部状态条最左边**。用户 2026-10-12 第十七轮报「太隐蔽」，要求
/// 「改到设置的上面也就是左下角」：现在它是侧栏左下角、设置齿轮**正上方**的一整行
/// （图标 + 文字），点它 = 唤回/重新打开播放窗口（悬停 tooltip 里带标题与暂停/停止提示）。
/// 没有在播内容时整行不渲染（不占位、不显示空态）—— 那时它上面的「观看记录」就直接
/// 贴着设置那一行（第二十七轮补记之后，两行同处左下角这一块）。
///
/// 文字为什么要写出来：它以前只有一颗图标，夹在状态条那颗引擎点旁边 —— 用户找不到。
class _ResumePlayingRow extends ConsumerStatefulWidget {
  const _ResumePlayingRow();

  @override
  ConsumerState<_ResumePlayingRow> createState() => _ResumePlayingRowState();
}

class _ResumePlayingRowState extends ConsumerState<_ResumePlayingRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final DsTokens t = context.ds;
    final NowPlaying? current = ref.watch(playbackProvider).nowPlaying;
    // `windowOpen` = 这扇窗还在（含"被收起来"）；`visible` = 它在屏幕上（在播/暂停中）。
    // 用户 2026-10-11：关掉播放器 = 收起来（不拆引擎），所以这两件事必须分开看，
    // 否则收起之后侧栏还会显示"正在播放"。
    //
    // ⚠️ 两个窗口 provider 必须在 `current != null` **之后**才读：没有播放窗口时
    // `playerWindowServiceProvider` 可能根本没被装配（组件测试就是这种环境）。
    if (current == null) return const SizedBox.shrink();
    final bool windowOpen = ref.watch(playerWindowIsOpenProvider);
    final bool visible = ref.watch(playerWindowVisibleProvider);
    final String title = ref.watch(playerWindowTitleProvider) ?? current.title;
    final String message = !windowOpen
        ? '播放窗口已关闭：$title\n点一下重新打开并继续播放'
        : visible
        ? '弹出播放窗口正在播放：$title\n点一下暂停 / 继续'
        : '播放器已收起（还在后台，引擎留着，唤回是秒开）：$title\n'
              '点一下唤回并继续播放\n右键可以彻底关闭它（把那扇窗的引擎一起释放）';
    final Color fg = visible ? t.success : (_hover ? t.text : t.text2);
    // 悬停底色与导航项同一个口径（第二十五轮）：实色 `t.sunken` + 不做过渡动画。
    // 原来是 `t.raised @55%`：在侧栏底色（= `t.raised`）上静止时看不见，而
    // `Colors.transparent` → 它的 lerp 中间帧会先暗一下（就是导航项那个"黑一下"）。
    final Decoration bg = visible
        ? BoxDecoration(
            color: t.successSoft,
            borderRadius: BorderRadius.circular(t.radiusControl),
          )
        : BoxDecoration(
            color: _hover ? t.sunken : Colors.transparent,
            borderRadius: BorderRadius.circular(t.radiusControl),
          );
    return Padding(
      // 与导航项同一条左右内边距（侧栏固定 184px，回归测试盯着它）。
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Tooltip(
        message: message,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _hover = true),
          onExit: (_) => setState(() => _hover = false),
          child: GestureDetector(
            key: dsResumePlayingKey,
            behavior: HitTestBehavior.opaque,
            onTap: () {
              if (visible) {
                unawaited(ref.read(playbackProvider.notifier).pauseWindow());
              } else {
                // 收起/关掉之后点它：走"重新唤出并继续"那条真实路径
                // （`open()` 会复用同一扇窗，子窗口收到播放请求会把自己 show 出来）。
                unawaited(ref.read(playbackProvider.notifier).reopenPlayerWindow());
              }
            },
            // 右键 = 彻底关闭（拆掉那扇窗、释放它那份内存）。
            // 为什么藏在这里：用户 2026-10-10 起明确要求界面上别再堆按钮，
            // 而"彻底关闭"是低频动作（默认关闭只是收起来，随时能秒开）。
            onSecondaryTap: visible
                ? () => unawaited(ref.read(playerWindowServiceProvider).destroy())
                : null,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              decoration: bg,
              child: Row(
                children: <Widget>[
                  Icon(visible ? Icons.pause : Icons.play_arrow, size: 16, color: fg),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      visible ? '正在播放' : '继续播放',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: fg,
                        fontSize: DsTypeScale.secondary,
                        fontWeight: visible ? FontWeight.w600 : FontWeight.w400,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
