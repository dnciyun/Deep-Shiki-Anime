/// 番剧详情页「在字幕组的旁边，可以直接订阅」（第二十七轮）。
///
/// 用户原话：
/// > 「优化正在追，直接调用 mikan 的 rss 订阅，在字幕组的旁边，可以直接订阅」
///
/// 钉两件事：**每个字幕组的标题旁边**都有一颗「订阅」；点它建出来的订阅
/// 带着这一组自己的 RSS 地址与 `sourceParams`（番剧 id / 组名）—— 后者正是
/// 「正在追」点开层能把订阅归到这一部番名下的依据。
library;

import 'dart:async';

import 'package:dsanima/domain/following_subscription.dart';
import 'package:dsanima/domain/models.dart';
import 'package:dsanima/domain/ports.dart';
import 'package:dsanima/domain/unavailable.dart';
import 'package:dsanima/state/providers.dart';
import 'package:dsanima/theme/app_theme.dart';
import 'package:dsanima/ui/bangumi_detail.dart';
import 'package:dsanima_core/sources/kv.dart' show InMemoryKeyValueStore;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _Subs implements SubsPort {
  _Subs(this.subs);

  final List<SubscriptionView> subs;
  final StreamController<List<SubscriptionView>> _controller =
      StreamController<List<SubscriptionView>>.broadcast();

  @override
  Stream<List<SubscriptionView>> watch() async* {
    yield subs;
    yield* _controller.stream;
  }

  @override
  Future<void> upsert(SubscriptionView subscription) async {
    subs
      ..removeWhere((SubscriptionView s) => s.id == subscription.id)
      ..add(subscription);
    _controller.add(List<SubscriptionView>.unmodifiable(subs));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('测试替身：${invocation.memberName}');
}

class _Schedule implements SchedulePort {
  @override
  bool get isAvailable => true;

  @override
  Future<ScheduleView> schedule() async => ScheduleView(
    entries: const <ScheduleEntryView>[],
    byDay: const <int, List<ScheduleEntryView>>{},
    fetchedAt: DateTime(2026, 10, 12),
  );

  @override
  Future<BangumiDetailView> bangumi(String bangumiId) async => BangumiDetailView(
    bangumiId: bangumiId,
    title: '葬送的芙莉莲',
    groups: <BangumiGroupView>[
      const BangumiGroupView(
        name: 'ANi',
        id: 'group-3',
        rssUrl: 'https://mikanani.me/RSS/Bangumi?bangumiId=3887&subgroupid=3',
      ),
      const BangumiGroupView(
        name: 'LoliHouse',
        id: 'group-4',
        rssUrl: 'https://mikanani.me/RSS/Bangumi?bangumiId=3887&subgroupid=4',
      ),
      // 站点没给 RSS 的组：按钮要说明"订阅不了"，而不是点了没反应。
      const BangumiGroupView(name: '无 RSS 的组', id: 'group-5'),
    ],
    episodes: <SourceItemView>[
      SourceItemView(
        id: 'mikan:e1',
        sourceId: 'mikan',
        title: '[ANi] 葬送的芙莉莲 - 01 [1080p]',
        magnet: 'magnet:?xt=urn:btih:${'a' * 40}',
        group: 'ANi',
        episodeHints: const <String>['01'],
      ),
    ],
  );
}

ScheduleEntryView get _entry => const ScheduleEntryView(
  bangumiId: '3887',
  dayOfWeek: -1,
  title: '葬送的芙莉莲',
  coverUrl: 'https://mikanani.me/images/Bangumi/x.jpg',
);

void main() {
  testWidgets('每个字幕组旁边一颗「订阅」；点它就按这一组的 RSS 建订阅（带番剧 id / 组名）',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final _Subs subs = _Subs(<SubscriptionView>[]);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          keyValueStoreProvider.overrideWithValue(InMemoryKeyValueStore(<String, Object?>{
            SettingsController.storageKey: const AppSettings(firstRunCompleted: true).toJson(),
          })),
          subsPortProvider.overrideWithValue(subs),
          schedulePortProvider.overrideWithValue(_Schedule()),
          queuePortProvider.overrideWithValue(const UnavailableQueuePort()),
          enginePortProvider.overrideWithValue(const UnavailableEnginePort()),
          playerPortProvider.overrideWithValue(const UnavailablePlayerPort()),
          pickerPortProvider.overrideWithValue(const UnavailablePickerPort()),
          sourcePortProvider.overrideWithValue(const UnavailableSourcePort()),
        ],
        child: MaterialApp(
          theme: buildDsanimaTheme(),
          home: BangumiDetailPage(entry: _entry),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 三个组各一行标题 → 两颗可订阅的「订阅」+ 一颗「无 RSS」。
    // （组名会出现两次：页头那排胶囊 + 剧集列表的分组小标题。）
    expect(find.text('ANi'), findsWidgets);
    expect(find.text('LoliHouse'), findsWidgets);
    expect(find.text('无 RSS 的组'), findsWidgets);
    expect(find.text('订阅'), findsNWidgets(2));
    expect(find.text('无 RSS'), findsOneWidget, reason: '没有 RSS 地址的组要说明订阅不了');

    // 点第一颗「订阅」→ 建的订阅就是这一组的地址。
    await tester.tap(find.text('订阅').first);
    await tester.pumpAndSettle();

    expect(subs.subs, hasLength(1));
    final SubscriptionView created = subs.subs.single;
    expect(created.feedUrl, contains('subgroupid=3'));
    expect(subscriptionBangumiId(created), '3887');
    expect(subscriptionGroupName(created), 'ANi');
    expect(created.sourceParams[kSubParamGroupId], 'group-3');
    expect(created.name, '葬送的芙莉莲 · ANi');
    expect(created.rules.single.excludeRegex, isEmpty,
        reason: '默认 exclude 里有 HEVC 10bit：照它过滤会把这一组的集藏起来');

    // 建完之后那一组变成「已订阅」（另一颗仍然是「订阅」）。
    expect(find.text('已订阅'), findsOneWidget);
    expect(find.text('订阅'), findsOneWidget);
  });
}
