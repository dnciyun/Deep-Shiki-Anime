/// 自定义 RSS / Atom 源单测。
///
/// * `generic_dmhy.xml` / `generic_acgrip.xml` 是 2026-10-08 的真实站点抓取；
/// * 少量「单体解析」用例用内联 XML 构造边界（Atom、description 内磁力、
///   `media:content@fileSize`、重复 guid），已在用例名里标注为合成样本。
library;

import 'package:dsanima_core/sources/sources.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'fixtures.dart';
import 'support.dart';

final DateTime _now = DateTime.utc(2026, 10, 8, 12);

RssSource _source(RecordingHttpFactory factory, {FakeClock? clock}) {
  final c = clock ?? FakeClock(_now);
  return RssSource(
    feedId: 'test',
    feedUrl: Uri.parse('https://example.invalid/feed.xml'),
    http: buildHttp(factory, clock: c),
    cache: SourceCache(store: InMemoryKeyValueStore(), clock: c.call),
    clock: c.call,
  );
}

void main() {
  group('RssParser（generic_dmhy.xml，真实抓取：enclosure 是 base32 磁力）', () {
    late ParseOutcome outcome;

    setUpAll(() {
      outcome = RssParser.parse(
        loadFixture('generic_dmhy.xml'),
        feedId: 'dmhy',
        sourceId: 'rss:dmhy',
        clock: () => _now,
      );
    });

    test('5 条 item，id 形如 rss:<feedId>:<guid|link>', () {
      expect(outcome.items, hasLength(5));
      expect(outcome.skipped, 0);
      for (final item in outcome.items) {
        expect(item.id, startsWith('rss:dmhy:'));
        expect(item.sourceId, 'rss:dmhy');
      }
      // dmhy feed 没有 guid，用 link 作 identity
      expect(outcome.items.first.id,
          startsWith('rss:dmhy:http://share.dmhy.org/topics/view/728537_'));
    });

    test('第 1 条：enclosure 直接是 magnet（base32），infoHash 归一化为 hex', () {
      final item = outcome.items.first;
      expect(
        item.title,
        '[JMAX] [2026.07.13／10.09]「ガールズバンドクライ First Riff」'
        'F-272 - Diorama／A Tragic Mirage [FLAC]',
      );
      expect(item.extra['guid'],
          'http://share.dmhy.org/topics/view/728537_JMAX_2026_07_13_10_09_First_Riff_F-272_-_Diorama_A_Tragic_Mirage_FLAC.html');
      expect(item.magnet, startsWith('magnet:?xt=urn:btih:FCEBW3EH7SPCQAOGGTKKGXMRV7D7EXRO'));
      expect(item.infoHash, '28881b6c87fc9e2801c634d4a35d91afc7f25e2e');
      // magnet 形式的 enclosure 不是 .torrent 直链
      expect(item.torrentUrl, isNull);
      expect(item.extra['enclosureType'], 'application/x-bittorrent');
      expect(item.publishedAt, DateTime.utc(2026, 10, 8, 12, 39, 4));
      expect(item.group, 'JMAX');
      expect(item.episodeHints, isEmpty);
      expect(item.extra['isBatch'], isFalse);
    });

    test('第 5 条：enclosure 磁力优先于 description 里的磁力（记录优先级）', () {
      final item = outcome.items.last;
      expect(item.title, startsWith('[整理搬运] 犬夜叉 (Inuyasha)'));
      expect(item.infoHash, '045b674f6ee7ee5670621bb9944070450eae091e');
      expect(item.magnet, startsWith('magnet:?xt=urn:btih:ARNWOT3O47XFM4DCDO4ZIQDQIUHK4CI6'));
      expect(item.extra['subtitleType'], '外挂');
      expect(item.extra['subtitleLang'], '简');
      expect(item.detailUrl.toString(),
          'http://share.dmhy.org/topics/view/728522_Inuyasha_TV_OVA_CD_2023_05_02.html');
    });

    test('description 里的 magnet 正则兜底（合成样本：没有 enclosure）', () {
      const xml = '''
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0"><channel><title>t</title>
<item>
  <guid>desc-magnet-1</guid>
  <title>[组] 只有描述里有磁力 - 01</title>
  <description><![CDATA[<p>详情页说明</p>
  magnet:?xt=urn:btih:979729c737fbed10e72ef82690b6aaea7beaa23b<br/>完]]></description>
</item>
</channel></rss>
''';
      final out = RssParser.parse(xml,
          feedId: 'f', sourceId: 'rss:f', clock: () => _now);
      expect(out.items, hasLength(1));
      final item = out.items.single;
      expect(item.magnet, 'magnet:?xt=urn:btih:979729c737fbed10e72ef82690b6aaea7beaa23b');
      expect(item.infoHash, '979729c737fbed10e72ef82690b6aaea7beaa23b');
      expect(item.torrentUrl, isNull);
      expect(item.extra['contentPreview'], contains('详情页说明'));
    });
  });

  group('RssParser（generic_acgrip.xml，真实抓取：torrent: 与 media: 扩展）', () {
    late ParseOutcome outcome;

    setUpAll(() {
      outcome = RssParser.parse(
        loadFixture('generic_acgrip.xml'),
        feedId: 'acgrip',
        sourceId: 'rss:acgrip',
        clock: () => _now,
      );
    });

    test('5 条 item，第 1 条逐字段正确', () {
      expect(outcome.items, hasLength(5));
      final item = outcome.items.first;
      expect(item.id, 'rss:acgrip:https://acg.rip/t/364729');
      expect(item.title, '[黒ネズミたち] 麵包小偷 / Pan Dorobou - 01 (ABEMA 1920x1080 AVC AAC MKV)');
      expect(item.torrentUrl, 'https://acg.rip/t/364729.torrent');
      expect(item.detailUrl.toString(), 'https://acg.rip/t/364729');
      expect(item.magnet, isNull);
      expect(item.infoHash, isNull);
      expect(item.sizeBytes, 283864064); // torrent:contentLength
      expect(item.publishedAt, DateTime.utc(2026, 10, 8, 13, 10, 36));
      expect(item.group, '黒ネズミたち');
      expect(item.episodeHints, <String>['01']);
      expect(item.extra['resolution'], 1080); // 1920x1080
    });

    test('media:content@fileSize 也能作为体积来源（合成样本）', () {
      const xml = '''
<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0" xmlns:media="http://search.yahoo.com/mrss/">
<channel><title>t</title>
<item>
  <title>[组] 只有 media:content - 02</title>
  <guid>media-1</guid>
  <enclosure url="https://example.invalid/m.torrent" type="application/x-bittorrent"/>
  <media:content url="https://example.invalid/m.torrent" fileSize="664637440"/>
</item>
</channel></rss>
''';
      final out = RssParser.parse(xml,
          feedId: 'f', sourceId: 'rss:f', clock: () => _now);
      expect(out.items.single.sizeBytes, 664637440);
    });
  });

  group('RssParser Atom 支持（合成样本，spec §4.2 要求 Atom）', () {
    test('entry/link@href/id/published/summary', () {
      const xml = '''
<?xml version="1.0" encoding="utf-8"?>
<feed xmlns="http://www.w3.org/2005/Atom">
  <title>Atom 订阅</title>
  <entry>
    <title type="html">[组] Atom 的一条 - 03</title>
    <id>tag:example.invalid,2026:3</id>
    <link rel="alternate" href="https://example.invalid/entry/3"/>
    <link rel="enclosure" type="application/x-bittorrent"
          href="https://example.invalid/e3.torrent"/>
    <published>2026-10-08T09:00:00Z</published>
    <summary>说明：magnet:?xt=urn:btih:abb3ec1657eef101c0263f33baa7ee9d09dc0e5c</summary>
  </entry>
</feed>
''';
      final out = RssParser.parse(xml,
          feedId: 'atom', sourceId: 'rss:atom', clock: () => _now);
      expect(out.items, hasLength(1));
      final item = out.items.single;
      expect(item.id, 'rss:atom:tag:example.invalid,2026:3');
      expect(item.title, '[组] Atom 的一条 - 03');
      expect(item.detailUrl.toString(), 'https://example.invalid/entry/3');
      expect(item.torrentUrl, 'https://example.invalid/e3.torrent');
      expect(item.magnet,
          'magnet:?xt=urn:btih:abb3ec1657eef101c0263f33baa7ee9d09dc0e5c');
      expect(item.infoHash, 'abb3ec1657eef101c0263f33baa7ee9d09dc0e5c');
      expect(item.publishedAt, DateTime.utc(2026, 10, 8, 9, 0, 0));
      expect(item.episodeHints, <String>['03']);
    });
  });

  group('去重与边界', () {
    test('同一 feed 重复抓取按 id 去重（合成样本：guid 相同）', () {
      const xml = '''
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0"><channel><title>t</title>
<item><guid>dup-1</guid><title>[组] 第一条 - 01</title></item>
<item><guid>dup-1</guid><title>[组] 第一条（重复项）- 01</title></item>
<item><guid>dup-2</guid><title>[组] 第二条 - 02</title></item>
</channel></rss>
''';
      final out = RssParser.parse(xml,
          feedId: 'f', sourceId: 'rss:f', clock: () => _now);
      expect(out.items, hasLength(2));
      expect(out.warnings.single, contains('去重'));
      expect(out.items.first.title, '[组] 第一条 - 01'); // 保留首次出现
    });

    test('空 feed → 空列表 + warning，不抛错', () {
      final out = RssParser.parse(
        loadEdgeFixture('empty_feed.xml'),
        feedId: 'f',
        sourceId: 'rss:f',
        clock: () => _now,
      );
      expect(out.items, isEmpty);
      expect(out.warnings.single, contains('空 feed'));
    });

    test('字段缺失：无 identity 的条目被计数丢弃，其余照常解析', () {
      final out = RssParser.parse(
        loadEdgeFixture('missing_fields.xml'),
        feedId: 'f',
        sourceId: 'rss:f',
        clock: () => _now,
      );
      // item1 只有 title → 用 title 作 identity（可接受）；item2 完全无 identity → 丢弃
      expect(out.skipped, 1);
      expect(out.items, hasLength(3));
      expect(out.items[0].title, contains('只有标题的一条'));
      expect(out.items[1].id, 'rss:f:stable-guid-3');
      expect(out.items[1].torrentUrl, isNull);
      expect(out.items[1].magnet, isNull);
      expect(out.items[2].torrentUrl, 'https://example.invalid/only-link-4.torrent');
      expect(out.items[2].sizeBytes, 4096);
    });

    test('非法日期 → publishedAt 为 null（绝不倒填当前时间）', () {
      final out = RssParser.parse(
        loadEdgeFixture('bad_dates.xml'),
        feedId: 'f',
        sourceId: 'rss:f',
        clock: () => _now,
      );
      expect(out.items, hasLength(5));
      expect(out.items[0].publishedAt, isNull);
      expect(out.items[1].publishedAt, isNull);
      expect(out.items[2].publishedAt, isNull);
      expect(out.items[3].publishedAt, isNull);
      // 第 5 条是合法对照
      expect(out.items[4].publishedAt, DateTime.utc(2026, 10, 8, 5, 18, 50));
    });

    test('缺 enclosure：torrentUrl/magnet/infoHash 全为 null，且不伪造', () {
      final out = RssParser.parse(
        loadEdgeFixture('no_enclosure.xml'),
        feedId: 'f',
        sourceId: 'rss:f',
        clock: () => _now,
      );
      expect(out.items, hasLength(2));
      for (final item in out.items) {
        expect(item.torrentUrl, isNull);
        expect(item.magnet, isNull);
        expect(item.infoHash, isNull);
        expect(item.isDownloadable, isFalse);
        expect(item.bestMagnet, isNull);
      }
      expect(out.items[0].detailUrl.toString(), 'https://example.invalid/detail/1');
      // 类型不对的 enclosure（image/jpeg）会被忽略：既不当种子，也不拿它的 length 当体积
      expect(out.items[1].extra['enclosureType'], isNull);
      expect(out.items[1].sizeBytes, isNull);
    });

    test('非 feed 内容 → SourceException（含根元素提示）', () {
      expect(
        () => RssParser.parse(loadEdgeFixture('nyaa_no_table.html'),
            feedId: 'f', sourceId: 'rss:f', clock: () => _now),
        throwsA(isA<SourceException>()),
      );
    });
  });

  group('RssSource', () {
    test('supportsSearch=false，search() 抛明确异常而不是返回空列表', () async {
      final source = _source(textFactory('<rss version="2.0"><channel/></rss>'));
      expect(source.supportsSearch, isFalse);
      expect(source.id, 'rss:test');
      expect(source.displayName, 'RSS（test）');
      await expectLater(
        source.search('任意'),
        throwsA(isA<SourceException>().having(
          (SourceException e) => e.message,
          'message',
          contains('不支持关键字搜索'),
        )),
      );
    });

    test('latest() 走网络解析并写缓存；第二次命中缓存不发请求', () async {
      final clock = FakeClock(_now);
      final factory = textFactory(loadFixture('generic_acgrip.xml'));
      final source = _source(factory, clock: clock);

      final first = await source.latest();
      expect(first.items, hasLength(5));
      expect(first.fromCache, isFalse);
      expect(first.hasNext, isFalse);
      expect(factory.requestedUris, hasLength(1));

      final second = await source.latest();
      expect(second.items, hasLength(5));
      expect(second.fromCache, isTrue);
      expect(factory.requestedUris, hasLength(1)); // 未过期 → 不发第二次请求
    });

    test('非 UTF-8（GBK）字节：latin1 兜底 + fetch 标记 encodingFallback', () async {
      final clock = FakeClock(_now);
      final factory = RecordingHttpFactory((http.Request request) async {
        return http.Response.bytes(
          loadEdgeFixtureBytes('gbk_feed.xml'),
          200,
          headers: <String, String>{
            'content-type': 'application/xml; charset=gb2312',
          },
        );
      });
      final transport = buildHttp(factory, clock: clock);

      final fetched = await transport.fetch(
        Uri.parse('https://example.invalid/gbk.xml'),
        sourceId: 'rss:gbk',
      );
      expect(fetched.encodingFallback, isTrue);
      expect(fetched.encoding, 'latin1(fallback)');
      expect(fetched.declaredCharset, 'gb2312');

      final source = RssSource(
        feedId: 'gbk',
        feedUrl: Uri.parse('https://example.invalid/gbk.xml'),
        http: transport,
        cache: SourceCache(store: InMemoryKeyValueStore(), clock: clock.call),
        clock: clock.call,
      );
      final page = await source.latest();
      expect(page.items, hasLength(1));
      final item = page.items.single;
      // 中文会变乱码（这是 latin1 兜底的代价，已在 HttpFetch 里显式标记），
      // 但 ASCII 结构与字段必须完好。
      expect(item.id, 'rss:gbk:gbk-0001');
      expect(item.torrentUrl, 'https://example.invalid/gbk-0001.torrent');
      expect(item.sizeBytes, 123456);
      expect(item.publishedAt, DateTime.utc(2026, 10, 8, 2, 0, 0));
      expect(item.title, contains('01 [1080p]'));
      expect(item.episodeHints, <String>['01']);
    });
  });
}
