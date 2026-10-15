/// 字幕组订阅（第二十七轮）：订阅条目的构造、与番的匹配、以及"每集打勾键"的口径。
library;

import 'package:dsanima/domain/following_store.dart';
import 'package:dsanima/domain/following_subscription.dart';
import 'package:dsanima/domain/models.dart';
import 'package:dsanima/domain/watch_history.dart';
import 'package:flutter_test/flutter_test.dart';

SubscriptionView _sub({
  String id = 'sub-1',
  String? bangumiId = '3887',
  String? groupName = 'ANi',
  String kind = 'rss',
}) => SubscriptionView(
  id: id,
  name: '某番 · ${groupName ?? '?'}',
  feedUrl: 'https://mikanani.me/RSS/Bangumi?bangumiId=3887&subgroupid=9',
  sourceKind: kind,
  sourceParams: <String, String>{
    kSubParamBangumiId: ?bangumiId,
    kSubParamGroupName: ?groupName,
  },
);

FollowingEntry _entry({String? mikanId = '3887', String title = '某番'}) => FollowingEntry(
  id: mikanId == null ? 'title:$title' : 'mikan:$mikanId',
  title: title,
  mikanBangumiId: mikanId,
  addedAt: DateTime(2026, 10, 1),
);

SourceItemView _item(String title, {List<String> hints = const <String>['03']}) =>
    SourceItemView(id: 'mikan:$title', sourceId: 'rss:sub-1', title: title, episodeHints: hints);

void main() {
  group('buildGroupSubscription：点「订阅」造出来的那一条', () {
    test('名字 = 番名 · 字幕组；番剧 id / 组名 / 组 id 都进 sourceParams', () {
      final SubscriptionView sub = buildGroupSubscription(
        id: 'sub-9',
        ruleId: 'rule-9',
        bangumiId: '3887',
        groupName: 'ANi',
        groupId: 'group-3',
        showTitle: '葬送的芙莉莲',
        feedUrl: 'https://mikanani.me/RSS/Bangumi?bangumiId=3887&subgroupid=3',
      );
      expect(sub.name, '葬送的芙莉莲 · ANi');
      expect(sub.sourceKind, 'rss');
      expect(sub.feedUrl, contains('subgroupid=3'));
      expect(subscriptionBangumiId(sub), '3887');
      expect(subscriptionGroupName(sub), 'ANi');
      expect(sub.sourceParams[kSubParamGroupId], 'group-3');
      expect(sub.enabled, isTrue);
      // 订阅 = 追更 + 手动下载：默认不自动下载。
      expect(sub.rules.single.autoDownload, isFalse);
    });

    test('规则的两条正则都留空 —— 默认 exclude 会把 HEVC 10bit 的集藏起来', () {
      final SubscriptionView sub = buildGroupSubscription(
        id: 'sub-9',
        ruleId: 'rule-9',
        bangumiId: '1',
        groupName: 'G',
        showTitle: 'X',
        feedUrl: 'u',
      );
      expect(sub.rules.single.includeRegex, isEmpty);
      expect(sub.rules.single.excludeRegex, isEmpty);
      expect(sub.rules.single.name, '全部剧集');
    });
  });

  group('订阅 ↔ 番 的匹配', () {
    test('subscriptionsOf：只按 mikan 番剧 id 精确匹配（不靠番名猜）', () {
      final List<SubscriptionView> subs = <SubscriptionView>[
        _sub(id: 'a'),
        _sub(id: 'b', groupName: 'LoliHouse'),
        _sub(id: 'c', bangumiId: '9999'),
        _sub(id: 'd', bangumiId: null, groupName: '无 id 的自定义订阅'),
      ];
      final List<SubscriptionView> mine = subscriptionsOf(_entry(), subs);
      expect(mine.map((SubscriptionView s) => s.id), <String>['a', 'b']);
    });

    test('没有 mikan id 的追番记录：匹配不到任何订阅（诚实地空）', () {
      expect(subscriptionsOf(_entry(mikanId: null), <SubscriptionView>[_sub()]), isEmpty);
    });

    test('subscriptionForGroup：同番同组才算已订阅（同番不同组各有各的订阅）', () {
      final List<SubscriptionView> subs = <SubscriptionView>[_sub(id: 'a', groupName: 'ANi')];
      expect(
        subscriptionForGroup(subs, bangumiId: '3887', groupName: 'ANi')?.id,
        'a',
      );
      expect(subscriptionForGroup(subs, bangumiId: '3887', groupName: 'LoliHouse'), isNull);
      expect(subscriptionForGroup(subs, bangumiId: '9999', groupName: 'ANi'), isNull);
    });
  });

  group('每集「已看过」的键', () {
    test('键 = 观看记录那套（番剧 id + 字幕组 + 集数）', () {
      final String key = subscriptionItemWatchKey(
        bangumiId: '3887',
        title: '某番',
        group: 'ANi',
        item: _item('[ANi] 某番 - 03 [1080p]'),
      );
      expect(key, watchRecordId(mikanBangumiId: '3887', title: '某番', group: 'ANi', episode: 3));
    });

    test('一组条目 → 键列表去重；集数认不出时用集号文案兜底', () {
      final List<String> keys = subscriptionItemWatchKeys(
        bangumiId: '3887',
        title: '某番',
        group: 'ANi',
        items: <SourceItemView>[
          _item('A', hints: <String>['03']),
          _item('B', hints: <String>['03']), // 同一集的另一个链接：键相同
          _item('C', hints: <String>['SP1']),
        ],
      );
      expect(keys.toSet().length, keys.length, reason: '同一条订阅里同一集只该出一个键');
      expect(keys, hasLength(2));
    });

    test('episodeLabelOf 直接把 episodeHints 变成展示文案', () {
      expect(episodeLabelOf(_item('x', hints: <String>['01'])), isNotNull);
      expect(episodeLabelOf(_item('x', hints: const <String>[])), isNull);
    });
  });
}
