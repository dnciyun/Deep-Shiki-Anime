/// 观看记录 + 「已看过」标记（用户第二十七轮）。
///
/// 两件事同源但**不是一份数据**：
/// * [WatchRecord] —— 「看过什么」的流水：每看一集记一条（番名 / 集数 / 字幕组 /
///   看过时间 / 播放进度），侧栏「观看记录」页展示它、可导出、超期自动清；
/// * [WatchedMarkStore] —— 「这集算看完了」的勾：可以手动打（正在追里点一下），
///   也可以由播放进度自动打。「下载全部」靠它跳过已经看过的集。
///
/// 为什么分成两份：观看记录是**会过期的流水**（30 天自动清），而「已看过」是
/// **不该过期的事实** —— 清了流水就把"这部我追到第 8 集了"忘掉，正是用户最不想要的。
/// 打勾的粒度是**集**（番剧 + 字幕组 + 集数），不是整部番。
library;

import 'dart:convert';

import 'package:dsanima_core/sources/kv.dart' show KeyValueStore;
import 'package:flutter/foundation.dart';

/// 「观看记录」自动清理的保留档位（天）：**0 = 永不自动删除**。
///
/// 默认 30（用户：「超 30 天自动移除，可在设置内更改删除时间或不删除」）。
const List<int> kHistoryRetentionDays = <int>[7, 30, 90, 0];

/// 观看记录条数硬上限（保留天数之外的第二道闸）。
///
/// 为什么还要条数上限：保留档位是"天数"，一个把 30 天填满的重度用户能堆出几万条，
/// Hive 里一份 JSON 会拖慢每次读写。2000 条对"回看我看过什么"远远够用，
/// 超出时丢**最旧**的（见 [upsertWatchRecord]）。
const int kWatchHistoryMaxEntries = 2000;

/// 「看到多少算看完」：正片长度 90% 以上就算看完（片尾曲/滚动字幕不该让人再点一次）。
const double kWatchFinishedRatio = 0.9;

/// 一条观看记录。
///
/// 同一条（番剧 + 字幕组 + 集数）**反复看只留一条**：更新 [watchedAt] / 进度，
/// 不做"每次看都追加一条"—— 观看记录页要回答的是"我看过哪些集"，
/// 不是"我总共点开过多少次"。
@immutable
class WatchRecord {
  const WatchRecord({
    required this.id,
    required this.title,
    this.titleEn,
    this.coverUrl,
    this.coverReferer,
    this.mikanBangumiId,
    this.group,
    this.episodeLabel,
    this.episode,
    required this.watchedAt,
    this.positionMs = 0,
    this.durationMs = 0,
    this.engineId,
    this.fileIndex,
    this.infoHash,
    this.sourceItemId,
  });

  /// 稳定键（见 [watchRecordId]）：同一集反复看只更新这一条。
  final String id;

  final String title;
  final String? titleEn;

  /// 封面（mikan 图床 / Bangumi 图床；Bangumi 的要带 [coverReferer]）。
  final String? coverUrl;
  final String? coverReferer;

  /// mikan 番剧 id（用于回到详情页/正在追）。
  final String? mikanBangumiId;

  /// 字幕组（订阅的 mikan 字幕组 RSS 时能拿到；搜索来的条目也可能有）。
  final String? group;

  /// 展示用集号（`第 03 集` / `03` / 空）。
  final String? episodeLabel;

  /// 解析出的集数（打勾/去重用；认不出就是 null，不编）。
  final int? episode;

  /// 最近一次观看时间。
  final DateTime watchedAt;

  /// 看到的位置 / 总时长（毫秒）。`recordWatchProgress` 关掉时**不再更新**，
  /// 保留最后一次记到的值（不抹掉历史，也不假装是 0）。
  final int positionMs;
  final int durationMs;

  /// 播放用的引擎坐标（「继续播放」要复用它）。
  final int? engineId;
  final int? fileIndex;

  /// 种子 infohash：引擎重启后 `engineId` 会变，靠它重新找到那条 torrent。
  final String? infoHash;

  /// 源条目 id（`mikan:<hash>` / `rss:<订阅>:<guid>`），用于再点播时补磁力。
  final String? sourceItemId;

  /// 0..1；时长未知时是 0（**不编**）。
  double get progress {
    if (durationMs <= 0) return 0;
    return (positionMs / durationMs).clamp(0.0, 1.0);
  }

  /// 看到 [kWatchFinishedRatio] 之上算看完（时长未知时判否 —— 不猜）。
  bool get finished => durationMs > 0 && positionMs >= durationMs * kWatchFinishedRatio;

  /// 「继续播放」这一下该从哪儿开始（毫秒）；`null` = 从头。
  ///
  /// 第四十二轮 UX #2（二级，100% 必现）：观看记录那一行写着
  /// 「看到 12:34 / 24:00（52%）」+ 进度条，点「继续播放」却**永远从 0:00 开始**，
  /// 一句说明都没有 —— 界面承诺了却不兑现。
  ///
  /// 规则（与界面文案严格对齐，不留第二种解释）：
  /// * **已看完** → `null`。行里那个按钮对看完的集显示的也是「重看」，
  ///   从 95% 接着放没有意义；
  /// * 没有进度记录（`positionMs <= 0`）→ `null`（本来就该从头）；
  /// * 其余 → 记录里的位置。**不给"太靠前就从 0 开始"之类的阈值** ——
  ///   行里写着「看到 00:12」，那就必须从 00:12 开始，否则又是同一个假承诺。
  int? get resumePositionMs => (finished || positionMs <= 0) ? null : positionMs;

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'title': title,
    'titleEn': titleEn,
    'coverUrl': coverUrl,
    'coverReferer': coverReferer,
    'mikanBangumiId': mikanBangumiId,
    'group': group,
    'episodeLabel': episodeLabel,
    'episode': episode,
    'watchedAt': watchedAt.toIso8601String(),
    'positionMs': positionMs,
    'durationMs': durationMs,
    'engineId': engineId,
    'fileIndex': fileIndex,
    'infoHash': infoHash,
    'sourceItemId': sourceItemId,
  };

  /// 单条坏数据 → null（整份记录不因为一条坏行报废，与追番记录同一口径）。
  static WatchRecord? fromJson(Object? raw) {
    if (raw is! Map) return null;
    String? str(Object? v) {
      final String s = (v ?? '').toString().trim();
      return s.isEmpty ? null : s;
    }

    final String id = (raw['id'] ?? '').toString();
    final String title = (raw['title'] ?? '').toString();
    final DateTime? at = DateTime.tryParse((raw['watchedAt'] ?? '').toString());
    if (id.isEmpty || title.isEmpty || at == null) return null;
    return WatchRecord(
      id: id,
      title: title,
      titleEn: str(raw['titleEn']),
      coverUrl: str(raw['coverUrl']),
      coverReferer: str(raw['coverReferer']),
      mikanBangumiId: str(raw['mikanBangumiId']),
      group: str(raw['group']),
      episodeLabel: str(raw['episodeLabel']),
      episode: (raw['episode'] as num?)?.toInt(),
      watchedAt: at,
      positionMs: (raw['positionMs'] as num?)?.toInt() ?? 0,
      durationMs: (raw['durationMs'] as num?)?.toInt() ?? 0,
      engineId: (raw['engineId'] as num?)?.toInt(),
      fileIndex: (raw['fileIndex'] as num?)?.toInt(),
      infoHash: str(raw['infoHash']),
      sourceItemId: str(raw['sourceItemId']),
    );
  }

  WatchRecord copyWith({
    String? title,
    String? coverUrl,
    String? coverReferer,
    String? mikanBangumiId,
    String? group,
    String? episodeLabel,
    int? episode,
    DateTime? watchedAt,
    int? positionMs,
    int? durationMs,
    int? engineId,
    int? fileIndex,
    String? infoHash,
    String? sourceItemId,
  }) => WatchRecord(
    id: id,
    title: title ?? this.title,
    titleEn: titleEn,
    coverUrl: coverUrl ?? this.coverUrl,
    coverReferer: coverReferer ?? this.coverReferer,
    mikanBangumiId: mikanBangumiId ?? this.mikanBangumiId,
    group: group ?? this.group,
    episodeLabel: episodeLabel ?? this.episodeLabel,
    episode: episode ?? this.episode,
    watchedAt: watchedAt ?? this.watchedAt,
    positionMs: positionMs ?? this.positionMs,
    durationMs: durationMs ?? this.durationMs,
    engineId: engineId ?? this.engineId,
    fileIndex: fileIndex ?? this.fileIndex,
    infoHash: infoHash ?? this.infoHash,
    sourceItemId: sourceItemId ?? this.sourceItemId,
  );
}

/// 观看记录的稳定键：**番剧 + 字幕组 + 集数**。
///
/// 为什么要带字幕组：同一集常有两个字幕组的版本，看了 A 组的 08 不等于看了 B 组的 08
/// （用户在正在追里按字幕组订阅，正是为了分清这件事）。
/// 集数认不出时退化成集号文案，再认不出退化成空 —— 宁可两条分开，也不要合并错。
String watchRecordId({
  String? mikanBangumiId,
  required String title,
  String? group,
  int? episode,
  String? episodeLabel,
}) {
  final String show = (mikanBangumiId ?? '').trim().isEmpty
      ? title.trim().toLowerCase()
      : 'mikan:${mikanBangumiId!.trim()}';
  final String g = (group ?? '').trim();
  final String ep = episode != null
      ? 'e$episode'
      : ((episodeLabel ?? '').trim().isEmpty ? 'all' : (episodeLabel!).trim());
  return '$show|$g|$ep';
}

/// 「这一集该从哪儿接着播」—— 续播的唯一口径（用户 2026-10-18：
/// 「发现bug继续观看回不到上一次的观看位置」）。
///
/// 为什么要有这个函数：`resumePositionMs` 之前只在两处被用到 —— 「观看记录」页点
/// 「继续播放」、以及重启后侧栏那行「继续播放」。其它点播入口（正在追/今日更新点开层、
/// 已完成页、播放列表切集）**一律从 0 开始**；而子窗口自己那份续播记忆是按
/// **串流 URL** 存的（`ShikiiN` 的 `SettingsController.resumeKey` = md5(URL|size)），
/// URL 里带着边车 token，重启一次就换了 ⇒ 那份记忆必然 miss。
/// 观看记录里的位置才是按「番剧 + 字幕组 + 集数」记的，跨重启仍然有效。
///
/// 规则与 [WatchRecord.resumePositionMs] 完全一致（已看完 / 没进度 → null = 从头），
/// 所以「看了 95% 算看完」这条不会再从别的入口漏一遍。
int? resumePositionForRecord(Iterable<WatchRecord> records, String recordId) {
  for (final WatchRecord r in records) {
    if (r.id == recordId) return r.resumePositionMs;
  }
  return null;
}

/// 同上，但按**引擎坐标**查（[infoHash] + [fileIndex]）。
///
/// 「已完成」页点播没有番剧/集号上下文，手上只有 torrent 与文件序号；那两样恰好也
/// 记在观看记录里（[WatchRecord.infoHash] / [WatchRecord.fileIndex]），所以能对上。
///
/// 同 infoHash 可能有多条（不同文件）：`fileIndex` 必须严格相等，缺省时只匹配同样
/// 缺省的老记录 —— **不猜**「大概是这一集」。命中多条时取最近看的那条。
int? resumePositionForFile(
  Iterable<WatchRecord> records, {
  String? infoHash,
  int? fileIndex,
}) {
  final String hash = (infoHash ?? '').trim();
  if (hash.isEmpty) return null;
  int? best;
  DateTime? bestAt;
  for (final WatchRecord r in records) {
    if ((r.infoHash ?? '').trim() != hash) continue;
    if (r.fileIndex != fileIndex) continue;
    final int? ms = r.resumePositionMs;
    if (ms == null) continue;
    if (bestAt != null && !r.watchedAt.isAfter(bestAt)) continue;
    best = ms;
    bestAt = r.watchedAt;
  }
  return best;
}

/// 按保留天数丢掉过期的记录（纯函数）。
///
/// [retentionDays] <= 0 表示**永不删除**（用户可选项）；判据是 [WatchRecord.watchedAt]
/// （"最近一次看"的时间）—— 一部番一个月前看到第 3 集、昨天又看了一集，
/// 这两条各自按自己的时间算，不做"整部番一起过期"。
List<WatchRecord> pruneWatchHistory(
  List<WatchRecord> records, {
  required int retentionDays,
  required DateTime now,
}) {
  if (retentionDays <= 0) return List<WatchRecord>.unmodifiable(records);
  final DateTime cutoff = now.subtract(Duration(days: retentionDays));
  return List<WatchRecord>.unmodifiable(
    records.where((WatchRecord r) => r.watchedAt.isAfter(cutoff)),
  );
}

/// 写入一条记录：同键**覆盖**，并保证按 [WatchRecord.watchedAt] 倒序、不超过 [maxEntries]。
///
/// 纯函数：调用方（provider）负责落盘。
List<WatchRecord> upsertWatchRecord(
  List<WatchRecord> records,
  WatchRecord record, {
  int maxEntries = kWatchHistoryMaxEntries,
}) {
  final List<WatchRecord> next = <WatchRecord>[
    record,
    ...records.where((WatchRecord r) => r.id != record.id),
  ];
  next.sort((WatchRecord a, WatchRecord b) => b.watchedAt.compareTo(a.watchedAt));
  if (next.length <= maxEntries) return List<WatchRecord>.unmodifiable(next);
  return List<WatchRecord>.unmodifiable(next.sublist(0, maxEntries));
}

/// 更新某条记录的进度（**同键覆盖**，找不到就原样返回 —— 不凭空造记录）。
///
/// 只动进度与观看时间，不动标题/封面这些"身份"字段。
List<WatchRecord> updateWatchProgress(
  List<WatchRecord> records, {
  required String id,
  required int positionMs,
  required int durationMs,
  DateTime? at,
}) {
  final int index = records.indexWhere((WatchRecord r) => r.id == id);
  if (index < 0) return List<WatchRecord>.unmodifiable(records);
  final WatchRecord old = records[index];
  final WatchRecord next = old.copyWith(
    positionMs: positionMs < 0 ? 0 : positionMs,
    durationMs: durationMs < 0 ? 0 : durationMs,
    watchedAt: at ?? DateTime.now(),
  );
  final List<WatchRecord> out = <WatchRecord>[...records];
  out[index] = next;
  out.sort((WatchRecord a, WatchRecord b) => b.watchedAt.compareTo(a.watchedAt));
  return List<WatchRecord>.unmodifiable(out);
}

/// 导出成 JSON 文本（UTF-8 可写文件）。
///
/// **含隐私**（看过什么、看到哪儿）—— 这是用户显式点的「导出观看记录」，
/// 与"诊断包不含观看历史"（`config_io.dart`）不冲突：那条约束说的是**自动**带出去的包。
String watchHistoryJson(
  List<WatchRecord> records, {
  DateTime? exportedAt,
  int? retentionDays,
}) {
  return const JsonEncoder.withIndent('  ').convert(<String, Object?>{
    'schema': 'dsanima.watch-history/1',
    'app': 'DSAnima',
    'exportedAt': (exportedAt ?? DateTime.now()).toIso8601String(),
    if (retentionDays != null)
      'retention': retentionDays <= 0 ? 'keep' : '$retentionDays days',
    'count': records.length,
    'records': <Object?>[for (final WatchRecord r in records) r.toJson()],
  });
}

/// 观看记录的持久化（与追番记录同一套 `KeyValueStore`）。
class WatchHistoryStore {
  WatchHistoryStore(this._store, {this.key = defaultKey});

  static const String defaultKey = 'dsanima.watch_history';

  final KeyValueStore _store;
  final String key;

  List<WatchRecord> load() {
    final Object? raw = _store.get(key);
    if (raw is! List) return const <WatchRecord>[];
    return raw
        .map(WatchRecord.fromJson)
        .whereType<WatchRecord>()
        .toList(growable: false);
  }

  Future<void> save(List<WatchRecord> records) => _store.put(
    key,
    records.map((WatchRecord r) => r.toJson()).toList(growable: false),
  );

  Future<void> clear() => _store.delete(key);
}

// ─────────────────────────────────────────────────────────────────────────────
// 「已看过」标记
// ─────────────────────────────────────────────────────────────────────────────

/// 「已看过」的键：番剧 + 字幕组 + 集数（与 [watchRecordId] 同一套口径）。
String watchedKey(
  String bangumiId, {
  String? group,
  int? episode,
  String? episodeLabel,
}) => watchRecordId(
  mikanBangumiId: bangumiId,
  title: bangumiId,
  group: group,
  episode: episode,
  episodeLabel: episodeLabel,
);

/// 一次播放要记的账（第二十七轮）：观看记录键 + 元数据。
///
/// 为什么在**开播那一刻**算好键：进度是子窗口之后才报上来的（`kMethodWatchProgress`），
/// 那时宿主手上只剩 `nowPlaying`。把键当时算好、随 `NowPlaying` 带着走，
/// 就不会出现"开播记了一条、进度又记到另一个键上"的分裂。
@immutable
class WatchMeta {
  const WatchMeta({
    required this.recordId,
    required this.title,
    this.titleEn,
    this.coverUrl,
    this.coverReferer,
    this.mikanBangumiId,
    this.group,
    this.episode,
    this.episodeLabel,
    this.infoHash,
    this.sourceItemId,
  });

  /// [watchRecordId] 的结果 —— 同时就是「已看过」的键（两者口径一致）。
  final String recordId;

  final String title;
  final String? titleEn;
  final String? coverUrl;
  final String? coverReferer;
  final String? mikanBangumiId;
  final String? group;
  final int? episode;
  final String? episodeLabel;
  final String? infoHash;
  final String? sourceItemId;

  /// 这一条播放的「已看过」键（与 [recordId] 同值，单独给一个名字是为了调用处好读）。
  String get watchedKey => recordId;
}

/// 按同一套口径装配 [WatchMeta]（`mikanBangumiId` 缺省时退化成番名）。
WatchMeta buildWatchMeta({
  required String title,
  String? titleEn,
  String? coverUrl,
  String? coverReferer,
  String? mikanBangumiId,
  String? group,
  int? episode,
  String? episodeLabel,
  String? infoHash,
  String? sourceItemId,
}) {
  final String show = (mikanBangumiId ?? '').trim();
  return WatchMeta(
    recordId: watchRecordId(
      mikanBangumiId: show.isEmpty ? null : show,
      title: title,
      group: group,
      episode: episode,
      episodeLabel: episodeLabel,
    ),
    title: title,
    titleEn: titleEn,
    coverUrl: coverUrl,
    coverReferer: coverReferer,
    mikanBangumiId: show.isEmpty ? null : show,
    group: group,
    episode: episode,
    episodeLabel: episodeLabel,
    infoHash: infoHash,
    sourceItemId: sourceItemId,
  );
}

/// 「已看过」标记的持久化：`{键: 打勾时间}`。
///
/// 只在被标记过之后才有条目 —— 没看过就是**不在表里**（不写 false）。
///
/// 另有一个**抑制表**（`dsanima.watched_unmarked`）：用户**手动取消**过勾的那些键。
/// 有了它，"播到 95% 自动打勾 → 用户说'片尾我没看完'点掉 → 5 秒后又被自动打回来"
/// 这个死循环才不会出现（见 `watchedMarksProvider` 的 `mark(byUser:)`）。
class WatchedMarkStore {
  WatchedMarkStore(this._store, {this.key = defaultKey, this.suppressedKey = defaultSuppressedKey});

  static const String defaultKey = 'dsanima.watched_marks';

  /// 用户手动取消过勾的键（自动打勾要跳过它们）。
  static const String defaultSuppressedKey = 'dsanima.watched_unmarked';

  final KeyValueStore _store;
  final String key;
  final String suppressedKey;

  Map<String, DateTime> load() => _decode(_store.get(key));

  Map<String, DateTime> loadSuppressed() => _decode(_store.get(suppressedKey));

  Future<void> save(Map<String, DateTime> marks) => _store.put(key, _encode(marks));

  Future<void> saveSuppressed(Map<String, DateTime> marks) =>
      _store.put(suppressedKey, _encode(marks));

  Future<void> clear() async {
    await _store.delete(key);
    await _store.delete(suppressedKey);
  }

  static Map<String, DateTime> _decode(Object? raw) {
    if (raw is! Map) return const <String, DateTime>{};
    final Map<String, DateTime> out = <String, DateTime>{};
    raw.forEach((Object? k, Object? v) {
      final String key = (k ?? '').toString();
      final DateTime? at = DateTime.tryParse((v ?? '').toString());
      if (key.isEmpty || at == null) return;
      out[key] = at;
    });
    return out;
  }

  static Map<String, String> _encode(Map<String, DateTime> marks) => <String, String>{
    for (final MapEntry<String, DateTime> e in marks.entries) e.key: e.value.toIso8601String(),
  };
}
