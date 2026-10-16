/// 动漫库「种子」块：领域规则 + 状态机。
///
/// 用户原话（第四十五轮）：「能实现动漫库中直接显示种子吗，就像主页那样」。
/// 用户原话（第四十八轮）：「我自己去 mikan 搜都搜索得到，这里就搜不到了，修复一下，
/// 然后改为主流搜索当引擎，按字幕组分隔，不同搜索引擎同名字就按合并」。
///
/// 第四十八轮换掉了引擎，所以这一份里能看到两代口径：
/// * **主路径**：番名阶梯 × 勾选的源（聚合搜）→ 名字命中判据 → 跨站同名合并 → 按字幕组分段；
/// * **手动**：粘 mikan 番剧页地址/id，把它并进池子（它给的是整部剧集表 + 每组 RSS）。
///
/// 真机口径的证据在 `build/round48/`：841 行 → 名字命中 841（用打分当判据会只剩 595，
/// 丢掉 KissSub 一整套 01–12）→ 同名合并 835 → **54 段**，中位数 3 条/段、最多 93 条/段。
library;

import 'dart:async';

import 'package:dsanima/domain/aggregate.dart';
import 'package:dsanima/domain/bangumi.dart';
import 'package:dsanima/domain/library_seed.dart';
import 'package:dsanima/domain/models.dart';
import 'package:dsanima/domain/ports.dart';
import 'package:dsanima/domain/subtitle_groups.dart';
import 'package:dsanima/domain/unavailable.dart';
import 'package:dsanima/state/providers.dart';
import 'package:dsanima_core/sources/kv.dart' show InMemoryKeyValueStore;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

// ─────────────────────────────────────────────────────────────────────────────
// 测试替身
// ─────────────────────────────────────────────────────────────────────────────

/// 假源表：`hits['源:词']` 里有东西才算搜到（复现 mikan"整串匹配、不分词"）；
/// [failingSources] 里的源每次都抛（复现"某个站挂了"）。
class _FakeSources extends UnavailableSourcePort {
  _FakeSources({
    this.hits = const <String, List<SourceItemView>>{},
    this.options = const <SourceOption>[
      SourceOption(id: 'mikan', displayName: 'Mikan（蜜柑计划）'),
      SourceOption(id: 'dmhy', displayName: '动漫花园（DMHY）'),
    ],
    this.failingSources = const <String>{},
  });

  final Map<String, List<SourceItemView>> hits;
  final List<SourceOption> options;
  final Set<String> failingSources;

  /// 记录每次搜索（`源:词`）——"命中即停"与"阶梯试到哪一级"都靠它断言。
  final List<String> searched = <String>[];

  @override
  List<SourceOption> get sources => options;

  @override
  Future<SourcePageView> latest(String sourceId, {int page = 1}) async =>
      SourcePageView(
        items: const <SourceItemView>[],
        page: page,
        hasNext: false,
        fetchedAt: DateTime(2026, 10, 16, 12),
      );

  @override
  Future<SourcePageView> search(
    String sourceId,
    String keyword, {
    int page = 1,
  }) async {
    searched.add('$sourceId:$keyword');
    if (failingSources.contains(sourceId)) {
      throw PortUnavailableException('源站 503', hint: '稍后重试');
    }
    return SourcePageView(
      items: hits['$sourceId:$keyword'] ?? const <SourceItemView>[],
      page: page,
      hasNext: false,
      fetchedAt: DateTime(2026, 10, 16, 12),
    );
  }
}

/// 假番剧端口：按 id 给整部剧集；[failure] 非空时每次都抛（复现 404 / 网络失败）。
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

SourceItemView _item(
  int n,
  String title, {
  String group = '桜都字幕组',
  String source = 'mikan',
}) => SourceItemView(
  id: '$source:${_hash(n)}',
  sourceId: source,
  title: title,
  group: group,
  magnet: 'magnet:?xt=urn:btih:${_hash(n)}',
  infoHash: _hash(n),
  sizeBytes: 400 * 1024 * 1024,
  publishedAt: DateTime(2026, 10, 1).add(Duration(days: n)),
  episodeHints: <String>['$n'],
);

BangumiDetailView _detail(
  String id,
  String title,
  List<SourceItemView> episodes,
) => BangumiDetailView(
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

/// 设置里那一条（`searchProvider` 会读它 —— 种子块的"问哪些源"就是它的勾选）。
AppSettings _settings({List<String> excluded = const <String>[]}) => AppSettings(
  firstRunCompleted: true,
  searchMode: SearchMode.aggregate,
  defaultSourceId: 'mikan',
  aggregateExcludedSourceIds: excluded,
);

InMemoryKeyValueStore _store([InMemoryKeyValueStore? given]) {
  if (given == null) {
    return InMemoryKeyValueStore(<String, Object?>{
      SettingsController.storageKey: _settings().toJson(),
    });
  }
  // 调用方自己建的 store（要预置绑定）：把设置补上，别让设置那一层退回"第一次启动"。
  unawaited(given.put(SettingsController.storageKey, _settings().toJson()));
  return given;
}

ProviderContainer _container({
  required _FakeSources source,
  required _FakeSchedule schedule,
  InMemoryKeyValueStore? store,
}) => ProviderContainer(
  overrides: [
    keyValueStoreProvider.overrideWithValue(_store(store)),
    sourcePortProvider.overrideWithValue(source),
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
      final BangumiSubject subject = _subject(
        nameCn: '',
        name: 'CLANNAD 〜AFTER STORY〜',
      );
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
      expect(
        dropSeasonSuffix('Re：从零开始的异世界生活 第二季 后半部分'),
        'Re：从零开始的异世界生活',
      );
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
      expect(seedTitleScore('[7³ACG] 葬送的芙莉莲 - 01 [1080p]', names), 100);
      expect(seedTitleScore('葬送的芙莉莲 特别篇', names), 60);
    });

    test('⚠️ 季号不同直接判 0（实测候选顺序不保证是目标那一季）', () {
      expect(seedTitleScore('进击的巨人 第二季', <String>['进击的巨人 第三季']), 0);
      expect(
        seedTitleScore('SPY×FAMILY Season 1', <String>['SPY×FAMILY Season 2']),
        0,
      );
    });

    test('不像的判 0', () {
      expect(seedTitleScore('完全无关的番', names), 0);
    });
  });

  // ── 第四十八轮：相关度判据（与打分函数刻意分开） ──────────────────────────────

  group('seedTitleMentions：相关度判据', () {
    const List<String> names = <String>['命运石之门', 'STEINS;GATE'];

    test('方括号里的名字也算命中（换成打分函数就漏了）', () {
      const String title =
          '[KissSub][Steins;Gate][命运石之门][12][GB_BIG5_JP][BDrip][1080P][HEVC] 静滞极限的教理';
      expect(seedTitleMentions(title, names), isTrue);
      expect(
        seedTitleScore(title, names),
        0,
        reason: '打分函数要剥方括号，名字装在方括号里就没了 —— 真机上 29% 是这么漏的',
      );
    });

    test('大小写 / 标点 / 全角都不影响', () {
      expect(seedTitleMentions('[组] steins gate 01', names), isTrue);
      expect(seedTitleMentions('[组] ＳＴＥＩＮＳ；ＧＡＴＥ 01', names), isTrue);
      expect(seedTitleMentions('完全无关的番', names), isFalse);
      expect(seedTitleMentions(null, names), isFalse);
    });

    test('一个字的名字不算命中（`零` 会捞回半个站）', () {
      expect(seedTitleMentions('[组] 零 01', <String>['零']), isFalse);
      expect(seedTitleMentions('[组] 零之使魔 01', <String>['零之使魔']), isTrue);
    });
  });

  // ── 第四十八轮：同一个名字在不同站出现就合成一条 ──────────────────────────────

  group('mergeSeedDuplicates：不同引擎同名字按合并', () {
    test('同一字幕组 + 同一标题（只差全角/空格）→ 并成一条，记下别的站', () {
      final SourceItemView a = _item(
        1,
        '[桜都字幕组] 葬送的芙莉莲 - 01 [1080p]',
        source: 'mikan',
      );
      final SourceItemView b = _item(
        9,
        '[桜都字幕组]　葬送的芙莉莲 － 01　［1080p］',
        source: 'dmhy',
      );
      expect(
        aggregateMerge(<SourceItemView>[a], <SourceItemView>[b]),
        hasLength(2),
        reason: '先过的是 infoHash 那一层：两个不同的种子文件，它管不着',
      );

      // 顺序照控制器来：先合并（保持到达顺序），最后才排序。
      final List<SourceItemView> merged = mergeSeedDuplicates(
        <SourceItemView>[a, b],
      );

      expect(merged, hasLength(1), reason: '同一家组发的同一条，并成一条');
      expect(merged.single.sourceId, 'mikan', reason: '信息一样 → 留先到的');
      expect(seedAlsoOn(merged.single), <String>['dmhy']);
    });

    test('⚠️ 同标题但**不同字幕组**不合并（那是两份不同的文件）', () {
      final SourceItemView a = _item(1, '葬送的芙莉莲 - 01', group: '桜都字幕组');
      final SourceItemView b = _item(
        9,
        '葬送的芙莉莲 - 01',
        group: 'LoliHouse',
        source: 'dmhy',
      );
      expect(mergeSeedDuplicates(<SourceItemView>[a, b]), hasLength(2));
    });

    test('没有标题的不合并（同一组里一堆"无标题"不许并成一条）', () {
      final SourceItemView a = SourceItemView(id: 'mikan:a', sourceId: 'mikan');
      final SourceItemView b = SourceItemView(id: 'dmhy:b', sourceId: 'dmhy');
      expect(mergeSeedDuplicates(<SourceItemView>[a, b]), hasLength(2));
    });

    test('留下的那条按"信息更全"选（与聚合搜索同一把尺子）', () {
      final SourceItemView poor = SourceItemView(
        id: 'mikan:a',
        sourceId: 'mikan',
        title: '葬送的芙莉莲 - 01',
        group: '桜都字幕组',
      );
      final SourceItemView rich = _item(9, '葬送的芙莉莲 - 01', source: 'dmhy');
      final List<SourceItemView> merged = mergeSeedDuplicates(
        <SourceItemView>[poor, rich],
      );
      expect(merged.single.sourceId, 'dmhy');
      expect(seedAlsoOn(merged.single), <String>['mikan']);
    });
  });

  // ── 第四十八轮：按字幕组分段 ─────────────────────────────────────────────────

  group('groupSeedItems：按字幕组分段', () {
    test('同一家组的不同写法归到一段（桜都字幕组 / 桜都字幕組 / 桜都）', () {
      final List<SeedGroup> groups = groupSeedItems(<SourceItemView>[
        _item(1, '葬送的芙莉莲 - 01', group: '桜都字幕组'),
        _item(2, '葬送的芙莉莲 - 02', group: '桜都字幕組', source: 'dmhy'),
        _item(3, '葬送的芙莉莲 - 03', group: '桜都', source: 'acgnx'),
      ]);
      expect(groups, hasLength(1));
      expect(groups.single.key, '桜都');
      expect(groups.single.label, '桜都字幕组', reason: '预置名单里有它，显示站点上那个写法');
      expect(groups.single.count, 3);
    });

    test('协作署名自成一段（`喵萌奶茶屋&LoliHouse` 不并进 `喵萌奶茶屋`）', () {
      final List<SeedGroup> groups = groupSeedItems(<SourceItemView>[
        _item(1, '葬送的芙莉莲 - 01', group: '喵萌奶茶屋'),
        _item(2, '葬送的芙莉莲 - 02', group: '喵萌奶茶屋&LoliHouse'),
        _item(3, '葬送的芙莉莲 - 03', group: 'LoliHouse'),
      ]);
      expect(groups.map((SeedGroup g) => g.label).toSet(), <String>{
        '喵萌奶茶屋',
        '喵萌奶茶屋&LoliHouse',
        'LoliHouse',
      });
      expect(
        groups.map((SeedGroup g) => g.count),
        everyElement(1),
        reason: '协作署名是**自己一段**：既没并进喵萌，也没并进 LoliHouse',
      );
    });

    test('组名解析不出来的落到「未知组」', () {
      final List<SeedGroup> groups = groupSeedItems(<SourceItemView>[
        SourceItemView(
          id: 'mikan:a',
          sourceId: 'mikan',
          title: '葬送的芙莉莲 - 01',
        ),
      ]);
      expect(groups.single.key, kUnknownSubtitleGroupKey);
      expect(groups.single.label, '未知组');
      expect(groups.single.isUnknown, isTrue);
    });

    test('条数多的段在前（平手按最新那条，再按组名）', () {
      final List<SeedGroup> groups = groupSeedItems(<SourceItemView>[
        _item(1, '葬送的芙莉莲 - 01', group: '小组'),
        _item(2, '葬送的芙莉莲 - 01', group: '大组', source: 'dmhy'),
        _item(3, '葬送的芙莉莲 - 02', group: '大组', source: 'dmhy'),
        _item(4, '葬送的芙莉莲 - 03', group: '大组', source: 'dmhy'),
      ]);
      expect(groups.map((SeedGroup g) => g.label), <String>['大组', '小组']);
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

  group('LibrarySeedController：引擎 = 勾选的那些主流站点', () {
    test('中文名一次命中 → 各站一起搜、按字幕组分段；**不再去猜 mikan 番剧页**', () async {
      final _FakeSources source = _FakeSources(
        hits: <String, List<SourceItemView>>{
          'mikan:葬送的芙莉莲': <SourceItemView>[
            _item(1, '[桜都字幕组] 葬送的芙莉莲 - 01 [1080p]'),
            _item(2, '[桜都字幕组] 葬送的芙莉莲 - 02 [1080p]'),
          ],
          'dmhy:葬送的芙莉莲': <SourceItemView>[
            _item(5, '[LoliHouse] 葬送的芙莉莲 - 01', group: 'LoliHouse', source: 'dmhy'),
          ],
        },
      );
      final _FakeSchedule schedule = _FakeSchedule(
        const <String, BangumiDetailView>{},
      );
      final ProviderContainer c = _container(source: source, schedule: schedule);
      addTearDown(c.dispose);

      await c.read(librarySeedProvider.notifier).resolve(_subject());
      final LibrarySeedState s = c.read(librarySeedProvider);

      expect(s.phase, LibrarySeedPhase.ready);
      expect(s.word, '葬送的芙莉莲', reason: '块上要显示"实际用的词"');
      expect(s.episodes, hasLength(3));
      expect(s.groups.map((SeedGroup g) => g.label), <String>['桜都字幕组', 'LoliHouse']);
      expect(s.groups.first.count, 2);
      expect(s.shownGroups, hasLength(2));
      expect(s.remainingGroups, 0);
      expect(
        source.searched,
        <String>['mikan:葬送的芙莉莲', 'dmhy:葬送的芙莉莲'],
        reason: '命中即停：不再试原名 / 别名 / 短名',
      );
      expect(schedule.asked, isEmpty, reason: '第四十八轮起不去猜番剧页（那正是病根）');
      expect(s.binding, isNull);
      expect(s.warning, isNull);
    });

    test('中文名 0 条 → 退到原名；命中即停', () async {
      final _FakeSources source = _FakeSources(
        hits: <String, List<SourceItemView>>{
          'mikan:Sousou no Frieren': <SourceItemView>[
            _item(1, '[桜都字幕组] Sousou no Frieren - 01'),
          ],
          'dmhy:Sousou no Frieren': <SourceItemView>[
            _item(2, '[LoliHouse] Sousou no Frieren - 01', group: 'LoliHouse', source: 'dmhy'),
          ],
        },
      );
      final ProviderContainer c = _container(
        source: source,
        schedule: _FakeSchedule(const <String, BangumiDetailView>{}),
      );
      addTearDown(c.dispose);

      await c.read(librarySeedProvider.notifier).resolve(_subject());
      final LibrarySeedState s = c.read(librarySeedProvider);

      expect(s.phase, LibrarySeedPhase.ready);
      expect(s.word, 'Sousou no Frieren');
      expect(source.searched, <String>[
        'mikan:葬送的芙莉莲',
        'dmhy:葬送的芙莉莲',
        'mikan:Sousou no Frieren',
        'dmhy:Sousou no Frieren',
      ]);
    });

    test('哪一级都没结果 → notFound，而不是"搜坏了"', () async {
      final _FakeSources source = _FakeSources();
      final ProviderContainer c = _container(
        source: source,
        schedule: _FakeSchedule(const <String, BangumiDetailView>{}),
      );
      addTearDown(c.dispose);

      await c.read(librarySeedProvider.notifier).resolve(_subject());
      final LibrarySeedState s = c.read(librarySeedProvider);

      expect(s.phase, LibrarySeedPhase.failed);
      expect(s.problem, LibrarySeedProblem.notFound);
      expect(
        source.searched,
        hasLength(librarySeedQueries(_subject()).length * 2),
        reason: '阶梯有哪几级就试哪几级 × 每个源',
      );
    });

    test('源站给了东西但没一条带这个名字 → 原样给用户（本地判据无权宣布"都没有"）', () async {
      final _FakeSources source = _FakeSources(
        hits: <String, List<SourceItemView>>{
          'mikan:葬送的芙莉莲': <SourceItemView>[
            _item(1, '[搬运] 完全对不上的东西 - 01'),
          ],
        },
      );
      final ProviderContainer c = _container(
        source: source,
        schedule: _FakeSchedule(const <String, BangumiDetailView>{}),
      );
      addTearDown(c.dispose);

      await c.read(librarySeedProvider.notifier).resolve(_subject());
      final LibrarySeedState s = c.read(librarySeedProvider);

      expect(s.phase, LibrarySeedPhase.ready);
      expect(s.episodes, hasLength(1));
      expect(s.word, '葬送的芙莉莲', reason: '四级都没命中名字，留在第一级那批上');
    });

    test('部分源挂了 → 结果照常给 + 警告带点名是哪几个', () async {
      final _FakeSources source = _FakeSources(
        hits: <String, List<SourceItemView>>{
          'mikan:葬送的芙莉莲': <SourceItemView>[
            _item(1, '[桜都字幕组] 葬送的芙莉莲 - 01'),
          ],
        },
        failingSources: <String>{'dmhy'},
      );
      final ProviderContainer c = _container(
        source: source,
        schedule: _FakeSchedule(const <String, BangumiDetailView>{}),
      );
      addTearDown(c.dispose);

      await c.read(librarySeedProvider.notifier).resolve(_subject());
      final LibrarySeedState s = c.read(librarySeedProvider);

      expect(s.phase, LibrarySeedPhase.ready);
      expect(s.warning, contains('动漫花园'));
      expect(s.warning, contains('503'));
    });

    test('全部源挂了 → network（整页错误，不是"空"）', () async {
      final _FakeSources source = _FakeSources(
        failingSources: <String>{'mikan', 'dmhy'},
      );
      final ProviderContainer c = _container(
        source: source,
        schedule: _FakeSchedule(const <String, BangumiDetailView>{}),
      );
      addTearDown(c.dispose);

      await c.read(librarySeedProvider.notifier).resolve(_subject());
      final LibrarySeedState s = c.read(librarySeedProvider);

      expect(s.phase, LibrarySeedPhase.failed);
      expect(s.problem, LibrarySeedProblem.network);
      expect(s.failure, isNotNull);
      expect(s.failure!.hint, contains('503'));
    });

    test('搜到了条目但一条能下的都没有 → noMagnet（另一种空）', () async {
      final SourceItemView dead = SourceItemView(
        id: 'mikan:${_hash(7)}',
        sourceId: 'mikan',
        title: '[桜都字幕组] 葬送的芙莉莲 - 07',
        group: '桜都字幕组',
        // 既没有磁力、也没有详情页可补链 ⇒ canDownload 为假。
      );
      final _FakeSources source = _FakeSources(
        hits: <String, List<SourceItemView>>{
          'mikan:葬送的芙莉莲': <SourceItemView>[dead],
        },
      );
      final ProviderContainer c = _container(
        source: source,
        schedule: _FakeSchedule(const <String, BangumiDetailView>{}),
      );
      addTearDown(c.dispose);

      await c.read(librarySeedProvider.notifier).resolve(_subject());
      final LibrarySeedState s = c.read(librarySeedProvider);

      expect(s.phase, LibrarySeedPhase.failed);
      expect(s.problem, LibrarySeedProblem.noMagnet);
      expect(s.episodes, hasLength(1), reason: '条目还是要留在那儿，好让用户看见是什么没源');
    });

    test('一个源都没勾（勾上的也都不支持搜索）→ network + 说清去哪儿勾', () async {
      final _FakeSources source = _FakeSources(
        options: const <SourceOption>[
          SourceOption(id: 'rss:x', displayName: '订阅源', supportsSearch: false),
        ],
      );
      final ProviderContainer c = _container(
        source: source,
        schedule: _FakeSchedule(const <String, BangumiDetailView>{}),
      );
      addTearDown(c.dispose);

      await c.read(librarySeedProvider.notifier).resolve(_subject());
      final LibrarySeedState s = c.read(librarySeedProvider);

      expect(s.problem, LibrarySeedProblem.network);
      expect(s.failure, isNotNull);
      expect(source.searched, isEmpty);
    });

    test('字幕组先露 4 段，「显示更多字幕组」一次加 8 段', () async {
      final _FakeSources source = _FakeSources(
        hits: <String, List<SourceItemView>>{
          'mikan:葬送的芙莉莲': <SourceItemView>[
            for (int i = 1; i <= 12; i++)
              _item(i, '[组$i] 葬送的芙莉莲 - 01', group: '组$i'),
          ],
        },
      );
      final ProviderContainer c = _container(
        source: source,
        schedule: _FakeSchedule(const <String, BangumiDetailView>{}),
      );
      addTearDown(c.dispose);
      final LibrarySeedController controller = c.read(
        librarySeedProvider.notifier,
      );

      await controller.resolve(_subject());
      final LibrarySeedState s = c.read(librarySeedProvider);
      expect(s.groups, hasLength(12));
      expect(s.shownGroups, hasLength(kSeedVisibleGroups));
      expect(s.remainingGroups, 12 - kSeedVisibleGroups);

      controller.showMoreGroups();
      final LibrarySeedState more = c.read(librarySeedProvider);
      expect(more.shownGroups, hasLength(kSeedVisibleGroups + kSeedGroupsStep));
      expect(more.remainingGroups, 0);
    });
  });

  group('LibrarySeedController：手动锚点（粘 mikan 番剧页）', () {
    test('粘地址：它的剧集并进池子、落盘记住、detail 留着（订阅要用它）', () async {
      final InMemoryKeyValueStore store = InMemoryKeyValueStore();
      final _FakeSources source = _FakeSources(
        hits: <String, List<SourceItemView>>{
          'mikan:葬送的芙莉莲': <SourceItemView>[
            _item(2, '[桜都字幕组] 葬送的芙莉莲 - 02'),
          ],
        },
      );
      final _FakeSchedule schedule = _FakeSchedule(<String, BangumiDetailView>{
        '3141': _detail('3141', '葬送的芙莉莲', <SourceItemView>[
          _item(1, '葬送的芙莉莲 - 01'),
          _item(3, '葬送的芙莉莲 - 03'),
        ]),
      });
      final ProviderContainer c = _container(
        source: source,
        schedule: schedule,
        store: store,
      );
      addTearDown(c.dispose);
      final LibrarySeedController controller = c.read(
        librarySeedProvider.notifier,
      );

      await controller.resolve(_subject());
      expect(c.read(librarySeedProvider).episodes, hasLength(1));

      await controller.bindRaw(_subject(), 'https://mikanani.me/Home/Bangumi/3141');
      final LibrarySeedState s = c.read(librarySeedProvider);

      expect(s.phase, LibrarySeedPhase.ready);
      expect(s.binding?.bangumiId, '3141');
      expect(s.detail?.bangumiId, '3141');
      expect(s.episodes, hasLength(3), reason: '搜索那一条 + 番剧页那两条');
      expect(s.groups.single.label, '桜都字幕组');
      expect(schedule.asked, <String>['3141']);
      expect(
        c.read(librarySeedServiceProvider).bindingFor(400602)?.bangumiId,
        '3141',
        reason: '落盘记住：下次进这一页不用再粘',
      );

      // 「重新搜一遍」要绕开 30 分钟缓存（番剧页重打一次），但**锚点不能丢** ——
      // 那是用户手动指的页面（第四十八轮修：旧写法在这里把锚点一起忘了）。
      await controller.retry();
      expect(schedule.asked, <String>['3141', '3141'], reason: 'force 绕开缓存');
      final LibrarySeedState again = c.read(librarySeedProvider);
      expect(again.binding?.bangumiId, '3141');
      expect(again.detail?.bangumiId, '3141', reason: '锚点还在，订阅按钮就还在');
      expect(again.episodes, hasLength(3));
    });

    test('记住的番剧页取不回来了 → 忘掉它 + 一句提示；搜索结果照常给', () async {
      final InMemoryKeyValueStore store = InMemoryKeyValueStore(
        <String, Object?>{
          '${LibrarySeedService.bindingPrefix}400602': const MikanSeedBinding(
            bangumiId: '9999',
            title: '旧的一页',
            query: '葬送的芙莉莲',
          ).toJson(),
        },
      );
      final _FakeSources source = _FakeSources(
        hits: <String, List<SourceItemView>>{
          'mikan:葬送的芙莉莲': <SourceItemView>[
            _item(1, '[桜都字幕组] 葬送的芙莉莲 - 01'),
          ],
        },
      );
      final _FakeSchedule schedule = _FakeSchedule(
        const <String, BangumiDetailView>{},
      )..failure = const PortUnavailableException('番剧页取不回来', hint: '稍后重试');
      final ProviderContainer c = _container(
        source: source,
        schedule: schedule,
        store: store,
      );
      addTearDown(c.dispose);

      await c.read(librarySeedProvider.notifier).resolve(_subject());
      final LibrarySeedState s = c.read(librarySeedProvider);

      expect(s.phase, LibrarySeedPhase.ready, reason: '番剧页挂了不该把整块拖垮');
      expect(schedule.asked, <String>['9999'], reason: '先试落盘的那个锚点');
      expect(s.binding, isNull);
      expect(s.warning, contains('取不回来'));
      expect(
        c.read(librarySeedServiceProvider).bindingFor(400602),
        isNull,
        reason: '取不回来就忘掉，下次别再为它多等一秒',
      );
    });

    test('粘一串不是 id 的东西 → badInput（不编一个 id 去搜）', () async {
      final _FakeSources source = _FakeSources();
      final ProviderContainer c = _container(
        source: source,
        schedule: _FakeSchedule(const <String, BangumiDetailView>{}),
      );
      addTearDown(c.dispose);

      await c.read(
        librarySeedProvider.notifier,
      ).bindRaw(_subject(), '这是番名不是 id');
      expect(c.read(librarySeedProvider).problem, LibrarySeedProblem.badInput);
      expect(source.searched, isEmpty);
    });
  });

  group('LibrarySeedController：改搜索词', () {
    test('只试手打的那一个词（失败不静默换词）', () async {
      final _FakeSources source = _FakeSources();
      final ProviderContainer c = _container(
        source: source,
        schedule: _FakeSchedule(const <String, BangumiDetailView>{}),
      );
      addTearDown(c.dispose);

      await c.read(librarySeedProvider.notifier).useQuery(_subject(), 'Frieren');
      final LibrarySeedState s = c.read(librarySeedProvider);

      expect(source.searched, <String>['mikan:Frieren', 'dmhy:Frieren']);
      expect(s.problem, LibrarySeedProblem.notFound);
      expect(s.word, 'Frieren');
    });

    test('手打的词有结果 → 直接出段', () async {
      final _FakeSources source = _FakeSources(
        hits: <String, List<SourceItemView>>{
          'mikan:Frieren': <SourceItemView>[
            _item(1, '[桜都字幕组] 葬送的芙莉莲 - 01'),
          ],
        },
      );
      final ProviderContainer c = _container(
        source: source,
        schedule: _FakeSchedule(const <String, BangumiDetailView>{}),
      );
      addTearDown(c.dispose);

      await c.read(librarySeedProvider.notifier).useQuery(_subject(), 'Frieren');
      final LibrarySeedState s = c.read(librarySeedProvider);

      expect(s.phase, LibrarySeedPhase.ready);
      expect(s.groups.single.label, '桜都字幕组');
    });
  });
}
