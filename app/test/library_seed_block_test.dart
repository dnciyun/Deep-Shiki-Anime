/// 动漫库「种子」块（第四十五轮起，第四十八轮换了引擎）的**页面**测试。
///
/// 状态机在 `library_seed_test.dart` 里验；这里只验用户能看见的东西：
/// * 加载文案（「正在各站搜…」）；
/// * 有结果时：**一段一个字幕组**（抬头写着组名与条数）、**默认全收起**（一进来只有组抬头，
///   点哪一段抬头才画那一段的条目）、表头只在第一张展开的表上画一次、
///   行尾的「已看过 / 在队列 / 已完成」与「别的站也有」标记；
/// * 「展开全部字幕组 / 收起字幕组」是**两颗纯图标**（`unfold_more` / `unfold_less`），
///   只管组名列表的宽窄、不碰每段自己的开合，而且**同时都在**：比首屏宽时收起就是亮的
///   （第四十八轮·补四，三个方向都是用户退回过的）；
/// * 这一排画在结果**下面**（「这些位置也不应该在上面」）；
/// * 每一段展开后的末尾还有一颗「收起这一组」；
/// * 每段展开后先露 12 条（「本组还有 N 条」）、整块先露 4 段；
/// * 右键 / 抬头那颗「这一组都入队」真的把这一段加进队列（跳过已看过的），
///   **收起状态下也能点**；
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
import 'package:dsanima/ui/widgets/neo.dart' show NeoIconButton;
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
  testWidgets('有结果：默认**全收起**（只有一组行抬头，一条条目都不画）', (WidgetTester tester) async {
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
    // ⚠️ 第四十八轮·补：默认收起 —— 一行条目、一条表头都不该出现。
    expect(
      find.textContaining('葬送的芙莉莲 - 0'),
      findsNothing,
      reason: '收起形态：进页面先看组名，点开哪一段才画哪一段',
    );
    expect(find.text('番名'), findsNothing, reason: '一张表都没展开 → 没有表头');
    // 只有 2 段（没超过首屏那 4 个）→ 没有"列表宽窄"可调，两颗图标都不画。
    expect(find.byKey(dsDetailSeedsExpandAllKey), findsNothing);
    expect(find.byKey(dsDetailSeedsCollapseKey), findsNothing);

    // 没锚过番剧页 → 没有「订阅」（那颗要番剧 id）。
    expect(find.text('订阅'), findsNothing);
    expect(find.byKey(dsDetailSeedsSearchPageKey), findsOneWidget);

    // 点「桜都」那一段的抬头 → **只**展开这一段。
    await tester.tap(find.byKey(dsDetailSeedsGroupToggleKey('桜都')));
    await tester.pumpAndSettle();

    expect(find.textContaining('葬送的芙莉莲 - 01'), findsOneWidget);
    expect(find.textContaining('葬送的芙莉莲 - 02'), findsOneWidget);
    expect(
      find.textContaining('葬送的芙莉莲 - 03'),
      findsNothing,
      reason: 'LoliHouse 那一段还收着',
    );
    expect(find.text('番名'), findsOneWidget, reason: '表头只在第一张展开的表上画一次');

    // 再点一次抬头 = 收起来。
    await tester.tap(find.byKey(dsDetailSeedsGroupToggleKey('桜都')));
    await tester.pumpAndSettle();
    expect(find.textContaining('葬送的芙莉莲 - 01'), findsNothing);
  });

  testWidgets('组名列表那一对是**纯图标**：展开 / 收起同时都在，收起不用等展开完', (
    WidgetTester tester,
  ) async {
    // 用户第四十八轮·补四三句话都钉在这一条上：
    //   ① 「去掉展开这些文字，只需要矢量图」—— 那排只有图标，中文只留在悬停提示里；
    //   ② 「多加一个收起按钮」—— 两颗**同时都在**，不是一颗按钮变来变去；
    //   ③ 「只点一次时不能收起」—— 只要比首屏宽，收起那颗就是亮的、点得动。
    // 另外：展开/收起只管**组名列表**（"不是把字幕组也展开了"），一条条目都不许跟着打开；
    // 这一排画在结果**下面**（"这些位置也不应该在上面"）。
    // ⚠️ 同条数时段的次序看"这一段最新那条"（见 `groupSeedItems`），所以 `day` 反着给，
    // 让露出来的 4 段就是 组1 / 组2 / 组3 / 组4，被窗口挡住的**一定**有 组12。
    final _Harness h = _Harness(
      source: _FakeSources(<String, List<SourceItemView>>{
        'mikan:葬送的芙莉莲': <SourceItemView>[
          for (int i = 1; i <= 15; i++) _item(i, group: '组1', day: i),
          for (int i = 2; i <= 12; i++) _item(100 + i, group: '组$i', day: 13 - i),
        ],
      }),
      schedule: _FakeSchedule(const <String, BangumiDetailView>{}),
      store: InMemoryKeyValueStore(),
    );
    await _pump(tester, h);

    // 刚进来：露 4 段、一段都没展开。
    expect(find.text('组1（15 条）'), findsOneWidget);
    expect(find.byKey(dsDetailSeedsGroupKey('组12')), findsNothing, reason: '默认只露 4 段');
    expect(find.textContaining('葬送的芙莉莲 - '), findsNothing, reason: '默认全收起');

    // ① 那排是**图标**：一个文字标签都没有，两句话都只写在悬停提示里。
    expect(find.byKey(dsDetailSeedsExpandAllKey), findsOneWidget);
    expect(find.byKey(dsDetailSeedsCollapseKey), findsOneWidget);
    expect(find.text('展开全部字幕组'), findsNothing, reason: '去掉展开这些文字');
    expect(find.text('收起字幕组'), findsNothing);
    expect(find.textContaining('显示更多字幕组'), findsNothing);
    expect(find.byTooltip('展开全部字幕组（还有 8 个）'), findsOneWidget);

    // ③ 收起在**没展开的时候就在**（只是还没亮 —— 现在就等于首屏那 4 个）。
    expect(
      tester.widget<NeoIconButton>(find.byKey(dsDetailSeedsCollapseKey)).onPressed,
      isNull,
      reason: '已经是首屏那 4 个 → 收起那颗是灰的，但它在',
    );

    // 位置：这一排在结果**下面**（比最后一段抬头还低）。
    expect(
      tester.getTopLeft(find.byKey(dsDetailSeedsExpandAllKey)).dy,
      greaterThan(
        tester.getTopLeft(find.byKey(dsDetailSeedsGroupKey('组4'))).dy,
      ),
      reason: '这一排跟着结果走，画在结果下面 —— 用户退回过"挪到上面"那一版',
    );

    await tester.tap(find.byKey(dsDetailSeedsExpandAllKey));
    await tester.pumpAndSettle();

    // ① 12 个组名全露出来了（展开那颗按下去就没得按了，收起那颗反过来亮了）。
    expect(find.byKey(dsDetailSeedsGroupKey('组12')), findsOneWidget);
    expect(find.text('组12（1 条）'), findsOneWidget);
    expect(
      tester.widget<NeoIconButton>(find.byKey(dsDetailSeedsExpandAllKey)).onPressed,
      isNull,
      reason: '已经全露出来了 → 展开那颗灰掉（提示也改成"已经全露出来了"）',
    );
    expect(find.byTooltip('字幕组已经全露出来了'), findsOneWidget);
    expect(
      tester.widget<NeoIconButton>(find.byKey(dsDetailSeedsCollapseKey)).onPressed,
      isNotNull,
      reason: '比首屏宽 → 收起那颗亮着，随时能收',
    );
    // ② ⚠️ 每一段**仍然收着**：一条条目、一条表头都不该跟着出来。
    expect(
      find.textContaining('葬送的芙莉莲 - '),
      findsNothing,
      reason: '展开的是组名列表，不是把字幕组也展开了',
    );
    expect(find.text('番名'), findsNothing);
    expect(find.textContaining('本组还有'), findsNothing);

    await tester.tap(find.byKey(dsDetailSeedsCollapseKey));
    await tester.pumpAndSettle();

    // ③ 反向：收回 4 个组名，展开那颗又亮回来（提示里带着还剩几个）。
    expect(find.byKey(dsDetailSeedsGroupKey('组12')), findsNothing);
    expect(find.byTooltip('展开全部字幕组（还有 8 个）'), findsOneWidget);
    expect(
      tester.widget<NeoIconButton>(find.byKey(dsDetailSeedsCollapseKey)).onPressed,
      isNull,
      reason: '回到首屏那 4 个 → 收起那颗灰掉',
    );

    // 列表归列表、段归段：点某一段抬头，照旧只展开那一段，也不会把列表撑开。
    await tester.tap(find.byKey(dsDetailSeedsGroupToggleKey('组1')));
    await tester.pumpAndSettle();
    expect(find.textContaining('葬送的芙莉莲 - 15'), findsOneWidget, reason: '这一段打开了');
    expect(find.byKey(dsDetailSeedsGroupKey('组12')), findsNothing, reason: '点段抬头不会把组名列表也撑开');
  });

  testWidgets('列表只露了一部分时，收起那颗也点得动（不用先展开完）', (WidgetTester tester) async {
    // 用户第四十八轮·补四那句「只点一次时不能收起」：把列表放到"露了 12 个、还剩 8 个"这一档
    // （分档展开现在界面上没有入口，所以这一步直接推 provider 的状态），
    // 收起那颗必须是亮的、且真的能收回首屏那 4 个。
    final _Harness h = _Harness(
      source: _FakeSources(<String, List<SourceItemView>>{
        'mikan:葬送的芙莉莲': <SourceItemView>[
          for (int i = 1; i <= 20; i++) _item(i, group: '组$i', day: 21 - i),
        ],
      }),
      schedule: _FakeSchedule(const <String, BangumiDetailView>{}),
      store: InMemoryKeyValueStore(),
    );
    await _pump(tester, h);

    expect(find.byKey(dsDetailSeedsGroupKey('组4')), findsOneWidget);
    expect(find.byKey(dsDetailSeedsGroupKey('组5')), findsNothing);
    expect(find.byTooltip('展开全部字幕组（还有 16 个）'), findsOneWidget);

    final ProviderContainer container = ProviderScope.containerOf(
      tester.element(find.byKey(dsDetailSeedsKey)),
    );
    container.read(librarySeedProvider.notifier).showMoreGroups();
    await tester.pumpAndSettle();

    expect(find.byKey(dsDetailSeedsGroupKey('组12')), findsOneWidget);
    expect(find.byKey(dsDetailSeedsGroupKey('组13')), findsNothing, reason: '只露到第 12 段');
    expect(
      tester.widget<NeoIconButton>(find.byKey(dsDetailSeedsCollapseKey)).onPressed,
      isNotNull,
      reason: '只要比首屏宽，收起那颗就是亮的 —— 不用等展开完',
    );

    await tester.tap(find.byKey(dsDetailSeedsCollapseKey));
    await tester.pumpAndSettle();

    expect(find.byKey(dsDetailSeedsGroupKey('组5')), findsNothing);
    expect(find.byTooltip('展开全部字幕组（还有 16 个）'), findsOneWidget, reason: '收回首屏那 4 个');
    expect(
      tester.widget<NeoIconButton>(find.byKey(dsDetailSeedsCollapseKey)).onPressed,
      isNull,
    );
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
    // 收起态下先点开这一段才看得见行尾那枚标记。
    await tester.tap(find.byKey(dsDetailSeedsGroupToggleKey('桜都')));
    await tester.pumpAndSettle();
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
    expect(find.text('本组还有 3 条'), findsNothing, reason: '收起着的段连"还有几条"都不画');

    await tester.tap(find.byKey(dsDetailSeedsGroupToggleKey('桜都')));
    await tester.pumpAndSettle();

    // 组内按发布 新→旧：藏起来的是**最老的**那三条。
    expect(find.textContaining('葬送的芙莉莲 - 15'), findsOneWidget);
    expect(find.textContaining('葬送的芙莉莲 - 03'), findsNothing, reason: '最老的三条先藏着');
    expect(find.text('本组还有 3 条'), findsOneWidget);

    await tester.tap(find.byKey(dsDetailSeedsGroupMoreKey('桜都')));
    await tester.pumpAndSettle();

    expect(find.textContaining('葬送的芙莉莲 - 01'), findsOneWidget);
    expect(find.text('本组还有 3 条'), findsNothing);

    // 末尾那颗「收起这一组」：这一段 15 行，看完想收起来时不用再滚回抬头去点那颗小箭头。
    expect(find.byKey(dsDetailSeedsGroupCollapseKey('桜都')), findsOneWidget);
    await tester.tap(find.byKey(dsDetailSeedsGroupCollapseKey('桜都')));
    await tester.pumpAndSettle();

    expect(find.textContaining('葬送的芙莉莲 - '), findsNothing, reason: '收起来了');
    expect(find.text('桜都字幕组（15 条）'), findsOneWidget, reason: '只是收起，抬头还在');
    // 只有 1 段 → 没有"列表宽窄"可调（那颗按钮只管组名列表，不管段开合）。
    expect(find.byKey(dsDetailSeedsExpandAllKey), findsNothing);
  });

  testWidgets('字幕组超过 4 段才出现那两颗图标', (WidgetTester tester) async {
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
    expect(find.byKey(dsDetailSeedsExpandAllKey), findsOneWidget);
    expect(find.byKey(dsDetailSeedsCollapseKey), findsOneWidget);
    expect(find.byTooltip('展开全部字幕组（还有 8 个）'), findsOneWidget);

    await tester.tap(find.byKey(dsDetailSeedsExpandAllKey));
    await tester.pumpAndSettle();

    expect(find.byKey(dsDetailSeedsGroupKey('组12')), findsOneWidget, reason: '12 段全露出来了');
    expect(
      tester.widget<NeoIconButton>(find.byKey(dsDetailSeedsExpandAllKey)).onPressed,
      isNull,
      reason: '没得再展开 → 那颗灰掉（但还在，收起那颗还是亮的）',
    );
    expect(
      tester.widget<NeoIconButton>(find.byKey(dsDetailSeedsCollapseKey)).onPressed,
      isNotNull,
    );
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

    // 标记画在行尾，所以先把这一段点开。
    await tester.tap(find.byKey(dsDetailSeedsGroupToggleKey('桜都')));
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
    // 收起状态下抬头那颗也要能用（想整组下的人，正是最不想先翻那 90 行的人）。
    expect(find.textContaining('葬送的芙莉莲 - 0'), findsNothing);

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

    await tester.tap(find.byKey(dsDetailSeedsGroupToggleKey('桜都')));
    await tester.pumpAndSettle();

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
