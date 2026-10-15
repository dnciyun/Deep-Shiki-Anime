/// 观看记录与「已看过」标记的状态（第二十七轮）。
///
/// 为什么单独一个文件（而不是塞进 `host_store.dart`）：这两个控制器读**设置**
/// （保留档位决定加载时清掉哪些），而 `host_store.dart` 刻意只依赖 `infra.dart`；
/// 放到 `providers.dart` 的 re-export 之后，业务代码仍然只 import `state/providers.dart`。
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/models.dart';
import '../domain/watch_history.dart';
import 'infra.dart';
import 'providers.dart' show settingsProvider;

/// 观看记录（按 `watchedAt` 倒序，已按保留档位清过）。
class WatchHistoryController extends Notifier<List<WatchRecord>> {
  WatchHistoryStore get _store => WatchHistoryStore(ref.read(keyValueStoreProvider));

  @override
  List<WatchRecord> build() {
    // 保留档位变了就重算一次（设置页保存后立刻生效，不用等下次启动）。
    final int retentionDays =
        ref.watch(settingsProvider.select((AppSettings s) => s.historyRetentionDays));
    final List<WatchRecord> loaded = _store.load();
    final List<WatchRecord> kept = pruneWatchHistory(
      loaded,
      retentionDays: retentionDays,
      now: DateTime.now(),
    );
    if (kept.length != loaded.length) {
      // 过期的**就地清掉**：不能只显示"已过滤"，否则盘上那份永远在长。
      unawaited(_store.save(kept));
    }
    return kept;
  }

  /// 立刻按当前保留档位清一遍（第二十七轮复核抓到的问题：只靠 `build()` 清，
  /// 常驻不重启的程序里"超 30 天自动移除"就变成了"启动时移除"）。
  ///
  /// 「观看记录」页挂载时调一次 + 每 30 分钟调一次；没东西可清时不写盘。
  /// [retentionDays] / [now] 是给测试用的缝（真实调用不带，走当前设置与当前时间）；
  /// 返回清掉了几条。
  Future<int> pruneNow({int? retentionDays, DateTime? now}) async {
    final int days = retentionDays ??
        ref.read(settingsProvider).historyRetentionDays;
    final List<WatchRecord> kept = pruneWatchHistory(
      state,
      retentionDays: days,
      now: now ?? DateTime.now(),
    );
    if (kept.length == state.length) return 0;
    final int dropped = state.length - kept.length;
    await _write(kept);
    return dropped;
  }

  /// 开播时记一条（同一集覆盖，刷新时间与元数据）。
  ///
  /// 进度**保留上一次的值**直到有新的回报：重看同一集时，"上次看到 18 分钟"
  /// 比立刻抹成 0 更有用（新进度一来就会被覆盖）。
  Future<WatchRecord> recordStart({
    required String title,
    String? titleEn,
    String? coverUrl,
    String? coverReferer,
    String? mikanBangumiId,
    String? group,
    int? episode,
    String? episodeLabel,
    int? engineId,
    int? fileIndex,
    String? infoHash,
    String? sourceItemId,
    DateTime? at,
  }) async {
    final String id = watchRecordId(
      mikanBangumiId: mikanBangumiId,
      title: title,
      group: group,
      episode: episode,
      episodeLabel: episodeLabel,
    );
    WatchRecord? previous;
    for (final WatchRecord r in state) {
      if (r.id == id) previous = r;
    }
    final WatchRecord record = WatchRecord(
      id: id,
      title: title,
      titleEn: titleEn ?? previous?.titleEn,
      coverUrl: coverUrl ?? previous?.coverUrl,
      coverReferer: coverReferer ?? previous?.coverReferer,
      mikanBangumiId: mikanBangumiId ?? previous?.mikanBangumiId,
      group: group ?? previous?.group,
      episodeLabel: episodeLabel ?? previous?.episodeLabel,
      episode: episode ?? previous?.episode,
      watchedAt: at ?? DateTime.now(),
      positionMs: previous?.positionMs ?? 0,
      durationMs: previous?.durationMs ?? 0,
      engineId: engineId ?? previous?.engineId,
      fileIndex: fileIndex ?? previous?.fileIndex,
      infoHash: infoHash ?? previous?.infoHash,
      sourceItemId: sourceItemId ?? previous?.sourceItemId,
    );
    await _write(upsertWatchRecord(state, record));
    return record;
  }

  /// 进度回报：只动进度（**没有这条记录就不写** —— 不凭空造"看过"）。
  ///
  /// 同值不重复落盘：子窗口每 5 秒报一条，但"暂停着不动"会一直报同一个数。
  Future<void> recordProgress({
    required String id,
    required int positionMs,
    required int durationMs,
  }) async {
    final int index = state.indexWhere((WatchRecord r) => r.id == id);
    if (index < 0) return;
    final WatchRecord old = state[index];
    if (old.positionMs == positionMs && old.durationMs == durationMs) return;
    await _write(updateWatchProgress(
      state,
      id: id,
      positionMs: positionMs,
      durationMs: durationMs,
    ));
  }

  Future<void> remove(String id) async {
    final List<WatchRecord> next =
        state.where((WatchRecord r) => r.id != id).toList(growable: false);
    if (next.length == state.length) return;
    await _write(next);
  }

  Future<void> clear() async {
    state = const <WatchRecord>[];
    await _store.clear();
  }

  Future<void> _write(List<WatchRecord> next) async {
    state = next;
    await _store.save(next);
  }
}

final NotifierProvider<WatchHistoryController, List<WatchRecord>> watchHistoryProvider =
    NotifierProvider<WatchHistoryController, List<WatchRecord>>(WatchHistoryController.new);

/// 「已看过」标记：`{键: 打勾时间}`。
///
/// 区分**用户打的勾**与**自动打的勾**（第二十七轮复核抓到的一处真实缺陷）：
/// 播到 90% 会自动打勾，用户看片尾是 ED、点掉那一集的勾之后，5 秒后子窗口又报一条
/// 位置 ≥90% 的进度 —— 没有抑制表的话 `mark` 会把勾打回来，**用户永远取消不掉**。
/// 所以：`unmark(..., byUser: true)` 记进抑制表；自动路径 `mark(...)` 跳过抑制表里的键；
/// 用户自己手动打勾（`mark(..., byUser: true)`）会把抑制解掉（他的最新意图是"看过"）。
class WatchedMarksController extends Notifier<Map<String, DateTime>> {
  WatchedMarkStore get _store => WatchedMarkStore(ref.read(keyValueStoreProvider));

  /// 用户手动取消过勾的键（不参与 UI，纯记账）。
  Map<String, DateTime> _suppressed = const <String, DateTime>{};

  @override
  Map<String, DateTime> build() {
    _suppressed = _store.loadSuppressed();
    return _store.load();
  }

  bool isWatched(String key) => state.containsKey(key);

  /// 这些键是不是**都**已经打过勾（空集合判否 —— "没有集"谈不上"都看过"）。
  bool allWatched(Iterable<String> keys) {
    bool any = false;
    for (final String key in keys) {
      any = true;
      if (!state.containsKey(key)) return false;
    }
    return any;
  }

  /// [byUser] false（默认，自动路径）= 跳过用户手动取消过的键。
  Future<void> mark(Iterable<String> keys, {DateTime? at, bool byUser = false}) async {
    final Map<String, DateTime> next = <String, DateTime>{...state};
    final Map<String, DateTime> suppressed = <String, DateTime>{..._suppressed};
    final DateTime stamp = at ?? DateTime.now();
    bool changed = false;
    bool suppressionChanged = false;
    for (final String key in keys) {
      if (key.isEmpty) continue;
      if (!byUser && suppressed.containsKey(key)) continue; // 用户取消过：不许自动打回来
      if (byUser && suppressed.remove(key) != null) suppressionChanged = true;
      if (next.containsKey(key)) continue;
      next[key] = stamp;
      changed = true;
    }
    if (suppressionChanged) {
      _suppressed = Map<String, DateTime>.unmodifiable(suppressed);
      await _store.saveSuppressed(suppressed);
    }
    if (changed) await _write(next);
  }

  /// [byUser] true（默认，正在追里点的那一下）= 把这一条记进抑制表。
  Future<void> unmark(Iterable<String> keys, {bool byUser = true}) async {
    final Map<String, DateTime> next = <String, DateTime>{...state};
    final Map<String, DateTime> suppressed = <String, DateTime>{..._suppressed};
    final DateTime stamp = DateTime.now();
    bool changed = false;
    bool suppressionChanged = false;
    for (final String key in keys) {
      if (key.isEmpty) continue;
      if (next.remove(key) != null) changed = true;
      if (byUser && !suppressed.containsKey(key)) {
        suppressed[key] = stamp;
        suppressionChanged = true;
      }
    }
    if (suppressionChanged) {
      _suppressed = Map<String, DateTime>.unmodifiable(suppressed);
      await _store.saveSuppressed(suppressed);
    }
    if (changed) await _write(next);
  }

  /// 打勾/取消打勾（正在追里点的那一下，两个方向都算"用户的意图"）；
  /// 返回 true = 现在已看过。
  Future<bool> toggle(String key) async {
    if (state.containsKey(key)) {
      await unmark(<String>[key], byUser: true);
      return false;
    }
    await mark(<String>[key], byUser: true);
    return true;
  }

  Future<void> clear() async {
    state = const <String, DateTime>{};
    _suppressed = const <String, DateTime>{};
    await _store.clear();
  }

  Future<void> _write(Map<String, DateTime> next) async {
    state = Map<String, DateTime>.unmodifiable(next);
    await _store.save(next);
  }
}

final NotifierProvider<WatchedMarksController, Map<String, DateTime>> watchedMarksProvider =
    NotifierProvider<WatchedMarksController, Map<String, DateTime>>(
      WatchedMarksController.new,
    );
