/// 源抓取持久化缓存（spec §4.2）。
///
/// * 键 = `sha1(sourceId + 归一化请求)`；
/// * TTL：`latest`/`search` 300s，`detail` 24h；
/// * 未过期即命中（不再发网络请求）；
/// * 过期视为 miss，但网络失败时可回落 stale 缓存，并把 `SourcePage.fromCache` 置 true；
/// * 存储走可注入的 [KeyValueStore]（宿主注入 Hive，或 [FileKeyValueStore] 落
///   `<appSupport>/dsanima/cache/sources`），单测用 [InMemoryKeyValueStore] ——
///   **不落盘、不联网**。
library;

import 'package:crypto/crypto.dart';
import 'dart:convert';

import 'http.dart' show ClockFn;
import 'kv.dart';
import 'models.dart';

/// 缓存类别，决定 TTL。
///
/// ⚠️ [schedule] 必须与 [latest] 分开：mikan 首页（追番表）与 RSS「最新」取的
/// 是**两个不同接口**，载荷形状也不一样（`{schedule,skipped}` vs
/// `{items,hasNext,page}`）。共用一个键时各自把对方的载荷判成 miss ⇒ 交替调用
/// 永远打网络，而且互相覆盖。
enum CacheKind { latest, search, detail, schedule }

/// 归一化后的请求标识（同一 `sourceId` 下唯一）。
class CacheRequest {
  const CacheRequest.latest({this.page = 1})
      : kind = CacheKind.latest,
        query = null;

  const CacheRequest.search(String keyword, {this.page = 1})
      : kind = CacheKind.search,
        query = keyword;

  const CacheRequest.detail(String itemId)
      : kind = CacheKind.detail,
        query = itemId,
        page = 1;

  /// 首页「本周追番更新表」（mikan 的 `/`）—— 与 [CacheRequest.latest]（RSS）**不同键**。
  const CacheRequest.schedule()
      : kind = CacheKind.schedule,
        query = null,
        page = 1;

  final CacheKind kind;

  /// search = 关键字；detail = item id；latest = null。
  final String? query;
  final int page;

  /// 归一化：去首尾空白、折叠内部空白、search 关键字转小写。
  String get normalized {
    switch (kind) {
      case CacheKind.latest:
        return 'latest:p$page';
      case CacheKind.search:
        final q = (query ?? '')
            .trim()
            .replaceAll(RegExp(r'\s+'), ' ')
            .toLowerCase();
        return 'search:p$page:$q';
      case CacheKind.detail:
        return 'detail:${(query ?? '').trim()}';
      case CacheKind.schedule:
        return 'schedule:home';
    }
  }

  @override
  String toString() => 'CacheRequest(${kind.name}, $normalized)';
}

/// 一条缓存记录。
class CachedPayload {
  const CachedPayload({
    required this.payload,
    required this.storedAt,
    required this.age,
  });

  final Map<String, dynamic> payload;
  final DateTime storedAt;

  /// 距写入已过去的时间。
  final Duration age;

  @override
  String toString() => 'CachedPayload(storedAt=$storedAt, age=$age)';
}

/// JSON 缓存。
class SourceCache {
  SourceCache({
    required this.store,
    ClockFn? clock,
    this.latestTtl = const Duration(seconds: 300),
    this.searchTtl = const Duration(seconds: 300),
    this.detailTtl = const Duration(hours: 24),
    this.keyPrefix = 'src_',
  })  : _clock = clock ?? DateTime.now;

  /// 持久化后端（宿主注入 Hive，或 [FileKeyValueStore]）。
  final KeyValueStore store;
  final ClockFn _clock;
  final Duration latestTtl;
  final Duration searchTtl;
  final Duration detailTtl;
  final String keyPrefix;

  /// 最近一次缓存读写错误（写入失败不影响抓取结果，只记录）。
  Object? lastError;

  /// 命中/未命中计数（诊断与测试用）。
  int hitCount = 0;
  int missCount = 0;

  Duration ttlFor(CacheKind kind) {
    switch (kind) {
      case CacheKind.latest:
        return latestTtl;
      case CacheKind.search:
        return searchTtl;
      case CacheKind.detail:
        return detailTtl;
      case CacheKind.schedule:
        // 首页追番表与 RSS「最新」同一档新鲜度（都是"今天有什么"）。
        return latestTtl;
    }
  }

  /// `sha1(sourceId + 归一化请求)`（spec §4.2 冻结的键规则）。
  String storageKey(String sourceId, CacheRequest request) =>
      keyPrefix + cacheKey(sourceId, request.normalized);

  /// 纯函数版本的键计算（便于单测直接断言）。
  static String cacheKey(String sourceId, String normalizedRequest) =>
      sha1.convert(utf8.encode('$sourceId$normalizedRequest')).toString();

  /// 写入一条记录。**永不抛异常**（缓存是加速手段，不该让抓取失败）。
  Future<void> put(
    String sourceId,
    CacheRequest request,
    Map<String, dynamic> payload,
  ) async {
    try {
      await store.put(storageKey(sourceId, request), <String, dynamic>{
        'v': 1,
        'sourceId': sourceId,
        'request': request.normalized,
        'storedAt': _clock().toUtc().toIso8601String(),
        'payload': payload,
      });
      lastError = null;
    } catch (e) {
      lastError = e;
    }
  }

  /// 读取一条记录。
  ///
  /// [allowStale] = true 时忽略 TTL（供网络失败回落用）；
  /// 返回 null 表示 cache miss 或记录损坏。
  Future<CachedPayload?> get(
    String sourceId,
    CacheRequest request, {
    bool allowStale = false,
  }) async {
    Object? raw;
    try {
      raw = store.get(storageKey(sourceId, request));
    } catch (e) {
      lastError = e;
      missCount++;
      return null;
    }
    final record = _asStringMap(raw);
    if (record == null) {
      missCount++;
      return null;
    }

    final storedAtRaw = record['storedAt'];
    final storedAt =
        storedAtRaw is String ? DateTime.tryParse(storedAtRaw) : null;
    final payload = _asStringMap(record['payload']);
    if (storedAt == null || payload == null) {
      missCount++;
      return null;
    }

    final age = _clock().toUtc().difference(storedAt.toUtc());
    if (!allowStale && age > ttlFor(request.kind)) {
      missCount++;
      return null;
    }
    hitCount++;
    return CachedPayload(payload: payload, storedAt: storedAt, age: age);
  }

  /// 写一整页。
  Future<void> putPage(
    String sourceId,
    CacheRequest request,
    SourcePage page,
  ) =>
      put(sourceId, request, <String, dynamic>{
        'items': page.items.map((SourceItem i) => i.toJson()).toList(),
        'hasNext': page.hasNext,
        'page': page.page,
      });

  /// 读一整页；`fromCache` 固定为 true（数据确实来自缓存）。
  Future<SourcePage?> getPage(
    String sourceId,
    CacheRequest request, {
    bool allowStale = false,
    required ClockFn clock,
  }) async {
    final entry = await get(sourceId, request, allowStale: allowStale);
    if (entry == null) return null;
    final rawItems = entry.payload['items'];
    if (rawItems is! List) return null;
    final items = <SourceItem>[];
    for (final raw in rawItems) {
      final map = _asStringMap(raw);
      if (map == null) continue;
      try {
        items.add(SourceItem.fromJson(map));
      } catch (_) {
        // 单条损坏 → 丢弃该条，其余照常返回。
      }
    }
    return SourcePage(
      items: items,
      hasNext: entry.payload['hasNext'] == true,
      page: (entry.payload['page'] as num?)?.toInt() ?? request.page,
      fetchedAt: clock(),
      fromCache: true,
    );
  }

  /// 失效某个源的缓存（设置页「清缓存」/订阅手动刷新用）。
  Future<int> invalidateSource(String sourceId) async {
    var removed = 0;
    try {
      for (final key in store.keys.toList(growable: false)) {
        if (!key.startsWith(keyPrefix)) continue;
        final record = _asStringMap(store.get(key));
        if (record == null) continue;
        if (record['sourceId'] == sourceId) {
          await store.delete(key);
          removed++;
        }
      }
    } catch (e) {
      lastError = e;
    }
    return removed;
  }

  /// 清空全部源缓存条目（不动同一个 store 里的其他键）。
  Future<int> clear() async {
    var removed = 0;
    try {
      for (final key in store.keys.toList(growable: false)) {
        if (key.startsWith(keyPrefix)) {
          await store.delete(key);
          removed++;
        }
      }
    } catch (e) {
      lastError = e;
    }
    return removed;
  }
}

Map<String, dynamic>? _asStringMap(Object? value) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) {
    return value.map(
      (dynamic k, dynamic v) => MapEntry<String, dynamic>(k.toString(), v),
    );
  }
  return null;
}
