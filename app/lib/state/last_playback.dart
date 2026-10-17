/// 「上次播放」快照：**关掉程序之后**侧栏左下角那行「继续播放」靠它复活。
///
/// 用户 2026-10-17 报：「关闭程序后继续观看就没了，会影响有时候的体验」。
/// 旧实现里 `nowPlaying` 只活在内存（`PlaybackController` 的 provider 状态），
/// 进程一退就没了 —— 重启后侧栏那行整行不渲染，用户只能重新找源。
///
/// 这里只存**恢复播放真正需要的最小上下文**：
/// * **不序列化 `SourceItemView`**（它没有 toJson，而且重启后重新点播也不该复用旧条目：
///   磁力链可能过期、补链信息也可能变）；
/// * `infoHash` 是重启后回引擎找 torrent 的**唯一可靠钥匙** —— `engineId` 每次起边车
///   都可能变（引擎重启会重新分配 id），跟它走必然找不到；
/// * 观看记录那份 `WatchMeta` 的展示字段（title/titleEn/封面/番剧 id）拍平成顶层字段，
///   恢复时直接喂给 `playTorrentFile` 的 `showTitle/coverUrl/mikanBangumiId`。
///
/// 写盘走 core 的 `KeyValueStore`（生产 = Hive，测试 = 内存），键 [defaultKey]；
/// **进度写盘由 `PlaybackController` 节流**（见那里的 `kSnapshotWriteInterval`）：
/// 进度 5 秒一条，没必要每条都落一次盘。
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'infra.dart';

/// 落盘键（`dsanima.` 前缀与 settings / 观看记录一致，便于诊断时一眼认出归属）。
const String kLastPlayingKey = 'dsanima.last_playing';

/// 一次「上次播放」的上下文（可 JSON 序列化）。
@immutable
class LastPlayback {
  const LastPlayback({
    required this.title,
    required this.infoHash,
    required this.fileIndex,
    required this.savedAt,
    this.showTitle,
    this.titleEn,
    this.coverUrl,
    this.coverReferer,
    this.mikanBangumiId,
    this.startPositionMs = 0,
  });

  /// 这一集的展示标题（侧栏行 tooltip / 失败文案用）。
  final String title;

  /// 番名（观看记录那份 `WatchMeta.title`）：恢复时作为 `showTitle` 交给播放链路。
  final String? showTitle;
  final String? titleEn;
  final String? coverUrl;
  final String? coverReferer;
  final String? mikanBangumiId;

  /// 重启后回引擎找 torrent 的钥匙（**必填**：空 hash 的快照没有恢复价值）。
  final String infoHash;

  /// 播的是 torrent 里的第几个文件。
  final int fileIndex;

  /// 上次落盘时看到哪儿（毫秒）；`0` = 从头。
  ///
  /// 与观看记录的 `resumePositionMs` 同口径：**不猜**、不做「太靠前就归零」的阈值。
  final int startPositionMs;

  /// 写入时刻（排序/诊断用；目前没有过期清理 —— 快照只被新播放覆盖或被 `stop()` 清掉）。
  final DateTime savedAt;

  Map<String, Object?> toJson() => <String, Object?>{
    // 版本号：以后字段变了可以按版本兼容，别让旧格式悄悄被当成新格式读。
    'v': 1,
    'title': title,
    'showTitle': showTitle,
    'titleEn': titleEn,
    'coverUrl': coverUrl,
    'coverReferer': coverReferer,
    'mikanBangumiId': mikanBangumiId,
    'infoHash': infoHash,
    'fileIndex': fileIndex,
    'startPositionMs': startPositionMs,
    'savedAt': savedAt.toIso8601String(),
  };

  /// 坏 JSON / 缺关键字段 / 旧格式 → `null`（当没有快照），绝不猜一条半截的。
  static LastPlayback? fromJson(Object? raw) {
    if (raw is! Map) return null;
    String? str(Object? value) {
      final String s = (value ?? '').toString().trim();
      return s.isEmpty ? null : s;
    }

    final String? infoHash = str(raw['infoHash']);
    final String? showTitle = str(raw['showTitle']);
    final String? title = str(raw['title']) ?? showTitle;
    final int? fileIndex = (raw['fileIndex'] as num?)?.toInt();
    final DateTime? savedAt = DateTime.tryParse((raw['savedAt'] ?? '').toString());
    if (infoHash == null ||
        title == null ||
        fileIndex == null ||
        fileIndex < 0 ||
        savedAt == null) {
      return null;
    }
    final int rawPosition = (raw['startPositionMs'] as num?)?.toInt() ?? 0;
    return LastPlayback(
      title: title,
      showTitle: showTitle,
      titleEn: str(raw['titleEn']),
      coverUrl: str(raw['coverUrl']),
      coverReferer: str(raw['coverReferer']),
      mikanBangumiId: str(raw['mikanBangumiId']),
      infoHash: infoHash,
      fileIndex: fileIndex,
      startPositionMs: rawPosition <= 0 ? 0 : rawPosition,
      savedAt: savedAt,
    );
  }

  LastPlayback copyWith({
    String? title,
    String? showTitle,
    String? titleEn,
    String? coverUrl,
    String? coverReferer,
    String? mikanBangumiId,
    int? startPositionMs,
    DateTime? savedAt,
  }) => LastPlayback(
    title: title ?? this.title,
    showTitle: showTitle ?? this.showTitle,
    titleEn: titleEn ?? this.titleEn,
    coverUrl: coverUrl ?? this.coverUrl,
    coverReferer: coverReferer ?? this.coverReferer,
    mikanBangumiId: mikanBangumiId ?? this.mikanBangumiId,
    infoHash: infoHash,
    fileIndex: fileIndex,
    startPositionMs: startPositionMs ?? this.startPositionMs,
    savedAt: savedAt ?? this.savedAt,
  );
}

/// 「上次播放」的持久化（同步读 + 异步写，与 `recentPlayedProvider` 同一套口径）。
///
/// `build()` 是**同步**的：KV 的 `get` 本身就是同步的（Hive `Box.get`），
/// 所以 `PlaybackController` 启动时就能拿到 `restored`，侧栏那行不用等任何异步。
class LastPlaybackController extends Notifier<LastPlayback?> {
  @override
  LastPlayback? build() =>
      LastPlayback.fromJson(ref.watch(keyValueStoreProvider).get(kLastPlayingKey));

  /// 写盘成功后**才**更新内存态：反过来的话，写失败会让界面以为"已经记住了"，
  /// 而进程一退（正是这个功能要解决的场景）又什么都没有。
  Future<void> save(LastPlayback snapshot) async {
    await ref.read(keyValueStoreProvider).put(kLastPlayingKey, snapshot.toJson());
    state = snapshot;
  }

  Future<void> clear() async {
    await ref.read(keyValueStoreProvider).delete(kLastPlayingKey);
    state = null;
  }
}

final NotifierProvider<LastPlaybackController, LastPlayback?>
lastPlaybackProvider =
    NotifierProvider<LastPlaybackController, LastPlayback?>(
      LastPlaybackController.new,
    );
