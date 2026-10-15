/// 订阅规则单测（spec §4.3）：默认值、命中判定、非法配置、候选排序、订阅模型与持久化。
library;

import 'package:dsanima_core/sources/sources.dart';
import 'package:dsanima_core/subs/subs.dart';
import 'package:flutter_test/flutter_test.dart';

SourceItem _item(
  String id, {
  String? title,
  String sourceId = 'nyaa',
  String? group,
  int? seeders,
  int? sizeBytes,
  int? resolution,
  bool isBatch = false,
}) =>
    SourceItem(
      id: id,
      sourceId: sourceId,
      title: title ?? '[组] 某番 - $id [1080p]',
      group: group,
      seeders: seeders,
      sizeBytes: sizeBytes,
      episodeHints: const <String>['01'],
      extra: <String, dynamic>{
        'resolution': ?resolution,
        'isBatch': isBatch,
      },
    );

void main() {
  group('SubsRule 默认值（spec §4.3）', () {
    test('默认排除模式、做种数、体积、自动下载', () {
      final rule = SubsRule(id: 'r1', name: '默认规则');
      expect(rule.includeRegex, '');
      expect(rule.excludeRegex, '(合集|全集|BDRip|HEVC.*10bit|招募|招新)');
      expect(rule.excludeRegex, SubsRule.defaultExcludeRegex);
      expect(rule.minSeeders, 0);
      expect(rule.minSizeMB, 0);
      expect(rule.maxSizeMB, 0);
      expect(rule.autoDownload, isFalse);
      expect(rule.preferResolution, isNull);
      expect(rule.sourceId, isNull);
      expect(rule.saveSubFolder, '');
      expect(rule.validate(), isNull);
    });

    test('JSON 往返', () {
      final rule = SubsRule(
        id: 'r2',
        name: '芙莉莲',
        sourceId: 'nyaa',
        includeRegex: 'Frieren|芙莉莲',
        groupAllow: 'Erai-raws, Nix-Raws',
        minSeeders: 5,
        minSizeMB: 200,
        maxSizeMB: 3000,
        preferResolution: 1080,
        autoDownload: true,
        saveSubFolder: 'Anime/{title}',
      );
      final restored = SubsRule.fromJson(rule.toJson());
      expect(restored.id, rule.id);
      expect(restored.name, rule.name);
      expect(restored.sourceId, 'nyaa');
      expect(restored.includeRegex, 'Frieren|芙莉莲');
      expect(restored.excludeRegex, SubsRule.defaultExcludeRegex);
      expect(restored.groupAllow, 'Erai-raws, Nix-Raws');
      expect(restored.minSeeders, 5);
      expect(restored.minSizeMB, 200);
      expect(restored.maxSizeMB, 3000);
      expect(restored.preferResolution, 1080);
      expect(restored.autoDownload, isTrue);
      expect(restored.saveSubFolder, 'Anime/{title}');
      expect(restored.groupAllowList, <String>['Erai-raws', 'Nix-Raws']);
    });

    test('groupAllowList 支持中英文逗号与空白', () {
      expect(
        SubsRule(id: 'r', name: 'r', groupAllow: ' A，B ,, C ').groupAllowList,
        <String>['A', 'B', 'C'],
      );
      expect(SubsRule(id: 'r', name: 'r').groupAllowList, isEmpty);
      expect(SubsRule(id: 'r', name: 'r', groupAllow: '  ').groupAllowList,
          isEmpty);
    });
  });

  group('SubsRule.validate', () {
    test('非法正则会报出来（不静默当不命中）', () {
      final rule = SubsRule(id: 'r', name: 'r', includeRegex: '([未闭合');
      expect(rule.validate(), contains('includeRegex'));
      expect(() => rule.matches(_item('a')), throwsA(isA<SubsRuleException>()));
    });

    test('excludeRegex 非法同样报错', () {
      expect(SubsRule(id: 'r', name: 'r', excludeRegex: '*坏').validate(),
          contains('excludeRegex'));
    });

    test('preferResolution 只接受 null/720/1080/2160', () {
      expect(SubsRule(id: 'r', name: 'r', preferResolution: 1080).validate(),
          isNull);
      expect(SubsRule(id: 'r', name: 'r', preferResolution: 480).validate(),
          contains('preferResolution'));
    });

    test('体积上下限与空 id', () {
      expect(
        SubsRule(id: 'r', name: 'r', minSizeMB: 500, maxSizeMB: 100).validate(),
        contains('maxSizeMB'),
      );
      expect(SubsRule(id: 'r', name: 'r', minSizeMB: -1).validate(),
          contains('负数'));
      expect(SubsRule(id: '  ', name: 'r').validate(), contains('id'));
    });
  });

  group('SubsRule.matches', () {
    test('sourceId 非 null 时必须完全一致', () {
      final rule = SubsRule(id: 'r', name: 'r', sourceId: 'nyaa');
      expect(rule.matches(_item('a', sourceId: 'nyaa')), isTrue);
      expect(rule.matches(_item('a', sourceId: 'mikan')), isFalse);
      expect(rule.matches(_item('a', sourceId: 'rss:sub1')), isFalse);

      final rssRule = SubsRule(id: 'r', name: 'r', sourceId: 'rss:sub1');
      expect(rssRule.matches(_item('a', sourceId: 'rss:sub1')), isTrue);
    });

    test('sourceId 为 null = 全部源', () {
      final rule = SubsRule(id: 'r', name: 'r');
      expect(rule.matches(_item('a', sourceId: 'nyaa')), isTrue);
      expect(rule.matches(_item('a', sourceId: 'mikan')), isTrue);
      expect(rule.matches(_item('a', sourceId: 'rss:x')), isTrue);
    });

    test('includeRegex / excludeRegex（默认排除合集与 HEVC 10bit）', () {
      final rule = SubsRule(id: 'r', name: 'r', includeRegex: 'Frieren|芙莉莲');
      expect(rule.matches(_item('a', title: '[Erai-raws] Frieren - 10 [1080p]')),
          isTrue);
      expect(rule.matches(_item('a', title: '[组] 其他番 - 10')), isFalse);
      expect(rule.matches(_item('a', title: '[组] 芙莉莲 合集')), isFalse);
      expect(rule.matches(_item('a', title: '[组] Frieren BDRip 1080p')), isFalse);
      expect(
        rule.matches(_item('a', title: '[ASW] Frieren [1080p HEVC x265 10Bit]')),
        isFalse,
      );
      expect(rule.matches(_item('a', title: '[组] Frieren 招募')), isFalse);
    });

    test('excludeRegex 为空串 = 不排除', () {
      final rule = SubsRule(id: 'r', name: 'r', excludeRegex: '');
      expect(rule.matches(_item('a', title: '[组] 某番 合集')), isTrue);
    });

    test('groupAllow 白名单：条目没有字幕组时 fail closed', () {
      final rule = SubsRule(id: 'r', name: 'r', groupAllow: 'Nix-Raws, ASW');
      expect(rule.matches(_item('a', group: 'Nix-Raws')), isTrue);
      expect(rule.matches(_item('a', group: 'nix-raws')), isTrue); // 大小写不敏感
      expect(rule.matches(_item('a', group: 'ASW')), isTrue);
      expect(rule.matches(_item('a', group: 'Erai-raws')), isFalse);
      expect(rule.matches(_item('a')), isFalse); // group 为 null
    });

    test('minSeeders：做种数未知按 0 处理', () {
      final rule = SubsRule(id: 'r', name: 'r', minSeeders: 10);
      expect(rule.matches(_item('a', seeders: 10)), isTrue);
      expect(rule.matches(_item('a', seeders: 9)), isFalse);
      expect(rule.matches(_item('a')), isFalse); // mikan RSS 没有做种数

      final loose = SubsRule(id: 'r', name: 'r', minSeeders: 0);
      expect(loose.matches(_item('a')), isTrue);
    });

    test('体积区间：体积未知 fail closed', () {
      final rule = SubsRule(id: 'r', name: 'r', minSizeMB: 200, maxSizeMB: 3000);
      expect(rule.matches(_item('a', sizeBytes: 500 * 1024 * 1024)), isTrue);
      expect(rule.matches(_item('a', sizeBytes: 100 * 1024 * 1024)), isFalse);
      expect(rule.matches(_item('a', sizeBytes: 5000 * 1024 * 1024)), isFalse);
      expect(rule.matches(_item('a')), isFalse);

      final openRange = SubsRule(id: 'r', name: 'r');
      expect(openRange.matches(_item('a')), isTrue); // 不限体积 → 未知也命中
    });
  });

  group('候选排序（分辨率优先 → 做种数 → 体积接近 minSizeMB）', () {
    List<String> ids(List<SourceItem> items) =>
        items.map((SourceItem i) => i.id).toList();

    test('分辨率：等于 preferResolution 最前，其余从高到低，未知最后', () {
      final rule = SubsRule(id: 'r', name: 'r', preferResolution: 1080);
      final items = <SourceItem>[
        _item('720', resolution: 720, seeders: 100),
        _item('1080', resolution: 1080, seeders: 1),
        _item('2160', resolution: 2160, seeders: 50),
        _item('none', seeders: 999),
      ];
      items.sort(rule.compareCandidates);
      expect(ids(items), <String>['1080', '2160', '720', 'none']);
    });

    test('同分辨率比做种数（多的优先，未知按 0）', () {
      final rule = SubsRule(id: 'r', name: 'r', preferResolution: 1080);
      final items = <SourceItem>[
        _item('a', resolution: 1080, seeders: 5),
        _item('b', resolution: 1080, seeders: 50),
        _item('c', resolution: 1080),
      ];
      items.sort(rule.compareCandidates);
      expect(ids(items), <String>['b', 'a', 'c']);
    });

    test('再做种数也相同 → 体积最接近 minSizeMB', () {
      final rule =
          SubsRule(id: 'r', name: 'r', preferResolution: 1080, minSizeMB: 1400);
      final items = <SourceItem>[
        _item('far', resolution: 1080, seeders: 10, sizeBytes: 5000 * 1024 * 1024),
        _item('exact', resolution: 1080, seeders: 10, sizeBytes: 1400 * 1024 * 1024),
        _item('near', resolution: 1080, seeders: 10, sizeBytes: 1300 * 1024 * 1024),
        _item('unknown', resolution: 1080, seeders: 10),
      ];
      items.sort(rule.compareCandidates);
      expect(ids(items), <String>['exact', 'near', 'far', 'unknown']);
    });

    test('rank() = 先按规则过滤再排序，被排除的不会出现', () {
      final rule = SubsRule(
        id: 'r',
        name: 'r',
        sourceId: 'nyaa',
        includeRegex: 'Frieren',
        preferResolution: 1080,
      );
      final ranked = rule.rank(<SourceItem>[
        _item('ok1080', title: 'Frieren - 01 [1080p]', resolution: 1080, seeders: 3),
        _item('ok720', title: 'Frieren - 01 [720p]', resolution: 720, seeders: 99),
        _item('batch', title: 'Frieren 合集 [1080p]', resolution: 1080, seeders: 999),
        _item('other', title: '别的番 - 01 [1080p]', resolution: 1080, seeders: 999),
        _item('mikan', title: 'Frieren - 01 [1080p]', sourceId: 'mikan', resolution: 1080),
      ]);
      expect(ids(ranked), <String>['ok1080', 'ok720']);
    });
  });

  group('Subscription', () {
    test('sourceId 由 sourceKind 推导', () {
      expect(Subscription(id: 's1', name: 's', feedUrl: 'u').sourceId,
          'rss:s1');
      expect(
        Subscription(id: 's1', name: 's', feedUrl: 'u', sourceKind: 'nyaa')
            .sourceId,
        'nyaa',
      );
      expect(
        Subscription(id: 's1', name: 's', feedUrl: 'u', sourceKind: 'mikan')
            .sourceId,
        'mikan',
      );
    });

    test('默认值：30 分钟刷新、启用、未 seeded', () {
      final sub = Subscription(id: 's1', name: 's', feedUrl: 'u');
      expect(sub.refreshInterval, const Duration(minutes: 30));
      expect(sub.enabled, isTrue);
      expect(sub.isSeeded, isFalse);
      expect(sub.lastRefreshAt, isNull);
      expect(sub.lastError, isNull);
      expect(sub.rules, isEmpty);
      expect(sub.sourceParams, isEmpty);
    });

    test('首次抓取只做已读标记，不倒灌历史剧集', () {
      final sub = Subscription(id: 's1', name: 's', feedUrl: 'u');
      final items = <SourceItem>[_item('a'), _item('b')];
      final seeded = sub.seed(items);
      expect(seeded, <String>{'a', 'b'});
      expect(sub.isSeeded, isTrue);
      expect(sub.unseen(items), isEmpty); // 全部已读 → 不倒灌

      final fresh = _item('c');
      expect(sub.unseen(<SourceItem>[...items, fresh]), <SourceItem>[fresh]);
    });

    test('matchAll：多规则命中并去重（用于「命中预览」）', () {
      final sub = Subscription(
        id: 's1',
        name: 's',
        feedUrl: 'u',
        rules: <SubsRule>[
          SubsRule(id: 'r1', name: 'r1', includeRegex: 'Frieren'),
          SubsRule(id: 'r2', name: 'r2', includeRegex: '芙莉莲'),
        ],
      );
      final matched = sub.matchAll(<SourceItem>[
        _item('a', title: '[组] Frieren - 01'),
        _item('b', title: '[组] 芙莉莲 - 02'),
        _item('c', title: '[组] 别的 - 03'),
      ]);
      expect(matched.map((SourceItem i) => i.id).toList(), <String>['a', 'b']);
    });

    test('JSON 往返（含规则与 seededIds）', () {
      final sub = Subscription(
        id: 's1',
        name: '芙莉莲订阅',
        feedUrl: 'https://mikanani.me/RSS/Classic',
        sourceKind: 'mikan',
        sourceParams: <String, String>{'category': '1_2'},
        rules: <SubsRule>[SubsRule(id: 'r1', name: 'r1', autoDownload: true)],
        refreshInterval: const Duration(minutes: 15),
        lastRefreshAt: DateTime.utc(2026, 10, 8, 12),
        lastError: '上次失败了',
        seededIds: <String, bool>{'mikan:x': true},
      );
      final restored = Subscription.fromJson(sub.toJson());
      expect(restored.id, 's1');
      expect(restored.name, '芙莉莲订阅');
      expect(restored.feedUrl, 'https://mikanani.me/RSS/Classic');
      expect(restored.sourceKind, 'mikan');
      expect(restored.sourceParams, <String, String>{'category': '1_2'});
      expect(restored.rules.single.id, 'r1');
      expect(restored.rules.single.autoDownload, isTrue);
      expect(restored.refreshInterval, const Duration(minutes: 15));
      expect(restored.lastRefreshAt, DateTime.utc(2026, 10, 8, 12));
      expect(restored.lastError, '上次失败了');
      expect(restored.seededIds['mikan:x'], isTrue);
      expect(restored.sourceId, 'mikan');
    });
  });

  group('SubscriptionStore（注入 KeyValueStore，不依赖 Hive）', () {
    test('save/load 往返', () async {
      final store = InMemoryKeyValueStore();
      final subs = SubscriptionStore(store);
      await subs.save(<Subscription>[
        Subscription(
          id: 's1',
          name: 'A',
          feedUrl: 'u1',
          rules: <SubsRule>[SubsRule(id: 'r', name: 'r')],
        ),
        Subscription(id: 's2', name: 'B', feedUrl: 'u2', enabled: false),
      ]);

      final loaded = await SubscriptionStore(store).load();
      expect(loaded, hasLength(2));
      expect(loaded[0].id, 's1');
      expect(loaded[0].rules.single.id, 'r');
      expect(loaded[1].id, 's2');
      expect(loaded[1].enabled, isFalse);
      expect(store.get('subscriptions'), isA<List<dynamic>>());
    });

    test('损坏记录被跳过，不炸掉整个订阅列表', () async {
      final store = InMemoryKeyValueStore(<String, Object?>{
        'subscriptions': <dynamic>[
          'not-a-map',
          Subscription(id: 'good', name: 'ok', feedUrl: 'u').toJson(),
        ],
      });
      final loaded = await SubscriptionStore(store).load();
      expect(loaded, hasLength(1));
      expect(loaded.single.id, 'good');
    });

    test('空 / 缺键 → 空列表', () async {
      expect(await SubscriptionStore(InMemoryKeyValueStore()).load(), isEmpty);
      final store = InMemoryKeyValueStore(<String, Object?>{'subscriptions': 42});
      expect(await SubscriptionStore(store).load(), isEmpty);
    });
  });
}
