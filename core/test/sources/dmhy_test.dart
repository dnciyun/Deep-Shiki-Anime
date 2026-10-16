/// dmhy（动漫花园）源单测：列表页解析、磁力规范化、分页语义、URL 形态、临时页重试。
///
/// 全部离线；fixture 大多是 **2026-10-12** 从 `share.dmhy.org` 真实抓取后裁掉多余行
/// 的原文（见 `test/fixtures/README.md`）；`dmhy_not_list_page.html` 是第四十八轮·补三
/// 抓的那一版（来源见用例里的注释）。
library;

import 'dart:convert';

import 'package:dsanima_core/sources/sources.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

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

    test('页面完全不是 dmhy 的（连站名都没有）→ 说"没到 dmhy"，不冒充"0 条"', () {
      expect(
        () => DmhyListParser.parse(
          '<html><head><title>502 Bad Gateway</title></head>'
          '<body><p>这不是列表页</p></body></html>',
          sourceId: 'dmhy',
          clock: () => _now,
        ),
        throwsA(
          isA<DmhyNotListPageException>()
              .having(
                (DmhyNotListPageException e) => e.message,
                'message',
                allOf(
                  contains('根本不是 dmhy 的页面'),
                  contains('HTTP 200'),
                  contains('502 Bad Gateway'),
                  isNot(contains('没有结果（0 条）')),
                ),
              ),
        ),
      );
    });

    // ── 第四十八轮·补三（用户：「1/7 个源没回来：动漫花园·季度全集(DMHY) —— 页面里既没有
    //    结果表，也没有它自己的分页工具条」）────────────────────────────────────────
    //
    // 这条文案原来写的是「页面结构可能已改版 —— 把这一条反馈给我，我按新结构修解析」。
    // 真机复测（`build/round48b/probe_dmhy*.py`，20 多个样本）**复现不出"结构变了"**：
    // 有结果 / 零结果 / 分页 / 各种关键字全都是正常列表页（nav_title + 结果表都在），
    // 而站点**自己的错误页**正好长成"有 .top_sort、没有 nav_title、没有结果表"。
    // 所以：这是**偶发的临时页**，不是改版 —— 文案要能行动，[DmhySource] 还要自动重试一次。
    test('站点自己的临时页（真机抓的错误页骨架）→ 说"没回列表页 + 页面标题"，不说"改版"', () {
      expect(
        () => DmhyListParser.parse(
          loadFixture('dmhy_not_list_page.html'),
          sourceId: 'dmhy-batch',
          clock: () => _now,
          keyword: '命运石之门',
          pageUri: Uri.parse(
            'https://share.dmhy.org/topics/list?keyword=%E5%91%BD%E8%BF%90%E7%9F%B3%E4%B9%8B%E9%97%A8&sort_id=31',
          ),
        ),
        throwsA(
          isA<DmhyNotListPageException>()
              .having(
                (DmhyNotListPageException e) => e.message,
                'message',
                allOf(
                  contains('dmhy 搜索「命运石之门」没回列表页'),
                  // 诊断三件套：站点标记在不在、页面标题、真 0 条长什么样。
                  contains('分类导航'),
                  contains('页面标题「動漫花園資源網'),
                  contains('真 0 条时站点会带上那条工具条'),
                  contains('过几分钟再点一次'),
                  isNot(contains('结构可能已改版')),
                  isNot(contains('没有结果（0 条）')),
                ),
              )
              .having(
                (DmhyNotListPageException e) => e.url.toString(),
                'url',
                contains('sort_id=31'),
                // 报错要带**这次真正请求的 URL**（原来只带站点根，反馈时等于没有线索）。
              ),
        ),
      );
    });

    test('站点骨架不在、但站点标记在 → 与"根本不是 dmhy"分开说', () {
      expect(
        () => DmhyListParser.parse(
          '<html><head><title>動漫花園資源網 - 動漫愛好者的自由交流平台</title></head>'
          '<body><div class="top_sort"></div></body></html>',
          sourceId: 'dmhy',
          clock: () => _now,
        ),
        throwsA(
          isA<DmhyNotListPageException>().having(
            (DmhyNotListPageException e) => e.message,
            'message',
            contains('站点自己的东西在'),
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

    // ── 第四十八轮·补三：临时页**自动重试一次** ────────────────────────────────
    test('第一次拿到临时页、第二次正常 → 用户这边毫无感觉（只看到结果）', () async {
      final factory = sequenceFactory(<http.Response Function()>[
        () => http.Response.bytes(
          utf8.encode(loadFixture('dmhy_not_list_page.html')),
          200,
          headers: <String, String>{'content-type': 'text/html; charset=utf-8'},
        ),
        () => http.Response.bytes(
          utf8.encode(loadFixture('dmhy_list.html')),
          200,
          headers: <String, String>{'content-type': 'text/html; charset=utf-8'},
        ),
      ]);
      final s = DmhySource(
        http: buildHttp(factory),
        cache: SourceCache(store: InMemoryKeyValueStore()),
        clock: () => _now,
      );

      final page = await s.search('葬送的芙莉莲');

      expect(page.items, hasLength(4), reason: '第二次那张页才是列表页');
      expect(
        factory.requestedUris,
        hasLength(2),
        reason: '同一个 URL 打了两次（中间由限速器保证间隔）',
      );
      expect(factory.requestedUris[0], factory.requestedUris[1]);
    });

    test('两次都是临时页 → 才把话交给用户，且说明"已重试一次" + 带上真 URL', () async {
      final factory = textFactory(
        loadFixture('dmhy_not_list_page.html'),
        contentType: 'text/html; charset=utf-8',
      );
      final s = DmhySource(
        http: buildHttp(factory),
        cache: SourceCache(store: InMemoryKeyValueStore()),
        clock: () => _now,
      );

      await expectLater(
        s.search('命运石之门'),
        throwsA(
          isA<DmhyNotListPageException>()
              .having(
                (DmhyNotListPageException e) => e.message,
                'message',
                allOf(
                  contains('没回列表页'),
                  contains('已自动重试一次，两次都是这个页面'),
                ),
              )
              .having((DmhyNotListPageException e) => e.sourceId, 'sourceId', 'dmhy')
              .having(
                (DmhyNotListPageException e) => e.url!.queryParameters['keyword'],
                'url.keyword',
                '命运石之门',
              ),
        ),
      );
      expect(factory.requestedUris, hasLength(2), reason: '重试过一次就不再打第三次');
    });

    test('零结果**不**重试：那是结论，再打一次还是 0 条', () async {
      final factory = textFactory(
        loadFixture('dmhy_search_empty.html'),
        contentType: 'text/html; charset=utf-8',
      );
      final s = DmhySource(
        http: buildHttp(factory),
        cache: SourceCache(store: InMemoryKeyValueStore()),
        clock: () => _now,
      );

      await expectLater(s.search('芙莉莲'), throwsA(isA<SourceException>()));
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
