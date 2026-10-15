/// nyaa 源解析单测：RSS（真实抓取样本）、HTML 搜索列表页、`/view` 详情页。
///
/// 全部离线，fixture 来自 2026-10-08 的真实站点抓取。
library;

import 'package:dsanima_core/sources/sources.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures.dart';
import 'support.dart';

final DateTime _fetchedAt = DateTime.utc(2026, 10, 8, 12);

void main() {
  group('NyaaRssParser（nyaa_anime_rss.xml，真实抓取）', () {
    late ParseOutcome outcome;

    setUpAll(() {
      outcome = NyaaRssParser.parse(
        loadFixture('nyaa_anime_rss.xml'),
        sourceId: 'nyaa',
        clock: () => _fetchedAt,
      );
    });

    test('6 条 item 全部解析成功，无丢弃', () {
      expect(outcome.items, hasLength(6));
      expect(outcome.skipped, 0);
    });

    test('第 1 条逐字段正确（含 nyaa: 扩展命名空间）', () {
      final item = outcome.items.first;
      expect(item.id, 'nyaa:2171210');
      expect(item.sourceId, 'nyaa');
      expect(
        item.title,
        '[DRiFTKiNG] You and I Are Polar Opposites - S02E08-E11 (CR WEB-DL 1080p '
        'H.264 AAC 2.0) [Multi-Audio] (German/Deutsch, Japanese Dubs) [OV] [OmU] '
        '[OmeU] [DF] [Synchro] | Seihantai na Kimi to Boku 2nd Season',
      );
      expect(item.detailUrl.toString(), 'https://nyaa.si/view/2171210');
      expect(item.torrentUrl, 'https://nyaa.si/download/2171210.torrent');
      // RSS 里只有 .torrent 直链，没有 magnet —— 由 detail() 补齐。
      expect(item.magnet, isNull);
      expect(item.infoHash, '3a1cbcfc711bb7a21f2741433119773c23ac081d');
      expect(item.sizeBytes, 6012954214); // 5.6 GiB
      expect(item.extra['sizeText'], '5.6 GiB');
      expect(item.seeders, 3);
      expect(item.leechers, 13);
      expect(item.downloads, 0);
      expect(item.extra['comments'], 0);
      expect(item.publishedAt, DateTime.utc(2026, 10, 8, 13, 18, 50));
      expect(item.category, 'Anime - English-translated');
      expect(item.extra['categoryId'], '1_2');
      expect(item.extra['trusted'], isFalse);
      expect(item.extra['remake'], isFalse);
      expect(item.group, 'DRiFTKiNG');
      expect(item.episodeHints, <String>['S02E08', 'S02E11']);
      expect(item.extra['isBatch'], isTrue); // S02E08-E11 是多集打包
      expect(item.extra['resolution'], 1080);
    });

    test('第 2 条逐字段正确（`- 02` 形态的集数）', () {
      final item = outcome.items[1];
      expect(item.id, 'nyaa:2171209');
      expect(item.title, '[ASW] FX Senshi Kurumi-chan - 02 [1080p HEVC x265 10Bit][AAC]');
      expect(item.torrentUrl, 'https://nyaa.si/download/2171209.torrent');
      expect(item.infoHash, 'abb3ec1657eef101c0263f33baa7ee9d09dc0e5c');
      expect(item.seeders, 78);
      expect(item.leechers, 56);
      expect(item.downloads, 123);
      expect(item.sizeBytes, 264975155); // 252.7 MiB
      expect(item.publishedAt, DateTime.utc(2026, 10, 8, 13, 13, 5));
      expect(item.group, 'ASW');
      expect(item.episodeHints, <String>['02']);
      expect(item.extra['isBatch'], isFalse);
      expect(item.extra['resolution'], 1080);
    });

    test('info hash 全是 40 位小写 hex', () {
      for (final item in outcome.items) {
        expect(item.infoHash, isNotNull, reason: '${item.id} 应有 infoHash');
        expect(RegExp(r'^[0-9a-f]{40}$').hasMatch(item.infoHash!), isTrue);
      }
    });

    test('拿到 HTML 错误页时抛错（根元素不是 feed，禁止静默空列表）', () {
      expect(
        () => NyaaRssParser.parse(loadEdgeFixture('nyaa_no_table.html'),
            sourceId: 'nyaa', clock: () => _fetchedAt),
        throwsA(isA<SourceException>().having(
          (SourceException e) => e.message,
          'message',
          contains('不是 rss/feed/RDF'),
        )),
      );
    });

    test('XML 标签不匹配时抛 SourceException（不返回空列表假装成功）', () {
      expect(
        () => NyaaRssParser.parse(loadEdgeFixture('malformed.xml'),
            sourceId: 'nyaa', clock: () => _fetchedAt),
        throwsA(isA<SourceException>()),
      );
    });

    test('EOF 未闭合标签同样抛 SourceException（XmlTagException 不是 XmlParserException）',
        () {
      expect(
        () => NyaaRssParser.parse(loadEdgeFixture('unclosed_tags.xml'),
            sourceId: 'nyaa', clock: () => _fetchedAt),
        throwsA(isA<SourceException>()),
      );
    });
  });

  group('NyaaHtmlListParser（nyaa_search.html，真实抓取）', () {
    late ParseOutcome outcome;

    setUpAll(() {
      outcome = NyaaHtmlListParser.parse(
        loadFixture('nyaa_search.html'),
        sourceId: 'nyaa',
        clock: () => _fetchedAt,
      );
    });

    test('table.torrent-list 的 75 行全部解析', () {
      expect(outcome.items, hasLength(75));
      expect(outcome.skipped, 0);
      expect(outcome.warnings, isEmpty);
    });

    test('分页标记：存在可点的 li.next → hasNext = true', () {
      expect(outcome.hasNext, isTrue);
    });

    test('第 1 行逐字段正确（含 magnet 与 data-timestamp）', () {
      final item = outcome.items.first;
      expect(item.id, 'nyaa:2090638');
      expect(item.title,
          '[Erai-raws] Sousou no Frieren 2nd Season - 10 [1080p CR WEB-DL AVC AAC][MultiSub][5A357DEE]');
      expect(item.detailUrl.toString(), 'https://nyaa.si/view/2090638');
      expect(item.torrentUrl, 'https://nyaa.si/download/2090638.torrent');
      expect(item.magnet,
          startsWith('magnet:?xt=urn:btih:bd167d148570f2c7ece6c15bd90d3901acb6d79c'));
      expect(item.infoHash, 'bd167d148570f2c7ece6c15bd90d3901acb6d79c');
      expect(item.sizeBytes, 1503238554); // 1.4 GiB
      expect(item.extra['sizeText'], '1.4 GiB');
      expect(item.seeders, 804);
      expect(item.leechers, 2);
      expect(item.downloads, 34787);
      expect(item.category, 'Anime - English-translated');
      expect(item.publishedAt, DateTime.fromMillisecondsSinceEpoch(1774623653000, isUtc: true));
      expect(item.extra['comments'], 1);
      expect(item.group, 'Erai-raws');
      expect(item.episodeHints, <String>['10']);
      expect(item.extra['resolution'], 1080);
      // 列表行 class="success" ⇒ nyaa 标记为 trusted
      expect(item.extra['trusted'], isTrue);
      expect(item.extra['remake'], isFalse);
      expect(item.extra['fromHtmlList'], isTrue);
    });

    test('没有 table.torrent-list 时抛明确异常', () {
      expect(
        () => NyaaHtmlListParser.parse(loadEdgeFixture('nyaa_no_table.html'),
            sourceId: 'nyaa', clock: () => _fetchedAt),
        throwsA(isA<SourceException>().having(
          (SourceException e) => e.message,
          'message',
          contains('table.torrent-list'),
        )),
      );
    });
  });

  group('NyaaHtmlDetailParser（nyaa_view_2090638.html，真实抓取）', () {
    test('补出 magnet / infoHash / 精确发布时间 / 提交者', () {
      final base = SourceItem(
        id: 'nyaa:2090638',
        sourceId: 'nyaa',
        title: '旧标题',
        detailUrl: Uri.parse('https://nyaa.si/view/2090638'),
      );
      final item = NyaaHtmlDetailParser.parse(
        loadFixture('nyaa_view_2090638.html'),
        base: base,
        sourceId: 'nyaa',
        clock: () => _fetchedAt,
      );
      expect(item, isNotNull);
      expect(item!.title,
          '[Erai-raws] Sousou no Frieren 2nd Season - 10 [1080p CR WEB-DL AVC AAC][MultiSub][5A357DEE]');
      expect(item.infoHash, 'bd167d148570f2c7ece6c15bd90d3901acb6d79c');
      expect(item.magnet, startsWith('magnet:?xt=urn:btih:bd167d148570f2c7ece6c15bd90d3901acb6d79c'));
      expect(item.torrentUrl, 'https://nyaa.si/download/2090638.torrent');
      expect(item.sizeBytes, 1503238554);
      expect(item.seeders, 801);
      expect(item.leechers, 2);
      expect(item.downloads, 34787);
      expect(item.category, 'Anime - English-translated');
      expect(item.publishedAt,
          DateTime.fromMillisecondsSinceEpoch(1774623653000, isUtc: true));
      expect(item.extra['submitter'], 'Erai-raws');
      expect(item.extra['detailFetched'], isTrue);
      expect(item.episodeHints, <String>['10']);
    });

    test('结构不认识（没有 h3.panel-title）→ null，由调用方决定抛错', () {
      final base = SourceItem(id: 'nyaa:1', sourceId: 'nyaa');
      final item = NyaaHtmlDetailParser.parse(
        loadEdgeFixture('nyaa_no_table.html'),
        base: base,
        sourceId: 'nyaa',
        clock: () => _fetchedAt,
      );
      expect(item, isNull);
    });
  });

  group('NyaaSource URL 与分页语义', () {
    late NyaaSource source;

    setUp(() {
      final clock = FakeClock(_fetchedAt);
      source = NyaaSource(
        http: buildHttp(textFactory(''), clock: clock),
        cache: SourceCache(store: InMemoryKeyValueStore(), clock: clock.call),
        clock: clock.call,
      );
    });

    test('RSS URL：最新用 c=1_2（spec 冻结），搜索放宽到 c=1_0 并带 q/s/o', () {
      expect(source.rssUri().toString(),
          'https://nyaa.si/?page=rss&c=1_2&f=0');
      // 搜索那个 c=1_0 是 2026-10-12 的修正：中文关键字在 English-translated
      // 分类下实测只有 2 条，放宽到全部 Anime 是 75 条（见 searchCategory 注释）。
      expect(source.rssUri(keyword: 'Frieren').toString(),
          'https://nyaa.si/?page=rss&q=Frieren&c=1_0&f=0&s=seeders&o=desc');
    });

    test('搜索 HTML 第 N 页 URL', () {
      expect(source.searchHtmlUri('Frieren 测试', 3).queryParameters, <String, String>{
        'page': 'search',
        'q': 'Frieren 测试',
        'c': '1_0',
        'f': '0',
        's': 'seeders',
        'o': 'desc',
        'p': '3',
      });
    });

    test('searchCategory 可显式覆盖（想钉死分类时用）', () {
      final clock = FakeClock(_fetchedAt);
      final s = NyaaSource(
        http: buildHttp(textFactory(''), clock: clock),
        cache: SourceCache(store: InMemoryKeyValueStore(), clock: clock.call),
        searchCategory: '1_3',
        clock: clock.call,
      );
      expect(s.rssUri(keyword: 'x').queryParameters['c'], '1_3');
      expect(s.searchHtmlUri('x', 2).queryParameters['c'], '1_3');
      // 最新不受影响
      expect(s.rssUri().queryParameters['c'], '1_2');
    });

    test('c=1_0（全部 Anime）可作为源参数', () {
      final clock = FakeClock(_fetchedAt);
      final s = NyaaSource(
        http: buildHttp(textFactory(''), clock: clock),
        cache: SourceCache(store: InMemoryKeyValueStore(), clock: clock.call),
        category: '1_0',
        clock: clock.call,
      );
      expect(s.rssUri().queryParameters['c'], '1_0');
    });

    test('latest(page>1) 返回空页且 hasNext=false（RSS 无分页，不伪造数据）', () async {
      final page = await source.latest(page: 2);
      expect(page.items, isEmpty);
      expect(page.hasNext, isFalse);
      expect(page.page, 2);
      expect(page.fromCache, isFalse);
    });

    test('空关键字 → 抛 SourceException', () async {
      expect(() => source.search('   '), throwsA(isA<SourceException>()));
    });

    test('viewIdOf 支持 id 与 detailUrl 两种来源', () {
      expect(
        NyaaSource.viewIdOf(SourceItem(id: 'nyaa:2171209', sourceId: 'nyaa')),
        '2171209',
      );
      expect(
        NyaaSource.viewIdOf(SourceItem(
          id: 'x',
          sourceId: 'nyaa',
          detailUrl: Uri.parse('https://nyaa.si/view/42'),
        )),
        '42',
      );
    });
  });
}
