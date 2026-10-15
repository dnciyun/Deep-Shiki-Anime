/// ACGNX 源单测：两个分区（動畫 / 季度全集）、搜索 feed、体积从描述里取。
///
/// 全部离线；feed 是 **2026-10-12** 从 `share.acgnx.se` 真实抓取后裁掉多余 item 的原文
/// （`rss-1.xml` / `rss-2.xml` / `rss.xml?keyword=学生会`）。
///
/// 为什么这个源只有 RSS：站点网页（`/sort-1-1.html`、`/search-*.html`、根路径）实测
/// 全部 403 `Just a moment...`（Cloudflare 挑战），只有 RSS 端点 200 —— 见 `acgnx.dart`
/// 的文件头注释。
library;

import 'package:dsanima_core/sources/sources.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures.dart';
import 'support.dart';

final DateTime _now = DateTime(2026, 10, 12, 12, 0);

void main() {
  group('AcgnxFeedParser（acgnx_batch.xml，季度全集，真实抓取）', () {
    late ParseOutcome outcome;

    setUpAll(() {
      outcome = AcgnxFeedParser.parse(
        loadFixture('acgnx_batch.xml'),
        sourceId: 'acgnx-batch',
        clock: () => _now,
      );
    });

    test('3 条全部解析出来，单页 feed 没有下一页', () {
      expect(outcome.items, hasLength(3));
      expect(outcome.skipped, 0);
      expect(outcome.warnings, isEmpty);
      expect(outcome.hasNext, isFalse);
    });

    test('第 1 条逐字段正确', () {
      final item = outcome.items.first;
      expect(item.id, 'acgnx-batch:0c6e76513b0f145f17220ee80de45b870d922b15');
      expect(item.sourceId, 'acgnx-batch');
      expect(item.title,
          '[ToonsHub] 转生贵族凭鉴定技能扭转人生 第二季 / Tensei Kizoku, Kantei Skill de Nariagaru Dai 2 Ki - 01-12 [CR][1080P][DUAL][CHT&CHS&EN][MKV]');
      expect(item.detailUrl.toString(),
          'https://share.acgnx.se/show-0c6e76513b0f145f17220ee80de45b870d922b15.html');
      // enclosure 就是磁力（不是 .torrent 直链）——所以 torrentUrl 必须是 null。
      expect(item.torrentUrl, isNull);
      expect(item.infoHash, '0c6e76513b0f145f17220ee80de45b870d922b15');
      expect(item.magnet, contains('xt=urn:btih:0c6e76513b0f145f17220ee80de45b870d922b15'));
      expect(item.magnet, contains('tr=http%3A%2F%2Fopentracker.acgnx.se%2Fannounce'));
      expect(item.isDownloadable, isTrue);
      // 16.9GB 是从 description 的 `| 16.9GB |` 段里取的（enclosure length="1" 是假值）。
      expect(item.sizeBytes, 16900000000);
      expect(item.category, '季度全集');
      expect(item.group, '華盟RIP鏡像');
      expect(item.publishedAt, DateTime.utc(2026, 10, 12, 10, 6, 52),
          reason: '+0800 的 18:06:52 必须是 UTC 10:06:52');
      expect(item.extra['fromRssFeed'], isTrue);
    });

    test('RSS 里没有做种/下载数：一律 null，不编 0', () {
      for (final item in outcome.items) {
        expect(item.seeders, isNull);
        expect(item.leechers, isNull);
        expect(item.downloads, isNull);
      }
    });

    test('《电影哆啦A梦》那条的体积也取对（3.1GB，描述里同样只有一处体积）', () {
      expect(outcome.items[2].sizeBytes, 3100000000);
      expect(outcome.items[2].group, '動漫花園鏡像');
    });
  });

  group('AcgnxFeedParser（動畫 / 搜索 feed）', () {
    test('動畫 feed：磁力都在，category 用站点自己标的那一栏', () {
      final anime = AcgnxFeedParser.parse(
        loadFixture('acgnx_anime.xml'),
        sourceId: 'acgnx',
        clock: () => _now,
      );
      expect(anime.items, hasLength(3));
      for (final item in anime.items) {
        expect(item.magnet, isNotNull, reason: '${item.id} 缺磁力');
        expect(item.infoHash, isNotNull);
        // ⚠️ 動畫 feed 里**确实**混着站点标为「季度全集」的条目（实测：季度全集是
        // 動畫分区的子分区，同一部合集在两边都出现）。所以这里断言"站点标了分类"，
        // 而不是断言它一定等于 動畫 —— 那样就得篡改站点数据。
        expect(item.category, anyOf('動畫', '季度全集'));
      }
    });

    test('搜索 feed（?keyword=学生会）：条目都是命中项，id 按源前缀', () {
      final hits = AcgnxFeedParser.parse(
        loadFixture('acgnx_search.xml'),
        sourceId: 'acgnx',
        clock: () => _now,
      );
      expect(hits.items, hasLength(2));
      for (final item in hits.items) {
        // 简繁两种写法的命中项都可能出现，所以两个字面量都接受。
        expect(item.title, anyOf(contains('学生'), contains('學生')));
        expect(item.id, startsWith('acgnx:'));
      }
    });

    test('feed 不是 XML / 根元素不对 → SourceException（不返回空列表）', () {
      expect(
        () => AcgnxFeedParser.parse(
          '<html><body>Cloudflare 挑战页</body></html>',
          sourceId: 'acgnx',
          clock: () => _now,
        ),
        throwsA(isA<SourceException>()),
      );
    });
  });

  group('AcgnxSource：身份、URL、单页语义', () {
    late AcgnxSource source;

    setUp(() {
      source = AcgnxSource(
        http: buildHttp(textFactory('')),
        cache: SourceCache(store: InMemoryKeyValueStore()),
        clock: () => _now,
      );
    });

    test('默认身份 = 動畫分区', () {
      expect(source.id, 'acgnx');
      expect(source.displayName, 'ACGNX · 動畫');
      expect(source.feedId, kAcgnxAnimeFeed);
      expect(source.baseUrl, 'https://share.acgnx.se');
      expect(source.supportsSearch, isTrue);
      expect(source.latestUri(1).toString(), 'https://share.acgnx.se/rss-1.xml');
    });

    test('季度全集实例：rss-2.xml + 独立 id', () {
      final batch = AcgnxSource(
        http: buildHttp(textFactory('')),
        cache: SourceCache(store: InMemoryKeyValueStore()),
        id: 'acgnx-batch',
        displayName: 'ACGNX · 季度全集',
        feedId: kAcgnxBatchFeed,
        clock: () => _now,
      );
      expect(batch.id, 'acgnx-batch');
      expect(batch.categoryLabel, '季度全集');
      expect(batch.latestUri(1).toString(), 'https://share.acgnx.se/rss-2.xml');
    });

    test('搜索 URL：rss.xml?keyword=，中文百分号编码，**并带分区 sort_id**', () {
      // 第二十四轮：RSS 搜索端点也认 sort_id（真机实测：不带 = 50 条 0 合集；
      // sort_id=2 = 30 条 17 合集 0 单集）。不带就会出现用户报的「还是会搜到单集」。
      expect(source.searchUri('学生会', 1).toString(),
          'https://share.acgnx.se/rss.xml?keyword=%E5%AD%A6%E7%94%9F%E4%BC%9A&sort_id=1');
    });

    test('最新：第 1 页走分区 feed 并解析；第 2 页返回空页（RSS 没有翻页）', () async {
      final factory = textFactory(
        loadFixture('acgnx_batch.xml'),
        contentType: 'text/xml;charset=UTF-8',
      );
      final s = AcgnxSource(
        http: buildHttp(factory),
        cache: SourceCache(store: InMemoryKeyValueStore()),
        id: 'acgnx-batch',
        feedId: kAcgnxBatchFeed,
        clock: () => _now,
      );
      final page = await s.latest();
      expect(factory.requestedUris.single.toString(),
          'https://share.acgnx.se/rss-2.xml');
      expect(page.items, hasLength(3));
      expect(page.hasNext, isFalse);

      final second = await s.latest(page: 2);
      expect(second.items, isEmpty);
      expect(second.hasNext, isFalse);
      expect(factory.requestedUris, hasLength(1),
          reason: '第 2 页不该再去打网络（站点根本不分页）');
    });

    test('搜索：打到 rss.xml?keyword= 并把结果解析出来；第 2 页空页', () async {
      final factory = textFactory(
        loadFixture('acgnx_search.xml'),
        contentType: 'text/xml;charset=UTF-8',
      );
      final s = AcgnxSource(
        http: buildHttp(factory),
        cache: SourceCache(store: InMemoryKeyValueStore()),
        clock: () => _now,
      );
      final page = await s.search('学生会');
      expect(factory.requestedUris.single.path, '/rss.xml');
      expect(factory.requestedUris.single.queryParameters['keyword'], '学生会');
      expect(page.items, hasLength(2));

      final second = await s.search('学生会', page: 2);
      expect(second.items, isEmpty);
      expect(second.hasNext, isFalse);
      expect(factory.requestedUris, hasLength(1));
    });

    test('空关键字 / page<1 → SourceException', () async {
      await expectLater(source.search('  '), throwsA(isA<SourceException>()));
      await expectLater(source.latest(page: 0), throwsA(isA<SourceException>()));
    });

    test('构造源不得触发任何网络', () {
      final factory = textFactory('');
      final s = AcgnxSource(
        http: buildHttp(factory),
        cache: SourceCache(store: InMemoryKeyValueStore()),
      );
      expect(s.id, 'acgnx');
      expect(factory.createCount, 0);
    });
  });
}
