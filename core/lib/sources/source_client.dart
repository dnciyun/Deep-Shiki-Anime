/// 源客户端契约（spec §4.2 冻结签名）。
library;

import 'cache.dart';
import 'http.dart';
import 'models.dart';

/// 一个内容源。
///
/// 字段/方法名与 spec §4.2 完全一致；自定义站点解析通过实现本接口 +
/// `SourceRegistry.register` 接入（「可自行添加其他网站解析」的入口）。
abstract class SourceClient {
  /// `nyaa` | `mikan` | `rss:<订阅id>`。
  String get id;

  String get displayName;

  bool get supportsSearch;

  Future<SourcePage> latest({int page = 1});

  Future<SourcePage> search(String keyword, {int page = 1});

  /// 有详情页能力的源才实现；默认返回 null（表示「本源不支持补齐详情」）。
  Future<SourceItem?> detail(SourceItem item) async => null;
}

/// 带缓存 + 限速 + 代理的源客户端骨架。
///
/// 统一取数流程（spec §4.2）：
/// 1. 新鲜缓存命中（未过期）→ 直接返回，`fromCache = true`，**不发网络请求**；
/// 2. 否则走网络；成功 → 写缓存并返回 `fromCache = false`；
/// 3. 网络失败 → 回落 stale 缓存（忽略 TTL），`fromCache = true`；
/// 4. 没有 stale 可用 → 原样抛出 [SourceException]（**不伪造空数据**）。
abstract class CachedSourceClient implements SourceClient {
  CachedSourceClient({
    required this.http,
    required this.cache,
    ClockFn? clock,
  }) : clock = clock ?? DateTime.now;

  /// 抓取器（共享，内含限速 + 代理 + 重试）。
  final SourceHttp http;

  /// 缓存。
  final SourceCache cache;

  /// 时钟（可注入，单测用假时钟）。
  final ClockFn clock;

  /// 默认「不支持详情补齐」（spec §4.2：默认返回 null）。
  @override
  Future<SourceItem?> detail(SourceItem item) async => null;

  /// 取数主流程。
  Future<SourcePage> loadPage({
    required CacheRequest request,
    required Future<SourcePage> Function() fetch,
  }) async {
    final cached = await cache.getPage(id, request, clock: clock);
    if (cached != null) return cached;

    try {
      final page = await fetch();
      await cache.putPage(id, request, page);
      return page;
    } on SourceException {
      final stale =
          await cache.getPage(id, request, allowStale: true, clock: clock);
      if (stale != null) return stale;
      rethrow;
    }
  }
}
