/// 「正在追」点开层（第二十七轮）：只列订阅的字幕组、逐集打勾、下载全部跳过已看过。
///
/// 用户这一轮的原话（节选）：
/// > 「订阅可在正在追内标记已看过，已看过的在旁边打上勾。……点开后，仅显示订阅的字幕组，
/// >  并在上面可直接下载全部或单集下载，下载全部跳过已看过的。」
///
/// 用假端口注入（订阅 / 队列 / 番剧详情），不联网、不起引擎。
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

({Widget widget, _Subs subs, _Queue queue}) _harness({
  List<SubscriptionView>? subs,
  Map<String, List<SourceItemView>>? items,
  List<BangumiGroupView> groups = const <BangumiGroupView>[],
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
      sourcePortProvider.overrideWithValue(const UnavailableSourcePort()),
      notificationPortProvider.overrideWithValue(const UnavailableNotificationPort()),
      lifecyclePortProvider.overrideWithValue(const UnavailableLifecyclePort()),
    ],
    child: MaterialApp(
      theme: buildDsanimaTheme(),
      home: FollowingDetailPage(entry: _entry),
    ),
  );
  return (widget: widget, subs: subsPort, queue: queuePort);
}

void main() {
  testWidgets('只有订阅的字幕组才列剧集；没订阅的组在下面给出「订阅」', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final ({Widget widget, _Subs subs, _Queue queue}) h = _harness(
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

    final ({Widget widget, _Subs subs, _Queue queue}) h = _harness(
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

    final ({Widget widget, _Subs subs, _Queue queue}) h = _harness(
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

    final ({Widget widget, _Subs subs, _Queue queue}) h = _harness(
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

    final ({Widget widget, _Subs subs, _Queue queue}) h = _harness(
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

    final ({Widget widget, _Subs subs, _Queue queue}) h = _harness(
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
}
