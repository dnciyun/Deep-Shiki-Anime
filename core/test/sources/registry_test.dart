/// SourceRegistry 单测：默认源、注册/注销、自定义 RSS 接入、代理装配、缓存回落。
library;

import 'package:dsanima_core/sources/sources.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'fixtures.dart';
import 'support.dart';

void main() {
  late FakeClock clock;
  late InMemoryKeyValueStore store;
  late SourceCache cache;

  setUp(() {
    clock = FakeClock(DateTime.utc(2026, 10, 8, 12));
    store = InMemoryKeyValueStore();
    cache = SourceCache(store: store, clock: clock.call);
  });

  SourceRegistry build(
    RecordingHttpFactory factory, {
    ProxyConfig proxy = const ProxyConfig.none(),
  }) {
    return SourceRegistry(
      http: factory,
      cache: cache,
      limiter: RateLimiter(
        minInterval: Duration.zero,
        clock: clock.call,
        sleep: clock.sleep,
      ),
      proxy: proxy,
      clock: clock.call,
    );
  }

  test('默认注册 nyaa / mikan / dmhy + 三个站的分区实例 + bangumi.moe（顺序稳定）', () {
    final registry = build(textFactory(''));
    expect(
      registry.clients.map((SourceClient c) => c.id).toList(),
      <String>[
        'nyaa',
        'mikan',
        'dmhy',
        'dmhy-batch',
        'acgrip',
        'acgnx',
        'acgnx-batch',
        'bangumimoe',
      ],
      reason: '第二十四轮起「全集」实例只剩两个真正按季度全集分区搜的（dmhy-batch / acgnx-batch）',
    );
    expect(registry.byId('nyaa')!.displayName, 'Nyaa（动漫区）');
    expect(registry.byId('mikan')!.displayName, 'Mikan（蜜柑计划）');
    expect(registry.byId('dmhy')!.displayName, '动漫花园（DMHY）');
    expect(registry.byId('dmhy-batch')!.displayName, '动漫花园 · 季度全集（DMHY）');
    expect(registry.byId('acgrip')!.displayName, 'ACG.RIP · 动画');
    expect(registry.byId('acgnx')!.displayName, 'ACGNX · 動畫');
    expect(registry.byId('acgnx-batch')!.displayName, 'ACGNX · 季度全集');
    expect(registry.byId('bangumimoe')!.displayName, 'Bangumi.moe · 動畫');
    expect(registry.byId('nyaa')!.supportsSearch, isTrue);
    expect(registry.byId('dmhy')!.supportsSearch, isTrue);
    expect(registry.byId('dmhy-batch')!.supportsSearch, isTrue);
    expect(registry.byId('acgrip')!.supportsSearch, isTrue);
    expect(registry.byId('acgnx')!.supportsSearch, isTrue);
    expect(registry.byId('bangumimoe')!.supportsSearch, isTrue);
    expect(registry.byId('不存在'), isNull);
    // 第二十四轮用户「ACG.rip bangumi.moe 去除全集源」：这两个实例整个不再注册。
    expect(registry.byId('acgrip-batch'), isNull, reason: 'ACG.RIP · 合集 已按用户要求删掉');
    expect(registry.byId('bangumimoe-collection'), isNull,
        reason: 'Bangumi.moe · 動畫合集 已按用户要求删掉');
    registry.dispose();
  });

  test('两个分区的实例是可区分的（id / 列表 URL / tag 都不同）', () {
    final registry = build(textFactory(''));
    final dmhy = registry.byId('dmhy')! as DmhySource;
    final dmhyBatch = registry.byId('dmhy-batch')! as DmhySource;
    expect(dmhy.animeSortId, kDmhyAnimeSortId);
    expect(dmhyBatch.animeSortId, kDmhyBatchSortId);
    expect(dmhy.latestUri(1).toString(), 'https://share.dmhy.org/topics/list/sort_id/2');
    expect(dmhyBatch.latestUri(1).toString(),
        'https://share.dmhy.org/topics/list/sort_id/31');

    expect((registry.byId('acgrip')! as AcgRipSource).latestUri(1).toString(),
        'https://acg.rip/1');
    expect((registry.byId('acgnx')! as AcgnxSource).latestUri(1).toString(),
        'https://share.acgnx.se/rss-1.xml');
    expect((registry.byId('acgnx-batch')! as AcgnxSource).latestUri(1).toString(),
        'https://share.acgnx.se/rss-2.xml');

    // bangumi.moe：動畫分区 = tag `Donga`（合集那个实例第二十四轮删掉了，类照旧支持 tagIds）。
    final moe = registry.byId('bangumimoe')! as BangumiMoeSource;
    expect(moe.latestUri().toString(), 'https://bangumi.moe/api/torrent/search');
    expect(moe.latestBody(1)['tag_id'], kBangumiMoeAnimeTags);
    registry.dispose();
  });

  test('第二十四轮：搜索 URL 必须带站点自己的分区参数（否则「全集」会搜到单集）', () {
    // 真机证据：build/probe-scope/probe-scope-filters.log
    //   dmhy 关键词「蜡笔小新」：不带 sort_id 80 条（0 合集）/ sort_id=31 → 21 条（12 合集 0 单集）；
    //   acgnx 同一个词：不带 sort_id 50 条（0 合集）/ sort_id=2 → 30 条（17 合集 0 单集）。
    final registry = build(textFactory(''));
    final dmhy = registry.byId('dmhy')! as DmhySource;
    final dmhyBatch = registry.byId('dmhy-batch')! as DmhySource;
    expect(dmhy.searchUri('蜡笔小新', 1).queryParameters['sort_id'], kDmhyAnimeSortId);
    expect(dmhyBatch.searchUri('蜡笔小新', 1).queryParameters['sort_id'], kDmhyBatchSortId);
    expect(dmhyBatch.searchUri('蜡笔小新', 1).queryParameters['keyword'], '蜡笔小新');
    // 第 2 页走路径分页，参数照旧要带。
    expect(dmhyBatch.searchUri('蜡笔小新', 2).path, '/topics/list/page/2');
    expect(dmhyBatch.searchUri('蜡笔小新', 2).queryParameters['sort_id'], kDmhyBatchSortId);

    final acgnx = registry.byId('acgnx')! as AcgnxSource;
    final acgnxBatch = registry.byId('acgnx-batch')! as AcgnxSource;
    expect(acgnx.searchUri('蜡笔小新', 1).queryParameters['sort_id'], kAcgnxAnimeFeed);
    expect(acgnxBatch.searchUri('蜡笔小新', 1).queryParameters['sort_id'], kAcgnxBatchFeed);
    registry.dispose();
  });

  test('第 14 轮：分区声明（聚合搜索的 动漫 / 全集 两档读它）', () {
    final registry = build(textFactory(''));
    // 「合集」实例显式声明为 collection（第二十四轮删掉两个后只剩这两个）；动漫分区保持默认。
    for (final String id in <String>[
      'dmhy-batch',
      'acgnx-batch',
    ]) {
      expect(registry.partitionOf(id), SourcePartition.collection,
          reason: '$id 应当被声明为「全集」分区');
    }
    for (final String id in <String>[
      'nyaa',
      'mikan',
      'dmhy',
      'acgrip',
      'acgnx',
      'bangumimoe',
    ]) {
      expect(registry.partitionOf(id), SourcePartition.anime,
          reason: '$id 应当算「动漫」分区');
    }
    // 没注册/没声明的 id：默认动漫分区（不抛错）。
    expect(registry.partitionOf('没这个源'), SourcePartition.anime);

    // 注销要连分区一起清掉（否则重新注册一个同名 id 会继承旧分区）。
    expect(registry.unregister('dmhy-batch'), isTrue);
    expect(registry.partitionOf('dmhy-batch'), SourcePartition.anime);

    // 重新注册一个 id 时没带 partition：不该把已声明的分区降级成默认值。
    registry.register(_FakeClient(), partition: SourcePartition.other);
    expect(registry.partitionOf('mysite'), SourcePartition.other);
    registry.register(_FakeClient());
    expect(registry.partitionOf('mysite'), SourcePartition.other,
        reason: '第二次注册没带 partition（null = 不改），不能悄悄降回 anime');
    registry.dispose();
  });

  test('registerDefaults: false 时不注册内置源', () {
    final registry = SourceRegistry(
      http: textFactory(''),
      cache: cache,
      limiter: RateLimiter(minInterval: Duration.zero, clock: clock.call),
      proxy: const ProxyConfig.none(),
      clock: clock.call,
      registerDefaults: false,
    );
    expect(registry.clients, isEmpty);
    registry.dispose();
  });

  test('register 可接入自定义解析（「自行添加其他网站解析」入口）', () {
    final registry = build(textFactory(''));
    final custom = _FakeClient();
    registry.register(custom);
    expect(registry.byId('mysite'), same(custom));
    // 默认 8 个源（第二十四轮删掉 acgrip-batch / bangumimoe-collection 之后）+ 这个自定义的。
    expect(registry.clients, hasLength(9));

    // 同 id 再注册 → 替换
    final replacement = _FakeClient();
    registry.register(replacement);
    expect(registry.byId('mysite'), same(replacement));
    expect(registry.clients, hasLength(9));

    expect(registry.unregister('mysite'), isTrue);
    expect(registry.unregister('mysite'), isFalse);
    expect(registry.byId('mysite'), isNull);
    registry.dispose();
  });

  test('addRss 用显式 feedId；addRssUrl 用 URL 的 sha1 前 12 位（可重复）', () {
    final registry = build(textFactory(''));
    final explicit = registry.addRss(
      feedId: 'dmhy',
      feedUrl: Uri.parse('https://share.dmhy.org/topics/rss/rss.xml'),
      displayName: '动漫花园',
    );
    expect(explicit.id, 'rss:dmhy');
    expect(explicit.displayName, '动漫花园');
    expect(registry.byId('rss:dmhy'), same(explicit));

    final byUrl = registry.addRssUrl('https://acg.rip/.xml');
    expect(byUrl.id, startsWith('rss:'));
    expect(byUrl.feedId, shortHash('https://acg.rip/.xml'));
    expect(byUrl.feedId, hasLength(12));
    expect(byUrl.displayName, 'acg.rip');

    // 同一 URL 重复添加 → 同一 feedId（去重/幂等）
    final again = registry.addRssUrl('https://acg.rip/.xml');
    expect(again.feedId, byUrl.feedId);
    expect(registry.clients.where((SourceClient c) => c.id == byUrl.id),
        hasLength(1));
    registry.dispose();
  });

  test('addRssUrl 非法 URL → SourceException', () {
    final registry = build(textFactory(''));
    expect(() => registry.addRssUrl('不是 URL'),
        throwsA(isA<SourceException>()));
    registry.dispose();
  });

  test('入参 proxy 会体现在实际使用的 HttpClientFactory 上', () {
    const wanted = ProxyConfig(
      mode: ProxyMode.socks5,
      host: '127.0.0.1',
      port: 1080,
    );
    final registry = build(
      RecordingHttpFactory((http.Request request) async => http.Response('', 200)),
      proxy: wanted,
    );
    // 传入的是普通假工厂 → 直接使用，不会被替换（不影响单测）
    expect(registry.transport.factory.describe, 'RecordingHttpFactory');
    expect(registry.proxy, wanted);
    registry.dispose();

    final io = SourceRegistry(
      http: IoHttpClientFactory(),
      cache: cache,
      limiter: RateLimiter(minInterval: Duration.zero, clock: clock.call),
      proxy: wanted,
      clock: clock.call,
    );
    // 传入默认 IO 工厂但 proxy 不一致 → 以 registry 的 proxy 为准重建
    expect(io.transport.factory, isA<IoHttpClientFactory>());
    expect((io.transport.factory as IoHttpClientFactory).proxy, wanted);
    io.dispose();
  });

  test('端到端：自定义 RSS 走网络 → 缓存命中 → 网络失败回落 stale（fromCache）', () async {
    var mode = 'ok';
    final factory = RecordingHttpFactory((http.Request request) async {
      if (mode == 'fail') {
        return http.Response('boom', 500);
      }
      return http.Response.bytes(expectedBytes(),
          200, headers: <String, String>{'content-type': 'application/xml; charset=utf-8'});
    });
    final registry = build(factory);
    final source = registry.addRssUrl('https://acg.rip/.xml');

    final first = await source.latest();
    expect(first.items, hasLength(5));
    expect(first.hasNext, isFalse);
    expect(first.fromCache, isFalse);
    expect(first.staleFallback, isFalse, reason: '走的网络，谈不上回落');
    expect(factory.requestedUris.single.toString(), 'https://acg.rip/.xml');

    // 1) 未过期 → 直接命中缓存，不再发请求
    final second = await source.latest();
    expect(second.fromCache, isTrue);
    expect(second.items, hasLength(5));
    expect(factory.requestedUris, hasLength(1));
    // 第四十二轮 UX #10：新鲜命中**不是**"网络失败回落"。旧实现两种情形共用
    // `fromCache` 一个标志，界面于是把新鲜命中报成「网络抓取失败」——
    // 而重搜同一个词必然命中这一条，用户会以为网络一直在坏。
    expect(second.staleFallback, isFalse,
        reason: '新鲜命中根本没发网络请求，界面不许报「网络抓取失败」');
    // 同一处修的第二个毛病：缓存页的 `fetchedAt` 原来是 `clock()`（= 现在），
    // 于是"这份缓存是 5 分钟前写的"在界面上永远显示「刚刚」。
    expect(second.fetchedAt, first.fetchedAt,
        reason: '要报缓存的**写入时间**，不是读取时间');

    // 2) 让缓存过期 + 网络失败 → 回落 stale，并标记 fromCache
    clock.advance(const Duration(seconds: 301));
    mode = 'fail';
    final third = await source.latest();
    expect(third.fromCache, isTrue);
    expect(third.staleFallback, isTrue, reason: '这一条才是"网络抓取失败，显示的是缓存"');
    expect(third.items, hasLength(5));
    expect(third.items.first.id, '${source.id}:https://acg.rip/t/364729');
    expect(factory.requestedUris, hasLength(4)); // 3 次重试（1+2）
    registry.dispose();
  });

  test('端到端：无缓存 + 网络失败 → 抛 SourceException（不返回假空页）', () async {
    final factory = sequenceFactory(<http.Response Function()>[
      () => http.Response('boom', 500),
    ]);
    final registry = build(factory);
    final source = registry.addRssUrl('https://acg.rip/.xml');
    await expectLater(
      source.latest(),
      throwsA(isA<SourceException>()
          .having((SourceException e) => e.statusCode, 'statusCode', 500)),
    );
    registry.dispose();
  });

  test('dispose 关闭底层工厂', () {
    final factory = textFactory('');
    final registry = build(factory);
    registry.dispose();
    expect(factory.closed, isTrue);
  });
}

/// 真实 fixture 的字节（避免测试里出现手写 feed 冒充站点样本）。
List<int> expectedBytes() => loadFixtureBytes('generic_acgrip.xml');

class _FakeClient implements SourceClient {
  @override
  String get id => 'mysite';

  @override
  String get displayName => '自定义站点';

  @override
  bool get supportsSearch => false;

  @override
  Future<SourcePage> latest({int page = 1}) async =>
      SourcePage(items: const <SourceItem>[], fetchedAt: DateTime.utc(2026));

  @override
  Future<SourcePage> search(String keyword, {int page = 1}) async =>
      SourcePage(items: const <SourceItem>[], fetchedAt: DateTime.utc(2026));

  @override
  Future<SourceItem?> detail(SourceItem item) async => null;
}
