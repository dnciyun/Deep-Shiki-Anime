/// bangumi.moe 源单测：分区列表（POST tag 搜索）、关键词搜索、字幕组改名、
/// 分页的两条 hasNext 规则、坏响应的诚实报错。
///
/// 全部离线；样本是 **2026-10-12 从 `bangumi.moe` 真实抓取**的 JSON
/// （`test/fixtures/bangumi_moe_*.json`，抓取命令与裁剪方式见
/// `test/fixtures/README.md`）。
library;

import 'dart:convert';

import 'package:dsanima_core/sources/sources.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'fixtures.dart';
import 'support.dart';

final DateTime _now = DateTime(2026, 10, 12, 12, 0);

/// 站点真实响应里的第一条（`/api/torrent/search` 動畫第 1 页）。
const String _firstTorrentId = '6accbe4d992853e4c9c24765';
const String _firstInfoHash = '2d3536714e37b34584de18bc7e626332741c8449';

/// 按路径分发的假工厂：本源取一页要打两次请求（列表 + 字幕组改名），
/// 所以不能像单请求源那样只回一段固定文本。
RecordingHttpFactory _routedFactory(
  Map<String, String> bodies, {
  String? failPath,
  int failStatus = 500,
  List<http.Request>? seen,
}) {
  return RecordingHttpFactory((http.Request request) async {
    seen?.add(request);
    final String path = request.url.path;
    if (failPath != null && path == failPath) {
      return http.Response('boom', failStatus);
    }
    final String? body = bodies[path];
    if (body == null) {
      return http.Response.bytes(
        utf8.encode('{"success":false,"message":"未预料的路径 $path"}'),
        200,
        headers: <String, String>{
          'content-type': 'application/json; charset=utf-8',
        },
      );
    }
    return http.Response.bytes(
      utf8.encode(body),
      200,
      headers: <String, String>{
        'content-type': 'application/json; charset=utf-8',
      },
    );
  });
}

BangumiMoeSource _build(
  RecordingHttpFactory factory, {
  String? id,
  String? displayName,
  List<String>? tagIds,
  String partitionLabel = '動畫',
}) =>
    BangumiMoeSource(
      http: buildHttp(factory),
      cache: SourceCache(store: InMemoryKeyValueStore()),
      clock: () => _now,
      id: id,
      displayName: displayName,
      tagIds: tagIds,
      partitionLabel: partitionLabel,
    );

/// 一页 30 条、**没有 page_count** 的合成样本（覆盖「按满不满 30 条推 hasNext」）。
String _thirtyItemPage() {
  final String hash = List<String>.filled(40, 'a').join();
  final String item = jsonEncode(<String, Object?>{
    '_id': 'synth',
    'title': '[组名] 测试番 01 [1080P]',
    'magnet': 'magnet:?xt=urn:btih:$hash',
    'infoHash': hash,
    'size': '1 GB',
    'team_id': null,
  });
  return '{"torrents":[${List<String>.filled(30, item).join(',')}]}';
}

void main() {
  final String anime = loadFixture('bangumi_moe_tag_anime.json');
  final String animePage2 = loadFixture('bangumi_moe_tag_anime_page2.json');
  final String collection = loadFixture('bangumi_moe_tag_collection.json');
  final String search = loadFixture('bangumi_moe_search.json');
  final String teams = loadFixture('bangumi_moe_team_fetch.json');

  group('分区列表：POST /api/torrent/search（真实样本）', () {
    test('一页 5 条；两次请求（列表 + 字幕组改名）；站点的 page_count → 还有下一页', () async {
      final List<http.Request> seen = <http.Request>[];
      final RecordingHttpFactory factory = _routedFactory(
        <String, String>{
          '/api/torrent/search': anime,
          '/api/team/fetch': teams,
        },
        seen: seen,
      );
      final SourcePage page = await _build(factory).latest();

      expect(page.items, hasLength(5));
      expect(page.hasNext, isTrue, reason: 'page_count=7148 > 1');
      expect(page.page, 1);
      expect(page.fromCache, isFalse);
      expect(seen, hasLength(2), reason: '列表一次 + 字幕组改名一次（都还没有缓存）');

      // ① 列表：POST + body 里带类型/tag/页码（GET 版本 404，见库注释）。
      final http.Request list = seen.first;
      expect(list.method, 'POST');
      expect(list.url.path, '/api/torrent/search');
      final Map<String, dynamic> body =
          jsonDecode(list.body) as Map<String, dynamic>;
      expect(body['type'], 'tag');
      expect(body['tag_id'], kBangumiMoeAnimeTags);
      expect(body['p'], 1);

      // ② 字幕组：一次批量问本页 3 个不同的 team_id（不是每条打一次）。
      final http.Request teamRequest = seen.last;
      expect(teamRequest.url.path, '/api/team/fetch');
      final Map<String, dynamic> teamBody =
          jsonDecode(teamRequest.body) as Map<String, dynamic>;
      expect(teamBody['_ids'], hasLength(3));
      expect(teamBody['_ids'], contains('567eb203305cd5e56819b001'));
    });

    test('第 1 条逐字段（磁力/体积/做种数/UTC 发布时间/分类）', () async {
      final factory = _routedFactory(<String, String>{
        '/api/torrent/search': anime,
        '/api/team/fetch': teams,
      });
      final SourceItem item = (await _build(factory).latest()).items.first;

      expect(item.id, 'bangumimoe:$_firstTorrentId');
      expect(item.sourceId, 'bangumimoe');
      expect(item.title, contains('黑色五叶草 2nd Season'));
      expect(item.detailUrl.toString(),
          'https://bangumi.moe/torrent/$_firstTorrentId');
      // 站点自己的下载链接拼法：`/download/torrent/<id>/<标题>.torrent`。
      expect(item.torrentUrl, startsWith('https://bangumi.moe/download/torrent/'));
      expect(item.torrentUrl, endsWith('.torrent'));
      expect(item.magnet,
          'magnet:?xt=urn:btih:$_firstInfoHash');
      expect(item.infoHash, _firstInfoHash);
      expect(item.sizeBytes, 1040000000, reason: '站点写的 "1.04 GB" 按十进制 GB 换算');
      // ⚠️ 0 是站点真实上报的做种数（新种子就是 0），不是"拿不到"。
      expect(item.seeders, 0);
      expect(item.leechers, 0);
      expect(item.downloads, 4);
      expect(item.publishedAt, DateTime.utc(2026, 10, 12, 11, 2, 37, 939));
      expect(item.category, '動畫', reason: '列表接口不返回分区名，用源自己的分区配置');
      expect(item.group, 'NEO·QSW', reason: 'team_id → /api/team/fetch 里的名字');
      expect(item.extra['partition'], '動畫');
      expect(item.extra['sizeText'], '1.04 GB');
      expect(item.extra['torrentId'], _firstTorrentId);
      expect(item.extra['categoryTagId'], kBangumiMoeDongaTagId);
      expect(item.extra['teamId'], '567eb203305cd5e56819b001');
      expect(item.extra['fromJsonApi'], isTrue);
      expect(item.extra['fileCount'], 1);
      expect(item.isDownloadable, isTrue);
      // 站点自己在 `sync` 里给了同一份种子在 dmhy / acgrip 的地址 —— 顺手带出来。
      expect(item.extra['syncedSites'], <String>['dmhy', 'acgrip']);
    });

    test('字幕组换不到的那条回落到标题前缀（不编名字）', () async {
      final factory = _routedFactory(<String, String>{
        '/api/torrent/search': anime,
        '/api/team/fetch': teams,
      });
      final List<SourceItem> items = (await _build(factory).latest()).items;
      expect(items[1].group, '悠哈璃羽字幕社');
      // team_fetch 样本里没有第 5 条那个组 → 回落标题里的【今晚月色真美】。
      expect(items[4].group, '今晚月色真美');
    });

    test('字幕组接口挂了不拖垮列表：group 回落标题前缀，条目照旧', () async {
      final factory = _routedFactory(
        <String, String>{'/api/torrent/search': anime},
        failPath: '/api/team/fetch',
      );
      final SourcePage page = await _build(factory).latest();
      expect(page.items, hasLength(5));
      expect(page.items.first.group, 'NEO·QSW',
          reason: '标题前缀就是这个组名，回落之后仍然可用');
    });

    test('合集分区：独立 id 前缀 + category 是「動畫合集」+ tag 是 AND 的两个 id', () async {
      final factory = _routedFactory(<String, String>{
        '/api/torrent/search': collection,
        '/api/team/fetch': teams,
      });
      final BangumiMoeSource source = _build(
        factory,
        id: 'bangumimoe-collection',
        displayName: 'Bangumi.moe · 動畫合集',
        tagIds: kBangumiMoeAnimeCollectionTags,
        partitionLabel: '動畫合集',
      );
      final SourcePage page = await source.latest();

      expect(page.items, hasLength(3));
      expect(page.items.first.id, startsWith('bangumimoe-collection:'));
      expect(page.items.first.category, '動畫合集');
      expect(page.items.first.extra['partition'], '動畫合集');
      expect(
        source.latestBody(3)['tag_id'],
        <String>[kBangumiMoeDongaTagId, kBangumiMoeCollectionTagId],
        reason: '两个 tag 是 AND：实测只给 Collection 会把电影/音乐/游戏合集也拉进来',
      );
      expect(source.latestBody(3)['p'], 3);
    });
  });

  group('关键词搜索：GET /api/v2/torrent/search（真实样本）', () {
    test('URL：中文百分号编码；第 1 页不带 p，第 2 页带 p', () {
      final BangumiMoeSource source = _build(_routedFactory(<String, String>{}));
      expect(source.searchUri('学生会', 1).toString(),
          'https://bangumi.moe/api/v2/torrent/search?query=%E5%AD%A6%E7%94%9F%E4%BC%9A');
      expect(source.searchUri('学生会', 2).toString(),
          'https://bangumi.moe/api/v2/torrent/search?query=%E5%AD%A6%E7%94%9F%E4%BC%9A&p=2');
      expect(source.latestUri().toString(),
          'https://bangumi.moe/api/torrent/search');
      expect(source.teamFetchUri().toString(),
          'https://bangumi.moe/api/team/fetch');
    });

    test('13 条、hasNext=false（page_count=1）；字幕组用响应里内嵌的 team.name（不打第二枪）', () async {
      final List<http.Request> seen = <http.Request>[];
      final factory = _routedFactory(
        <String, String>{'/api/v2/torrent/search': search},
        seen: seen,
      );
      final SourcePage page = await _build(factory).search('学生会');

      expect(page.items, hasLength(13));
      expect(page.hasNext, isFalse, reason: 'page_count=1');
      expect(seen, hasLength(1), reason: 'v2 搜索的响应自带 team.name，不该再问 team/fetch');
      expect(page.items.first.group, '悠哈璃羽字幕社');
      expect(page.items.first.category, '動畫',
          reason: '分类用站点内嵌的 category_tag（locale.zh_tw），不是源的分区名');
      expect(page.items.first.infoHash,
          '4d357004893937cc8467e8e5a0533afadc77aef2');
      expect(page.items.first.sizeBytes, 436120000);
    });

    test('分类：站点报了就用站点的，没报才用分区名（合集实例搜出来的分类不会被硬贴成「動畫合集」）', () async {
      final String hash = List<String>.filled(40, 'c').join();
      final factory = _routedFactory(<String, String>{
        '/api/v2/torrent/search':
            '{"torrents":['
                '{"_id":"with","title":"[组] 合集条目 01-12","infoHash":"$hash",'
                '"size":"10 GB","team":null,'
                '"category_tag":{"_id":"x","name":"Collection","locale":{"zh_tw":"合集","zh_cn":"合集"}}},'
                '{"_id":"without","title":"[组] 普通条目 03","infoHash":"$hash",'
                '"size":"1 GB","team":null}'
                '],"count":2,"page_count":1,"success":true}',
      });
      final BangumiMoeSource source = _build(
        factory,
        id: 'bangumimoe-collection',
        displayName: 'Bangumi.moe · 動畫合集',
        tagIds: kBangumiMoeAnimeCollectionTags,
        partitionLabel: '動畫合集',
      );
      final SourcePage page = await source.search('游戏');

      expect(page.items[0].category, '合集', reason: '站点自己报的分类优先');
      expect(page.items[0].extra['categoryTagId'], isNull,
          reason: '这条记录没给 category_tag_id —— 不编');
      expect(page.items[1].category, '動畫合集',
          reason: '站点没报分类（分区列表就是这样）→ 用源自己的分区名');
    });

    test('空关键字 → 抛异常且一个请求都不发', () async {
      final List<http.Request> seen = <http.Request>[];
      final factory = _routedFactory(<String, String>{}, seen: seen);
      await expectLater(
        _build(factory).search('   '),
        throwsA(isA<SourceException>().having(
            (SourceException e) => e.message, 'message', contains('关键字不能为空'))),
      );
      expect(seen, isEmpty);
    });
  });

  group('分页：hasNext 的两条规则', () {
    test('第 1 页有 page_count → 用它；最后一页（page == page_count）→ false', () async {
      final factory = _routedFactory(<String, String>{
        '/api/torrent/search': anime,
        '/api/team/fetch': teams,
      });
      final BangumiMoeSource source = _build(factory);
      expect((await source.latest(page: 1)).hasNext, isTrue);
      expect((await source.latest(page: 7148)).hasNext, isFalse);
    });

    test('p>=2 站点不给 page_count → 不满 30 条就算到底', () async {
      final factory = _routedFactory(<String, String>{
        '/api/torrent/search': animePage2,
        '/api/team/fetch': teams,
      });
      final SourcePage page = await _build(factory).latest(page: 2);
      expect(page.items, hasLength(2));
      expect(page.hasNext, isFalse);
    });

    test('p>=2 满 30 条 → 还有下一页（真实响应里就是 30 条）', () async {
      final factory = _routedFactory(<String, String>{
        '/api/torrent/search': _thirtyItemPage(),
      });
      final SourcePage page = await _build(factory).latest(page: 2);
      expect(page.items, hasLength(30));
      expect(page.hasNext, isTrue);
      expect(page.items.first.title, '[组名] 测试番 01 [1080P]');
    });
  });

  group('坏响应：不许把「失败」伪装成「0 条」', () {
    test('站点限流（success=false + too frequently）→ 抛异常并给可行动文案', () async {
      final factory = _routedFactory(<String, String>{
        '/api/v2/torrent/search':
            '{"success":false,"message":"too frequently"}',
      });
      await expectLater(
        _build(factory).search('学生会'),
        throwsA(isA<SourceException>().having(
          (SourceException e) => e.message,
          'message',
          allOf(contains('too frequently'), contains('稍等几秒')),
        )),
      );
    });

    test('不是 JSON（反爬/错误页）→ 抛异常', () async {
      final factory = _routedFactory(<String, String>{
        '/api/torrent/search': '<html><body>Just a moment...</body></html>',
      });
      await expectLater(
        _build(factory).latest(),
        throwsA(isA<SourceException>().having(
            (SourceException e) => e.message, 'message', contains('不是 JSON'))),
      );
    });

    test('JSON 对象但没有 torrents 字段 → 抛异常', () async {
      final factory = _routedFactory(<String, String>{
        '/api/torrent/search': '{"ok":true}',
      });
      await expectLater(
        _build(factory).latest(),
        throwsA(isA<SourceException>().having(
            (SourceException e) => e.message, 'message', contains('没有给出结果列表'))),
      );
    });

    test('空结果页是合法状态：空表 + hasNext=false，不抛', () async {
      final factory = _routedFactory(<String, String>{
        '/api/v2/torrent/search':
            '{"torrents":[],"count":0,"page_count":0,"success":true}',
      });
      final SourcePage page = await _build(factory).search('这个关键词不存在');
      expect(page.items, isEmpty);
      expect(page.hasNext, isFalse);
    });

    test('缺 _id / title 的行被丢掉并计数（不静默）', () async {
      final String hash = List<String>.filled(40, 'b').join();
      final factory = _routedFactory(<String, String>{
        '/api/torrent/search':
            '{"torrents":[{"_id":"","title":"x"},{"title":"没 id"},'
                '{"_id":"ok1","title":"[组] 好条目 01",'
                '"magnet":"magnet:?xt=urn:btih:$hash"}],'
                '"page_count":2}',
      });
      final BangumiMoeSource source = _build(factory);
      final SourcePage page = await source.latest();
      expect(page.items, hasLength(1));
      expect(source.lastSkipped, 2);
      expect(source.lastWarnings, hasLength(2));
      expect(source.lastWarnings.first, contains('缺 _id 或 title'));
    });

    test('page < 1 → 抛异常且一个请求都不发', () async {
      final List<http.Request> seen = <http.Request>[];
      final factory = _routedFactory(<String, String>{}, seen: seen);
      await expectLater(
        _build(factory).latest(page: 0),
        throwsA(isA<SourceException>().having(
            (SourceException e) => e.message, 'message', contains('page 必须 >= 1'))),
      );
      await expectLater(
        _build(factory).search('x', page: -1),
        throwsA(isA<SourceException>()),
      );
      expect(seen, isEmpty);
    });
  });

  group('身份与 URL', () {
    test('默认实例 = 動畫分区', () {
      final BangumiMoeSource source = _build(_routedFactory(<String, String>{}));
      expect(source.id, 'bangumimoe');
      expect(source.displayName, 'Bangumi.moe · 動畫');
      expect(source.tagIds, kBangumiMoeAnimeTags);
      expect(source.partitionLabel, '動畫');
      expect(source.supportsSearch, isTrue);
      expect(source.baseUrl, 'https://bangumi.moe');
    });

    test('.torrent 直链：站点自己的非法字符替换 + 中文百分号编码', () {
      final BangumiMoeSource source = _build(_routedFactory(<String, String>{}));
      final String url = source
          .torrentUriOf('abc', '[组名] 番名 01: "坏字符" / 分割 | 问?')
          .toString();
      expect(url, startsWith('https://bangumi.moe/download/torrent/abc/'));
      expect(url, endsWith('.torrent'));
      // `: " / | ?` 都被换成 `_`（与站点前端同一套正则），其余交给百分号编码。
      expect(Uri.decodeComponent(url.split('/').last), contains('_'));
      expect(url, isNot(contains('"')));
      expect(url, contains('%5B'), reason: '`[` 也要编码，不能裸着进 URL');
    });

    test('tagIds 不能为空（站点没有"不带 tag 的分区列表"端点）', () {
      expect(
        () => BangumiMoeSource(
          http: buildHttp(_routedFactory(<String, String>{})),
          cache: SourceCache(store: InMemoryKeyValueStore()),
          tagIds: const <String>[],
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('合集分区实例：独立 id / 显示名 / tag 列表', () {
      final BangumiMoeSource batch = _build(
        _routedFactory(<String, String>{}),
        id: 'bangumimoe-collection',
        displayName: 'Bangumi.moe · 動畫合集',
        tagIds: kBangumiMoeAnimeCollectionTags,
        partitionLabel: '動畫合集',
      );
      expect(batch.id, 'bangumimoe-collection');
      expect(batch.displayName, 'Bangumi.moe · 動畫合集');
      expect(batch.tagIds, hasLength(2));
      expect(batch.partitionLabel, '動畫合集');
    });
  });

  group('缓存：同一页第二次不再打网络', () {
    test('latest() 命中缓存（fromCache=true，请求数不变）', () async {
      final List<http.Request> seen = <http.Request>[];
      final factory = _routedFactory(
        <String, String>{
          '/api/torrent/search': anime,
          '/api/team/fetch': teams,
        },
        seen: seen,
      );
      final BangumiMoeSource source = _build(factory);
      final SourcePage first = await source.latest();
      expect(first.fromCache, isFalse);
      expect(seen, hasLength(2));

      final SourcePage second = await source.latest();
      expect(second.fromCache, isTrue);
      expect(second.items, hasLength(5));
      expect(seen, hasLength(2), reason: '新鲜缓存命中就不该再打网络');
    });
  });

  group('BangumiMoeParser 单元', () {
    test('readTeams：坏数据返回空表（字幕组名丢了不该让整页失败）', () {
      expect(BangumiMoeParser.readTeams('<html>'), isEmpty);
      expect(BangumiMoeParser.readTeams('{"a":1}'), isEmpty);
      expect(BangumiMoeParser.readTeams('[]'), isEmpty);
      expect(BangumiMoeParser.readTeams(teams), hasLength(2));
    });

    test('readPage：顶层是数组 → 抛异常', () {
      expect(
        () => BangumiMoeParser.readPage('[]', sourceId: 'bangumimoe'),
        throwsA(isA<SourceException>()),
      );
    });

    test('embeddedTeamName：内嵌 team.name 认得出来（决定要不要多打一次改名请求）', () {
      expect(
        BangumiMoeParser.embeddedTeamName(<String, dynamic>{
          'team': <String, dynamic>{'_id': 'x', 'name': ' 悠哈璃羽字幕社 '},
        }),
        '悠哈璃羽字幕社',
      );
      expect(
        BangumiMoeParser.embeddedTeamName(<String, dynamic>{'team': null}),
        isNull,
      );
    });
  });
}
