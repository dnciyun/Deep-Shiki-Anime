/// 动漫库「种子」块（第四十五轮起，第四十八轮换了引擎）的**页面**测试。
///
/// 状态机在 `library_seed_test.dart` 里验；这里只验用户能看见的东西：
/// * 加载文案（「正在各站搜…」）；
/// * 有结果时：**一段一个字幕组**（抬头写着组名与条数）、每段一张表（表头只在最上面画一次）、
///   行尾的「已看过 / 在队列 / 已完成」与「别的站也有」标记；
/// * 每段先露 12 条（「本组还有 N 条」）、整块先露 4 段（「显示更多字幕组」）；
/// * 右键 / 抬头那颗「这一组都入队」真的把这一段加进队列（跳过已看过的）；
/// * 粘 mikan 番剧页之后，每段抬头多出「订阅」；
/// * 没有结果时：说清是"各站都没有"、给「重新搜一遍」；
/// * 抬头那颗「在搜索页打开」在**任何阶段**都在。
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

/// 假源表：`hits['源:词']`。
class _FakeSources extends UnavailableSourcePort {
  _FakeSources(this.hits);

  final Map<String, List<SourceItemView>> hits;
  final List<String> searched = <String>[];

  @override
  List<SourceOption> get sources => const <SourceOption>[
    SourceOption(id: 'mikan', displayName: 'Mikan（蜜柑计划）'),
    SourceOption(id: 'dmhy', displayName: '动漫花园（DMHY）'),
  ];

  @override
  Future<SourcePageView> search(
    String sourceId,
    String keyword, {
    int page = 1,
  }) async {
    searched.add('$sourceId:$keyword');
    return SourcePageView(
      items: hits['$sourceId:$keyword'] ?? const <SourceItemView>[],
      page: page,
      hasNext: false,
      fetchedAt: DateTime(2026, 10, 16, 12),
    );
  }
}

/// 卡住搜索那一枪的假源（用来看加载文案）。
class _GatedSources extends UnavailableSourcePort {
  _GatedSources(this.gate, this.items);

  final Completer<void> gate;
  final List<SourceItemView> items;

  @override
  List<SourceOption> get sources => const <SourceOption>[
    SourceOption(id: 'mikan', displayName: 'Mikan（蜜柑计划）'),
  ];

  @override
  Future<SourcePageView> search(
    String sourceId,
    String keyword, {
    int page = 1,
  }) async {
    await gate.future;
    return SourcePageView(
      items: items,
      page: page,
      hasNext: false,
      fetchedAt: DateTime(2026, 10, 16, 12),
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
  Stream<List<QueueJobView>> watchJobs() =>
      Stream<List<QueueJobView>>.value(jobs);

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
  Stream<List<EngineTorrentView>> watch() =>
      Stream<List<EngineTorrentView>>.value(torrents);
}

// ─────────────────────────────────────────────────────────────────────────────
// 数据
// ─────────────────────────────────────────────────────────────────────────────

String _hash(int n) => n.toRadixString(16).padLeft(40, '0');

SourceItemView _item(
  int n, {
  String group = '桜都字幕组',
  int day = 1,
  String source = 'mikan',
  String? title,
}) => SourceItemView(
  id: '$source:${_hash(n)}',
  sourceId: source,
  title: title ?? '葬送的芙莉莲 - ${n.toString().padLeft(2, '0')} [1080p][$group]',
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

BangumiDetailView _detail(String id, List<SourceItemView> episodes) =>
    BangumiDetailView(
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

/// 一次「造好 -> 等它解析完」的公共流程。
class _Harness {
  _Harness({
    required this.source,
    required this.schedule,
    required this.store,
    this.queue,
    this.engine,
  });

  final SourcePort source;
  final SchedulePort schedule;
  final InMemoryKeyValueStore store;
  final _FakeQueue? queue;
  final _FakeEngine? engine;
  int searchPageTaps = 0;

  Widget widget() => ProviderScope(
    overrides: [
      keyValueStoreProvider.overrideWithValue(store),
      sourcePortProvider.overrideWithValue(source),
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
  testWidgets('有结果：一段一个字幕组（组名 + 条数）/ 每段一张表 / 抬头两颗动作都在', (
    WidgetTester tester,
  ) async {
    final _Harness h = _Harness(
      source: _FakeSources(<String, List<SourceItemView>>{
        'mikan:葬送的芙莉莲': <SourceItemView>[_item(1), _item(2)],
        'dmhy:葬送的芙莉莲': <SourceItemView>[
          _item(3, group: 'LoliHouse', source: 'dmhy'),
        ],
      }),
      schedule: _FakeSchedule(const <String, BangumiDetailView>{}),
      store: InMemoryKeyValueStore(),
    );
    await _pump(tester, h);

    expect(find.byKey(dsDetailSeedsKey), findsOneWidget);
    expect(find.text('种子'), findsOneWidget);
    // 抬头说清来源与用的词（"2 个字幕组 · 共 3 条"）。
    expect(find.textContaining('2 个字幕组'), findsOneWidget);
    expect(find.textContaining('共 3 条'), findsOneWidget);
    expect(find.textContaining('用的是「葬送的芙莉莲」'), findsOneWidget);
    // 两段：条数多的在前；抬头写着组名与条数。
    expect(find.byKey(dsDetailSeedsGroupKey('桜都')), findsOneWidget);
    expect(find.byKey(dsDetailSeedsGroupKey('lolihouse')), findsOneWidget);
    expect(find.text('桜都字幕组（2 条）'), findsOneWidget);
    expect(find.text('LoliHouse（1 条）'), findsOneWidget);
    // 三行都在；没锚过番剧页 → 没有「订阅」（那颗要番剧 id）。
    expect(find.byKey(dsDetailSeedsTableKey), findsOneWidget);
    for (int i = 1; i <= 3; i++) {
      expect(find.textContaining('葬送的芙莉莲 - 0$i'), findsOneWidget);
    }
    expect(find.text('订阅'), findsNothing);
    // 段数没超默认值 → 没有「显示更多字幕组」。
    expect(find.byKey(dsDetailSeedsMoreKey), findsNothing);
    expect(find.byKey(dsDetailSeedsSearchPageKey), findsOneWidget);
  });

  testWidgets('跨站同名合并成一条：行尾带「别的站也有」的小标记', (WidgetTester tester) async {
    final _Harness h = _Harness(
      source: _FakeSources(<String, List<SourceItemView>>{
        'mikan:葬送的芙莉莲': <SourceItemView>[_item(1)],
        'dmhy:葬送的芙莉莲': <SourceItemView>[
          _item(
            9,
            source: 'dmhy',
            title: '葬送的芙莉莲 - 01 [1080p][桜都字幕组]',
          ),
        ],
      }),
      schedule: _FakeSchedule(const <String, BangumiDetailView>{}),
      store: InMemoryKeyValueStore(),
    );
    await _pump(tester, h);

    expect(find.text('桜都字幕组（1 条）'), findsOneWidget, reason: '两个站的一条 → 合成一段一条');
    expect(find.byTooltip('另外 1 个站也有这一条（同名合并成了一条）'), findsOneWidget);
  });

  testWidgets('每段先露 12 条，「本组还有 N 条」再展开', (WidgetTester tester) async {
    final _Harness h = _Harness(
      source: _FakeSources(<String, List<SourceItemView>>{
        'mikan:葬送的芙莉莲': <SourceItemView>[
          for (int i = 1; i <= 15; i++) _item(i, day: i),
        ],
      }),
      schedule: _FakeSchedule(const <String, BangumiDetailView>{}),
      store: InMemoryKeyValueStore(),
    );
    await _pump(tester, h);

    expect(find.text('桜都字幕组（15 条）'), findsOneWidget);
    // 组内按发布 新→旧：藏起来的是**最老的**那三条。
    expect(find.textContaining('葬送的芙莉莲 - 15'), findsOneWidget);
    expect(find.textContaining('葬送的芙莉莲 - 03'), findsNothing, reason: '最老的三条先藏着');
    expect(find.text('本组还有 3 条'), findsOneWidget);

    await tester.tap(find.byKey(dsDetailSeedsGroupMoreKey('桜都')));
    await tester.pumpAndSettle();

    expect(find.textContaining('葬送的芙莉莲 - 01'), findsOneWidget);
    expect(find.text('本组还有 3 条'), findsNothing);
  });

  testWidgets('字幕组超过 4 段才出现「显示更多字幕组」', (WidgetTester tester) async {
    final _Harness h = _Harness(
      source: _FakeSources(<String, List<SourceItemView>>{
        'mikan:葬送的芙莉莲': <SourceItemView>[
          for (int i = 1; i <= 12; i++)
            _item(i, group: '组$i', day: i),
        ],
      }),
      schedule: _FakeSchedule(const <String, BangumiDetailView>{}),
      store: InMemoryKeyValueStore(),
    );
    await _pump(tester, h);

    expect(find.textContaining('12 个字幕组'), findsOneWidget);
    expect(find.byKey(dsDetailSeedsMoreKey), findsOneWidget);
    expect(find.textContaining('还有 8 个'), findsOneWidget);

    await tester.tap(find.byKey(dsDetailSeedsMoreKey));
    await tester.pumpAndSettle();

    expect(find.byKey(dsDetailSeedsMoreKey), findsNothing, reason: '12 段全露出来了');
    expect(find.byKey(dsDetailSeedsGroupKey('组12')), findsOneWidget);
  });

  testWidgets('加载文案：正在各站搜这一部', (WidgetTester tester) async {
    final Completer<void> searchGate = Completer<void>();
    final _Harness h = _Harness(
      source: _GatedSources(searchGate, <SourceItemView>[_item(1)]),
      schedule: _FakeSchedule(const <String, BangumiDetailView>{}),
      store: InMemoryKeyValueStore(),
    );
    tester.view.physicalSize = const Size(1400, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(h.widget());
    await tester.pump(const Duration(milliseconds: 20));

    expect(find.byKey(dsDetailSeedsLoadingKey), findsOneWidget);
    expect(find.textContaining('正在各站搜'), findsWidgets);

    searchGate.complete();
    await tester.pumpAndSettle();
    expect(find.byKey(dsDetailSeedsTableKey), findsOneWidget);
  });

  testWidgets('三枚标记：已看过 / 在队列 / 已完成', (WidgetTester tester) async {
    final SourceItemView one = _item(1);
    final SourceItemView two = _item(2);
    final SourceItemView three = _item(3);
    final _FakeQueue queue = _FakeQueue(<QueueJobView>[
      QueueJobView(
        id: 'job1',
        item: two,
        createdAt: DateTime(2026, 10, 16),
        updatedAt: DateTime(2026, 10, 16),
      ),
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
        'mikan:葬送的芙莉莲': <SourceItemView>[one, two, three],
      }),
      schedule: _FakeSchedule(const <String, BangumiDetailView>{}),
      store: InMemoryKeyValueStore(),
      queue: queue,
      engine: engine,
    );
    await _pump(tester, h);

    // 没锚过 mikan 番剧页时，观看记录的键退回**番名**（见 `_marks`）。
    final ProviderContainer container = ProviderScope.containerOf(
      tester.element(find.byKey(dsDetailSeedsKey)),
    );
    await container.read(watchedMarksProvider.notifier).mark(<String>[
      subscriptionItemWatchKey(
        bangumiId: '葬送的芙莉莲',
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

  testWidgets('抬头那颗「这一组都入队」：把这一段加进队列，跳过已看过的', (
    WidgetTester tester,
  ) async {
    final SourceItemView one = _item(1);
    final SourceItemView two = _item(2);
    final SourceItemView other = _item(3, group: 'LoliHouse');
    final _FakeQueue queue = _FakeQueue(const <QueueJobView>[]);
    final _Harness h = _Harness(
      source: _FakeSources(<String, List<SourceItemView>>{
        'mikan:葬送的芙莉莲': <SourceItemView>[one, two, other],
      }),
      schedule: _FakeSchedule(const <String, BangumiDetailView>{}),
      store: InMemoryKeyValueStore(),
      queue: queue,
    );
    await _pump(tester, h);

    final ProviderContainer container = ProviderScope.containerOf(
      tester.element(find.byKey(dsDetailSeedsKey)),
    );
    await container.read(watchedMarksProvider.notifier).mark(<String>[
      subscriptionItemWatchKey(
        bangumiId: '葬送的芙莉莲',
        title: '葬送的芙莉莲',
        group: '桜都字幕组',
        item: one,
      ),
    ]);
    await tester.pumpAndSettle();

    // 两段各有一颗「这一组都入队」；点第一段（桜都：01 已看过、02 没看过）。
    await tester.tap(find.text('这一组都入队').first);
    await tester.pumpAndSettle();

    expect(
      queue.enqueued.map((SourceItemView i) => i.id),
      <String>[two.id],
      reason: '只入队这一段里没看过的那一条（LoliHouse 那条不在这一段）',
    );
  });

  testWidgets('右键菜单里那一项写着这一组有几条', (WidgetTester tester) async {
    final _FakeQueue queue = _FakeQueue(const <QueueJobView>[]);
    final _Harness h = _Harness(
      source: _FakeSources(<String, List<SourceItemView>>{
        'mikan:葬送的芙莉莲': <SourceItemView>[
          _item(1),
          _item(2),
          _item(3, group: 'LoliHouse'),
        ],
      }),
      schedule: _FakeSchedule(const <String, BangumiDetailView>{}),
      store: InMemoryKeyValueStore(),
      queue: queue,
    );
    await _pump(tester, h);

    await tester.tap(
      find.textContaining('葬送的芙莉莲 - 01'),
      buttons: kSecondaryButton,
    );
    await tester.pumpAndSettle();

    expect(find.text('这一组都入队（2 条）'), findsOneWidget);
    await tester.tap(find.text('这一组都入队（2 条）'));
    await tester.pumpAndSettle();
    expect(queue.enqueued, hasLength(2));
  });

  testWidgets('粘 mikan 番剧页：它的剧集并进来，每段抬头多出「订阅」', (
    WidgetTester tester,
  ) async {
    final _Harness h = _Harness(
      source: _FakeSources(<String, List<SourceItemView>>{
        'mikan:葬送的芙莉莲': <SourceItemView>[_item(1)],
      }),
      schedule: _FakeSchedule(<String, BangumiDetailView>{
        '3141': _detail('3141', <SourceItemView>[
          _item(2),
          _item(3, group: 'LoliHouse'),
        ]),
      }),
      store: InMemoryKeyValueStore(),
    );
    await _pump(tester, h);
    expect(find.text('订阅'), findsNothing, reason: '还没有番剧 id 之前画不出组订阅');

    await tester.tap(find.text('改搜索词 / 粘链接'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(dsDetailSeedsRawFieldKey), '3141');
    await tester.tap(find.byKey(dsDetailSeedsApplyRawKey));
    await tester.pumpAndSettle();

    expect(find.text('桜都字幕组（2 条）'), findsOneWidget, reason: '搜索那一条 + 番剧页那一条');
    expect(find.text('LoliHouse（1 条）'), findsOneWidget);
    expect(find.text('订阅'), findsNWidgets(2), reason: '每个组旁边一颗');
  });

  testWidgets('各站都没搜到：说清是"空"、给「重新搜一遍」与手动出口', (
    WidgetTester tester,
  ) async {
    final _Harness h = _Harness(
      source: _FakeSources(const <String, List<SourceItemView>>{}),
      schedule: _FakeSchedule(const <String, BangumiDetailView>{}),
      store: InMemoryKeyValueStore(),
    );
    await _pump(tester, h);

    expect(find.byKey(dsDetailSeedsFailedKey), findsOneWidget);
    expect(find.textContaining('各站都没搜到「葬送的芙莉莲」'), findsOneWidget);
    expect(find.byKey(dsDetailSeedsRetryKey), findsOneWidget);
    // 阶梯有哪几级就试哪几级 × 两个源（这一部是"中文名 → 原名"两级）。
    expect((h.source as _FakeSources).searched, hasLength(2 * 2));
  });

  testWidgets('「在搜索页打开」在任何阶段都点得到', (WidgetTester tester) async {
    final _Harness h = _Harness(
      source: _FakeSources(const <String, List<SourceItemView>>{}),
      schedule: _FakeSchedule(const <String, BangumiDetailView>{}),
      store: InMemoryKeyValueStore(),
    );
    await _pump(tester, h);
    await tester.tap(find.byKey(dsDetailSeedsSearchPageKey));
    await tester.pumpAndSettle();
    expect(h.searchPageTaps, 1);
  });
}
