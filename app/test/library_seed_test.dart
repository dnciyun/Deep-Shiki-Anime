/// 动漫库「种子」块（第四十五轮）：领域规则 + 状态机。
///
/// 用户原话：「能实现动漫库中直接显示种子吗，就像主页那样」，问答里逐条定下：
/// * 主路径 = 按番名搜 mikan → 认番剧页 → 拿整部（字幕组 + 每集磁力），对应关系**落盘记住**；
/// * 查询词阶梯 = 中文名 → 原名 → 罗马字/英文别名 → 去季/部后缀的短名，**命中即停**；
/// * 候选番剧页**必须回验标题**（实测候选顺序不保证是目标那一季），拿不准就列出来让用户点；
/// * 落空 = **手动**「用其他源再搜一次」（不自动打聚合）；
/// * 三种空分开写；番剧页结果宿主侧缓存 30 分钟、失败不缓存。
library;

import 'package:dsanima/domain/bangumi.dart';
import 'package:dsanima/domain/library_seed.dart';
import 'package:dsanima/domain/models.dart';
import 'package:dsanima/domain/ports.dart';
import 'package:dsanima/domain/unavailable.dart';
import 'package:dsanima/state/providers.dart';
import 'package:dsanima_core/sources/kv.dart' show InMemoryKeyValueStore;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

// ─────────────────────────────────────────────────────────────────────────────
// 测试替身
// ─────────────────────────────────────────────────────────────────────────────

/// 假源：`mikanHits` 里的词能搜到（其余词 0 条），复现 mikan"整串匹配、不分词"。
class _FakeSources extends UnavailableSourcePort {
  _FakeSources({
    this.mikanHits = const <String, List<SourceItemView>>{},
    this.otherHits = const <String, List<SourceItemView>>{},
    this.options = const <SourceOption>[
      SourceOption(id: 'mikan', displayName: 'Mikan（蜜柑计划）'),
      SourceOption(id: 'dmhy', displayName: '动漫花园（DMHY）'),
    ],
  });

  final Map<String, List<SourceItemView>> mikanHits;
  final Map<String, List<SourceItemView>> otherHits;
  final List<SourceOption> options;

  /// 记录每次搜索（`源:词`），用来断言"命中即停"与"有没有乱打聚合"。
  final List<String> searched = <String>[];

  @override
  List<SourceOption> get sources => options;

  @override
  Future<SourcePageView> latest(String sourceId, {int page = 1}) async => SourcePageView(
    items: const <SourceItemView>[],
    page: page,
    hasNext: false,
    fetchedAt: DateTime(2026, 10, 16, 12),
  );

  @override
  Future<SourcePageView> search(String sourceId, String keyword, {int page = 1}) async {
    searched.add('$sourceId:$keyword');
    final Map<String, List<SourceItemView>> map =
        sourceId == 'mikan' ? mikanHits : otherHits;
    return SourcePageView(
      items: map[keyword] ?? const <SourceItemView>[],
      page: page,
      hasNext: false,
      fetchedAt: DateTime(2026, 10, 16, 12),
    );
  }
}

/// 假宿主数据层：**照真实现的契约来**。
///
/// ⚠️ 第四十七轮修的那条真机 bug 就死在"假契约"上，所以这里刻意把两条都建准：
/// * [episodeInfo] —— "去单集页认番剧页"，**不看有没有磁力**（真实现是
///   `MikanEpisodeParser` 认 `extra['bangumiId'] / ['bangumiTitle']`）；
/// * [ensurePlayable] —— "**缺磁力才补**，已经有磁力就一次网络都不打"
///   （`host_data.dart` 真实现的第一条）。旧版假实现这里无脑补 `bangumiId`，
///   于是"控制器错用了 `ensurePlayable`"在测试里永远看不见，真机上却全军覆没。
class _FakeHostData extends UnavailableHostDataPort {
  _FakeHostData(this.byItem);

  /// 条目 id → 这个条目所在的番剧页。
  final Map<String, ({String id, String title})> byItem;

  /// 真的去"单集页"取过信息的条目（= 打了几次网络）。
  final List<String> enriched = <String>[];

  /// `core.SourceItem.bestMagnet` 的等价判据（视图层没有这个 getter，见
  /// `core/lib/sources/models.dart:87`）：有 magnet 或能用 infoHash 拼出磁力。
  static bool _playableAlready(SourceItemView item) =>
      (item.magnet ?? '').isNotEmpty || (item.infoHash ?? '').isNotEmpty;

  @override
  Future<SourceItemView> episodeInfo(SourceItemView item) async {
    enriched.add(item.id);
    final ({String id, String title})? hit = byItem[item.id];
    if (hit == null) return item;
    return _withExtras(item, <String, Object?>{
      'bangumiId': hit.id,
      'bangumiTitle': hit.title,
    });
  }

  @override
  Future<SourceItemView> ensurePlayable(SourceItemView item) async =>
      _playableAlready(item) ? item : episodeInfo(item);

  static SourceItemView _withExtras(SourceItemView item, Map<String, Object?> extra) =>
      SourceItemView(
        id: item.id,
        sourceId: item.sourceId,
        title: item.title,
        detailUrl: item.detailUrl,
        torrentUrl: item.torrentUrl,
        magnet: item.magnet,
        infoHash: item.infoHash,
        sizeBytes: item.sizeBytes,
        publishedAt: item.publishedAt,
        group: item.group,
        episodeHints: item.episodeHints,
        extra: <String, Object?>{...item.extra, ...extra},
      );
}

/// 假番剧端口：按 id 给整部剧集；`failure` 非空时每次都抛（复现 404 / 网络失败）。
class _FakeSchedule extends UnavailableSchedulePort {
  _FakeSchedule(this.pages);

  final Map<String, BangumiDetailView> pages;
  final List<String> asked = <String>[];
  Object? failure;

  @override
  Future<BangumiDetailView> bangumi(String bangumiId) async {
    asked.add(bangumiId);
    if (failure != null) throw failure!;
    final BangumiDetailView? page = pages[bangumiId];
    if (page == null) {
      throw PortUnavailableException('没有这一页', hint: '换一个 id');
    }
    return page;
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 造数据
// ─────────────────────────────────────────────────────────────────────────────

String _hash(int n) => n.toRadixString(16).padLeft(40, '0');

SourceItemView _item(int n, String title, {String group = '桜都字幕组'}) =>
    SourceItemView(
      id: 'mikan:${_hash(n)}',
      sourceId: 'mikan',
      title: title,
      group: group,
      magnet: 'magnet:?xt=urn:btih:${_hash(n)}',
      infoHash: _hash(n),
      sizeBytes: 400 * 1024 * 1024,
      publishedAt: DateTime(2026, 10, 1).add(Duration(days: n)),
      episodeHints: <String>['$n'],
    );

BangumiDetailView _detail(String id, String title, List<SourceItemView> episodes) =>
    BangumiDetailView(
      bangumiId: id,
      title: title,
      groups: <BangumiGroupView>[
        BangumiGroupView(
          id: '1',
          name: '桜都字幕组',
          rssUrl: 'https://mikanani.me/RSS/Bangumi?bangumiId=$id&subgroupid=1',
        ),
      ],
      episodes: episodes,
    );

BangumiSubject _subject({
  int id = 400602,
  String? nameCn = '葬送的芙莉莲',
  String? name = 'Sousou no Frieren',
  List<String> aliases = const <String>[],
}) => BangumiSubject(
  id: id,
  name: name,
  nameCn: nameCn,
  infobox: aliases.isEmpty
      ? const <BangumiInfoboxItem>[]
      : <BangumiInfoboxItem>[BangumiInfoboxItem(key: '别名', values: aliases)],
);

ProviderContainer _container({
  required _FakeSources source,
  required _FakeHostData host,
  required _FakeSchedule schedule,
  InMemoryKeyValueStore? store,
}) => ProviderContainer(
  overrides: [
    keyValueStoreProvider.overrideWithValue(store ?? InMemoryKeyValueStore()),
    sourcePortProvider.overrideWithValue(source),
    hostDataPortProvider.overrideWithValue(host),
    schedulePortProvider.overrideWithValue(schedule),
  ],
);

void main() {
  group('librarySeedQueries：逐级退让的查询词', () {
    test('顺序 = 中文名 → 原名 → 罗马字/英文别名 → 去季/部后缀的短名', () {
      final BangumiSubject subject = _subject(
        nameCn: '间谍过家家 第2部分',
        name: 'SPY×FAMILY 第2クール',
        aliases: <String>['SPY×FAMILY Part 2', '间谍家家酒'],
      );
      expect(librarySeedQueries(subject), <String>[
        '间谍过家家 第2部分',
        'SPY×FAMILY 第2クール',
        'SPY×FAMILY Part 2',
        '间谍过家家', // 去季/部后缀的短名
      ]);
    });

    test('没有中文名（实测占条目池 8%）：第一格直接是原名，不出现空格子', () {
      final BangumiSubject subject = _subject(nameCn: '', name: 'CLANNAD 〜AFTER STORY〜');
      expect(librarySeedQueries(subject).first, 'CLANNAD 〜AFTER STORY〜');
    });

    test('最多四级（每一级都可能是一次网络）', () {
      final BangumiSubject subject = _subject(
        aliases: <String>['A', 'B', 'C', 'D', 'E'],
      );
      expect(librarySeedQueries(subject).length, kMaxLibrarySeedQueries);
    });

    test('别名只从 infobox 的「别名」行取', () {
      final BangumiSubject subject = BangumiSubject(
        id: 1,
        name: 'N',
        infobox: const <BangumiInfoboxItem>[
          BangumiInfoboxItem(key: '别名', values: <String>['Alias A']),
          BangumiInfoboxItem(key: '中文名', values: <String>['不该被当别名']),
        ],
      );
      expect(librarySeedAliases(subject), <String>['Alias A']);
    });
  });

  group('dropSeasonSuffix：mikan 整串匹配的救命稻草', () {
    test('中文季/部/期/后半部分都剥掉（可连续剥）', () {
      expect(dropSeasonSuffix('间谍过家家 第2部分'), '间谍过家家');
      expect(dropSeasonSuffix('Re：从零开始的异世界生活 第二季 后半部分'), 'Re：从零开始的异世界生活');
      expect(dropSeasonSuffix('某番 第三期'), '某番');
    });

    test('英文/日文形态也剥（Season 2 / Part 2 / S2 / 2nd Season）', () {
      expect(dropSeasonSuffix('Sousou no Frieren Season 2'), 'Sousou no Frieren');
      expect(dropSeasonSuffix('SPY×FAMILY Part 2'), 'SPY×FAMILY');
      expect(dropSeasonSuffix('Bocchi the Rock S2'), 'Bocchi the Rock');
      expect(dropSeasonSuffix('Mushoku Tensei 2nd Season'), 'Mushoku Tensei');
    });

    test('基础名本身就是空的 → null（不返回空串去搜）', () {
      expect(dropSeasonSuffix('第二季'), isNull);
      expect(dropSeasonSuffix(''), isNull);
      expect(dropSeasonSuffix(null), isNull);
    });

    test('没有季/部后缀时原样返回', () {
      expect(dropSeasonSuffix('葬送的芙莉莲'), '葬送的芙莉莲');
    });
  });

  group('seedTitleScore：同番判定', () {
    const List<String> names = <String>['葬送的芙莉莲', 'Sousou no Frieren'];

    test('完全同名 = 100', () {
      expect(seedTitleScore('葬送的芙莉莲', names), 100);
      expect(seedTitleScore('  【葬送的芙莉莲】 ', names), 100);
    });

    test('一边包含另一边 = 60；括号与集号尾标剥掉之后完全一样 = 100', () {
      expect(seedTitleScore('葬送的芙莉莲 第二季', names), 60);
      // 方括号里是组名/技术标签，剥掉 + 砍掉 `- 01` 之后**就是**同一个名字 → 100。
      expect(seedTitleScore('[7³ACG] 葬送的芙莉莲 - 01 [1080p]', names), 100);
      expect(seedTitleScore('葬送的芙莉莲 特别篇', names), 60);
    });

    test('⚠️ 季号不同直接判 0（实测候选顺序不保证是目标那一季）', () {
      expect(seedTitleScore('进击的巨人 第二季', <String>['进击的巨人 第三季']), 0);
      expect(seedTitleScore('SPY×FAMILY Season 1', <String>['SPY×FAMILY Season 2']), 0);
    });

    test('剥掉季/部后缀后一样 = 40（比"像"低一档，不足以自动绑定）', () {
      expect(seedTitleScore('葬送的芙莉莲 第一季', <String>['葬送的芙莉莲']), 60);
      expect(seedTitleScore('葬送的芙莉莲', <String>['葬送的芙莉莲 第一季']), 60);
      // 基础名相同但一边带季号：走"包含"那一档仍是 60；40 留给"两边都带季号且不同"之外的写法
      expect(seedTitleScore('完全无关的番', names), 0);
    });
  });

  group('parseMikanBangumiId / 绑定序列化', () {
    test('三种形态都收：纯 id / 站内路径 / 完整链接', () {
      expect(parseMikanBangumiId('2833'), '2833');
      expect(parseMikanBangumiId('/Home/Bangumi/2833'), '2833');
      expect(parseMikanBangumiId('https://mikanani.me/Home/Bangumi/2833'), '2833');
      expect(parseMikanBangumiId('https://mikanani.me/Home/Bangumi/2833?x=1'), '2833');
    });

    test('不是 id 的一律 null（不猜）', () {
      expect(parseMikanBangumiId('葬送的芙莉莲'), isNull);
      expect(parseMikanBangumiId(''), isNull);
      expect(parseMikanBangumiId('https://dmhy.org/topics/view/1.html'), isNull);
    });

    test('绑定 json 往返；缺 id 的坏数据返回 null', () {
      const MikanSeedBinding binding = MikanSeedBinding(
        bangumiId: '2833',
        title: '孤独摇滚！',
        query: '孤独摇滚',
      );
      final MikanSeedBinding? back = MikanSeedBinding.fromJson(binding.toJson());
      expect(back?.bangumiId, '2833');
      expect(back?.title, '孤独摇滚！');
      expect(back?.query, '孤独摇滚');
      expect(MikanSeedBinding.fromJson(<String, Object?>{'title': 'x'}), isNull);
    });
  });

  group('LibrarySeedController：主路径', () {
    test('中文名一次命中 + 标题完全一样 → 自动绑定并取回整部（1 搜 + 1 详情 + 1 番剧页）', () async {
      final _FakeSources source = _FakeSources(
        mikanHits: <String, List<SourceItemView>>{
          '葬送的芙莉莲': <SourceItemView>[_item(1, '[桜都字幕组] 葬送的芙莉莲 - 01 [1080p]')],
        },
      );
      final _FakeHostData host = _FakeHostData(<String, ({String id, String title})>{
        'mikan:${_hash(1)}': (id: '3141', title: '葬送的芙莉莲'),
      });
      final _FakeSchedule schedule = _FakeSchedule(<String, BangumiDetailView>{
        '3141': _detail('3141', '葬送的芙莉莲', <SourceItemView>[
          _item(1, '葬送的芙莉莲 - 01'),
          _item(2, '葬送的芙莉莲 - 02'),
        ]),
      });
      final ProviderContainer c = _container(
        source: source,
        host: host,
        schedule: schedule,
      );
      addTearDown(c.dispose);

      await c.read(librarySeedProvider.notifier).resolve(_subject());
      final LibrarySeedState s = c.read(librarySeedProvider);

      expect(s.phase, LibrarySeedPhase.ready);
      expect(s.binding?.bangumiId, '3141');
      expect(s.word, '葬送的芙莉莲', reason: '块上要显示"实际用的词"');
      expect(s.episodes, hasLength(2));
      expect(s.groupNames, <String>['桜都字幕组']);
      expect(source.searched, <String>['mikan:葬送的芙莉莲'], reason: '命中即停');
      expect(host.enriched, hasLength(1));
      expect(schedule.asked, <String>['3141']);
    });

    // ⚠️ 第四十七轮真机踩到的**整块失效**：真站上 mikan 搜索页的行天生带磁力
    // （`td[0]` 的 `input.js-episode-select[data-magnet]`），而这一条链要的番剧 id
    // **只在单集页里**。`ensurePlayable` 的契约是"缺磁力才补" ⇒ 它对这种行**一次网络
    // 都不打** ⇒ `extra['bangumiId']` 永远为空 ⇒ 1000 行一条候选都攒不出来，
    // 每部番都报"mikan 上没找到"（用户原话：「什么都搜不到了」）。
    test('带磁力的搜索行也要去单集页认番剧 id（不许踩 ensurePlayable 的短路）', () async {
      final _FakeSources source = _FakeSources(
        mikanHits: <String, List<SourceItemView>>{
          '葬送的芙莉莲': <SourceItemView>[
            _item(
              1,
              '[7³ACG] 葬送的芙莉莲/Sousou no Frieren S01 | 01-28+SPx11 [简繁字幕] BDrip 1080p',
            ),
          ],
        },
      );
      final _FakeHostData host = _FakeHostData(<String, ({String id, String title})>{
        'mikan:${_hash(1)}': (id: '3141', title: '葬送的芙莉莲'),
      });
      final ProviderContainer c = _container(
        source: source,
        host: host,
        schedule: _FakeSchedule(<String, BangumiDetailView>{
          '3141': _detail('3141', '葬送的芙莉莲', <SourceItemView>[_item(1, '葬送的芙莉莲 - 01')]),
        }),
      );
      addTearDown(c.dispose);

      await c.read(librarySeedProvider.notifier).resolve(_subject());
      final LibrarySeedState s = c.read(librarySeedProvider);

      expect(s.phase, LibrarySeedPhase.ready, reason: '"有磁力"不等于"不用去单集页"');
      expect(s.binding?.bangumiId, '3141');
      expect(host.enriched, hasLength(1), reason: '必须真的去单集页取过（episodeInfo）');
    });

    test('对照：ensurePlayable 的短路仍然成立（有磁力就一次网络都不打）', () async {
      final _FakeHostData host = _FakeHostData(<String, ({String id, String title})>{
        'mikan:${_hash(1)}': (id: '3141', title: '葬送的芙莉莲'),
      });
      final SourceItemView item = _item(1, '[桜都字幕组] 葬送的芙莉莲 - 01 [1080p]');

      final SourceItemView out = await host.ensurePlayable(item);

      expect(identical(out, item), isTrue, reason: '已经有磁力 → 原样返回');
      expect(host.enriched, isEmpty, reason: '一次网络都不打（搜索页那一大片真播/下载靠它）');
    });

    test('中文名 0 条 → 退到原名；不再往下试（命中即停）', () async {
      final _FakeSources source = _FakeSources(
        mikanHits: <String, List<SourceItemView>>{
          'Sousou no Frieren': <SourceItemView>[
            _item(1, '[桜都字幕组] Sousou no Frieren - 01'),
          ],
        },
      );
      final _FakeHostData host = _FakeHostData(<String, ({String id, String title})>{
        'mikan:${_hash(1)}': (id: '3141', title: 'Sousou no Frieren'),
      });
      final ProviderContainer c = _container(
        source: source,
        host: host,
        schedule: _FakeSchedule(<String, BangumiDetailView>{
          '3141': _detail('3141', 'Sousou no Frieren', <SourceItemView>[
            _item(1, 'Sousou no Frieren - 01'),
          ]),
        }),
      );
      addTearDown(c.dispose);

      await c.read(librarySeedProvider.notifier).resolve(_subject());
      final LibrarySeedState s = c.read(librarySeedProvider);

      expect(s.phase, LibrarySeedPhase.ready);
      expect(source.searched, <String>[
        'mikan:葬送的芙莉莲',
        'mikan:Sousou no Frieren',
      ]);
      expect(s.word, 'Sousou no Frieren');
    });

    test('两个候选同分 → 不自动绑，列出来让用户点（needsPick）', () async {
      final _FakeSources source = _FakeSources(
        mikanHits: <String, List<SourceItemView>>{
          '葬送的芙莉莲': <SourceItemView>[
            _item(1, '[组A] 葬送的芙莉莲 - 01'),
            _item(2, '[组B] 葬送的芙莉莲 - 02'),
          ],
        },
      );
      final _FakeHostData host = _FakeHostData(<String, ({String id, String title})>{
        'mikan:${_hash(1)}': (id: '111', title: '葬送的芙莉莲 特别篇'),
        'mikan:${_hash(2)}': (id: '222', title: '葬送的芙莉莲 剧场版'),
      });
      final _FakeSchedule schedule = _FakeSchedule(const <String, BangumiDetailView>{});
      final ProviderContainer c = _container(
        source: source,
        host: host,
        schedule: schedule,
      );
      addTearDown(c.dispose);

      await c.read(librarySeedProvider.notifier).resolve(_subject());
      final LibrarySeedState s = c.read(librarySeedProvider);

      expect(s.phase, LibrarySeedPhase.needsPick);
      // 同分时按"排在前面的是更近发布的那条"（`_seedRankMikan` 的次序），两条都列出来。
      expect(
        s.candidates.map((MikanSeedCandidate c) => c.bangumiId).toSet(),
        <String>{'111', '222'},
      );
      expect(schedule.asked, isEmpty, reason: '还没认下来，不该去取番剧页');
      expect(host.enriched, hasLength(2), reason: '最多试 kMaxLibrarySeedDetails 条');
    });

    test('一条都搜不到 → mikanNotFound，且**不自动**打聚合（用户选定手动）', () async {
      final _FakeSources source = _FakeSources(
        mikanHits: const <String, List<SourceItemView>>{},
        otherHits: <String, List<SourceItemView>>{
          '葬送的芙莉莲': <SourceItemView>[_item(9, '[别站] 葬送的芙莉莲 - 01')],
        },
      );
      final ProviderContainer c = _container(
        source: source,
        host: _FakeHostData(const <String, ({String id, String title})>{}),
        schedule: _FakeSchedule(const <String, BangumiDetailView>{}),
      );
      addTearDown(c.dispose);

      await c.read(librarySeedProvider.notifier).resolve(_subject());
      final LibrarySeedState s = c.read(librarySeedProvider);

      expect(s.phase, LibrarySeedPhase.failed);
      expect(s.problem, LibrarySeedProblem.mikanNotFound);
      expect(
        source.searched.every((String q) => q.startsWith('mikan:')),
        isTrue,
        reason: '落空只报空，不偷偷去打 8 个源',
      );
      expect(
        source.searched,
        hasLength(librarySeedQueries(_subject()).length),
        reason: '阶梯有哪几级就试哪几级',
      );
    });

    test('找到了番剧页但一集可下的都没有 → noMagnet（另一种空）', () async {
      final SourceItemView dead = SourceItemView(
        id: 'mikan:${_hash(7)}',
        sourceId: 'mikan',
        title: '葬送的芙莉莲 - 07',
        // 既没有磁力、也没有详情页可补链 ⇒ canDownload 为假。
      );
      final _FakeSources source = _FakeSources(
        mikanHits: <String, List<SourceItemView>>{
          '葬送的芙莉莲': <SourceItemView>[_item(1, '[桜都字幕组] 葬送的芙莉莲 - 01')],
        },
      );
      final ProviderContainer c = _container(
        source: source,
        host: _FakeHostData(<String, ({String id, String title})>{
          'mikan:${_hash(1)}': (id: '3141', title: '葬送的芙莉莲'),
        }),
        schedule: _FakeSchedule(<String, BangumiDetailView>{
          '3141': _detail('3141', '葬送的芙莉莲', <SourceItemView>[dead]),
        }),
      );
      addTearDown(c.dispose);

      await c.read(librarySeedProvider.notifier).resolve(_subject());
      final LibrarySeedState s = c.read(librarySeedProvider);

      expect(s.problem, LibrarySeedProblem.noMagnet);
      expect(s.detail?.bangumiId, '3141', reason: '页面确实拿到了，只是没有磁力');
    });
  });

  group('LibrarySeedController：落盘绑定与缓存', () {
    test('记住绑定 + 30 分钟缓存：第二次进来一次网络都不打', () async {
      final InMemoryKeyValueStore store = InMemoryKeyValueStore();
      final _FakeSources source = _FakeSources(
        mikanHits: <String, List<SourceItemView>>{
          '葬送的芙莉莲': <SourceItemView>[_item(1, '[桜都字幕组] 葬送的芙莉莲 - 01')],
        },
      );
      final _FakeHostData host = _FakeHostData(<String, ({String id, String title})>{
        'mikan:${_hash(1)}': (id: '3141', title: '葬送的芙莉莲'),
      });
      final _FakeSchedule first = _FakeSchedule(<String, BangumiDetailView>{
        '3141': _detail('3141', '葬送的芙莉莲', <SourceItemView>[_item(1, '葬送的芙莉莲 - 01')]),
      });
      final ProviderContainer c1 = _container(
        source: source,
        host: host,
        schedule: first,
        store: store,
      );
      addTearDown(c1.dispose);
      await c1.read(librarySeedProvider.notifier).resolve(_subject());
      expect(c1.read(librarySeedProvider).phase, LibrarySeedPhase.ready);

      // 新容器 = 重进这一页（同一个 store）。
      final _FakeSources source2 = _FakeSources();
      final _FakeSchedule second = _FakeSchedule(<String, BangumiDetailView>{
        '3141': _detail('3141', '葬送的芙莉莲', <SourceItemView>[_item(2, '葬送的芙莉莲 - 02')]),
      });
      final ProviderContainer c2 = _container(
        source: source2,
        host: _FakeHostData(const <String, ({String id, String title})>{}),
        schedule: second,
        store: store,
      );
      addTearDown(c2.dispose);
      await c2.read(librarySeedProvider.notifier).resolve(_subject());
      final LibrarySeedState s2 = c2.read(librarySeedProvider);

      expect(s2.phase, LibrarySeedPhase.ready);
      expect(s2.binding?.bangumiId, '3141');
      expect(source2.searched, isEmpty, reason: '绑定落盘了，不用再按番名搜');
      expect(
        second.asked,
        <String>['3141'],
        reason: '换进程之后番剧页要重打一次（那份缓存是进程内的，只有绑定落盘）',
      );

      // 同一次运行里再进一遍：绑定 + 番剧页缓存都命中 → 一次网络都不打。
      await c2.read(librarySeedProvider.notifier).resolve(_subject());
      expect(second.asked, <String>['3141'], reason: '30 分钟内同一部不重打');
    });

    test('绑定失效（番剧页 404）→ 自动重搜一次，仍失败则报网络', () async {
      final InMemoryKeyValueStore store = InMemoryKeyValueStore();
      await store.put(
        '${LibrarySeedService.bindingPrefix}400602',
        const MikanSeedBinding(bangumiId: '9999', title: '旧的一页', query: '葬送的芙莉莲').toJson(),
      );
      final _FakeSources source = _FakeSources(
        mikanHits: <String, List<SourceItemView>>{
          '葬送的芙莉莲': <SourceItemView>[_item(1, '[桜都字幕组] 葬送的芙莉莲 - 01')],
        },
      );
      final _FakeSchedule schedule = _FakeSchedule(<String, BangumiDetailView>{})
        ..failure = const PortUnavailableException('mikan 番剧页取不回来', hint: '稍后重试');
      final ProviderContainer c = _container(
        source: source,
        host: _FakeHostData(const <String, ({String id, String title})>{}),
        schedule: schedule,
        store: store,
      );
      addTearDown(c.dispose);

      await c.read(librarySeedProvider.notifier).resolve(_subject());
      final LibrarySeedState s = c.read(librarySeedProvider);

      expect(schedule.asked, <String>['9999'], reason: '先试落盘的那份绑定');
      expect(source.searched, isNotEmpty, reason: '绑定取不回来 → 自动重搜一次');
      expect(s.problem, LibrarySeedProblem.network);
      expect(s.failure, isNotNull);
    });

    test('绑定里的 id 已经不指向这一部（站点换页）→ 丢掉绑定重新按番名找', () async {
      final InMemoryKeyValueStore store = InMemoryKeyValueStore();
      await store.put(
        '${LibrarySeedService.bindingPrefix}400602',
        const MikanSeedBinding(bangumiId: '9999', title: '别的番', query: '别的番').toJson(),
      );
      final _FakeSources source = _FakeSources(
        mikanHits: <String, List<SourceItemView>>{
          '葬送的芙莉莲': <SourceItemView>[_item(1, '[桜都字幕组] 葬送的芙莉莲 - 01')],
        },
      );
      final ProviderContainer c = _container(
        source: source,
        host: _FakeHostData(<String, ({String id, String title})>{
          'mikan:${_hash(1)}': (id: '3141', title: '葬送的芙莉莲'),
        }),
        schedule: _FakeSchedule(<String, BangumiDetailView>{
          '9999': _detail('9999', '完全无关的另一部番', <SourceItemView>[_item(3, '别的番 - 01')]),
          '3141': _detail('3141', '葬送的芙莉莲', <SourceItemView>[_item(1, '葬送的芙莉莲 - 01')]),
        }),
        store: store,
      );
      addTearDown(c.dispose);

      await c.read(librarySeedProvider.notifier).resolve(_subject());
      final LibrarySeedState s = c.read(librarySeedProvider);

      expect(s.phase, LibrarySeedPhase.ready);
      expect(s.binding?.bangumiId, '3141');
      expect(source.searched, isNotEmpty, reason: '绑定被否掉了，必须重新按番名搜');
    });

    test('「重新搜一次」绕过缓存（force）：番剧页再打一次', () async {
      final _FakeSources source = _FakeSources(
        mikanHits: <String, List<SourceItemView>>{
          '葬送的芙莉莲': <SourceItemView>[_item(1, '[桜都字幕组] 葬送的芙莉莲 - 01')],
        },
      );
      final _FakeHostData host = _FakeHostData(<String, ({String id, String title})>{
        'mikan:${_hash(1)}': (id: '3141', title: '葬送的芙莉莲'),
      });
      final _FakeSchedule schedule = _FakeSchedule(<String, BangumiDetailView>{
        '3141': _detail('3141', '葬送的芙莉莲', <SourceItemView>[_item(1, '葬送的芙莉莲 - 01')]),
      });
      final ProviderContainer c = _container(
        source: source,
        host: host,
        schedule: schedule,
      );
      addTearDown(c.dispose);
      final LibrarySeedController controller = c.read(librarySeedProvider.notifier);

      await controller.resolve(_subject());
      expect(schedule.asked, hasLength(1));
      await controller.retry();
      expect(schedule.asked, hasLength(2), reason: 'force 要绕过 30 分钟缓存');
      expect(source.searched, hasLength(2), reason: 'force 也要绕过绑定');
    });
  });

  group('LibrarySeedController：手动兜底与其它动作', () {
    test('「用其他源再搜一次」：合并去重、按时间新→旧、标出这是聚合结果', () async {
      final _FakeSources source = _FakeSources(
        options: const <SourceOption>[
          SourceOption(id: 'mikan', displayName: 'Mikan（蜜柑计划）'),
          SourceOption(id: 'dmhy', displayName: '动漫花园（DMHY）'),
        ],
        mikanHits: <String, List<SourceItemView>>{
          '葬送的芙莉莲': <SourceItemView>[],
        },
        otherHits: <String, List<SourceItemView>>{
          '葬送的芙莉莲': <SourceItemView>[
            _item(5, '[A] 葬送的芙莉莲 - 05'),
            _item(6, '[A] 葬送的芙莉莲 - 06'),
          ],
        },
      );
      final ProviderContainer c = _container(
        source: source,
        host: _FakeHostData(const <String, ({String id, String title})>{}),
        schedule: _FakeSchedule(const <String, BangumiDetailView>{}),
      );
      addTearDown(c.dispose);
      final LibrarySeedController controller = c.read(librarySeedProvider.notifier);

      await controller.resolve(_subject());
      expect(c.read(librarySeedProvider).phase, LibrarySeedPhase.failed);

      await controller.searchEverywhere(_subject());
      final LibrarySeedState s = c.read(librarySeedProvider);
      expect(s.phase, LibrarySeedPhase.ready);
      expect(s.fromAggregate, isTrue);
      expect(s.episodes, hasLength(2));
      expect(s.groupNames, isEmpty, reason: '聚合结果没有 mikan 的字幕组结构');
      expect(source.searched, contains('dmhy:葬送的芙莉莲'));
    });

    test('聚合兜底也 0 条 → allSourcesEmpty（冷门番那一档）', () async {
      final _FakeSources source = _FakeSources();
      final ProviderContainer c = _container(
        source: source,
        host: _FakeHostData(const <String, ({String id, String title})>{}),
        schedule: _FakeSchedule(const <String, BangumiDetailView>{}),
      );
      addTearDown(c.dispose);
      final LibrarySeedController controller = c.read(librarySeedProvider.notifier);

      await controller.searchEverywhere(_subject());
      final LibrarySeedState s = c.read(librarySeedProvider);
      expect(s.phase, LibrarySeedPhase.failed);
      expect(s.problem, LibrarySeedProblem.allSourcesEmpty);
    });

    test('「改搜索词重搜」只试手打的那一个词（失败不静默换词）', () async {
      final _FakeSources source = _FakeSources(
        mikanHits: const <String, List<SourceItemView>>{},
      );
      final ProviderContainer c = _container(
        source: source,
        host: _FakeHostData(const <String, ({String id, String title})>{}),
        schedule: _FakeSchedule(const <String, BangumiDetailView>{}),
      );
      addTearDown(c.dispose);

      await c.read(librarySeedProvider.notifier).useQuery(_subject(), 'Frieren');
      expect(source.searched, <String>['mikan:Frieren']);
      expect(c.read(librarySeedProvider).problem, LibrarySeedProblem.mikanNotFound);
    });

    test('粘一串不是 id 的东西 → badInput（不编一个 id 去搜）', () async {
      final _FakeSources source = _FakeSources();
      final ProviderContainer c = _container(
        source: source,
        host: _FakeHostData(const <String, ({String id, String title})>{}),
        schedule: _FakeSchedule(const <String, BangumiDetailView>{}),
      );
      addTearDown(c.dispose);

      await c.read(librarySeedProvider.notifier).bindRaw(_subject(), '这是番名不是 id');
      expect(c.read(librarySeedProvider).problem, LibrarySeedProblem.badInput);
      expect(source.searched, isEmpty);
    });

    test('挑候选 / 显示更多', () async {
      // 搜索只给两条候选（两条标题都像、分数打平 → needsPick）；
      // 「显示更多」验的是番剧页那 25 集只先露 20 条。
      final _FakeSources source = _FakeSources(
        mikanHits: <String, List<SourceItemView>>{
          '葬送的芙莉莲': <SourceItemView>[
            _item(1, '[组A] 葬送的芙莉莲 - 01'),
            _item(2, '[组B] 葬送的芙莉莲 - 02'),
          ],
        },
      );
      final _FakeHostData host = _FakeHostData(<String, ({String id, String title})>{
        'mikan:${_hash(1)}': (id: '111', title: '葬送的芙莉莲 特别篇'),
        'mikan:${_hash(2)}': (id: '222', title: '葬送的芙莉莲 剧场版'),
      });
      final _FakeSchedule schedule = _FakeSchedule(<String, BangumiDetailView>{
        '222': _detail('222', '葬送的芙莉莲 剧场版', <SourceItemView>[
          for (int i = 1; i <= 25; i++) _item(i, '葬送的芙莉莲 - $i'),
        ]),
      });
      final ProviderContainer c = _container(
        source: source,
        host: host,
        schedule: schedule,
      );
      addTearDown(c.dispose);
      final LibrarySeedController controller = c.read(librarySeedProvider.notifier);

      await controller.resolve(_subject());
      final LibrarySeedState picked = c.read(librarySeedProvider);
      expect(picked.phase, LibrarySeedPhase.needsPick);

      await controller.pickCandidate(_subject(), picked.candidates.firstWhere(
        (MikanSeedCandidate x) => x.bangumiId == '222',
      ));
      final LibrarySeedState ready = c.read(librarySeedProvider);
      expect(ready.phase, LibrarySeedPhase.ready);
      expect(ready.binding?.bangumiId, '222');
      expect(ready.shown, hasLength(kSeedVisibleStep), reason: '先露 20 条');
      expect(ready.remaining, 5);

      controller.showMore();
      expect(c.read(librarySeedProvider).shown, hasLength(25));
      expect(c.read(librarySeedProvider).remaining, 0);
    });
  });
}
