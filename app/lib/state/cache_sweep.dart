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

/// Bangumi 条目详情缓存键前缀（1.1.0 M1/T7 纳入清扫）：
/// 主键 `dsanima.bangumi.subject.<id>`，旁边还有兄弟键 `.fresh`（存回时间）与
/// `.extra`（角色/关联条目）。以前这三样**一个都不在**用量统计与清扫范围里 ——
/// 详情缓存只会在设置页「清空缓存」时被删掉，平时永远只涨不减。
const String kBangumiSubjectPrefix = 'dsanima.bangumi.subject.';

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
    this.detailEntries = 0,
  });

  final int sourceEntries;
  final int sourceBytes;
  final int recommendEntries;
  final int metaEntries;

  /// Bangumi 条目详情（主键 `.subject.<id>` 的条数，1.1.0 M1/T7 起计入）。
  final int detailEntries;

  int get entries => sourceEntries + recommendEntries + metaEntries + detailEntries;
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
  int details = 0;
  for (final String key in store.keys) {
    if (key.startsWith(kSourceCachePrefix)) {
      sources++;
      bytes += _bytesOf(store.get(key));
    } else if (key.startsWith(kBangumiRecommendPrefix)) {
      recommends++;
    } else if (key.startsWith(kBangumiMetaPrefix)) {
      metas++;
    } else if (_isSubjectMainKey(key)) {
      // 兄弟键（`.fresh` / `.extra`）不算"一条详情"，跟着主键走。
      details++;
    }
  }
  return HostCacheUsage(
    sourceEntries: sources,
    sourceBytes: bytes,
    recommendEntries: recommends,
    metaEntries: metas,
    detailEntries: details,
  );
}

/// `dsanima.bangumi.subject.<id>`（主键）——后面**不能再有** `.fresh`/`.extra`。
bool _isSubjectMainKey(String key) {
  if (!key.startsWith(kBangumiSubjectPrefix)) return false;
  return int.tryParse(key.substring(kBangumiSubjectPrefix.length)) != null;
}

/// 一条详情所有的键：主键 + 两个兄弟键（`.` 后缀）。
List<String> _subjectKeysOf(String id) => <String>[
  '$kBangumiSubjectPrefix$id',
  '$kBangumiSubjectPrefix$id.fresh',
  '$kBangumiSubjectPrefix$id.extra',
];

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

  // ④ Bangumi 条目详情：主键 + 兄弟键（`.fresh` / `.extra`）**整组**一起走。
  //
  //    年龄优先看 `.fresh`（1.1.0 M1/T7 的存回时间）；没有它就看主键值里的 `cachedAt`
  //    （旧版本写的数据）；都读不出来就按"很久以前"清掉（与 [_stampOf] 的口径一致）。
  final Set<String> keysNow = store.keys.toSet();
  for (final String key in keysNow) {
    if (!_isSubjectMainKey(key)) continue;
    final String id = key.substring(kBangumiSubjectPrefix.length);
    // 读不出时间戳 → [_stampOf] 给的是 epoch（很久以前），会被当成过期清掉，
    // 与其它三处缓存的既定口径一致（见 [_stampOf] 的注释）。
    final DateTime freshAt =
        _parseStamp(store.get('$key.fresh')) ?? _stampOf(store.get(key), 'cachedAt');
    if (at.difference(freshAt) > maxAge) {
      for (final String sibling in _subjectKeysOf(id)) {
        if (!keysNow.contains(sibling)) continue;
        freed += _bytesOf(store.get(sibling));
        await store.delete(sibling);
        removed++;
      }
    } else {
      kept++;
    }
  }
  // ④b 孤儿兄弟键（主键已经不在了，比如旧版本只写过 `.extra`）：留着永远是垃圾。
  for (final String key in keysNow) {
    if (!key.startsWith(kBangumiSubjectPrefix) || _isSubjectMainKey(key)) continue;
    final String id = key.substring(kBangumiSubjectPrefix.length).split('.').first;
    if (int.tryParse(id) == null) continue; // 不是我们的键，别碰
    if (keysNow.contains('$kBangumiSubjectPrefix$id')) continue; // 主键还在 → 上面处理过
    freed += _bytesOf(store.get(key));
    await store.delete(key);
    removed++;
  }

  return HostCacheSweep(removed: removed, kept: kept, freedBytes: freed);
}

/// 一键清空（设置页按钮）：源缓存 + 推荐 + 番剧信息 + **条目详情（含兄弟键）**全删。
/// 返回删掉的条数。
Future<int> clearHostCache(KeyValueStore store) async {
  int removed = 0;
  for (final String key in store.keys.toList(growable: false)) {
    if (key.startsWith(kSourceCachePrefix) ||
        key.startsWith(kBangumiRecommendPrefix) ||
        key.startsWith(kBangumiMetaPrefix) ||
        key.startsWith(kBangumiSubjectPrefix)) {
      await store.delete(key);
      removed++;
    }
  }
  return removed;
}

/// 时间戳解析（空 / 损坏 → null，交给调用方按"读不出来"处理）。
DateTime? _parseStamp(Object? raw) {
  if (raw is DateTime) return raw;
  if (raw is String) return DateTime.tryParse(raw);
  if (raw is int) return DateTime.fromMillisecondsSinceEpoch(raw);
  return null;
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
