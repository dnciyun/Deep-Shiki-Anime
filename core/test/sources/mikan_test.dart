/// mikan 源解析单测：RSS（Classic / Search）、单集页（magnet）、番剧详情页（字幕组 + 每集）。
///
/// 全部离线，fixture 来自 2026-10-08 的真实站点抓取。
library;

import 'dart:convert';

import 'package:dsanima_core/sources/sources.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'fixtures.dart';
import 'support.dart';

final DateTime _now = DateTime(2026, 10, 8, 22, 0);

void main() {
  group('MikanRssParser（mikan_classic.xml，真实抓取）', () {
    late ParseOutcome outcome;

    setUpAll(() {
      outcome = MikanRssParser.parse(
        loadFixture('mikan_classic.xml'),
        sourceId: 'mikan',
        clock: () => _now,
      );
    });

    test('6 条 item 里 1 条重复 → 去重后 5 条，并记录 warning', () {
      expect(outcome.items, hasLength(5));
      expect(outcome.skipped, 0);
      expect(outcome.warnings.single, contains('去重'));
    });

    test('第 1 条逐字段正确（含 torrent 扩展命名空间与 enclosure）', () {
      final item = outcome.items.first;
      expect(item.id, 'mikan:f5271d82b0527d6bd12d4c939fea2e13007834f3');
      expect(item.sourceId, 'mikan');
      expect(
        item.title,
        '[Nix-Raws] 新网球王子 U-17 世界杯 决赛成员选拔赛 / '
        'The Prince of Tennis II S03E01 [CR WEB-DL 1080p AVC AAC][简繁内封]',
      );
      expect(item.detailUrl.toString(),
          'https://mikanani.me/Home/Episode/f5271d82b0527d6bd12d4c939fea2e13007834f3');
      expect(
        item.torrentUrl,
        'https://mikanani.me/Download/20261008/'
        'f5271d82b0527d6bd12d4c939fea2e13007834f3.torrent',
      );
      // spec §4.2：mikan RSS 没有 infoHash / magnet，必须留 null 交给 detail()
      expect(item.magnet, isNull);
      expect(item.infoHash, isNull);
      expect(item.isDownloadable, isFalse);
      expect(item.sizeBytes, 1288490240);
      expect(item.extra['contentLength'], 1288490240);
      expect(item.extra['enclosureLength'], 1288490240);
      expect(item.extra['sizeText'], '1.2 GB');
      expect(item.extra['torrentFileHash'], 'f5271d82b0527d6bd12d4c939fea2e13007834f3');
      expect(item.extra['episodeHash'], 'f5271d82b0527d6bd12d4c939fea2e13007834f3');
      expect(item.extra['guid'], item.title);
      expect(item.publishedAt, DateTime(2026, 10, 8, 21, 18, 53, 451, 203));
      expect(item.seeders, isNull); // RSS 不提供做种数
      expect(item.leechers, isNull);
      expect(item.downloads, isNull);
      expect(item.category, isNull);
      expect(item.group, 'Nix-Raws');
      expect(item.episodeHints, <String>['S03E01']);
      expect(item.extra['resolution'], 1080);
      expect(item.extra['subtitleLang'], '简繁');
      expect(item.extra['subtitleType'], '内封');
      expect(item.extra['isBatch'], isFalse);
    });

    test('后续条目 id 取 episode hash，互不重复', () {
      final ids = outcome.items.map((SourceItem i) => i.id).toList();
      expect(ids.toSet(), hasLength(5));
      expect(ids[1], 'mikan:212ba173a1ba8e966feb1c0e1f4d13c91c325ca6');
      for (final id in ids) {
        expect(RegExp(r'^mikan:[0-9a-f]{40}$').hasMatch(id), isTrue, reason: id);
      }
    });

    test('description 末尾的 [11.4GB] 解析为体积兜底', () {
      final item = outcome.items[1];
      expect(item.title, startsWith('[整理搬运] 濑户的花嫁'));
      expect(item.extra['sizeText'], '11.4GB');
      expect(item.sizeBytes, 12240656384); // contentLength 优先于 description
    });

    test('空 feed → 空列表（合法结果，不抛错也不算失败）', () {
      final empty = MikanRssParser.parse(
        loadEdgeFixture('empty_feed.xml'),
        sourceId: 'mikan',
        clock: () => _now,
      );
      expect(empty.items, isEmpty);
      expect(empty.skipped, 0);
    });

    test('非 feed 内容 → SourceException', () {
      expect(
        () => MikanRssParser.parse(loadEdgeFixture('malformed.xml'),
            sourceId: 'mikan', clock: () => _now),
        throwsA(isA<SourceException>()),
      );
    });
  });

  group('MikanRssParser（mikan_search.xml，真实抓取）', () {
    test('5 条搜索结果，第 1 条是合集（01-28）', () {
      final outcome = MikanRssParser.parse(
        loadFixture('mikan_search.xml'),
        sourceId: 'mikan',
        clock: () => _now,
      );
      expect(outcome.items, hasLength(5));
      final item = outcome.items.first;
      expect(item.id, 'mikan:f8651444a2c0b3ff7e3da3cbd75da58ef5f09e19');
      expect(
        item.title,
        '[7³ACG] 葬送的芙莉莲/Sousou no Frieren S01 | 01-28+SPx11 '
        '[简繁字幕] BDrip 1080p x265 OPUS 2.0',
      );
      expect(item.sizeBytes, 52076478464);
      expect(item.extra['sizeText'], '48.5GB');
      expect(item.group, '7³ACG');
      expect(item.extra['resolution'], 1080);
      expect(item.extra['subtitleLang'], '简繁');
      expect(item.extra['isBatch'], isTrue);
      expect(item.episodeHints, isEmpty); // 合集不产出单集提示
    });
  });

  group('MikanEpisodeParser（mikan_episode_f5271d82.html，真实抓取）', () {
    test('补出 magnet / infoHash / 字幕组 / 大小 / 日期', () {
      final base = SourceItem(
        id: 'mikan:f5271d82b0527d6bd12d4c939fea2e13007834f3',
        sourceId: 'mikan',
        title: 'RSS 标题',
        detailUrl: Uri.parse(
            'https://mikanani.me/Home/Episode/f5271d82b0527d6bd12d4c939fea2e13007834f3'),
        torrentUrl: 'https://mikanani.me/Download/20261008/'
            'f5271d82b0527d6bd12d4c939fea2e13007834f3.torrent',
      );
      final item = MikanEpisodeParser.parse(
        loadFixture('mikan_episode_f5271d82.html'),
        base: base,
        url: base.detailUrl!,
        sourceId: 'mikan',
        clock: () => _now,
      );

      expect(item, isNotNull);
      expect(item!.magnet, startsWith(
          'magnet:?xt=urn:btih:f5271d82b0527d6bd12d4c939fea2e13007834f3'));
      expect(item.infoHash, 'f5271d82b0527d6bd12d4c939fea2e13007834f3');
      expect(item.isDownloadable, isTrue);
      expect(item.bestMagnet, item.magnet);
      // 单集页里的标题去掉了尾部 `[1.2 GB]`
      expect(
        item.title,
        '[Nix-Raws] 新网球王子 U-17 世界杯 决赛成员选拔赛 / '
        'The Prince of Tennis II S03E01 [CR WEB-DL 1080p AVC AAC][简繁内封]',
      );
      expect(item.sizeBytes, 1200000000); // 文件大小：1.2 GB
      expect(item.extra['sizeText'], '1.2 GB');
      expect(item.group, 'Nix-Raws');
      expect(item.extra['bangumiTitle'], '新网球王子 U-17 世界杯 决赛成员选拔赛');
      expect(item.extra['publishedText'], '今天 21:18');
      expect(item.publishedAt, DateTime(2026, 10, 8, 21, 18));
      expect(item.extra['detailFetched'], isTrue);
      // 单集页里 `p.bangumi-title a` 指向 `/Home/Bangumi/4094`：宿主靠这个 id 去
      // 番剧页取**整部番的剧集清单**（播放列表要凑齐前几集，用户 2026-10-11
      // 「我点第8集就没有765等」）。丢了它，播放列表就只能有当前这一批。
      expect(item.extra['bangumiId'], '4094');
      expect(item.episodeHints, <String>['S03E01']);
    });

    test('episodeHashOf / bangumiIdOf 从 detailUrl 提取', () {
      final episode = SourceItem(
        id: 'mikan:x',
        sourceId: 'mikan',
        detailUrl: Uri.parse(
            'https://mikanani.me/Home/Episode/f5271d82b0527d6bd12d4c939fea2e13007834f3'),
      );
      expect(MikanSource.episodeHashOf(episode),
          'f5271d82b0527d6bd12d4c939fea2e13007834f3');
      expect(MikanSource.bangumiIdOf(episode), isNull);

      final bangumi = SourceItem(
        id: 'mikan:4094',
        sourceId: 'mikan',
        detailUrl: Uri.parse('https://mikanani.me/Home/Bangumi/4094'),
      );
      expect(MikanSource.bangumiIdOf(bangumi), '4094');
      expect(MikanSource.episodeHashOf(bangumi), isNull);
    });
  });

  group('MikanBangumiParser（mikan_bangumi_4094.html，真实抓取）', () {
    late MikanBangumiDetail detail;

    setUpAll(() {
      detail = MikanBangumiParser.parse(
        loadFixture('mikan_bangumi_4094.html'),
        url: Uri.parse('https://mikanani.me/Home/Bangumi/4094'),
        sourceId: 'mikan',
        clock: () => _now,
      );
    });

    test('番剧标题与 3 个字幕组', () {
      expect(detail.bangumiId, '4094');
      expect(detail.title, '新网球王子 U-17 世界杯 决赛成员选拔赛');
      expect(detail.groups, hasLength(3));
      expect(
        detail.groups.map((MikanSubtitleGroup g) => g.name).toList(),
        <String>['Nix-Raws', 'ANi', 'Kirara Fantasia'],
      );
      expect(detail.groups.map((MikanSubtitleGroup g) => g.id).toList(),
          <String>['1256', '583', '615']);
      expect(
        detail.groups.first.rssUrl.toString(),
        'https://mikanani.me/RSS/Bangumi?bangumiId=4094&subgroupid=1256',
      );
    });

    test('6 集全部解析出 magnet、大小、日期、字幕组', () {
      expect(detail.episodes, hasLength(6));
      expect(detail.skipped, 0);
      expect(detail.warnings, isEmpty);

      final first = detail.episodes.first;
      expect(first.id, 'mikan:f5271d82b0527d6bd12d4c939fea2e13007834f3');
      expect(first.magnet, startsWith(
          'magnet:?xt=urn:btih:f5271d82b0527d6bd12d4c939fea2e13007834f3'));
      expect(first.infoHash, 'f5271d82b0527d6bd12d4c939fea2e13007834f3');
      expect(first.torrentUrl,
          'https://mikanani.me/Download/20261008/f5271d82b0527d6bd12d4c939fea2e13007834f3.torrent');
      expect(first.sizeBytes, 1200000000);
      expect(first.publishedAt, DateTime(2026, 10, 8, 21, 18));
      expect(first.group, 'Nix-Raws');
      expect(first.extra['subtitleGroupId'], '1256');
      expect(first.extra['bangumiId'], '4094');
      expect(first.episodeHints, <String>['S03E01']);

      // 每个字幕组各自贡献若干集
      expect(detail.episodes.map((SourceItem i) => i.group).toSet(),
          <String>{'Nix-Raws', 'ANi', 'Kirara Fantasia'});
      // 全部 6 集都有可直接下载的 magnet
      for (final episode in detail.episodes) {
        expect(episode.infoHash, isNotNull, reason: episode.id);
        expect(episode.bestMagnet, isNotNull);
      }
    });

    test('没有剧集表格且没有字幕组时抛错（结构变化要显式暴露）', () {
      expect(
        () => MikanBangumiParser.parse(
          loadEdgeFixture('nyaa_no_table.html'),
          url: Uri.parse('https://mikanani.me/Home/Bangumi/1'),
          sourceId: 'mikan',
          clock: () => _now,
        ),
        throwsA(isA<SourceException>()),
      );
    });
  });

  group('MikanSource URL 与分页语义', () {
    late MikanSource source;

    setUp(() {
      final clock = FakeClock(_now);
      source = MikanSource(
        http: buildHttp(textFactory(''), clock: clock),
        cache: SourceCache(store: InMemoryKeyValueStore(), clock: clock.call),
        clock: clock.call,
      );
    });

    test('URL 严格照 spec：最新走 RSS，搜索走 HTML 搜索页', () {
      expect(source.classicRssUri().toString(),
          'https://mikanani.me/RSS/Classic');
      // 搜索走 HTML（2026-10-12 修正）：RSS/Search 上限 100 条，HTML 搜索页实测 1000 条。
      expect(source.searchHtmlUri('葬送的芙莉莲').toString(),
          'https://mikanani.me/Home/Search?searchstr=%E8%91%AC%E9%80%81%E7%9A%84%E8%8A%99%E8%8E%89%E8%8E%B2');
      expect(source.episodeUri('abc').toString(),
          'https://mikanani.me/Home/Episode/abc');
      expect(source.bangumiUri(4094).toString(),
          'https://mikanani.me/Home/Bangumi/4094');
    });

    test('latest/search 的 page>1 返回空页（两个接口都没有分页参数）', () async {
      final latest = await source.latest(page: 2);
      expect(latest.items, isEmpty);
      expect(latest.hasNext, isFalse);
      final search = await source.search('任意', page: 3);
      expect(search.items, isEmpty);
      expect(search.hasNext, isFalse);
    });

    test('搜索真的打到 HTML 搜索页，并把 1000 条那批行全解析出来', () async {
      final clock = FakeClock(_now);
      final factory = textFactory(
        loadFixture('mikan_search.html'),
        contentType: 'text/html; charset=utf-8',
      );
      final s = MikanSource(
        http: buildHttp(factory, clock: clock),
        cache: SourceCache(store: InMemoryKeyValueStore(), clock: clock.call),
        clock: clock.call,
      );
      final page = await s.search('葬送的芙莉莲');
      expect(factory.requestedUris.single.toString(),
          'https://mikanani.me/Home/Search?searchstr=%E8%91%AC%E9%80%81%E7%9A%84%E8%8A%99%E8%8E%89%E8%8E%B2');
      // fixture 里裁了 3 行；这里断言"有几行就给几条"，以及字段真的是解析出来的。
      expect(page.items, hasLength(3));
      expect(page.hasNext, isFalse);
      final first = page.items.first;
      expect(first.id, 'mikan:f8651444a2c0b3ff7e3da3cbd75da58ef5f09e19');
      expect(first.infoHash, 'f8651444a2c0b3ff7e3da3cbd75da58ef5f09e19');
      expect(first.magnet, contains('xt=urn:btih:f8651444a2c0b3ff7e3da3cbd75da58ef5f09e19'));
      expect(first.sizeBytes, parseSizeToBytes('48.5GB'));
      expect(first.publishedAt, DateTime(2026, 8, 28, 5, 32));
      expect(first.detailUrl.toString(),
          'https://mikanani.me/Home/Episode/f8651444a2c0b3ff7e3da3cbd75da58ef5f09e19');
      expect(first.torrentUrl,
          'https://mikanani.me/Download/20260828/f8651444a2c0b3ff7e3da3cbd75da58ef5f09e19.torrent');
      // 搜索页没有 div.subgroup-text：不得编一个"未知字幕组"的假名字。
      expect(first.extra['bangumiTitle'], isNull);
    });

    test('空关键字 → SourceException', () async {
      expect(() => source.search('  '), throwsA(isA<SourceException>()));
    });

    test('detail() 对既不是单集也不是番剧的条目返回 null', () async {
      final item = SourceItem(id: 'mikan:x', sourceId: 'mikan');
      expect(await source.detail(item), isNull);
    });
  });

  group('缓存键：latest（RSS）与 schedule（首页）不许共用一条', () {
    test('交替调用各命中各的缓存 —— 键相同就会互相顶掉、每次都真打站点', () async {
      // 旧实现里 schedule() 用的是 `CacheRequest.latest()`（键 `latest:p1`），
      // 而两者的载荷形状完全不同（`{items,hasNext,page}` vs `{schedule,skipped}`），
      // core 各自把对方的载荷判成 miss ⇒ 交替调用时永远打网络，
      // 注释里承诺的"反复切页不会反复打站点"不成立。
      final clock = FakeClock(_now);
      final cache = SourceCache(store: InMemoryKeyValueStore(), clock: clock.call);
      var requests = 0;
      final factory = RecordingHttpFactory((http.Request request) async {
        requests++;
        final String body = request.url.path == '/'
            ? loadFixture('mikan_home_schedule.html')
            : loadFixture('mikan_classic.xml');
        return http.Response.bytes(
          utf8.encode(body),
          200,
          headers: <String, String>{
            'content-type': request.url.path == '/'
                ? 'text/html; charset=utf-8'
                : 'application/xml; charset=utf-8',
          },
        );
      });
      final source = MikanSource(
        http: buildHttp(factory, clock: clock),
        cache: cache,
        clock: clock.call,
      );

      final firstSchedule = await source.schedule();
      expect(firstSchedule.entries, isNotEmpty);
      expect(requests, 1);

      final firstPage = await source.latest();
      expect(firstPage.items, isNotEmpty);
      expect(requests, 2, reason: '首页载荷不能被当成 RSS 那一页的缓存');

      await source.schedule();
      expect(requests, 2, reason: 'schedule 第二次要命中自己的缓存');

      await source.latest();
      expect(requests, 2, reason: 'latest 第二次也要命中自己的缓存');
    });
  });
}
