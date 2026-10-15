/// Bangumi 元数据服务（spec §7.8）：按番名查条目，**磁盘缓存 7 天**，失败一律静默降级。
///
/// 用途：番剧详情页的「封面 + 标签 + 评分 + 年份」块（「正在追」卡的评分也来自追番记录里的同一批数据）。
/// **搜索页不加封面**（用户明确要求搜索页是纯列表，spec §7.5）。
library;

import 'package:dsanima_core/sources/kv.dart' show KeyValueStore;

import '../domain/bangumi.dart';
import '../domain/bangumi_match.dart';
import '../domain/title_match.dart';

/// 一次匹配查询的结果。
class BangumiLookup {
  const BangumiLookup({this.match, this.error});

  /// null = 没匹配上（或失败了）——UI 显示「未匹配到 Bangumi」，**不显示错封面**。
  final BangumiMatch? match;
  final String? error;

  bool get matched => match != null;
  BangumiSubject? get subject => match?.subject;
}

/// 名字 → Bangumi 条目（带 7 天磁盘缓存 + 进程内缓存）。
class BangumiMetaService {
  BangumiMetaService({
    required this.store,
    BangumiClient? client,
    this.cacheTtl = const Duration(days: 7),
    DateTime Function()? clock,
  })  : client = client ?? BangumiClient(),
        _clock = clock ?? DateTime.now;

  static const String _prefix = 'dsanima.bangumi.meta.';

  final KeyValueStore store;
  final BangumiClient client;
  final Duration cacheTtl;
  final DateTime Function() _clock;

  /// 进程内缓存：一次页面刷新里同一部番只查一次。
  final Map<String, BangumiLookup> _memory = <String, BangumiLookup>{};

  /// 查一部番的元数据。**永不抛**（网络/解析失败都变成 `error` 字段）。
  Future<BangumiLookup> lookup(
    String? title, {
    int? year,
    int? episodes,
  }) async {
    final String key = normalizeTitleForMatch(title);
    if (key.length < minMatchableTitleLength) {
      return const BangumiLookup();
    }
    final BangumiLookup? cachedMemory = _memory[key];
    if (cachedMemory != null) return cachedMemory;

    final BangumiLookup? cachedDisk = _readCache(key);
    if (cachedDisk != null) {
      _memory[key] = cachedDisk;
      return cachedDisk;
    }

    try {
      final List<BangumiSubject> results =
          await client.searchSubjects(title ?? '', maxResults: 10);
      BangumiMatch? match =
          bestBangumiMatch(title, results, year: year, episodes: episodes);
      // 命中后补一次详情（搜索接口的 rating/tags 可能是精简的）。
      if (match != null) {
        try {
          final BangumiSubject detail = await client.subject(match.subject.id);
          final BangumiMatch? verified = bestBangumiMatch(
            title,
            <BangumiSubject>[detail],
            year: year,
            episodes: episodes,
          );
          if (verified != null) match = verified;
        } catch (_) {
          // 详情失败就用搜索结果（不算失败）。
        }
      }
      final BangumiLookup result = BangumiLookup(match: match);
      _memory[key] = result;
      await _writeCache(key, result);
      return result;
    } catch (error) {
      final BangumiLookup failure = BangumiLookup(error: '$error');
      // 失败**不落盘**（下次还能重试），但本轮记住，避免同一页反复打接口。
      _memory[key] = failure;
      return failure;
    }
  }

  BangumiLookup? _readCache(String key) {
    final Object? raw = store.get('$_prefix$key');
    if (raw is! Map) return null;
    final Map<Object?, Object?> map = raw.cast<Object?, Object?>();
    // ⚠️ 不许直接 `as String?`：缓存是"加速手段"，磁盘上一条脏数据（类型被写坏）
    // 就会抛 TypeError，而这里是**没有** try/catch 的读取路径 —— 一次坏记录能把页面打崩。
    // 类型不对就当"没有时间戳" → 按 miss 处理，下一句自然去重查。
    final Object? atRaw = map['cachedAt'];
    final DateTime? at = atRaw is String ? DateTime.tryParse(atRaw) : null;
    if (at == null || _clock().difference(at) > cacheTtl) return null;
    final Object? subject = map['subject'];
    if (subject is! Map) {
      // 缓存里也记「没匹配上」，避免每次开页面都重查。
      return const BangumiLookup();
    }
    return BangumiLookup(
      match: BangumiMatch(
        BangumiSubject.fromJson(subject.cast<String, Object?>()),
        BangumiMatchConfidence.contained,
      ),
    );
  }

  Future<void> _writeCache(String key, BangumiLookup value) async {
    try {
      await store.put('$_prefix$key', <String, Object?>{
        'cachedAt': _clock().toIso8601String(),
        if (value.subject != null) 'subject': value.subject!.toJson(),
      });
    } catch (_) {
      // 缓存写失败不影响本次结果。
    }
  }

  void dispose() => client.dispose();
}
