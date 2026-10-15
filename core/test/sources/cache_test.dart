/// 源缓存单测：sha1 键、TTL、stale 回落、序列化往返、清理。
library;

import 'package:dsanima_core/sources/sources.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

SourceItem _fullItem() => SourceItem(
      id: 'nyaa:2171210',
      sourceId: 'nyaa',
      title: '[DRiFTKiNG] Test - S02E08 [1080p]',
      detailUrl: Uri.parse('https://nyaa.si/view/2171210'),
      torrentUrl: 'https://nyaa.si/download/2171210.torrent',
      magnet: 'magnet:?xt=urn:btih:3a1cbcfc711bb7a21f2741433119773c23ac081d',
      infoHash: '3a1cbcfc711bb7a21f2741433119773c23ac081d',
      sizeBytes: 6012954214,
      seeders: 3,
      leechers: 13,
      downloads: 0,
      publishedAt: DateTime.utc(2026, 10, 8, 13, 18, 50),
      category: 'Anime - English-translated',
      group: 'DRiFTKiNG',
      episodeHints: const <String>['S02E08'],
      extra: const <String, dynamic>{
        'resolution': 1080,
        'isBatch': false,
        'trusted': false,
      },
    );

void main() {
  group('缓存键（spec §4.2：sha1(sourceId + 归一化请求)）', () {
    test('归一化形式', () {
      expect(const CacheRequest.latest().normalized, 'latest:p1');
      expect(const CacheRequest.latest(page: 3).normalized, 'latest:p3');
      expect(const CacheRequest.search('  Frieren   Test ').normalized,
          'search:p1:frieren test');
      expect(const CacheRequest.search('Frieren', page: 2).normalized,
          'search:p2:frieren');
      expect(const CacheRequest.detail('nyaa:1').normalized, 'detail:nyaa:1');
    });

    test('sha1 键与外部计算一致', () {
      expect(SourceCache.cacheKey('nyaa', 'latest:p1'),
          'b58928d26d6c9d4cd15dd58960438575a832a3ec');
      expect(SourceCache.cacheKey('nyaa', 'search:p1:frieren'),
          'b7e5241a65b1241d8d8c88bd3aa7de586fd1d7db');
      expect(SourceCache.cacheKey('mikan', 'latest:p1'),
          '3cb65d1f9c49b7790caa1204946dfc1bfdb61a6f');
      // 不同 sourceId / 不同请求 → 不同键
      expect(SourceCache.cacheKey('nyaa', 'latest:p1'),
          isNot(SourceCache.cacheKey('mikan', 'latest:p1')));
      expect(SourceCache.cacheKey('nyaa', 'latest:p1'),
          isNot(SourceCache.cacheKey('nyaa', 'latest:p2')));
    });

    test('storageKey 带前缀', () {
      final cache = SourceCache(store: InMemoryKeyValueStore());
      expect(cache.storageKey('nyaa', const CacheRequest.latest()),
          'src_b58928d26d6c9d4cd15dd58960438575a832a3ec');
    });
  });

  group('TTL 与命中', () {
    late FakeClock clock;
    late InMemoryKeyValueStore store;
    late SourceCache cache;

    setUp(() {
      clock = FakeClock(DateTime.utc(2026, 10, 8, 12));
      store = InMemoryKeyValueStore();
      cache = SourceCache(store: store, clock: clock.call);
    });

    test('search/latest TTL 300s：未过期命中，过期 miss，allowStale 可回落', () async {
      await cache.put('nyaa', const CacheRequest.latest(),
          <String, dynamic>{'items': <dynamic>[], 'hasNext': false, 'page': 1});

      expect(await cache.get('nyaa', const CacheRequest.latest()), isNotNull);

      clock.advance(const Duration(seconds: 299));
      expect(await cache.get('nyaa', const CacheRequest.latest()), isNotNull);

      clock.advance(const Duration(seconds: 2)); // 301s
      expect(await cache.get('nyaa', const CacheRequest.latest()), isNull);

      final stale = await cache.get('nyaa', const CacheRequest.latest(),
          allowStale: true);
      expect(stale, isNotNull);
      expect(stale!.age, const Duration(seconds: 301));
      expect(cache.hitCount, 3);
      expect(cache.missCount, 1);
    });

    test('detail TTL 24h', () async {
      await cache.put('nyaa', const CacheRequest.detail('nyaa:1'),
          <String, dynamic>{'item': <String, dynamic>{}});
      clock.advance(const Duration(hours: 23));
      expect(await cache.get('nyaa', const CacheRequest.detail('nyaa:1')),
          isNotNull);
      clock.advance(const Duration(hours: 2));
      expect(await cache.get('nyaa', const CacheRequest.detail('nyaa:1')),
          isNull);
      expect(
        await cache.get('nyaa', const CacheRequest.detail('nyaa:1'),
            allowStale: true),
        isNotNull,
      );
    });

    test('TTL 可通过构造参数调整（设置页）', () async {
      final custom = SourceCache(
        store: store,
        clock: clock.call,
        searchTtl: const Duration(seconds: 10),
      );
      await custom.put('nyaa', const CacheRequest.search('a'),
          <String, dynamic>{'items': <dynamic>[]});
      clock.advance(const Duration(seconds: 11));
      expect(await custom.get('nyaa', const CacheRequest.search('a')), isNull);
    });

    test('记录损坏（存了字符串/缺 storedAt）→ miss，不抛错', () async {
      await store.put('src_deadbeef', '这不是 JSON 结构');
      final broken = SourceCache(store: store, clock: clock.call);
      expect(
        await broken.get('nyaa', const CacheRequest.latest()),
        isNull,
      );
      expect(broken.lastError, isNull); // 结构不符不是异常，只是 miss
    });
  });

  group('页面序列化往返', () {
    test('SourceItem 全字段往返一致', () {
      final item = _fullItem();
      final restored = SourceItem.fromJson(item.toJson());
      expect(restored.id, item.id);
      expect(restored.sourceId, item.sourceId);
      expect(restored.title, item.title);
      expect(restored.detailUrl, item.detailUrl);
      expect(restored.torrentUrl, item.torrentUrl);
      expect(restored.magnet, item.magnet);
      expect(restored.infoHash, item.infoHash);
      expect(restored.sizeBytes, item.sizeBytes);
      expect(restored.seeders, item.seeders);
      expect(restored.leechers, item.leechers);
      expect(restored.downloads, item.downloads);
      expect(restored.publishedAt, item.publishedAt);
      expect(restored.category, item.category);
      expect(restored.group, item.group);
      expect(restored.episodeHints, item.episodeHints);
      expect(restored.extra, item.extra);
      expect(restored.isDownloadable, isTrue);
    });

    test('null 字段不会变成伪造默认值', () {
      const item = SourceItem(id: 'mikan:x', sourceId: 'mikan');
      final restored = SourceItem.fromJson(item.toJson());
      expect(restored.title, isNull);
      expect(restored.detailUrl, isNull);
      expect(restored.torrentUrl, isNull);
      expect(restored.magnet, isNull);
      expect(restored.infoHash, isNull);
      expect(restored.sizeBytes, isNull);
      expect(restored.seeders, isNull);
      expect(restored.publishedAt, isNull);
      expect(restored.episodeHints, isEmpty);
      expect(restored.isDownloadable, isFalse);
    });

    test('putPage/getPage 往返（fromCache 恒为 true）', () async {
      final clock = FakeClock(DateTime.utc(2026, 10, 8, 12));
      final cache = SourceCache(
        store: InMemoryKeyValueStore(),
        clock: clock.call,
      );
      final page = SourcePage(
        items: <SourceItem>[_fullItem()],
        hasNext: true,
        page: 2,
        fetchedAt: clock.now,
      );
      await cache.putPage('nyaa', const CacheRequest.search('test', page: 2), page);

      final restored = await cache.getPage(
        'nyaa',
        const CacheRequest.search('test', page: 2),
        clock: clock.call,
      );
      expect(restored, isNotNull);
      expect(restored!.fromCache, isTrue);
      expect(restored.hasNext, isTrue);
      expect(restored.page, 2);
      expect(restored.items, hasLength(1));
      expect(restored.items.single.id, 'nyaa:2171210');
      expect(restored.items.single.infoHash, _fullItem().infoHash);
      expect(restored.items.single.extra['resolution'], 1080);
    });

    test('items 里单条损坏 → 丢弃该条、其余保留', () async {
      final clock = FakeClock(DateTime.utc(2026, 10, 8, 12));
      final store = InMemoryKeyValueStore();
      final cache = SourceCache(store: store, clock: clock.call);
      await cache.put('nyaa', const CacheRequest.latest(), <String, dynamic>{
        'items': <dynamic>[
          'garbage',
          _fullItem().toJson(),
        ],
        'hasNext': false,
        'page': 1,
      });
      final page = await cache.getPage('nyaa', const CacheRequest.latest(),
          clock: clock.call);
      expect(page!.items, hasLength(1));
    });
  });

  group('清理', () {
    test('invalidateSource 只清指定源', () async {
      final clock = FakeClock(DateTime.utc(2026, 10, 8, 12));
      final cache = SourceCache(
        store: InMemoryKeyValueStore(),
        clock: clock.call,
      );
      await cache.put('nyaa', const CacheRequest.latest(),
          <String, dynamic>{'items': <dynamic>[]});
      await cache.put('mikan', const CacheRequest.latest(),
          <String, dynamic>{'items': <dynamic>[]});

      expect(await cache.invalidateSource('nyaa'), 1);
      expect(await cache.get('nyaa', const CacheRequest.latest()), isNull);
      expect(await cache.get('mikan', const CacheRequest.latest()), isNotNull);
    });

    test('clear 只删带前缀的键，不动同一 store 里的其他数据', () async {
      final clock = FakeClock(DateTime.utc(2026, 10, 8, 12));
      final store = InMemoryKeyValueStore(<String, Object?>{
        'subscriptions': <String>['keep-me'],
      });
      final cache = SourceCache(store: store, clock: clock.call);
      await cache.put('nyaa', const CacheRequest.latest(),
          <String, dynamic>{'items': <dynamic>[]});
      expect(await cache.clear(), 1);
      expect(store.get('subscriptions'), <String>['keep-me']);
      expect(await cache.get('nyaa', const CacheRequest.latest()), isNull);
    });
  });
}
