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
///
/// 第五十一轮（用户：「动漫库种子块 1/7、2/7 个源没回来」，全是 DMHY）：DMHY 的关键字搜索
/// 是**整串 / 分词 AND 匹配**（`build/round51/dmhy-kw-matrix.txt`：全名 0 条、`无职转生`
/// 80/35 条），而全局阶梯「命中即停」让 DMHY 永远吃不到短名。所以自动阶梯多了一层
/// 「某个源**正常回 0 条** → 换短名补搜它一次」（`_FakeSources.noResultsSources` 模拟
/// DMHY 的"0 条也抛异常"；短名派生见 [shortenSeedQuery]）。
library;

import 'dart:async';

import 'package:dsanima/domain/aggregate.dart';
import 'package:dsanima/domain/bangumi.dart';
import 'package:dsanima/domain/library_seed.dart';
import 'package:dsanima/domain/models.dart';
import 'package:dsanima/domain/ports.dart';
import 'package:dsanima/domain/seed_language.dart';
import 'package:dsanima/domain/seed_version.dart';
import 'package:dsanima/domain/subtitle_groups.dart';
import 'package:dsanima/domain/unavailable.dart';
import 'package:dsanima/state/providers.dart';
import 'package:dsanima_core/sources/kv.dart' show InMemoryKeyValueStore;
import 'package:dsanima_core/sources/models.dart' show SourceNoResultsException;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

// ─────────────────────────────────────────────────────────────────────────────
// 测试替身
// ─────────────────────────────────────────────────────────────────────────────

/// 假源表：`hits['源:词']` 里有东西才算搜到（复现 mikan"整串匹配、不分词"）；
/// [failingSources] 里的源每次都抛（复现"某个站挂了"）；
/// [noResultsSources] 里的源在没命中时抛 `SourceNoResultsException`（复现 DMHY 的
/// 「0 条也报错」—— 第五十一轮的短名补搜要靠它区分"词不对"与"站挂了"）。
class _FakeSources extends UnavailableSourcePort {
  _FakeSources({
    this.hits = const <String, List<SourceItemView>>{},
    this.options = const <SourceOption>[
      SourceOption(id: 'mikan', displayName: 'Mikan（蜜柑计划）'),
      SourceOption(id: 'dmhy', displayName: '动漫花园（DMHY）'),
    ],
    this.failingSources = const <String>{},
    this.noResultsSources = const <String>{},
  });

  final Map<String, List<SourceItemView>> hits;
  final List<SourceOption> options;
  final Set<String> failingSources;
  final Set<String> noResultsSources;

  /// 记录每次搜索（`源:词`）——"命中即停"、阶梯试到哪一级、有没有补搜都靠它断言。
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
    final List<SourceItemView>? hit = hits['$sourceId:$keyword'];
    if (hit == null && noResultsSources.contains(sourceId)) {
      // 真机 DMHY 的「这一页 0 条」是**抛异常**（core 的 SourceNoResultsException），
      // 不是空列表 —— 第五十一轮补搜就是靠这个类型知道"该换短名再问一次"。
      throw SourceNoResultsException(
        '$sourceId 搜索「$keyword」没有结果（0 条）：'
        '站点页面是正常的（测试替身，模拟 DMHY 的整串 AND 匹配）',
        sourceId: sourceId,
      );
    }
    return SourcePageView(
      items: hit ?? const <SourceItemView>[],
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
  DateTime? publishedAt,
}) => SourceItemView(
  id: '$source:${_hash(n)}',
  sourceId: source,
  title: title,
  group: group,
  magnet: 'magnet:?xt=urn:btih:${_hash(n)}',
  infoHash: _hash(n),
  sizeBytes: 400 * 1024 * 1024,
  publishedAt: publishedAt ?? DateTime(2026, 10, 1).add(Duration(days: n)),
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

  // ── 第五十一轮（用户：「动漫库种子块 1/7、2/7 个源没回来」，全是 DMHY）──────────

  group('shortenSeedQuery：个别源「0 条」时补搜的短名', () {
    // 真机实测（`build/round51/dmhy-kw-matrix.txt`）：DMHY 的搜索是**整串 / 分词 AND
    // 匹配** —— 全名 0 条、短名有货。所以全名那一级要先能派生出短名。
    test('剥尾部副标题：`无职转生第三季～到了异世界就拿出真本事～` → `无职转生`', () {
      // 实测：全名在 sort_id=2 / 31 都是 0 条；`无职转生` 是 80 / 35 条。
      expect(shortenSeedQuery('无职转生第三季～到了异世界就拿出真本事～'), '无职转生');
      expect(shortenSeedQuery('无职转生第三季~到了异世界就拿出真本事~'), '无职转生');
    });

    test('剥尾部章节名 + 括号段：`…第2章「引き裂かれし翼竜」` → `コードギアス 亡国のアキト`', () {
      // 实测：整串 0 条；`コードギアス 亡国のアキト` 是 3 / 1 条、`亡国のアキト` 是 3 / 1 条。
      expect(
        shortenSeedQuery('コードギアス 亡国のアキト 第2章「引き裂かれし翼竜」'),
        'コードギアス 亡国のアキト',
      );
      expect(shortenSeedQuery('亡国のアキト 第2章'), '亡国のアキト');
      expect(shortenSeedQuery('某剧场版（前篇）'), '某剧场版');
    });

    test('尾部标点 / 空格也剥（`无职转生 第二季，` → `无职转生`）', () {
      expect(shortenSeedQuery('葬送的芙莉莲 第二季，'), '葬送的芙莉莲');
      expect(shortenSeedQuery('某番 - '), '某番', reason: '尾部标点在 DMHY 的 AND 匹配里就是白送一个不命中的词');
    });

    test('简单名字（短名 == 原名）→ null：这一层机制不许多打任何请求', () {
      expect(shortenSeedQuery('葬送的芙莉莲'), isNull);
      expect(shortenSeedQuery('Frieren'), isNull);
      expect(shortenSeedQuery(''), isNull);
      expect(shortenSeedQuery('～副标题～'), isNull, reason: '剥空了就不能拿去搜');
    });

    test('候选最多 2 个、按 中文名 → 原名 → 别名 的顺序、去重', () {
      final BangumiSubject subject = _subject(
        nameCn: '无职转生 第二季 ～到了异世界就拿出真本事～',
        name: '無職転生Ⅱ ～異世界行ったら本気だす～',
        aliases: <String>['无职转生', 'Mushoku Tensei II'],
      );
      expect(librarySeedShortQueries(subject), <String>['无职转生', '無職転生Ⅱ'],
          reason: '别名里的「无职转生」与中文名派生的同一个 → 去重；最多两个候选');
    });

    test('简单名字 / 没有长名的条目 → 空表（补搜一个请求都不发）', () {
      expect(
        librarySeedShortQueries(_subject(nameCn: '葬送的芙莉莲', name: '葬送的芙莉莲')),
        isEmpty,
      );
      expect(
        librarySeedShortQueries(
          const BangumiSubject(id: 1, name: 'Frieren', nameCn: 'Frieren'),
        ),
        isEmpty,
      );
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

    test('⚠️「未知组」永远排最后，哪怕它条数最多', () {
      final List<SeedGroup> groups = groupSeedItems(<SourceItemView>[
        // 杂项（解析不出组名）先给了 3 条，正常组只有 1 条 —— 条数排法会把杂项放首屏。
        for (int i = 1; i <= 3; i++)
          SourceItemView(
            id: 'mikan:x$i',
            sourceId: 'mikan',
            title: '葬送的芙莉莲 - 0$i',
          ),
        _item(9, '葬送的芙莉莲 - 01', group: '大组'),
      ]);
      expect(groups.last.key, kUnknownSubtitleGroupKey);
      expect(groups.last.count, 3, reason: '它确实是条数最多的那一段');
      expect(groups.first.label, '大组', reason: '有条理的那几家先摆出来');
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

    test('AGC.RIP 不在种子块的站点里（用户「去除 acg.rip 源」）', () async {
      final _FakeSources source = _FakeSources(
        options: const <SourceOption>[
          SourceOption(id: 'mikan', displayName: 'Mikan（蜜柑计划）'),
          SourceOption(id: 'acgrip', displayName: 'ACG.RIP · 动画'),
          SourceOption(id: 'dmhy', displayName: '动漫花园（DMHY）'),
        ],
        hits: <String, List<SourceItemView>>{
          'mikan:葬送的芙莉莲': <SourceItemView>[
            _item(1, '[桜都字幕组] 葬送的芙莉莲 - 01'),
          ],
          'dmhy:葬送的芙莉莲': <SourceItemView>[
            _item(2, '[LoliHouse] 葬送的芙莉莲 - 01', group: 'LoliHouse', source: 'dmhy'),
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

      expect(
        source.searched.where((String q) => q.startsWith('acgrip')),
        isEmpty,
        reason: '这一块不问 ACG.RIP：它不给 magnet，每条都要多打一次请求才算得出磁力',
      );
      expect(
        source.searched,
        <String>['mikan:葬送的芙莉莲', 'dmhy:葬送的芙莉莲'],
        reason: '其它站照旧一起搜',
      );
      expect(s.phase, LibrarySeedPhase.ready);
      expect(
        s.groups.map((SeedGroup g) => g.label),
        unorderedEquals(<String>['桜都字幕组', 'LoliHouse']),
      );
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

    test('字幕组先露 4 段；「展开一些」一次加 8 段（界面上是那颗 unfold_more 图标）', () async {
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

    test('「展开一些」一档一档加（4 → 12 → 全露），「收起字幕组」退回刚进页面的那 4 段', () async {
      final _FakeSources source = _FakeSources(
        hits: <String, List<SourceItemView>>{
          'mikan:葬送的芙莉莲': <SourceItemView>[
            for (int i = 1; i <= 20; i++)
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
      expect(c.read(librarySeedProvider).shownGroups, hasLength(kSeedVisibleGroups));

      // 第四十八轮·补五（用户「展开一些加回来」）：界面那颗 `unfold_more` 图标挂在这一档上 ——
      // 点一次多露 kSeedGroupsStep 个，**不是**一次全露（20 段要点两次）。
      // （它**不碰**每段自己的开合，那是界面上的 `_openGroups`，provider 这边看不见。）
      controller.showMoreGroups();
      final LibrarySeedState step1 = c.read(librarySeedProvider);
      expect(step1.shownGroups, hasLength(kSeedVisibleGroups + kSeedGroupsStep));
      expect(step1.remainingGroups, 20 - kSeedVisibleGroups - kSeedGroupsStep);

      controller.showMoreGroups();
      final LibrarySeedState all = c.read(librarySeedProvider);
      expect(all.shownGroups, hasLength(20));
      expect(all.remainingGroups, 0);

      // 全露之后再点一次是空操作（窗口不会被加到 28）。
      controller.showMoreGroups();
      expect(c.read(librarySeedProvider).shownGroups, hasLength(20));

      // 「一次全露」那个方法还在（界面不挂了，见它的注释）—— 留个口径：它一步到底。
      controller.collapseGroups();
      controller.showAllGroups();
      expect(c.read(librarySeedProvider).remainingGroups, 0);

      // 收起：一次回到刚进这一页的样子（不是退一档 —— 「展开一些加回来」只管展开那颗）；
      // 已经在默认窗口上时再收一次是空操作（不会把窗口收成 0 段）。
      controller.collapseGroups();
      final LibrarySeedState back = c.read(librarySeedProvider);
      expect(back.shownGroups, hasLength(kSeedVisibleGroups), reason: '收起字幕组 = 回到刚进这一页的样子');
      expect(back.remainingGroups, 20 - kSeedVisibleGroups);
      controller.collapseGroups();
      expect(c.read(librarySeedProvider).shownGroups, hasLength(kSeedVisibleGroups));
    });

    test('种子池按版本分开：本作进 groups，别的版本进 otherVersions（真标题）', () async {
      // 第四十八轮·补六（用户「详细页会搜到其他版本的，比如第二季 剧场版 番外等等」）：
      // 一条基础名一搜回来，S1 / S2 / S3 全混在一起（实测 mikan 基础名 1666 条）——
      // 这一层把"别的版本"分出去，**但一条都不丢**（进 otherVersions，界面上翻得到）。
      final _FakeSources source = _FakeSources(
        hits: <String, List<SourceItemView>>{
          'mikan:无职转生 第二季 ～到了异世界就拿出真本事～': <SourceItemView>[
            _item(
              1,
              '无职转生 第二季 ～到了异世界就拿出真本事～ - 01',
              publishedAt: DateTime.utc(2024, 4, 10),
            ),
            _item(
              2,
              '无职转生 第二季 ～到了异世界就拿出真本事～ - 02',
              publishedAt: DateTime.utc(2024, 4, 17),
            ),
            _item(
              3,
              '[绿茶字幕组] 无职转生 第三季 ～到了异世界就拿出真本事～ - 14',
              group: '绿茶字幕组',
              publishedAt: DateTime.utc(2026, 7, 10),
            ),
            _item(
              4,
              '無職転生Ⅲ ～異世界行ったら本気だす～ / 无职转生 第三季 - 01',
              group: '绿茶字幕组',
              publishedAt: DateTime.utc(2026, 7, 20),
            ),
            _item(
              5,
              '无职转生 ～到了异世界就拿出真本事～ - 05',
              publishedAt: DateTime.utc(2021, 2, 8),
            ),
            // 本作的**合集**（第四十八轮·补七：从本作单集里切出来，单独一页）。
            _item(
              6,
              '无职转生 第二季 ～到了异世界就拿出真本事～ [01-12 合集][1080p]',
              publishedAt: DateTime.utc(2024, 6, 20),
            ),
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

      await controller.resolve(
        _subject(
          nameCn: '无职转生 第二季 ～到了异世界就拿出真本事～',
          name: '無職転生Ⅱ ～異世界行ったら本気だす～',
          aliases: <String>['无职转生'],
          platform: 'TV',
          date: '2024-04-07',
          eps: 12,
        ),
      );
      final LibrarySeedState s = c.read(librarySeedProvider);

      expect(s.phase, LibrarySeedPhase.ready);
      // 本作**单集**：只有 S2 那两条（S1 的行按时间窗判成"更早的版本"，S3 按季号判走）。
      // 池子里是**新→旧**排过的（`aggregateSort`），所以 02 在 01 前面。
      expect(s.episodes.map((SourceItemView i) => i.title), <String>[
        '无职转生 第二季 ～到了异世界就拿出真本事～ - 02',
        '无职转生 第二季 ～到了异世界就拿出真本事～ - 01',
      ]);
      // 段也只算本作单集：「桜都字幕组（2 条）」不会把 S1 那条、合集那条算进去。
      expect(s.groups, hasLength(1));
      expect(s.groups.single.label, contains('桜都'));
      expect(s.groups.single.count, 2);
      // 本作的**合集**单独一页（补七）。
      expect(s.batchItems, hasLength(1));
      expect(s.batchItems.single.title, contains('合集'));
      expect(s.batchGroups.single.label, contains('桜都'));
      expect(s.batchGroups.single.count, 1);
      // 别的版本：按桶分好，桶里也按字幕组分段（界面直接画）。
      expect(s.otherVersions.map((SeedOtherBlock b) => b.label), <String>[
        '第三季',
        '更早的版本',
      ]);
      expect(s.otherVersions.first.count, 2);
      expect(s.otherVersions.first.groups.single.label, contains('绿茶'));
      expect(s.otherVersions.last.count, 1);
      expect(s.otherCount, 3);
      // 整池还在（勾选下载、手动锚点再合成要用它）：2 单集 + 1 合集 + 3 别的版本。
      expect(s.allItems, hasLength(6));
    });

    test('语言过滤：点一下只看简体、再点只看繁体、再点恢复（不重搜、整池不丢）', () async {
      // 第四十八轮·补九（用户「加入按钮，点一次只显示简体，再点一次只显示繁体，再点一次恢复」）：
      // 过滤只裁**显示的行**；版本归属、整池都不动（再点恢复靠整池重算）。
      final _FakeSources source = _FakeSources(
        hits: <String, List<SourceItemView>>{
          'mikan:无职转生 第二季 ～到了异世界就拿出真本事～': <SourceItemView>[
            _item(
              1,
              '无职转生 第二季 ～到了异世界就拿出真本事～ - 01 [1080p][简体内嵌]',
              publishedAt: DateTime.utc(2024, 4, 10),
            ),
            _item(
              2,
              '无职转生 第二季 ～到了异世界就拿出真本事～ - 01 [1080p][繁体内嵌]',
              publishedAt: DateTime.utc(2024, 4, 11),
            ),
            _item(
              3,
              '无职转生 第二季 ～到了异世界就拿出真本事～ - 01 [1080p][简繁内封]',
              publishedAt: DateTime.utc(2024, 4, 12),
            ),
            _item(
              4,
              '无职转生 第二季 ～到了异世界就拿出真本事～ - 02 [1080p][繁体内嵌]',
              group: 'LoliHouse',
              publishedAt: DateTime.utc(2024, 4, 13),
            ),
            _item(
              5,
              '[绿茶字幕组] 无职转生 第三季 ～到了异世界就拿出真本事～ - 14 [1080p][简体内嵌]',
              group: '绿茶字幕组',
              publishedAt: DateTime.utc(2026, 7, 10),
            ),
            _item(
              6,
              '[绿茶字幕组] 无职转生 第三季 ～到了异世界就拿出真本事～ - 15 [1080p][繁体内嵌]',
              group: '绿茶字幕组',
              publishedAt: DateTime.utc(2026, 7, 11),
            ),
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

      await controller.resolve(
        _subject(
          nameCn: '无职转生 第二季 ～到了异世界就拿出真本事～',
          name: '無職転生Ⅱ ～異世界行ったら本気だす～',
          aliases: <String>['无职转生'],
          platform: 'TV',
          date: '2024-04-07',
          eps: 12,
        ),
      );
      final LibrarySeedState all = c.read(librarySeedProvider);
      expect(all.language, SeedLanguage.all);
      expect(all.episodes, hasLength(4));
      expect(all.groups.map((SeedGroup g) => g.count), <int>[3, 1]);
      expect(all.otherCount, 2);
      expect(all.allItems, hasLength(6), reason: '整池');

      // ① 只看简体：简体内嵌 + 简繁内封（没标的 LoliHouse 那条不算）。
      controller.setSeedLanguage(SeedLanguage.simplified);
      final LibrarySeedState simplified = c.read(librarySeedProvider);
      expect(simplified.language, SeedLanguage.simplified);
      expect(
        simplified.episodes.map((SourceItemView i) => i.title),
        <String>[
          '无职转生 第二季 ～到了异世界就拿出真本事～ - 01 [1080p][简繁内封]',
          '无职转生 第二季 ～到了异世界就拿出真本事～ - 01 [1080p][简体内嵌]',
        ],
      );
      expect(simplified.groups.single.count, 2, reason: '段按过滤后的条目重算');
      expect(
        simplified.batchItems,
        isEmpty,
        reason: '补九前的那条合集没标语言 → 简档下不显示',
      );
      expect(
        simplified.otherVersions.single.items.single.title,
        contains('[简体内嵌]'),
        reason: '别的版本也跟着过滤（第三季只剩简体那条）',
      );
      expect(simplified.allItems, hasLength(6), reason: '整池不动：再点恢复要靠它');

      // ② 只看繁体：繁体内嵌 + 简繁内封（LoliHouse 那条也标了繁）。
      controller.setSeedLanguage(SeedLanguage.traditional);
      final LibrarySeedState traditional = c.read(librarySeedProvider);
      expect(
        traditional.episodes.map((SourceItemView i) => i.title),
        <String>[
          '无职转生 第二季 ～到了异世界就拿出真本事～ - 02 [1080p][繁体内嵌]',
          '无职转生 第二季 ～到了异世界就拿出真本事～ - 01 [1080p][简繁内封]',
          '无职转生 第二季 ～到了异世界就拿出真本事～ - 01 [1080p][繁体内嵌]',
        ],
      );
      expect(traditional.groups.map((SeedGroup g) => g.count), <int>[2, 1]);
      expect(traditional.otherCount, 1);

      // ③ 恢复全部：条数 / 段 / 别的版本全回来（过滤不是"删数据"）。
      controller.setSeedLanguage(SeedLanguage.all);
      final LibrarySeedState restored = c.read(librarySeedProvider);
      expect(restored.episodes, hasLength(4));
      expect(restored.groups.map((SeedGroup g) => g.count), <int>[3, 1]);
      expect(restored.otherCount, 2);
      expect(restored.allItems, hasLength(6));
    });

    test('「重新搜一遍」不忘掉语言过滤；换一部番才回到「全部」', () async {
      final _FakeSources source = _FakeSources(
        hits: <String, List<SourceItemView>>{
          'mikan:无职转生 第二季 ～到了异世界就拿出真本事～': <SourceItemView>[
            _item(
              1,
              '无职转生 第二季 ～到了异世界就拿出真本事～ - 01 [1080p][简体内嵌]',
              publishedAt: DateTime.utc(2024, 4, 10),
            ),
            _item(
              2,
              '无职转生 第二季 ～到了异世界就拿出真本事～ - 01 [1080p][繁体内嵌]',
              publishedAt: DateTime.utc(2024, 4, 11),
            ),
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
      final BangumiSubject subject = _subject(
        nameCn: '无职转生 第二季 ～到了异世界就拿出真本事～',
        name: '無職転生Ⅱ ～異世界行ったら本気だす～',
        platform: 'TV',
        date: '2024-04-07',
        eps: 12,
      );
      await controller.resolve(subject);
      controller.setSeedLanguage(SeedLanguage.simplified);
      expect(c.read(librarySeedProvider).episodes, hasLength(1));

      await controller.resolve(subject);
      expect(
        c.read(librarySeedProvider).language,
        SeedLanguage.simplified,
        reason: '重搜不该把用户挑的语言忘了',
      );
      expect(c.read(librarySeedProvider).episodes, hasLength(1));

      await controller.resolve(_subject(id: 1, nameCn: '别的番', name: 'Other'));
      expect(
        c.read(librarySeedProvider).language,
        SeedLanguage.all,
        reason: '换一部番就从「全部」开始，不拿上一部的过滤去套新番',
      );
    });

    test('本作一条都不剩时**不分**：整池还是本作，不许把页面弄空', () async {
      final _FakeSources source = _FakeSources(
        hits: <String, List<SourceItemView>>{
          'mikan:无职转生 第二季 ～到了异世界就拿出真本事～': <SourceItemView>[
            for (int i = 1; i <= 3; i++)
              _item(
                i,
                '无职转生 第三季 ～到了异世界就拿出真本事～ - 0$i',
                publishedAt: DateTime.utc(2026, 7, 10),
              ),
          ],
        },
      );
      final ProviderContainer c = _container(
        source: source,
        schedule: _FakeSchedule(const <String, BangumiDetailView>{}),
      );
      addTearDown(c.dispose);

      await c.read(librarySeedProvider.notifier).resolve(
        _subject(
          nameCn: '无职转生 第二季 ～到了异世界就拿出真本事～',
          name: '無職転生Ⅱ ～異世界行ったら本気だす～',
          aliases: <String>['无职转生'],
          platform: 'TV',
          date: '2024-04-07',
          eps: 12,
        ),
      );
      final LibrarySeedState s = c.read(librarySeedProvider);

      expect(s.otherVersions, isEmpty, reason: '全判成别的版本时宁可不分');
      expect(s.episodes, hasLength(3));
      expect(s.groups, isNotEmpty);
    });
  });

  // ── 第五十一轮（用户：「动漫库种子块 1/7、2/7 个源没回来」，全是 DMHY）──────────
  //
  // DMHY 的搜索是整串 AND 匹配：全名（带副标题/章节名）0 条、短名有货。全局阶梯是
  // "命中即停"，mikan 全名就中了 ⇒ DMHY 永远吃不到短名 ⇒ 被报成"源没回来"。
  // 修法：**只对回 0 条的源**、只用**自动阶梯**的轮次，换短名再问它一次。

  group('LibrarySeedController：某个源「0 条」→ 短名补搜（第五十一轮）', () {
    BangumiSubject uwSubject() => _subject(
      nameCn: '无职转生 第二季 ～到了异世界就拿出真本事～',
      name: '無職転生Ⅱ ～異世界行ったら本気だす～',
      aliases: <String>['无职转生'],
      platform: 'TV',
      date: '2024-04-07',
      eps: 12,
    );

    SourceItemView s2(
      int n, {
      String source = 'mikan',
      String group = '桜都字幕组',
    }) => _item(
      n,
      '无职转生 第二季 ～到了异世界就拿出真本事～ - 0$n [1080p]',
      group: group,
      source: source,
      publishedAt: DateTime.utc(2024, 4, 10).add(Duration(days: n)),
    );

    test('mikan 全名命中、DMHY 全名 0 条但短名有货 → DMHY 不再算"没回来"', () async {
      final _FakeSources source = _FakeSources(
        hits: <String, List<SourceItemView>>{
          'mikan:无职转生 第二季 ～到了异世界就拿出真本事～': <SourceItemView>[
            s2(1),
            s2(2),
          ],
          'dmhy:无职转生': <SourceItemView>[
            s2(9, source: 'dmhy', group: 'LoliHouse'),
          ],
        },
        noResultsSources: <String>{'dmhy'},
      );
      final ProviderContainer c = _container(
        source: source,
        schedule: _FakeSchedule(const <String, BangumiDetailView>{}),
      );
      addTearDown(c.dispose);

      await c.read(librarySeedProvider.notifier).resolve(uwSubject());
      final LibrarySeedState s = c.read(librarySeedProvider);

      expect(s.phase, LibrarySeedPhase.ready);
      expect(s.warning, isNull, reason: 'DMHY 用短名搜到了 → 不该再报"1/7 个源没回来"');
      expect(s.groups.map((SeedGroup g) => g.label), contains('LoliHouse'));
      expect(
        source.searched.first,
        'mikan:无职转生 第二季 ～到了异世界就拿出真本事～',
        reason: '阶梯第 1 级仍是全名；补搜只发生在那个源第一次回 0 条之后',
      );
      expect(source.searched, contains('dmhy:无职转生'), reason: 'DMHY 换了短名再问一次');
    });

    test('短名也全空 → 结果照常给，失败文案说明"也试过哪些短名，同样 0 条"', () async {
      final _FakeSources source = _FakeSources(
        hits: <String, List<SourceItemView>>{
          'mikan:无职转生 第二季 ～到了异世界就拿出真本事～': <SourceItemView>[s2(1)],
        },
        noResultsSources: <String>{'dmhy'},
      );
      final ProviderContainer c = _container(
        source: source,
        schedule: _FakeSchedule(const <String, BangumiDetailView>{}),
      );
      addTearDown(c.dispose);

      await c.read(librarySeedProvider.notifier).resolve(uwSubject());
      final LibrarySeedState s = c.read(librarySeedProvider);

      expect(s.phase, LibrarySeedPhase.ready, reason: 'mikan 的结果照常给');
      expect(s.warning, contains('短名'));
      expect(s.warning, contains('「无职转生」'));
      expect(s.warning, contains('同样 0 条'));
      expect(
        source.searched,
        contains('dmhy:無職転生Ⅱ'),
        reason: '两个候选都试过才放弃（第 2 个候选兜底中文短名在合集分区 0 条的情形）',
      );
    });

    test('不抛异常、只回空页的源也一样补搜（「0 条」有两种表现）', () async {
      final _FakeSources source = _FakeSources(
        hits: <String, List<SourceItemView>>{
          'mikan:无职转生 第二季 ～到了异世界就拿出真本事～': <SourceItemView>[s2(1)],
          'dmhy:无职转生': <SourceItemView>[
            s2(9, source: 'dmhy', group: 'LoliHouse'),
          ],
        },
        // dmhy 不在 noResultsSources 里：全名那一轮回的是**空表**（nyaa 这类源就是这样），
        // 不是异常 —— 第五十一轮把它和 DMHY 的「0 条异常」当成同一种情形处理。
      );
      final ProviderContainer c = _container(
        source: source,
        schedule: _FakeSchedule(const <String, BangumiDetailView>{}),
      );
      addTearDown(c.dispose);

      await c.read(librarySeedProvider.notifier).resolve(uwSubject());
      final LibrarySeedState s = c.read(librarySeedProvider);

      expect(s.phase, LibrarySeedPhase.ready);
      expect(s.warning, isNull);
      expect(source.searched, contains('dmhy:无职转生'));
      expect(s.groups.map((SeedGroup g) => g.label), contains('LoliHouse'));
    });

    test('网络失败 / 超时**不**补搜（那说明站挂了，不是词不对）', () async {
      final _FakeSources source = _FakeSources(
        failingSources: <String>{'dmhy'},
      );
      final ProviderContainer c = _container(
        source: source,
        schedule: _FakeSchedule(const <String, BangumiDetailView>{}),
      );
      addTearDown(c.dispose);

      await c.read(librarySeedProvider.notifier).resolve(uwSubject());

      expect(
        source.searched.where((String q) => q.startsWith('dmhy:')),
        hasLength(librarySeedQueries(uwSubject()).length),
        reason: '阶梯有几级就问几次；失败的那一轮一次都没补搜',
      );
    });

    test('手打的词不补搜（用户要搜的就是那个词，不静默换词）', () async {
      final _FakeSources source = _FakeSources(
        noResultsSources: <String>{'dmhy'},
      );
      final ProviderContainer c = _container(
        source: source,
        schedule: _FakeSchedule(const <String, BangumiDetailView>{}),
      );
      addTearDown(c.dispose);

      await c.read(librarySeedProvider.notifier).useQuery(uwSubject(), 'Frieren');
      final LibrarySeedState s = c.read(librarySeedProvider);

      expect(source.searched, <String>['mikan:Frieren', 'dmhy:Frieren']);
      expect(s.problem, LibrarySeedProblem.notFound);
    });

    test('简单名字（短名 == 原名）不多打任何请求', () async {
      final _FakeSources source = _FakeSources(
        noResultsSources: <String>{'dmhy'},
      );
      final ProviderContainer c = _container(
        source: source,
        schedule: _FakeSchedule(const <String, BangumiDetailView>{}),
      );
      addTearDown(c.dispose);

      await c.read(librarySeedProvider.notifier).resolve(
        _subject(nameCn: '葬送的芙莉莲', name: '葬送的芙莉莲'),
      );

      expect(source.searched, <String>['mikan:葬送的芙莉莲', 'dmhy:葬送的芙莉莲'],
          reason: '派生不出短名 → 一个额外请求都不发（阶梯只有一级）');
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

  group('seedSourceTargetsFor：种子块问哪些源', () {
    List<String> ids(List<SourceOption> all, {Set<String> excluded = const <String>{}}) =>
        seedSourceTargetsFor(all, excluded).map((SourceOption s) => s.id).toList();

    test('ACG.RIP 减掉，其它勾上的照旧（含合集分区那些）', () {
      expect(
        ids(const <SourceOption>[
          SourceOption(id: 'nyaa', displayName: 'Nyaa'),
          SourceOption(id: 'acgrip', displayName: 'ACG.RIP · 动画'),
          SourceOption(id: 'acgrip-batch', displayName: 'ACG.RIP · 合集'),
          SourceOption(id: 'dmhy-batch', displayName: '动漫花园 · 季度全集'),
        ]),
        <String>['nyaa', 'dmhy-batch'],
      );
    });

    test('搜索页的排除名单照旧生效（两道减法叠在一起）', () {
      expect(
        ids(
          const <SourceOption>[
            SourceOption(id: 'mikan', displayName: 'Mikan'),
            SourceOption(id: 'nyaa', displayName: 'Nyaa'),
            SourceOption(id: 'acgrip', displayName: 'ACG.RIP · 动画'),
          ],
          excluded: <String>{'nyaa'},
        ),
        <String>['mikan'],
      );
    });

    test('自定义 RSS 哪怕指向 acg.rip 也照问（那是用户自己加的）', () {
      expect(
        ids(const <SourceOption>[
          SourceOption(id: 'rss:8f3a', displayName: 'acg.rip'),
        ]),
        <String>['rss:8f3a'],
      );
    });

    test('不支持关键字搜索的源照旧排除（不是这一轮加的口径）', () {
      expect(
        ids(const <SourceOption>[
          SourceOption(id: 'mikan', displayName: 'Mikan'),
          SourceOption(id: 'rss:x', displayName: '订阅源', supportsSearch: false),
        ]),
        <String>['mikan'],
      );
    });
  });
}
