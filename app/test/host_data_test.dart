/// 宿主数据层适配测试（源/订阅/队列映射与语义）。
///
/// **不联网、不起引擎**：用假 `SourceClient` / 假 `TorrentEnginePort`，
/// 存储用 core 的 `InMemoryKeyValueStore`。
library;

import 'package:dsanima/domain/models.dart' as domain;
import 'package:dsanima/domain/ports.dart';
import 'package:dsanima/state/host_data.dart';
import 'package:dsanima/state/providers.dart';
import 'package:dsanima_core/dsanima_core.dart' as core;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

// ─────────────────────────────────────────────────────────────────────────────
// 测试替身
// ─────────────────────────────────────────────────────────────────────────────

core.SourceItem _item(
  String id,
  String title, {
  int seeders = 5,
  List<String> episodes = const <String>['01'],
}) => core.SourceItem(
  id: id,
  sourceId: 'nyaa',
  title: title,
  magnet: 'magnet:?xt=urn:btih:$id',
  sizeBytes: 734003200,
  seeders: seeders,
  publishedAt: DateTime(2026, 10, 8, 12),
  group: 'G',
  episodeHints: episodes,
  extra: const <String, dynamic>{'resolution': 1080},
);

class FakeSourceClient implements core.SourceClient {
  FakeSourceClient({this.items = const <core.SourceItem>[], this.failure});

  List<core.SourceItem> items;
  Object? failure;
  int calls = 0;

  /// `detail()` 的返回（mikan 搜索结果补磁力就靠它）。
  core.SourceItem? detailResult;

  /// 让 `detail()` 抛错（离线 / 页面结构变了）。
  Object? detailFailure;
  int detailCalls = 0;

  @override
  String get id => 'nyaa';

  @override
  String get displayName => 'nyaa.si 动漫区';

  @override
  bool get supportsSearch => true;

  @override
  Future<core.SourcePage> latest({int page = 1}) async {
    calls++;
    final Object? error = failure;
    if (error != null) throw error;
    return core.SourcePage(
      items: items,
      page: page,
      fetchedAt: DateTime(2026, 10, 8, 12),
      fromCache: false,
    );
  }

  @override
  Future<core.SourcePage> search(String keyword, {int page = 1}) => latest(page: page);

  @override
  Future<core.SourceItem?> detail(core.SourceItem item) async {
    detailCalls++;
    final Object? error = detailFailure;
    if (error != null) throw error;
    return detailResult;
  }
}

/// 假引擎端口（core `TorrentEnginePort`）：不碰网络。
class FakeTorrentEngine implements core.TorrentEnginePort {
  final List<String> addedMagnets = <String>[];

  /// 引擎里当前的 torrent（默认空）。第十九轮：队列移除一个已下完的任务时，
  /// 这份列表必须**原样留着** —— 宿主「已完成」页读的就是它（`finished` 那批）。
  List<core.EngineTorrentRef> torrents = const <core.EngineTorrentRef>[];

  /// 收到的 `remove` 调用（回归钉：已下完的那条不该出现在这里）。
  final List<({int id, bool deleteFiles})> removeCalls = <({int id, bool deleteFiles})>[];

  @override
  Future<core.EngineAddedTorrent> addMagnet(
    String magnet, {
    String? name,
    List<int>? onlyFiles,
    bool startPaused = false,
    String? subFolder,
  }) async {
    addedMagnets.add(magnet);
    return core.EngineAddedTorrent(
      id: addedMagnets.length,
      infoHash: magnet.split(':').last,
      name: name ?? magnet,
      files: const <core.EngineFileInfo>[
        core.EngineFileInfo(index: 0, path: 'a/ep01.mkv', length: 100, isVideo: true),
      ],
    );
  }

  @override
  Future<List<core.EngineTorrentRef>> listTorrents() async => torrents;

  @override
  Future<void> pause(int id) async {}

  @override
  Future<void> resume(int id) async {}

  @override
  Future<void> remove(int id, {bool deleteFiles = false}) async {
    removeCalls.add((id: id, deleteFiles: deleteFiles));
    torrents = torrents
        .where((core.EngineTorrentRef t) => t.id != id)
        .toList(growable: false);
  }

  @override
  Stream<core.EngineProgressTick> progress() => const Stream<core.EngineProgressTick>.empty();

  @override
  Uri streamUrl(int id, int fileIndex) =>
      Uri.parse('http://127.0.0.1:1/torrents/$id/files/$fileIndex/stream?token=t');
}

HostDataRuntime _runtime(FakeSourceClient client, {BandwidthPolicyLike? policy, FakeTorrentEngine? engine}) {
  final domain.AppSettings settings = domain.AppSettings(
    downloadDir: r'F:\Anime',
    bandwidth: (policy ?? BandwidthPolicyLike.defaults()).toDomain(),
  );
  final HostDataHolder holder = HostDataHolder();
  final HostDataRuntime runtime = HostDataRuntime(
    holder: holder,
    store: core.InMemoryKeyValueStore(),
    enginePort: _NoEnginePort(),
    torrentPort: engine ?? FakeTorrentEngine(),
    settings: settings,
    supportDir: null,
  );
  holder.attach(runtime);
  // 用假源替换默认 nyaa（register 同 id 会替换）。
  runtime.registry.register(client);
  return runtime;
}

/// mikan 搜索结果的样子：**没有 magnet、没有 infoHash**，只有详情页地址与 `.torrent` 直链
/// （spec §4.2：RSS 里没有 infoHash/magnet，磁力只在单集详情页 HTML 里）。
core.SourceItem _rssItem(String id, String title) => core.SourceItem(
  id: id,
  sourceId: 'nyaa',
  title: title,
  detailUrl: Uri.parse('https://mikanani.me/Home/Episode/$id'),
  torrentUrl: 'https://mikanani.me/Download/20261008/$id.torrent',
  magnet: null,
  infoHash: null,
  group: 'ASW',
  episodeHints: const <String>['01'],
  extra: const <String, dynamic>{},
);

/// 省流量策略的小包装（避免测试里到处写 domain.BandwidthPolicy）。
class BandwidthPolicyLike {
  const BandwidthPolicyLike({
    this.preheatAhead = 0,
    this.excludePatterns = const <String>[],
    this.maxConcurrent = 1,
  });

  factory BandwidthPolicyLike.defaults() => const BandwidthPolicyLike();

  /// 预热档位（第三十八轮；默认 0 = 关）。
  final int preheatAhead;
  final List<String> excludePatterns;
  final int maxConcurrent;

  domain.BandwidthPolicy toDomain() => domain.BandwidthPolicy(
    preheatAhead: preheatAhead,
    excludePatterns: excludePatterns,
    maxConcurrent: maxConcurrent,
  );
}

class _NoEnginePort implements EnginePort {
  @override
  Future<domain.EngineHealthView> health() async => const domain.EngineHealthView(ok: false);

  @override
  Future<domain.EngineTorrentView> addMagnet(
    String magnet, {
    String? name,
    List<int>? onlyFiles,
    bool startPaused = false,
    String? subFolder,
  }) async => throw const PortUnavailableException('测试替身：不加种');

  @override
  Future<List<domain.EngineTorrentView>> list() async => const <domain.EngineTorrentView>[];

  @override
  Future<void> pause(int id) async {}

  @override
  Future<void> resume(int id) async {}

  @override
  Future<void> remove(int id, {bool deleteFiles = false}) async {}

  @override
  Stream<List<domain.EngineTorrentView>> watch() =>
      const Stream<List<domain.EngineTorrentView>>.empty();

  @override
  Uri? streamUrl(int id, int fileIndex) => null;
}

void main() {
  test('源页映射：core SourceItem/SourcePage → 宿主视图（字段逐项对齐）', () {
    final core.SourcePage page = core.SourcePage(
      items: <core.SourceItem>[_item('abc', '芙莉莲 第 01 话', seeders: 42)],
      page: 2,
      hasNext: true,
      fetchedAt: DateTime(2026, 10, 8, 12),
      fromCache: true,
    );
    final domain.SourcePageView view = toPageView(page);
    expect(view.page, 2);
    expect(view.hasNext, isTrue);
    expect(view.fromCache, isTrue, reason: 'stale 缓存标记必须传下去');
    expect(view.items.single.id, 'abc');
    expect(view.items.single.title, '芙莉莲 第 01 话');
    expect(view.items.single.seeders, 42);
    expect(view.items.single.group, 'G');
    expect(view.items.single.episodeHints, <String>['01']);
    expect(view.items.single.resolution, '1080p', reason: 'core 写 int 1080，视图要显示成 1080p');
    expect(view.items.single.hasTorrentSource, isTrue);
  });

  test('省流量策略映射：preheatAhead / excludePatterns / 并发都传下去', () {
    final core.BandwidthPolicy core1 = toCorePolicy(
      const domain.BandwidthPolicy(
        preheatAhead: 2,
        excludePatterns: <String>['合集'],
        maxConcurrent: 9,
      ).copyWith(stopSeedingAfterPlayback: true),
      stopSeedingAfterDownload: false,
    );
    expect(core1.preheatAhead, 2);
    expect(core1.isExcluded('某番 合集 1080p'), isTrue);
    expect(core1.isExcluded('某番 第01话'), isFalse);
    expect(core1.effectiveMaxConcurrent, 3, reason: '并发被夹到 1–3');
    expect(core1.stopSeedingAfterPlayback, isTrue);
    expect(
      core1.stopSeedingAfterDownload,
      isFalse,
      reason: '「开启做种」时不该由宿主停做种（引擎按 --seed-ratio 走）',
    );
  });

  // 用户 2026-10-12 第十二轮：「修复下载完后，自动上传做种问题，设置关着的做种」。
  // 开关原来是**接在边车 `--seed-ratio` 上的**，而边车的语义是「0 = 不做任何做种干预」
  // （engine/src/state.rs 的 maybe_stop_seeding）⇒ 关掉开关等于永远做种。
  // 现在它接到队列策略上（下完就 pause），下面这条是那个映射的回归钉。
  test('「开启做种」开关真的接到队列策略上（关 ⇒ 下完就停上传；开 ⇒ 宿主不下手）', () async {
    final HostDataRuntime runtime = _runtime(FakeSourceClient());
    await runtime.init();

    expect(
      runtime.queue.policy.stopSeedingAfterDownload,
      isTrue,
      reason: '做种默认关（产品默认「不做任何做种」）⇒ 队列要在下完那一刻 pause',
    );

    await runtime.applySettings(
      const domain.AppSettings(downloadDir: r'F:\Anime', seedEnabled: true),
    );
    expect(
      runtime.queue.policy.stopSeedingAfterDownload,
      isFalse,
      reason: '用户开了做种 ⇒ 宿主不再替他停（交给引擎的做种比规则）',
    );

    await runtime.applySettings(const domain.AppSettings(downloadDir: r'F:\Anime'));
    expect(runtime.queue.policy.stopSeedingAfterDownload, isTrue);

    await runtime.dispose();
  });

  test('订阅刷新：首次只做已读标记不倒灌，第二次才按规则入队', () async {
    final FakeSourceClient client = FakeSourceClient(
      items: <core.SourceItem>[_item('a', '芙莉莲 第 01 话'), _item('b', '芙莉莲 第 02 话')],
    );
    final HostDataRuntime runtime = _runtime(client);
    await runtime.init();

    await runtime.upsertSubscription(
      domain.SubscriptionView(
        id: 'sub1',
        name: '芙莉莲',
        feedUrl: 'https://nyaa.si/?page=rss&c=1_2',
        sourceKind: 'nyaa',
        rules: <domain.SubsRuleView>[domain.SubsRuleView(id: 'r1', name: '默认', autoDownload: true)],
      ),
    );

    final domain.SubsRefreshResult first = await runtime.refreshSubscription('sub1');
    expect(first.seeded, isTrue, reason: '首次抓取必须标记已读');
    expect(first.fetched, 2);
    expect(runtime.queue.jobs, isEmpty, reason: '首次不得倒灌历史剧集');

    final domain.SubsRefreshResult second = await runtime.refreshSubscription('sub1');
    expect(second.seeded, isFalse);
    expect(second.matched, 2);
    expect(second.queued, greaterThanOrEqualTo(1));
    expect(runtime.queue.jobs, isNotEmpty);
    expect(runtime.queue.jobs.first.subscriptionId, 'sub1');

    await runtime.dispose();
  });

  test('命中预览：走真实规则匹配，不入队', () async {
    final FakeSourceClient client = FakeSourceClient(
      items: <core.SourceItem>[_item('a', '芙莉莲 第 01 话'), _item('b', '芙莉莲 合集 01-12')],
    );
    final HostDataRuntime runtime = _runtime(client);
    await runtime.init();
    await runtime.upsertSubscription(
      domain.SubscriptionView(
        id: 'sub1',
        name: '芙莉莲',
        feedUrl: 'https://nyaa.si/?page=rss&c=1_2',
        sourceKind: 'nyaa',
        rules: <domain.SubsRuleView>[
          // 默认 excludeRegex 会排掉「合集」
          domain.SubsRuleView(id: 'r1', name: '默认'),
        ],
      ),
    );

    final List<domain.SourceItemView> hits = await runtime.previewMatches(
      toSubscriptionView(runtime.subscriptionById('sub1')!),
    );
    expect(hits.map((domain.SourceItemView i) => i.id), <String>['a']);
    expect(runtime.queue.jobs, isEmpty, reason: '预览不入队');

    await runtime.dispose();
  });

  test('队列端口：入队/优先级/取消都打到 core QueueManager', () async {
    final HostDataRuntime runtime = _runtime(FakeSourceClient());
    await runtime.init();
    final QueuePort port = runtime.queuePort;

    final domain.QueueJobView job = await port.enqueueDownload(
      toItemView(_item('abc', '芙莉莲 第 01 话')),
    );
    expect(job.item.id, 'abc');
    expect(job.priority, core.QueueManager.playbackPriority + 10);
    // autoPump=true：入队后调度器立刻启动（走到哪一步是异步的，稍等一拍再断言）。
    await Future<void>.delayed(Duration.zero);
    final core.QueueJob started = runtime.queue.byId(job.id)!;
    expect(started.state, core.JobState.downloading);
    expect(started.engineId, isNotNull, reason: '调度器应已把任务交给引擎');
    expect(started.fileIndex, isNotNull);

    await port.setPriority(job.id, 5);
    expect(runtime.queue.byId(job.id)!.priority, 5);

    // 移除 = 真删记录（旧实现只标 cancelled，重启后又被绑回来 → 用户删不掉）
    await port.removeJob(job.id);
    expect(runtime.queue.byId(job.id), isNull);

    await port.clearCompleted();
    await runtime.dispose();
  });

  // 用户 2026-10-12 第十九轮：「队列中移除了不应该把已完成里也移除」。
  //
  // 「已完成」页的数据源就是引擎里 `finished` 的那批种子
  // （`completedGroupsProvider → cachedTorrentsProvider`），所以这条钉在端到端这层：
  // 队列侧「移除（不含文件）」之后，引擎端口**不能**收到删除 —— 否则用户看到的就是
  // 「我在队列里清一下，已完成里的片也没了」，而文件明明还在磁盘上。
  test('队列「移除」已下完的任务：引擎那条记录留着（「已完成」页照旧）', () async {
    final FakeTorrentEngine engine = FakeTorrentEngine();
    final HostDataRuntime runtime = _runtime(FakeSourceClient(), engine: engine);
    await runtime.init();
    final QueuePort port = runtime.queuePort;

    final domain.QueueJobView job = await port.enqueueDownload(
      toItemView(_item('done', '芙莉莲 第 01 话')),
    );
    await Future<void>.delayed(Duration.zero); // autoPump：任务已经进了引擎
    final core.QueueJob started = runtime.queue.byId(job.id)!;
    final int engineId = started.engineId!;
    // 引擎说这个种子下完了（真机就是引擎报 `finished` / 进度 100%）
    engine.torrents = <core.EngineTorrentRef>[
      core.EngineTorrentRef(id: engineId, finished: true),
    ];

    await port.removeJob(job.id);

    expect(runtime.queue.byId(job.id), isNull, reason: '队列记录照旧真删');
    expect(engine.removeCalls, isEmpty,
        reason: '引擎那份留着：它就是「已完成」页的数据源');
    expect(engine.torrents, hasLength(1));
    await runtime.dispose();
  });

  test('队列任务流：订阅时立刻给一份当前快照（否则页面永远停在加载）', () async {
    // 用户 2026-10-11：「队列页面一直在加载不知道什么东西」——
    // core 的 `changes` 是 broadcast 且只在变化时推送，页面「先订阅再等数据」
    // 就会一直停在 loading。修复前这个 `.first` **永远不返回**，所以这里带超时：
    // 卡住会变成一条明确的失败，而不是把整个测试套件挂死。
    final HostDataRuntime runtime = _runtime(FakeSourceClient());
    await runtime.init();
    final domain.QueueJobView job = await runtime.queuePort.enqueueDownload(
      toItemView(_item('snap', '芙莉莲 第 01 话')),
    );

    final List<domain.QueueJobView> first = await runtime.queuePort.watchJobs().first.timeout(
      const Duration(seconds: 2),
    );
    expect(first.map((domain.QueueJobView j) => j.id), contains(job.id), reason: '首帧就该带上盘上已有的任务');

    // 后续变化照旧推（不是只给一次快照就完事）：第二份流跳过首帧，等一次真实变化。
    final Future<List<domain.QueueJobView>> second = runtime.queuePort
        .watchJobs()
        .skip(1)
        .first
        .timeout(const Duration(seconds: 5));
    await runtime.queuePort.enqueueDownload(
      toItemView(_item('snap2', '芙莉莲 第 02 话', episodes: <String>['02'])),
    );
    expect(await second, hasLength(2));
    await runtime.dispose();
  });

  // ── 用户 2026-10-11：「搜索内的全部无法播放 mikan 的」────────────────────────
  //
  // 根因：mikan 的 RSS（`/RSS/Search`）**没有 magnet、也没有 infoHash**（spec §4.2），
  // 磁力只存在于单集详情页 HTML。搜索页把 RSS 条目直接交给队列，`bestMagnet` 是 null，
  // 于是 `QueueManager.playNow` 直接抛「既没有磁力链接也没有 infoHash」——
  // 搜索结果一条都播不了。修法：投递前补一次详情页（`ensurePlayable`）。
  group('ensurePlayable：搜索结果补磁力（mikan 那一类没有 magnet 的条目）', () {
    test('没有磁力 → 用详情页那一份（磁力/标题一起更新）', () async {
      final FakeSourceClient client = FakeSourceClient();
      client.detailResult = _item('rss1', '芙莉莲 第 01 话 [ASW][1080p]');
      final HostDataRuntime runtime = _runtime(client);
      await runtime.init();

      final core.SourceItem rich = await runtime.ensurePlayable(_rssItem('rss1', '芙莉莲 第 01 话'));
      expect(client.detailCalls, 1, reason: '没有磁力就必须去详情页补');
      expect(rich.bestMagnet, 'magnet:?xt=urn:btih:rss1');
      expect(rich.title, '芙莉莲 第 01 话 [ASW][1080p]', reason: '详情页标题更准，应当采用');
      await runtime.dispose();
    });

    test('本来就有磁力 → 一次详情页都不打（离线也能播 nyaa 的结果）', () async {
      final FakeSourceClient client = FakeSourceClient();
      final HostDataRuntime runtime = _runtime(client);
      await runtime.init();

      final core.SourceItem same = await runtime.ensurePlayable(_item('abc', '芙莉莲 第 01 话'));
      expect(client.detailCalls, 0);
      expect(same.bestMagnet, 'magnet:?xt=urn:btih:abc');
      await runtime.dispose();
    });

    test('详情页拿不到（null / 抛错）→ 原样返回，绝不编一个磁力出来', () async {
      final FakeSourceClient client = FakeSourceClient();
      final HostDataRuntime runtime = _runtime(client);
      await runtime.init();

      final core.SourceItem nulled = await runtime.ensurePlayable(_rssItem('rss2', '某番 第 02 话'));
      expect(nulled.bestMagnet, isNull);
      expect(nulled.id, 'rss2');

      client.detailFailure = core.SourceException('mikan 详情页炸了', sourceId: 'nyaa');
      final core.SourceItem failed = await runtime.ensurePlayable(_rssItem('rss3', '某番 第 03 话'));
      expect(failed.bestMagnet, isNull, reason: '抓不到就该让下游报真实错误，不能假装成功');
      expect(failed.id, 'rss3');
      await runtime.dispose();
    });

    test('点播：补出来的磁力真的进了引擎（用户那条路径的回归）', () async {
      final FakeTorrentEngine engine = FakeTorrentEngine();
      final FakeSourceClient client = FakeSourceClient();
      client.detailResult = _item('rss9', '某番 第 09 话 [ASW]');
      final HostDataRuntime runtime = _runtime(client, engine: engine);
      await runtime.init();

      await runtime.queuePort.enqueuePlayNow(toItemView(_rssItem('rss9', '某番 第 09 话')));
      expect(
        engine.addedMagnets,
        <String>['magnet:?xt=urn:btih:rss9'],
        reason: '没有磁力的搜索结果补全后必须真的加进引擎，否则点播永远失败',
      );
      await runtime.dispose();
    });
  });

  test('源端口：未注册的源给可行动错误，而不是空列表', () async {
    final HostDataRuntime runtime = _runtime(FakeSourceClient());
    await runtime.init();
    final SourcePort port = runtime.sourcePort;
    expect(port.sources.map((domain.SourceOption s) => s.id), contains('nyaa'));

    await expectLater(port.search('rss:不存在', 'x'), throwsA(isA<PortUnavailableException>()));
    await runtime.dispose();  });

  test('源端口：分区实例都在下拉里，且第二十四轮删掉的两个「全集」源不再出现', () async {
    final HostDataRuntime runtime = _runtime(FakeSourceClient());
    await runtime.init();
    final List<domain.SourceOption> sources = runtime.sourcePort.sources;
    final List<String> ids = sources.map((domain.SourceOption s) => s.id).toList();

    // 下拉顺序按站分组（与 registry 一致）。第二十四轮用户「ACG.rip bangumi.moe 去除全集源」
    // ⇒ `acgrip-batch` / `bangumimoe-collection` 整个不再注册（合集只剩 dmhy / acgnx 两家）。
    expect(ids, <String>[
      'nyaa',
      'mikan',
      'dmhy',
      'dmhy-batch',
      'acgrip',
      'acgnx',
      'acgnx-batch',
      'bangumimoe',
    ]);
    // 展示名要说清是哪个站的哪个分区 —— 下拉里只显示名字。
    expect(
      <String, String>{
        for (final domain.SourceOption s in sources) s.id: s.displayName,
      },
      containsPair('acgrip', 'ACG.RIP · 动画'),
    );
    expect(
      sources.firstWhere((domain.SourceOption s) => s.id == 'acgnx-batch').displayName,
      'ACGNX · 季度全集',
    );
    expect(
      sources.firstWhere((domain.SourceOption s) => s.id == 'dmhy-batch').displayName,
      '动漫花园 · 季度全集（DMHY）',
    );
    // 分区实例各自独立：id 不同、列表 URL 不同（同 id 会撞缓存键与条目 id）。
    final core.SourceRegistry registry = runtime.registry;
    expect(
      (registry.byId('acgnx')! as core.AcgnxSource).latestUri(1).toString(),
      'https://share.acgnx.se/rss-1.xml',
    );
    expect(
      (registry.byId('acgnx-batch')! as core.AcgnxSource).latestUri(1).toString(),
      'https://share.acgnx.se/rss-2.xml',
    );
    // 第二十四轮：**搜索**也要按分区（不然「全集」档搜出来的是全站）。
    expect(
      (registry.byId('acgnx-batch')! as core.AcgnxSource)
          .searchUri('蜡笔小新', 1)
          .queryParameters['sort_id'],
      core.kAcgnxBatchFeed,
    );
    expect(
      (registry.byId('dmhy-batch')! as core.DmhySource)
          .searchUri('蜡笔小新', 1)
          .queryParameters['sort_id'],
      core.kDmhyBatchSortId,
    );
    // 删掉的那两个实例：连 id 都查不到。
    expect(registry.byId('acgrip-batch'), isNull);
    expect(registry.byId('bangumimoe-collection'), isNull);
    // bangumi.moe：動畫分区 = tag Donga。
    expect(
      (registry.byId('bangumimoe')! as core.BangumiMoeSource).latestBody(1)['tag_id'],
      core.kBangumiMoeAnimeTags,
    );
    // 全都支持搜索（acgnx 走 rss.xml?keyword=、bangumi.moe 走 v2 搜索，实测都有结果）。
    expect(sources.where((domain.SourceOption s) => !s.supportsSearch), isEmpty);
    await runtime.dispose();
  });

  // ── 源表热加载（用户 2026-10-12 第 10 轮：「sukebe设置打开要重启，不能热加载修复下」）──
  //
  // 根因不在注册表（`applySettings` 一直是真重建的），而在 riverpod 那层：
  // `sourceOptionsProvider` 原来是个只算一次就缓存住的 `Provider`，没有任何会变的依赖，
  // 于是"注册表变了"这件事传不到 UI。这里用真 `HostDataRuntime` + 真 provider 钉住：
  // 注册表一变（sukebei 开关 / 自定义订阅增删），下拉必须**当场**跟着变。

  ProviderContainer containerFor(HostDataRuntime runtime) => ProviderContainer(
    overrides: [
      sourcePortProvider.overrideWithValue(runtime.sourcePort),
      sourceRevisionProvider.overrideWithValue(runtime.holder.sourceRevision),
    ],
  );

  test('源表热加载：设置里打开 sukebei，源下拉当场多一条（不许等重启）', () async {
    final HostDataRuntime runtime = _runtime(FakeSourceClient());
    await runtime.init();
    final ProviderContainer container = containerFor(runtime);

    List<String> ids() => container
        .read(sourceOptionsProvider)
        .map((domain.SourceOption s) => s.id)
        .toList(growable: false);

    expect(ids(), isNot(contains('sukebei')), reason: '默认关');
    final int before = runtime.holder.sourceRevision.value;

    // 设置页的真实链路是 SettingsController.replace + EngineLifecyclePort.applySettings
    // → HostDataRuntime.applySettings（边车那一半由 settings_effect_test 覆盖）。
    await runtime.applySettings(
      const domain.AppSettings(downloadDir: r'F:\Anime', sukebeiEnabled: true),
    );

    expect(runtime.holder.sourceRevision.value, greaterThan(before),
        reason: '注册表变了必须发信号，否则 UI 永远看不到');
    expect(ids(), contains('sukebei'));
    expect(
      container
          .read(sourceOptionsProvider)
          .firstWhere((domain.SourceOption s) => s.id == 'sukebei')
          .displayName,
      'sukebei（成人区 · 动漫分区）',
    );

    // ⚠️ 第二十五轮（用户：「sukebei 改为仅动漫分区 https://sukebei.nyaa.si/?f=0&c=1_1&q=」）：
    // 「最新」与「搜索」两条 URL 都必须带 **c=1_1**（Art - Anime）。
    // 只给一边的话，另一半还在灌全分类 —— 这条钉住两边。
    final core.NyaaSource sukebei =
        runtime.registry.byId('sukebei')! as core.NyaaSource;
    expect(sukebei.rssUri().queryParameters['c'], '1_1', reason: '最新（RSS）带分区');
    expect(sukebei.searchHtmlUri('测试', 2).queryParameters['c'], '1_1',
        reason: '搜索（HTML 列表页）也带同一个分区');
    expect(sukebei.rssUri(keyword: '测试').queryParameters['q'], '测试',
        reason: '搜索走 RSS 时关键字照旧');

    // 再关掉 → 立刻消失（不是"下次启动才没有"）。
    await runtime.applySettings(const domain.AppSettings(downloadDir: r'F:\Anime'));
    expect(ids(), isNot(contains('sukebei')));

    container.dispose();
    await runtime.dispose();
  });

  test('源表热加载：新增 / 删除自定义 RSS 订阅，下拉立刻多出 / 少掉那一条', () async {
    final HostDataRuntime runtime = _runtime(FakeSourceClient());
    await runtime.init();
    final ProviderContainer container = containerFor(runtime);

    List<String> ids() => container
        .read(sourceOptionsProvider)
        .map((domain.SourceOption s) => s.id)
        .toList(growable: false);

    expect(ids(), isNot(contains('rss:sub1')));

    await runtime.upsertSubscription(
      domain.SubscriptionView(
        id: 'sub1',
        name: '某站新番',
        feedUrl: 'https://example.com/anime.xml',
        sourceKind: 'rss',
        rules: <domain.SubsRuleView>[domain.SubsRuleView(id: 'r1', name: '默认')],
      ),
    );
    expect(ids(), contains('rss:sub1'), reason: '订阅源注册了就该在下拉里能选');
    expect(
      container
          .read(sourceOptionsProvider)
          .firstWhere((domain.SourceOption s) => s.id == 'rss:sub1')
          .displayName,
      '某站新番',
    );

    await runtime.removeSubscription('sub1');
    expect(ids(), isNot(contains('rss:sub1')));

    container.dispose();
    await runtime.dispose();
  });

  test('未装配数据层时源下拉是空表（不炸、也不假装有源）', () {
    final ProviderContainer container = ProviderContainer();
    expect(container.read(sourceOptionsProvider), isEmpty);
    container.dispose();
  });

  test('预热：档位 0（默认关）时不预热；开档后入队 priority 100', () async {
    // 默认档位 = 0（第三十八轮：用户要求"添加逻辑默认关闭"），省流量列表也放一个命中项
    final HostDataRuntime off = _runtime(
      FakeSourceClient(),
      policy: const BandwidthPolicyLike(excludePatterns: <String>['合集']),
    );
    await off.init();
    off.queue.addCandidates('sub1', <core.SourceItem>[
      _item('ep1', '芙莉莲 第 01 话'),
      _item('ep2', '芙莉莲 第 02 话', episodes: <String>['02']),
    ]);
    off.queue.markPlaying(
      off.registry.byId('nyaa') == null ? null : _item('ep1', '芙莉莲 第 01 话'),
      subscriptionId: 'sub1',
    );
    final List<core.QueueJob> blocked =
        await off.queue.preheat('sub1', afterItemId: 'ep1');
    expect(blocked, isEmpty, reason: '档位 0 必须拦住预热');
    expect(off.queue.jobs, isEmpty);
    await off.dispose();

    // 开档（预热 1 集）
    final HostDataRuntime on = _runtime(
      FakeSourceClient(),
      policy: const BandwidthPolicyLike(preheatAhead: 1),
    );
    await on.init();
    on.queue.addCandidates('sub1', <core.SourceItem>[
      _item('ep1', '芙莉莲 第 01 话'),
      _item('ep2', '芙莉莲 第 02 话', episodes: <String>['02']),
    ]);
    on.queue.markPlaying(_item('ep1', '芙莉莲 第 01 话'), subscriptionId: 'sub1');
    final List<core.QueueJob> warmed =
        await on.queue.preheat('sub1', afterItemId: 'ep1');
    expect(warmed, hasLength(1), reason: '档位 1：下一集入队');
    expect(warmed.single.priority, core.QueueManager.prefetchPriority);
    expect(warmed.single.item.id, 'ep2');
    await on.dispose();
  });

  test('省流量列表命中整部番时不预热（excludePatterns 生效）', () async {
    final HostDataRuntime runtime = _runtime(
      FakeSourceClient(),
      policy: const BandwidthPolicyLike(
        preheatAhead: 2,
        excludePatterns: <String>['芙莉莲'],
      ),
    );
    await runtime.init();
    runtime.queue.addCandidates('sub1', <core.SourceItem>[
      _item('ep1', '芙莉莲 第 01 话'),
      _item('ep2', '芙莉莲 第 02 话', episodes: <String>['02']),
    ]);
    runtime.queue.markPlaying(_item('ep1', '芙莉莲 第 01 话'), subscriptionId: 'sub1');
    final List<core.QueueJob> jobs =
        await runtime.queue.preheat('sub1', afterItemId: 'ep1');
    // 命中省流量列表 → core 直接不入队（档位再高也不预热）
    expect(jobs, isEmpty);
    await runtime.dispose();
  });

  // ───────────────────────────────────────────────────────────────────────────
  // 自动下载（用户 2026-10-10 报的严重问题：自己下几部不知道什么的动漫 + 删不掉）
  // ───────────────────────────────────────────────────────────────────────────

  test('订阅规则默认不开自动下载（旧默认是 true，会自己下番）', () {
    expect(const domain.SubsRuleView(id: 'r1', name: '默认规则').autoDownload, isFalse);
    // 首启向导建的那条「默认规则」也不该开
    expect(domain.AppSettings().defaultSourceId, 'mikan');
  });

  test('升级迁移：盘上历史规则 autoDownload=true 一律关掉并写回', () async {
    // 造一份 v1 写下的订阅（规则 autoDownload=true）。
    final core.KeyValueStore store = core.InMemoryKeyValueStore(<String, Object?>{
      'subscriptions': <dynamic>[
        <String, dynamic>{
          'id': 'sub1',
          'name': '某番',
          'feedUrl': 'https://mikanani.me/RSS/Bangumi?bangumiId=1',
          'sourceKind': 'mikan',
          'rules': <dynamic>[
            <String, dynamic>{'id': 'r1', 'name': '默认规则', 'autoDownload': true},
          ],
        },
      ],
    });
    final HostDataHolder holder = HostDataHolder();
    final HostDataRuntime runtime = HostDataRuntime(
      holder: holder,
      store: store,
      enginePort: _NoEnginePort(),
      torrentPort: FakeTorrentEngine(),
      settings: domain.AppSettings(downloadDir: r'F:\Anime'),
      supportDir: null,
    );
    holder.attach(runtime);
    await runtime.init();

    final List<domain.SubscriptionView> subs = await runtime.watchSubscriptions().first;
    expect(subs.single.rules.single.autoDownload, isFalse, reason: '升级后历史规则必须关掉自动下载');
    expect('${store.get('subscriptions')}', contains('false'), reason: '关掉之后要写回盘，否则下次启动又开回来');
    await runtime.dispose();
  });

  test('自动下载已关的订阅刷新时不会入队任何任务', () async {
    final FakeSourceClient client = FakeSourceClient(
      items: <core.SourceItem>[_item('ep1', '芙莉莲 第 01 话')],
    );
    final HostDataRuntime runtime = _runtime(client);
    await runtime.init();
    await runtime.upsertSubscription(
      domain.SubscriptionView(
        id: 'sub1',
        name: '某番',
        feedUrl: 'https://mikanani.me/RSS/Bangumi?bangumiId=1',
        sourceKind: 'mikan',
        rules: <domain.SubsRuleView>[domain.SubsRuleView(id: 'r1', name: '默认规则')],
      ),
    );
    // 首次刷新只做已读标记，不会入队。
    await runtime.refreshSubscription('sub1');
    expect(runtime.queue.jobs, isEmpty);
    // 第二次刷新：规则没开自动下载 → 仍然一条都不入队。
    await runtime.refreshSubscription('sub1');
    expect(runtime.queue.jobs, isEmpty, reason: 'autoDownload=false 时刷新绝不能自己入队下载');
    await runtime.dispose();
  });

  test('重启恢复：盘上排队的任务不会自动开始下载（严重问题的端到端复现）', () async {
    final String hash = 'a' * 40;
    final core.KeyValueStore store = core.InMemoryKeyValueStore(<String, Object?>{
      // 复刻用户盘上那份坏数据：一个没下完的 `queued` 任务留在队列里。
      'queue.jobs': <dynamic>[
        <String, dynamic>{
          'id': 'job-1',
          'subscriptionId': 'nyaa',
          'item': <String, dynamic>{
            'id': 'nyaa:1',
            'sourceId': 'nyaa',
            'title': '[GJM] 没人要的番 - 01 [1080p]',
            'magnet': 'magnet:?xt=urn:btih:$hash',
            'infoHash': hash,
          },
          'state': 'queued',
          'priority': 10,
          'attempts': 0,
          'createdAt': '2026-10-08T17:32:06.724693Z',
          'updatedAt': '2026-10-08T17:32:06.724693Z',
        },
      ],
    });
    final FakeTorrentEngine engine = FakeTorrentEngine();
    final HostDataHolder holder = HostDataHolder();
    final HostDataRuntime runtime = HostDataRuntime(
      holder: holder,
      store: store,
      enginePort: _NoEnginePort(),
      torrentPort: engine,
      settings: domain.AppSettings(downloadDir: r'F:\Anime'),
      supportDir: null,
    );
    holder.attach(runtime);
    await runtime.init();
    await Future<void>.delayed(Duration.zero);

    expect(engine.addedMagnets, isEmpty, reason: '打开应用不能自己把盘上排队的任务下起来（用户报的严重问题）');
    expect(runtime.queue.jobs.single.state, core.JobState.paused, reason: '恢复出来的排队任务要暂停，等用户点「继续」');
    await runtime.dispose();
  });
}
