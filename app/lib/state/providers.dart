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

import 'package:dsanima_core/dsanima_core.dart' show EngineClient, EngineException;
import 'package:dsanima_core/sources/models.dart' show SourceNoResultsException;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/aggregate.dart';
import '../domain/bangumi.dart';
import '../domain/completed.dart';
import '../domain/download_dir.dart' show effectiveDownloadDir;
import '../domain/error_text.dart';
import '../domain/models.dart';
import '../domain/ports.dart';
import '../domain/queue_sort.dart';
import '../domain/reveal_in_explorer.dart';
import '../domain/recycle_bin.dart';
import '../domain/library_seed.dart';
import '../domain/seed_language.dart';
import '../domain/seed_version.dart';
import '../domain/settings_effect.dart';
import '../domain/subtitle_groups.dart';
import '../domain/title_match.dart' show normalizeTitleForMatch;
import '../domain/unavailable.dart';
import '../theme/tokens.dart';
import 'completed_covers.dart';
import 'engine_bootstrap.dart' show CoreEngineBootstrap;
import 'infra.dart';
// ⚠️ `export` 不会把名字带进**本文件**的作用域：下面这段用到的 `schedulePortProvider`
// 与 `librarySeedServiceProvider` 都要显式 import（虽然同一批文件也被 export 出去）。
import 'library_seed_service.dart' show LibrarySeedService, librarySeedServiceProvider;
import 'schedule_provider.dart' show schedulePortProvider;
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
// 动漫库「种子」块的宿主侧服务（第四十五轮：绑定落盘 + 番剧页 30 分钟缓存）。
export 'library_seed_service.dart';
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

/// 上一次「保存并生效」时**关于边车的那句话**（null = 没什么可说的）。
///
/// 为什么要有它（1.1.0 M1/T4）：边车现在有三种结局 —— 没重启（只改了不需要重启的项）、
/// **热更新**（只改限速，`PATCH /limits`）、真重启（下载目录/引擎路径/做种比/tracker）。
/// 这三种对用户的含义不同（"要不要等 3.5 秒""以后还会不会重启"），但设置页原本只有
/// 一句固定成功文案。旧做法是让 `applySettings` **抛异常**来传达"回退重启了" ——
/// 那会把一次成功的保存画成红色失败横幅，是**骗人**的。所以改成：结果放这里，
/// 设置页成功文案把它接在后面（见 `ui/settings_page.dart` 的 `_applySuccess`）。
class EngineApplyNoteController extends Notifier<String?> {
  @override
  String? build() => null;

  void set(String? note) => state = note;

  void clear() => state = null;
}

final NotifierProvider<EngineApplyNoteController, String?> engineApplyNoteProvider =
    NotifierProvider<EngineApplyNoteController, String?>(EngineApplyNoteController.new);

/// 让设置真正生效：重启边车 + 重建源客户端。
///
/// 进程参数里**只有下载目录/引擎路径/做种比/tracker 必须重启**；上下行限速优先走
/// `PATCH /limits` 热更新（1.1.0 M1/T4：只改限速不再付 ~3.5s、不打断正在下载的连接），
/// 边车不支持或引擎没连上才回退重启，并且明确告诉用户（不许静默当成功 —— 通过
/// [engineApplyNoteProvider] 说，而不是伪造一个失败）。
class EngineLifecyclePort implements LifecyclePort {
  EngineLifecyclePort(this._ref);

  final Ref _ref;

  /// 热更新失败、回退重启时的「怎么办」文案。
  static const String _hotPatchHint =
      '想改限速免重启：把边车更新到支持 PATCH /limits 的版本（engine/README.md §10 第 9 条）；'
      '旧版边车只能靠重启生效，一次约 3.5 秒，正在下载的连接会短暂中断';

  @override
  Future<void> applySettings(AppSettings settings) async {
    final EngineApplyNoteController note = _ref.read(engineApplyNoteProvider.notifier);
    note.clear();
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
    // 引擎**只在真的需要时**才重启（用户 2026-10-11 第二阶段清单第 6 项，
    // 第十六轮改成手动保存之后这条判断照旧：一次「保存并生效」可能同时动了
    // 下载目录与 TTL，只有真的动了进程参数才付那 3.5 秒）。
    // 上下行限速**不再**算"必须重启"（1.1.0 M1/T4）：只改限速时先试 `PATCH /limits`
    // 热更新，省一次 ~3.5s、也不打断正在下载的连接；不行才回退重启。
    final AppSettings? launched = _ref.read(engineBootstrapProvider).launchedWith;
    final bool restartRequired = launched == null || engineRestartRequired(launched, settings);
    // 非 null = 热更新没成、值是「为什么没成」：下面据此回退重启，并把原因说出来。
    String? hotPatchFallback;
    if (launched != null && engineLimitsOnlyChanged(launched, settings)) {
      hotPatchFallback = await _hotPatchLimits(launched, settings);
      if (hotPatchFallback == null) {
        // 热更新成功后必须让「已生效设置」对齐（否则下一次保存又会误判需要重启）：
        // 边车进程实际跑的限速已经等于 settings，但 `launchedWith` 还记着旧值。
        // 不对齐的话，下一次保存只改外观时 `engineLimitsChanged(旧, 新)` 仍为 true，
        // 于是又白发一次 `PATCH /limits`；而任何按 `launchedWith` 判"进程参数变没变"
        // 的地方都会误判 → 白重启一次、打断下载。
        _ref.read(engineBootstrapProvider.notifier).adoptHotPatchedSettings(settings);
        note.set('限速已热更新，边车没有重启（正在下载的连接没被打断）');
      }
    }
    if (restartRequired || hotPatchFallback != null) {
      // 重启原因：首次启动/引擎没跑过 = 不是"重启"，不说原因。
      final List<String> reasons =
          launched == null ? const <String>[] : engineRestartReasons(launched, settings);
      final bool ok = await _ref
          .read(engineBootstrapProvider.notifier)
          .start(settings: settings, supportDir: supportDir);
      if (!ok) {
        final EngineBootstrapState state = _ref.read(engineBootstrapProvider);
        final String reason = state.error ?? '引擎重启失败';
        throw PortUnavailableException(
          hotPatchFallback == null ? reason : '$hotPatchFallback；重启边车也没能成功：$reason',
          hint: hotPatchFallback == null ? state.errorHint : _hotPatchHint,
        );
      }
      if (hotPatchFallback != null) {
        // **不许静默当成功**（1.1.0 M1/T4 硬要求）：这次限速是靠**重启**生效的，
        // 用户得知道"以后每次改限速还会重启"（旧边车没有 PATCH /limits 端点）。
        // 但重启本身是成功的 —— 绝不用异常把它画成失败（见 [engineApplyNoteProvider]）。
        note.set('$hotPatchFallback；已重启边车让新限速生效（约 3.5 秒），以后每次改限速仍会重启');
      } else if (reasons.isNotEmpty) {
        // `engineRestartReasons` 到这一轮才真正有了调用方：以前它只有定义和测试，
        // 用户看不到"这次为什么重启"。
        note.set('边车已重启（需要重启的改动：${reasons.join('、')}）');
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

  /// 试着用 `PATCH /limits` 热更新限速。返回 `null` = 已生效；否则返回「为什么没成」，
  /// 调用方必须**回退到重启**并把它告诉用户（不许静默当成功）。
  ///
  /// 为什么从 `EngineBootstrapPort` 伸手拿 client：端口抽象（`domain/ports.dart`）
  /// 只承诺 start/stop，故意不暴露 core 的 HTTP 客户端；限速是唯一能在**不重启**的
  /// 前提下改的进程参数，而装配根注入的真实实现就是 [CoreEngineBootstrap]（它持有
  /// 运行期 client）。其它实现（测试替身 / 未接通）一律按「引擎没连上」处理 → 回退重启。
  Future<String?> _hotPatchLimits(AppSettings from, AppSettings to) async {
    final EngineBootstrapPort port = _ref.read(engineBootstrapPortProvider);
    final EngineClient? client = port is CoreEngineBootstrap ? port.client : null;
    if (client == null) {
      return '引擎没连上，限速没法热更新，需要重启边车才能改';
    }
    final ({int? downloadBps, int? uploadBps}) patch = engineLimitsPatch(from, to);
    try {
      await client.setLimits(
        downloadBps: patch.downloadBps,
        uploadBps: patch.uploadBps,
      );
      return null;
    } on EngineException catch (error) {
      final int? status = error.statusCode;
      // 404 = 老边车根本没这个路由；405 = 路由在但方法不对（同样等于"不支持热改"）。
      if (status == 404 || status == 405) {
        return '这个引擎版本不支持热改限速（PATCH /limits → HTTP $status），需要重启边车才能改';
      }
      return '限速热更新失败：${error.message}';
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

  /// 按当前设置启动边车（已在跑则先停；下载目录/引擎路径/做种比/tracker 变了必须重启）。
  ///
  /// 限速**不**常走这里：只改限速时 `applySettings` 先试 `PATCH /limits` 热更新，
  /// 只有边车不支持/没连上才回退到本方法（见 `EngineLifecyclePort`）。
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

  /// 限速热更新成功后，把「进程是用哪份设置拉起来的」推进到最新那份。
  ///
  /// 为什么必须做（1.1.0 M1/T4）：`launchedWith` 是 `applySettings` 判断"要不要重启"
  /// 的基线。热更新**没有**重启进程，但 `launchedWith` 还停在旧限速上 —— 不推进的话，
  /// 下一次保存哪怕只改外观/只改限速，`engineLimitsChanged(旧, 新)` 仍为 true，
  /// 于是又白热更一次；将来任何按 `launchedWith` 比较进程参数的地方也会误判。
  /// 基线必须与边车**实际**参数一致，而不是与"上次重启时那份"一致。
  void adoptHotPatchedSettings(AppSettings settings) {
    final EngineBootstrapState current = state;
    // 没在跑 / 没有基线时不动：避免造出"这个进程是用 settings 拉起来的"这种假事实。
    if (!current.running || current.launchedWith == null) return;
    state = current.copyWith(launchedWith: settings);
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
/// 第二十七轮补记之后的侧栏形状：顶部导航 = **主页 / 动漫库 / 搜索 / 正在追 / 队列 / 已完成**
///（`shellNavTabs`；1.1.0 M3/T15 又在「已完成」后面加了第 7 项**扩展**），
/// 左下角那一块 = **观看记录**（`shellFooterTabs`）+ 在播时的「继续播放 / 正在播放」+
/// **设置**（最底下那一整行，`_SettingsGear`）。
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
///
/// **「扩展」**（1.1.0 M3/T15，用户 2026-10-17：「扩展就是插件一样的东西可能会加很多东西」）：
/// 侧栏顶部导航的最后一项（在「已完成」之后）；它是**资源型插件**的安装/管理页
/// （1.1.0 只把 `shader-pack` 接进**播放器的「超分」菜单**（装/卸/启停后已打开的
/// 播放窗口会立即刷新，
/// 见 `state/extension_schemes.dart`），别的内容类型装得上但暂不生效）。
/// ⚠️ 位置刻意在 `completed` 之后、`history` 之前：`history` 属于左下角那一块
/// （[shellFooterTabs]），而扩展是**常驻目的地**，所以跟顶部导航排在一起。
enum ShellTab {
  home('主页', 'mikan 追番更新表 · 今日推荐'),
  library('动漫库', 'Bangumi 全库 · 筛选浏览'),
  search('搜索', '多站点 · 分区 · 分页'),
  following('正在追', '追番 · 字幕组订阅 · 打勾与下载'),
  queue('队列', '下载进度与优先级'),
  completed('已完成', '下完的剧集 · 按番名分类'),
  /// 「本地」（2026-10-20，用户：「加入本地文件功能，可选择文件夹并加载内的视频」）：
  /// 选文件夹 → 递归扫出里面的视频 → 直接播（与引擎那条链路完全无关）。
  /// 刻意排在 `completed` 之后：「已完成」是引擎下完的东西，「本地」是自己盘上的东西，
  /// 两者相邻但数据源不同（见 docs/specs/2026-10-20-dsanima-local-media.md）。
  local('本地', '本地文件夹 · 递归扫描 · 直接播放'),
  extensions('扩展', '资源包 · 着色器包 · 在线目录'),
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

/// 队列 / 引擎那两个流的**安全快照**（第四十五轮）。
///
/// ⚠️ 这两个流在**未装配**时是 `Stream.error(...)`（`UnavailableQueuePort.watchJobs` /
/// `UnavailableEnginePort.watch` 都是"立即出错的流"），而 Riverpod 3 会给出错的服务排一条
/// **自动重试**计时器 —— 组件测试里表现为「widget 树都拆了还有 Timer 在 pending」，
/// 把**不相干**的既有用例打红（第四十五轮实测：动漫库详情页一挂上种子块，15 个用例当场红）。
///
/// 种子块里那两枚「在队列 / 已完成」只是**装饰性标记**：未接通时返回空表、**根本不订阅**，
/// 等于"引擎没装就少一个标记"，而不是让一个装饰去惊动重试机制。
final Provider<List<QueueJobView>> queueJobsSnapshotProvider =
    Provider<List<QueueJobView>>((Ref ref) {
  if (_isPlaceholderPort(ref.read(queuePortProvider))) {
    return const <QueueJobView>[];
  }
  return ref.watch(queueJobsProvider).value ?? const <QueueJobView>[];
});

/// 同 [queueJobsSnapshotProvider]，给「已完成」那枚标记用。
final Provider<List<EngineTorrentView>> engineTorrentsSnapshotProvider =
    Provider<List<EngineTorrentView>>((Ref ref) {
  if (_isPlaceholderPort(ref.read(enginePortProvider))) {
    return const <EngineTorrentView>[];
  }
  return ref.watch(engineTorrentsProvider).value ?? const <EngineTorrentView>[];
});

/// 这个端口是不是**占位实现**（`main.dart` 没注入真端口）。
///
/// ⚠️ 判据是**精确类型相等**，不是 `is`：测试里的假端口常常**继承**占位实现（只覆盖
/// 需要的那一个方法），用 `is` 会把它们也判成"未接通"，于是那些用例里的标记永远不显示。
bool _isPlaceholderPort(Object port) =>
    port.runtimeType == UnavailableQueuePort ||
    port.runtimeType == UnavailableEnginePort;

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

/// 「这个订阅抓出来的东西会变吗」的比较键（1.1.0 M1/T3）。
///
/// 只放**会影响抓到什么**的字段（源种类 + 地址 + 参数）。**不放**
/// `lastError` / `lastRefreshAt` / `name` / `rules` —— 订阅流每次自动刷新后这些都会变，
/// 旧写法 `ref.watch(subscriptionsProvider)` 一挂就是整个列表，于是列表每推一次
/// （哪怕只是 `lastCheckedAt` 动了一下）**所有订阅的条目缓存一起失效**：
/// 「正在追」一页有 N 个字幕组就重抓 N 个 RSS。
String _subscriptionFeedIdentity(SubscriptionView sub) =>
    '${sub.sourceKind}\u0001${sub.feedUrl}\u0001'
    '${(sub.sourceParams.entries.toList()..sort((MapEntry<String, String> a, MapEntry<String, String> b) => a.key.compareTo(b.key))).map((MapEntry<String, String> e) => '${e.key}=${e.value}').join('&')}';

/// 列表还没加载完（不知道这个订阅在不在）。
const String _kSubsNotLoaded = '\u0000not-loaded';

/// 列表已加载，但没有这个 id。
const String _kSubsGone = '\u0000gone';

/// 订阅列表里某个订阅的比较键（见 [_subscriptionFeedIdentity]）。
String _subscriptionKeyOf(List<SubscriptionView>? subs, String subscriptionId) {
  if (subs == null) return _kSubsNotLoaded;
  for (final SubscriptionView s in subs) {
    if (s.id == subscriptionId) return _subscriptionFeedIdentity(s);
  }
  return _kSubsGone;
}

/// 从**当前**订阅列表里取那个订阅（不建立依赖：依赖已经挂在 [subscriptionItemsProvider]
/// 的 `select` 键上了，这里只是把 `items()` 需要的那份 view 取出来）。
SubscriptionView? _findSubscription(List<SubscriptionView>? subs, String id) {
  if (subs == null) return null;
  for (final SubscriptionView s in subs) {
    if (s.id == id) return s;
  }
  return null;
}

/// 命中预览：「这条规则会下哪些」。
final subsPreviewProvider = FutureProvider.family<List<SourceItemView>, String>((
  Ref ref,
  String subscriptionId,
) async {
  // 依赖**只挂在比较键上**（1.1.0 M1/T3）：同 [_subscriptionItemsOf] 的理由。
  final String key = ref.watch<String>(
    subscriptionsProvider.select(
      (AsyncValue<List<SubscriptionView>> value) =>
          _subscriptionKeyOf(value.value, subscriptionId),
    ),
  );
  if (key == _kSubsNotLoaded) {
    throw const PortUnavailableException('订阅列表尚未加载完成，无法预览', hint: '等列表出现后再点「命中预览」');
  }
  if (key == _kSubsGone) {
    throw const PortUnavailableException('订阅不存在（可能已被删除）', hint: '刷新订阅列表后重试');
  }
  final SubscriptionView? target =
      _findSubscription(ref.read(subscriptionsProvider).value, subscriptionId);
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
///
/// ⚠️ **1.1.0 M1/T3**：依赖从「整个订阅列表」收窄成「这个订阅的抓取身份」。
/// 旧写法 `ref.watch(subscriptionsProvider)` 在订阅流每推一次（自动刷新后
/// `lastError` / `lastRefreshAt` 变了也是新 List）就让 **所有** family 一起失效 ——
/// 「正在追」一页 N 个字幕组 = 每推一次重抓 N 个 RSS。现在只有这个订阅的
/// **源地址真的变了**（改 feed / 换源种类）才会重抓。
final subscriptionItemsProvider =
    FutureProvider.family<List<SourceItemView>, String>((Ref ref, String subscriptionId) async {
  final String key = ref.watch<String>(
    subscriptionsProvider.select(
      (AsyncValue<List<SubscriptionView>> value) =>
          _subscriptionKeyOf(value.value, subscriptionId),
    ),
  );
  if (key == _kSubsNotLoaded) {
    throw const PortUnavailableException('订阅列表尚未加载完成', hint: '等列表出现后重试');
  }
  if (key == _kSubsGone) {
    throw const PortUnavailableException('订阅不存在（可能已被删除）', hint: '刷新订阅列表后重试');
  }
  final SubscriptionView? target =
      _findSubscription(ref.read(subscriptionsProvider).value, subscriptionId);
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

  /// 字幕组筛选勾选的组（归一化 key；空 = 不限）。
  ///
  /// **第四十五轮**（用户：「在搜索中加入字幕组筛选」，并选定了口径）：
  /// * 只在**客户端**筛已经取到的池子，**不进请求**（源站对字幕组的支持度天差地别：
  ///   dmhy 有分类、bangumi.moe 有 team 接口、mikan 只能靠标题解析、acgnx 混在 author 里）；
  /// * 多选 = **并集**（勾桜都 + LoliHouse = 两家的都显示）。交集是说不通的：一条结果
  ///   属于一个字幕组，取交集必然空集；
  /// * 它是**池子级**的：页码、页数、`items` 全部按筛选后的条数算（见 [visible]）。
  final Set<String> groupFilter;

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

  /// 上面这份缓存是**过期回落**来的（= 网络那一步真的失败过）。
  /// 新鲜命中（TTL 内）为 false —— 那种情况下**根本没发网络请求**，
  /// 界面不许报「网络抓取失败」（第四十二轮 UX #10）。
  final bool staleFallback;
  final DateTime? fetchedAt;
  final DsFailure? failure;

  const SearchState({
    required this.sourceId,
    this.keyword = '',
    this.mode = SearchMode.aggregate,
    this.scope,
    this.excludedSourceIds = const <String>{},
    this.groupFilter = const <String>{},
    this.aggregateWarning,
    this.fetched = const <SourceItemView>[],
    this.page = 1,
    this.sourcePage = 0,
    this.hasMoreSource = false,
    this.loading = false,
    this.loadingPage = false,
    this.loaded = false,
    this.fromCache = false,
    this.staleFallback = false,
    this.fetchedAt,
    this.failure,
  });

  /// 筛选后的池子（[groupFilter] 为空时**就是** [fetched]，零开销）。
  ///
  /// 第四十五轮：字幕组筛选是**池子级**的 —— 页码、页数、当前窗口全部按它算。
  /// 为什么不做成"只隐藏行"：那样会出现「第 1 页 0 条，页码条却说还有 3 页」这种
  /// 自相矛盾的画面（用户第四十五轮选定：池子级 + 不够一页自动续拉）。
  List<SourceItemView> get visible => groupFilter.isEmpty
      ? fetched
      : <SourceItemView>[
          for (final SourceItemView item in fetched)
            if (itemMatchesSubtitleGroups(item, groupFilter)) item,
        ];

  /// 字幕组筛选开着（chip 高亮、结果区提示行、空态文案都看它）。
  bool get filtering => groupFilter.isNotEmpty;

  /// 当前显示页的 20 条窗口。
  List<SourceItemView> get items => searchPageSlice(visible, page);

  /// 已知/可推断的总页数。
  ///
  /// 源不给总页数（`SourcePage` 只有 `hasNext`），所以只能这样推：
  /// * 池子里已攒的条目能切出几页 = 已知页数下限；
  /// * 源还说"还有下一页" → 再多算一页（源的原话只能换算成"下限 +1"，
  ///   绝不能假装知道确切数字，否则页码条会骗人）；
  /// * 一条都没有 → 至少 1 页（"第 1 / 1 页"比"第 1 / 0 页"更像人话）。
  int get pageCount {
    final int loadedPages = (visible.length + kSearchPageSize - 1) ~/ kSearchPageSize;
    if (hasMoreSource) return loadedPages + 1;
    return loadedPages < 1 ? 1 : loadedPages;
  }

  /// 有更早的页可以翻。
  bool get canGoPrevious => page > 1;

  /// 还有更晚的页可以翻（页码条/上一页/下一页都按它决定禁用与否）。
  bool get canGoNext => page < pageCount;

  bool get isEmpty => loaded && fetched.isEmpty && failure == null;

  /// 池子里**有**东西，但勾的字幕组一条都没命中（第四十五轮）。
  ///
  /// 与 [isEmpty] 分开：那是"这次搜索源那边就没有结果"，这里是"这批结果里没有你要的组"
  /// —— 两句提示给的动作完全不同（前者换关键字，后者清筛选或继续加载更多）。
  bool get emptyAfterFilter =>
      loaded && fetched.isNotEmpty && visible.isEmpty && failure == null;

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
    Set<String>? groupFilter,
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
    bool? staleFallback,
    DateTime? fetchedAt,
    DsFailure? failure,
    bool clearFailure = false,
  }) => SearchState(
    sourceId: sourceId ?? this.sourceId,
    keyword: keyword ?? this.keyword,
    mode: mode ?? this.mode,
    scope: clearScope ? null : (scope ?? this.scope),
    excludedSourceIds: excludedSourceIds ?? this.excludedSourceIds,
    groupFilter: groupFilter ?? this.groupFilter,
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
    staleFallback: staleFallback ?? this.staleFallback,
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
      // 第四十五轮：字幕组筛选**落盘记住**（用户选定「和源勾选一个待遇」）。
      groupFilter: settings.subtitleGroupFilter.toSet(),
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
      // setSource/setMode 是**新建** state（不是 copyWith），新字段忘了传就会被静默重置
      // ——`groupFilter` 是第四十五轮加的，必须显式带上（否则换一次源筛选就没了）。
      groupFilter: state.groupFilter,
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
      groupFilter: state.groupFilter, // 同上：新建 state 必须显式带上
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

  // ───────────────────────────────────────────────────────────────────────────
  // 字幕组筛选（第四十五轮）
  // ───────────────────────────────────────────────────────────────────────────

  /// 勾/取消一个字幕组（面板里那一排开关）。多选 = **并集**。
  void toggleGroup(String key) {
    final Set<String> next = <String>{...state.groupFilter};
    if (!next.remove(key)) next.add(key);
    setGroupFilter(next);
  }

  /// 改字幕组筛选（唯一入口）：改 state → 回第 1 页 → **不够一页就自动续拉** → 落盘。
  ///
  /// 为什么切筛选要回第 1 页：页码与页数都按**筛选后**的池子算（[SearchState.visible]），
  /// 停在第 5 页而筛选后只剩 2 页，页码条会当场撒谎。
  ///
  /// 为什么自动续拉：用户第四十五轮选的是「池子级 + 不够一页就自动去源站续拉」。
  /// 拉取上限**复用现有的** `maxSourceFetchesPerNav` / `maxAggregateFetchesPerNav`
  /// —— 点一下不是"无限要"，用完了还有「继续加载更多结果」那颗按钮（[loadMoreForFilter]）。
  void setGroupFilter(Set<String> groupFilter) {
    if (_sameIds(groupFilter, state.groupFilter)) return;
    state = state.copyWith(groupFilter: <String>{...groupFilter}, page: 1);
    unawaited(_persistGroupFilter(groupFilter));
    if (groupFilter.isNotEmpty) unawaited(_rememberGroups(groupFilter));
    unawaited(refillForFilter());
  }

  /// 清空筛选（面板里的「全清」、空态里的「清空筛选」）。
  void clearGroupFilter() => setGroupFilter(const <String>{});

  /// 让**当前页**在筛选后重新填满：向源续拉，直到够一页或用完这一轮的上限。
  ///
  /// 与 [goToPage] 的区别：不改目标页，也不受 `target == state.page` 那道闸门挡
  /// （筛选变化后"再来一轮"的目标正好就是当前页，走 [goToPage] 会被它直接吞掉）。
  ///
  /// [force] = true 时跳过"已经够一页了"这一步（[loadMoreForFilter] 用）。
  Future<void> refillForFilter({bool force = false}) async {
    if (!state.loaded) return;
    if (state.loading || state.loadingPage) return;
    if (!force && state.visible.length >= kSearchPageSize) return;
    if (!state.hasMoreSource) return;
    final int generation = _requestId;
    state = state.copyWith(loadingPage: true, clearFailure: true);
    final DsFailure? failure = await _fillForPage(state.page, generation: generation);
    if (!ref.mounted) return;
    if (_stale(generation)) return; // 新一轮接管了，收尾交给它
    state = state.copyWith(
      loadingPage: false,
      failure: failure,
      clearFailure: failure == null,
    );
  }

  /// 空态里那颗「继续加载更多结果」：**明知**上一轮已经用完上限，也再拉一轮。
  ///
  /// 为什么允许越过"用完了"：那是用户**明确要求**再要一点，和他点下一页是同一件事；
  /// 挡住它只会让人以为"网络坏了"。每一轮仍然受同样的上限保护（点一次最多 8/3 轮）。
  Future<void> loadMoreForFilter() => refillForFilter(force: true);

  /// 落盘（排序后写，理由同 [_persistExclusions]）。
  Future<void> _persistGroupFilter(Set<String> groupFilter) async {
    final List<String> sorted = groupFilter.toList()..sort();
    try {
      await ref.read(settingsProvider.notifier).patch(
        (AppSettings s) => s.copyWith(subtitleGroupFilter: sorted),
      );
    } catch (_) {
      // 静默：勾选已经在 state 里生效了，最坏就是"这次没记住"。
    }
  }

  /// 把刚勾的组记进「最近用过」（新的在前，最多 [kRecentSubtitleGroupLimit] 个）。
  ///
  /// 只记 key：展示名在渲染时从预置表 / 本批结果里取，存名字反而会过期
  /// （同一个组的原始写法在不同源上都不一样）。
  Future<void> _rememberGroups(Set<String> picked) async {
    final List<String> current = ref.read(settingsProvider).recentSubtitleGroups;
    final List<String> next = <String>[
      ...picked,
      for (final String key in current)
        if (!picked.contains(key)) key,
    ];
    final List<String> trimmed = next.length > kRecentSubtitleGroupLimit
        ? next.sublist(0, kRecentSubtitleGroupLimit)
        : next;
    if (_sameList(trimmed, current)) return;
    try {
      await ref.read(settingsProvider.notifier).patch(
        (AppSettings s) => s.copyWith(recentSubtitleGroups: trimmed),
      );
    } catch (_) {
      // 静默：这只是排序用的记忆，失败不影响筛选本身。
    }
  }

  static bool _sameList(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  // ───────────────────────────────────────────────────────────────────────────
  // 并发守卫（第四十二轮 UX #6）
  // ───────────────────────────────────────────────────────────────────────────
  //
  // 搜索的形状是"发请求 → 等回来 → 把结果写进 state"，中间用户完全可以改词/换源。
  // 旧实现两个毛病：
  // ① `refresh()` 开头 `if (state.loading) return;` —— 加载中提交的新查询被**整个吞掉**
  //    （用户按了回车，界面纹丝不动、也不报错）；
  // ② 没有任何序号校验 —— 在飞的旧请求回来时写的是**当前** state，于是旧源（或旧词）
  //    的那 20 条会挂到新源名下，用户看到的是"换了源但结果没变"。
  //
  // 现在：`_requestId` 是"哪一轮算数"的唯一真相（照 `library_provider` 的 `_requestId`
  // 范式）；`_inflightKey` 只用来挡**同一个意图**被重复触发（源下拉曾经一次选择打两次
  // 网络）。**判据是意图，不是"正在加载"** —— 意图变了就必须放行。

  /// 当前算数的那一轮取数。每次 [refresh] 自增；旧一轮的回应一律丢弃。
  int _requestId = 0;

  /// 正在路上的那一轮的"意图指纹"。
  String? _inflightKey;

  /// 意图指纹 = 模式 + 源 + 关键字 + 勾选（这四样决定"要问谁、问什么"）。
  String _intentKey() {
    final List<String> excluded = state.excludedSourceIds.toList()..sort();
    return '${state.mode.name}|${state.sourceId}|${state.keyword.trim()}|'
        '${excluded.join(',')}';
  }

  /// 这一轮的回应还算数吗（`generation == null` = 不校验，给内部调用用）。
  bool _stale(int? generation) =>
      generation != null && generation != _requestId;

  /// 关键字提交（回车/按钮）：清空池子，从源的原始第 1 页重来。
  Future<void> refresh() async {
    // 挡**同一个意图**的重复刷新：源下拉的 onChanged 是「setSource 自带一次刷新 +
    // 显式再刷新」，不挡就会为同一次选择打两次网络（旧实现就是这样）。
    // ⚠️ 不能退回成"加载中就 return"：加载中改了词/换了源是一个**新意图**，
    // 那样会被吞掉（第四十二轮 UX #6）。
    final String key = _intentKey();
    if (state.loading && key == _inflightKey) return;
    _inflightKey = key;
    final int generation = ++_requestId;
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
    final DsFailure? failure = await _fetchSourcePage(1, generation: generation);
    if (!ref.mounted) return;
    // 过期回应：这一轮的池子早被新一轮换掉了，写回去就是"旧结果挂到新源名下"。
    // 收尾（loading 归位）交给还在路上的那一轮，别抢。
    if (_stale(generation)) return;
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
    await _goToPage(target);
  }

  /// 上一次翻页**想去**的那一页（失败横幅上的「重试」照它再走一遍）。
  int? _lastPageTarget;

  /// 重试上一次失败的翻页（第四十二轮 UX #21）。
  ///
  /// 旧实现翻页失败只在表格上方留一条**纯文本**横幅、没有任何动作 —— 用户唯一
  /// 的出路是猜"再点一次那个页码"，而 `goToPage` 的 `target == state.page` 闸门
  /// 在"池子凑不出这一页"这类情形下正好会把它吞掉（点了没反应，原地打转）。
  /// 这里**绕开那个闸门**：用户点的是"再来一次"，目标是不是当前页无所谓。
  ///
  /// 没有翻页目标（整轮刷新失败）时退回 [refresh]。
  Future<void> retryFailedPage() async {
    final int? target = _lastPageTarget;
    if (target == null) return refresh();
    if (state.loading || state.loadingPage) return;
    await _goToPage(target);
  }

  Future<void> _goToPage(int target) async {
    _lastPageTarget = target;
    // 记下"我属于哪一轮"：翻页途中用户换了词/源（`refresh()` 会 ++），
    // 那这一轮的收尾就**不许**再写 state —— 否则它会拿旧池子的结论覆盖新一轮
    // （第四十二轮 UX #6）。
    final int generation = _requestId;
    state = state.copyWith(loadingPage: true, clearFailure: true);
    final DsFailure? failure = await _fillForPage(target, generation: generation);
    if (!ref.mounted) return;
    if (_stale(generation)) return; // 新一轮接管了，收尾交给它
    if (failure != null) {
      // 取数失败就**留在原页**：已经拿到的那一页结果不该被一次翻页失败清掉，
      // 只在底部/表格上方说明原因（横幅上那颗「重试」就是再走一遍这里）。
      state = state.copyWith(loadingPage: false, failure: failure);
      return;
    }
    if (searchPageSlice(state.visible, target).isEmpty) {
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
  ///
  /// ⚠️ 第四十五轮起这里量的是**筛选后**的 [SearchState.visible] 而不是 `fetched`：
  /// 开了字幕组筛选时，"这一页够不够 20 条"必须按**看得到的**条数算，否则点一次筛选
  /// 会得到"半页结果 + 源那边明明还有"的僵局。筛选为空时 `visible == fetched`，
  /// 行为与改造前完全一致。
  Future<DsFailure?> _fillForPage(int target, {int? generation}) async {
    final int needed = target * kSearchPageSize;
    // 聚合一轮 = 向每个源各要一页，上限要小得多（见 maxAggregateFetchesPerNav）。
    final int cap = state.mode == SearchMode.aggregate
        ? maxAggregateFetchesPerNav
        : maxSourceFetchesPerNav;
    int fetchedPages = 0;
    while (state.visible.length < needed && state.hasMoreSource) {
      if (fetchedPages >= cap) break;
      final int before = state.visible.length;
      final DsFailure? failure =
          await _fetchSourcePage(state.sourcePage + 1, generation: generation);
      if (_stale(generation)) return null; // 这一轮已经被新一轮换掉了
      if (failure != null) return failure;
      // 这一页既没有新条目、也没有任何一条命中筛选：再往下拉也是同一批，停手，别空转。
      // （筛选开着时这一条尤其重要：源页可能整页都是别的字幕组，白拉 8 轮太贵。）
      if (state.visible.length == before) break;
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
  /// [generation] = 调用方那一轮的序号：写 state 之前会核对，过期就直接丢掉
  /// （第四十二轮 UX #6，理由见 [_requestId]）。
  ///
  /// 第 14 轮起按 [SearchState.mode] 分两条路：单独源 = 原来那条；聚合 = 把这一档的
  /// 源全部问一遍（见 [_fetchAggregatePage]）。
  Future<DsFailure?> _fetchSourcePage(int sourcePage, {int? generation}) {
    if (state.mode == SearchMode.aggregate) {
      return _fetchAggregatePage(sourcePage, generation: generation);
    }
    return _fetchSingleSourcePage(sourcePage, generation: generation);
  }

  Future<DsFailure?> _fetchSingleSourcePage(int sourcePage, {int? generation}) async {
    final SourcePort port = ref.read(sourcePortProvider);
    final String sourceId = state.sourceId;
    final String keyword = state.keyword.trim();
    try {
      final SourcePageView result = keyword.isEmpty
          ? await port.latest(sourceId, page: sourcePage)
          : await port.search(sourceId, keyword, page: sourcePage);
      if (!ref.mounted) return null;
      if (_stale(generation)) return null;
      state = state.copyWith(
        fetched: searchAppendItems(state.fetched, result.items),
        sourcePage: sourcePage,
        hasMoreSource: result.hasNext,
        fromCache: result.fromCache,
        staleFallback: result.staleFallback,
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
  Future<DsFailure?> _fetchAggregatePage(int sourcePage, {int? generation}) async {
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
    // 过期回应：新一轮（换了源/词）已经接管，别把这一批并进它的池子。
    if (_stale(generation)) return null;

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
      staleFallback: results.any((AggregateSourceResult r) => r.staleFallback),
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
        staleFallback: page.staleFallback,
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

/// 「已缓存」角标用的**归一化名字上下文**（1.1.0 M1/T2）。
///
/// 为什么不能直接 watch [cachedTorrentsProvider]（旧写法）：引擎快照是**每 2Hz 一帧**的，
/// 每一帧都是新的 `List` 身份，Riverpod 因此**无条件**通知下游 —— 主页整页（推荐轮播 +
/// 区头 + 网格 + 每张卡）跟着 2Hz 重建，而且每张卡还会把「已下完的全部 torrent 名」
/// 各归一化一遍做包含匹配（逐字符扫描）。滑动时那点掉帧就出在这条链上。
///
/// 做法：用 `select` 把整个 `List` 先压成**名字指纹**（名字排序后拼接，`\u0000` 分隔）。
/// 进度/速度每帧都在动，但"哪几个 torrent 已经下完"这一步平时不变 → 指纹相等 →
/// 下游**不通知**。归一化也挪到这里做一次（名字集合变了才做），卡片侧只剩 `contains`。
///
/// ⚠️ 不要把它换成 `Provider<List<String>>` 直接 watch `cachedTorrentsProvider`：
/// `List` 的 `==` 是身份比较，新列表永远"不相等"，2Hz 重建会原样回来。
final Provider<List<String>> cachedNormalizedTorrentNamesProvider =
    Provider<List<String>>((Ref ref) {
  final String namesKey = ref.watch<String>(
    cachedTorrentsProvider.select((List<EngineTorrentView> torrents) {
      final List<String> names = <String>[
        for (final EngineTorrentView t in torrents) t.name,
      ]..sort();
      return names.join('\u0000');
    }),
  );
  if (namesKey.isEmpty) return const <String>[];
  return <String>[
    for (final String name in namesKey.split('\u0000')) normalizeTitleForMatch(name),
  ];
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

// ─────────────────────────────────────────────────────────────────────────────
// 动漫库「种子」（第四十五轮起，第四十八轮把引擎换成主流站点搜索）
// ─────────────────────────────────────────────────────────────────────────────
//
// 用户原话（第四十五轮）：「能实现动漫库中直接显示种子吗，就像主页那样」——主页卡片点
// 进去那页（`ui/bangumi_detail.dart`）就是「按字幕组列剧集 + 每集磁力」。
//
// 用户原话（第四十八轮）：「我自己去 mikan 搜都搜索得到，这里就搜不到了，修复一下，
// 然后改为主流搜索当引擎，按字幕组分隔，不同搜索引擎同名字就按合并」。
//
// 第四十八轮之前，引擎是「按番名搜 mikan → 拿搜索行去单集页换番剧 id → 读番剧页」。
// 那条路的病根在真机上是量得到的（`build/round48/`）：「命运石之门」的搜索页有 841 行、
// 841 行都带磁力，但抽样 28 行只有 **7 行**能换出番剧 id，而且**最新那 3 行一个都没有**
// （它们是 `7³ACG` 用 API 直发的合集/剧场版，页面里根本没有番剧链接）——3 次详情预算
// 全烧在它们身上，于是每部这样的番都报「mikan 上没找到」。
//
// 现在是：**引擎 = 用户勾选的那些主流站点的关键字搜索**（[_seedFanOut]，与搜索页同一套
// 并发/超时口径），番名阶梯照旧逐级退让；结果过一遍相关度、跨站同名合并、再**按字幕组
// 归段**（`domain/library_seed.dart` 的 `filterSeedItems` / `mergeSeedDuplicates` /
// `groupSeedItems`）。mikan 番剧页那条路降级成**手动**（[LibrarySeedController.bindRaw]，
// 粘地址或 id）：它给的东西更完整（整部剧集表 + 每组自己的 RSS 订阅），只是不该再当主力。

/// 种子块先露几个字幕组（「显示更多字幕组」每次再按 [kSeedGroupsStep] 加）。
const int kSeedVisibleGroups = 4;

/// 「显示更多字幕组」一次多露几个。
///
/// 为什么比首屏多：实测「命运石之门」841 行切成 **54 段**，其中 16 段只有 1 条 ——
/// 一次露 4 段要点十几次才翻完，而小段渲染起来很便宜（每段最多 [kSeedGroupVisibleStep] 行）。
const int kSeedGroupsStep = 8;

/// 每一段（字幕组）里先露几条；「本组还有 N 条」再展开（界面上的临时状态，不落盘）。
const int kSeedGroupVisibleStep = 12;

/// 种子块正在做哪一段。
enum LibrarySeedPhase {
  /// 还没开始（页面刚挂载，`ensure` 之前）。
  idle,

  /// 正在主流站点上搜这一部（番名阶梯：中文名 → 原名 → 别名 → 短名）。
  searching,

  /// 搜完了，正在取用户指定的那张 mikan 番剧页（只有手动粘过才有这一步）。
  fetching,

  /// 有结果了（已经按字幕组分好段）。
  ready,

  /// 空 / 坏：具体看 [LibrarySeedState.problem]。
  failed,
}

/// 「空」与「坏」要分开说（第四十五轮定下，第四十八轮换了名目）。
enum LibrarySeedProblem {
  none,

  /// 勾选的源都问过了，一条沾边的都没有（或用户手打的词一个站都没结果）。
  notFound,

  /// 搜到了条目，但没有一条带可下的源（磁力 / 直链 / infoHash 都没有）。
  noMagnet,

  /// 请求失败（网络 / 源站错误 / 一个源都没勾）。
  network,

  /// 用户粘进来的东西里没有番剧 id。
  badInput,
}

/// 动漫库详细页「种子」块的状态。
@immutable
class LibrarySeedState {
  const LibrarySeedState({
    this.subjectId,
    this.phase = LibrarySeedPhase.idle,
    this.query,
    this.binding,
    this.detail,
    this.episodes = const <SourceItemView>[],
    this.batchItems = const <SourceItemView>[],
    this.allItems = const <SourceItemView>[],
    this.groups = const <SeedGroup>[],
    this.batchGroups = const <SeedGroup>[],
    this.otherVersions = const <SeedOtherBlock>[],
    this.language = SeedLanguage.all,
    this.visibleGroups = kSeedVisibleGroups,
    this.problem = LibrarySeedProblem.none,
    this.failure,
    this.warning,
  });

  /// 这份状态属于哪条条目（换条目时页面据此丢弃旧数据）。
  final int? subjectId;

  final LibrarySeedPhase phase;

  /// 这一轮**实际用的**查询词（块上要显示"用的是哪个词"）。
  final String? query;

  /// 「这条条目 ↔ mikan 番剧页」的手动锚点（用户粘过 / 认下来过才有）。
  final MikanSeedBinding? binding;

  /// 那张 mikan 番剧页（含字幕组列表与各自的 RSS）；没有就是 null。
  ///
  /// 有它才能画每个字幕组旁边那颗「订阅」（mikan 的组订阅靠番剧 id + 组 RSS 地址）。
  final BangumiDetailView? detail;

  /// **本作单集**的条目（相关度筛过、跨站同名合并过、新→旧排过、**版本筛过**）。
  ///
  /// 播放列表与批量下载用它 —— 别的版本与**合集**都不在这里，否则播完一集「下一集」会
  /// 跳到另一季、或者跳进一个整季文件（第四十八轮·补六 / 补七）。
  final List<SourceItemView> episodes;

  /// 本作里的**合集**（整季一次发的批量种；第四十八轮·补七：分页里的「合集」那一页）。
  final List<SourceItemView> batchItems;

  /// **整池**（本作单集 + 合集 + 别的版本；同名合并过、新→旧排过）。
  ///
  /// 只给"合成 / 勾选下载"这类要拿到全量的地方用，界面本身不拿它画列表
  /// （界面画的是 [groups] / [batchGroups] / [otherVersions]）。
  final List<SourceItemView> allItems;

  /// **按字幕组分好的段**（本作单集；顺序 = 条数多的在前，见 [groupSeedItems]）。
  final List<SeedGroup> groups;

  /// 合集的段（按字幕组分；界面「合集」那一页按它画）。
  final List<SeedGroup> batchGroups;

  /// **别的版本**（第四十八轮·补六）：按版本分好的桶（第三季 / 剧场版 / 更早的版本…）。
  ///
  /// 界面上是分页条上的一页一页（补七：「在字幕组上面加入分页」）—— 判错的条目也在里面，**不删**。
  final List<SeedOtherBlock> otherVersions;

  /// 字幕语言过滤（第四十八轮·补九，用户「点一次只显示简体，再点一次只显示繁体，再点一次恢复」）。
  ///
  /// ⚠️ 它是**显示层**的过滤：[episodes] / [batchItems] / [groups] / [batchGroups] /
  /// [otherVersions] 都是过滤后的视图；[allItems] 仍是**整池**（切换过滤不重打网络，
  /// 只从整池重算视图，见 `LibrarySeedController.setSeedLanguage`）。
  final SeedLanguage language;

  /// 现在露几段（「显示更多字幕组」加 [kSeedGroupsStep]）。
  final int visibleGroups;

  final LibrarySeedProblem problem;
  final DsFailure? failure;

  /// 部分源没回来 / 手动锚点失效这类"结果照常给、但要说一句"的提示。
  final String? warning;

  bool get loading =>
      phase == LibrarySeedPhase.searching || phase == LibrarySeedPhase.fetching;

  /// 现在该显示的段。
  List<SeedGroup> get shownGroups => visibleGroups >= groups.length
      ? groups
      : groups.sublist(0, visibleGroups);

  /// 还有几段没露出来（0 = 「显示更多字幕组」该消失）。
  int get remainingGroups => groups.length - shownGroups.length;

  /// 别的版本一共几条（0 = 界面上连那一行都不画）。
  int get otherCount {
    int total = 0;
    for (final SeedOtherBlock block in otherVersions) {
      total += block.count;
    }
    return total;
  }

  /// 实际用的词（没搜过时为 null）。
  String? get word {
    final String text = (query ?? binding?.query ?? '').trim();
    return text.isEmpty ? null : text;
  }

  LibrarySeedState copyWith({
    int? subjectId,
    LibrarySeedPhase? phase,
    String? query,
    MikanSeedBinding? binding,
    BangumiDetailView? detail,
    bool clearDetail = false,
    List<SourceItemView>? episodes,
    List<SourceItemView>? batchItems,
    List<SourceItemView>? allItems,
    List<SeedGroup>? groups,
    List<SeedGroup>? batchGroups,
    List<SeedOtherBlock>? otherVersions,
    SeedLanguage? language,
    int? visibleGroups,
    LibrarySeedProblem? problem,
    DsFailure? failure,
    bool clearFailure = false,
    String? warning,
    bool clearWarning = false,
  }) => LibrarySeedState(
    subjectId: subjectId ?? this.subjectId,
    phase: phase ?? this.phase,
    query: query ?? this.query,
    binding: binding ?? this.binding,
    detail: clearDetail ? null : (detail ?? this.detail),
    episodes: episodes ?? this.episodes,
    batchItems: batchItems ?? this.batchItems,
    allItems: allItems ?? this.allItems,
    groups: groups ?? this.groups,
    batchGroups: batchGroups ?? this.batchGroups,
    otherVersions: otherVersions ?? this.otherVersions,
    language: language ?? this.language,
    visibleGroups: visibleGroups ?? this.visibleGroups,
    problem: problem ?? this.problem,
    failure: clearFailure ? null : (failure ?? this.failure),
    warning: clearWarning ? null : (warning ?? this.warning),
  );
}

/// 种子块的控制器（单例，不按 subject 开 family）。
///
/// 为什么不开 family：解析需要**整个 [BangumiSubject]**（要中文名/原名/别名拼查询词），
/// 而 family 的键只能是可比较的值；详情页同一时刻只开一条，用 [ensure] 换条目更直接。
/// 换条目时靠 [LibrarySeedState.subjectId] 判定"这份数据是不是我的"（页面渲染前先比）。
class LibrarySeedController extends Notifier<LibrarySeedState> {
  BangumiSubject? _subject;
  int _run = 0;

  @override
  LibrarySeedState build() => const LibrarySeedState();

  /// 页面挂载/换条目时调：同一条条目已经解析过就不重复打网络。
  void ensure(BangumiSubject subject) {
    _subject = subject;
    if (state.subjectId == subject.id && state.phase != LibrarySeedPhase.idle) return;
    unawaited(resolve(subject));
  }

  /// 解析（第四十八轮起 = 主流站点的关键字搜索）。
  ///
  /// 两件事**同时**跑：
  /// 1. 番名阶梯 × 勾选的源（主路径，见 [_searchNames]）；
  /// 2. 如果用户手动锚过一张 mikan 番剧页，顺手把它也取回来并进池子（通常命中 30 分钟
  ///    缓存，一次网络都不打）。
  ///
  /// [force]（「重新搜一遍」）= 绕开番剧页那份 30 分钟缓存。
  /// ⚠️ **锚点本身不因为 force 丢掉**：那是用户手动指的页面（第四十八轮修）——
  /// 旧写法把 force 当成"连锚点一起忘掉"，于是用户点一次「重新搜一遍」，
  /// 手动粘的那张番剧页就再也不参与了。
  Future<void> resolve(BangumiSubject subject, {bool force = false}) async {
    _subject = subject;
    final int run = ++_run;
    final LibrarySeedService service = ref.read(librarySeedServiceProvider);
    final MikanSeedBinding? anchor = service.bindingFor(subject.id);
    final List<String> names = _seedNamesOf(subject);
    final List<String> ladder = librarySeedQueries(subject);
    // 「重新搜一遍」不该忘掉用户挑的字幕语言（补九）；换一部番才回到「全部」。
    final SeedLanguage language = state.subjectId == subject.id
        ? state.language
        : SeedLanguage.all;
    state = LibrarySeedState(
      subjectId: subject.id,
      phase: LibrarySeedPhase.searching,
      query: anchor?.query ?? (ladder.isEmpty ? null : ladder.first),
      binding: anchor,
      language: language,
    );

    final List<SourceOption> targets = seedSourceTargetsFor(
      ref.read(sourceOptionsProvider),
      ref.read(searchProvider).excludedSourceIds,
    );
    if (targets.isEmpty) {
      _fail(
        run,
        LibrarySeedProblem.network,
        failure: const DsFailure(
          '一个源都没有勾（或者勾上的源都不支持关键字搜索）',
          hint: '到搜索页右上角的「源」面板把源勾上，再回这一页',
        ),
      );
      return;
    }

    // 两件事同时发出去：等主路径的时候，锚点那一页已经在路上了。
    final Future<_SeedSearch> searching =
        _searchNames(subject, names, ladder, targets, run, onlyQueries: null);
    final Future<_SeedAnchor> anchoring = _fetchAnchor(
      subject,
      anchor,
      run,
      fresh: force,
    );
    final _SeedSearch search = await searching;
    final _SeedAnchor fetched = await anchoring;
    if (_stale(run)) return;
    _apply(subject, search, fetched, run);
  }

  /// 「重新搜一次」（绕开 30 分钟番剧页缓存与落盘锚点）。
  Future<void> retry() async {
    final BangumiSubject? subject = _subject;
    if (subject == null) return;
    await resolve(subject, force: true);
  }

  /// 「改搜索词重搜」：只试用户手打的这一个词（失败就说清原因，不静默换词）。
  Future<void> useQuery(BangumiSubject subject, String query) async {
    _subject = subject;
    final String word = query.trim();
    if (word.isEmpty) return;
    final int run = ++_run;
    state = state.copyWith(
      subjectId: subject.id,
      phase: LibrarySeedPhase.searching,
      query: word,
      problem: LibrarySeedProblem.none,
      clearFailure: true,
      clearWarning: true,
      episodes: const <SourceItemView>[],
      groups: const <SeedGroup>[],
      visibleGroups: kSeedVisibleGroups,
    );
    final List<SourceOption> targets = seedSourceTargetsFor(
      ref.read(sourceOptionsProvider),
      ref.read(searchProvider).excludedSourceIds,
    );
    final List<String> names = _seedNamesOf(subject);
    final _SeedSearch search = targets.isEmpty
        ? const _SeedSearch()
        : await _searchNames(
            subject,
            names,
            const <String>[],
            targets,
            run,
            onlyQueries: <String>[word],
          );
    if (_stale(run)) return;
    _apply(subject, search, const _SeedAnchor(), run, typedQuery: word);
  }

  /// 粘 mikan 番剧页地址 / id：把它**并进**当前池子（并落盘记住）。
  ///
  /// 用户明确指定了"就是这一页"，所以它的条目**不再过相关度筛**（见 [_seedPool]），
  /// 而且它给的东西是搜索给不了的：整部的剧集表 + 每个字幕组自己的 RSS（那颗「订阅」）。
  Future<void> bindRaw(BangumiSubject subject, String raw) async {
    _subject = subject;
    final String? id = parseMikanBangumiId(raw);
    if (id == null) {
      state = state.copyWith(
        subjectId: subject.id,
        phase: LibrarySeedPhase.failed,
        problem: LibrarySeedProblem.badInput,
        failure: const DsFailure(
          '这一串里没有 mikan 番剧 id',
          hint: '粘 `https://mikanani.me/Home/Bangumi/2833` 这样的地址，或者直接写 `2833`',
        ),
      );
      return;
    }
    final int run = ++_run;
    final MikanSeedBinding binding = MikanSeedBinding(
      bangumiId: id,
      title: '',
      query: state.word ?? '',
    );
    state = state.copyWith(
      subjectId: subject.id,
      phase: LibrarySeedPhase.fetching,
      query: binding.query,
      binding: binding,
      problem: LibrarySeedProblem.none,
      clearFailure: true,
      clearWarning: true,
    );
    await ref.read(librarySeedServiceProvider).saveBinding(subject.id, binding);
    final _SeedAnchor anchor = await _fetchAnchor(
      subject,
      binding,
      run,
      fresh: true,
    );
    if (_stale(run)) return;
    final BangumiDetailView? detail = anchor.detail;
    if (detail == null) {
      _fail(
        run,
        LibrarySeedProblem.network,
        failure: DsFailure(
          '这张 mikan 番剧页没取回来',
          hint: anchor.failure?.message ?? '地址/id 对不对？或者网络/代理不通。',
        ),
      );
      return;
    }
    final MikanSeedBinding saved = MikanSeedBinding(
      bangumiId: binding.bangumiId,
      title: detail.displayTitle,
      query: binding.query,
    );
    await ref.read(librarySeedServiceProvider).saveBinding(subject.id, saved);
    if (_stale(run)) return;
    _publish(
      run,
      subjectId: subject.id,
      subject: subject,
      // ⚠️ 这里要用**整池** [LibrarySeedState.allItems]：`episodes` 只是本作那一半，
      // 拿它再合成会把「其他版本」的条目从池子里永久洗掉（第四十八轮·补六）。
      pool: _seedPool(state.allItems, detail.episodes),
      query: saved.query,
      binding: saved,
      detail: detail,
    );
  }

  /// 「展开一些」：多露 [kSeedGroupsStep] 个（界面那颗 `unfold_more` 图标用）。
  ///
  /// 第四十八轮·补五（用户原话「展开一些加回来」）：界面上那颗图标就挂在这一档上 —— 一次
  /// 多露 8 个组名，不是一次把五十多段全铺出来（那一版被退回了）。它只动**组名列表**：
  /// 不碰每段自己的开合。
  void showMoreGroups() {
    if (state.remainingGroups <= 0) return;
    state = state.copyWith(visibleGroups: state.visibleGroups + kSeedGroupsStep);
  }

  /// 「一次全露」：段窗口直接拉到全部（第四十八轮·补五起界面**不挂**它 —— 那颗图标改成
  /// 一次一档 [showMoreGroups]；这个方法留着给"全露"这种用法）。
  ///
  /// ⚠️ 它只改**组名列表的宽窄**（露几个段），**不碰**每段自己的开合 —— 那是界面上的
  /// `_openGroups`：用户第四十八轮·补四的原话是「我说的张开字幕组列表，不是把字幕组也展开了」。
  void showAllGroups() {
    if (state.remainingGroups <= 0) return;
    state = state.copyWith(visibleGroups: state.groups.length);
  }

  /// 「收起字幕组」：段窗口退回 [kSeedVisibleGroups] 个 —— 回到刚进这一页的样子
  /// （界面那颗 `unfold_less` 图标用；比首屏宽就亮着，所以"点一次也能收"）。
  void collapseGroups() {
    if (state.visibleGroups <= kSeedVisibleGroups) return;
    state = state.copyWith(visibleGroups: kSeedVisibleGroups);
  }

  /// 字幕语言过滤：点一下切一档（全部 → 简体 → 繁体 → 全部；第四十八轮·补九）。
  ///
  /// **不重打网络**：一条种子属于哪一版跟字幕语言无关，所以从 [LibrarySeedState.allItems]
  /// （整池）重新分版本、再按语言裁各视图；段窗口退回首屏那 [kSeedVisibleGroups] 个
  /// （列表变了，留着旧的"多露了 8 段"没有意义）。
  void setSeedLanguage(SeedLanguage language) {
    if (state.language == language) return;
    final BangumiSubject? subject = _subject;
    if (subject == null ||
        state.phase != LibrarySeedPhase.ready ||
        state.subjectId != subject.id) {
      state = state.copyWith(language: language);
      return;
    }
    final SeedVersionSplit split = _splitPool(state.allItems, subject);
    final List<SourceItemView> episodes = filterSeedItemsByLanguage(
      split.current,
      language,
    );
    final List<SourceItemView> batch = filterSeedItemsByLanguage(
      split.batch,
      language,
    );
    state = state.copyWith(
      language: language,
      visibleGroups: kSeedVisibleGroups,
      episodes: episodes,
      batchItems: batch,
      groups: groupSeedItems(episodes),
      batchGroups: groupSeedItems(batch),
      otherVersions: _filterOtherVersions(split.others, language),
    );
  }

  // ───────────────────────────────────────────────────────────────────────────
  // 内部
  // ───────────────────────────────────────────────────────────────────────────

  /// 引擎：把番名阶梯逐级丢给**勾选的那些主流站点**，命中即停。
  ///
  /// 「命中」的判据是 [seedItemsMentioning]：这一级回来的条目里，标题真的有名字
  /// （不是打分 —— 理由见那个函数的注释，用打分当判据会漏掉 29%）。
  /// 分级与"命中即停"的理由同 [librarySeedQueries]：mikan 的搜索是整串匹配，多一个字就
  /// 0 行，所以中文名不中就去试原名/别名/短名；而一旦某一级有货就**不再往下试**
  /// （每一级都要问所有源一轮）。
  ///
  /// 四级都没命中、但源站确实给了东西时（例如只有英文写法命中不了的站），把**最后那一批**
  /// 原样带回去（[fallback]）—— 本地判据不该有权说"各站都没有"，那是用户报的那个毛病。
  ///
  /// [onlyQueries] 非空 = 用户手打了词：只试这一个，不静默换别的（第四十五轮的口径）。
  ///
  /// 第五十一轮（用户「种子块 1/7、2/7 个源没回来」，全是 DMHY）：**自动阶梯**这一路额外
  /// 带上"短名候选"（[librarySeedShortQueries]），让某个源**正常回 0 条**时能换短名再问
  /// 它一次（见 [_seedFetchOne]；DMHY 是整串 AND 匹配，全名 0 条、短名有货）。
  /// 手打词那一路**不带**：用户要搜「Frieren」就不该悄悄改成别的词。
  Future<_SeedSearch> _searchNames(
    BangumiSubject subject,
    List<String> names,
    List<String> ladder,
    List<SourceOption> targets,
    int run, {
    required List<String>? onlyQueries,
  }) async {
    final List<String> queries = onlyQueries ?? ladder;
    if (queries.isEmpty || targets.isEmpty) return const _SeedSearch();
    final SourcePort port = ref.read(sourcePortProvider);
    final List<String> shortQueries = onlyQueries == null
        ? librarySeedShortQueries(subject)
        : const <String>[];
    List<AggregateSourceResult> last = const <AggregateSourceResult>[];
    List<SourceItemView> lastPool = const <SourceItemView>[];
    String? lastQuery;
    for (final String query in queries) {
      if (_stale(run)) return const _SeedSearch();
      state = state.copyWith(
        subjectId: subject.id,
        phase: LibrarySeedPhase.searching,
        query: query,
        problem: LibrarySeedProblem.none,
        clearFailure: true,
      );
      final List<AggregateSourceResult> results = await _seedFanOut(
        port,
        targets,
        query,
        shortQueries: shortQueries,
      );
      if (_stale(run)) return const _SeedSearch();
      last = results;
      List<SourceItemView> merged = const <SourceItemView>[];
      for (final AggregateSourceResult result in results) {
        merged = aggregateMerge(merged, result.items);
      }
      // 这一级一个站都没给东西 → 退到下一级（不是"报错"，是"这个写法在源站上不认"）。
      if (merged.isEmpty) continue;
      final List<SourceItemView> hits = seedItemsMentioning(merged, names);
      if (hits.isEmpty) {
        // 兜底：下一级也空的时候，至少还有东西给用户看（词要记住是**哪一级**给的，
        // 块上那句"用的是「…」"说的就是它）。
        lastPool = merged;
        lastQuery = query;
        continue;
      }
      return _SeedSearch(items: hits, results: results, query: query);
    }
    return _SeedSearch(
      fallback: lastPool,
      query: lastPool.isEmpty ? null : lastQuery,
      results: last,
    );
  }

  /// 取用户锚定的那张 mikan 番剧页（30 分钟缓存优先；[fresh] = 绕开缓存）。
  ///
  /// 取不回来（404 / 被删 / 网络）：**忘掉这个锚点**并记一句提示 —— 绝不能让一张取不回来
  /// 的页面拖垮这一块。现在的主力是各站搜索，番剧页只是"更完整的一份数据"。
  Future<_SeedAnchor> _fetchAnchor(
    BangumiSubject subject,
    MikanSeedBinding? binding,
    int run, {
    bool fresh = false,
  }) async {
    if (binding == null) return const _SeedAnchor();
    final LibrarySeedService service = ref.read(librarySeedServiceProvider);
    if (!fresh) {
      final BangumiDetailView? cached = service.cachedDetail(binding.bangumiId);
      if (cached != null) return _SeedAnchor(binding: binding, detail: cached);
    }
    try {
      final BangumiDetailView detail = await ref
          .read(schedulePortProvider)
          .bangumi(binding.bangumiId);
      if (_stale(run)) return const _SeedAnchor();
      service.putDetail(binding.bangumiId, detail);
      return _SeedAnchor(binding: binding, detail: detail);
    } catch (error, stackTrace) {
      if (_stale(run)) return const _SeedAnchor();
      await service.forgetBinding(subject.id);
      return _SeedAnchor(
        failure: describeFailure(error, stackTrace: stackTrace),
      );
    }
  }

  /// 搜索到的东西 + 锚定的番剧页 → 定稿。
  ///
  /// [typedQuery] = 用户手打的词：阶梯那条路失败时**不带** query（见 [_fail] 的注释），
  /// 但用户自己打的词要说出来 —— 「各站都没搜到「Frieren」」比「各站都没搜到这一部」有用。
  void _apply(
    BangumiSubject subject,
    _SeedSearch search,
    _SeedAnchor anchor,
    int run, {
    String? typedQuery,
  }) {
    if (_stale(run)) return;
    final List<AggregateSourceResult> failed = aggregateFailures(search.results);
    final bool allFailed =
        search.results.isNotEmpty && failed.length == search.results.length;
    final DsFailure? anchorFailure = anchor.failure;
    final String? anchorNote = anchorFailure == null
        ? null
        : '记住的那张 mikan 番剧页取不回来了（${anchorFailure.message}），'
              '这一轮用的是各站搜索的结果。';
    // 四级都没命中名字、但源站给了东西 → 原样给用户（本地判据无权宣布"各站都没有"）。
    final List<SourceItemView> found = search.items.isNotEmpty
        ? search.items
        : search.fallback;
    if (found.isEmpty && anchor.detail == null) {
      // 一条都没有：分开说"全失败（网络）"与"都成功了但都没有"（第四十五轮定的口径）。
      _fail(
        run,
        allFailed ? LibrarySeedProblem.network : LibrarySeedProblem.notFound,
        failure: allFailed
            ? DsFailure(
                '勾选的源全都没回来（${search.results.length} 个）',
                hint: '${failed.first.failure}；检查网络/代理，'
                    '或到搜索页的「源」面板换个源再来',
              )
            : null,
        warning: anchorNote,
        query: search.query ?? typedQuery ?? anchor.binding?.query,
      );
      return;
    }
    _publish(
      run,
      subjectId: subject.id,
      subject: subject,
      pool: _seedPool(
        found,
        anchor.detail?.episodes ?? const <SourceItemView>[],
      ),
      query: search.query ?? typedQuery ?? anchor.binding?.query,
      binding: anchor.binding,
      detail: anchor.detail,
      results: search.results,
      warning: anchorNote,
    );
  }

  /// 合成池子：搜索来的（已过相关度筛）+ 锚定番剧页来的（**不过筛**，用户自己指定了
  /// "就是这一页"）→ 去重 → 同名合并 → 新→旧排。
  List<SourceItemView> _seedPool(
    Iterable<SourceItemView> searched,
    Iterable<SourceItemView> anchored,
  ) => aggregateSort(
    mergeSeedDuplicates(
      aggregateMerge(List<SourceItemView>.of(searched), anchored),
    ),
  );

  /// 整池 → 版本分桶（判定逻辑见 `domain/seed_version.dart`；补六 / 补七 / 补八）。
  SeedVersionSplit _splitPool(
    List<SourceItemView> pool,
    BangumiSubject subject,
  ) => splitSeedVersions(
    pool,
    seedSignatureOf(
      names: _seedNamesOf(subject),
      platform: subject.platform,
      date: subject.date,
      eps: subject.eps,
    ),
  );

  /// 别的版本的桶也按字幕语言裁一遍（补九）：空桶直接去掉，桶名 / 年份提示原样保留。
  List<SeedOtherBlock> _filterOtherVersions(
    List<SeedOtherBlock> blocks,
    SeedLanguage language,
  ) {
    final List<SeedOtherBlock> out = <SeedOtherBlock>[];
    for (final SeedOtherBlock block in blocks) {
      final List<SourceItemView> items = filterSeedItemsByLanguage(
        block.items,
        language,
      );
      if (items.isEmpty) continue;
      out.add(
        SeedOtherBlock(
          label: block.label,
          hint: block.hint,
          items: items,
          groups: groupSeedItems(items),
        ),
      );
    }
    return out;
  }

  /// 定稿：分版本 + 分段 + 判"有没有可下的"。**池子为空由调用方先说清是哪一种空**。
  void _publish(
    int run, {
    required int subjectId,
    required BangumiSubject subject,
    required List<SourceItemView> pool,
    String? query,
    MikanSeedBinding? binding,
    BangumiDetailView? detail,
    List<AggregateSourceResult> results = const <AggregateSourceResult>[],
    String? warning,
  }) {
    if (_stale(run)) return;
    if (!pool.any((SourceItemView item) => item.canDownload)) {
      // 「搜到了条目但没有一条带源」是独立的一种空（第四十五轮选定）。
      state = state.copyWith(
        subjectId: subjectId,
        phase: LibrarySeedPhase.failed,
        problem: LibrarySeedProblem.noMagnet,
        query: query,
        binding: binding,
        detail: detail,
        episodes: pool,
        allItems: pool,
        groups: groupSeedItems(pool),
        batchItems: const <SourceItemView>[],
        batchGroups: const <SeedGroup>[],
        otherVersions: const <SeedOtherBlock>[],
        visibleGroups: kSeedVisibleGroups,
        warning: warning,
        clearWarning: warning == null,
      );
      return;
    }
    // 「这一条属于哪一版」（第四十八轮·补六，见 `domain/seed_version.dart`）：
    // 本作进列表，别的版本分桶；本作里的**合集**再单独切一页（补七）。
    // 判错的方向**宁多勿少** —— 最坏也只是把本作的一条挪进了别的页，那条不丢、翻得到。
    final SeedVersionSplit split = _splitPool(pool, subject);
    // 语言过滤（补九）在**分桶之后**：它只裁显示的行，不改变一条种子属于哪一版。
    final SeedLanguage language = state.language;
    final List<SourceItemView> episodes = filterSeedItemsByLanguage(
      split.current,
      language,
    );
    final List<SourceItemView> batch = filterSeedItemsByLanguage(
      split.batch,
      language,
    );
    final String banner = aggregateFailureBanner(results);
    final String note = <String>[
      ?warning,
      if (banner.isNotEmpty) banner,
    ].join(' ');
    state = LibrarySeedState(
      subjectId: subjectId,
      phase: LibrarySeedPhase.ready,
      query: query,
      binding: binding,
      detail: detail,
      language: language,
      episodes: episodes,
      batchItems: batch,
      allItems: pool,
      groups: groupSeedItems(episodes),
      batchGroups: groupSeedItems(batch),
      otherVersions: _filterOtherVersions(split.others, language),
      warning: note.isEmpty ? null : note,
    );
  }

  void _fail(
    int run,
    LibrarySeedProblem problem, {
    DsFailure? failure,
    String? warning,
    String? query,
  }) {
    if (_stale(run)) return;
    // ⚠️ 这里**重建** state 而不是 `copyWith`：阶梯跑完时 `state.query` 停在**最后一级**
    // （最不像的那个写法），拿它去写「各站都没搜到「…」」是在怪用户——所以失败态默认
    // **不带 query**（界面会退回这一部番自己的名字），要保留就显式传进来。
    state = LibrarySeedState(
      subjectId: state.subjectId,
      phase: LibrarySeedPhase.failed,
      query: query,
      binding: state.binding,
      problem: problem,
      failure: failure,
      warning: warning,
    );
  }

  bool _stale(int run) => run != _run || !ref.mounted;
}

/// 用户能用来拼查询词的全部名字（回验也用它）。
List<String> _seedNamesOf(BangumiSubject subject) {
  final List<String> out = <String>[];
  void add(String? raw) {
    final String text = (raw ?? '').trim();
    if (text.isNotEmpty && !out.contains(text)) out.add(text);
  }

  add(subject.nameCn);
  add(subject.name);
  for (final String alias in librarySeedAliases(subject)) {
    add(alias);
  }
  return out;
}

/// 一轮"问所有源"的结果（[_searchNames] 的返回值）。
///
/// [items] 是**名字真的命中**的那些；[fallback] 是"每一级都没命中、但源站确实给了东西"
/// 时留着的那一批（见 [_searchNames] 末尾）；[results] 是**原始**的每源结果（哪几个源
/// 没回来要说给用户听）；[query] 是真正命中的那个词（四级阶梯里是哪一级）。
@immutable
class _SeedSearch {
  const _SeedSearch({
    this.items = const <SourceItemView>[],
    this.fallback = const <SourceItemView>[],
    this.results = const <AggregateSourceResult>[],
    this.query,
  });

  final List<SourceItemView> items;
  final List<SourceItemView> fallback;
  final List<AggregateSourceResult> results;
  final String? query;
}

/// 用户锚定的那张 mikan 番剧页取回来的结果。
@immutable
class _SeedAnchor {
  const _SeedAnchor({this.binding, this.detail, this.failure});

  final MikanSeedBinding? binding;
  final BangumiDetailView? detail;

  /// 取不回来时的原因（取不回来 = 已经把这个锚点忘了，见 `_fetchAnchor`）。
  final DsFailure? failure;
}

/// 种子块要问哪些源 = **用户勾选的那些**（与搜索页「源」面板同一份真相）。
///
/// 真相只有一份：`SearchQueryController` 的排除名单（用户点面板时它就落盘到
/// `AppSettings.aggregateExcludedSourceIds`，见 `_persistExclusions`）。调用点读**实时**
/// 那一份而不是设置里那份：用户刚在搜索页改完勾选、还没落盘完成就点进动漫库，
/// 也该按他刚勾的来。
///
/// 参数是两个清单而不是 `Ref`：调用方一半是 controller（`Ref`）、一半是界面（`WidgetRef`），
/// 两者没有共同的父类型能读 provider。
///
/// ⚠️ 第四十八轮·补：在勾选之上再减掉 [kSeedSkippedSourceIds]（ACG.RIP）—— 用户
/// 「去除 acg.rip 源」。减法放在**这里**而不是各个调用点：controller 的两处取站点、
/// 以及失败文案里"问过几个站"的那个数字，读的都是这一份口径，不会各说各话。
List<SourceOption> seedSourceTargetsFor(
  List<SourceOption> all,
  Set<String> excluded,
) => selectedSources(all, excluded, needSearch: true)
    .where((SourceOption s) => !kSeedSkippedSourceIds.contains(s.id))
    .toList(growable: false);

/// 种子块的聚合兜底：把 [query] 在 [targets] 上搜一遍（并发与超时口径同搜索页）。
///
/// [shortQueries] 只透传给 [_seedFetchOne]：某个源**正常回 0 条**时才轮到它们（第五十一轮）。
Future<List<AggregateSourceResult>> _seedFanOut(
  SourcePort port,
  List<SourceOption> targets,
  String query, {
  List<String> shortQueries = const <String>[],
}) async {
  final List<AggregateSourceResult> out = List<AggregateSourceResult>.filled(
    targets.length,
    const AggregateSourceResult(sourceId: '', displayName: ''),
  );
  int next = 0;
  Future<void> worker() async {
    while (true) {
      final int at = next++;
      if (at >= targets.length) return;
      out[at] = await _seedFetchOne(
        port,
        targets[at],
        query,
        shortQueries: shortQueries,
      );
    }
  }

  final int workers = targets.length < kAggregateMaxConcurrent
      ? targets.length
      : kAggregateMaxConcurrent;
  await Future.wait(<Future<void>>[
    for (int i = 0; i < workers; i++) worker(),
  ]);
  return out;
}

/// 问一个源。**永不抛**（与搜索页的 `_fetchOneSource` 同一口径）。
///
/// 第五十一轮（用户「动漫库种子块 1/7、2/7 个源没回来」，全是 DMHY）：DMHY 的关键字搜索
/// 是**整串 / 分词 AND 匹配**（实测表见 [shortenSeedQuery]），名字里多一段副标题或章节名
/// 就 0 条，而同一部番的短名有货。所以这里对「这个源**正常**回 0 条」的情形，依次用
/// [shortQueries] 里的短名补搜，命中即用（这个源就算回来了，不再是"没回来"）。
///
/// 三条边界（都有测试钉着）：
/// * **只补「0 条」**：[SourceNoResultsException]，或"成功但 items 为空"。网络失败 / 超时
///   **不补** —— 那说明站挂了，补搜只是再白等一轮；
/// * 候选由调用方按「最多 [kMaxLibrarySeedShortQueries] 个」收窄，这里再跳过与本次查询
///   相同的词和长度 < 2 的，所以**简单名字**（短名 == 原名）一个额外请求都不会有；
/// * 全空时把"也试过哪些短名"写进失败文案 —— 否则用户看到"没回来"会以为是自己网络坏了。
Future<AggregateSourceResult> _seedFetchOne(
  SourcePort port,
  SourceOption source,
  String query, {
  List<String> shortQueries = const <String>[],
}) async {
  final _SeedAsk first = await _seedAskOnce(port, source, query);
  if (!first.noResults) return first.result;
  final List<String> fallbacks = <String>[
    for (final String candidate in shortQueries)
      if (candidate != query && candidate.length >= 2) candidate,
  ];
  for (final String word in fallbacks) {
    final _SeedAsk again = await _seedAskOnce(port, source, word);
    if (again.result.items.isNotEmpty) return again.result;
  }
  final String? reason = first.result.failure;
  if (reason == null || fallbacks.isEmpty) return first.result;
  final String tried = fallbacks.map((String word) => '「$word」').join('、');
  return AggregateSourceResult(
    sourceId: first.result.sourceId,
    displayName: first.result.displayName,
    items: first.result.items,
    hasNext: first.result.hasNext,
    failure: '$reason（短名$tried 也试过，同样 0 条）',
    fromCache: first.result.fromCache,
    staleFallback: first.result.staleFallback,
    fetchedAt: first.result.fetchedAt,
  );
}

/// 问一个源**一次**。[_seedFetchOne] 的短名补搜就是拿它多问几次。
///
/// [noResults] 只表示"源站正常、这一轮 0 条"（唯一允许补搜的情形）：
/// [SourceNoResultsException] 或者成功但条目为空；失败（网络 / 超时 / 坏页）一律 false。
Future<_SeedAsk> _seedAskOnce(
  SourcePort port,
  SourceOption source,
  String query,
) async {
  try {
    final SourcePageView page = await port
        .search(source.id, query)
        .timeout(kAggregateSourceTimeout);
    return _SeedAsk(
      AggregateSourceResult(
        sourceId: source.id,
        displayName: source.displayName,
        items: List<SourceItemView>.unmodifiable(page.items),
        hasNext: page.hasNext,
        fromCache: page.fromCache,
        staleFallback: page.staleFallback,
        fetchedAt: page.fetchedAt,
      ),
      noResults: page.items.isEmpty,
    );
  } on TimeoutException {
    return _SeedAsk(
      AggregateSourceResult(
        sourceId: source.id,
        displayName: source.displayName,
        failure: '${kAggregateSourceTimeout.inSeconds} 秒没回来',
      ),
    );
  } on SourceNoResultsException catch (error) {
    // 0 条不是"站挂了"：源站自己那句文案就说了"没有结果（0 条）"，原样给用户看。
    return _SeedAsk(
      AggregateSourceResult(
        sourceId: source.id,
        displayName: source.displayName,
        failure: error.message,
      ),
      noResults: true,
    );
  } catch (error, stackTrace) {
    return _SeedAsk(
      AggregateSourceResult(
        sourceId: source.id,
        displayName: source.displayName,
        failure: describeFailure(error, stackTrace: stackTrace).message,
      ),
    );
  }
}

/// 一个源**问一次**的结果 + 「这次算不算正常 0 条」。
///
/// 为什么把 0 条单独标出来（第五十一轮）：只有这一种情形值得换短名补搜；
/// 网络失败 / 超时补搜只是白打一次请求。
@immutable
class _SeedAsk {
  const _SeedAsk(this.result, {this.noResults = false});

  final AggregateSourceResult result;
  final bool noResults;
}

final NotifierProvider<LibrarySeedController, LibrarySeedState>
    librarySeedProvider =
    NotifierProvider<LibrarySeedController, LibrarySeedState>(
      LibrarySeedController.new,
    );
