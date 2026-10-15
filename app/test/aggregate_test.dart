/// 聚合搜索纯函数单测（2026-10-12 第十四轮）。
///
/// 这里全是**纯函数**：分档、合并去重、排序、失败文案。UI 与网络分页在
/// `search_page_test.dart` / `host_data_test.dart` 那边验，本文件只钉规则。
library;

import 'package:dsanima/domain/aggregate.dart';
import 'package:dsanima/domain/models.dart';
import 'package:flutter_test/flutter_test.dart';

SourceOption _src(String id, SourcePartition partition, {bool search = true}) =>
    SourceOption(id: id, displayName: id, supportsSearch: search, partition: partition);

SourceItemView _item(
  String id, {
  String? infoHash,
  int? seeders,
  int? size,
  String? magnet,
  DateTime? at,
}) =>
    SourceItemView(
      id: id,
      sourceId: id.split(':').first,
      title: id,
      infoHash: infoHash,
      seeders: seeders,
      sizeBytes: size,
      magnet: magnet,
      publishedAt: at,
    );

void main() {
  group('分档（聚合 / 动漫 / 全集）', () {
    final List<SourceOption> sources = <SourceOption>[
      _src('nyaa', SourcePartition.anime),
      _src('mikan', SourcePartition.anime),
      _src('dmhy', SourcePartition.anime),
      _src('dmhy-batch', SourcePartition.collection),
      _src('acgrip-batch', SourcePartition.collection),
      _src('bangumimoe-collection', SourcePartition.collection),
      _src('sukebei', SourcePartition.other),
      _src('rss:abc', SourcePartition.anime),
      _src('不支持搜索的源', SourcePartition.anime, search: false),
    ];

    test('聚合 = 全部可搜索的源（含 sukebei 与自定义 RSS）', () {
      expect(
        sourcesForScope(sources, SearchScope.all).map((SourceOption s) => s.id),
        <String>[
          'nyaa', 'mikan', 'dmhy', 'dmhy-batch', 'acgrip-batch',
          'bangumimoe-collection', 'sukebei', 'rss:abc',
        ],
      );
    });

    test('动漫 = 只留 anime 分区（sukebei/合集都不在里面）', () {
      expect(
        sourcesForScope(sources, SearchScope.anime).map((SourceOption s) => s.id),
        <String>['nyaa', 'mikan', 'dmhy', 'rss:abc'],
      );
    });

    test('全集 = 只留 collection 分区（正是第 9/10 轮注册的四个合集实例）', () {
      expect(
        sourcesForScope(sources, SearchScope.collection).map((SourceOption s) => s.id),
        <String>['dmhy-batch', 'acgrip-batch', 'bangumimoe-collection'],
      );
    });

    test('「最新」那条路（needSearch: false）不挑 supportsSearch', () {
      expect(
        sourcesForScope(sources, SearchScope.anime, needSearch: false)
            .map((SourceOption s) => s.id),
        contains('不支持搜索的源'),
      );
      // 但搜索那条路一定要把它挡在外面（它 search() 会抛「不支持搜索」）。
      expect(
        sourcesForScope(sources, SearchScope.anime).map((SourceOption s) => s.id),
        isNot(contains('不支持搜索的源')),
      );
    });
  });

  group('合并去重：同一条资源只留一条', () {
    test('同 infoHash → 合成一条，留信息最全的那份', () {
      final SourceItemView thin = _item('dmhy:1', infoHash: 'HASH1', seeders: 3);
      final SourceItemView rich = _item('mikan:9',
          infoHash: 'HASH1', seeders: 12, size: 1234, magnet: 'magnet:?xt=HASH1');
      final List<SourceItemView> merged =
          aggregateMerge(<SourceItemView>[thin], <SourceItemView>[rich]);
      expect(merged.length, 1);
      expect(merged.single.id, 'mikan:9', reason: '留下的是信息更全的那条');
    });

    test('没有 infoHash 的条目只按自己的 id 去重（跨站认不出是同一部，就不硬合）', () {
      final List<SourceItemView> merged = aggregateMerge(
        <SourceItemView>[_item('dmhy:1')],
        <SourceItemView>[_item('mikan:1')],
      );
      expect(merged.length, 2, reason: '没有 infoHash 时无法判定同一条，宁可都留着');
    });

    test('信息一样全 → 种子多的优先；也一样多 → 保持先到的（稳定）', () {
      final SourceItemView a = _item('a:1', infoHash: 'H', seeders: 5, size: 1);
      final SourceItemView b = _item('b:1', infoHash: 'H', seeders: 9, size: 1);
      expect(aggregateMerge(<SourceItemView>[a], <SourceItemView>[b]).single.id, 'b:1');

      final SourceItemView c = _item('c:1', infoHash: 'H', seeders: 5, size: 1);
      expect(aggregateMerge(<SourceItemView>[a], <SourceItemView>[c]).single.id, 'a:1');
    });

    test('合并保留先到顺序（排序是另一件事）', () {
      final List<SourceItemView> merged = aggregateMerge(
        <SourceItemView>[_item('a:1'), _item('a:2')],
        <SourceItemView>[_item('b:1'), _item('a:1')],
      );
      expect(merged.map((SourceItemView i) => i.id), <String>['a:1', 'a:2', 'b:1']);
    });
  });

  group('排序：新→旧，没时间的排最后', () {
    test('按发布时间倒序；缺时间的沉底；同时间按 id 稳定', () {
      final SourceItemView old = _item('a:1', at: DateTime.utc(2026, 1, 1));
      final SourceItemView fresh = _item('b:1', at: DateTime.utc(2026, 10, 1));
      final SourceItemView noneA = _item('c:1');
      final SourceItemView noneB = _item('d:1');
      final List<SourceItemView> sorted =
          aggregateSort(<SourceItemView>[old, noneB, fresh, noneA]);
      expect(
        sorted.map((SourceItemView i) => i.id),
        <String>['b:1', 'a:1', 'c:1', 'd:1'],
      );
    });
  });

  group('失败文案（部分源失败 → 警告带）', () {
    const AggregateSourceResult ok = AggregateSourceResult(
      sourceId: 'mikan',
      displayName: 'Mikan（蜜柑计划）',
      items: <SourceItemView>[],
    );
    const AggregateSourceResult bad1 = AggregateSourceResult(
      sourceId: 'dmhy',
      displayName: '动漫花园（DMHY）',
      failure: '拉取超时',
    );
    const AggregateSourceResult bad2 = AggregateSourceResult(
      sourceId: 'acgnx',
      displayName: 'ACGNX · 動畫',
      failure: 'HTTP 502',
    );

    test('说出「几个源的几个」+ 是哪几个 + 原因', () {
      expect(aggregateFailureBanner(<AggregateSourceResult>[ok, bad1, bad2]),
          '2/3 个源没回来：动漫花园（DMHY）（拉取超时）、ACGNX · 動畫（HTTP 502）');
    });

    test('全成功 → 空串（不画警告带）', () {
      expect(aggregateFailureBanner(<AggregateSourceResult>[ok]), '');
    });

    test('失败多于 3 个 → 只列 3 个 + 共几个', () {
      final List<AggregateSourceResult> many = <AggregateSourceResult>[
        for (int i = 0; i < 5; i++)
          AggregateSourceResult(sourceId: 's$i', displayName: '源$i', failure: '超时'),
      ];
      final String text = aggregateFailureBanner(many);
      expect(text, startsWith('5/5 个源没回来：源0（超时）、源1（超时）、源2（超时）'));
      expect(text, endsWith('…共 5 个'));
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // 第十五轮：勾选
  // ───────────────────────────────────────────────────────────────────────────
  group('勾选：默认全开 / 可只勾几个 / 至少留一个', () {
    final List<SourceOption> sources = <SourceOption>[
      _src('nyaa', SourcePartition.anime),
      _src('mikan', SourcePartition.anime),
      _src('rss:abc', SourcePartition.anime, search: false),
      _src('dmhy-batch', SourcePartition.collection),
      _src('sukebei', SourcePartition.other),
    ];

    test('空的排除名单 = 默认全开（连 sukebei 与 RSS 都在勾选里）', () {
      expect(selectedSourceCount(sources, const <String>{}), 5);
      expect(selectionSummary(sources, const <String>{}), '源 5/5');
      // 但"会去问"的仍受 supportsSearch 限制：有关键字时不问 RSS。
      expect(
        selectedSources(sources, const <String>{}).map((SourceOption s) => s.id),
        <String>['nyaa', 'mikan', 'dmhy-batch', 'sukebei'],
      );
      expect(
        selectedSources(sources, const <String>{}, needSearch: false).map((SourceOption s) => s.id),
        contains('rss:abc'),
      );
    });

    test('档位预设 = 排除掉不在这一档里的源；反推能认出是哪一档', () {
      expect(excludedForScope(sources, SearchScope.all), isEmpty);
      expect(
        excludedForScope(sources, SearchScope.anime),
        <String>{'dmhy-batch', 'sukebei'},
      );
      expect(
        excludedForScope(sources, SearchScope.collection),
        <String>{'nyaa', 'mikan', 'rss:abc', 'sukebei'},
      );
      expect(activeScopePreset(sources, const <String>{}), SearchScope.all);
      expect(
        activeScopePreset(sources, excludedForScope(sources, SearchScope.anime)),
        SearchScope.anime,
      );
      expect(
        activeScopePreset(sources, excludedForScope(sources, SearchScope.collection)),
        SearchScope.collection,
      );
    });

    test('手动改过 → 三档都不是（null = 自定义）', () {
      // 「聚合」档上又取消了 sukebei：哪一档都不完全一样。
      final Set<String> mixed = <String>{'sukebei'};
      expect(activeScopePreset(sources, mixed), isNull);
      expect(selectionSummary(sources, mixed), '源 4/5');
    });

    test('取消一个源只影响它自己', () {
      expect(
        selectedSources(sources, <String>{'mikan'}).map((SourceOption s) => s.id),
        <String>['nyaa', 'dmhy-batch', 'sukebei'],
      );
      expect(
        selectedSources(sources, <String>{'mikan'}, needSearch: false)
            .map((SourceOption s) => s.id),
        <String>['nyaa', 'rss:abc', 'dmhy-batch', 'sukebei'],
      );
    });

    test('排除名单里躺着一个已不存在的 id：不是脏数据，不影响档位判断', () {
      // sukebei 被关掉（源没了）之后再打开，用户当初"不要它"仍然算数。
      expect(selectedSourceCount(sources, <String>{'gone-batch'}), 5);
      expect(activeScopePreset(sources, <String>{'gone-batch'}), SearchScope.all);
      expect(selectedSources(sources, <String>{'gone-batch'}).length, 4);
    });

    test('至少留一个源：取消最后一个会被挡住', () {
      expect(
        blocksUnselect(
          sources: sources,
          excludedSourceIds: <String>{'nyaa', 'mikan', 'rss:abc', 'dmhy-batch'},
          id: 'sukebei',
        ),
        isTrue,
        reason: '只剩 sukebei 一个勾着 → 取消后一个源都没有',
      );
      expect(
        blocksUnselect(
          sources: sources,
          excludedSourceIds: <String>{'nyaa', 'mikan', 'dmhy-batch'},
          id: 'sukebei',
        ),
        isFalse,
      );
      expect(
        blocksUnselect(sources: sources, excludedSourceIds: <String>{'sukebei'}, id: 'sukebei'),
        isFalse,
        reason: '它本来就没勾（用户点的是"勾上"）→ 永远不挡',
      );
    });

    test('面板分组：动漫 → 全集 → 其它，空组不出现，组内保持注册顺序', () {
      final List<SourceGroup> groups = sourceGroups(<SourceOption>[
        _src('sukebei', SourcePartition.other),
        _src('mikan', SourcePartition.anime),
        _src('dmhy-batch', SourcePartition.collection),
        _src('nyaa', SourcePartition.anime),
      ]);
      expect(groups.map((SourceGroup g) => g.partition), <SourcePartition>[
        SourcePartition.anime,
        SourcePartition.collection,
        SourcePartition.other,
      ]);
      expect(groups.first.sources.map((SourceOption s) => s.id), <String>['mikan', 'nyaa']);
      expect(
        sourceGroups(<SourceOption>[_src('mikan', SourcePartition.anime)]).length,
        1,
        reason: '只有动漫源时不该画出「全集（0）」「其它（0）」这种空组',
      );
      expect(partitionLabel(SourcePartition.other), '其它');
    });

    test('「正在问哪些站」把名字摆出来，非搜索源有备注', () {
      final String detail = selectionDetail(sources, <String>{'sukebei'});
      expect(detail, startsWith('正在问：nyaa、mikan、rss:abc、dmhy-batch'));
      expect(detail, contains('1 个不支持关键字搜索'));
      // 一个都没勾（正常情况下到不了这里）也要说人话，而不是空白。
      final Set<String> none = <String>{
        for (final SourceOption s in sources) s.id,
      };
      expect(selectionDetail(sources, none), contains('一个源都没勾'));
      // 源多时不列全，避免 tooltip 长到看不清。
      final List<SourceOption> many = <SourceOption>[
        for (int i = 0; i < 9; i++) _src('s$i', SourcePartition.anime),
      ];
      expect(selectionDetail(many, const <String>{}), contains('共 9 个'));
    });

    test('勾选落进设置：toJson / fromJson 来回一趟不丢，坏数据当全开', () {
      const AppSettings saved = AppSettings(
        firstRunCompleted: true,
        aggregateExcludedSourceIds: <String>['sukebei', 'dmhy-batch'],
      );
      expect(
        AppSettings.fromJson(saved.toJson()).aggregateExcludedSourceIds,
        <String>['sukebei', 'dmhy-batch'],
      );
      // 老配置里没有这个字段 → 空 = 全开。
      expect(
        AppSettings.fromJson(<Object?, Object?>{'firstRunCompleted': true})
            .aggregateExcludedSourceIds,
        isEmpty,
      );
      // 乱码/空白/重复：丢掉。
      expect(
        AppSettings.fromJson(<Object?, Object?>{
          'aggregateExcludedSourceIds': <Object?>['  ', 7, 'sukebei', 'sukebei', ' mikan '],
        }).aggregateExcludedSourceIds,
        <String>['sukebei', 'mikan'],
      );
    });
  });
}
