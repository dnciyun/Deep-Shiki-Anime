/// **core 数据层适配**：把已经落地的 `dsanima_core` 源/订阅/队列真实现接进宿主。
///
/// ⚠️ 只有 `main.dart`（装配根）import 本文件；UI/state 层只认 `domain/ports.dart`
/// 的抽象端口（这样上游重构不会打断宿主的 analyze / widget 测试）。
///
/// 这里做三件事：
/// * [HostDataRuntime]：持有 `SourceRegistry` / `SubscriptionStore` / `QueueManager`
///   与三份端口实现，并负责「设置变更后重建」；
/// * 模型互转：core `SourceItem`/`SourcePage`/`Subscription`/`SubsRule`/`QueueJob`
///   ↔ 宿主视图模型（字段名逐字对齐 spec，纯搬运）；
/// * 订阅刷新语义：**首次只做已读标记不倒灌**（`seed`）、命中 `autoDownload` 才入队、
///   候选喂给 `QueueManager.addCandidates` 供「下完本集预取下一集」。
library;

import 'dart:async';
import 'dart:io';

import 'package:dsanima_core/dsanima_core.dart' as core;
import 'package:dsanima_core/sources/kv.dart' show KeyValueStore;
import 'package:flutter/foundation.dart' show ValueNotifier;

import '../domain/models.dart' as domain;
import '../domain/ports.dart';

// ─────────────────────────────────────────────────────────────────────────────
// 模型互转（纯函数，可单测）
// ─────────────────────────────────────────────────────────────────────────────

/// 「设置 → 网络」里的代理 → core 的 [core.ProxyConfig]。
///
/// 抽成公开函数是因为有**两个**调用方：源抓取（[HostDataRuntime._buildRegistry]）
/// 与检查更新（`main.dart` 给 `GitHubUpdatePort` 的 HTTP 客户端工厂）。
/// GitHub 在很多网络里直连不通，两处各写一份迟早会走偏（一处支持 socks5、一处不支持）。
core.ProxyConfig coreProxyConfig(domain.AppSettings settings) => core.ProxyConfig(
  mode: switch (settings.proxyMode) {
    domain.ProxyMode.none => core.ProxyMode.none,
    domain.ProxyMode.http => core.ProxyMode.http,
    domain.ProxyMode.socks5 => core.ProxyMode.socks5,
  },
  host: settings.proxyHost.trim().isEmpty ? null : settings.proxyHost.trim(),
  port: settings.proxyPort,
  username: settings.proxyUsername.trim().isEmpty ? null : settings.proxyUsername.trim(),
  password: settings.proxyPassword.isEmpty ? null : settings.proxyPassword,
);

domain.SourceItemView toItemView(core.SourceItem item) => domain.SourceItemView(
  id: item.id,
  sourceId: item.sourceId,
  title: item.title,
  detailUrl: item.detailUrl,
  torrentUrl: item.torrentUrl,
  magnet: item.magnet,
  infoHash: item.infoHash,
  sizeBytes: item.sizeBytes,
  seeders: item.seeders,
  leechers: item.leechers,
  downloads: item.downloads,
  publishedAt: item.publishedAt,
  category: item.category,
  group: item.group,
  episodeHints: item.episodeHints,
  extra: Map<String, Object?>.from(item.extra),
);

domain.SourcePageView toPageView(core.SourcePage page) => domain.SourcePageView(
  items: page.items.map(toItemView).toList(growable: false),
  page: page.page,
  hasNext: page.hasNext,
  fetchedAt: page.fetchedAt,
  fromCache: page.fromCache,
);

core.Subscription toCoreSubscription(domain.SubscriptionView view) => core.Subscription(
  id: view.id,
  name: view.name,
  feedUrl: view.feedUrl,
  sourceKind: view.sourceKind,
  sourceParams: Map<String, String>.from(view.sourceParams),
  rules: view.rules.map(toCoreRule).toList(growable: false),
  refreshInterval: view.refreshInterval,
  enabled: view.enabled,
  lastRefreshAt: view.lastRefreshAt,
  lastError: view.lastError,
  seededIds: view.seededCount > 0
      ? <String, bool>{for (int i = 0; i < view.seededCount; i++) '$i': true}
      : null,
);

core.SubsRule toCoreRule(domain.SubsRuleView rule) => core.SubsRule(
  id: rule.id,
  name: rule.name,
  sourceId: rule.sourceId,
  includeRegex: rule.includeRegex,
  excludeRegex: rule.excludeRegex,
  groupAllow: rule.groupAllow,
  minSeeders: rule.minSeeders,
  minSizeMB: rule.minSizeMB,
  maxSizeMB: rule.maxSizeMB,
  preferResolution: rule.preferResolution,
  autoDownload: rule.autoDownload,
  saveSubFolder: rule.saveSubFolder,
);

domain.SubsRuleView toRuleView(core.SubsRule rule) => domain.SubsRuleView(
  id: rule.id,
  name: rule.name,
  sourceId: rule.sourceId,
  includeRegex: rule.includeRegex,
  excludeRegex: rule.excludeRegex,
  groupAllow: rule.groupAllow,
  minSeeders: rule.minSeeders,
  minSizeMB: rule.minSizeMB,
  maxSizeMB: rule.maxSizeMB,
  preferResolution: rule.preferResolution,
  autoDownload: rule.autoDownload,
  saveSubFolder: rule.saveSubFolder,
);

domain.SubscriptionView toSubscriptionView(core.Subscription sub) => domain.SubscriptionView(
  id: sub.id,
  name: sub.name,
  feedUrl: sub.feedUrl,
  sourceKind: sub.sourceKind,
  sourceParams: Map<String, String>.from(sub.sourceParams),
  rules: sub.rules.map(toRuleView).toList(growable: false),
  refreshInterval: sub.refreshInterval,
  enabled: sub.enabled,
  lastRefreshAt: sub.lastRefreshAt,
  lastError: sub.lastError,
  seededCount: sub.seededIds.length,
);

domain.QueueJobView toJobView(core.QueueJob job) => domain.QueueJobView(
  id: job.id,
  subscriptionId: job.subscriptionId,
  item: toItemView(job.item),
  state: switch (job.state) {
    core.JobState.queued => domain.JobState.queued,
    core.JobState.downloading => domain.JobState.downloading,
    core.JobState.paused => domain.JobState.paused,
    core.JobState.completed => domain.JobState.completed,
    core.JobState.failed => domain.JobState.failed,
    core.JobState.cancelled => domain.JobState.cancelled,
  },
  engineId: job.engineId,
  fileIndex: job.fileIndex,
  priority: job.priority,
  attempts: job.attempts,
  error: job.error,
  createdAt: job.createdAt,
  updatedAt: job.updatedAt,
);

/// 宿主策略 → core 策略。
///
/// [stopSeedingAfterDownload] **故意设成 required**：它由设置里的「开启做种」开关决定
/// （`seedEnabled == false` ⇒ true），把开关真正接到队列上（下完就 `pause()`）。
/// 忘传就编译不过 —— 这个 bug（关掉做种却一直在上传）就是这么漏出去的：
/// 旧实现只把 `--seed-ratio` 传成 0，而边车的语义是「0 = 不做任何做种干预」。
core.BandwidthPolicy toCorePolicy(
  domain.BandwidthPolicy policy, {
  required bool stopSeedingAfterDownload,
}) => core.BandwidthPolicy(
  preheatAhead: policy.preheatAhead,
  stopSeedingAfterPlayback: policy.stopSeedingAfterPlayback,
  stopSeedingAfterDownload: stopSeedingAfterDownload,
  deleteAfterPlayed: policy.deleteAfterPlayed,
  maxConcurrent: policy.maxConcurrent,
  excludePatterns: policy.excludePatterns,
);

/// core `MikanScheduleEntry` → 宿主视图（纯搬运）。
///
/// **不补字段**：封面没给就是 null（UI 降级成灰框），集数本来就没有（不编）。
domain.ScheduleEntryView toScheduleEntryView(core.MikanScheduleEntry entry) =>
    domain.ScheduleEntryView(
      bangumiId: entry.bangumiId,
      dayOfWeek: entry.dayOfWeek,
      title: entry.title,
      coverUrl: entry.coverUri?.toString(),
      updateText: entry.updateText,
      updatedAt: entry.updatedAt,
      index: entry.index,
      subscribed: entry.subscribed,
      detailUrl: entry.detailUrl,
    );

/// core `MikanSchedule` → 宿主视图。一次拿全周，切星期不再打站点。
domain.ScheduleView toScheduleView(core.MikanSchedule schedule, {DateTime? fetchedAt}) =>
    domain.ScheduleView(
      entries: schedule.entries.map(toScheduleEntryView).toList(growable: false),
      byDay: <int, List<domain.ScheduleEntryView>>{
        for (final MapEntry<int, List<core.MikanScheduleEntry>> e in schedule.byDay.entries)
          e.key: e.value.map(toScheduleEntryView).toList(growable: false),
      },
      fetchedAt: fetchedAt ?? DateTime.now(),
      skipped: schedule.skipped,
    );

// ─────────────────────────────────────────────────────────────────────────────
// 运行期（装配根创建）
// ─────────────────────────────────────────────────────────────────────────────

/// 宿主数据层运行期：源 + 订阅 + 队列。
class HostDataRuntime {
  HostDataRuntime({
    required this.holder,
    required this.store,
    required this.enginePort,
    required this.torrentPort,
    required domain.AppSettings settings,
    required this.supportDir,
  }) : _subsStore = core.SubscriptionStore(store, key: 'subscriptions'),
       queue = core.QueueManager(
         engine: torrentPort,
         store: store,
         policy: toCorePolicy(
           settings.bandwidth,
           // 「开启做种」默认关 ⇒ 队列在下完那一刻 pause（= 不做种）。
           stopSeedingAfterDownload: !settings.seedEnabled,
         ),
         jobsKey: 'queue.jobs',
       ) {
    _registry = _buildRegistry(settings);
  }

  /// 运行期持有者：端口通过它拿运行期（null = 未装配 → 可行动错误）。
  final HostDataHolder holder;
  final KeyValueStore store;
  final EnginePort enginePort;
  final core.TorrentEnginePort torrentPort;
  final Directory? supportDir;

  late core.SourceRegistry _registry;

  final core.SubscriptionStore _subsStore;
  final core.QueueManager queue;

  final StreamController<List<domain.SubscriptionView>> _subsOut =
      StreamController<List<domain.SubscriptionView>>.broadcast();
  List<core.Subscription> _subs = <core.Subscription>[];
  List<domain.SubscriptionView> _subsViews = <domain.SubscriptionView>[];

  /// 「仅订阅」按钮的候选（手动加入订阅过滤的条目，持久化）。
  static const String _manualKey = 'dsanima.subs_candidates';

  /// 自动下载策略版本（见 [_migrateAutoDownloadPolicy]）。
  static const String _autoDownloadPolicyKey = 'dsanima.subs_autodownload_policy';
  static const int _autoDownloadPolicyVersion = 2;
  List<core.SourceItem> _manualCandidates = <core.SourceItem>[];

  core.SourceRegistry get registry => _registry;

  CoreSourcePort get sourcePort => CoreSourcePort(holder);
  CoreSubsPort get subsPort => CoreSubsPort(holder);
  CoreQueuePort get queuePort => CoreQueuePort(holder);
  CoreSchedulePort get schedulePort => CoreSchedulePort(holder);

  /// 启动：读订阅/队列 + 注册 RSS 源 + 启动进度订阅 + 与引擎对齐。
  Future<void> init() async {
    await _loadSubscriptions();
    await _migrateAutoDownloadPolicy();
    await queue.load();
    queue.start();
    await _loadManualCandidates();
    try {
      await queue.reconcileWithEngine();
    } catch (error) {
      // 引擎没起时对齐会失败：这不是错误，等引擎起来后由 applySettings 再对齐。
      if (error is! PortUnavailableException) rethrow;
    }
  }

  /// 一次性迁移：v1 的 `SubsRuleView.autoDownload` 默认是 **true**，凡是没显式关过的
  /// 订阅都会在每次刷新时自动入队下载 —— 用户看到的就是「自动下载几部不知道什么的动漫，
  /// 还删不掉」。v2 改成「默认关、显式开」，升级时把历史规则一并关掉（用户需要就自己打开）。
  Future<void> _migrateAutoDownloadPolicy() async {
    final Object? raw = store.get(_autoDownloadPolicyKey);
    if (raw is num && raw.toInt() >= _autoDownloadPolicyVersion) return;
    bool changed = false;
    for (final core.Subscription sub in _subs) {
      for (final core.SubsRule rule in sub.rules) {
        if (rule.autoDownload) {
          rule.autoDownload = false;
          changed = true;
        }
      }
    }
    if (changed) {
      await _subsStore.save(_subs);
      await _emitSubscriptions();
    }
    await store.put(_autoDownloadPolicyKey, _autoDownloadPolicyVersion);
  }

  /// 设置变更：重建源注册表（代理/限速/TTL 都在构造参数里）+ 更新队列策略。
  Future<void> applySettings(domain.AppSettings settings) async {
    final core.SourceRegistry old = _registry;
    _registry = _buildRegistry(settings);
    old.dispose();
    // 源表换了（最典型的就是打开 sukebei：注册表里多一个实例）→ 通知 UI 重算下拉。
    holder.sourcesChanged();
    await _registerSubscriptionSources();
    // 「开启做种」开关就在这里生效：关着做种 ⇒ 队列在下完那一刻 pause（停止上传）。
    // 从「做种」切到「不做种」时，队列还会**立刻**把已经下完、还在跑的 torrent 停掉
    // （不能只等下一次进度事件：下完且空闲的种子可能很久都不再有变化事件）。
    queue.setPolicy(toCorePolicy(
      settings.bandwidth,
      stopSeedingAfterDownload: !settings.seedEnabled,
    ));
    await _emitSubscriptions();
  }

  /// 引擎就绪后重新对齐队列（同 infoHash 视为同一任务）。
  Future<void> reconcile() async {
    try {
      await queue.reconcileWithEngine();
    } catch (error) {
      if (error is! PortUnavailableException) rethrow;
    }
  }

  /// 播放/下载前把一条搜索结果补全成「能加磁力」的形态（见 `HostDataPort.ensurePlayable`）。
  ///
  /// 只有 mikan 的 RSS 条目需要这一步：它**没有 magnet、没有 infoHash**，磁力在单集
  /// 详情页 HTML 里（`MikanEpisodeParser`）。补齐后 `SourceItem.bestMagnet` 才是真的。
  ///
  /// 三级降级，任何一级失败都不阻断调用方（下游会给出真实错误）：
  /// 1. 本来就有磁力/infoHash → 原样返回，**一次网络都不打**；
  /// 2. 源客户端支持 detail → 取详情页，拿到磁力就用详情页那份（标题/字幕组/大小也更准）；
  /// 3. 详情页也拿不到（无网络 / 页面结构变了）→ 原样返回。
  Future<core.SourceItem> ensurePlayable(core.SourceItem item) async {
    if (item.bestMagnet != null) return item;
    final core.SourceClient? client = _registry.byId(item.sourceId);
    if (client == null) return item;
    try {
      final core.SourceItem? rich = await client.detail(item);
      if (rich != null && rich.bestMagnet != null) return rich;
    } catch (_) {
      // 详情页抓取失败（离线/超时/结构变化）：不抛出 —— 这只是"顺手补全"，
      // 真正的错误留给下游（queue/playback）去说明，它们的话更具体。
    }
    return item;
  }

  Future<void> dispose() async {
    await queue.dispose();
    _registry.dispose();
    await _subsOut.close();
  }

  /// 这一条所在的**整部番的剧集清单**（见 `HostDataPort.seriesEpisodes`）。
  ///
  /// 只有 mikan 有这个能力：`/Home/Bangumi/<id>` 一页列全每集（带 magnet），
  /// 而它的**搜索/最新 RSS 只有当前发过的那几集**。用户 2026-10-11：
  /// 「不会有前几集，我点第8集就没有765等」—— 只按"这一批结果"归组时列表里
  /// 就只有这一批出现过的集号。
  ///
  /// * bangumiId 从详情页带出来（`MikanEpisodeParser` 的 `extra['bangumiId']`）；
  ///   没有就退回从 `detailUrl` 里认（`/Home/Bangumi/<id>` 形态的条目）。
  /// * **按 id 记在内存里**：番剧页比单集页大得多，同一部番反复点播不该反复拉；
  ///   失败不入缓存（下次播放再试一次），失败的代价只是列表少几集。
  /// * 任何失败都返回空表，绝不抛 —— 播放列表凑不齐不该让播放失败。
  Future<List<core.SourceItem>> seriesEpisodes(core.SourceItem item) async {
    if (item.sourceId != 'mikan') return const <core.SourceItem>[];
    final core.SourceClient? client = _registry.byId(item.sourceId);
    if (client is! core.MikanSource) return const <core.SourceItem>[];
    final String? bangumiId = _bangumiIdOf(item);
    if (bangumiId == null || bangumiId.isEmpty) return const <core.SourceItem>[];
    final String key = '${item.sourceId}:$bangumiId';
    final Future<List<core.SourceItem>>? cached = _seriesCache[key];
    if (cached != null) return cached;
    final Future<List<core.SourceItem>> pending = () async {
      try {
        final core.MikanBangumiDetail detail = await client.bangumi(bangumiId);
        return detail.episodes;
      } catch (_) {
        _seriesCache.remove(key); // 失败不留缓存：下次播放再试
        return const <core.SourceItem>[];
      }
    }();
    _seriesCache[key] = pending;
    return pending;
  }

  /// 整部番的内存缓存（key = `sourceId:bangumiId`）。
  final Map<String, Future<List<core.SourceItem>>> _seriesCache =
      <String, Future<List<core.SourceItem>>>{};

  /// 从条目里认 bangumiId：先看详情页带回来的 `extra`，再从 detailUrl 里认。
  static String? _bangumiIdOf(core.SourceItem item) {
    final Object? fromExtra = item.extra['bangumiId'];
    final String text = fromExtra?.toString().trim() ?? '';
    if (text.isNotEmpty) return text;
    return core.MikanSource.bangumiIdOf(item);
  }

  core.SourceRegistry _buildRegistry(domain.AppSettings settings) {
    final core.ProxyConfig proxy = coreProxyConfig(settings);
    final core.SourceRegistry registry = core.SourceRegistry(
      http: core.IoHttpClientFactory(proxy: proxy),
      cache: core.SourceCache(
        store: store,
        latestTtl: Duration(seconds: settings.sourceCacheTtlSeconds),
        searchTtl: Duration(seconds: settings.sourceCacheTtlSeconds),
        detailTtl: Duration(seconds: settings.sourceDetailCacheTtlSeconds),
      ),
      limiter: core.RateLimiter(
        minInterval: Duration(milliseconds: settings.sourceRequestIntervalMs),
      ),
      proxy: proxy,
    );
    // Q4：sukebei 默认关；打开则多注册一个实例（**独立 id** 才不会撞缓存键）。
    //
    // ⚠️ 第二十五轮（用户：「sukebei 改为仅动漫分区 https://sukebei.nyaa.si/?f=0&c=1_1&q=」）：
    // 分类从「不限」改成 **`1_1` = Art - Anime**（sukebei 自己的分区编号，与 nyaa.si 的
    // `1_0/1_2` 完全不是一回事 —— 见 `core/lib/sources/nyaa.dart` 的注释）。
    // 「最新」与「搜索」两边都带这个分区：只给一边，用户就会在另一半看到全分类
    //（问答里给的那条 URL 是搜索页 `?f=0&c=1_1&q=`，而「最新」也得是同一个区，
    // 否则源列表里的"最新"还是在灌 Art-Doujinshi / Real Life）。
    if (settings.sukebeiEnabled) {
      registry.register(
        core.NyaaSource(
          http: registry.transport,
          cache: registry.cache,
          id: 'sukebei',
          displayName: 'sukebei（成人区 · 动漫分区）',
          baseUrl: 'https://sukebei.nyaa.si',
          category: '1_1',
          searchCategory: '1_1',
        ),
        // 第 14 轮：分区显式声明成 other —— 它既不是动漫正片也不是季度全集，
        // 所以只出现在「聚合」档里（勾「动漫」时把它混进来是错的）。
        partition: core.SourcePartition.other,
      );
    }
    return registry;
  }

  // ── 订阅 ──────────────────────────────────────────────────────────────────

  Future<void> _loadSubscriptions() async {
    _subs = await _subsStore.load();
    await _registerSubscriptionSources();
    await _emitSubscriptions();
  }

  /// 自定义 RSS 订阅要注册成 `rss:<订阅id>` 源（`Subscription.sourceId` 的约定）。
  Future<void> _registerSubscriptionSources() async {
    for (final core.Subscription sub in _subs) {
      if (sub.sourceKind != 'rss') continue;
      final Uri? url = Uri.tryParse(sub.feedUrl.trim());
      if (url == null || !url.hasScheme) continue;
      try {
        _registry.addRss(feedId: sub.id, feedUrl: url, displayName: sub.name);
      } catch (_) {
        // 订阅地址坏掉不该拖垮整张表：该订阅刷新时会给出可行动错误。
      }
    }
    // 挂完 RSS 源 → 源表（可能）变了：新增/编辑订阅之后下拉要立刻多出这一条。
    holder.sourcesChanged();
  }

  Future<void> _emitSubscriptions() async {
    _subsViews = _subs.map(toSubscriptionView).toList(growable: false);
    if (!_subsOut.isClosed) _subsOut.add(_subsViews);
  }

  Stream<List<domain.SubscriptionView>> watchSubscriptions() async* {
    yield _subsViews;
    yield* _subsOut.stream;
  }

  Future<void> upsertSubscription(domain.SubscriptionView view) async {
    final core.Subscription next = toCoreSubscription(view);
    final int index = _subs.indexWhere((core.Subscription s) => s.id == next.id);
    // 已读标记由 core 维护：编辑订阅时不要把历史标记弄丢。
    if (index >= 0) {
      final Map<String, bool> seeded = _subs[index].seededIds;
      next
        ..seededIds = seeded
        ..lastRefreshAt = _subs[index].lastRefreshAt;
    }
    if (index >= 0) {
      _subs[index] = next;
    } else {
      _subs.add(next);
    }
    await _subsStore.save(_subs);
    await _registerSubscriptionSources();
    await _emitSubscriptions();
  }

  Future<void> removeSubscription(String id) async {
    _subs.removeWhere((core.Subscription s) => s.id == id);
    _registry.unregister('rss:$id');
    // 注销了一个源 → 下拉里那一条也要立刻消失（同样是"热加载"的一半）。
    holder.sourcesChanged();
    await _subsStore.save(_subs);
    await _emitSubscriptions();
  }

  core.Subscription? subscriptionById(String id) {
    for (final core.Subscription s in _subs) {
      if (s.id == id) return s;
    }
    return null;
  }

  /// 手动刷新：抓取 → 首次只标记已读 → 命中规则入队 → 候选喂给队列（预取素材）。
  Future<domain.SubsRefreshResult> refreshSubscription(String id) async {
    final core.Subscription? sub = subscriptionById(id);
    if (sub == null) {
      throw const PortUnavailableException('订阅不存在（可能已被删除）', hint: '刷新列表后重试');
    }
    final core.SourceClient? client = _registry.byId(sub.sourceId);
    if (client == null) {
      throw PortUnavailableException(
        '这个订阅对应的源没注册成功：${sub.sourceId}',
        hint:
            '检查订阅类型（rss/nyaa/mikan）与地址是否为合法 RSS；'
            '自定义 RSS 需要 http(s) 地址',
      );
    }
    final core.SourcePage page = await client.latest();
    sub.lastRefreshAt = DateTime.now();

    // 首次抓取：只做已读标记，不倒灌历史剧集（spec §4.3）。
    if (!sub.isSeeded) {
      sub.seed(page.items);
      sub.lastError = null;
      await _subsStore.save(_subs);
      await _emitSubscriptions();
      return domain.SubsRefreshResult(fetched: page.items.length, seeded: true);
    }

    final List<core.SourceItem> matched = sub.matchAll(page.items);
    // 候选（含手动加入的）：预取「下一集」的素材，按订阅规则过滤。
    queue.addCandidates(id, <core.SourceItem>[...matched, ..._manualCandidates]);

    int queued = 0;
    for (final core.SubsRule rule in sub.rules) {
      if (!rule.autoDownload) continue;
      final List<core.SourceItem> hits = rule.rank(
        page.items.where((core.SourceItem item) => rule.matches(item)),
      );
      if (hits.isEmpty) continue;
      final core.SourceItem best = hits.first;
      // 同一条目已有任务 → `enqueue` 会复用；被用户移除过的 → 返回 null 不拉回来。
      final core.QueueJob? job = await queue.enqueue(
        best,
        subscriptionId: id,
        saveSubFolder: rule.saveSubFolder,
      );
      if (job != null) queued++;
    }
    sub.lastError = null;
    await _subsStore.save(_subs);
    await _emitSubscriptions();
    return domain.SubsRefreshResult(
      fetched: page.items.length,
      matched: matched.length,
      queued: queued,
    );
  }

  /// 订阅的**全部条目**（不套规则）—— 第二十七轮「正在追」点开层要的是
  /// 「这个字幕组都出过哪些集」，而不是"按规则会下哪些"。
  ///
  /// 与 [previewMatches] 的区别只有一处：那里过 `sub.matchAll`，这里不过。
  /// 默认规则里的 `excludeRegex`（`合集|全集|BDRip|HEVC.*10bit`…）是给"自动下载"用的，
  /// 拿它过滤剧集列表会把 HEVC 10bit 的集直接藏起来 —— 那是**看不见数据**，不是省事。
  Future<List<domain.SourceItemView>> subscriptionItems(String id) async {
    final core.Subscription? sub = subscriptionById(id);
    final core.SourceClient? client = sub == null ? null : _registry.byId(sub.sourceId);
    if (client == null) {
      throw PortUnavailableException(
        '这个订阅对应的源没注册成功（${sub?.sourceId ?? id}）',
        hint: '检查订阅类型与地址；自定义 RSS 需要 http(s) 地址',
      );
    }
    final core.SourcePage page = await client.latest();
    return page.items.map(toItemView).toList(growable: false);
  }

  /// 命中预览：这条规则会下哪些（不落库、不入队）。
  Future<List<domain.SourceItemView>> previewMatches(domain.SubscriptionView view) async {
    final core.Subscription? sub = subscriptionById(view.id);
    final core.SourceClient? client = sub == null ? null : _registry.byId(sub.sourceId);
    if (client == null) {
      throw PortUnavailableException(
        '这个订阅对应的源没注册成功（${sub?.sourceId ?? view.id}）',
        hint: '检查订阅类型与地址；自定义 RSS 需要 http(s) 地址',
      );
    }
    final core.SourcePage page = await client.latest();
    final List<core.SourceItem> hits = sub == null ? page.items : sub.matchAll(page.items);
    return hits.map(toItemView).toList(growable: false);
  }

  /// 全季入队：把当前命中的条目按规则优先级全部入队（首启/追番常用）。
  Future<int> enqueueSeason(domain.SubscriptionView view) async {
    final core.Subscription? sub = subscriptionById(view.id);
    if (sub == null) {
      throw const PortUnavailableException('订阅不存在', hint: '刷新列表后重试');
    }
    final core.SourceClient? client = _registry.byId(sub.sourceId);
    if (client == null) {
      throw PortUnavailableException('这个订阅对应的源没注册成功（${sub.sourceId}）', hint: '检查订阅类型与地址');
    }
    final core.SourcePage page = await client.latest();
    final List<core.SourceItem> hits = sub.matchAll(page.items);
    queue.addCandidates(sub.id, hits);
    int queued = 0;
    for (final core.SourceItem item in hits) {
      // 用户明确点了「全季入队」= 重新要，墓碑清掉。
      final core.QueueJob? job = await queue.enqueue(item, subscriptionId: sub.id, explicit: true);
      if (job != null) queued++;
    }
    return queued;
  }

  // ── 「仅订阅」候选 ────────────────────────────────────────────────────────

  Future<void> _loadManualCandidates() async {
    final Object? raw = store.get(_manualKey);
    if (raw is! List) return;
    _manualCandidates = raw
        .whereType<Map>()
        .map(
          (Map<dynamic, dynamic> m) => core.SourceItem.fromJson(
            m.map((dynamic k, dynamic v) => MapEntry<String, dynamic>(k.toString(), v)),
          ),
        )
        .toList(growable: true);
  }

  Future<void> addManualCandidate(core.SourceItem item) async {
    if (_manualCandidates.any((core.SourceItem i) => i.id == item.id)) return;
    _manualCandidates.add(item);
    await store.put(_manualKey, _manualCandidates.map((core.SourceItem i) => i.toJson()).toList());
  }

  Future<core.SourceItem?> itemById(String id) async {
    for (final core.SourceItem item in _manualCandidates) {
      if (item.id == id) return item;
    }
    return null;
  }
}

/// 运行期持有者（可空 = 尚未装配，端口会给出可行动错误）。
class HostDataHolder {
  HostDataRuntime? runtime;

  /// 源表版本号：注册表内容一变（设置页重建 / 订阅源增删）就 +1。
  ///
  /// 为什么需要它（用户 2026-10-12 第 10 轮：「sukebe设置打开要重启，不能热加载修复下」）：
  /// 源下拉读的是 `SourcePort.sources`，它每次读注册表都是**活的**；坏在 riverpod 那层 ——
  /// `sourceOptionsProvider` 原来是 `Provider((ref) => port.sources)`，没有任何会变的依赖，
  /// 算过一次就被缓存住。于是「设置里打开 sukebei」时注册表确实重建了（`applySettings`
  /// 真的多注册了一个 `sukebei` 实例），下拉却一辈子是旧的，只有重启进程才看得见新源。
  /// 自定义 RSS 订阅的新增/删除同理。
  ///
  /// 所以给注册表加一个**显式版本号**，UI 跟着它失效重算（见 `providers.dart` 的
  /// `sourceOptionsProvider`）。只要求单调递增，不要求恰好 +1：一次设置变更的路径上
  /// 可能连跳两下（重建注册表 + 重挂 RSS 源），UI 只关心"变没变"。
  final ValueNotifier<int> sourceRevision = ValueNotifier<int>(0);

  /// 声明「源表内容变了」（见 [sourceRevision]）。
  void sourcesChanged() => sourceRevision.value++;

  void attach(HostDataRuntime value) => runtime = value;

  Future<void> detach() async {
    final HostDataRuntime? rt = runtime;
    runtime = null;
    await rt?.dispose();
  }
}

/// `HostDataPort` 的真实实现（装配根注入，UI 只认抽象）。
class CoreHostDataPort implements HostDataPort {
  const CoreHostDataPort(this._holder);

  final HostDataHolder _holder;

  HostDataRuntime _require() {
    final HostDataRuntime? rt = _holder.runtime;
    if (rt == null) throw _noHostData;
    return rt;
  }

  @override
  Future<void> applySettings(domain.AppSettings settings) => _require().applySettings(settings);

  @override
  Future<void> reconcile() => _require().reconcile();

  @override
  Future<domain.SourceItemView> ensurePlayable(domain.SourceItemView item) async {
    final core.SourceItem rich = await _require().ensurePlayable(_toCoreItem(item));
    // 没补到东西就别造一个新的视图对象（`id` 相同但字段可能被覆盖）。
    final bool unchanged = rich.magnet == item.magnet && rich.infoHash == item.infoHash;
    return unchanged ? item : toItemView(rich);
  }

  /// 整部番的剧集清单 → 视图层（播放列表要用它凑齐前几集，见端口注释）。
  @override
  Future<List<domain.SourceItemView>> seriesEpisodes(domain.SourceItemView item) async {
    try {
      final List<core.SourceItem> all = await _require().seriesEpisodes(_toCoreItem(item));
      if (all.isEmpty) return const <domain.SourceItemView>[];
      return <domain.SourceItemView>[for (final core.SourceItem i in all) toItemView(i)];
    } catch (_) {
      // 端口契约：拿不到就空表，绝不让"列表少几集"变成"播不了"。
      return const <domain.SourceItemView>[];
    }
  }
}

const PortUnavailableException _noHostData = PortUnavailableException(
  '宿主数据层未接通：源/订阅/队列适配器还没装配',
  hint: '这是装配问题（main.dart 未注入 HostDataRuntime），请回报开发者',
);

// ─────────────────────────────────────────────────────────────────────────────
// 端口实现
// ─────────────────────────────────────────────────────────────────────────────

/// 源：nyaa 动漫区 / mikan / 自定义 RSS（core `SourceRegistry`）。
class CoreSourcePort implements SourcePort {
  const CoreSourcePort(this._holder);

  final HostDataHolder _holder;

  core.SourceRegistry _require() {
    final HostDataRuntime? rt = _holder.runtime;
    if (rt == null) throw _noHostData;
    return rt.registry;
  }

  @override
  List<domain.SourceOption> get sources => _holder.runtime == null
      ? const <domain.SourceOption>[]
      : <domain.SourceOption>[
          for (final core.SourceClient c in _holder.runtime!.registry.clients)
            domain.SourceOption(
              id: c.id,
              displayName: c.displayName,
              supportsSearch: c.supportsSearch,
              // 第 14 轮：分区是**注册时**声明的（core 的 SourceRegistry.partitionOf），
              // 宿主读它给「聚合搜索 → 动漫 / 全集」分档。
              partition: _partition(c.id),
            ),
        ];

  domain.SourcePartition _partition(String id) =>
      switch (_require().partitionOf(id)) {
        core.SourcePartition.anime => domain.SourcePartition.anime,
        core.SourcePartition.collection => domain.SourcePartition.collection,
        core.SourcePartition.other => domain.SourcePartition.other,
      };

  @override
  Future<domain.SourcePageView> latest(String sourceId, {int page = 1}) async {
    final core.SourceClient client = _client(sourceId);
    if (!client.supportsSearch) {
      throw PortUnavailableException('源「${client.displayName}」不支持浏览最新', hint: '换一个源，或改用搜索关键字');
    }
    return toPageView(await client.latest(page: page));
  }

  @override
  Future<domain.SourcePageView> search(String sourceId, String keyword, {int page = 1}) async {
    final core.SourceClient client = _client(sourceId);
    if (!client.supportsSearch) {
      throw PortUnavailableException(
        '源「${client.displayName}」不支持搜索',
        hint: '这个源只能看最新；换 nyaa / mikan 搜索，或给它加 RSS 搜索地址',
      );
    }
    return toPageView(await client.search(keyword, page: page));
  }

  core.SourceClient _client(String sourceId) {
    final core.SourceRegistry registry = _require();
    final core.SourceClient? client = registry.byId(sourceId);
    if (client == null) {
      throw PortUnavailableException(
        '源「$sourceId」没有注册',
        hint: '到「设置 → 网络」重新选默认源；自定义 RSS 订阅会自动注册为 rss:<订阅id>',
      );
    }
    return client;
  }
}

/// 主页：mikan 追番更新表 + 番剧详情（core `MikanSource.schedule()` / `bangumi()`）。
///
/// 只用 `mikan` 这个注册实例：追番表是 mikan 首页的东西，换别的源没有意义。
class CoreSchedulePort implements SchedulePort {
  const CoreSchedulePort(this._holder);

  final HostDataHolder _holder;

  @override
  bool get isAvailable => _holder.runtime != null;

  @override
  Future<domain.ScheduleView> schedule() async => toScheduleView(await _mikan().schedule());

  @override
  Future<domain.BangumiDetailView> bangumi(String bangumiId) async {
    final String id = bangumiId.trim();
    if (id.isEmpty) {
      throw const PortUnavailableException(
        '这条追番记录没有番剧 id，打不开详情页',
        hint: 'mikan 首页偶尔不给 id；到「搜索」页按番名找这一部',
      );
    }
    final core.MikanBangumiDetail detail = await _mikan().bangumi(id);
    return domain.BangumiDetailView(
      bangumiId: detail.bangumiId,
      title: detail.title,
      groups: detail.groups
          .map(
            (core.MikanSubtitleGroup g) => domain.BangumiGroupView(
              id: g.id,
              name: g.name,
              rssUrl: g.rssUrl?.toString(),
            ),
          )
          .toList(growable: false),
      episodes: detail.episodes.map(toItemView).toList(growable: false),
      skipped: detail.skipped,
    );
  }

  core.MikanSource _mikan() {
    final HostDataRuntime? rt = _holder.runtime;
    if (rt == null) throw _noHostData;
    final core.SourceClient? client = rt.registry.byId('mikan');
    if (client is! core.MikanSource) {
      throw const PortUnavailableException(
        'mikan 源没有注册，主页追番表拿不到数据',
        hint: '这是装配问题（SourceRegistry 未注册 mikan），请回报开发者',
      );
    }
    return client;
  }
}

/// 订阅：core `SubscriptionStore` + 规则匹配（首次只标记已读，不倒灌历史）。
class CoreSubsPort implements SubsPort {
  const CoreSubsPort(this._holder);

  final HostDataHolder _holder;

  HostDataRuntime _require() {
    final HostDataRuntime? rt = _holder.runtime;
    if (rt == null) throw _noHostData;
    return rt;
  }

  @override
  Stream<List<domain.SubscriptionView>> watch() => _require().watchSubscriptions();

  @override
  Future<void> upsert(domain.SubscriptionView subscription) =>
      _require().upsertSubscription(subscription);

  @override
  Future<void> remove(String id) => _require().removeSubscription(id);

  @override
  Future<domain.SubsRefreshResult> refresh(String id) => _require().refreshSubscription(id);

  @override
  Future<List<domain.SourceItemView>> items(domain.SubscriptionView subscription) =>
      _require().subscriptionItems(subscription.id);
}

/// 队列：core `QueueManager`（点播入队 → 预取/暂停/清理才一致）。
class CoreQueuePort implements QueuePort {
  const CoreQueuePort(this._holder);

  final HostDataHolder _holder;

  HostDataRuntime _require() {
    final HostDataRuntime? rt = _holder.runtime;
    if (rt == null) throw _noHostData;
    return rt;
  }

  /// 队列任务流：**先给一份当前快照**，再推后续变化。
  ///
  /// 为什么必须补这个首帧（用户 2026-10-11：「队列页面一直在加载不知道什么东西」）：
  /// `QueueManager.changes` 是 broadcast 且**只在变化时**推送。页面「先订阅、再等数据」
  /// 的消费方式（`StreamProvider` + loading 态）在没有下一次变化之前**永远停在 loading**，
  /// 用户看到的就是那条「正在从队列管理器读取任务…」。订阅类流
  /// （[watchSubscriptions]）一直是「先 yield 快照」的写法，队列这条漏了。
  ///
  /// 用 `async*` 与订阅表保持一致；快照与后续变化之间的缝隙在真实使用里是
  /// 「自己刚入队的任务」这种同一 microtask 内的事件，队列每次变化都会重推整份快照，
  /// 不会丢状态（最坏少一次中间态，不会卡在 loading）。
  @override
  Stream<List<domain.QueueJobView>> watchJobs() async* {
    final HostDataRuntime rt = _require();
    yield _jobViews(rt.queue.jobs);
    yield* rt.queue.changes.map(_jobViews);
  }

  List<domain.QueueJobView> _jobViews(List<core.QueueJob> jobs) =>
      jobs.map(toJobView).toList(growable: false);

  @override
  Future<domain.QueueJobView> enqueuePlayNow(
    domain.SourceItemView item, {
    List<domain.SourceItemView> upNext = const <domain.SourceItemView>[],
    List<domain.SourceItemView> preheat = const <domain.SourceItemView>[],
  }) async {
    final HostDataRuntime rt = _require();
    final core.SourceItem coreItem = await rt.ensurePlayable(_toCoreItem(item));
    final core.PlaybackTicket ticket = await rt.queue.playNow(
      coreItem,
      subscriptionId: item.sourceId,
      // 第三十八轮：预热是"入队 + 启动"（档位在 core 策略里），传整批由 core 挑。
      preheat: preheat.map(_toCoreItem).toList(growable: false),
    );
    // 点播时把同批结果里的后续集喂成候选，预取才有素材。
    if (upNext.isNotEmpty) {
      rt.queue.addCandidates(item.sourceId, <core.SourceItem>[
        coreItem,
        ...upNext.map(_toCoreItem),
      ]);
    }
    return toJobView(ticket.job);
  }

  @override
  Future<domain.QueueJobView> enqueueDownload(domain.SourceItemView item) async {
    // 用户手点「下载」= 明确要（explicit），所以不会返回 null（墓碑会被清掉）。
    // mikan 搜索结果同样先在详情页补磁力，否则入队后永远起不来（见 ensurePlayable）。
    final core.SourceItem rich = await _require().ensurePlayable(_toCoreItem(item));
    // ⚠️ 2026-10-15 第三十轮：补链之后**还是**没有源 ⇒ 不入队，直接说清为什么。
    // 原来会把这种条目也 enqueue 进去 —— 队列里躺着一条永远 0% 的任务，用户看到的
    // 是"点了没反应、队列里也没多东西"（同一个报障的另一半）。宁可失败得响一点。
    if (rich.bestMagnet == null) {
      throw PortUnavailableException(
        '「${item.displayTitle}」没有磁力链、也没有可用的 infoHash',
        hint: '点开这一集的详情页确认资源是否已下架；或在「设置 → 网络」检查代理后重试',
      );
    }
    final core.QueueJob queued = (await _require().queue.enqueue(
      rich,
      subscriptionId: item.sourceId,
      priority: core.QueueManager.playbackPriority + 10,
      explicit: true,
    ))!;
    return toJobView(queued);
  }

  @override
  Future<void> attachToSubsRule(domain.SourceItemView item) async {
    final HostDataRuntime rt = _require();
    final core.SourceItem? known = await rt.itemById(item.id);
    // 订阅过滤要把条目存下来，之后靠它自动入队 —— 没有磁力的条目存了也下不动。
    await rt.addManualCandidate(
      known ?? await rt.ensurePlayable(_toCoreItem(item)),
    );
  }

  @override
  Future<void> pauseJob(String jobId) => _require().queue.pauseJob(jobId);

  @override
  Future<void> resumeJob(String jobId) => _require().queue.resumeJob(jobId);

  @override
  Future<String?> removeJob(String jobId, {bool deleteFiles = false}) =>
      _require().queue.removeJob(jobId, deleteFiles: deleteFiles);

  @override
  Future<String?> removeByEngine(int engineId, {bool deleteFiles = true}) =>
      _require().queue.removeByEngine(engineId, deleteFiles: deleteFiles);

  @override
  Future<void> setPriority(String jobId, int priority) async {
    final HostDataRuntime rt = _require();
    final core.QueueJob? job = rt.queue.byId(jobId);
    if (job == null) {
      throw PortUnavailableException('任务不存在（可能已被删除）', hint: '刷新队列后重试');
    }
    job.priority = priority;
    await rt.queue.pump();
  }

  @override
  Future<void> clearCompleted() => _require().queue.clearCompleted();

  @override
  Future<String?> clearAll({bool deleteFiles = false}) =>
      _require().queue.clearAll(deleteFiles: deleteFiles);

  @override
  Future<void> settleAfterPlayback(int engineId) =>
      _require().queue.settleAfterPlayback(engineId);

  @override
  Future<List<domain.SourceItemView>> previewMatches(domain.SubscriptionView subscription) =>
      _require().previewMatches(subscription);

  @override
  Future<int> enqueueSeason(domain.SubscriptionView subscription) =>
      _require().enqueueSeason(subscription);
}

/// 宿主视图 → core 模型（视图字段与 spec 冻结字段逐字对齐）。
///
/// 顶层函数而不是某个类的静态方法：**队列端口与宿主数据端口都要用**（补磁力那条路
/// 在 `CoreHostDataPort.ensurePlayable` 上，投递那条路在 `CoreQueuePort` 上）。
core.SourceItem _toCoreItem(domain.SourceItemView item) => core.SourceItem(
    id: item.id,
    sourceId: item.sourceId,
    title: item.title,
    detailUrl: item.detailUrl,
    torrentUrl: item.torrentUrl,
    magnet: item.magnet,
    infoHash: item.infoHash,
    sizeBytes: item.sizeBytes,
    seeders: item.seeders,
    leechers: item.leechers,
    downloads: item.downloads,
    publishedAt: item.publishedAt,
    category: item.category,
    group: item.group,
    episodeHints: item.episodeHints,
    extra: Map<String, dynamic>.from(item.extra),
  );
