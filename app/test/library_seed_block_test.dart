/// 动漫库「种子」块（第四十五轮起，第四十八轮换了引擎）的**页面**测试。
///
/// 状态机在 `library_seed_test.dart` 里验；这里只验用户能看见的东西：
/// * 加载文案（「正在各站搜…」）；
/// * 有结果时：**一段一个字幕组**（抬头写着组名与条数）、**默认全收起**（一进来只有组抬头，
///   点哪一段抬头才画那一段的条目）、表头只在第一张展开的表上画一次、
///   行尾的「已看过 / 在队列 / 已完成」与「别的站也有」标记；
/// * 「展开一些 / 收起字幕组」是**两颗纯图标**（`unfold_more` / `unfold_less`），
///   只管组名列表的宽窄、不碰每段自己的开合，而且**同时都在**：比首屏宽时收起就是亮的
///   （第四十八轮·补四，三个方向都是用户退回过的）；
/// * 展开那颗**一次只多露一档**（8 个）—— 第四十八轮·补五「展开一些加回来」，不是一次全露；
/// * 这一排画在结果**下面**（「这些位置也不应该在上面」）；
/// * **分页条只给「合集」一页、画在组名列表上面**（补七「在字幕组上面加入分页，把合集分进去」
///   + 补八「只给合集最分页，其他的不要」）：页上只有 本作 / 合集，切页 = 换一组段；合集从
///   本作里切出去；第三季 / 更早的版本这些别的版本回到结果下面那行折区，不进分页条；
/// * 补八还钉了一条：`[V2]`（修正版发布标签）不是第五季（用户「命运石之门没有第五季」）；
/// * **语言过滤那颗按钮**（补九「点一次只显示简体，再点一次只显示繁体，再点一次恢复」）：
///   `语言：全部 / 简体 / 繁体` 三档循环，段条数与副标题跟着变；裁空时有一句解释；
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
  Future<QueueJobView> enqueueDownload(SourceItemView item, {List<int>? onlyFiles}) async {
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
  DateTime? publishedAt,
}) => SourceItemView(
  id: '$source:${_hash(n)}',
  sourceId: source,
  title: title ?? '葬送的芙莉莲 - ${n.toString().padLeft(2, '0')} [1080p][$group]',
  group: group,
  magnet: 'magnet:?xt=urn:btih:${_hash(n)}',
  infoHash: _hash(n),
  sizeBytes: 400 * 1024 * 1024,
  publishedAt: publishedAt ?? DateTime(2026, 10, day),
  episodeHints: <String>[n.toString().padLeft(2, '0')],
);

BangumiSubject _subject({
  int id = 400602,
  String? nameCn = '葬送的芙莉莲',
  String? name = 'Sousou no Frieren',
  List<String> aliases = const <String>[],
  String? platform,
  String? date,
  int? eps,
}) => BangumiSubject(
  id: id,
  name: name,
  nameCn: nameCn,
  platform: platform,
  date: date,
  eps: eps,
  infobox: aliases.isEmpty
      ? const <BangumiInfoboxItem>[]
      : <BangumiInfoboxItem>[BangumiInfoboxItem(key: '别名', values: aliases)],
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
    this.subject,
  });

  final SourcePort source;
  final SchedulePort schedule;
  final InMemoryKeyValueStore store;
  final _FakeQueue? queue;
  final _FakeEngine? engine;

  /// 不给就用默认那部（「葬送的芙莉莲」，没有 platform/放送日 ⇒ 不参与版本判定）。
  final BangumiSubject? subject;
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
            subject: subject ?? _subject(),
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
    expect(find.byTooltip('展开剩下的 8 个字幕组'), findsOneWidget);

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

    // ① 12 个组名全露出来了（12 段 = 首屏 4 + 一档 8，这一下正好是最后一档；展开那颗随后就没得按了，收起那颗反过来亮了）。
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
    expect(find.byTooltip('展开剩下的 8 个字幕组'), findsOneWidget);
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
    // 用户第四十八轮·补四那句「只点一次时不能收起」：**界面上点一次展开**（4 → 12，还剩 8 个没露）
    // 就把列表放到"露了 12 个"这一档，收起那颗必须是亮的、且真的能收回首屏那 4 个。
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
    expect(find.byTooltip('展开更多字幕组（一次 8 个，还有 16 个）'), findsOneWidget);

    await tester.tap(find.byKey(dsDetailSeedsExpandAllKey));
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
    expect(
      find.byTooltip('展开更多字幕组（一次 8 个，还有 16 个）'),
      findsOneWidget,
      reason: '收回首屏那 4 个',
    );
    expect(
      tester.widget<NeoIconButton>(find.byKey(dsDetailSeedsCollapseKey)).onPressed,
      isNull,
    );
  });

  testWidgets('展开那颗**一次只多露一档**（第四十八轮·补五「展开一些加回来」）', (
    WidgetTester tester,
  ) async {
    // 20 段：首屏 4 段 → 点一次 12 段（还剩 8）→ 再点一次才全露。用户退回的是"一次全铺开"，
    // 所以要钉住"点一次不等于全露"：第 13 段还在窗外、展开那颗还亮着。
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

    // 第一档：4 → 12（= kSeedVisibleGroups + kSeedGroupsStep）。
    await tester.tap(find.byKey(dsDetailSeedsExpandAllKey));
    await tester.pumpAndSettle();

    expect(find.byKey(dsDetailSeedsGroupKey('组12')), findsOneWidget);
    expect(
      find.byKey(dsDetailSeedsGroupKey('组13')),
      findsNothing,
      reason: '点一次只多露 8 个 —— 不是一次全铺开',
    );
    expect(
      tester.widget<NeoIconButton>(find.byKey(dsDetailSeedsExpandAllKey)).onPressed,
      isNotNull,
      reason: '还有 8 段没露 → 展开那颗还亮着',
    );
    expect(find.byTooltip('展开剩下的 8 个字幕组'), findsOneWidget);
    // 露的只是**组名**：一条条目都不许跟着出来。
    expect(find.textContaining('葬送的芙莉莲 - '), findsNothing);

    // 第二档：12 → 20（剩下的全露），展开那颗这才灰掉。
    await tester.tap(find.byKey(dsDetailSeedsExpandAllKey));
    await tester.pumpAndSettle();

    expect(find.byKey(dsDetailSeedsGroupKey('组20')), findsOneWidget);
    expect(
      tester.widget<NeoIconButton>(find.byKey(dsDetailSeedsExpandAllKey)).onPressed,
      isNull,
      reason: '全露出来了 → 展开那颗灰掉',
    );
    expect(find.byTooltip('字幕组已经全露出来了'), findsOneWidget);
    expect(find.textContaining('葬送的芙莉莲 - '), findsNothing);

    // 收起：一次回到首屏那 4 个（展开那颗又亮回来）。
    await tester.tap(find.byKey(dsDetailSeedsCollapseKey));
    await tester.pumpAndSettle();

    expect(find.byKey(dsDetailSeedsGroupKey('组5')), findsNothing);
    expect(find.byTooltip('展开更多字幕组（一次 8 个，还有 16 个）'), findsOneWidget);
  });

  testWidgets('分页只给合集一页；别的版本回到下面那行折区（真标题：无职转生）', (
    WidgetTester tester,
  ) async {
    // 第四十八轮·补七 + 补八：
    // * 补七用户「在字幕组上面加入分页，把合集分进去」——分页条画在组名列表**上面**；
    // * 补八用户「只给合集最分页，其他的不要」——分页条上只剩 本作 / 合集 两页，
    //   第三季 / 更早的版本**不做页**，回到结果下面那行「其他版本（N 条）」折区；
    // * **合集**（整季一次发的批量种）从本作里切出去：本作的条数 / 「这一组都入队」
    //   不会再被几条全集顶长；判成别的版本的条目**一条都不丢**，折区里点开就能下。
    final _Harness h = _Harness(
      subject: _subject(
        id: 444557,
        nameCn: '无职转生 第二季 ～到了异世界就拿出真本事～',
        name: '無職転生Ⅱ ～異世界行ったら本気だす～',
        aliases: <String>['无职转生'],
        platform: 'TV',
        date: '2024-04-07',
        eps: 12,
      ),
      source: _FakeSources(<String, List<SourceItemView>>{
        'mikan:无职转生 第二季 ～到了异世界就拿出真本事～': <SourceItemView>[
          _item(
            1,
            group: '桜都字幕组',
            title: '无职转生 第二季 ～到了异世界就拿出真本事～ - 01 [1080p]',
            publishedAt: DateTime.utc(2024, 4, 10),
          ),
          _item(
            2,
            group: '桜都字幕组',
            title: '无职转生 第二季 ～到了异世界就拿出真本事～ - 02 [1080p]',
            publishedAt: DateTime.utc(2024, 4, 17),
          ),
          _item(
            3,
            group: 'LoliHouse',
            title: '无职转生 第二季 ～到了异世界就拿出真本事～ - 01 [1080p]',
            publishedAt: DateTime.utc(2024, 4, 11),
          ),
          _item(
            4,
            group: '绿茶字幕组',
            title: '[绿茶字幕组] 无职转生 第三季 ～到了异世界就拿出真本事～ - 14',
            publishedAt: DateTime.utc(2026, 7, 10),
          ),
          _item(
            5,
            group: '绿茶字幕组',
            title: '無職転生Ⅲ ～異世界行ったら本気だす～ / 无职转生 第三季 - 01',
            publishedAt: DateTime.utc(2026, 7, 20),
          ),
          _item(
            6,
            group: '桜都字幕组',
            title: '无职转生 ～到了异世界就拿出真本事～ - 05',
            publishedAt: DateTime.utc(2021, 2, 8),
          ),
          // 本作的**合集**：整季一次发（`[01-12]` 区间 + 合集）。
          _item(
            7,
            group: '桜都字幕组',
            title: '无职转生 第二季 ～到了异世界就拿出真本事～ [01-12 合集][1080p]',
            publishedAt: DateTime.utc(2024, 6, 20),
          ),
        ],
      }),
      schedule: _FakeSchedule(const <String, BangumiDetailView>{}),
      store: InMemoryKeyValueStore(),
    );
    await _pump(tester, h);

    // ① 分页条只有 本作 / 合集 两页，画在**组名列表上面**。
    expect(find.byKey(dsDetailSeedsCategoryKey('本作')), findsOneWidget);
    expect(find.byKey(dsDetailSeedsCategoryKey('合集')), findsOneWidget);
    expect(
      find.byKey(dsDetailSeedsCategoryKey('第三季')),
      findsNothing,
      reason: '补八：「只给合集最分页，其他的不要」',
    );
    expect(find.byKey(dsDetailSeedsCategoryKey('更早的版本')), findsNothing);
    expect(
      tester.getTopLeft(find.byKey(dsDetailSeedsCategoryKey('本作'))).dy,
      lessThan(tester.getTopLeft(find.byKey(dsDetailSeedsGroupKey('桜都'))).dy),
      reason: '分页条画在组名列表上面（用户「在字幕组上面加入分页」）',
    );

    // ② 默认第一页 = 本作：只有 S2 的两家组，且**不含合集那条**。
    expect(find.text('桜都字幕组（2 条）'), findsOneWidget);
    expect(find.text('LoliHouse（1 条）'), findsOneWidget);
    expect(find.text('绿茶字幕组（2 条）'), findsNothing, reason: '第三季不在这一页');
    expect(find.textContaining('2 个字幕组'), findsOneWidget);
    expect(find.textContaining('共 3 条'), findsOneWidget, reason: '本作 3 条 = 单集 2 + LoliHouse 1');
    expect(find.textContaining('合集 1'), findsOneWidget, reason: '分页条上合集那页的条数');

    // ③ 别的版本：默认折在结果下面那一行（不在分页条上，也不占第一屏）。
    expect(
      find.text('其他版本（3 条）：第三季 2 · 更早的版本 1'),
      findsOneWidget,
      reason: '补八：别的版本不做页，收在结果下面那行折区里',
    );
    expect(find.byKey(dsDetailSeedsOtherBlockKey('第三季')), findsNothing, reason: '默认收起');
    expect(
      tester.getTopLeft(find.byKey(dsDetailSeedsOtherKey)).dy,
      greaterThan(tester.getTopLeft(find.byKey(dsDetailSeedsGroupKey('桜都'))).dy),
      reason: '折区在结果下面',
    );

    // ④ 切到「合集」页：整套种子的那一组在这里，本作那些单集不再画。
    await tester.tap(find.byKey(dsDetailSeedsCategoryKey('合集')));
    await tester.pumpAndSettle();
    expect(find.text('桜都字幕组（1 条）'), findsOneWidget);
    expect(find.text('LoliHouse（1 条）'), findsNothing, reason: '切页了，本作那些组不画');
    expect(find.textContaining('合集 · 1 个字幕组'), findsOneWidget);
    // 合集页里的段也能展开（真的能下，不是摆设）。
    await tester.tap(find.byKey(dsDetailSeedsOtherGroupToggleKey('合集', '桜都')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(dsDetailSeedsOtherGroupCollapseKey('合集', '桜都')),
      findsOneWidget,
      reason: '展开后末尾有「本组还有 N 条 / 收起这一组」',
    );

    // ⑤ 折区展开：按版本分小节，第三季 / 更早的版本各自按字幕组分段、能展开。
    await tester.tap(find.byKey(dsDetailSeedsOtherToggleKey));
    await tester.pumpAndSettle();
    expect(find.byKey(dsDetailSeedsOtherBlockKey('第三季')), findsOneWidget);
    expect(find.byKey(dsDetailSeedsOtherBlockKey('更早的版本')), findsOneWidget);
    await tester.tap(find.byKey(dsDetailSeedsOtherGroupToggleKey('第三季', '绿茶')));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('无职转生 第三季 ～到了异世界就拿出真本事～ - 14'),
      findsOneWidget,
    );
    expect(
      find.byKey(dsDetailSeedsOtherGroupCollapseKey('第三季', '绿茶')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(dsDetailSeedsOtherGroupToggleKey('更早的版本', '桜都')));
    await tester.pumpAndSettle();
    expect(find.textContaining('无职转生 ～到了异世界就拿出真本事～ - 05'), findsOneWidget);

    // ⑥ 切回本作：原样（段窗口 / 条数都没被别的页改动）。
    await tester.tap(find.byKey(dsDetailSeedsCategoryKey('本作')));
    await tester.pumpAndSettle();
    expect(find.text('桜都字幕组（2 条）'), findsOneWidget);
    expect(find.textContaining('2 个字幕组'), findsOneWidget);
    // 那一排工具按钮在每一页都在（它不属于某一页）。
    expect(find.text('改搜索词 / 粘链接'), findsOneWidget);
  });

  testWidgets('命运石之门：`[V2]` 那几条算本作，没有「第五季」（补八用户报的）', (
    WidgetTester tester,
  ) async {
    // 补八用户原话：「为什么会有第五季，命运石之门没有第五季」。
    // 真标题（`build/round48c/sg_titles.txt`）里 6 条带 `[V2]` 的修正版标签，
    // 旧规则把 V 读成罗马数字 ⇒ 一整页「第五季」；修完它们都留在本作。
    final _Harness h = _Harness(
      subject: _subject(
        id: 10380,
        nameCn: '命运石之门',
        name: 'STEINS;GATE',
        platform: 'TV',
        date: '2011-04-06',
        eps: 25,
      ),
      source: _FakeSources(<String, List<SourceItemView>>{
        'mikan:命运石之门': <SourceItemView>[
          _item(
            1,
            group: 'TSDM字幕组',
            title: '【命运石之门Steins;Gate】【23】【TSDM字幕组】【GB简体】【480P】'
                '【PC&PSP兼容MP4】【V2】【修正ED】',
            publishedAt: DateTime.utc(2011, 9, 8),
          ),
          _item(
            2,
            group: 'KTKJ',
            title: '[KTKJ][Steins;Gate_命运石之门][02V2][BIG5][576RMVB&720MKV&Tips]',
            publishedAt: DateTime.utc(2011, 4, 19),
          ),
          _item(
            3,
            group: '幻樱字幕组',
            title: '[幻樱字幕组][命运石之门][01][BIG5][BDRip]',
            publishedAt: DateTime.utc(2011, 4, 10),
          ),
          // S;G 0 的 BD 合集：真事上的"另一版"，该进折区（不丢）。
          _item(
            4,
            group: 'Moozzi2',
            title: '[Moozzi2] 命运石之门第二季 Steins;Gate 0 1-24 '
                '(BD 1920x1080 x.264-10Bit Flac)',
            publishedAt: DateTime.utc(2019, 1, 23),
          ),
        ],
      }),
      schedule: _FakeSchedule(const <String, BangumiDetailView>{}),
      store: InMemoryKeyValueStore(),
    );
    await _pump(tester, h);

    // `[V2]` 那几条留在本作（修前它们会让页面上出现「第五季」）。
    expect(find.text('TSDM字幕组（1 条）'), findsOneWidget);
    expect(find.text('KTKJ（1 条）'), findsOneWidget);
    expect(find.text('幻樱字幕组（1 条）'), findsOneWidget);
    expect(find.textContaining('3 个字幕组'), findsOneWidget);
    expect(
      find.textContaining('第五季'),
      findsNothing,
      reason: '`[V2]` 是"修正版第 2 版"的发布标签，不是第五季',
    );
    // 只有 S;G 0 那条在折区里，版本名是「第二季」。
    expect(find.textContaining('其他版本（1 条）'), findsOneWidget);
    expect(find.textContaining('第二季 1'), findsOneWidget);
  });

  testWidgets('语言：全部 → 简体 → 繁体 → 全部（点一次切一档，结果跟着变）', (
    WidgetTester tester,
  ) async {
    // 第四十八轮·补九，用户原话「加入按钮，点一次只显示简体，再点一次只显示繁体，
    // 再点一次恢复」：按钮画在结果下面那排（跟"改搜索词"同一排），每点一下切一档；
    // 过滤只裁显示的行 —— 段条数、副标题、别的版本全都跟着走。
    final _Harness h = _Harness(
      source: _FakeSources(<String, List<SourceItemView>>{
        'mikan:葬送的芙莉莲': <SourceItemView>[
          _item(
            1,
            title: '葬送的芙莉莲 - 01 [1080p][简体内嵌]',
            publishedAt: DateTime.utc(2026, 10, 1),
          ),
          _item(
            2,
            title: '葬送的芙莉莲 - 02 [1080p][繁体内嵌]',
            publishedAt: DateTime.utc(2026, 10, 2),
          ),
          _item(
            3,
            title: '葬送的芙莉莲 - 03 [1080p][简繁内封]',
            publishedAt: DateTime.utc(2026, 10, 3),
          ),
          _item(
            4,
            group: 'LoliHouse',
            title: '葬送的芙莉莲 - 01 [1080p][繁体内嵌]',
            publishedAt: DateTime.utc(2026, 10, 4),
          ),
          _item(
            5,
            group: 'LoliHouse',
            title: '葬送的芙莉莲 - 04 [1080p]',
            publishedAt: DateTime.utc(2026, 10, 5),
          ),
        ],
      }),
      schedule: _FakeSchedule(const <String, BangumiDetailView>{}),
      store: InMemoryKeyValueStore(),
    );
    await _pump(tester, h);

    // ① 默认「全部」：两家组、5 条都画。
    expect(find.text('语言：全部'), findsOneWidget);
    expect(find.text('桜都字幕组（3 条）'), findsOneWidget);
    expect(find.text('LoliHouse（2 条）'), findsOneWidget);
    expect(find.textContaining('2 个字幕组'), findsOneWidget);
    expect(find.textContaining('共 5 条'), findsOneWidget);

    // ② 点一下 = 只看简体：桜都只剩简体内嵌 + 简繁内封；LoliHouse 那两条都不是简体 → 整段不见。
    await tester.tap(find.byKey(dsDetailSeedsLanguageKey));
    await tester.pumpAndSettle();
    expect(find.text('语言：简体'), findsOneWidget);
    expect(find.text('桜都字幕组（2 条）'), findsOneWidget);
    expect(find.text('LoliHouse（2 条）'), findsNothing);
    expect(find.textContaining('1 个字幕组'), findsOneWidget);
    expect(find.textContaining('共 2 条'), findsOneWidget);
    await tester.tap(find.byKey(dsDetailSeedsGroupToggleKey('桜都')));
    await tester.pumpAndSettle();
    expect(find.textContaining('葬送的芙莉莲 - 01 [1080p][简体内嵌]'), findsOneWidget);
    expect(find.textContaining('葬送的芙莉莲 - 03 [1080p][简繁内封]'), findsOneWidget);
    expect(find.textContaining('葬送的芙莉莲 - 02'), findsNothing, reason: '繁体那条被裁掉');

    // ③ 再点一下 = 只看繁体：桜都只剩繁体 + 简繁；LoliHouse 那条繁体回来。
    await tester.tap(find.byKey(dsDetailSeedsLanguageKey));
    await tester.pumpAndSettle();
    expect(find.text('语言：繁体'), findsOneWidget);
    expect(find.text('桜都字幕组（2 条）'), findsOneWidget);
    expect(find.text('LoliHouse（1 条）'), findsOneWidget);
    expect(find.textContaining('2 个字幕组'), findsOneWidget);
    expect(find.textContaining('共 3 条'), findsOneWidget);

    // ④ 再点一下 = 恢复全部：条数 / 段全回来（过滤不是删数据）。
    await tester.tap(find.byKey(dsDetailSeedsLanguageKey));
    await tester.pumpAndSettle();
    expect(find.text('语言：全部'), findsOneWidget);
    expect(find.text('桜都字幕组（3 条）'), findsOneWidget);
    expect(find.text('LoliHouse（2 条）'), findsOneWidget);
    expect(find.textContaining('共 5 条'), findsOneWidget);
  });

  testWidgets('语言过滤把这一页裁空时：说清"为什么空、去哪儿恢复"', (
    WidgetTester tester,
  ) async {
    // 只有繁体行的池子：点一下（简体）会一条不剩 —— 不给一句解释，用户会以为搜坏了。
    final _Harness h = _Harness(
      source: _FakeSources(<String, List<SourceItemView>>{
        'mikan:葬送的芙莉莲': <SourceItemView>[
          _item(
            1,
            title: '葬送的芙莉莲 - 01 [1080p][繁体内嵌]',
            publishedAt: DateTime.utc(2026, 10, 1),
          ),
          _item(
            2,
            group: 'LoliHouse',
            title: '葬送的芙莉莲 - 02 [1080p][繁体内嵌]',
            publishedAt: DateTime.utc(2026, 10, 2),
          ),
        ],
      }),
      schedule: _FakeSchedule(const <String, BangumiDetailView>{}),
      store: InMemoryKeyValueStore(),
    );
    await _pump(tester, h);
    expect(find.text('桜都字幕组（1 条）'), findsOneWidget);

    await tester.tap(find.byKey(dsDetailSeedsLanguageKey));
    await tester.pumpAndSettle();
    expect(find.text('语言：简体'), findsOneWidget);
    expect(find.byKey(dsDetailSeedsLanguageEmptyKey), findsOneWidget);
    expect(find.textContaining('没有标「简体」字幕的种子'), findsOneWidget);
    expect(find.text('桜都字幕组（1 条）'), findsNothing);
    expect(find.textContaining('0 个字幕组'), findsOneWidget);

    // 再点一下（繁体）：行回来、提示消失。
    await tester.tap(find.byKey(dsDetailSeedsLanguageKey));
    await tester.pumpAndSettle();
    expect(find.byKey(dsDetailSeedsLanguageEmptyKey), findsNothing);
    expect(find.text('桜都字幕组（1 条）'), findsOneWidget);
    expect(find.text('LoliHouse（1 条）'), findsOneWidget);
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
    expect(find.byTooltip('展开剩下的 8 个字幕组'), findsOneWidget);

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
