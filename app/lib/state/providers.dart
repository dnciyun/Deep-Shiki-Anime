/// 全局 riverpod provider 装配。
///
/// 三件事：
/// 1. **注入点**：外部能力以端口形式注入。真实实现已就绪的（引擎 core、
///    播放器 shikiin）直接作为默认值；尚未落地的（源/订阅/队列）用
///    `domain/unavailable.dart` 的诚实实现（抛异常 + 可行动提示）。
/// 2. **状态**：设置、搜索、引擎进度、队列、订阅、导航。
/// 3. **派生**：引擎连接状态、当前 torrent/文件等 UI 只读视图。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/aggregate.dart';
import '../domain/completed.dart';
import '../domain/download_dir.dart' show effectiveDownloadDir;
import '../domain/error_text.dart';
import '../domain/models.dart';
import '../domain/ports.dart';
import '../domain/queue_sort.dart';
import '../domain/reveal_in_explorer.dart';
import '../domain/recycle_bin.dart';
import '../domain/settings_effect.dart';
import '../domain/unavailable.dart';
import '../theme/tokens.dart';
import 'completed_covers.dart';
import 'infra.dart';
// 存储/支持目录/选择器/托盘/通知/磁盘探测都在 infra.dart；
// 宿主侧持久化状态（继续观看、可清理标记）在 host_store.dart；
// 主页（mikan 追番表）状态在 schedule_provider.dart；
// 今日推荐（Bangumi 全年代随机）在 recommend_provider.dart；
// 追番本地标记在 following_provider.dart。
// 业务代码仍然只 import 本文件即可。
export 'bangumi_meta_provider.dart';
export 'completed_covers.dart';
export 'following_provider.dart';
export 'host_store.dart';
export 'infra.dart';
export 'recommend_provider.dart';
export 'schedule_provider.dart';
export 'settings_guard.dart';
// 观看记录与「已看过」标记（第二十七轮）。
export 'watch_history_provider.dart';
// 弹出播放窗口那条链路（服务、开关/标题 provider、参数编解码）。
export 'player_window.dart';

// ─────────────────────────────────────────────────────────────────────────────
// 注入点（main.dart / 测试 override）
// ─────────────────────────────────────────────────────────────────────────────

/// 源查询（nyaa / mikan / dmhy / acgrip / acgnx / bangumi.moe 各分区 + 自定义 RSS）。
/// core 的 sources/ 尚未落地 → 诚实报错。
final Provider<SourcePort> sourcePortProvider = Provider<SourcePort>(
  (Ref ref) => const UnavailableSourcePort(),
);

/// 引擎边车（rqbit-engine）。真实实现（core `EngineRuntime`）由 `main.dart` 注入
/// `CoreEnginePort`；未注入/未启动时所有调用抛可行动异常（不是假成功）。
final Provider<EnginePort> enginePortProvider = Provider<EnginePort>(
  (Ref ref) => const UnavailableEnginePort(),
);

/// 宿主数据层（源注册表/订阅存储/队列管理器）的生命周期。
/// 真实实现在 `main.dart` 注入 `CoreHostDataPort`；未注入时是显式报错。
final Provider<HostDataPort> hostDataPortProvider = Provider<HostDataPort>(
  (Ref ref) => const UnavailableHostDataPort(),
);

/// 拉起/停止边车。真实实现（core `EngineRuntime`）由 `main.dart` 注入。
final Provider<EngineBootstrapPort> engineBootstrapPortProvider = Provider<EngineBootstrapPort>(
  (Ref ref) => const UnavailableEngineBootstrapPort(),
);

/// 下载队列（core `QueueManager`，由 main.dart 注入）。
final Provider<QueuePort> queuePortProvider = Provider<QueuePort>(
  (Ref ref) => const UnavailableQueuePort(),
);

/// 订阅（core `SubscriptionStore` + 规则匹配，由 main.dart 注入）。
final Provider<SubsPort> subsPortProvider = Provider<SubsPort>(
  (Ref ref) => const UnavailableSubsPort(),
);

/// 播放器：**弹出播放窗口**那条链路（决策 B26 + 用户 2026-10-10 的要求）。
///
/// 装配根会在启动时用 `overrideWithValue(PlayerWindowPort(...))` 换上它；
/// 默认给 [UnavailablePlayerPort] 是为了让 widget 测试不碰真窗口。
final Provider<PlayerPort> playerPortProvider = Provider<PlayerPort>(
  (Ref ref) => const UnavailablePlayerPort(),
);

/// 让设置生效（重启边车 + 重建源客户端）。
final Provider<LifecyclePort> lifecyclePortProvider = Provider<LifecyclePort>(
  (Ref ref) => EngineLifecyclePort(ref),
);

/// 目录/文件选择器（真实实现在 main.dart 注入 `FilePickerPort`）。
final Provider<PickerPort> pickerPortProvider = Provider<PickerPort>(
  (Ref ref) => const UnavailablePickerPort(),
);

/// 检查更新 / 直接更新（第三十九轮；真实实现在 main.dart 注入 `GitHubUpdatePort`）。
///
/// 未接通时是 [UnavailableUpdatePort]：**抛异常**说"没接通"，绝不假装"已是最新"。
///
/// 状态机与那颗「立即重启并更新」按钮在 `state/update.dart`（它 import 本文件，
/// 所以这里不反向 import，免得绕成一个环）。
final Provider<UpdatePort> updatePortProvider = Provider<UpdatePort>(
  (Ref ref) => const UnavailableUpdatePort(),
);

/// 播放画面：宿主播放页里常驻挂载的内置播放器播放面。
///
/// **已删除**（决策 B40）：这里原本是 `playerSurfaceBuilderProvider`（一个可被
/// `main.dart` 覆盖的构建器，用来挂 ShikiiN 的 `AppShell`）。现在播放面写死在
/// `ui/player_page.dart` 里是 `shikiin.PlayerSurface`，少一层间接。

/// 当前外观（决策 F6/F7）：8 套手调色表之一；旧值 `light/dark/A/C/B/乱码` 由
/// [DsAppearance.fromCode] 迁移（`light`→白黑、`dark`→黑白）。
final Provider<DsAppearance> themeAppearanceProvider = Provider<DsAppearance>(
  (Ref ref) => DsAppearance.fromCode(ref.watch(settingsProvider).themeId),
);

/// 当前生效的完整 token —— UI 只该读这一个。
///
/// 扁平化后**没有「简洁模式」了**（决策 F9/F16：除悬浮层外一律零阴影），所以这里也
/// 不再做 `copyWith`。
final Provider<DsTokens> themeTokensProvider = Provider<DsTokens>(
  (Ref ref) => ref.watch(themeAppearanceProvider).tokens,
);

/// 「封面大小」三档（决策 F23）：**只影响今日更新网格的宽度封顶**（172/208/250）。
final Provider<DsCoverSize> homeCoverSizeProvider = Provider<DsCoverSize>(
  (Ref ref) => DsCoverSize.fromCode(ref.watch(settingsProvider).homeCoverSize),
);

/// 「轮播封面」两档（决策 F24）：横版（默认 = 现状）/ 竖版（竖长方形，看完整封面）。
final Provider<DsCarouselShape> carouselShapeProvider =
    Provider<DsCarouselShape>(
  (Ref ref) =>
      DsCarouselShape.fromCode(ref.watch(settingsProvider).carouselShape),
);

/// 「轮播大小」三档（决策 F24 / F28）：主卡 + 邻卡 + 整块高度等比（0.85 / 1.2 / 1.5）。
/// 第三十二轮上移一档：`m`「中」= 1.2（旧的「大」）、`l`「大」= 1.5（本轮新增）。
final Provider<DsCarouselSize> carouselSizeProvider = Provider<DsCarouselSize>(
  (Ref ref) => DsCarouselSize.fromCode(ref.watch(settingsProvider).carouselSize),
);

/// 让设置真正生效：重启边车（下载目录/限速/做种比/tracker 都是进程启动参数）。
class EngineLifecyclePort implements LifecyclePort {
  EngineLifecyclePort(this._ref);

  final Ref _ref;

  @override
  Future<void> applySettings(AppSettings settings) async {
    final Directory? supportDir = _ref.read(supportDirProvider);
    if (supportDir == null) {
      throw const PortUnavailableException(
        '设置已保存，但无法生效：应用支持目录未注入',
        hint: '这是装配问题（main.dart 未注入 supportDirProvider），请回报开发者',
      );
    }
    // 下载目录现在有**默认值**（用户 2026-10-11：「下载目录默认在
    // C:\Users\用户名\Downloads\Anime」）：设置里是 null 不代表"没有目录"，
    // 拿不到默认目录（解析不出用户目录）才真的算没得用。
    if (effectiveDownloadDir(settings.downloadDir).isEmpty) {
      throw const PortUnavailableException('设置已保存，但引擎未启动：还没有下载目录', hint: '先在「设置 → 引擎」选择下载目录');
    }
    // 引擎**只在进程参数真的变了**时才重启（用户 2026-10-11 第二阶段清单第 6 项，
    // 第十六轮改成手动保存之后这条判断照旧：一次「保存并生效」可能同时动了
    // 下载目录与 TTL，只有真的动了进程参数才付那 3.5 秒）。
    final AppSettings? launched = _ref.read(engineBootstrapProvider).launchedWith;
    if (launched == null || engineRestartRequired(launched, settings)) {
      final bool ok = await _ref
          .read(engineBootstrapProvider.notifier)
          .start(settings: settings, supportDir: supportDir);
      if (!ok) {
        final EngineBootstrapState state = _ref.read(engineBootstrapProvider);
        throw PortUnavailableException(state.error ?? '引擎重启失败', hint: state.errorHint);
      }
    }
    // 让设置真正生效的第二半（便宜、每次都做）：重建源注册表（代理/限速/TTL）
    // + 更新队列策略 + 订阅表。
    try {
      await _ref.read(hostDataPortProvider).applySettings(settings);
    } catch (error) {
      if (error is! PortUnavailableException) rethrow;
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 边车启动 / 停止（首启向导 + 设置页都用它）
// ─────────────────────────────────────────────────────────────────────────────

@immutable
class EngineBootstrapState {
  /// 正在启动/停止。
  final bool busy;

  /// 引擎是否已连接。
  final bool running;

  /// 失败信息（可行动文案）。
  final String? error;
  final String? errorHint;

  /// 实际使用的 exe 路径（启动成功后填）。
  final String? exePath;

  /// 最近一次启动耗时。
  final Duration? lastStartup;

  /// 当前这个进程是**用哪份设置**拉起来的（null = 没在跑 / 还没成功启动过）。
  ///
  /// `EngineLifecyclePort.applySettings` 靠它判断"这次改设置要不要重启进程"
  /// （见 `domain/settings_effect.dart`）：改外观/缓存 TTL/省流量策略都不用重启。
  final AppSettings? launchedWith;

  /// 边车根地址（`http://127.0.0.1:<port>`）；状态栏小面板显示端口用。
  final String? baseUrl;

  const EngineBootstrapState({
    this.busy = false,
    this.running = false,
    this.error,
    this.errorHint,
    this.exePath,
    this.lastStartup,
    this.launchedWith,
    this.baseUrl,
  });

  EngineBootstrapState copyWith({
    bool? busy,
    bool? running,
    String? error,
    String? errorHint,
    String? exePath,
    Duration? lastStartup,
    AppSettings? launchedWith,
    String? baseUrl,
    bool clearError = false,
  }) => EngineBootstrapState(
    busy: busy ?? this.busy,
    running: running ?? this.running,
    error: clearError ? null : (error ?? this.error),
    errorHint: clearError ? null : (errorHint ?? this.errorHint),
    exePath: exePath ?? this.exePath,
    lastStartup: lastStartup ?? this.lastStartup,
    launchedWith: launchedWith ?? this.launchedWith,
    baseUrl: baseUrl ?? this.baseUrl,
  );
}

/// 启动 / 停止 / 重启边车：状态在宿主侧，动作交给 [EngineBootstrapPort]。
class EngineBootstrapController extends Notifier<EngineBootstrapState> {
  @override
  EngineBootstrapState build() =>
      EngineBootstrapState(running: ref.read(engineBootstrapPortProvider).isRunning);

  /// 正在跑的那一次 `start()`（重入保护，见 [start]）。
  Future<bool>? _starting;

  /// 按当前设置启动边车（已在跑则先停，改下载目录/限速必须重启进程才生效）。
  ///
  /// ⚠️ **串行，不并发**：`CoreEngineBootstrap.start()` 一进来就 `detach()`（真的停掉
  /// 正在跑的边车），两次并发 start 会互相掐掉对方刚拉起来的进程 —— 设置页
  /// 「保存并生效」、tracker 每日刷新、首启向导都可能同时走到这里。
  /// 后来者**排队**：等前一次收尾，再按自己的设置来一次。
  /// （刻意不"合并成同一次"：那样后来那份设置就永远到不了进程，等于静默没生效。）
  Future<bool> start({required AppSettings settings, required Directory supportDir}) {
    final Future<bool>? inFlight = _starting;
    if (inFlight == null) {
      late final Future<bool> run;
      run = _startOnce(settings: settings, supportDir: supportDir).whenComplete(() {
        if (identical(_starting, run)) _starting = null;
      });
      _starting = run;
      return run;
    }
    return inFlight
        .then<bool>((bool _) => true, onError: (Object _) => false)
        .then((bool _) => start(settings: settings, supportDir: supportDir));
  }

  Future<bool> _startOnce({
    required AppSettings settings,
    required Directory supportDir,
  }) async {
    state = state.copyWith(busy: true, clearError: true);
    final EngineStartOutcome outcome = await ref
        .read(engineBootstrapPortProvider)
        .start(settings: settings, supportDir: supportDir);
    if (!ref.mounted) return outcome.ok;
    if (outcome.ok) {
      state = EngineBootstrapState(
        running: true,
        exePath: outcome.exePath,
        lastStartup: outcome.startup,
        // 记下"这个进程是用这份设置拉起来的"：改设置时用它判断要不要重启。
        launchedWith: settings,
        baseUrl: outcome.baseUrl,
      );
      ref.invalidate(engineHealthProvider);
      ref.invalidate(engineTorrentsProvider);
      // 引擎就绪 → 队列与引擎对齐（重启后同 infoHash 视为同一任务）。
      try {
        await ref.read(hostDataPortProvider).reconcile();
        ref.invalidate(queueJobsProvider);
      } catch (error) {
        if (error is! PortUnavailableException) rethrow;
      }
      return true;
    }
    state = EngineBootstrapState(
      running: false,
      error: outcome.message ?? '引擎启动失败',
      errorHint: outcome.hint,
    );
    return false;
  }

  Future<void> stop() async {
    state = state.copyWith(busy: true, clearError: true);
    await ref.read(engineBootstrapPortProvider).stop();
    if (!ref.mounted) return;
    state = const EngineBootstrapState(running: false);
  }
}

final NotifierProvider<EngineBootstrapController, EngineBootstrapState> engineBootstrapProvider =
    NotifierProvider<EngineBootstrapController, EngineBootstrapState>(
      EngineBootstrapController.new,
    );

// ─────────────────────────────────────────────────────────────────────────────
// 设置
// ─────────────────────────────────────────────────────────────────────────────

class SettingsController extends Notifier<AppSettings> {
  static const String storageKey = 'dsanima.app_settings';

  @override
  AppSettings build() {
    final store = ref.watch(keyValueStoreProvider);
    final Object? raw = store.get(storageKey);
    return AppSettings.fromJson(raw is Map ? raw.cast<Object?, Object?>() : null);
  }

  /// 保存并立即在内存态生效（下发到引擎/源客户端由生命周期端口负责）。
  ///
  /// ⚠️ 落盘失败时**回滚内存态**并把异常抛给调用方。`state` 先改、`put` 后写的顺序下，
  /// 写失败若还把 `state` 留在新值上，内存与磁盘就分裂了：界面显示新值、重启后回到旧值，
  /// 而调用方拿不到失败信号（设置页那套"先落盘再说已保存"的文案就会撒谎）。
  Future<void> replace(AppSettings next) async {
    final AppSettings previous = state;
    state = next;
    try {
      await ref.read(keyValueStoreProvider).put(storageKey, next.toJson());
    } catch (_) {
      state = previous;
      rethrow;
    }
  }

  Future<void> patch(AppSettings Function(AppSettings current) mutate) => replace(mutate(state));
}

final NotifierProvider<SettingsController, AppSettings> settingsProvider =
    NotifierProvider<SettingsController, AppSettings>(SettingsController.new);

/// 首启向导是否还没走完。
final Provider<bool> needsFirstRunProvider = Provider<bool>(
  (Ref ref) => !ref.watch(settingsProvider).firstRunCompleted,
);

// ─────────────────────────────────────────────────────────────────────────────
// 导航
// ─────────────────────────────────────────────────────────────────────────────

/// 左侧栏目的地（spec §7.5/§7.6）。
///
/// 第二十七轮补记之后的侧栏形状：顶部导航 = **主页 / 搜索 / 正在追 / 队列 / 已完成**
///（`shellNavTabs`），左下角那一块 = **观看记录**（`shellFooterTabs`）+ 在播时的
/// 「继续播放 / 正在播放」+ **设置**（最底下那一整行，`_SettingsGear`）。
///
/// **没有「正在播放」**（用户 2026-10-10 的硬要求）：播放只在**弹出窗口**里发生，
/// 主窗口不挂任何播放面，所以这一项连同 `ui/player_page.dart` 一起删掉了。
/// 想找回播放窗口走侧栏左下角那一行「正在播放 / 继续播放」（见 `shell.dart`）。
///
/// ⚠️ **「订阅」页在第二十七轮删掉了**（用户：「移除订阅，功能同步至正在追」）：
/// 订阅实体改成「一部番的一个字幕组」（mikan 组 RSS），入口是字幕组旁边那颗「订阅」，
/// 管理（刷新 / 规则 / 命中预览 / 取消）与剧集列表都在「正在追」的点开层里
/// （`ui/following_detail.dart`）。所以这个枚举里**没有** `subs` 了。
///
/// **「观看记录」**（第二十七轮新增）：看过的番与集 + 进度，超期自动清、可导出
/// （`ui/history_page.dart`）；它在侧栏**左下角 = 设置那一行的上面**。
/// ⚠️ **第二十七轮补记**：用户原话「新增观看记录在设置的上面」，第一版把它塞进了
/// 顶部导航列表的最后一项 —— 那一列在最上面，底下隔着一个 `Spacer` 才是设置，
/// 看着并不在「设置的上面」。现在它**不在** [shellNavTabs] 里，而在 [shellFooterTabs] 里。
///
/// **「已完成」**（第 14 轮新增）：「下载好的会在里面，按照名字分类，封面调用 bangumi」
/// —— 数据源是引擎里 `finished` 的 torrent，按番名归成封面卡，
/// 卡上能直接播 / 打开所在文件夹 / 移除任务 / 删文件到回收站（见 `ui/completed_page.dart`）。
///
/// ⚠️ **「已缓存」页在第二十一轮删掉了**（用户：「去掉已缓存页面，有已完成了」）：
/// 它与「已完成」本来是同一份数据源（引擎里 `finished` 的 torrent），摆法不同而已；
/// 用户认为「已完成」已经覆盖了它。它独有的「标记可清理 + 批量删除」随之一起去掉
/// （已完成页本来就有「移除任务（文件留着）」与「删除文件（进回收站）」）。
/// 首页/追番卡上那个「已缓存」**角标**照旧保留 —— 那是「这部番下完了没」的意思，
/// 与页面无关（见 `domain/title_match.dart`）。
///
/// ⚠️ `settings` 仍然在枚举里（设置页还在 [IndexedStack] 里、引擎点等入口还要
/// `select(ShellTab.settings)`），但它**不再出现在侧栏列表**：用户第 14 轮
/// 「主窗口的设置改为左下角」（后来更正为**左下角**）⇒ 侧栏最底下一整行入口。
enum ShellTab {
  home('主页', 'mikan 追番更新表 · 今日推荐'),
  library('动漫库', 'Bangumi 全库 · 筛选浏览'),
  search('搜索', '多站点 · 分区 · 分页'),
  following('正在追', '追番 · 字幕组订阅 · 打勾与下载'),
  queue('队列', '下载进度与优先级'),
  completed('已完成', '下完的剧集 · 按番名分类'),
  history('观看记录', '看过的番与集 · 可导出'),
  settings('设置', '目录、代理、限速、省流量');

  const ShellTab(this.label, this.subtitle);
  final String label;
  final String subtitle;
}

/// 侧栏**顶部导航区**里列出的项（= [ShellTab.values] 去掉 `settings` 与 `history`）。
///
/// 单独一个列表而不是在 UI 里 `where`：这是"哪些是常驻目的地"的唯一出处，
/// 测试也照它断言（改版时只改这一处）。
List<ShellTab> get shellNavTabs => <ShellTab>[
  for (final ShellTab tab in ShellTab.values)
    if (tab != ShellTab.settings && tab != ShellTab.history) tab,
];

/// 侧栏**左下角那一块**（设置那一行的上面）列出的项。
///
/// ⚠️ **第二十七轮补记**（用户：「观看记录改到左下角设置的上面」）：
/// 第一版把「观看记录」当成第 6 个导航项排在顶部列表最后，而设置入口从第十四轮起
/// 就在**左下角**（中间隔着一个 `Spacer`）—— 于是它离设置有一大段空白，不是
/// "设置的上面"。现在它和设置同处底部那一块：**观看记录在最上面、设置在最底下**，
/// 中间只有在播时才渲染的 `_ResumePlayingRow`（那一行是第十七轮用户点名要
/// "设置上面"的，位置不动）。
///
/// 不变式：`shellNavTabs + shellFooterTabs + [ShellTab.settings] == ShellTab.values`，
/// 每个目的地恰好出现在一处（`shell_widget_test` 钉着）。
List<ShellTab> get shellFooterTabs => const <ShellTab>[ShellTab.history];

class NavController extends Notifier<ShellTab> {
  @override
  ShellTab build() => ShellTab.home;

  void select(ShellTab tab) => state = tab;
}

final NotifierProvider<NavController, ShellTab> navProvider =
    NotifierProvider<NavController, ShellTab>(NavController.new);

// ─────────────────────────────────────────────────────────────────────────────
// 引擎
// ─────────────────────────────────────────────────────────────────────────────

/// 引擎健康检查（连接状态徽标 + 设置页「测试连通」）。
final FutureProvider<EngineHealthView> engineHealthProvider = FutureProvider<EngineHealthView>(
  (Ref ref) => ref.watch(enginePortProvider).health(),
);

/// SSE 全量进度流（队列页与播放浮层的实时数据源）。
final StreamProvider<List<EngineTorrentView>> engineTorrentsProvider =
    StreamProvider<List<EngineTorrentView>>((Ref ref) => ref.watch(enginePortProvider).watch());

enum EngineStatusKind { connecting, connected, error }

/// 外壳状态栏用的引擎状态摘要。
class EngineStatus {
  final EngineStatusKind kind;
  final String label;
  final String? hint;

  const EngineStatus(this.kind, this.label, {this.hint});

  bool get isConnected => kind == EngineStatusKind.connected;
}

final Provider<EngineStatus> engineStatusProvider = Provider<EngineStatus>((Ref ref) {
  final AsyncValue<EngineHealthView> health = ref.watch(engineHealthProvider);
  return health.when(
    loading: () => const EngineStatus(EngineStatusKind.connecting, '正在连接引擎…'),
    error: (Object error, StackTrace _) {
      final DsFailure failure = describeFailure(error);
      return EngineStatus(EngineStatusKind.error, failure.message, hint: failure.hint);
    },
    data: (EngineHealthView h) => EngineStatus(
      EngineStatusKind.connected,
      h.version.isEmpty ? '引擎已连接' : '引擎已连接 · v${h.version}',
    ),
  );
});

/// 按 index 找 torrent（UI 只读派生）。
final torrentByIdProvider = Provider.family<EngineTorrentView?, int>((Ref ref, int id) {
  final List<EngineTorrentView>? list = ref.watch(engineTorrentsProvider).value;
  if (list == null) return null;
  for (final EngineTorrentView t in list) {
    if (t.id == id) return t;
  }
  return null;
});

// ─────────────────────────────────────────────────────────────────────────────
// 队列
// ─────────────────────────────────────────────────────────────────────────────

final StreamProvider<List<QueueJobView>> queueJobsProvider = StreamProvider<List<QueueJobView>>(
  (Ref ref) => ref.watch(queuePortProvider).watchJobs(),
);

/// 队列统计（外壳徽标 + 队列页摘要）。
///
/// [paused] 必须**单独一档**：用户 2026-10-11 报「队列里总是有东西」时，那条遗留任务
/// 是 `paused`，却被算进 `active` 显示成「下载中 1」—— 一条没在下、也不在排队的任务
/// 被说成在下载，正是让人以为"删不掉/一直在跑"的误导来源。
@immutable
class QueueSummary {
  final int active;
  final int queued;
  final int completed;
  final int failed;
  final int paused;
  const QueueSummary({
    this.active = 0,
    this.queued = 0,
    this.completed = 0,
    this.failed = 0,
    this.paused = 0,
  });

  int get total => active + queued + completed + failed + paused;
}

final Provider<QueueSummary> queueSummaryProvider = Provider<QueueSummary>((Ref ref) {
  final List<QueueJobView>? jobs = ref.watch(queueJobsProvider).value;
  if (jobs == null) return const QueueSummary();
  int active = 0, queued = 0, completed = 0, failed = 0, paused = 0;
  for (final QueueJobView j in jobs) {
    switch (j.state) {
      case JobState.downloading:
        active++;
      case JobState.paused:
        paused++;
      case JobState.queued:
        queued++;
      case JobState.completed:
        completed++;
      case JobState.failed:
      case JobState.cancelled:
        failed++;
    }
  }
  return QueueSummary(
    active: active,
    queued: queued,
    completed: completed,
    failed: failed,
    paused: paused,
  );
});

/// 队列排序选择：**落盘**（用户 2026-10-11 第二阶段清单第 5 项：「排序要能记住」）。
///
/// 为什么用一个**独立的键**而不是塞进 `AppSettings`：
/// `AppSettings` 是设置页草稿（`_draft`）的比对基准，队列页改一个排序维度会让设置页
/// 立刻显示"有未保存改动"，用户随手点一下「保存并生效」又把排序改回去 ——
/// 两处 UI 争同一个字段。独立键（`dsanima.queue_sort`）语义也更准：它是"当下怎么看"，
/// 不是影响引擎/边车的设置。
///
/// 纯函数（枚举、排序规则、code ↔ 枚举）在 `domain/queue_sort.dart`。
class QueueSortController extends Notifier<QueueSortOrder> {
  static const String storageKey = 'dsanima.queue_sort';

  @override
  QueueSortOrder build() {
    final Object? raw = ref.watch(keyValueStoreProvider).get(storageKey);
    return queueSortOrderFromCode(raw is String ? raw : null);
  }

  void select(QueueSortOrder order) {
    state = order; // 立即生效，不等落盘
    unawaited(ref.read(keyValueStoreProvider).put(storageKey, order.code));
  }
}

final NotifierProvider<QueueSortController, QueueSortOrder> queueSortProvider =
    NotifierProvider<QueueSortController, QueueSortOrder>(QueueSortController.new);

// ─────────────────────────────────────────────────────────────────────────────
// 订阅
// ─────────────────────────────────────────────────────────────────────────────

final StreamProvider<List<SubscriptionView>> subscriptionsProvider =
    StreamProvider<List<SubscriptionView>>((Ref ref) => ref.watch(subsPortProvider).watch());

/// 命中预览：「这条规则会下哪些」。
final subsPreviewProvider = FutureProvider.family<List<SourceItemView>, String>((
  Ref ref,
  String subscriptionId,
) async {
  final List<SubscriptionView>? subs = ref.watch(subscriptionsProvider).value;
  if (subs == null) {
    throw const PortUnavailableException('订阅列表尚未加载完成，无法预览', hint: '等列表出现后再点「命中预览」');
  }
  SubscriptionView? target;
  for (final SubscriptionView s in subs) {
    if (s.id == subscriptionId) target = s;
  }
  if (target == null) {
    throw const PortUnavailableException('订阅不存在（可能已被删除）', hint: '刷新订阅列表后重试');
  }
  return ref.read(queuePortProvider).previewMatches(target);
});

/// 订阅的**全部条目**（第二十七轮）：不套规则，用于「正在追」点开层列剧集、
/// 以及卡片上算「这部番订阅的集是不是都看过了」。
///
/// 按订阅 id 分家并**常驻**（`keepAlive`）：卡片要读 `.value` 判断总勾，
/// 若用 autoDispose，卡片一重建就丢缓存、每帧都重新抓。抓取本身由 core 的源缓存兜着
///（TTL 见「设置 → 缓存」），刷新按钮走 `ref.invalidate`。
final subscriptionItemsProvider =
    FutureProvider.family<List<SourceItemView>, String>((Ref ref, String subscriptionId) async {
  final List<SubscriptionView>? subs = ref.watch(subscriptionsProvider).value;
  if (subs == null) {
    throw const PortUnavailableException('订阅列表尚未加载完成', hint: '等列表出现后重试');
  }
  SubscriptionView? target;
  for (final SubscriptionView s in subs) {
    if (s.id == subscriptionId) target = s;
  }
  if (target == null) {
    throw const PortUnavailableException('订阅不存在（可能已被删除）', hint: '刷新订阅列表后重试');
  }
  return ref.read(subsPortProvider).items(target);
});

// ─────────────────────────────────────────────────────────────────────────────
// 源
// ─────────────────────────────────────────────────────────────────────────────

/// 源表版本号（装配根 override 成 `HostDataHolder.sourceRevision`）。
///
/// 单独抽成 provider 是为了让 `sourceOptionsProvider` 能**订阅**它（见那里的说明）。
/// 默认值是一个本进程自有的 notifier：测试与"未装配"环境都不会空指针。
final Provider<ValueNotifier<int>> sourceRevisionProvider = Provider<ValueNotifier<int>>(
  (Ref ref) {
    final ValueNotifier<int> revision = ValueNotifier<int>(0);
    ref.onDispose(revision.dispose);
    return revision;
  },
);
/// 下拉框里的可用源（未接通时为空 → UI 显示「源未接通」）。
///
/// ⚠️ **必须盯住版本号**，不能写成 `Provider((ref) => port.sources)`。
///
/// 为什么（用户 2026-10-12 第 10 轮：「sukebe设置打开要重启，不能热加载修复下」）：
/// `SourcePort.sources` 是**活的**（每次读注册表），但 `Provider` 只算一次就缓存住，
/// 它依赖的东西（`sourcePortProvider`）又一辈子不变 ⇒ 注册表重建之后下拉仍是旧列表，
/// 看起来就像"这个设置要重启才生效"。现在注册表一变
/// （`HostDataHolder.sourcesChanged`）就 `invalidateSelf`，下拉立刻重算：
/// sukebei 开关、自定义 RSS 订阅的新增/删除都当场生效。
class SourceOptionsController extends Notifier<List<SourceOption>> {
  @override
  List<SourceOption> build() {
    final ValueNotifier<int> revision = ref.watch(sourceRevisionProvider);
    void onChanged() => ref.invalidateSelf();
    revision.addListener(onChanged);
    ref.onDispose(() => revision.removeListener(onChanged));
    return ref.watch(sourcePortProvider).sources;
  }
}

final NotifierProvider<SourceOptionsController, List<SourceOption>> sourceOptionsProvider =
    NotifierProvider<SourceOptionsController, List<SourceOption>>(
      SourceOptionsController.new,
    );

// ─────────────────────────────────────────────────────────────────────────────
// 搜索
// ─────────────────────────────────────────────────────────────────────────────

/// 一页显示多少条（用户 2026-10-11：「搜索改一下，按照一页20条，可加载其他几页」）。
///
/// 这是**显示页**的大小，与源的**原始页**无关：源的原始页多大完全不受宿主控制
/// （mikan 的 HTML 搜索页一次给 1000 条、dmhy 一页 80 条、nyaa 一页 75 条），
/// 所以切片只能宿主自己干，见 [SearchQueryController] 的分页模型。
const int kSearchPageSize = 20;

/// 把已取到的条目按 [kSearchPageSize] 切成显示页（[page] 从 1 起）。
///
/// 为什么单独抽成纯函数：分页最容易错的全是边界（空池、正好整除、最后一页不满），
/// 无副作用的函数可以直接喂数字断言，不用起 UI 也不用连网。
/// 越界**返回空表而不是抛错** —— 翻页与网络是异步的，"这一页暂时还没有数据"是正常状态。
List<SourceItemView> searchPageSlice(List<SourceItemView> all, int page) {
  if (page < 1) return const <SourceItemView>[];
  final int start = (page - 1) * kSearchPageSize;
  if (start >= all.length) return const <SourceItemView>[];
  final int end = start + kSearchPageSize;
  return all.sublist(start, end < all.length ? end : all.length);
}

/// 把新取到的一批条目**追加**进已有的池子，按 [SourceItemView.id] 去重。
///
/// 为什么必须去重：源的两个"页"之间经常重叠（nyaa 的 RSS 首页与 `?p=1` 就是同一批
/// 条目），不去重的话池子会虚胖、推算出来的页数跟着虚高，用户点到后面几页会觉得
/// "怎么还是这些"。去重后同一部番的同一集只会出现一次。
List<SourceItemView> searchAppendItems(
  List<SourceItemView> base,
  List<SourceItemView> extra,
) {
  if (extra.isEmpty) return base;
  final Set<String> seen = <String>{for (final SourceItemView i in base) i.id};
  final List<SourceItemView> merged = List<SourceItemView>.of(base);
  for (final SourceItemView i in extra) {
    if (seen.add(i.id)) merged.add(i);
  }
  return merged;
}

/// 页码条要显示哪些页码（`null` = 省略号）。
///
/// 两条规则（用户 2026-10-12 第八轮：「为什么只有 50 页，不要固定页数，加载出数据就加一页」）：
/// 1. **不画末页数字**。以前 `{1, pageCount}` 会把最后一页当跳板一起画出来 —— 于是
///    搜一个热门番，第 1 页底部就直接挂着「… 50」，看着像"页数是定死的"（mikan 一次
///    给 1000 条 = 正好 50 页）。现在右边只用**省略号**表示"后面还有"，数字随翻页
///    一页页长出来。
/// 2. **不铺满**。全铺 `1..pageCount` 会把底部挤成一条数字墙，真正有用的"我在第几页"
///    反而看不见；所以只留首页 + 当前页左右各 [window] 个，中间折断成省略号。
List<int?> searchPageNumbers({required int page, required int pageCount, int window = 1}) {
  if (pageCount < 1) return const <int?>[];
  // 页数够少就全铺（多数源只有一两页，全铺出来最好点）。
  if (pageCount <= window * 2 + 3) {
    return <int?>[for (int p = 1; p <= pageCount; p++) p];
  }
  final Set<int> keep = <int>{1};
  for (int d = -window; d <= window; d++) {
    final int p = page + d;
    if (p >= 1 && p <= pageCount) keep.add(p);
  }
  final List<int> sorted = keep.toList()..sort();
  final List<int?> out = <int?>[];
  int? previous;
  for (final int p in sorted) {
    if (previous != null && p - previous > 1) out.add(null);
    out.add(p);
    previous = p;
  }
  // 右边还有没画的页 → 再补一个省略号（只有提示，没有数字）。
  if (sorted.last < pageCount) out.add(null);
  return out;
}

/// 搜索页状态：一次查询的完整三态（loading / empty / error）+ **显示页**分页。
///
/// 关键设计：**池子与窗口分开**。
/// * [fetched] = "已经从源那里攒到的全部条目"（按取回顺序、按 id 去重）；
/// * [page] + [items] = "现在给用户看的那 20 条窗口"，由 [searchPageSlice] 从池子里切。
///
/// 为什么非这么分：源一页给多少完全不可控，只有把"源页"和"显示页"解耦，才能让
/// 「一页 20 条」成为宿主的硬约束；同时池子留住旧条目，翻回上一页不必再打一次网络，
/// 播放列表也能跨页按「同名同压制组」归组（见 `domain/playlist.dart`）。
@immutable
class SearchState {
  final String sourceId;
  final String keyword;

  /// 搜索模式（第 14 轮）：聚合（默认）还是只问一个源。
  ///
  /// 存在 state 里而不是每次读设置：一次搜索过程中模式不该变（变了就重来一轮），
  /// 设置页改了由搜索页 `listen` 后调 [SearchQueryController.setMode]。
  final SearchMode mode;

  /// 聚合档（[mode] == aggregate 时有效）：聚合 / 动漫 / 全集。
  ///
  /// 第 15 轮起这只是**勾选的一个名字**：正好等于某一档预设时就是它，用户手动改过
  /// 勾选就是 null（= 自定义，三颗 chip 都不高亮）。真相永远在
  /// [excludedSourceIds]，见 `domain/aggregate.dart` 的「勾选」一节。
  final SearchScope? scope;

  /// 聚合模式下**不勾**的源 id（真相；三颗 chip 与「源 N/M」面板都改它）。
  final Set<String> excludedSourceIds;

  /// 部分源失败的警告文案（聚合才有；null = 没有失败或不是聚合）。
  ///
  /// 与 [failure] 分工：整轮一条都没取到 → [failure]（整页错误面板）；
  /// 只是**几个源**没回来 → 这里（结果照常显示，上方一条警告带说明少了哪几个站）。
  final String? aggregateWarning;

  /// 已从源攒到的全部条目（池子）。翻页**不复位**，只有新一轮刷新才清空。
  final List<SourceItemView> fetched;

  /// 当前**显示页**（从 1 起）；给用户看的内容是 [items]。
  final int page;

  /// 源的**原始页**已经取到第几页（0 = 一页都还没取）。翻显示页时从它 +1 续拉。
  final int sourcePage;

  /// 源明确说过"还有下一页"（来自 `SourcePageView.hasNext`）。
  ///
  /// 与 [pageCount] 分开是因为语义不同：这是**源的原话**，[pageCount] 是宿主按池子
  /// 推算出来的；源从不给总页数，两者混成一个字段就再也说不清"到底还有没有"。
  final bool hasMoreSource;

  final bool loading;

  /// 正在为目标显示页取数（点页码 / 上一页 / 下一页）。
  ///
  /// 与 [loading] 分开：整轮刷新要清空重来（整页 loading），翻页只是往池子里续条目
  /// （表格留在原地、只在底部提示），两种加载形态不能混。
  final bool loadingPage;
  final bool loaded;
  final bool fromCache;
  final DateTime? fetchedAt;
  final DsFailure? failure;

  const SearchState({
    required this.sourceId,
    this.keyword = '',
    this.mode = SearchMode.aggregate,
    this.scope,
    this.excludedSourceIds = const <String>{},
    this.aggregateWarning,
    this.fetched = const <SourceItemView>[],
    this.page = 1,
    this.sourcePage = 0,
    this.hasMoreSource = false,
    this.loading = false,
    this.loadingPage = false,
    this.loaded = false,
    this.fromCache = false,
    this.fetchedAt,
    this.failure,
  });

  /// 当前显示页的 20 条窗口。
  List<SourceItemView> get items => searchPageSlice(fetched, page);

  /// 已知/可推断的总页数。
  ///
  /// 源不给总页数（`SourcePage` 只有 `hasNext`），所以只能这样推：
  /// * 池子里已攒的条目能切出几页 = 已知页数下限；
  /// * 源还说"还有下一页" → 再多算一页（源的原话只能换算成"下限 +1"，
  ///   绝不能假装知道确切数字，否则页码条会骗人）；
  /// * 一条都没有 → 至少 1 页（"第 1 / 1 页"比"第 1 / 0 页"更像人话）。
  int get pageCount {
    final int loadedPages = (fetched.length + kSearchPageSize - 1) ~/ kSearchPageSize;
    if (hasMoreSource) return loadedPages + 1;
    return loadedPages < 1 ? 1 : loadedPages;
  }

  /// 有更早的页可以翻。
  bool get canGoPrevious => page > 1;

  /// 还有更晚的页可以翻（页码条/上一页/下一页都按它决定禁用与否）。
  bool get canGoNext => page < pageCount;

  bool get isEmpty => loaded && fetched.isEmpty && failure == null;

  SearchState copyWith({
    String? sourceId,
    String? keyword,
    SearchMode? mode,
    SearchScope? scope,
    /// true = 把 [scope] 置空（"勾选是自定义的，哪一档都不是"）。
    ///
    /// 为什么需要这个开关：`?? this.scope` 语义下传 null 表示"不改"，而"自定义勾选"
    /// 恰恰就是要把它变回 null —— 没有这个开关，用户一取消某个源，chip 还会亮着，
    /// 等于界面上说了假话。
    bool clearScope = false,
    Set<String>? excludedSourceIds,
    String? aggregateWarning,
    bool clearAggregateWarning = false,
    List<SourceItemView>? fetched,
    int? page,
    int? sourcePage,
    bool? hasMoreSource,
    bool? loading,
    bool? loadingPage,
    bool? loaded,
    bool? fromCache,
    DateTime? fetchedAt,
    DsFailure? failure,
    bool clearFailure = false,
  }) => SearchState(
    sourceId: sourceId ?? this.sourceId,
    keyword: keyword ?? this.keyword,
    mode: mode ?? this.mode,
    scope: clearScope ? null : (scope ?? this.scope),
    excludedSourceIds: excludedSourceIds ?? this.excludedSourceIds,
    aggregateWarning:
        clearAggregateWarning ? null : (aggregateWarning ?? this.aggregateWarning),
    fetched: fetched ?? this.fetched,
    page: page ?? this.page,
    sourcePage: sourcePage ?? this.sourcePage,
    hasMoreSource: hasMoreSource ?? this.hasMoreSource,
    loading: loading ?? this.loading,
    loadingPage: loadingPage ?? this.loadingPage,
    loaded: loaded ?? this.loaded,
    fromCache: fromCache ?? this.fromCache,
    fetchedAt: fetchedAt ?? this.fetchedAt,
    failure: clearFailure ? null : (failure ?? this.failure),
  );
}

/// 搜索状态机（名字避开 Flutter Material 的 `SearchController`）。
///
/// **默认不加载**（用户 2026-10-12：「搜索页改成默认不加载，只有个搜索，搜索后才有」）：
/// 没人调 [refresh] 就一直是「没搜过」（[SearchState.loaded] = false）——
/// 进页面不再自动拉一次"最新"，那一屏只给输入框与提示。
///
/// **分页模型：源页 ≠ 显示页。**
/// * `refresh()`：清空池子，只取源的原始第 1 页，显示第 1 个 20 条窗口；
/// * `goToPage(n)`：先看池子里够不够第 n 页，**不够才**向源续拉（[_fillForPage]）。
///   mikan 搜索一次给 1000 条 ⇒ 翻页零请求；dmhy / nyaa 一页几十条 ⇒ 只在真要那几页
///   时才续拉，不会为了"第 3 页"把源从头搬到尾；
/// * 底部**只有页码条**（用户 2026-10-12：「加载更多去掉，不应该有」），
///   原来的 `loadMore()` 已删除 —— 窗口永远是一页 20 条。
class SearchQueryController extends Notifier<SearchState> {
  /// 一次翻页最多向源续拉几个原始页。
  ///
  /// 为什么要有上限：源的原话只有"还有下一页"，万一它每页只回一两条、或者一直回
  /// 同一批，为了凑满第 5 页就会无限打请求（用户点一下页卡半天）。宁可这一页少几条，
  /// 也不能把网络和 UI 卡在翻页上。
  static const int maxSourceFetchesPerNav = 8;

  /// 聚合模式下的一次翻页上限（比单源小得多）。
  ///
  /// 聚合每"一页"= 向**每一个**源各要一页，8 轮就是 8×10 = 80 条请求。3 轮封顶
  /// （最多 30 条）已经够翻到第 4 页附近；真翻到大后面，用户更该去用关键字或换档。
  static const int maxAggregateFetchesPerNav = 3;

  @override
  SearchState build() {
    final AppSettings settings = ref.read(settingsProvider);
    String sourceId = settings.defaultSourceId;
    // 存的源没注册（换过内核/删过订阅）→ 落到 mikan（默认源），别让搜索页一进来就报
    // 「源没有注册」。
    final List<SourceOption> sources = ref.read(sourceOptionsProvider);
    if (sources.isNotEmpty && !sources.any((SourceOption s) => s.id == sourceId)) {
      sourceId = sources.any((SourceOption s) => s.id == 'mikan') ? 'mikan' : sources.first.id;
    }
    // 第 14 轮：模式在建 state 时从设置读一次（默认聚合）。
    // 第 15 轮：勾选（排除名单）也从设置读一次 —— 默认空集 = **全开**。
    final Set<String> excluded = settings.aggregateExcludedSourceIds.toSet();
    return SearchState(
      sourceId: sourceId,
      mode: settings.searchMode,
      excludedSourceIds: excluded,
      scope: activeScopePreset(sources, excluded),
    );
  }

  /// 换源（**只在单独源模式**下有意义；聚合模式改勾选的是 [setExcludedSources]）。
  ///
  /// 已经有一份结果在屏幕上时才顺手重查一次 —— 那是**同一句关键字换个源**，
  /// 不重查等于把旧源的结果挂在新源名下（撒谎）。还没搜过就什么都不做：
  /// 换源本身不是"要结果"的意思（用户 2026-10-12：默认不加载）。
  void setSource(String sourceId) {
    if (sourceId == state.sourceId) return;
    final bool hadResults = state.loaded;
    state = SearchState(
      sourceId: sourceId,
      keyword: state.keyword,
      mode: state.mode,
      scope: state.scope,
      excludedSourceIds: state.excludedSourceIds,
    );
    if (hadResults) unawaited(refresh());
  }

  /// 设置里换了「聚合 / 单独源」模式（搜索页 listen 到设置变化后调它）。
  ///
  /// 已经搜过就按新模式重查一遍：结果池里的东西属于旧模式，留着就是挂羊头卖狗肉。
  void setMode(SearchMode mode) {
    if (mode == state.mode) return;
    final bool hadResults = state.loaded;
    state = SearchState(
      sourceId: state.sourceId,
      keyword: state.keyword,
      mode: mode,
      scope: state.scope,
      excludedSourceIds: state.excludedSourceIds,
    );
    if (hadResults) unawaited(refresh());
  }

  /// 这一档预设会选中几个源（要搜关键字时才算 `supportsSearch`）。
  int scopeSourceCount(SearchScope scope) => sourcesForScope(
    ref.read(sourceOptionsProvider),
    scope,
    needSearch: state.keyword.trim().isNotEmpty,
  ).length;

  /// 点三颗 chip 之一 = **按档位预设重设勾选**（第十五轮：chip 是快捷全选）。
  ///
  /// 返回 false = 这一档里一个源都没有，**没改任何东西**（「至少留一个源」这条规则
  /// 对 chip 一样有效：点了「动漫」却把源全排掉，等于让下一次搜索必然报错）。
  bool applyScopePreset(SearchScope scope) {
    final List<SourceOption> all = ref.read(sourceOptionsProvider);
    final Set<String> next = excludedForScope(all, scope);
    if (selectedSources(all, next, needSearch: state.keyword.trim().isNotEmpty).isEmpty) {
      return false;
    }
    setExcludedSources(next);
    return true;
  }

  /// 勾选/取消一个源（面板里那一排开关）。
  ///
  /// 返回 false = 被"至少留一个源"挡住（它是最后一个勾着的源），**什么都没改**。
  bool toggleSource(String sourceId) {
    final List<SourceOption> all = ref.read(sourceOptionsProvider);
    final Set<String> next = <String>{...state.excludedSourceIds};
    if (next.contains(sourceId)) {
      next.remove(sourceId); // 它本来没勾 → 勾上（永远不挡）
    } else {
      // 它正勾着，用户要取消 —— 只剩这一个时挡住（第一轮问答：不允许零勾）。
      if (blocksUnselect(sources: all, excludedSourceIds: next, id: sourceId)) {
        return false;
      }
      next.add(sourceId);
    }
    setExcludedSources(next);
    return true;
  }

  /// 全勾上（= 「聚合」这一档）。
  void selectAllSources() => setExcludedSources(const <String>{});

  /// 改勾选（唯一入口）：改 state → **写进设置**（下次启动照旧）→ 已经搜过就重查。
  ///
  /// 为什么"已经搜过就重查"：屏幕上的那批结果是旧源集合给的，留着就是撒谎。
  /// 没搜过就什么都不做（默认不加载，见类注释）。
  void setExcludedSources(Set<String> excludedSourceIds) {
    if (_sameIds(excludedSourceIds, state.excludedSourceIds)) return;
    final bool hadResults = state.loaded;
    final SearchScope? preset =
        activeScopePreset(ref.read(sourceOptionsProvider), excludedSourceIds);
    state = state.copyWith(
      excludedSourceIds: <String>{...excludedSourceIds},
      scope: preset,
      clearScope: preset == null, // 手动改过 → 三颗 chip 全灭（不是"还亮着但撒谎"）
    );
    unawaited(_persistExclusions(excludedSourceIds));
    if (hadResults) unawaited(refresh());
  }

  /// 落盘。排序后再写：JSON 里看着稳定，diff 也不会因为 Set 的迭代顺序乱跳。
  ///
  /// 写设置失败**不该让搜索失败**：勾选已经在 state 里生效了，最坏就是"这次没记住"。
  Future<void> _persistExclusions(Set<String> excludedSourceIds) async {
    final List<String> sorted = excludedSourceIds.toList()..sort();
    try {
      await ref.read(settingsProvider.notifier).patch(
        (AppSettings s) => s.copyWith(aggregateExcludedSourceIds: sorted),
      );
    } catch (_) {
      // 见上：静默。用户下一次进面板看到的仍是已经生效的勾选。
    }
  }

  static bool _sameIds(Set<String> a, Set<String> b) =>
      a.length == b.length && a.every(b.contains);

  void setKeyword(String keyword) {
    state = state.copyWith(keyword: keyword);
  }

  /// 关键字提交（回车/按钮）：清空池子，从源的原始第 1 页重来。
  Future<void> refresh() async {
    // 挡并发重复刷新：源下拉的 onChanged 是「setSource 自带一次刷新 + 显式再刷新」，
    // 不挡就会为同一次选择打两次网络（旧实现就是这样）。
    if (state.loading) return;
    state = state.copyWith(
      loading: true,
      loadingPage: false,
      loaded: false,
      fetched: const <SourceItemView>[],
      page: 1,
      sourcePage: 0,
      hasMoreSource: false,
      clearFailure: true,
      clearAggregateWarning: true,
    );
    final DsFailure? failure = await _fetchSourcePage(1);
    if (!ref.mounted) return;
    state = state.copyWith(
      loading: false,
      loadingPage: false,
      loaded: true,
      failure: failure,
      clearFailure: failure == null,
    );
  }

  /// 跳到第 [target] 个**显示页**：页码点击、上一页、下一页都走这里。
  ///
  /// 目标页的数据不在池子里时才向源续拉（[_fillForPage]）—— 这是"可加载其他几页"
  /// 与"翻回旧页不重复联网"两件事的唯一实现点。
  Future<void> goToPage(int target) async {
    if (state.loading || state.loadingPage) return;
    if (target == state.page || target < 1 || target > state.pageCount) return;
    state = state.copyWith(loadingPage: true, clearFailure: true);
    final DsFailure? failure = await _fillForPage(target);
    if (!ref.mounted) return;
    if (failure != null) {
      // 取数失败就**留在原页**：已经拿到的那一页结果不该被一次翻页失败清掉，
      // 只在底部/表格上方说明原因（页池没变，重试仍是点同一个页码）。
      state = state.copyWith(loadingPage: false, failure: failure);
      return;
    }
    if (searchPageSlice(state.fetched, target).isEmpty) {
      // 池子还是凑不出这一页。两种原因要分开说，否则用户会照着一个错的提示去排查：
      // * 源已经明确到底了（`hasMoreSource` 现在为假）→ 就是没有更多结果；
      // * 源嘴上还说"有"但给不出（或撞上了续拉上限）→ 是源那边抽风/每页太少，可重试。
      final bool sourceSaidMore = state.hasMoreSource;
      state = state.copyWith(
        loadingPage: false,
        failure: DsFailure(
          '第 $target 页没有内容',
          hint: sourceSaidMore
              ? '源给不出更多条目了（可能它每页太少或临时抽风）：稍后重试，或换个源/关键字'
              : '源那里没有更多结果了：换个关键字或换个源试试',
        ),
      );
      return;
    }
    state = state.copyWith(page: target, loadingPage: false, loaded: true, clearFailure: true);
  }

  /// 让池子至少能切出第 [target] 页；只有不够 + 源还有更多时才真的发请求。
  Future<DsFailure?> _fillForPage(int target) async {
    final int needed = target * kSearchPageSize;
    // 聚合一轮 = 向每个源各要一页，上限要小得多（见 maxAggregateFetchesPerNav）。
    final int cap = state.mode == SearchMode.aggregate
        ? maxAggregateFetchesPerNav
        : maxSourceFetchesPerNav;
    int fetchedPages = 0;
    while (state.fetched.length < needed && state.hasMoreSource) {
      if (fetchedPages >= cap) break;
      final int before = state.fetched.length;
      final DsFailure? failure = await _fetchSourcePage(state.sourcePage + 1);
      if (failure != null) return failure;
      // 这一页全是重复条目（或空页）：再往下拉也是同一批，停手，别空转。
      if (state.fetched.length == before) break;
      fetchedPages++;
    }
    return null;
  }

  /// 取源的**原始**第 [sourcePage] 页并追加进池子。
  ///
  /// 返回 `null` = 成功（哪怕这一页是空的，也算"问过了"）；非 null = 失败原因
  /// （已归一化成 [DsFailure]）。**不在这里写 state.failure**：整轮刷新与翻页对
  /// 同一个失败的呈现方式不同，由调用方决定。
  ///
  /// 第 14 轮起按 [SearchState.mode] 分两条路：单独源 = 原来那条；聚合 = 把这一档的
  /// 源全部问一遍（见 [_fetchAggregatePage]）。
  Future<DsFailure?> _fetchSourcePage(int sourcePage) {
    if (state.mode == SearchMode.aggregate) {
      return _fetchAggregatePage(sourcePage);
    }
    return _fetchSingleSourcePage(sourcePage);
  }

  Future<DsFailure?> _fetchSingleSourcePage(int sourcePage) async {
    final SourcePort port = ref.read(sourcePortProvider);
    final String sourceId = state.sourceId;
    final String keyword = state.keyword.trim();
    try {
      final SourcePageView result = keyword.isEmpty
          ? await port.latest(sourceId, page: sourcePage)
          : await port.search(sourceId, keyword, page: sourcePage);
      if (!ref.mounted) return null;
      state = state.copyWith(
        fetched: searchAppendItems(state.fetched, result.items),
        sourcePage: sourcePage,
        hasMoreSource: result.hasNext,
        fromCache: result.fromCache,
        fetchedAt: result.fetchedAt,
        clearAggregateWarning: true,
      );
      return null;
    } catch (error, stackTrace) {
      if (!ref.mounted) return null;
      return describeFailure(error, stackTrace: stackTrace);
    }
  }

  /// 这一轮聚合要问的源 = **勾选的**源（第 15 轮起勾选是唯一真相）。
  List<SourceOption> aggregateSources() {
    final List<SourceOption> all = ref.read(sourceOptionsProvider);
    return selectedSources(
      all,
      state.excludedSourceIds,
      // 有关键字才走 `search()`；「最新」那条路所有源都能给（`latest` 不受
      // supportsSearch 限制，见 SourcePort 的实现）。
      needSearch: state.keyword.trim().isNotEmpty,
    );
  }

  /// 聚合取数：把**勾选的**源并发问一遍，合并 + 去重 + 排序后并进池子。
  ///
  /// 失败处理（第一轮问答选定的那一档）：
  /// * **部分源失败** → 结果照常显示，只在 [SearchState.aggregateWarning] 里点名
  ///   是哪几个源、为什么（静默跳过会让用户以为"聚合了全部源"）；
  /// * **全部失败** → 返回 [DsFailure]，让调用方按整页错误处理。
  Future<DsFailure?> _fetchAggregatePage(int sourcePage) async {
    final List<SourceOption> targets = aggregateSources();
    if (targets.isEmpty) {
      // 正常情况下到不了这里：面板不允许把源取消到一个不剩（第一轮问答），
      // 档位预设也做同样的检查。留着是为了"设置文件被手改/源表整个换掉"时说话算数。
      return const DsFailure(
        '一个源都没选中（或选中的源都不支持关键字搜索）',
        hint: '打开搜索页右上角的「源」面板，至少勾一个源；'
            '或到「设置 → 网络 · 限速 · 做种」改成「单独源模式」逐个试',
      );
    }
    final List<AggregateSourceResult> results = await _fanOut(targets, sourcePage);
    if (!ref.mounted) return null;

    final List<SourceItemView> incoming = <SourceItemView>[
      for (final AggregateSourceResult r in results) ...r.items,
    ];
    final List<AggregateSourceResult> failed = aggregateFailures(results);
    final bool allFailed = failed.length == results.length;
    // 全失败时不写警告带：那件事会走整页错误面板说清楚，两条一起出现只是噪音。
    final String warning = allFailed ? '' : aggregateFailureBanner(results);

    state = state.copyWith(
      // 池子：先合并（同一条资源留信息最全的那条）再统一排序（新→旧）。
      fetched: aggregateSort(aggregateMerge(state.fetched, incoming)),
      sourcePage: sourcePage,
      hasMoreSource: results.any((AggregateSourceResult r) => r.hasNext && r.ok),
      fromCache: results.any((AggregateSourceResult r) => r.fromCache),
      fetchedAt: _newestFetchedAt(results) ?? state.fetchedAt,
      aggregateWarning: warning.isEmpty ? null : warning,
      clearAggregateWarning: warning.isEmpty,
    );

    if (allFailed) {
      // 一个源都没回来：这一轮等于没取到东西，把原因交给调用方走整页错误。
      return DsFailure(
        '勾选的源全都没回来（${targets.length} 个）',
        hint: '${failed.first.failure}；检查网络/代理，或打开搜索页的「源」面板换个源、'
            '或到「设置 → 网络 · 限速 · 做种」换成单独源模式逐个试',
      );
    }
    return null;
  }

  /// 并发问 [targets]（每个源最多等 [kAggregateSourceTimeout]），最多
  /// [kAggregateMaxConcurrent] 个同时在飞。返回顺序与 [targets] 一致（稳定）。
  Future<List<AggregateSourceResult>> _fanOut(
    List<SourceOption> targets,
    int sourcePage,
  ) async {
    final List<AggregateSourceResult> out = List<AggregateSourceResult>.filled(
      targets.length,
      const AggregateSourceResult(sourceId: '', displayName: ''),
    );
    int next = 0;
    Future<void> worker() async {
      while (true) {
        final int i = next;
        next++;
        if (i >= targets.length) return;
        out[i] = await _fetchOneSource(targets[i], sourcePage);
      }
    }

    final int workers = targets.length < kAggregateMaxConcurrent
        ? targets.length
        : kAggregateMaxConcurrent;
    await Future.wait(<Future<void>>[for (int i = 0; i < workers; i++) worker()]);
    return out;
  }

  /// 问一个源。**永不抛**：超时/网络错/源不支持搜索都变成带原因的失败结果。
  Future<AggregateSourceResult> _fetchOneSource(
    SourceOption source,
    int sourcePage,
  ) async {
    final SourcePort port = ref.read(sourcePortProvider);
    final String keyword = state.keyword.trim();
    try {
      final SourcePageView page = await (keyword.isEmpty
              ? port.latest(source.id, page: sourcePage)
              : port.search(source.id, keyword, page: sourcePage))
          .timeout(kAggregateSourceTimeout);
      return AggregateSourceResult(
        sourceId: source.id,
        displayName: source.displayName,
        items: List<SourceItemView>.unmodifiable(page.items),
        hasNext: page.hasNext,
        fromCache: page.fromCache,
        fetchedAt: page.fetchedAt,
      );
    } on TimeoutException {
      return AggregateSourceResult(
        sourceId: source.id,
        displayName: source.displayName,
        failure: '${kAggregateSourceTimeout.inSeconds} 秒没回来',
      );
    } catch (error, stackTrace) {
      return AggregateSourceResult(
        sourceId: source.id,
        displayName: source.displayName,
        failure: describeFailure(error, stackTrace: stackTrace).message,
      );
    }
  }

  /// 各源报回来的取数时刻里最新的那个（用于「显示的是缓存结果（…前）」那句）。
  DateTime? _newestFetchedAt(List<AggregateSourceResult> results) {
    DateTime? newest;
    for (final AggregateSourceResult r in results) {
      final DateTime? at = r.fetchedAt;
      if (at == null) continue;
      if (newest == null || at.isAfter(newest)) newest = at;
    }
    return newest;
  }
}

final NotifierProvider<SearchQueryController, SearchState> searchProvider =
    NotifierProvider<SearchQueryController, SearchState>(SearchQueryController.new);

// ─────────────────────────────────────────────────────────────────────────────
// 底部状态条 / 「已完成」页用的派生数据（全部来自真实引擎 SSE）
// ─────────────────────────────────────────────────────────────────────────────

/// 全引擎吞吐与对等数汇总。
@immutable
class EngineThroughput {
  final double downloadBps;
  final double uploadBps;
  final int peers;
  final int torrents;

  const EngineThroughput({
    this.downloadBps = 0,
    this.uploadBps = 0,
    this.peers = 0,
    this.torrents = 0,
  });
}

final Provider<EngineThroughput> engineThroughputProvider = Provider<EngineThroughput>((Ref ref) {
  final List<EngineTorrentView>? torrents = ref.watch(engineTorrentsProvider).value;
  if (torrents == null) return const EngineThroughput();
  double down = 0, up = 0;
  int peers = 0;
  for (final EngineTorrentView t in torrents) {
    down += t.downloadBps;
    up += t.uploadBps;
    peers += t.peers;
  }
  return EngineThroughput(
    downloadBps: down,
    uploadBps: up,
    peers: peers,
    torrents: torrents.length,
  );
});

/// 引擎侧已下完的 torrent（「已完成」页的数据源）。
final Provider<List<EngineTorrentView>> cachedTorrentsProvider = Provider<List<EngineTorrentView>>((
  Ref ref,
) {
  final List<EngineTorrentView>? torrents = ref.watch(engineTorrentsProvider).value;
  if (torrents == null) return const <EngineTorrentView>[];
  return torrents
      .where((EngineTorrentView t) => t.finished || t.progress >= 1.0)
      .toList(growable: false);
});

/// 缓存占用：已下完文件的总字节（真实来自引擎；不是磁盘占用估算）。
final Provider<int> cachedBytesProvider = Provider<int>((Ref ref) {
  int total = 0;
  for (final EngineTorrentView t in ref.watch(cachedTorrentsProvider)) {
    total += t.totalBytes;
  }
  return total;
});

// ─────────────────────────────────────────────────────────────────────────────
// 「已完成」页（第 14 轮）
// ─────────────────────────────────────────────────────────────────────────────

/// 已下完的 torrent 按**番名**归成卡（一部番一张卡，卡内按集号）。
///
/// 数据源与 [cachedTorrentsProvider] 同一份（引擎里 `finished` 的 torrent）——
/// 用户第 14 轮问答选定「新增一项，与当时那张缓存表同一数据源」（那张表第二十一轮删了,
/// 只剩「已完成」这一种摆法），所以这里只做**重排**，
/// 不引入第二种"什么算下完了"的判据。
final Provider<List<CompletedGroup>> completedGroupsProvider =
    Provider<List<CompletedGroup>>((Ref ref) {
  return completedGroups(ref.watch(cachedTorrentsProvider));
});

/// 在资源管理器里定位一个文件（默认 = 真实现；测试 override 成记录器）。
final Provider<RevealInExplorer> revealInExplorerProvider =
    Provider<RevealInExplorer>((Ref ref) => revealInExplorer);

/// 番名 → bangumi 封面（会话内记忆：不落盘，下次启动重新按"第一个结果"匹配）。
final NotifierProvider<CompletedCoverController, CompletedCoverState> completedCoverProvider =
    NotifierProvider<CompletedCoverController, CompletedCoverState>(
      CompletedCoverController.new,
    );

/// 把一批路径移进回收站（默认 = 真实现 `SHFileOperation`；测试 override 成假实现）。
///
/// 抽成 provider 而不是让页面直接调函数：删文件是本轮唯一**不可逆**的动作（回收站
/// 还救得回来，但也不能在组件测试里真删用户的文件），必须有注入缝。
final Provider<RecycleToTrash> recycleBinProvider =
    Provider<RecycleToTrash>((Ref ref) => moveToRecycleBin);
