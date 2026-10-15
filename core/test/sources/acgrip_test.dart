/// ACG.RIP 源单测：列表页解析、两个分区（动画 / 合集）、搜索 URL、.torrent → infohash。
///
/// 全部离线；HTML 是 **2026-10-12** 从 `acg.rip` 真实抓取后裁掉多余行的原文，
/// `.torrent` 是同一天抓的**真种子**（24 KB），用来证明 infohash 算法是对的
/// —— 它算出来必须等于 ACGNX 上同一条种子的 infohash（见下面那条断言）。
library;

import 'package:dsanima_core/sources/sources.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures.dart';
import 'support.dart';

final DateTime _now = DateTime(2026, 10, 12, 12, 0);

/// `https://acg.rip/t/365077.torrent` 的真实 infohash。
///
/// 互证方式：ACGNX 的 `rss-2.xml` 里同一条「[ToonsHub] 转生贵族…01-12」的 magnet
/// 写的就是这个 hash（`test/fixtures/acgnx_batch.xml` 第 1 条）。两个站 + 两种来源
/// （magnet 文本 vs `sha1(bencode(info))`）对上同一个值，说明算法没走偏。
const String _frierenHash = '0c6e76513b0f145f17220ee80de45b870d922b15';

void main() {
  group('AcgRipListParser（acgrip_list.html，真实抓取）', () {
    late ParseOutcome outcome;

    setUpAll(() {
      outcome = AcgRipListParser.parse(
        loadFixture('acgrip_list.html'),
        sourceId: 'acgrip',
        categoryLabel: '动画',
        clock: () => _now,
      );
    });

    test('3 行全部解析出来、没有跳过，并给出「还有下一页」', () {
      expect(outcome.items, hasLength(3));
      expect(outcome.skipped, 0);
      expect(outcome.warnings, isEmpty);
      expect(outcome.hasNext, isTrue);
    });

    test('第 1 条逐字段正确（含 unix 秒发布时间）', () {
      final item = outcome.items.first;
      expect(item.id, 'acgrip:365075');
      expect(item.sourceId, 'acgrip');
      expect(item.title,
          '[Yuuki] 一觉醒来就有了最强装备跟太空船 / Saikyou Soubi - 02 HEVC 1080P 简繁日三语 MKV');
      expect(item.detailUrl.toString(), 'https://acg.rip/t/365075');
      // 列表行里就有 .torrent 直链（不像 dmhy 只有磁力）。
      expect(item.torrentUrl, 'https://acg.rip/t/365075.torrent');
      // ⚠️ 这个站**没有磁力**：列表页绝不许编一个。
      expect(item.magnet, isNull);
      expect(item.infoHash, isNull);
      expect(item.isDownloadable, isFalse,
          reason: '还没走 detail() 补 infohash，就不该说它能下');
      expect(item.sizeBytes, 225200000);
      expect(item.publishedAt, DateTime.fromMillisecondsSinceEpoch(1791799048 * 1000,
          isUtc: true));
      expect(item.category, '动画');
      expect(item.group, 'Yuuki', reason: '标题前缀里的字幕组');
      // 列表行没有 span.label-team（搜索页才有），所以这里没有 team 字段 —— 不编。
      expect(item.extra.containsKey('team'), isFalse);
      expect(item.extra['partition'], '动画');
      expect(item.extra['sizeText'], '225.2 MB');
      expect(item.extra['fromHtmlList'], isTrue);
    });

    test('合集分区：条目 id 帶自己的源前缀，category 是「合集」', () {
      final batch = AcgRipListParser.parse(
        loadFixture('acgrip_batch.html'),
        sourceId: 'acgrip-batch',
        categoryLabel: '合集',
        clock: () => _now,
      );
      expect(batch.items, hasLength(3));
      expect(batch.items.first.id, startsWith('acgrip-batch:'));
      expect(batch.items.first.category, '合集');
      expect(batch.items.first.sourceId, 'acgrip-batch');
    });

    test('没有 a[rel=next]（最后一页）→ hasNext=false', () {
      final last = AcgRipListParser.parse(
        '<html><body><table class="table post-index"><tr><th>标题</th></tr>'
        '<tr><td class="date"><time datetime="1791799048">x</time></td>'
        '<td class="title"><a href="/t/1">t</a></td>'
        '<td class="action"><a href="/t/1.torrent">dl</a></td>'
        '<td class="size">1 MB</td></tr></table></body></html>',
        sourceId: 'acgrip',
        clock: () => _now,
      );
      expect(last.items, hasLength(1));
      expect(last.hasNext, isFalse);
    });

    test('结构不认识 → 抛 SourceException（不返回空列表假装成功）', () {
      expect(
        () => AcgRipListParser.parse(
          '<html><body><p>这不是列表页</p></body></html>',
          sourceId: 'acgrip',
          clock: () => _now,
        ),
        throwsA(isA<SourceException>()),
      );
    });
  });

  group('AcgRipSource：身份、URL、缓存', () {
    late AcgRipSource source;

    setUp(() {
      source = AcgRipSource(
        http: buildHttp(textFactory('')),
        cache: SourceCache(store: InMemoryKeyValueStore()),
        clock: () => _now,
      );
    });

    test('默认身份 = 动画分区', () {
      expect(source.id, 'acgrip');
      expect(source.displayName, 'ACG.RIP · 动画');
      expect(source.category, kAcgRipAnimeCategory);
      expect(source.baseUrl, 'https://acg.rip');
      expect(source.supportsSearch, isTrue);
    });

    test('合集分区实例：独立 id + 自己的列表 URL', () {
      final batch = AcgRipSource(
        http: buildHttp(textFactory('')),
        cache: SourceCache(store: InMemoryKeyValueStore()),
        id: 'acgrip-batch',
        displayName: 'ACG.RIP · 合集',
        category: kAcgRipBatchCategory,
        clock: () => _now,
      );
      expect(batch.id, 'acgrip-batch');
      expect(batch.displayName, 'ACG.RIP · 合集');
      expect(batch.categoryLabel, '合集');
      expect(batch.latestUri(1).toString(), 'https://acg.rip/5');
      expect(batch.latestUri(3).toString(), 'https://acg.rip/5/page/3');
    });

    test('「最新」URL：第 1 页不带 /page/', () {
      expect(source.latestUri(1).toString(), 'https://acg.rip/1');
      expect(source.latestUri(2).toString(), 'https://acg.rip/1/page/2');
    });

    test('搜索 URL 在分区内生效，且中文关键字百分号编码', () {
      expect(source.searchUri('学生会', 1).toString(),
          'https://acg.rip/1?term=%E5%AD%A6%E7%94%9F%E4%BC%9A');
      expect(source.searchUri('学生会', 2).toString(),
          'https://acg.rip/1/page/2?term=%E5%AD%A6%E7%94%9F%E4%BC%9A');
    });

    test('端到端（假 HTTP）：search 打到 /1?term= 并把整页解析出来', () async {
      final factory = textFactory(
        loadFixture('acgrip_search.html'),
        contentType: 'text/html; charset=utf-8',
      );
      final s = AcgRipSource(
        http: buildHttp(factory),
        cache: SourceCache(store: InMemoryKeyValueStore()),
        clock: () => _now,
      );
      final page = await s.search('学生会');
      expect(factory.requestedUris.single.path, '/1');
      expect(factory.requestedUris.single.queryParameters['term'], '学生会');
      expect(page.items, hasLength(3));
      expect(page.hasNext, isTrue);
      expect(page.fromCache, isFalse);
      // 搜索行的 `span.label-team` 是字幕组链接（列表页没有这一块）。
      expect(page.items.first.extra['team'], '悠哈璃羽');
    });

    test('同参数第二轮命中缓存，不再打网络', () async {
      final factory = textFactory(
        loadFixture('acgrip_list.html'),
        contentType: 'text/html; charset=utf-8',
      );
      final s = AcgRipSource(
        http: buildHttp(factory),
        cache: SourceCache(store: InMemoryKeyValueStore()),
        clock: () => _now,
      );
      await s.latest();
      final again = await s.latest();
      expect(again.fromCache, isTrue);
      expect(factory.requestedUris, hasLength(1));
    });

    test('空关键字 / page<1 → SourceException', () async {
      await expectLater(source.search('   '), throwsA(isA<SourceException>()));
      await expectLater(source.latest(page: 0), throwsA(isA<SourceException>()));
    });

    test('topicIdOf 支持两个分区的 id 前缀与 detailUrl 两种来源', () {
      expect(
        AcgRipSource.topicIdOf(SourceItem(id: 'acgrip:365075', sourceId: 'acgrip')),
        '365075',
      );
      expect(
        AcgRipSource.topicIdOf(
          SourceItem(id: 'acgrip-batch:365077', sourceId: 'acgrip-batch'),
        ),
        '365077',
      );
      expect(
        AcgRipSource.topicIdOf(SourceItem(
          id: 'x',
          sourceId: 'acgrip',
          detailUrl: Uri.parse('https://acg.rip/t/42'),
        )),
        '42',
      );
    });

    test('构造源不得触发任何网络', () {
      final factory = textFactory('');
      final s = AcgRipSource(
        http: buildHttp(factory),
        cache: SourceCache(store: InMemoryKeyValueStore()),
      );
      expect(s.id, 'acgrip');
      expect(factory.createCount, 0, reason: '构造源不得触发任何网络');
    });
  });

  group('detail()：下载 .torrent 算 infohash（这个站没有磁力）', () {
    test('真种子 → infohash 与 ACGNX 上同一条种子逐字一致', () async {
      final factory = textFactory(
        '',
        contentType: 'application/x-bittorrent',
        bytes: loadFixtureBytes('acgrip_365077.torrent'),
      );
      final s = AcgRipSource(
        http: buildHttp(factory),
        cache: SourceCache(store: InMemoryKeyValueStore()),
        clock: () => _now,
      );

      final base = SourceItem(
        id: 'acgrip:365077',
        sourceId: 'acgrip',
        title: '[ToonsHub] 转生贵族凭鉴定技能扭转人生 第二季 - 01-12',
        detailUrl: Uri.parse('https://acg.rip/t/365077'),
        torrentUrl: 'https://acg.rip/t/365077.torrent',
      );
      final enriched = (await s.detail(base))!;

      expect(factory.requestedUris.single.toString(),
          'https://acg.rip/t/365077.torrent');
      expect(enriched.infoHash, _frierenHash);
      // bestMagnet 从 infohash 拼得出来 —— 队列/播放链路就是靠它加种。
      expect(enriched.bestMagnet, 'magnet:?xt=urn:btih:$_frierenHash');
      expect(enriched.isDownloadable, isTrue);
      // 体积用种子里的精确字节数覆盖站点那个近似值。
      expect(enriched.sizeBytes, 18100050897);
      expect(enriched.extra['infoHashFromTorrent'], isTrue);
      expect(enriched.extra['torrentName'],
          'As.a.Reincarnated.Aristocrat.Ill.Use.My.Appraisal.Skill.to.Rise.in.the.World.S02');
      expect(enriched.title, base.title, reason: '列表页给的标题不许被详情页改掉');
    });

    test('第二轮命中 detail 缓存：不再下一次种子', () async {
      final factory = textFactory(
        '',
        contentType: 'application/x-bittorrent',
        bytes: loadFixtureBytes('acgrip_365077.torrent'),
      );
      final s = AcgRipSource(
        http: buildHttp(factory),
        cache: SourceCache(store: InMemoryKeyValueStore()),
        clock: () => _now,
      );
      final base = SourceItem(
        id: 'acgrip:365077',
        sourceId: 'acgrip',
        detailUrl: Uri.parse('https://acg.rip/t/365077'),
      );
      await s.detail(base);
      final again = await s.detail(base);
      expect(again!.infoHash, _frierenHash);
      expect(factory.requestedUris, hasLength(1), reason: 'detail 缓存没生效');
    });

    test('拿到的不是种子（HTML 错误页）→ 抛 SourceException，不编假 hash', () async {
      final factory = textFactory(
        '<html>error</html>',
        contentType: 'text/html; charset=utf-8',
      );
      final s = AcgRipSource(
        http: buildHttp(factory),
        cache: SourceCache(store: InMemoryKeyValueStore()),
        clock: () => _now,
      );
      await expectLater(
        s.detail(SourceItem(
          id: 'acgrip:1',
          sourceId: 'acgrip',
          detailUrl: Uri.parse('https://acg.rip/t/1'),
        )),
        throwsA(isA<SourceException>()),
      );
    });

    test('没有 /t/<id> 的条目 → 返回 null（不猜）', () async {
      final s = AcgRipSource(
        http: buildHttp(textFactory('')),
        cache: SourceCache(store: InMemoryKeyValueStore()),
        clock: () => _now,
      );
      expect(await s.detail(SourceItem(id: 'x', sourceId: 'acgrip')), isNull);
    });
  });

  group('bencode：infoHash / name / 总字节', () {
    test('真种子（24 KB，多文件）', () {
      final bytes = loadFixtureBytes('acgrip_365077.torrent');
      expect(infoHashFromTorrentBytes(bytes), _frierenHash);
      expect(torrentTotalBytesFromBytes(bytes), 18100050897);
      expect(torrentNameFromBytes(bytes),
          'As.a.Reincarnated.Aristocrat.Ill.Use.My.Appraisal.Skill.to.Rise.in.the.World.S02');
    });

    test('info 区间的 sha1 必须等于整段的 sha1（不是重新编码后的结果）', () {
      final bytes = loadFixtureBytes('acgrip_365077.torrent');
      final range = infoDictRange(bytes)!;
      expect(range.length, 23759);
      expect(bytes[range.start], 0x64 /* d */);
      expect(bytes[range.end - 1], 0x65 /* e */);
    });

    test('单文件种子（手工构造）', () {
      final bytes = _torrent(name: 'ep.mkv', length: 1234);
      final hash = infoHashFromTorrentBytes(bytes);
      expect(hash, isNotNull);
      expect(hash, hasLength(40));
      expect(torrentNameFromBytes(bytes), 'ep.mkv');
      expect(torrentTotalBytesFromBytes(bytes), 1234);
    });

    test('不是 bencode / 缺 info / 被截断 → null（绝不抛异常）', () {
      expect(infoHashFromTorrentBytes(<int>[]), isNull);
      expect(infoHashFromTorrentBytes('hello'.codeUnits), isNull);
      expect(infoHashFromTorrentBytes('d3:foo3:bare'.codeUnits), isNull);
      final whole = _torrent(name: 'ep.mkv', length: 1234);
      expect(infoHashFromTorrentBytes(whole.sublist(0, whole.length - 3)), isNull);
      expect(torrentTotalBytesFromBytes('d4:infod4:name3:a.tve'.codeUnits), isNull);
    });
  });
}

/// 手工构造一个单文件 `.torrent`（bencode），测试用。
///
/// 长度全部按字节数算出来 —— 手写 `20:http://example.com/` 这种数字最容易数错，
/// 数错就变成"非法 bencode"，测试会以假乱真地绿/红。
List<int> _torrent({required String name, required int length}) {
  String str(String s) => '${s.length}:$s';
  final info = 'd${str('length')}i${length}e${str('name')}${str(name)}'
      '${str('piece length')}i16384e${str('pieces')}0:'
      'e';
  final body = 'd${str('announce')}${str('http://example.com/')}'
      '${str('info')}$info'
      'e';
  return body.codeUnits;
}
