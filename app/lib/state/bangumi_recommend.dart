/// 主页「今日推荐」：真实 Bangumi 客户端 + 磁盘缓存（spec §7.7）。
///
/// 只有装配根（`main.dart`）import 本文件；UI/state 只认 `domain/ports.dart`
/// 的 [RecommendPort]。
library;

import 'dart:async';

import 'package:dsanima_core/sources/kv.dart' show KeyValueStore;

import '../domain/bangumi.dart';
import '../domain/ports.dart';

/// 推荐结果的磁盘缓存条目（TTL 7 天；同一天重启不再打 Bangumi）。
const String _cachePrefix = 'dsanima.bangumi.recommend.';

/// `RecommendPort` 的真实实现：4 个远距离 offset（并发拉、单窗口失败不致命）
/// → 窗口均衡抽 5 部 → 落缓存。
class BangumiRecommendPort implements RecommendPort {
  BangumiRecommendPort({
    required this.store,
    BangumiClient? client,
    this.want = 5,
    this.windows = recommendWindowCount,
    this.perWindow = 2,
    this.limit = recommendPageLimit,
    this.cacheTtl = const Duration(days: 7),
    DateTime Function()? clock,
  })  : client = client ?? BangumiClient(),
        _clock = clock ?? DateTime.now;

  final KeyValueStore store;
  final BangumiClient client;
  final int want;
  final int windows;
  final int perWindow;
  final int limit;
  final Duration cacheTtl;
  final DateTime Function() _clock;

  @override
  bool get isAvailable => true;

  @override
  Future<List<BangumiSubject>> recommend({required int seed, int? count}) async {
    final int need = count ?? want;
    if (need <= 0) return const <BangumiSubject>[];

    final String key = '$_cachePrefix$seed';
    final List<BangumiSubject>? cached = _readCache(key);
    if (cached != null) return cached;

    // 先拉第一页拿到全库 total（顺便就是一个窗口），再算 4 个远距离 offset。
    //
    // ⚠️ **这一页失败是真失败**，照旧抛出去：没有 total 就算不出"摊到全年代"的那几个
    // 窗口，硬编一个总数只会让推荐挤在某一段。它自己带重试（见 BangumiClient）。
    final BangumiSubjectsPage first = await client.subjects(limit: limit, offset: 0);
    final int total = first.total > 0 ? first.total : first.items.length;
    final List<int> offsets = recommendOffsets(
      seed: seed,
      total: total,
      windows: windows,
      limit: limit,
    );

    // ⚠️ **第三十一轮**（用户 2026-10-15：「今日推荐拉取失败」）：4 个窗口改成
    // **并发**发出，并且**单个窗口失败只丢那一个窗口**。
    //
    // 以前是 `for (offset) { await … }` —— 串行 + 任何一个窗口抛异常就整次推荐失败。
    // 而真机实测 Bangumi 单次请求 0.24s~35.9s 乱抖（见 BangumiClient 类注释），
    // 四个窗口里踩中一个慢响应的概率相当高，于是"今天没有推荐"成了常态。
    // 现在：发车时刻仍由客户端的限速闸门排成至少 1.1s 间隔（不违规连打），但响应互相
    // 不等；4 个窗口的总耗时 ≈ 最慢的那一个，而不是四个之和。
    final List<List<BangumiSubject>?> landed =
        await Future.wait(<Future<List<BangumiSubject>?>>[
      for (final int offset in offsets)
        if (offset == 0)
          Future<List<BangumiSubject>?>.value(first.items)
        else
          _window(offset),
    ]);
    final List<List<BangumiSubject>> usable = <List<BangumiSubject>>[
      for (final List<BangumiSubject>? items in landed)
        if (items != null && items.isNotEmpty) items,
    ];
    if (usable.isEmpty) {
      throw BangumiException(
        'Bangumi 的 ${offsets.length} 个取数窗口全部失败（网络不通或站点不可用）',
        url: Uri.parse('$bangumiApiBase/v0/subjects'),
      );
    }

    final List<BangumiSubject> picked = selectRecommendations(
      usable,
      seed: seed,
      want: need,
      perWindow: perWindow,
    );
    await _writeCache(key, picked, total: total, offsets: offsets, landed: usable.length);
    return picked;
  }
  /// 拉一个窗口；**失败返回 null**（"少一个窗口还能不能出结果"由调用方决定）。
  ///
  /// 只吞"网络/HTTP/解析"这类运行时失败；`Error`（类型/断言这类编程错误）照旧抛出去，
  /// 不能因为一次兜底把真 bug 藏起来。
  Future<List<BangumiSubject>?> _window(int offset) async {
    try {
      final BangumiSubjectsPage page =
          await client.subjects(limit: limit, offset: offset);
      return page.items;
    } catch (error) {
      if (error is Error) rethrow;
      return null;
    }
  }

  List<BangumiSubject>? _readCache(String key) {
    final Object? raw = store.get(key);
    if (raw is! Map) return null;
    final Map<Object?, Object?> map = raw.cast<Object?, Object?>();
    final DateTime? at = DateTime.tryParse((map['cachedAt'] as String?) ?? '');
    if (at == null) return null;
    if (_clock().difference(at) > cacheTtl) return null;
    final Object? items = map['items'];
    if (items is! List) return null;
    return <BangumiSubject>[
      for (final Object? e in items)
        if (e is Map) BangumiSubject.fromJson(e.cast<String, Object?>()),
    ];
  }

  Future<void> _writeCache(
    String key,
    List<BangumiSubject> items, {
    required int total,
    required List<int> offsets,
    required int landed,
  }) async {
    try {
      await store.put(key, <String, Object?>{
        'cachedAt': _clock().toIso8601String(),
        'total': total,
        'offsets': offsets,
        // 这次有几个窗口真的拿到数据（排障用：推荐"年代偏了"时先看这里）。
        'landed': landed,
        'items': items.map((BangumiSubject s) => s.toJson()).toList(growable: false),
      });
    } catch (_) {
      // 缓存写失败不影响本次推荐结果。
    }
  }

  void dispose() => client.dispose();
}
