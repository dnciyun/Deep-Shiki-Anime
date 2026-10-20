/// 本地文件：扩展名表、扫描结果的整理、字幕配对、目录分组、进度裁剪。
///
/// 这一层**不碰 IO**（`dart:io` 只在 `state/local_media_scanner.dart` 里）：
/// 扫描器交上来的是 [LocalFileStat]（路径 / 大小 / 修改时间），剩下全是纯函数，
/// 于是"字幕怎么配、集号怎么排、进度什么时候该清"都能在测试里逐条钉住。
///
/// 与引擎那条链路的关系：**没有**。本地文件不在引擎里（没有 infoHash / fileIndex /
/// 串流 URL），所以「本地」页的数据源、播放入口、进度表都与「队列 / 已完成」分开。
/// 唯一复用的是 `episode_group.dart` 的集号解析与归组规则（同目录 + 同指纹 = 同一部）。
library;

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'episode_group.dart' show EpisodeEntry, parseEpisodeNumber;

/// 认的本地视频扩展名（小写，不带点）。
///
/// 取舍：主流容器 + 老番常见格式全都收（`rmvb` / `ts` 这类在国内番剧里很常见），
/// 但**不收** `.iso`（蓝光镜像得先挂载，直接交给 mpv 只会得到黑屏）。
const List<String> kLocalVideoExtensions = <String>[
  'mkv',
  'mp4',
  'm4v',
  'mov',
  'avi',
  'wmv',
  'flv',
  'webm',
  'ts',
  'm2ts',
  'mts',
  'mpg',
  'mpeg',
  'rmvb',
  'rm',
  'asf',
  '3gp',
  'ogv',
  'divx',
];

/// 认的外挂字幕扩展名，**按优先级排序**（同一个视频配到多个时取靠前的）。
const List<String> kLocalSubtitleExtensions = <String>['ass', 'ssa', 'srt', 'vtt'];

/// 一次扫描最多收多少个文件（视频 + 字幕）。
///
/// 为什么要有上限：用户完全可能把 `D:\` 甚至 `C:\` 加进来。没有上限时 UI 要等
/// 几万个 `stat()` 才出第一行，看起来像卡死。到这个数就停，页面上说明"只扫了前
/// N 个"，用户换个更具体的目录就是了。
const int kLocalScanMaxFiles = 20000;

/// 进度表最多留多少条（按 `updatedAt` 丢最旧的）。
///
/// 同 `watch_history.dart` 的条数上限：一份 JSON 越写越大，每次读写都是全量。
/// 500 条对"最近在看哪些本地文件"远远够用。
const int kLocalProgressMaxEntries = 500;

/// 进度记到多小算"刚打开"（毫秒）。低于它不落盘：用户点开看一眼就关，不该留下进度。
const int kLocalProgressMinMs = 5000;

/// 看到多少算看完（与 `watch_history.dart` 的 `kWatchFinishedRatio` 同一口径）。
///
/// 看完就把进度清掉：下次点它是"重看"，而不是从片尾前 5 分钟开始。
const double kLocalFinishedRatio = 0.9;

/// 扫描失败（页面把它显示在那一行上，不是全局错误）。
class LocalScanException implements Exception {
  const LocalScanException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 扫描器交上来的一条原始文件（视频或字幕）。
@immutable
class LocalFileStat {
  const LocalFileStat({
    required this.path,
    this.sizeBytes = 0,
    this.modifiedAt,
  });

  /// 绝对路径（Windows 反斜杠形态，来自 `dart:io`）。
  final String path;
  final int sizeBytes;
  final DateTime? modifiedAt;

  @override
  String toString() => 'LocalFileStat($path, $sizeBytes)';
}

/// 本地页上的一条视频。
@immutable
class LocalVideo {
  const LocalVideo({
    required this.path,
    required this.folder,
    required this.title,
    this.episode,
    this.sizeBytes = 0,
    this.modifiedAt,
    this.subtitlePath,
  });

  /// 绝对路径。
  final String path;

  /// 所在目录（绝对路径）。归组 / 页面分段都用它。
  final String folder;

  /// 展示标题（文件名去掉扩展名，原样保留）。
  final String title;

  /// 从文件名解析出的集号（null = 没解析出来，不编）。
  final int? episode;

  final int sizeBytes;
  final DateTime? modifiedAt;

  /// 同目录同名字幕的绝对路径（null = 没有）。
  final String? subtitlePath;

  /// 稳定 id（= 路径）。UI 的 key 与进度表都用它。
  String get id => path;

  @override
  bool operator ==(Object other) =>
      other is LocalVideo && other.path == path && other.subtitlePath == subtitlePath;

  @override
  int get hashCode => Object.hash(path, subtitlePath);

  @override
  String toString() => 'LocalVideo($path, ep: $episode)';
}

/// 一个文件夹的扫描结果（成功或失败都在这一个对象里）。
@immutable
class LocalScanResult {
  const LocalScanResult({
    required this.folder,
    this.videos = const <LocalVideo>[],
    this.error,
    this.truncated = false,
  });

  /// 用户加成"文件夹"的那一层（绝对路径）。
  final String folder;

  /// 递归扫到、整理好的视频（整个子树，已排序）。
  final List<LocalVideo> videos;

  /// 这个文件夹扫失败的原因（null = 成功）。
  final String? error;

  /// 是否撞上了 [kLocalScanMaxFiles]。
  final bool truncated;

  int get totalBytes => videos.fold<int>(0, (int sum, LocalVideo v) => sum + v.sizeBytes);

  bool get ok => error == null;
}

/// 页面上的一段：一个目录（= 一部 / 一季）里的视频。
@immutable
class LocalFolderGroup {
  const LocalFolderGroup({
    required this.folder,
    required this.label,
    required this.rootFolder,
    required this.videos,
  });

  /// 目录绝对路径（= `LocalVideo.folder`）。
  final String folder;

  /// 显示名：相对用户选的那个根目录的路径（根目录本身用它的目录名）。
  final String label;

  /// 这一段的视频来自哪个"文件夹"（用来显示/删除时定位是哪一行）。
  final String rootFolder;

  final List<LocalVideo> videos;

  int get totalBytes => videos.fold<int>(0, (int sum, LocalVideo v) => sum + v.sizeBytes);
}

/// 是不是本地视频（按扩展名判，大小写不敏感）。
bool isLocalVideoPath(String path) {
  final String ext = p.extension(path).toLowerCase();
  if (ext.length < 2) return false;
  return kLocalVideoExtensions.contains(ext.substring(1));
}

/// 是不是外挂字幕。
bool isLocalSubtitlePath(String path) {
  final String ext = p.extension(path).toLowerCase();
  if (ext.length < 2) return false;
  return kLocalSubtitleExtensions.contains(ext.substring(1));
}

/// 把一次扫描的原始文件整理成视频清单（按集号/标题排序，附同名字幕）。
///
/// [folder] 是这个文件夹的根（只用来记录来源，归类靠每个文件自己的目录）。
List<LocalVideo> localVideosFrom({
  required String folder,
  required Iterable<LocalFileStat> files,
}) {
  final Map<String, List<LocalFileStat>> subsByDir = <String, List<LocalFileStat>>{};
  final List<LocalFileStat> videos = <LocalFileStat>[];
  for (final LocalFileStat stat in files) {
    if (isLocalSubtitlePath(stat.path)) {
      subsByDir.putIfAbsent(p.dirname(stat.path), () => <LocalFileStat>[]).add(stat);
      continue;
    }
    if (isLocalVideoPath(stat.path)) videos.add(stat);
  }

  final List<LocalVideo> out = <LocalVideo>[];
  for (final LocalFileStat stat in videos) {
    final String dir = p.dirname(stat.path);
    final String stem = p.basenameWithoutExtension(stat.path);
    out.add(
      LocalVideo(
        path: stat.path,
        folder: dir,
        title: stem,
        episode: parseEpisodeNumber(stat.path),
        sizeBytes: stat.sizeBytes,
        modifiedAt: stat.modifiedAt,
        subtitlePath: _bestSubtitle(subsByDir[dir] ?? const <LocalFileStat>[], stem),
      ),
    );
  }
  out.sort(compareLocalVideos);
  return out;
}

/// 视频排序：先集号（认不出的排在有集号的后面），再按标题（不区分大小写）。
int compareLocalVideos(LocalVideo a, LocalVideo b) {
  final int byEp = (a.episode ?? 1 << 30).compareTo(b.episode ?? 1 << 30);
  if (byEp != 0) return byEp;
  return a.title.toLowerCase().compareTo(b.title.toLowerCase());
}

/// 配字幕：同目录里以 [stem] 为名的字幕，优先级 = 扩展名顺序，其次文件名更短的先。
///
/// 认三种命名：
/// * 完全同名：`Show - 01.ass`
/// * 加语言段：`Show - 01.zh.ass` / `Show - 01.sc.srt`
/// * 加更多段：`Show - 01.zh-Hans.ass`
///
/// 不认"目录里只有一个字幕就硬挂"：番剧目录里常有 OP/ED 字幕，硬挂会比不挂更糟。
String? _bestSubtitle(List<LocalFileStat> subs, String stem) {
  String? best;
  int bestRank = 1 << 30;
  for (final LocalFileStat sub in subs) {
    final String subStem = p.basenameWithoutExtension(sub.path);
    if (subStem != stem && !subStem.startsWith('$stem.')) continue;
    final String ext = p.extension(sub.path).toLowerCase().substring(1);
    final int rank = kLocalSubtitleExtensions.indexOf(ext);
    if (rank < 0) continue;
    // 完全同名的永远优先于带语言段的（后者只是"就近挑一个"）。
    final int score = (subStem == stem ? 0 : 100) + rank;
    if (score < bestRank) {
      bestRank = score;
      best = sub.path;
    }
  }
  return best;
}

/// 多个文件夹的扫描结果 → 页面上的分段（按目录；根目录排最前，其余按路径）。
List<LocalFolderGroup> localGroupsOf(
  Iterable<LocalScanResult> results, {
  Map<String, int> order = const <String, int>{},
}) {
  final List<({int rootOrder, String rootFolder, String folder, List<LocalVideo> videos})> raw =
      <({int rootOrder, String rootFolder, String folder, List<LocalVideo> videos})>[];
  for (final LocalScanResult result in results) {
    final Map<String, List<LocalVideo>> byDir = <String, List<LocalVideo>>{};
    for (final LocalVideo video in result.videos) {
      byDir.putIfAbsent(video.folder, () => <LocalVideo>[]).add(video);
    }
    for (final MapEntry<String, List<LocalVideo>> entry in byDir.entries) {
      final List<LocalVideo> list = List<LocalVideo>.of(entry.value)..sort(compareLocalVideos);
      raw.add((
        rootOrder: order[result.folder] ?? 1 << 30,
        rootFolder: result.folder,
        folder: entry.key,
        videos: list,
      ));
    }
  }
  raw.sort((a, b) {
    final int byRoot = a.rootOrder.compareTo(b.rootOrder);
    if (byRoot != 0) return byRoot;
    return a.folder.toLowerCase().compareTo(b.folder.toLowerCase());
  });
  return <LocalFolderGroup>[
    for (final item in raw)
      LocalFolderGroup(
        folder: item.folder,
        label: localFolderLabel(item.folder, item.rootFolder),
        rootFolder: item.rootFolder,
        videos: item.videos,
      ),
  ];
}

/// 分段标题：相对根目录的路径（根目录本身 → 目录名）。
String localFolderLabel(String folder, String rootFolder) {
  String rel = p.relative(folder, from: rootFolder);
  if (rel == '.' || rel.isEmpty) rel = p.basename(folder);
  if (rel.isEmpty) rel = folder;
  return rel;
}

/// 一条视频 → 归组用的 [EpisodeEntry]（宿主侧先按真实路径归组）。
///
/// 这里 path 用**真实路径**（不是 `file:` URI）：`groupEpisodes` 靠目录 + 文件名
/// 指纹分组的规则是按真实路径写的，URI 形态会把百分号编码带进指纹。
List<EpisodeEntry> localEpisodeEntries(Iterable<LocalVideo> videos) => <EpisodeEntry>[
  for (final LocalVideo video in videos)
    EpisodeEntry(
      title: video.title,
      path: video.path,
      episode: video.episode,
      subtitlePath: video.subtitlePath,
    ),
];

/// 播放器里那一项用的 URI 文本（`file:` 形态）。
///
/// 为什么不直接给 Windows 路径：`PlayerRequest.streamUrl` 是 `Uri`，而
/// `Uri.parse(r'F:\a\b.mkv')` 会解析成 scheme=`f` 的垃圾（实测）。
/// `Uri.file()` 交给 media_kit 后由它的 `normalizeURI()` 还原成真实路径。
String localFileUriText(String path) => Uri.file(path).toString();

/// 播放器报上来的路径 → 本地真实路径（不是本地路径就返回空串）。
///
/// 播放窗口回推的是**在放的那一项的 uri 文本**（本地就是 `file:` URI），
/// 进度表要按真实路径记账，所以两边都要经过这个函数。
String localPathOf(String pathOrUri) {
  final String raw = pathOrUri.trim();
  if (raw.isEmpty) return '';
  final String lower = raw.toLowerCase();
  if (lower.startsWith('http://') || lower.startsWith('https://')) return '';
  if (lower.startsWith('file:')) {
    try {
      return Uri.parse(raw).toFilePath();
    } catch (_) {
      return '';
    }
  }
  return raw;
}

/// 这一条进度该不该留（null = 清掉）。
///
/// 规则：刚打开（< [kLocalProgressMinMs]）不记；看到 [kLocalFinishedRatio] 以上
/// 算看完（清掉，下次从头）；其余原样留着。
int? localProgressToKeep({required int positionMs, required int durationMs}) {
  if (positionMs < kLocalProgressMinMs) return null;
  if (durationMs > 0 && positionMs >= durationMs * kLocalFinishedRatio) return null;
  return positionMs;
}

/// 一条本地播放进度。
@immutable
class LocalProgress {
  const LocalProgress({
    required this.positionMs,
    this.durationMs = 0,
    this.updatedAt,
  });

  final int positionMs;
  final int durationMs;
  final DateTime? updatedAt;

  /// 还能接着播的位置（null = 从头开始）。
  int? get resumeMs => positionMs >= kLocalProgressMinMs ? positionMs : null;

  Map<String, Object?> toJson() => <String, Object?>{
    'positionMs': positionMs,
    if (durationMs > 0) 'durationMs': durationMs,
    if (updatedAt != null) 'updatedAt': updatedAt!.toIso8601String(),
  };
}

/// 读文件夹清单（盘上脏数据 → 空表，绝不因为一条坏记录把页面打崩）。
List<String> readLocalFolders(Object? raw) {
  if (raw is! List) return const <String>[];
  final List<String> out = <String>[];
  for (final Object? item in raw) {
    if (item is! String) continue;
    final String path = item.trim();
    if (path.isEmpty) continue;
    if (out.contains(path)) continue;
    out.add(path);
  }
  return out;
}

/// 读进度表（同上：脏一条丢一条）。
Map<String, LocalProgress> readLocalProgress(Object? raw) {
  if (raw is! Map) return const <String, LocalProgress>{};
  final Map<String, LocalProgress> out = <String, LocalProgress>{};
  raw.forEach((Object? key, Object? value) {
    if (key is! String || key.trim().isEmpty) return;
    if (value is! Map) return;
    final Object? pos = value['positionMs'];
    if (pos is! num) return;
    final Object? dur = value['durationMs'];
    final Object? at = value['updatedAt'];
    out[key] = LocalProgress(
      positionMs: pos.toInt(),
      durationMs: dur is num ? dur.toInt() : 0,
      updatedAt: at is String ? DateTime.tryParse(at) : null,
    );
  });
  return out;
}

/// 写进 KV 的形态（`LocalProgress` → JSON map）。
Map<String, Object?> encodeLocalProgress(Map<String, LocalProgress> progress) =>
    <String, Object?>{
      for (final MapEntry<String, LocalProgress> entry in progress.entries)
        entry.key: entry.value.toJson(),
    };

/// 修剪进度表：丢掉"刚打开"的与"已看完"的，再按最近更新时间截到上限。
Map<String, LocalProgress> pruneLocalProgress(Map<String, LocalProgress> progress) {
  final List<MapEntry<String, LocalProgress>> kept = <MapEntry<String, LocalProgress>>[];
  for (final MapEntry<String, LocalProgress> entry in progress.entries) {
    final int? keep = localProgressToKeep(
      positionMs: entry.value.positionMs,
      durationMs: entry.value.durationMs,
    );
    if (keep == null) continue;
    kept.add(entry);
  }
  kept.sort((a, b) {
    final DateTime? ta = a.value.updatedAt;
    final DateTime? tb = b.value.updatedAt;
    if (ta == null && tb == null) return 0;
    if (ta == null) return 1;
    if (tb == null) return -1;
    return tb.compareTo(ta);
  });
  final Map<String, LocalProgress> out = <String, LocalProgress>{};
  for (final MapEntry<String, LocalProgress> entry in kept.take(kLocalProgressMaxEntries)) {
    out[entry.key] = entry.value;
  }
  return out;
}
