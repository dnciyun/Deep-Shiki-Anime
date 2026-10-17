/// 「正在追」点开层（第二十七轮）：只列订阅的字幕组、逐集打勾、下载全部跳过已看过。
///
/// 用户这一轮的原话（节选）：
/// > 「订阅可在正在追内标记已看过，已看过的在旁边打上勾。……点开后，仅显示订阅的字幕组，
/// >  并在上面可直接下载全部或单集下载，下载全部跳过已看过的。」
///
/// **第四十九轮**（用户「优化下订阅，详细页订阅的也带有种子」）：这一页页头下面多了一块
/// 「种子」（和动漫库详细页同一个 `LibrarySeedBlock`）。这里补两条用例钉住：
/// * 种子块真的挂在这一页上、用**追番记录的名字**搜、结果按字幕组分段，而且在订阅区**上面**；
/// * 「已看过」与订阅用同一套键（种子块拿到这一部的 mikan 番剧 id）—— 订阅里打的勾，
///   种子块里也显示成「已看过」。
///
/// 用假端口注入（订阅 / 队列 / 番剧详情 / 源），不联网、不起引擎。
library;

import 'package:dsanima/domain/following_store.dart';
import 'package:dsanima/domain/following_subscription.dart';
import 'package:dsanima/domain/models.dart';
import 'package:dsanima/domain/ports.dart';
import 'package:dsanima/domain/unavailable.dart';
import 'package:dsanima/domain/watch_history.dart';
import 'package:dsanima/state/providers.dart';
import 'package:dsanima/theme/app_theme.dart';
import 'package:dsanima/ui/following_detail.dart';
import 'package:dsanima/ui/widgets/library_seed_block.dart';
import 'package:dsanima_core/sources/kv.dart' show InMemoryKeyValueStore;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

final FollowingEntry _entry = FollowingEntry(
  id: 'mikan:3887',
  title: '葬送的芙莉莲',
  mikanBangumiId: '3887',
  coverUrl: 'https://mikanani.me/images/Bangumi/x.jpg',
  addedAt: DateTime(2026, 10, 1),
);

SubscriptionView _sub({String group = 'ANi'}) => SubscriptionView(
  id: 'sub-1',
  name: '葬送的芙莉莲 · $group',
  feedUrl: 'https://mikanani.me/RSS/Bangumi?bangumiId=3887&subgroupid=9',
  sourceKind: 'rss',
  sourceParams: <String, String>{
    kSubParamBangumiId: '3887',
    kSubParamGroupName: group,
    kSubParamShowTitle: '葬送的芙莉莲',
  },
  rules: <SubsRuleView>[const SubsRuleView(id: 'rule-1', name: '全部剧集', excludeRegex: '')],
);

SourceItemView _episode(int n, {String group = 'ANi', bool magnet = true, bool batch = false}) =>
    SourceItemView(
      id: 'rss:sub-1:$n',
      sourceId: 'rss:sub-1',
      title: '[$group] 葬送的芙莉莲 - ${n.toString().padLeft(2, '0')} [1080p]',
      magnet: magnet ? 'magnet:?xt=urn:btih:${'a' * 40}' : null,
      group: group,
      episodeHints: <String>[n.toString().padLeft(2, '0')],
      extra: batch ? <String, Object?>{'isBatch': true} : const <String, Object?>{},
    );

class _Subs implements SubsPort {
  _Subs(this.subs, this.bySubscription);

  final List<SubscriptionView> subs;
  final Map<String, List<SourceItemView>> bySubscription;
  final List<String> removed = <String>[];

  @override
  Stream<List<SubscriptionView>> watch() => Stream<List<SubscriptionView>>.value(subs);

  @override
  Future<void> upsert(SubscriptionView subscription) async {}

  @override
  Future<void> remove(String id) async => removed.add(id);

  @override
  Future<SubsRefreshResult> refresh(String id) async => const SubsRefreshResult(fetched: 3);

  @override
  Future<List<SourceItemView>> items(SubscriptionView subscription) async =>
      bySubscription[subscription.id] ?? const <SourceItemView>[];
}

class _Queue implements QueuePort {
  final List<String> enqueued = <String>[];

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('测试替身：${invocation.memberName}');

  @override
  Future<QueueJobView> enqueueDownload(SourceItemView item) async {
    enqueued.add(item.id);
    return QueueJobView(
      id: 'job-${item.id}',
      item: item,
      state: JobState.queued,
      priority: 10,
      createdAt: DateTime(2026, 10, 12),
      updatedAt: DateTime(2026, 10, 12),
    );
  }

  @override
  Stream<List<QueueJobView>> watchJobs() =>
      Stream<List<QueueJobView>>.value(const <QueueJobView>[]);
}

class _Schedule implements SchedulePort {
  _Schedule(this.detail);

  final BangumiDetailView detail;

  @override
  bool get isAvailable => true;

  @override
  Future<ScheduleView> schedule() async => ScheduleView(
    entries: const <ScheduleEntryView>[],
    byDay: const <int, List<ScheduleEntryView>>{},
    fetchedAt: DateTime(2026, 10, 12),
  );

  @override
  Future<BangumiDetailView> bangumi(String bangumiId) async => detail;
}

/// 假源：种子块要的源表 + 按「源:词」给结果（第四十九轮）。
class _SeedSources extends UnavailableSourcePort {
  _SeedSources(this.hits);

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
      fetchedAt: DateTime(2026, 10, 17, 12),
    );
  }
}

String _seedHash(int n) => n.toRadixString(16).padLeft(40, '0');

/// 一条「各站搜到的种子」（标题里带番名，相关度筛才留得住）。
SourceItemView _seedItem(int n, {String group = '桜都字幕组'}) => SourceItemView(
  id: 'mikan:seed$n',
  sourceId: 'mikan',
  title: '[$group] 葬送的芙莉莲 - ${n.toString().padLeft(2, '0')} [1080p][简繁内嵌]',
  magnet: 'magnet:?xt=urn:btih:${_seedHash(n)}',
  infoHash: _seedHash(n),
  sizeBytes: 400 * 1024 * 1024,
  group: group,
  episodeHints: <String>[n.toString().padLeft(2, '0')],
  publishedAt: DateTime(2026, 10, 1),
);

/// 一次搭好的页面与替身。
///
/// 第四十九轮起多了 [source]（种子块要的假源；不给就还是「源未接通」）——
/// 用类而不是 record：record 的具名字段不能多给（多一个字段就不是同一个类型了）。
class _Harness {
  const _Harness({
    required this.widget,
    required this.subs,
    required this.queue,
    this.source,
  });

  final Widget widget;
  final _Subs subs;
  final _Queue queue;
  final _SeedSources? source;
}

_Harness _harness({
  List<SubscriptionView>? subs,
  Map<String, List<SourceItemView>>? items,
  List<BangumiGroupView> groups = const <BangumiGroupView>[],
  _SeedSources? source,
}) {
  final _Subs subsPort =
      _Subs(subs ?? <SubscriptionView>[], items ?? <String, List<SourceItemView>>{});
  final _Queue queuePort = _Queue();
  final Widget widget = ProviderScope(
    overrides: [
      keyValueStoreProvider.overrideWithValue(InMemoryKeyValueStore(<String, Object?>{
        SettingsController.storageKey: const AppSettings(firstRunCompleted: true).toJson(),
        FollowingStore.defaultKey: <Object?>[_entry.toJson()],
      })),
      subsPortProvider.overrideWithValue(subsPort),
      queuePortProvider.overrideWithValue(queuePort),
      schedulePortProvider.overrideWithValue(
        _Schedule(BangumiDetailView(
          bangumiId: '3887',
          title: '葬送的芙莉莲',
          groups: groups,
          episodes: <SourceItemView>[_episode(1)],
        )),
      ),
      enginePortProvider.overrideWithValue(const UnavailableEnginePort()),
      playerPortProvider.overrideWithValue(const UnavailablePlayerPort()),
      pickerPortProvider.overrideWithValue(const UnavailablePickerPort()),
      // 第四十九轮：不传就还是"源未接通"（种子块显示"一个源都没有勾"），
      // 既有六条用例的行为一字不变。
      sourcePortProvider.overrideWithValue(source ?? const UnavailableSourcePort()),
      notificationPortProvider.overrideWithValue(const UnavailableNotificationPort()),
      lifecyclePortProvider.overrideWithValue(const UnavailableLifecyclePort()),
    ],
    child: MaterialApp(
      theme: buildDsanimaTheme(),
      home: FollowingDetailPage(entry: _entry),
    ),
  );
  return _Harness(
    widget: widget,
    subs: subsPort,
    queue: queuePort,
    source: source,
  );
}

void main() {
  testWidgets('只有订阅的字幕组才列剧集；没订阅的组在下面给出「订阅」', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final _Harness h = _harness(
      subs: <SubscriptionView>[_sub(group: 'ANi')],
      items: <String, List<SourceItemView>>{
        'sub-1': <SourceItemView>[_episode(1), _episode(2)],
      },
      groups: <BangumiGroupView>[
        const BangumiGroupView(name: 'ANi', id: 'g1', rssUrl: 'https://mikanani.me/RSS/x'),
        const BangumiGroupView(name: 'LoliHouse', id: 'g2', rssUrl: 'https://mikanani.me/RSS/y'),
      ],
    );
    await tester.pumpWidget(h.widget);
    await tester.pumpAndSettle();

    // 订阅的那一组：剧集按组列出 + 管理按钮。
    expect(find.text('ANi'), findsWidgets);
    expect(find.textContaining('2 集 · 已看过 0 集'), findsOneWidget);
    expect(find.text('下载全部（跳过已看过）'), findsOneWidget);
    expect(find.text('全部标记已看过'), findsOneWidget);
    // 没订阅的那一组：只在「这一部的字幕组」里出现，给「订阅」按钮。
    expect(find.text('LoliHouse'), findsOneWidget);
    expect(find.text('订阅'), findsOneWidget);
    expect(find.text('已订阅'), findsNothing, reason: 'LoliHouse 还没订阅');
  });

  testWidgets('打勾「已看过」：写进标记，计数与文案跟着变', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final _Harness h = _harness(
      subs: <SubscriptionView>[_sub()],
      items: <String, List<SourceItemView>>{
        'sub-1': <SourceItemView>[_episode(1), _episode(2)],
      },
    );
    await tester.pumpWidget(h.widget);
    await tester.pumpAndSettle();

    // 每集左边那个方框：点第一集。
    await tester.tap(find.byIcon(Icons.check_box_outline_blank).first);
    await tester.pumpAndSettle();

    expect(find.textContaining('已看过 1 集'), findsOneWidget);
    final ProviderContainer container = ProviderScope.containerOf(
      tester.element(find.byType(FollowingDetailPage)),
    );
    final Map<String, DateTime> marks = container.read(watchedMarksProvider);
    expect(marks.keys, <String>[
      watchedKey('3887', group: 'ANi', episode: 1),
    ]);

    // 再点一次 = 取消（用户：「再点一下取消」）。
    await tester.tap(find.byIcon(Icons.check_box).first);
    await tester.pumpAndSettle();
    expect(find.textContaining('已看过 0 集'), findsOneWidget);
  });

  testWidgets('「全部标记已看过」一次打满，「下载全部」随后跳过它们', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final _Harness h = _harness(
      subs: <SubscriptionView>[_sub()],
      items: <String, List<SourceItemView>>{
        'sub-1': <SourceItemView>[_episode(1), _episode(2)],
      },
    );
    await tester.pumpWidget(h.widget);
    await tester.pumpAndSettle();

    await tester.tap(find.text('全部标记已看过'));
    await tester.pumpAndSettle();
    expect(find.textContaining('已看过 2 集'), findsOneWidget);

    // 全看过 → 下载全部点了只弹一句"没有要下的"，一条都不入队。
    await tester.tap(find.text('下载全部（跳过已看过）'));
    await tester.pumpAndSettle();
    expect(h.queue.enqueued, isEmpty);
    expect(find.textContaining('都看过了'), findsOneWidget);

    // 取消一集的勾 → 下载全部只下没看过的那一集。
    await tester.tap(find.text('取消全看过'));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.check_box_outline_blank).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('下载全部（跳过已看过）'));
    await tester.pumpAndSettle();
    expect(h.queue.enqueued, <String>['rss:sub-1:2'],
        reason: '第 1 集已看过 → 只下第 2 集');
  });

  testWidgets('「全部标记已看过」**不碰合集条目**（否则「下载全部」永远跳过它）', (WidgetTester tester) async {
    // 复核抓到的真实缺陷：合集/全集条目（isBatch）被一起打了勾之后，
    // 「下载全部（跳过已看过）」会永远跳过一条**没看过**的合集，用户还不知道为什么。
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final _Harness h = _harness(
      subs: <SubscriptionView>[_sub()],
      items: <String, List<SourceItemView>>{
        'sub-1': <SourceItemView>[_episode(1), _episode(2), _episode(99, batch: true)],
      },
    );
    await tester.pumpWidget(h.widget);
    await tester.pumpAndSettle();

    await tester.tap(find.text('全部标记已看过'));
    await tester.pumpAndSettle();
    expect(find.textContaining('已看过 2 集'), findsOneWidget,
        reason: '三集里只有两集是正片：合集那一条不该被打勾');
    expect(find.textContaining('合集/全集条目不计入批量打勾'), findsOneWidget);

    // 再点「下载全部」：两集正片都标过了 → 只剩那条**没看过的合集**要下。
    await tester.tap(find.text('下载全部（跳过已看过）'));
    await tester.pumpAndSettle();
    expect(h.queue.enqueued, <String>['rss:sub-1:99'],
        reason: '合集没被误标成看过，所以它还在下载全部的范围里');
  });

  testWidgets('没有订阅时：页头提示去订阅，下面列出这一部的字幕组', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final _Harness h = _harness(
      groups: <BangumiGroupView>[
        const BangumiGroupView(name: 'ANi', id: 'g1', rssUrl: 'https://mikanani.me/RSS/x'),
      ],
    );
    await tester.pumpWidget(h.widget);
    await tester.pumpAndSettle();

    expect(find.textContaining('还没有订阅任何字幕组'), findsOneWidget);
    expect(find.text('这一部的字幕组'), findsOneWidget);
    expect(find.text('订阅'), findsOneWidget);
  });

  testWidgets('取消订阅：走确认框，确认后调 remove（不动已下载文件）', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final _Harness h = _harness(
      subs: <SubscriptionView>[_sub()],
      items: <String, List<SourceItemView>>{
        'sub-1': <SourceItemView>[_episode(1)],
      },
    );
    await tester.pumpWidget(h.widget);
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.delete_outline).first);
    await tester.pumpAndSettle();
    expect(find.textContaining('取消订阅「ANi」'), findsOneWidget);
    await tester.tap(find.text('取消订阅').last);
    await tester.pumpAndSettle();
    expect(h.subs.removed, <String>['sub-1']);
  });

  // ── 第四十九轮：订阅详细页也带「种子」 ──────────────────────────────────────

  testWidgets('订阅详细页也有「种子」块：按番名搜、按字幕组分段、在订阅区上面', (
    WidgetTester tester,
  ) async {
    // 用户原话：「优化下订阅，详细页订阅的也带有种子」—— 从「正在追」点开一部番，
    // 不用再去动漫库，这一页就能看到全站种子（和动漫库详细页同一块）。
    tester.view.physicalSize = const Size(1400, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final _Harness h = _harness(
          subs: <SubscriptionView>[_sub()],
          items: <String, List<SourceItemView>>{
            'sub-1': <SourceItemView>[_episode(1)],
          },
          source: _SeedSources(<String, List<SourceItemView>>{
            'mikan:葬送的芙莉莲': <SourceItemView>[
              _seedItem(1),
              _seedItem(2),
            ],
            'dmhy:葬送的芙莉莲': <SourceItemView>[
              _seedItem(3, group: 'LoliHouse'),
            ],
          }),
        );
    await tester.pumpWidget(h.widget);
    await tester.pumpAndSettle();

    // 种子块在，而且是用**追番记录的名字**去搜的（不是空词、不是 AppBar 里别的什么）。
    expect(find.byKey(dsDetailSeedsKey), findsOneWidget);
    expect(find.text('种子'), findsOneWidget);
    expect(h.source!.searched, contains('mikan:葬送的芙莉莲'));
    expect(find.textContaining('用的是「葬送的芙莉莲」'), findsOneWidget);

    // 结果按字幕组分段（与动漫库详细页同一套）：抬头写组名与条数。
    expect(find.textContaining('2 个字幕组'), findsOneWidget);
    expect(find.text('桜都字幕组（2 条）'), findsOneWidget);
    expect(find.text('LoliHouse（1 条）'), findsOneWidget);
    // 默认全收起 —— 一进来只有组抬头（`[简繁内嵌]` 是种子标题独有的一段：订阅剧集没有，
    // 用它判"种子行没画出来"才不会撞上订阅那一行）。
    expect(find.textContaining('[简繁内嵌]'), findsNothing);

    // 位置：在页头（封面/标题）下面、订阅字幕组**上面** —— 一进这一页就看得见，
    // 不用先翻过几十集（订阅区本身照旧，见文件头的第四十九轮说明）。
    expect(
      tester.getTopLeft(find.byKey(dsDetailSeedsKey)).dy,
      lessThan(tester.getTopLeft(find.text('下载全部（跳过已看过）')).dy),
      reason: '种子块在订阅字幕组上面，不是折在最下面',
    );

    // 点一段抬头 → 只画这一段（种子块的既定形态）。
    await tester.tap(find.byKey(dsDetailSeedsGroupToggleKey('桜都')));
    await tester.pumpAndSettle();
    expect(find.textContaining('[简繁内嵌]'), findsNWidgets(2));
    expect(
      find.textContaining('[LoliHouse]'),
      findsNothing,
      reason: 'LoliHouse 那一段还收着',
    );
  });

  testWidgets('订阅里打过的勾，种子块里也显示「已看过」（同一个 mikan 番剧 id 同一套键）', (
    WidgetTester tester,
  ) async {
    // 第四十九轮的数据口径：种子块拿到这一部的 mikan 番剧 id 之后，「已看过」与观看记录
    // 和订阅用同一套键 —— 用户在订阅里打过的勾，翻种子时不会又看到"没看过"。
    tester.view.physicalSize = const Size(1400, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final _Harness h = _harness(
          subs: <SubscriptionView>[_sub()],
          items: <String, List<SourceItemView>>{
            'sub-1': <SourceItemView>[_episode(1)],
          },
          source: _SeedSources(<String, List<SourceItemView>>{
            'mikan:葬送的芙莉莲': <SourceItemView>[_seedItem(1, group: 'ANi')],
          }),
        );
    await tester.pumpWidget(h.widget);
    await tester.pumpAndSettle();

    // 订阅那一集打勾（真实 controller，写进 watchedMarks）。
    await tester.tap(find.byIcon(Icons.check_box_outline_blank).first);
    await tester.pumpAndSettle();
    expect(find.textContaining('已看过 1 集'), findsOneWidget);

    // 展开种子块里 ANi 那一段：同一条集号带着「已看过」的标记。
    await tester.tap(find.byKey(dsDetailSeedsGroupToggleKey('ani')));
    await tester.pumpAndSettle();
    expect(
      find.byTooltip('已看过'),
      findsOneWidget,
      reason: '订阅里打过的勾在种子块里也认（mikan 番剧 id 是同一个）',
    );
  });
}
