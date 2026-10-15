/// 缓存清扫/用量统计测试（用户 2026-10-11「不要没用的缓存」）。
library;

import 'package:dsanima/state/cache_sweep.dart';
import 'package:dsanima_core/sources/kv.dart' show InMemoryKeyValueStore;
import 'package:flutter_test/flutter_test.dart';

final DateTime _now = DateTime.utc(2026, 10, 11, 12);

InMemoryKeyValueStore _store(Map<String, Object?> data) =>
    InMemoryKeyValueStore(data);

Map<String, Object?> _source(DateTime at, {int payload = 10}) => <String, Object?>{
  'v': 1,
  'sourceId': 'mikan',
  'request': 'latest:p1',
  'storedAt': at,
  'payload': 'x' * payload,
};

void main() {
  test('源缓存：过期的被清掉，新的保留', () async {
    final store = _store(<String, Object?>{
      'src_old': _source(_now.subtract(const Duration(days: 8))),
      'src_fresh': _source(_now.subtract(const Duration(minutes: 5))),
      'queue.jobs': <Object?>[],
    });

    final HostCacheSweep sweep = await sweepHostCache(store, now: _now);

    expect(sweep.removed, 1);
    expect(store.get('src_old'), isNull);
    expect(store.get('src_fresh'), isNotNull);
    // 队列/设置这些**不是缓存**的键绝不能碰。
    expect(store.get('queue.jobs'), isNotNull);
  });

  test('源缓存：超过条数上限时留最新的（少的被丢）', () async {
    final Map<String, Object?> data = <String, Object?>{};
    for (int i = 0; i < 100; i++) {
      data['src_$i'] = _source(_now.subtract(Duration(minutes: i)));
    }
    final store = _store(data);

    final HostCacheSweep sweep = await sweepHostCache(store, now: _now);

    expect(sweep.removed, 20); // 100 → 80
    expect(store.get('src_0'), isNotNull); // 最新
    expect(store.get('src_99'), isNull); // 最旧
    expect(hostCacheUsage(store).sourceEntries, 80);
  });

  test('推荐缓存：只留 cachedAt 最新的 2 个（种子不是单调日期，按值里的时间排）', () async {
    final store = _store(<String, Object?>{
      'dsanima.bangumi.recommend.20261010': <String, Object?>{
        'cachedAt': _now.subtract(const Duration(days: 1)),
      },
      'dsanima.bangumi.recommend.20268928': <String, Object?>{
        'cachedAt': _now.subtract(const Duration(days: 3)),
      },
      'dsanima.bangumi.recommend.20261011': <String, Object?>{'cachedAt': _now},
    });

    final HostCacheSweep sweep = await sweepHostCache(store, now: _now);

    expect(sweep.removed, 1);
    expect(store.get('dsanima.bangumi.recommend.20261011'), isNotNull);
    expect(store.get('dsanima.bangumi.recommend.20261010'), isNotNull);
    expect(store.get('dsanima.bangumi.recommend.20268928'), isNull); // 最旧
  });

  test('番剧信息：按龄清；时间戳坏掉的条目当过期处理', () async {
    final store = _store(<String, Object?>{
      'dsanima.bangumi.meta.a': <String, Object?>{'cachedAt': _now},
      'dsanima.bangumi.meta.b': <String, Object?>{
        'cachedAt': _now.subtract(const Duration(days: 30)),
      },
      'dsanima.bangumi.meta.broken': <String, Object?>{'cachedAt': 'not-a-date'},
    });

    await sweepHostCache(store, now: _now);

    expect(store.get('dsanima.bangumi.meta.a'), isNotNull);
    expect(store.get('dsanima.bangumi.meta.b'), isNull);
    expect(store.get('dsanima.bangumi.meta.broken'), isNull);
  });

  test('ISO 字符串时间戳（旧格式）也能算龄', () async {
    final store = _store(<String, Object?>{
      'src_iso': _source(_now.subtract(const Duration(days: 9))).map(
        (String k, Object? v) => MapEntry<String, Object?>(
          k,
          k == 'storedAt' ? '2026-10-02T12:00:00.000Z' : v,
        ),
      ),
    });
    final HostCacheSweep sweep = await sweepHostCache(store, now: _now);
    expect(sweep.removed, 1);
  });

  test('用量统计：条数与字节分开算，且只算缓存键', () async {
    final store = _store(<String, Object?>{
      'src_a': _source(_now, payload: 100),
      'src_b': _source(_now, payload: 100),
      'dsanima.bangumi.meta.a': <String, Object?>{'cachedAt': _now},
      'dsanima.bangumi.recommend.1': <String, Object?>{'cachedAt': _now},
      'dsanima.app_settings': <String, Object?>{'x': 1},
    });

    final HostCacheUsage usage = hostCacheUsage(store);

    expect(usage.sourceEntries, 2);
    expect(usage.metaEntries, 1);
    expect(usage.recommendEntries, 1);
    expect(usage.entries, 4);
    expect(usage.sourceBytes, greaterThan(200));
  });

  test('一键清空：三类缓存全清，设置/队列不受影响', () async {
    final store = _store(<String, Object?>{
      'src_a': _source(_now),
      'dsanima.bangumi.meta.a': <String, Object?>{'cachedAt': _now},
      'dsanima.bangumi.recommend.1': <String, Object?>{'cachedAt': _now},
      'dsanima.app_settings': <String, Object?>{'themeId': 'light'},
      'queue.jobs': <Object?>[],
      'queue.removed': <String>['x'],
    });

    final int removed = await clearHostCache(store);

    expect(removed, 3);
    expect(hostCacheUsage(store).entries, 0);
    expect(store.get('dsanima.app_settings'), isNotNull);
    expect(store.get('queue.jobs'), isNotNull);
    expect(store.get('queue.removed'), isNotNull);
  });
}
