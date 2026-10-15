/// 聚合搜索的控制器测试（2026-10-12 第十四轮）。
///
/// 用户原话：
/// > 「添加聚合搜索，聚合全部源，默认为聚合源，可切换聚合 动漫和全集，
/// >  设置中切换回单独源模式」
///
/// 这里用假 `SourcePort` 验四件在 UI 上看不出来的事：
/// 1. **默认就是聚合模式**，一次 `refresh` 真的把这一档的源都问了一遍；
/// 2. 三档（聚合 / 动漫 / 全集）分别问哪些源（按 core 声明的分区，不猜 id）；
/// 3. 合并去重 + 新→旧排序（跨源同 infoHash 只留一条，留信息更全的那条）；
/// 4. 失败语义：**部分源失败 → 结果照常 + 警告带**；全部失败 → 整页错误；
///    设置里切回单独源模式 → 只问默认源（老行为原样）。
library;

import 'package:dsanima/domain/aggregate.dart';
import 'package:dsanima/domain/models.dart';
import 'package:dsanima/domain/ports.dart';
import 'package:dsanima/state/providers.dart';
import 'package:dsanima_core/sources/kv.dart' show InMemoryKeyValueStore;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// 一个假源：`pages[n]` = 这个源第 n 页给的东西；[failure] 非空则每次都抛。
class _FakeSource {
  _FakeSource({
    required this.id,
    required this.displayName,
    required this.pages,
    this.partition = SourcePartition.anime,
    this.failure,
  });

  final String id;
  final String displayName;
  final Map<int, List<SourceItemView>> pages;
  final SourcePartition partition;
  final String? failure;

  final List<int> requested = <int>[];
}

class _FakeAggregatePort implements SourcePort {
  _FakeAggregatePort(this.fakes);

  final List<_FakeSource> fakes;

  _FakeSource _byId(String id) => fakes.firstWhere((_FakeSource f) => f.id == id);

  @override
  List<SourceOption> get sources => <SourceOption>[
    for (final _FakeSource f in fakes)
      SourceOption(
        id: f.id,
        displayName: f.displayName,
        partition: f.partition,
      ),
  ];

  @override
  Future<SourcePageView> latest(String sourceId, {int page = 1}) => _page(sourceId, page);

  @override
  Future<SourcePageView> search(String sourceId, String keyword, {int page = 1}) =>
      _page(sourceId, page);

  Future<SourcePageView> _page(String sourceId, int page) async {
    final _FakeSource f = _byId(sourceId);
    f.requested.add(page);
    if (f.failure != null) {
      throw PortUnavailableException(f.failure!, hint: '稍后重试');
    }
    return SourcePageView(
      items: f.pages[page] ?? const <SourceItemView>[],
      page: page,
      hasNext: f.pages.containsKey(page + 1),
      fetchedAt: DateTime(2026, 10, 12, 12),
    );
  }
}

SourceItemView item(
  String id, {
  String sourceId = 'a',
  String? infoHash,
  int? seeders,
  int? size,
  String? magnet,
  DateTime? at,
}) =>
    SourceItemView(
      id: id,
      sourceId: sourceId,
      title: id,
      infoHash: infoHash,
      seeders: seeders,
      sizeBytes: size,
      magnet: magnet,
      publishedAt: at,
      episodeHints: const <String>['01'],
    );

ProviderContainer _container(
  _FakeAggregatePort port, {
  SearchMode mode = SearchMode.aggregate,
  AppSettings? settings,
  InMemoryKeyValueStore? store,
  List<String> excludedSourceIds = const <String>[],
}) {
  final InMemoryKeyValueStore kv = store ??
      InMemoryKeyValueStore(<String, Object?>{
        SettingsController.storageKey: (settings ??
                AppSettings(
                  firstRunCompleted: true,
                  searchMode: mode,
                  defaultSourceId: 'a',
                  aggregateExcludedSourceIds: excludedSourceIds,
                ))
            .toJson(),
      });
  return ProviderContainer(
    overrides: [
      keyValueStoreProvider.overrideWithValue(kv),
      sourcePortProvider.overrideWithValue(port),
    ],
  );
}

void main() {
  group('默认聚合：一次搜索把这一档的源都问一遍', () {
    test('默认模式是聚合；「聚合」档把 anime + collection 都问了', () async {
      final _FakeSource a = _FakeSource(
        id: 'a',
        displayName: 'A 站',
        pages: <int, List<SourceItemView>>{
          1: <SourceItemView>[item('a:1', sourceId: 'a', at: DateTime.utc(2026, 10, 1))],
        },
      );
      final _FakeSource b = _FakeSource(
        id: 'b',
        displayName: 'B 站合集',
        partition: SourcePartition.collection,
        pages: <int, List<SourceItemView>>{
          1: <SourceItemView>[item('b:1', sourceId: 'b', at: DateTime.utc(2026, 10, 5))],
        },
      );
      final _FakeAggregatePort port = _FakeAggregatePort(<_FakeSource>[a, b]);
      final ProviderContainer c = _container(port);
      addTearDown(c.dispose);

      expect(c.read(searchProvider).mode, SearchMode.aggregate, reason: '默认聚合');
      expect(c.read(searchProvider).scope, SearchScope.all);
      expect(c.read(searchProvider).loaded, isFalse, reason: '默认不加载（第 8 轮定下的）');

      c.read(searchProvider.notifier).setKeyword('葬送的芙莉莲');
      await c.read(searchProvider.notifier).refresh();

      expect(a.requested, <int>[1]);
      expect(b.requested, <int>[1]);
      final SearchState state = c.read(searchProvider);
      expect(state.loaded, isTrue);
      expect(state.failure, isNull);
      // 新→旧：b 的 10-05 在 a 的 10-01 前面。
      expect(state.items.map((SourceItemView i) => i.id), <String>['b:1', 'a:1']);
    });

    test('「动漫」档不问合集源；「全集」档只问合集源', () async {
      final _FakeSource anime = _FakeSource(
        id: 'anime',
        displayName: '动漫站',
        pages: <int, List<SourceItemView>>{
          1: <SourceItemView>[item('anime:1', sourceId: 'anime')],
        },
      );
      final _FakeSource batch = _FakeSource(
        id: 'batch',
        displayName: '合集站',
        partition: SourcePartition.collection,
        pages: <int, List<SourceItemView>>{
          1: <SourceItemView>[item('batch:1', sourceId: 'batch')],
        },
      );
      final _FakeAggregatePort port = _FakeAggregatePort(<_FakeSource>[anime, batch]);
      final ProviderContainer c = _container(port);
      addTearDown(c.dispose);

      c.read(searchProvider.notifier).applyScopePreset(SearchScope.anime);
      c.read(searchProvider.notifier).setKeyword('x');
      await c.read(searchProvider.notifier).refresh();
      expect(anime.requested, <int>[1]);
      expect(batch.requested, isEmpty, reason: '「动漫」档不该问合集源');

      c.read(searchProvider.notifier).applyScopePreset(SearchScope.collection);
      await c.read(searchProvider.notifier).refresh();
      expect(batch.requested, <int>[1]);
      expect(anime.requested, <int>[1], reason: '「全集」档不该再去问动漫源');
      expect(c.read(searchProvider).fetched.map((SourceItemView i) => i.id), <String>['batch:1']);
    });

    test('「动漫」档里一个源都没有 → 预设被拒绝（勾选不变，也不会去搜）', () async {
      final _FakeSource batch = _FakeSource(
        id: 'batch',
        displayName: '合集站',
        partition: SourcePartition.collection,
        pages: <int, List<SourceItemView>>{1: <SourceItemView>[item('batch:1')]},
      );
      final ProviderContainer c = _container(_FakeAggregatePort(<_FakeSource>[batch]));
      addTearDown(c.dispose);

      // 第十五轮起「至少留一个源」对 chip 一样生效：点「动漫」不会有任何改变，
      // 更不会把源全排掉、让下一次搜索必然报错。
      expect(c.read(searchProvider.notifier).applyScopePreset(SearchScope.anime), isFalse);
      expect(c.read(searchProvider).excludedSourceIds, isEmpty);
      expect(c.read(searchProvider).scope, SearchScope.all);

      c.read(searchProvider.notifier).setKeyword('x');
      await c.read(searchProvider.notifier).refresh();
      final SearchState state = c.read(searchProvider);
      expect(state.failure, isNull);
      expect(batch.requested, <int>[1], reason: '还是原来那一档在搜（合集源）');
    });

    test('（防御）排除名单被写坏成一个源都不剩 → 明确的失败，不是空结果', () async {
      final _FakeSource batch = _FakeSource(
        id: 'batch',
        displayName: '合集站',
        partition: SourcePartition.collection,
        pages: <int, List<SourceItemView>>{1: <SourceItemView>[item('batch:1')]},
      );
      final ProviderContainer c = _container(_FakeAggregatePort(<_FakeSource>[batch]));
      addTearDown(c.dispose);

      // 正常界面到不了这里（面板与 chip 都挡着），但设置文件是可以被手改的。
      c.read(searchProvider.notifier).setExcludedSources(<String>{'batch'});
      c.read(searchProvider.notifier).setKeyword('x');
      await c.read(searchProvider.notifier).refresh();

      final SearchState state = c.read(searchProvider);
      expect(state.failure, isNotNull);
      expect(state.failure!.message, contains('一个源都没选中'));
      expect(state.fetched, isEmpty);
      expect(batch.requested, isEmpty);
    });
  });

  group('合并去重 + 排序（第一轮问答选定的那一档）', () {
    test('跨源同 infoHash 只留一条，留信息最全的；其余按时间新→旧', () async {
      final _FakeSource a = _FakeSource(
        id: 'a',
        displayName: 'A 站',
        pages: <int, List<SourceItemView>>{
          1: <SourceItemView>[
            item('a:thin', sourceId: 'a', infoHash: 'H1', at: DateTime.utc(2026, 10, 3)),
            item('a:old', sourceId: 'a', at: DateTime.utc(2026, 1, 1)),
          ],
        },
      );
      final _FakeSource b = _FakeSource(
        id: 'b',
        displayName: 'B 站',
        pages: <int, List<SourceItemView>>{
          1: <SourceItemView>[
            item('b:rich',
                sourceId: 'b',
                infoHash: 'H1',
                seeders: 30,
                size: 999,
                magnet: 'magnet:?xt=H1',
                at: DateTime.utc(2026, 10, 4)),
          ],
        },
      );
      final ProviderContainer c =
          _container(_FakeAggregatePort(<_FakeSource>[a, b]));
      addTearDown(c.dispose);

      c.read(searchProvider.notifier).setKeyword('x');
      await c.read(searchProvider.notifier).refresh();

      expect(
        c.read(searchProvider).fetched.map((SourceItemView i) => i.id),
        <String>['b:rich', 'a:old'],
        reason: 'H1 只留信息最全的那条（b:rich），整体按发布时间新→旧',
      );
    });

    test('翻页：第 2 页从每个源各要一页，并进同一个池子', () async {
      final _FakeSource a = _FakeSource(
        id: 'a',
        displayName: 'A 站',
        pages: <int, List<SourceItemView>>{
          // 每页 20 条：第 1 显示页正好用满，翻第 2 页才需要原始第 2 页。
          1: <SourceItemView>[for (int i = 0; i < 20; i++) item('a:$i', sourceId: 'a')],
          2: <SourceItemView>[for (int i = 20; i < 40; i++) item('a:$i', sourceId: 'a')],
        },
      );
      final ProviderContainer c = _container(_FakeAggregatePort(<_FakeSource>[a]));
      addTearDown(c.dispose);

      c.read(searchProvider.notifier).setKeyword('x');
      await c.read(searchProvider.notifier).refresh();
      expect(c.read(searchProvider).items.length, 20);

      await c.read(searchProvider.notifier).goToPage(2);
      expect(a.requested, <int>[1, 2]);
      expect(c.read(searchProvider).fetched.length, 40);
      expect(c.read(searchProvider).page, 2);
    });
  });

  group('失败语义：部分源挂了不影响其它源', () {
    test('一个源失败 → 结果照常显示 + 警告带点名（不是整页错误）', () async {
      final _FakeSource good = _FakeSource(
        id: 'good',
        displayName: '好站',
        pages: <int, List<SourceItemView>>{
          1: <SourceItemView>[item('good:1', sourceId: 'good')],
        },
      );
      final _FakeSource bad = _FakeSource(
        id: 'bad',
        displayName: '坏站',
        failure: '拉取超时',
        pages: const <int, List<SourceItemView>>{},
      );
      final ProviderContainer c =
          _container(_FakeAggregatePort(<_FakeSource>[good, bad]));
      addTearDown(c.dispose);

      c.read(searchProvider.notifier).setKeyword('x');
      await c.read(searchProvider.notifier).refresh();

      final SearchState state = c.read(searchProvider);
      expect(state.failure, isNull, reason: '还有源活着 → 不该整页报错');
      expect(state.aggregateWarning, contains('坏站'));
      expect(state.aggregateWarning, contains('拉取超时'));
      expect(state.aggregateWarning, contains('1/2'));
      expect(state.items.map((SourceItemView i) => i.id), <String>['good:1']);
    });

    test('全部源失败 → 整页错误（并且不再重复一条警告带）', () async {
      final _FakeSource a = _FakeSource(
        id: 'a',
        displayName: 'A 站',
        failure: '连不上',
        pages: const <int, List<SourceItemView>>{},
      );
      final ProviderContainer c = _container(_FakeAggregatePort(<_FakeSource>[a]));
      addTearDown(c.dispose);

      c.read(searchProvider.notifier).setKeyword('x');
      await c.read(searchProvider.notifier).refresh();

      final SearchState state = c.read(searchProvider);
      expect(state.failure, isNotNull);
      expect(state.failure!.message, contains('全都没回来'));
      expect(state.failure!.hint, contains('连不上'));
      expect(state.aggregateWarning, isNull, reason: '整页已经在说同一件事，别再挂一条警告带');
      expect(state.fetched, isEmpty);
    });
  });

  group('设置里切回单独源模式', () {
    test('单独源模式：只问默认源（老行为原样）', () async {
      final _FakeSource a = _FakeSource(
        id: 'a',
        displayName: 'A 站',
        pages: <int, List<SourceItemView>>{
          1: <SourceItemView>[item('a:1', sourceId: 'a')],
        },
      );
      final _FakeSource b = _FakeSource(
        id: 'b',
        displayName: 'B 站',
        pages: <int, List<SourceItemView>>{
          1: <SourceItemView>[item('b:1', sourceId: 'b')],
        },
      );
      final ProviderContainer c = _container(
        _FakeAggregatePort(<_FakeSource>[a, b]),
        mode: SearchMode.single,
      );
      addTearDown(c.dispose);

      expect(c.read(searchProvider).mode, SearchMode.single);
      c.read(searchProvider.notifier).setKeyword('x');
      await c.read(searchProvider.notifier).refresh();

      expect(a.requested, <int>[1]);
      expect(b.requested, isEmpty, reason: '单独源模式不许顺带问别的源');
      expect(c.read(searchProvider).items.map((SourceItemView i) => i.id), <String>['a:1']);
    });

    test('运行中切模式：已经搜过就按新模式重来一遍（结果属于旧模式不能留着）', () async {
      final _FakeSource a = _FakeSource(
        id: 'a',
        displayName: 'A 站',
        pages: <int, List<SourceItemView>>{
          1: <SourceItemView>[item('a:1', sourceId: 'a')],
        },
      );
      final _FakeSource b = _FakeSource(
        id: 'b',
        displayName: 'B 站',
        pages: <int, List<SourceItemView>>{
          1: <SourceItemView>[item('b:1', sourceId: 'b')],
        },
      );
      final ProviderContainer c =
          _container(_FakeAggregatePort(<_FakeSource>[a, b]));
      addTearDown(c.dispose);

      c.read(searchProvider.notifier).setKeyword('x');
      await c.read(searchProvider.notifier).refresh();
      expect(c.read(searchProvider).fetched.length, 2);

      c.read(searchProvider.notifier).setMode(SearchMode.single);
      // setMode 里是 unawaited(refresh())：等一拍让它跑完。
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      final SearchState state = c.read(searchProvider);
      expect(state.mode, SearchMode.single);
      expect(state.fetched.map((SourceItemView i) => i.id), <String>['a:1'],
          reason: '切回单独源后池子里只剩默认源的结果');
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // 第十五轮：勾选（用户原话「优化聚合搜索，默认全开，可选择几个源搜索，
  // 开启 sukebe 时也能勾选」）
  // ───────────────────────────────────────────────────────────────────────────
  group('勾选：默认全开 / 可只勾几个 / 记住', () {
    _FakeSource src(String id, SourcePartition partition, String title) => _FakeSource(
      id: id,
      displayName: title,
      partition: partition,
      pages: <int, List<SourceItemView>>{
        1: <SourceItemView>[item('$id:1', sourceId: id, at: DateTime.utc(2026, 10, 1))],
      },
    );

    test('默认全开：other 分区的 sukebei 也被问（第 14 轮它只在「聚合」档里出现，现在是一个开关）',
        () async {
      final _FakeSource a = src('a', SourcePartition.anime, 'A');
      final _FakeSource batch = src('batch', SourcePartition.collection, 'B');
      final _FakeSource suk = src('sukebei', SourcePartition.other, 'S');
      final ProviderContainer c =
          _container(_FakeAggregatePort(<_FakeSource>[a, batch, suk]));
      addTearDown(c.dispose);

      expect(c.read(searchProvider).excludedSourceIds, isEmpty, reason: '默认排除名单是空的 = 全开');
      expect(c.read(searchProvider).scope, SearchScope.all);

      c.read(searchProvider.notifier).setKeyword('x');
      await c.read(searchProvider.notifier).refresh();

      expect(a.requested, <int>[1]);
      expect(batch.requested, <int>[1]);
      expect(suk.requested, <int>[1], reason: 'sukebei 默认就勾着');
      expect(c.read(searchProvider).fetched.length, 3);
    });

    test('取消一个源：再搜不再问它，别的源照旧；档位变成「自定义」', () async {
      final _FakeSource a = src('a', SourcePartition.anime, 'A');
      final _FakeSource b = src('b', SourcePartition.anime, 'B');
      final _FakeSource c2 = src('c', SourcePartition.collection, 'C');
      final ProviderContainer c =
          _container(_FakeAggregatePort(<_FakeSource>[a, b, c2]));
      addTearDown(c.dispose);

      expect(c.read(searchProvider.notifier).toggleSource('b'), isTrue);
      expect(c.read(searchProvider).excludedSourceIds, <String>{'b'});
      expect(c.read(searchProvider).scope, isNull, reason: '手动改过 → 哪一档都不是');

      c.read(searchProvider.notifier).setKeyword('x');
      await c.read(searchProvider.notifier).refresh();
      expect(a.requested, <int>[1]);
      expect(c2.requested, <int>[1]);
      expect(b.requested, isEmpty, reason: '取消掉的源一次都不许问');
    });

    test('chip = 快捷全选：applyScopePreset(anime) 只勾动漫源（合集/sukebei 被排掉）', () async {
      final _FakeSource a = src('a', SourcePartition.anime, 'A');
      final _FakeSource batch = src('batch', SourcePartition.collection, 'B');
      final _FakeSource suk = src('sukebei', SourcePartition.other, 'S');
      final ProviderContainer c =
          _container(_FakeAggregatePort(<_FakeSource>[a, batch, suk]));
      addTearDown(c.dispose);

      expect(c.read(searchProvider.notifier).applyScopePreset(SearchScope.anime), isTrue);
      expect(c.read(searchProvider).scope, SearchScope.anime);
      expect(c.read(searchProvider).excludedSourceIds, <String>{'batch', 'sukebei'});

      c.read(searchProvider.notifier).setKeyword('x');
      await c.read(searchProvider.notifier).refresh();
      expect(a.requested, <int>[1]);
      expect(batch.requested, isEmpty);
      expect(suk.requested, isEmpty);

      // 再点「聚合」= 全勾回来。
      expect(c.read(searchProvider.notifier).applyScopePreset(SearchScope.all), isTrue);
      expect(c.read(searchProvider).excludedSourceIds, isEmpty);
      expect(c.read(searchProvider).scope, SearchScope.all);
    });

    test('预设一个源都不剩 → 拒绝（不改勾选、也不发请求）', () async {
      final _FakeSource batch = src('batch', SourcePartition.collection, 'B');
      final ProviderContainer c = _container(_FakeAggregatePort(<_FakeSource>[batch]));
      addTearDown(c.dispose);

      expect(c.read(searchProvider.notifier).applyScopePreset(SearchScope.anime), isFalse);
      expect(c.read(searchProvider).excludedSourceIds, isEmpty, reason: '什么都没改');
      expect(c.read(searchProvider).scope, SearchScope.all);
      expect(batch.requested, isEmpty);
    });

    test('至少留一个源：取消最后一个源被挡下，勾选一点没变', () {
      final _FakeSource a = src('a', SourcePartition.anime, 'A');
      final _FakeSource b = src('b', SourcePartition.anime, 'B');
      final ProviderContainer c = _container(_FakeAggregatePort(<_FakeSource>[a, b]));
      addTearDown(c.dispose);

      expect(c.read(searchProvider.notifier).toggleSource('b'), isTrue);
      expect(c.read(searchProvider.notifier).toggleSource('a'), isFalse,
          reason: 'a 是最后一个勾着的源');
      expect(c.read(searchProvider).excludedSourceIds, <String>{'b'});

      // 把它勾回来之后，取消 a 就可以（规则只看"取消之后还剩几个"）。
      expect(c.read(searchProvider.notifier).toggleSource('b'), isTrue);
      expect(c.read(searchProvider).excludedSourceIds, isEmpty);
      expect(c.read(searchProvider.notifier).toggleSource('a'), isTrue);
    });

    test('勾选写进设置：重启（同一个存储）之后照旧，搜索也只问记住的那几个', () async {
      final InMemoryKeyValueStore store = InMemoryKeyValueStore(<String, Object?>{
        SettingsController.storageKey: const AppSettings(
          firstRunCompleted: true,
          defaultSourceId: 'a',
        ).toJson(),
      });
      final _FakeSource a = src('a', SourcePartition.anime, 'A');
      final _FakeSource b = src('b', SourcePartition.anime, 'B');
      final _FakePortPair pair = _FakePortPair(a, b);

      final ProviderContainer c1 = _container(pair.port, store: store);
      c1.read(searchProvider.notifier).toggleSource('b');
      // _persistExclusions 是 unawaited 的：等一拍让它写盘。
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(
        AppSettings.fromJson(store.get(SettingsController.storageKey) as Map<Object?, Object?>?)
            .aggregateExcludedSourceIds,
        <String>['b'],
        reason: '勾选落进设置文件，不是只活在内存里',
      );
      c1.dispose();

      final _FakePortPair pair2 = _FakePortPair(a, b);
      final ProviderContainer c2 = _container(pair2.port, store: store);
      addTearDown(c2.dispose);
      expect(c2.read(searchProvider).excludedSourceIds, <String>{'b'},
          reason: '下次启动读设置 → 勾选被记住');
      c2.read(searchProvider.notifier).setKeyword('x');
      await c2.read(searchProvider.notifier).refresh();
      expect(pair2.a.requested, <int>[1]);
      expect(pair2.b.requested, isEmpty);
    });

    test('新出现的源默认算勾上（排除名单里没有它）', () async {
      // 设置里记着"不要 sukebei"，但这次源表里根本没有 sukebei（开关是关的）。
      final _FakeSource a = src('a', SourcePartition.anime, 'A');
      final _FakeSource nyaa = src('nyaa', SourcePartition.anime, 'N');
      final ProviderContainer c = _container(
        _FakeAggregatePort(<_FakeSource>[a, nyaa]),
        excludedSourceIds: <String>['sukebei'],
      );
      addTearDown(c.dispose);

      c.read(searchProvider.notifier).setKeyword('x');
      await c.read(searchProvider.notifier).refresh();
      expect(a.requested, <int>[1]);
      expect(nyaa.requested, <int>[1], reason: '注册表里的源没被排除过 → 默认勾上');
      expect(c.read(searchProvider).scope, SearchScope.all,
          reason: '排除名单里的 sukebei 已经不在注册表里，不该让「聚合」档看起来没选全');
    });
  });
}

/// 一对假源 + 它们的端口（持久化测试要拿两次容器，所以单独包一下）。
class _FakePortPair {
  _FakePortPair(this.a, this.b);

  final _FakeSource a;
  final _FakeSource b;

  _FakeAggregatePort get port => _FakeAggregatePort(<_FakeSource>[a, b]);
}
