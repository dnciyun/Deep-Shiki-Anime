/// dmhy（动漫花园）源单测：列表页解析、磁力规范化、分页语义、URL 形态。
///
/// 全部离线；fixture 是 **2026-10-12** 从 `share.dmhy.org` 真实抓取后裁掉多余行
/// 的原文（见 `test/fixtures/README.md`）。
library;

import 'package:dsanima_core/sources/sources.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures.dart';
import 'support.dart';

final DateTime _now = DateTime(2026, 10, 12, 12, 0);

void main() {
  group('DmhyListParser（dmhy_list.html，真实抓取）', () {
    late ParseOutcome outcome;

    setUpAll(() {
      outcome = DmhyListParser.parse(
        loadFixture('dmhy_list.html'),
        sourceId: 'dmhy',
        clock: () => _now,
      );
    });

    test('4 行全部解析出来、没有跳过，并给出「还有下一页」', () {
      expect(outcome.items, hasLength(4));
      expect(outcome.skipped, 0);
      expect(outcome.warnings, isEmpty);
      expect(outcome.hasNext, isTrue);
    });

    test('第 1 条逐字段正确', () {
      final item = outcome.items.first;
      expect(item.id, 'dmhy:725809');
      expect(item.sourceId, 'dmhy');
      expect(
        item.title,
        '[7³ACG] 葬送的芙莉莲/Sousou no Frieren S01 | 01-28+SPx11 '
        '[简繁字幕] BDrip 1080p x265 OPUS 2.0',
      );
      expect(
        item.detailUrl.toString(),
        'https://share.dmhy.org/topics/view/725809_7_ACG_Sousou_no_Frieren_S01_'
        '01-28_SPx11_BDrip_1080p_x265_OPUS_2_0.html',
      );
      expect(item.torrentUrl, isNull,
          reason: '列表行里只有磁力、没有 .torrent 直链，不许编一个');
      expect(item.magnet, isNotNull);
      expect(item.infoHash, 'f8651444a2c0b3ff7e3da3cbd75da58ef5f09e19');
      expect(item.sizeBytes, 48500000000);
      expect(item.publishedAt, DateTime(2026, 8, 28, 5, 32));
      expect(item.category, '季度全集');
      expect(item.group, '7³ACG');
      expect(item.extra['uploader'], 'c8l');
      expect(item.extra['sizeText'], '48.5GB');
      expect(item.extra['fromHtmlList'], isTrue);
    });

    test('带 tracker 的 base32 磁力被换成 hex，15 个 tracker 一个不少', () {
      final magnet = outcome.items.first.magnet!;
      expect(magnet,
          contains('xt=urn:btih:f8651444a2c0b3ff7e3da3cbd75da58ef5f09e19'));
      expect(magnet, isNot(contains('7BSRIRFCYCZ767R5UPF5OXNFR327BHQZ')),
          reason: 'base32 必须换掉：引擎侧对 base32 的把握不如 hex');
      expect('&tr='.allMatches(magnet).length, 15,
          reason: '换 xt 不能把 tracker 丢掉');
    });

    test('做种/下载数按"列的位置"取，没有跟着 CSS 类名跑偏', () {
      // dmhy 把表头「種子」那一列的数字包在 span.btl_N、把「下載」包在 span.bts_N 里，
      // 类名与列义正好相反（见 DmhyListParser 的注释）。所以断言的是**列的位置**：
      // 第 1 条 btl_1=0 / bts_1=4 → seeders=0、leechers=4。
      expect(outcome.items.first.seeders, 0);
      expect(outcome.items.first.leechers, 4);
      expect(outcome.items.first.downloads, 6);
      // 第 3 条反过来：btl_1=2 / bts_1=0 → seeders=2、leechers=0。
      expect(outcome.items[2].seeders, 2);
      expect(outcome.items[2].leechers, 0);
      expect(outcome.items[2].downloads, 7);
    });

    test('日期格里的隐藏 span 不会把发布时间弄成 null', () {
      // 站点在第 0 格里除了可见日期，还有一个 display:none 的同款日期（给排序脚本用）：
      // 直接拿整格文本会得到两份日期拼在一起，parseFeedDate 认不出 → 整列 null。
      for (final item in outcome.items) {
        expect(item.publishedAt, isNotNull, reason: '${item.id} 的发布时间不该为空');
      }
    });

    test('最后一页（没有「下一頁」）→ hasNext=false', () {
      final last = DmhyListParser.parse(
        loadFixture('dmhy_list_last.html'),
        sourceId: 'dmhy',
        clock: () => _now,
      );
      expect(last.items, hasLength(2));
      expect(last.hasNext, isFalse);
    });

    test('结构不认识（连站点骨架都没有）→ 抛 SourceException，且文案说"可能已改版"', () {
      expect(
        () => DmhyListParser.parse(
          '<html><body><p>这不是列表页</p></body></html>',
          sourceId: 'dmhy',
          clock: () => _now,
        ),
        throwsA(
          isA<SourceException>().having(
            (SourceException e) => e.message,
            'message',
            allOf(contains('可能已改版'), contains('HTTP 200')),
          ),
        ),
      );
    });

    // ── 第二十二轮（用户：「2/11 个源没回来」，报的却是"HTML 结构已变"）──────────
    //
    // 真因：dmhy **搜索零结果时根本不输出结果表**（真机抓的 fixture 就在仓库里）。
    // 旧实现一律报"HTML 结构已变"，于是"这个关键字没命中"被说成"站点坏了"。
    // 现在用站点自己的 `div.nav_title`（所有列表/搜索页都有，包括零结果与不存在的分类）
    // 区分：骨架在 = 站点正常、这一页 0 条；骨架不在 = 才说可能改版。
    // 用户选定：**0 条也仍然报错**（要看得见），但必须说成两件不同的事。
    test('搜索零结果（dmhy_search_empty.html，真机抓的）→ 报"0 条/没命中"，不说改版', () {
      expect(
        () => DmhyListParser.parse(
          loadFixture('dmhy_search_empty.html'),
          sourceId: 'dmhy',
          clock: () => _now,
          keyword: 'zzzzqqqqxyz',
        ),
        throwsA(
          isA<SourceException>()
              .having((SourceException e) => e.message, 'message',
                  contains('搜索「zzzzqqqqxyz」没有结果（0 条）'))
              .having((SourceException e) => e.message, 'message', contains('没有命中'))
              .having((SourceException e) => e.message, 'message',
                  isNot(contains('结构可能已改版'))),
        ),
      );
    });

    test('不存在的分类（dmhy_list_empty_category.html）→ 同样说成"这一页 0 条"', () {
      expect(
        () => DmhyListParser.parse(
          loadFixture('dmhy_list_empty_category.html'),
          sourceId: 'dmhy',
          clock: () => _now,
        ),
        throwsA(
          isA<SourceException>().having(
            (SourceException e) => e.message,
            'message',
            allOf(contains('这一页没有结果（0 条）'), isNot(contains('可能已改版'))),
          ),
        ),
      );
    });
  });

  group('DmhyListParser：字幕组优先读站点 team 字段（第四十五轮）', () {
    // 用户第四十五轮要加「字幕组筛选」，于是把各源的组名可靠度过了一遍：dmhy 明明有
    // 站点登记的团队字段，core 却只看标题前导方括号（那常常是**搬运者**）。
    // fixture 是手工构造的最小页（见文件里的注释），只钉这三条。
    late ParseOutcome outcome;

    setUpAll(() {
      outcome = DmhyListParser.parse(
        loadFixture('dmhy_list_team.html'),
        sourceId: 'dmhy',
        clock: () => _now,
      );
    });

    test('有 team 链接时以站点字段为准（标题里那个方括号可能是搬运者）', () {
      final item = outcome.items[0];
      expect(item.group, '动漫国字幕组');
      expect(item.extra['siteGroup'], '动漫国字幕组');
      expect(item.title, startsWith('[搬运]'),
          reason: '标题前导方括号是 `[搬运]` —— 旧实现会把这个当组名');
    });

    test('没有 team 链接（个人发布）→ 退回标题前导方括号', () {
      final item = outcome.items[1];
      expect(item.group, '7³ACG');
      expect(item.extra['siteGroup'], isNull);
    });

    test('team 链接文本为空 → 不编一个空组名，仍然退回标题', () {
      final item = outcome.items[2];
      expect(item.group, '云光字幕组');
      expect(item.extra['siteGroup'], isNull);
    });
  });

  group('DmhySource：身份、URL、缓存', () {
    late DmhySource source;

    setUp(() {
      source = DmhySource(
        http: buildHttp(textFactory('')),
        cache: SourceCache(store: InMemoryKeyValueStore()),
        clock: () => _now,
      );
    });

    test('默认身份', () {
      expect(source.id, 'dmhy');
      expect(source.displayName, '动漫花园（DMHY）');
      expect(source.baseUrl, 'https://share.dmhy.org');
      expect(source.supportsSearch, isTrue);
    });

    test('「最新」走動畫分类并分页；第 1 页不带 /page/', () {
      expect(source.latestUri(1).toString(),
          'https://share.dmhy.org/topics/list/sort_id/2');
      expect(source.latestUri(4).toString(),
          'https://share.dmhy.org/topics/list/sort_id/2/page/4');
    });

    test('搜索 URL：中文关键字百分号编码，页码进路径，**并带上分区 sort_id**', () {
      // 第二十四轮用户报「无法只搜索全集（还是会搜到单集）」的修法：搜索必须带站点自己的
      // 分区参数，否则「季度全集」那个实例搜出来的是全站（真机证据见 registry_test 那条
      // 与 build/probe-scope/probe-scope-filters.log）。
      expect(source.searchUri('葬送的芙莉莲', 1).toString(),
          'https://share.dmhy.org/topics/list?keyword='
          '%E8%91%AC%E9%80%81%E7%9A%84%E8%8A%99%E8%8E%89%E8%8E%B2&sort_id=2');
      expect(source.searchUri('x', 3).toString(),
          'https://share.dmhy.org/topics/list/page/3?keyword=x&sort_id=2');
    });

    test('季度全集实例：搜索带 sort_id=31（用户给的那个 URL 的参数）', () {
      final batch = DmhySource(
        http: buildHttp(textFactory('')),
        cache: SourceCache(store: InMemoryKeyValueStore()),
        id: 'dmhy-batch',
        animeSortId: kDmhyBatchSortId,
        clock: () => _now,
      );
      final Uri uri = batch.searchUri('蜡笔小新', 1);
      expect(uri.path, '/topics/list');
      expect(uri.queryParameters['sort_id'], '31');
      expect(uri.queryParameters['keyword'], '蜡笔小新');
    });

    test('端到端（假 HTTP）：search 打到搜索 URL 并把整页解析出来', () async {
      final factory = textFactory(
        loadFixture('dmhy_list.html'),
        contentType: 'text/html; charset=utf-8',
      );
      final s = DmhySource(
        http: buildHttp(factory),
        cache: SourceCache(store: InMemoryKeyValueStore()),
        clock: () => _now,
      );
      final page = await s.search('葬送的芙莉莲');
      expect(factory.requestedUris.single.path, '/topics/list');
      expect(factory.requestedUris.single.queryParameters['keyword'], '葬送的芙莉莲');
      expect(page.items, hasLength(4));
      expect(page.hasNext, isTrue);
      expect(page.fromCache, isFalse);
      expect(page.page, 1);
    });

    test('端到端（假 HTTP）：零结果搜索把关键字写进错误文案（不是"结构已变"）', () async {
      final factory = textFactory(
        loadFixture('dmhy_search_empty.html'),
        contentType: 'text/html; charset=utf-8',
      );
      final s = DmhySource(
        http: buildHttp(factory),
        cache: SourceCache(store: InMemoryKeyValueStore()),
        clock: () => _now,
      );
      await expectLater(
        s.search('芙莉莲'),
        throwsA(isA<SourceException>().having(
          (SourceException e) => e.message,
          'message',
          allOf(contains('搜索「芙莉莲」没有结果（0 条）'), isNot(contains('可能已改版'))),
        )),
      );
      expect(factory.requestedUris.single.queryParameters['keyword'], '芙莉莲');
    });

    test('同参数第二轮命中缓存，不再打网络（翻页/回看零请求的基础）', () async {
      final factory = textFactory(
        loadFixture('dmhy_list.html'),
        contentType: 'text/html; charset=utf-8',
      );
      final s = DmhySource(
        http: buildHttp(factory),
        cache: SourceCache(store: InMemoryKeyValueStore()),
        clock: () => _now,
      );
      await s.search('x');
      final again = await s.search('x');
      expect(again.fromCache, isTrue);
      expect(again.items, hasLength(4));
      expect(factory.requestedUris, hasLength(1));
    });

    test('空关键字 / page<1 → SourceException', () async {
      await expectLater(source.search('   '), throwsA(isA<SourceException>()));
      await expectLater(source.latest(page: 0), throwsA(isA<SourceException>()));
    });

    test('topicIdOf 支持 id 与 detailUrl 两种来源', () {
      expect(
        DmhySource.topicIdOf(SourceItem(id: 'dmhy:725809', sourceId: 'dmhy')),
        '725809',
      );
      expect(
        DmhySource.topicIdOf(SourceItem(
          id: 'x',
          sourceId: 'dmhy',
          detailUrl: Uri.parse('https://share.dmhy.org/topics/view/42_a.html'),
        )),
        '42',
      );
    });

    test('构造源不得触发任何网络', () {
      final factory = textFactory('');
      final s = DmhySource(
        http: buildHttp(factory),
        cache: SourceCache(store: InMemoryKeyValueStore()),
      );
      expect(s.id, 'dmhy');
      expect(factory.createCount, 0, reason: '构造源不得触发任何网络');
      expect(factory.requestedUris, isEmpty);
    });
  });
}
