/// 「追番」本地标记的持久化（spec §7.6）。
///
/// ⚠️ **追番是轻量本地标记，不是订阅**：订阅（`Subscription`）是「自动下载规则」，
/// 会真的下东西；追番只是往「正在追」页收一份条目。两者互相独立。
///
/// 存 `KeyValueStore`（宿主用 Hive 实现，测试用内存实现），一份 JSON 数组。
library;

import 'package:dsanima_core/sources/kv.dart' show KeyValueStore;
import 'package:flutter/foundation.dart';

/// 一条追番记录。
///
/// 字段大多**可空且允许缺失**：从主页海报卡追番时只有中文名 + mikan 封面，
/// 从推荐卡追番时才有 Bangumi 的评分/日期/英文名。缺失就不显示，**不编**。
@immutable
class FollowingEntry {
  const FollowingEntry({
    required this.id,
    required this.title,
    this.titleEn,
    this.coverUrl,
    this.coverReferer,
    this.mikanBangumiId,
    this.bgmId,
    this.score,
    this.airDate,
    this.totalEpisodes,
    required this.addedAt,
    this.lastWatchedAt,
  });

  /// 稳定唯一键：`mikan:<bangumiId>` / `bgm:<id>` / `title:<归一化名>`。
  final String id;
  final String title;
  final String? titleEn;

  /// 封面 URL（mikan 图床或 Bangumi 图床）。
  final String? coverUrl;

  /// Bangumi 封面需要 `Referer: https://bgm.tv/`。
  final String? coverReferer;

  /// mikan 番剧 id（`/Home/Bangumi/<id>`），用于「详情」。
  final String? mikanBangumiId;

  /// Bangumi 条目 id。
  final int? bgmId;
  final double? score;

  /// 上映日期 `YYYY-MM-DD`。
  final String? airDate;

  /// 总话数（有才显示「共 M 话」，没有就不显示）。
  final int? totalEpisodes;

  final DateTime addedAt;
  final DateTime? lastWatchedAt;

  FollowingEntry copyWith({
    String? title,
    String? titleEn,
    String? coverUrl,
    String? coverReferer,
    String? mikanBangumiId,
    int? bgmId,
    double? score,
    String? airDate,
    int? totalEpisodes,
    DateTime? lastWatchedAt,
  }) =>
      FollowingEntry(
        id: id,
        title: title ?? this.title,
        titleEn: titleEn ?? this.titleEn,
        coverUrl: coverUrl ?? this.coverUrl,
        coverReferer: coverReferer ?? this.coverReferer,
        mikanBangumiId: mikanBangumiId ?? this.mikanBangumiId,
        bgmId: bgmId ?? this.bgmId,
        score: score ?? this.score,
        airDate: airDate ?? this.airDate,
        totalEpisodes: totalEpisodes ?? this.totalEpisodes,
        addedAt: addedAt,
        lastWatchedAt: lastWatchedAt ?? this.lastWatchedAt,
      );

  Map<String, Object?> toJson() => <String, Object?>{
        'id': id,
        'title': title,
        'titleEn': titleEn,
        'coverUrl': coverUrl,
        'coverReferer': coverReferer,
        'mikanBangumiId': mikanBangumiId,
        'bgmId': bgmId,
        'score': score,
        'airDate': airDate,
        'totalEpisodes': totalEpisodes,
        'addedAt': addedAt.toIso8601String(),
        'lastWatchedAt': lastWatchedAt?.toIso8601String(),
      };

  factory FollowingEntry.fromJson(Map<Object?, Object?> json) {
    String? str(Object? v) {
      final String s = (v ?? '').toString().trim();
      return s.isEmpty ? null : s;
    }

    return FollowingEntry(
      id: (json['id'] ?? '').toString(),
      title: (json['title'] ?? '').toString(),
      titleEn: str(json['titleEn']),
      coverUrl: str(json['coverUrl']),
      coverReferer: str(json['coverReferer']),
      mikanBangumiId: str(json['mikanBangumiId']),
      bgmId: (json['bgmId'] as num?)?.toInt(),
      score: (json['score'] as num?)?.toDouble(),
      airDate: str(json['airDate']),
      totalEpisodes: (json['totalEpisodes'] as num?)?.toInt(),
      addedAt: DateTime.tryParse((json['addedAt'] ?? '').toString()) ??
          DateTime.fromMillisecondsSinceEpoch(0),
      lastWatchedAt: DateTime.tryParse((json['lastWatchedAt'] ?? '').toString()),
    );
  }
}

/// 追番列表的读写（纯持久化，不碰网络）。
class FollowingStore {
  FollowingStore(this._store, {this.key = defaultKey});

  static const String defaultKey = 'dsanima.following';

  final KeyValueStore _store;
  final String key;

  List<FollowingEntry> load() {
    final Object? raw = _store.get(key);
    if (raw is! List) return <FollowingEntry>[];
    final List<FollowingEntry> out = <FollowingEntry>[];
    for (final Object? e in raw) {
      if (e is! Map) continue;
      try {
        final FollowingEntry entry =
            FollowingEntry.fromJson(e.cast<Object?, Object?>());
        if (entry.id.isNotEmpty) out.add(entry);
      } catch (_) {
        // 单条坏数据跳过，不让整份列表报废。
      }
    }
    return out;
  }

  Future<void> save(List<FollowingEntry> entries) => _store.put(
        key,
        entries.map((FollowingEntry e) => e.toJson()).toList(growable: false),
      );

  bool isFollowing(String id) =>
      load().any((FollowingEntry e) => e.id == id);

  /// 追番开关：返回 true = 现在已追。
  Future<bool> toggle(FollowingEntry entry) async {
    final List<FollowingEntry> entries = load();
    final int index =
        entries.indexWhere((FollowingEntry e) => e.id == entry.id);
    if (index >= 0) {
      entries.removeAt(index);
      await save(entries);
      return false;
    }
    entries.insert(0, entry);
    await save(entries);
    return true;
  }

  Future<void> remove(String id) async {
    final List<FollowingEntry> entries = load();
    entries.removeWhere((FollowingEntry e) => e.id == id);
    await save(entries);
  }

  /// 记一笔「最近观看」（用于「正在追」的第二排序键）。
  Future<void> touch(String id, {DateTime? at}) async {
    final List<FollowingEntry> entries = load();
    final int index =
        entries.indexWhere((FollowingEntry e) => e.id == id);
    if (index < 0) return;
    entries[index] =
        entries[index].copyWith(lastWatchedAt: at ?? DateTime.now());
    await save(entries);
  }
}
