/// 动漫库「种子」块（第四十五轮）的**页面**测试。
///
/// 状态机在 `library_seed_test.dart` 里验；这里只验用户能看见的东西：
/// * 两段式加载文案（「正在 mikan 找这一部…」→「正在取字幕组与剧集…」）；
/// * 有结果时：字幕组那一排（每个组一颗「订阅」）、每集一行、行尾的
///   「已看过 / 在队列 / 已完成」标记、「显示更多」；
/// * 右键那一项「这一组都入队（N 集）」真的把这一组的集加进队列（跳过已看过的）；
/// * 没有结果时：三种空分开写、给「用其他源再搜一次」这颗手动出口；
/// * 抬头那颗「在搜索页打开」在**任何阶段**都在（它是旧按钮的降级形态）。
library;

import 'dart:async';

import 'package:dsanima/domain/bangumi.dart';
import 'package:dsanima/domain/following_subscription.dart';
import 'package:dsanima/domain/models.dart';
import 'package:dsanima/domain/ports.dart';
import 'package:dsanima/domain/unavailable.dart';
import 'package:dsanima/state/providers.dart';
import 'package:dsanima/theme/app_theme.dart';
import 'package:dsanima/ui/widgets/library_seed_block.dart';
import 'package:dsanima_core/sources/kv.dart' show InMemoryKeyValueStore;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

// ─────────────────────────────────────────────────────────────────────────────
// 替身
// ─────────────────────────────────────────────────────────────────────────────

class _FakeSources extends UnavailableSourcePort {
  _FakeSources(this.hits);

  final Map<String, List<SourceItemView>> hits;
  final List<String> searched = <String>[];

  @override
  List<SourceOption> get sources => const <SourceOption>[
    SourceOption(id: 'mikan', displayName: 'Mikan（蜜柑计划）'),
  ];

  @override
  Future<SourcePageView> search(String sourceId, String keyword, {int page = 1}) async {
    searched.add('$sourceId:$keyword');
    return SourcePageView(
      items: hits[keyword] ?? const <SourceItemView>[],
      page: page,
      hasNext: false,
      fetchedAt: DateTime(2026, 10, 16, 12),
    );
  }
}

class _FakeHostData extends UnavailableHostDataPort {
  _FakeHostData(this.byItem);

  final Map<String, ({String id, String title})> byItem;

  @override
  Future<SourceItemView> ensurePlayable(SourceItemView item) async {
    final ({String id, String title})? hit = byItem[item.id];
    if (hit == null) return item;
    return SourceItemView(
      id: item.id,
      sourceId: item.sourceId,
      title: item.title,
      detailUrl: item.detailUrl,
      torrentUrl: item.torrentUrl,
      magnet: item.magnet,
      infoHash: item.infoHash,
      sizeBytes: item.sizeBytes,
      publishedAt: item.publishedAt,
      group: item.group,
      episodeHints: item.episodeHints,
      extra: <String, Object?>{
        ...item.extra,
        'bangumiId': hit.id,
        'bangumiTitle': hit.title,
      },
    );
  }
}

class _FakeSchedule extends UnavailableSchedulePort {
  _FakeSchedule(this.pages);

  final Map<String, BangumiDetailView> pages;

  @override
  Future<BangumiDetailView> bangumi(String bangumiId) async => pages[bangumiId]!;
}

/// 假队列：一个**能正常工作**的流（覆盖占位实现那个"立即出错的流"）。
class _FakeQueue extends UnavailableQueuePort {
  _FakeQueue(this.jobs);

  final List<QueueJobView> jobs;
  final List<SourceItemView> enqueued = <SourceItemView>[];

  @override
  Stream<List<QueueJobView>> watchJobs() => Stream<List<QueueJobView>>.value(jobs);

  @override
  Future<QueueJobView> enqueueDownload(SourceItemView item) async {
    enqueued.add(item);
    return QueueJobView(
      id: 'job${enqueued.length}',
      item: item,
      createdAt: DateTime(2026, 10, 16),
      updatedAt: DateTime(2026, 10, 16),
    );
  }

  @override
  Future<void> attachToSubsRule(SourceItemView item) async {}
}

/// 假引擎：一个下完的 torrent（用来验「已完成」标记）。
class _FakeEngine extends UnavailableEnginePort {
  _FakeEngine(this.torrents);

  final List<EngineTorrentView> torrents;

  @override
  Stream<List<EngineTorrentView>> watch() => Stream<List<EngineTorrentView>>.value(torrents);
}

// ─────────────────────────────────────────────────────────────────────────────
// 数据
// ─────────────────────────────────────────────────────────────────────────────

String _hash(int n) => n.toRadixString(16).padLeft(40, '0');

SourceItemView _item(int n, {String group = '桜都字幕组', int day = 1}) => SourceItemView(
  id: 'mikan:${_hash(n)}',
  sourceId: 'mikan',
  title: '葬送的芙莉莲 - ${n.toString().padLeft(2, '0')} [1080p][$group]',
  group: group,
  magnet: 'magnet:?xt=urn:btih:${_hash(n)}',
  infoHash: _hash(n),
  sizeBytes: 400 * 1024 * 1024,
  publishedAt: DateTime(2026, 10, day),
  episodeHints: <String>[n.toString().padLeft(2, '0')],
);

BangumiSubject _subject() => const BangumiSubject(
  id: 400602,
  name: 'Sousou no Frieren',
  nameCn: '葬送的芙莉莲',
);

BangumiDetailView _detail(String id, List<SourceItemView> episodes) => BangumiDetailView(
  bangumiId: id,
  title: '葬送的芙莉莲',
  groups: <BangumiGroupView>[
    const BangumiGroupView(
      id: '1',
      name: '桜都字幕组',
      rssUrl: 'https://mikanani.me/RSS/Bangumi?bangumiId=3141&subgroupid=1',
    ),
    const BangumiGroupView(
      id: '2',
      name: 'LoliHouse',
      rssUrl: 'https://mikanani.me/RSS/Bangumi?bangumiId=3141&subgroupid=2',
    ),
  ],
  episodes: episodes,
);

/// 一次「造好 -> 等它解析完 -> 可选地做完某件事」的公共流程。
class _Harness {
  _Harness({
    required this.source,
    required this.host,
    required this.schedule,
    required this.store,
    this.queue,
    this.engine,
  });

  final SourcePort source;
  final _FakeHostData host;
  final SchedulePort schedule;
  final InMemoryKeyValueStore store;
  final _FakeQueue? queue;
  final _FakeEngine? engine;
  int searchPageTaps = 0;

  Widget widget() => ProviderScope(
    overrides: [
      keyValueStoreProvider.overrideWithValue(store),
      sourcePortProvider.overrideWithValue(source),
      hostDataPortProvider.overrideWithValue(host),
      schedulePortProvider.overrideWithValue(schedule),
      if (queue != null) queuePortProvider.overrideWithValue(queue!),
      if (engine != null) enginePortProvider.overrideWithValue(engine!),
    ],
    child: MaterialApp(
      theme: buildDsanimaTheme(),
      home: Scaffold(
        body: SingleChildScrollView(
          child: LibrarySeedBlock(
            subject: _subject(),
            onOpenSearchPage: () => searchPageTaps++,
          ),
        ),
      ),
    ),
  );
}

Future<void> _pump(WidgetTester tester, _Harness h) async {
  tester.view.physicalSize = const Size(1400, 1400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(h.widget());
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('有结果：字幕组（带订阅）/ 每集一行 / 抬头两颗动作都在', (WidgetTester tester) async {
    final _Harness h = _Harness(
      source: _FakeSources(<String, List<SourceItemView>>{
        '葬送的芙莉莲': <SourceItemView>[_item(1)],
      }),
      host: _FakeHostData(<String, ({String id, String title})>{
        'mikan:${_hash(1)}': (id: '3141', title: '葬送的芙莉莲'),
      }),
      schedule: _FakeSchedule(<String, BangumiDetailView>{
        '3141': _detail('3141', <SourceItemView>[_item(1), _item(2), _item(3)]),
      }),
      store: InMemoryKeyValueStore(),
    );
    await _pump(tester, h);

    expect(find.byKey(dsDetailSeedsKey), findsOneWidget);
    expect(find.text('种子'), findsOneWidget);
    // 抬头说清来源与用的词。
    expect(find.textContaining('mikan 番剧页 · 2 个字幕组'), findsOneWidget);
    expect(find.textContaining('共 3 集'), findsOneWidget);
    expect(find.textContaining('用的是「葬送的芙莉莲」'), findsOneWidget);
    // 字幕组那一排：两个组、每个组旁边一颗「订阅」。
    expect(find.byKey(dsDetailSeedsGroupsKey), findsOneWidget);
    expect(find.text('桜都字幕组'), findsWidgets);
    expect(find.text('LoliHouse'), findsWidgets);
    expect(find.text('订阅'), findsNWidgets(2));
    // 结果表：三集都在，勾选列也画了（嵌进页面时不自己滚）。
    expect(find.byKey(dsDetailSeedsTableKey), findsOneWidget);
    for (int i = 1; i <= 3; i++) {
      expect(find.textContaining('葬送的芙莉莲 - 0$i'), findsOneWidget);
    }
    // 抬头那颗「在搜索页打开」= 旧按钮的降级形态。
    expect(find.byKey(dsDetailSeedsSearchPageKey), findsOneWidget);
  });

  testWidgets('两段式加载文案：先"正在 mikan 找这一部"，取番剧页时换第二段', (WidgetTester tester) async {
    // 两段各卡一枪才看得清（只 pump 一次的话微任务会把两步一口气跑完）：
    // ① 卡住 mikan 搜索 → 第一段；② 放进结果后卡住番剧页 → 第二段。
    final Completer<void> searchGate = Completer<void>();
    final Completer<BangumiDetailView> pageGate = Completer<BangumiDetailView>();
    final _Harness h = _Harness(
      source: _GatedSources(searchGate, <SourceItemView>[_item(1)]),
      host: _FakeHostData(<String, ({String id, String title})>{
        'mikan:${_hash(1)}': (id: '3141', title: '葬送的芙莉莲'),
      }),
      schedule: _GatedSchedule(pageGate),
      store: InMemoryKeyValueStore(),
    );
    tester.view.physicalSize = const Size(1400, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(h.widget());
    await tester.pump(const Duration(milliseconds: 20));
    expect(find.textContaining('正在 mikan 找这一部（第 1 步'), findsOneWidget);

    searchGate.complete();
    await tester.pump(const Duration(milliseconds: 20));
    await tester.pump(const Duration(milliseconds: 20));
    expect(find.textContaining('正在取字幕组与剧集（第 2 步'), findsOneWidget);

    pageGate.complete(_detail('3141', <SourceItemView>[_item(1)]));
    await tester.pumpAndSettle();
    expect(find.textContaining('正在取字幕组与剧集'), findsNothing);
    expect(find.byKey(dsDetailSeedsTableKey), findsOneWidget);
  });

  testWidgets('三枚标记：已看过 / 在队列 / 已完成', (WidgetTester tester) async {
    final SourceItemView one = _item(1);
    final SourceItemView two = _item(2);
    final SourceItemView three = _item(3);
    final _FakeQueue queue = _FakeQueue(<QueueJobView>[
      QueueJobView(id: 'job1', item: two, createdAt: DateTime(2026, 10, 16), updatedAt: DateTime(2026, 10, 16)),
    ]);
    final _FakeEngine engine = _FakeEngine(<EngineTorrentView>[
      EngineTorrentView(
        id: 1,
        name: 'third',
        infoHash: three.infoHash!,
        finished: true,
        progress: 1,
      ),
    ]);
    final _Harness h = _Harness(
      source: _FakeSources(<String, List<SourceItemView>>{
        '葬送的芙莉莲': <SourceItemView>[_item(1)],
      }),
      host: _FakeHostData(<String, ({String id, String title})>{
        'mikan:${_hash(1)}': (id: '3141', title: '葬送的芙莉莲'),
      }),
      schedule: _FakeSchedule(<String, BangumiDetailView>{
        '3141': _detail('3141', <SourceItemView>[one, two, three]),
      }),
      store: InMemoryKeyValueStore(),
      queue: queue,
      engine: engine,
    );
    await _pump(tester, h);

    // 已看过：按"番剧 id + 番名 + 组名 + 集"那套键打勾（与播放记录同一口径）。
    final ProviderContainer container = ProviderScope.containerOf(
      tester.element(find.byKey(dsDetailSeedsKey)),
    );
    await container.read(watchedMarksProvider.notifier).mark(<String>[
      subscriptionItemWatchKey(
        bangumiId: '3141',
        title: '葬送的芙莉莲',
        group: '桜都字幕组',
        item: one,
      ),
    ]);
    await tester.pumpAndSettle();

    expect(find.byTooltip('已看过'), findsOneWidget);
    expect(find.byTooltip('已下载'), findsNothing); // 队列里的是"下载中"这一档
    expect(find.byTooltip('已完成'), findsOneWidget);
  });

  testWidgets('右键「这一组都入队（N 集）」：把这一组的集加进队列，跳过已看过的', (WidgetTester tester) async {
    final SourceItemView one = _item(1);
    final SourceItemView two = _item(2);
    final SourceItemView other = _item(3, group: 'LoliHouse');
    final _FakeQueue queue = _FakeQueue(const <QueueJobView>[]);
    final _Harness h = _Harness(
      source: _FakeSources(<String, List<SourceItemView>>{
        '葬送的芙莉莲': <SourceItemView>[_item(1)],
      }),
      host: _FakeHostData(<String, ({String id, String title})>{
        'mikan:${_hash(1)}': (id: '3141', title: '葬送的芙莉莲'),
      }),
      schedule: _FakeSchedule(<String, BangumiDetailView>{
        '3141': _detail('3141', <SourceItemView>[one, two, other]),
      }),
      store: InMemoryKeyValueStore(),
      queue: queue,
    );
    await _pump(tester, h);

    final ProviderContainer container = ProviderScope.containerOf(
      tester.element(find.byKey(dsDetailSeedsKey)),
    );
    await container.read(watchedMarksProvider.notifier).mark(<String>[
      subscriptionItemWatchKey(
        bangumiId: '3141',
        title: '葬送的芙莉莲',
        group: '桜都字幕组',
        item: one,
      ),
    ]);
    await tester.pumpAndSettle();

    // 右键第一行 → 菜单里那一项写着这一组有几集（3 集里 2 集是桜都）。
    await tester.tap(find.textContaining('葬送的芙莉莲 - 01'), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    expect(find.text('这一组都入队（2 集）'), findsOneWidget);

    await tester.tap(find.text('这一组都入队（2 集）'));
    await tester.pumpAndSettle();

    // 只入队没看过的那一集（01 已看过）。
    expect(queue.enqueued.map((SourceItemView i) => i.id), <String>[two.id]);
  });

  testWidgets('mikan 没找到：三种空分开写 + 「用其他源再搜一次」是手动出口', (WidgetTester tester) async {
    final _Harness h = _Harness(
      source: _FakeSources(const <String, List<SourceItemView>>{}),
      host: _FakeHostData(const <String, ({String id, String title})>{}),
      schedule: _FakeSchedule(const <String, BangumiDetailView>{}),
      store: InMemoryKeyValueStore(),
    );
    await _pump(tester, h);

    expect(find.byKey(dsDetailSeedsFailedKey), findsOneWidget);
    expect(find.textContaining('mikan 上没找到「'), findsOneWidget);
    expect(find.byKey(dsDetailSeedsOtherSourcesKey), findsOneWidget);
    expect(find.byKey(dsDetailSeedsRetryKey), findsOneWidget);
    // 手动出口：点了才去打其他源（不会自己打）。
    expect((h.source as _FakeSources).searched.every((String q) => q.startsWith('mikan:')), isTrue);
    await tester.tap(find.byKey(dsDetailSeedsOtherSourcesKey));
    await tester.pumpAndSettle();
    expect(find.textContaining('其他源也没有这一部'), findsOneWidget);
  });

  testWidgets('「在搜索页打开」在任何阶段都点得到（旧按钮的降级形态）', (WidgetTester tester) async {
    final _Harness h = _Harness(
      source: _FakeSources(const <String, List<SourceItemView>>{}),
      host: _FakeHostData(const <String, ({String id, String title})>{}),
      schedule: _FakeSchedule(const <String, BangumiDetailView>{}),
      store: InMemoryKeyValueStore(),
    );
    await _pump(tester, h);
    await tester.tap(find.byKey(dsDetailSeedsSearchPageKey));
    await tester.pumpAndSettle();
    expect(h.searchPageTaps, 1);
  });
}

/// 卡住 mikan 搜索那一枪的假源（用来看"第一段"加载文案）。
class _GatedSources extends UnavailableSourcePort {
  _GatedSources(this.gate, this.items);

  final Completer<void> gate;
  final List<SourceItemView> items;

  @override
  List<SourceOption> get sources => const <SourceOption>[
    SourceOption(id: 'mikan', displayName: 'Mikan（蜜柑计划）'),
  ];

  @override
  Future<SourcePageView> search(String sourceId, String keyword, {int page = 1}) async {
    await gate.future;
    return SourcePageView(
      items: items,
      page: page,
      hasNext: false,
      fetchedAt: DateTime(2026, 10, 16, 12),
    );
  }
}

/// 卡住番剧页那一枪的假端口（用来看"第二段"加载文案）。
class _GatedSchedule extends UnavailableSchedulePort {
  _GatedSchedule(this.gate);

  final Completer<BangumiDetailView> gate;

  @override
  Future<BangumiDetailView> bangumi(String bangumiId) => gate.future;
}
