/// 宿主 KV 里那些「只涨不减」的缓存：用量统计 + 边界清扫 + 一键清空。
///
/// 为什么需要它（审计结论，用户 2026-10-11「不要没用的库依赖和缓存」）：
/// * `src_<sha1>`（core `SourceCache`）：**只按 TTL 判读时过期，条目永不删除**；
///   生产里 `SourceCache.clear()` / `invalidateSource()` 一个调用者都没有 ——
///   实测 595 KB 的 box 里大半是 mikan/nyaa 的 HTML payload。
/// * `dsanima.bangumi.recommend.<seed>`：每天一个新键（种子不是单调的日期，所以按
///   **值里的 `cachedAt`** 排序），7 天只影响"读时算不算过期"，键从不删。
/// * `dsanima.bangumi.meta.<标题>`：每看一部番一个新键，同样从不删。
///
/// 这里给它们补上和封面缓存同款的待遇：**启动扫一次 + 设置页能一键清空 + 显示占用**。
library;

import 'dart:convert';

import 'package:dsanima_core/sources/kv.dart' show KeyValueStore;

/// 源缓存键前缀（core `SourceCache`，值是 `{v, sourceId, request, storedAt, payload}`）。
const String kSourceCachePrefix = 'src_';

/// Bangumi 推荐缓存键前缀（`dsanima.bangumi.recommend.<seed>`）。
const String kBangumiRecommendPrefix = 'dsanima.bangumi.recommend.';

/// Bangumi 番剧信息缓存键前缀（`dsanima.bangumi.meta.<归一化标题>`）。
const String kBangumiMetaPrefix = 'dsanima.bangumi.meta.';

/// 这些缓存最多留多久（比读端 TTL 更长：读端只管"新不新"，这里管"还占不占地方"）。
const Duration kHostCacheMaxAge = Duration(days: 7);

/// 源缓存最多留多少条（按 `storedAt` 新的优先）。
const int kMaxSourceCacheEntries = 80;

/// 推荐缓存最多留几个种子（按 `cachedAt` 新的优先；主页只需要当天那一个）。
const int kMaxRecommendCacheEntries = 2;

/// 缓存用量（设置页显示用）。
class HostCacheUsage {
  const HostCacheUsage({
    required this.sourceEntries,
    required this.sourceBytes,
    required this.recommendEntries,
    required this.metaEntries,
  });

  final int sourceEntries;
  final int sourceBytes;
  final int recommendEntries;
  final int metaEntries;

  int get entries => sourceEntries + recommendEntries + metaEntries;
}

/// 一次清扫的结果。
class HostCacheSweep {
  const HostCacheSweep({
    required this.removed,
    required this.kept,
    required this.freedBytes,
  });

  static const HostCacheSweep none = HostCacheSweep(removed: 0, kept: 0, freedBytes: 0);

  final int removed;
  final int kept;
  final int freedBytes;

  bool get changed => removed > 0;

  @override
  String toString() => 'HostCacheSweep(removed=$removed, kept=$kept, freed=$freedBytes)';
}

HostCacheUsage hostCacheUsage(KeyValueStore store) {
  int sources = 0;
  int bytes = 0;
  int recommends = 0;
  int metas = 0;
  for (final String key in store.keys) {
    if (key.startsWith(kSourceCachePrefix)) {
      sources++;
      bytes += _bytesOf(store.get(key));
    } else if (key.startsWith(kBangumiRecommendPrefix)) {
      recommends++;
    } else if (key.startsWith(kBangumiMetaPrefix)) {
      metas++;
    }
  }
  return HostCacheUsage(
    sourceEntries: sources,
    sourceBytes: bytes,
    recommendEntries: recommends,
    metaEntries: metas,
  );
}

/// 按「过期 + 条数上限」清扫三处缓存。启动时跑一次；返回删了多少。
Future<HostCacheSweep> sweepHostCache(
  KeyValueStore store, {
  DateTime? now,
  Duration maxAge = kHostCacheMaxAge,
  int maxSourceEntries = kMaxSourceCacheEntries,
  int maxRecommendEntries = kMaxRecommendCacheEntries,
}) async {
  final DateTime at = now ?? DateTime.now();
  int removed = 0;
  int kept = 0;
  int freed = 0;

  // ① 源缓存：先过期，再按条数留新的。
  final List<({String key, DateTime at, int bytes})> sources =
      <({String key, DateTime at, int bytes})>[];
  for (final String key in store.keys) {
    if (!key.startsWith(kSourceCachePrefix)) continue;
    final Object? value = store.get(key);
    sources.add((key: key, at: _stampOf(value, 'storedAt'), bytes: _bytesOf(value)));
  }
  sources.sort((a, b) => b.at.compareTo(a.at)); // 新的在前
  for (int i = 0; i < sources.length; i++) {
    final bool tooOld = at.difference(sources[i].at) > maxAge;
    final bool tooMany = i >= maxSourceEntries;
    if (tooOld || tooMany) {
      await store.delete(sources[i].key);
      removed++;
      freed += sources[i].bytes;
    } else {
      kept++;
    }
  }

  // ② 推荐缓存：只留最新几个种子。
  final List<({String key, DateTime at, int bytes})> recommends =
      <({String key, DateTime at, int bytes})>[];
  for (final String key in store.keys) {
    if (!key.startsWith(kBangumiRecommendPrefix)) continue;
    final Object? value = store.get(key);
    recommends.add((key: key, at: _stampOf(value, 'cachedAt'), bytes: _bytesOf(value)));
  }
  recommends.sort((a, b) => b.at.compareTo(a.at));
  for (int i = 0; i < recommends.length; i++) {
    if (i >= maxRecommendEntries) {
      await store.delete(recommends[i].key);
      removed++;
      freed += recommends[i].bytes;
    } else {
      kept++;
    }
  }

  // ③ 番剧信息：只按龄清（同一部番再看一次就会重建，代价很小）。
  for (final String key in store.keys) {
    if (!key.startsWith(kBangumiMetaPrefix)) continue;
    final Object? value = store.get(key);
    if (at.difference(_stampOf(value, 'cachedAt')) > maxAge) {
      freed += _bytesOf(value);
      await store.delete(key);
      removed++;
    } else {
      kept++;
    }
  }

  return HostCacheSweep(removed: removed, kept: kept, freedBytes: freed);
}

/// 一键清空（设置页按钮）：源缓存 + 推荐 + 番剧信息全删。返回删掉的条数。
Future<int> clearHostCache(KeyValueStore store) async {
  int removed = 0;
  for (final String key in store.keys.toList(growable: false)) {
    if (key.startsWith(kSourceCachePrefix) ||
        key.startsWith(kBangumiRecommendPrefix) ||
        key.startsWith(kBangumiMetaPrefix)) {
      await store.delete(key);
      removed++;
    }
  }
  return removed;
}

/// 取缓存条目里的时间戳：Hive 可能把它存成真 `DateTime`（也可能是 ISO 字符串）。
DateTime _stampOf(Object? value, String field) {
  if (value is Map) {
    final Object? raw = value[field];
    if (raw is DateTime) return raw;
    if (raw is String) {
      final DateTime? parsed = DateTime.tryParse(raw);
      if (parsed != null) return parsed;
    }
    if (raw is int) return DateTime.fromMillisecondsSinceEpoch(raw);
  }
  // 时间戳都读不出来（旧格式/损坏）：当成很久以前，交给上面按龄清掉。
  return DateTime.fromMillisecondsSinceEpoch(0);
}

int _bytesOf(Object? value) {
  try {
    return jsonEncode(value).length;
  } catch (_) {
    return '$value'.length;
  }
}
