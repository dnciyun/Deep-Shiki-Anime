/// 本地文件夹状态：记了哪些文件夹、扫出来什么、每条看到哪儿。
///
/// 三份数据、两个存储键：
/// * 文件夹清单 → `dsanima.local.folders`（`List<String>`）；
/// * 每个文件夹的扫描结果 → **不落盘**（进页面扫一遍就够，磁盘才是真相）；
/// * 播放进度 → `dsanima.local.progress`（`{path: {positionMs, durationMs, updatedAt}}`）。
///
/// 为什么进度要单独一份、不并进「观看记录」：`WatchRecord` 的键是
/// 番剧 + 字幕组 + 集数，而且"继续播放"要靠 infoHash 回引擎找种子 —— 本地文件
/// 这两样都没有。硬塞进去只会得到一条点了必失败的记录（见 spec §4）。
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../domain/local_media.dart';
import '../domain/ports.dart' show LocalMediaScannerPort;
import 'infra.dart';
import 'playback.dart';

/// 文件夹清单的存储键。
const String kLocalFoldersKey = 'dsanima.local.folders';

/// 本地播放进度的存储键（键是视频的**真实路径**）。
const String kLocalProgressKey = 'dsanima.local.progress';

/// copyWith 的"没给"哨兵（`null` 是合法值：清空错误要用它）。
const Object _unset = Object();

@immutable
class LocalLibraryState {
  const LocalLibraryState({
    this.loaded = false,
    this.scanning = false,
    this.folders = const <String>[],
    this.results = const <String, LocalScanResult>{},
    this.progress = const <String, LocalProgress>{},
    this.error,
    this.scannedAt,
  });

  /// 是否已经走过一次"进页面自动扫"（只在第一次进页面触发，之后靠刷新按钮）。
  final bool loaded;

  /// 正在扫（页面据此显示进度 / 刷新按钮转圈）。
  final bool scanning;

  /// 用户加的文件夹（顺序 = 添加顺序，页面按这个顺序排）。
  final List<String> folders;

  /// 文件夹 → 扫描结果（失败也在里面，那一行的 [LocalScanResult.error] 有原因）。
  final Map<String, LocalScanResult> results;

  /// 视频真实路径 → 进度。
  final Map<String, LocalProgress> progress;

  /// 全局错误（加文件夹失败等；单个文件夹的失败在 [results] 里）。
  final String? error;

  final DateTime? scannedAt;

  /// 全部视频（按文件夹顺序、再按各文件夹内的排序）。
  List<LocalVideo> get videos => <LocalVideo>[
    for (final String folder in folders) ...?results[folder]?.videos,
  ];

  /// 全部扫描结果（含失败的）。
  List<LocalScanResult> get scanResults => <LocalScanResult>[
    for (final String folder in folders)
      results[folder] ?? LocalScanResult(folder: folder),
  ];

  /// 页面上的分段（按目录；同一文件夹内的子目录各成一段）。
  List<LocalFolderGroup> get groups => localGroupsOf(
    scanResults,
    order: <String, int>{for (int i = 0; i < folders.length; i++) folders[i]: i},
  );

  int get videoCount => scanResults.fold<int>(0, (int sum, LocalScanResult r) => sum + r.videos.length);

  int get totalBytes => scanResults.fold<int>(0, (int sum, LocalScanResult r) => sum + r.totalBytes);

  /// 扫失败的文件夹数（页头据此提示"有 N 个文件夹读不了"）。
  int get failedFolders => scanResults.where((LocalScanResult r) => !r.ok).length;

  bool get truncated => scanResults.any((LocalScanResult r) => r.truncated);

  /// 同一目录下的全部视频（= 播放器的那一份「上一集 / 下一集」）。
  List<LocalVideo> videosInFolder(String folder) => <LocalVideo>[
    for (final LocalScanResult result in scanResults)
      for (final LocalVideo video in result.videos)
        if (video.folder == folder) video,
  ];

  /// 这一段在页面上叫什么（也当场点播时的标题）。
  String showTitleOf(LocalVideo video) {
    for (final LocalFolderGroup group in groups) {
      if (group.folder == video.folder) return group.label;
    }
    return p.basename(video.folder);
  }

  /// 这一条该从哪儿接着播（null = 从头）。
  int? resumeMsOf(String path) => progress[path]?.resumeMs;

  LocalProgress? progressOf(String path) => progress[path];

  LocalVideo? videoByPath(String path) {
    for (final LocalScanResult result in scanResults) {
      for (final LocalVideo video in result.videos) {
        if (video.path == path) return video;
      }
    }
    return null;
  }

  LocalLibraryState copyWith({
    bool? loaded,
    bool? scanning,
    List<String>? folders,
    Map<String, LocalScanResult>? results,
    Map<String, LocalProgress>? progress,
    Object? error = _unset,
    Object? scannedAt = _unset,
  }) => LocalLibraryState(
    loaded: loaded ?? this.loaded,
    scanning: scanning ?? this.scanning,
    folders: folders ?? this.folders,
    results: results ?? this.results,
    progress: progress ?? this.progress,
    error: identical(error, _unset) ? this.error : error as String?,
    scannedAt: identical(scannedAt, _unset) ? this.scannedAt : scannedAt as DateTime?,
  );
}

class LocalLibraryController extends Notifier<LocalLibraryState> {
  @override
  LocalLibraryState build() {
    final store = ref.read(keyValueStoreProvider);
    return LocalLibraryState(
      folders: readLocalFolders(store.get(kLocalFoldersKey)),
      progress: pruneLocalProgress(readLocalProgress(store.get(kLocalProgressKey))),
    );
  }

  /// 进页面时调一次：第一次进来把已记的文件夹扫一遍（之后靠 [refresh]）。
  Future<void> ensureLoaded() async {
    if (state.loaded || state.scanning) return;
    state = state.copyWith(loaded: true);
    if (state.folders.isEmpty) {
      state = state.copyWith(scannedAt: DateTime.now());
      return;
    }
    await refresh();
  }

  /// 重新扫描所有文件夹。
  ///
  /// 单个文件夹失败**不影响**其它文件夹：失败的那一条自己带 [LocalScanResult.error]，
  /// 页面在它那一行显示，其余照常列（用户的下载盘掉线不该让整页变空）。
  Future<void> refresh() async {
    if (state.scanning) return;
    final List<String> folders = state.folders;
    if (folders.isEmpty) {
      state = state.copyWith(scanning: false, results: const <String, LocalScanResult>{}, scannedAt: DateTime.now());
      return;
    }
    state = state.copyWith(scanning: true, error: null);
    final LocalMediaScannerPort scanner = ref.read(localMediaScannerProvider);
    final Map<String, LocalScanResult> next = <String, LocalScanResult>{};
    for (final String folder in folders) {
      try {
        final List<LocalFileStat> files = await scanner.scan(folder);
        next[folder] = LocalScanResult(
          folder: folder,
          videos: localVideosFrom(folder: folder, files: files),
          truncated: files.length >= kLocalScanMaxFiles,
        );
      } catch (error) {
        next[folder] = LocalScanResult(folder: folder, error: _describe(error));
      }
    }
    if (!ref.mounted) return;
    state = state.copyWith(
      scanning: false,
      loaded: true,
      results: next,
      scannedAt: DateTime.now(),
    );
  }

  /// 选一个文件夹加进来。
  ///
  /// 返回加进来的路径（取消/重复 = null）。重复判定**不区分大小写**：
  /// Windows 上 `F:\Anime` 与 `f:\anime` 是同一个目录。
  ///
  /// 系统选择器本身可能不可用（插件没装好 / 远程桌面会话里拿不到对话框）：
  /// 这时把异常抛给页面，由它退回「手动输入路径」（见 [addFolderPath]）——
  /// 用户 2026-10-20 报的就是这条路上的报错（「系统目录选择器未接通」）。
  Future<String?> addFolder() async {
    final String? picked = await ref.read(pickerPortProvider).pickDirectory(title: '选择要加载的文件夹');
    return addFolderPath(picked ?? '');
  }

  /// 直接加一个路径（页面「手动输入路径」那条兜底路 / 将来拖进来也走它）。
  ///
  /// 返回加进来的路径；空串 / 重复返回 null（重复会写一条 `error` 给页面显示）。
  Future<String?> addFolderPath(String path) async {
    final String clean = path.trim();
    if (clean.isEmpty) return null;
    if (state.folders.any((String f) => f.toLowerCase() == clean.toLowerCase())) {
      state = state.copyWith(error: '这个文件夹已经加过了：$clean');
      return null;
    }
    final List<String> next = <String>[...state.folders, clean];
    state = state.copyWith(folders: next, error: null);
    await ref.read(keyValueStoreProvider).put(kLocalFoldersKey, next);
    await refresh();
    return clean;
  }

  /// 移除一个文件夹（**只从列表里移除，磁盘上一个文件都不动**）。
  Future<void> removeFolder(String folder) async {
    final List<String> next = <String>[
      for (final String f in state.folders)
        if (f != folder) f,
    ];
    if (next.length == state.folders.length) return;
    final Map<String, LocalScanResult> results = <String, LocalScanResult>{
      for (final MapEntry<String, LocalScanResult> entry in state.results.entries)
        if (entry.key != folder) entry.key: entry.value,
    };
    // 这一棵树下的进度一起丢掉：不然进度表会为已经不在页面上的文件一直占位。
    final Map<String, LocalProgress> progress = <String, LocalProgress>{
      for (final MapEntry<String, LocalProgress> entry in state.progress.entries)
        if (!_underFolder(entry.key, folder)) entry.key: entry.value,
    };
    state = state.copyWith(folders: next, results: results, progress: progress, error: null);
    final store = ref.read(keyValueStoreProvider);
    await store.put(kLocalFoldersKey, next);
    await store.put(kLocalProgressKey, encodeLocalProgress(progress));
  }

  /// 记一条播放进度（播放窗口每 5 秒回推一次，宿主在这里决定留还是清）。
  Future<void> recordProgress(
    String path, {
    required int positionMs,
    int durationMs = 0,
  }) async {
    final String real = localPathOf(path);
    if (real.isEmpty) return;
    final int? keep = localProgressToKeep(positionMs: positionMs, durationMs: durationMs);
    final Map<String, LocalProgress> next = <String, LocalProgress>{...state.progress};
    if (keep == null) {
      if (next.remove(real) == null) return;
    } else {
      next[real] = LocalProgress(
        positionMs: keep,
        durationMs: durationMs,
        updatedAt: DateTime.now(),
      );
    }
    state = state.copyWith(progress: pruneLocalProgress(next));
    await ref.read(keyValueStoreProvider).put(
      kLocalProgressKey,
      encodeLocalProgress(state.progress),
    );
  }

  /// 忘掉一条进度（行上的「从头开始」）。
  Future<void> forgetProgress(String path) async {
    final String real = localPathOf(path);
    if (!state.progress.containsKey(real)) return;
    final Map<String, LocalProgress> next = <String, LocalProgress>{...state.progress}..remove(real);
    state = state.copyWith(progress: next);
    await ref.read(keyValueStoreProvider).put(kLocalProgressKey, encodeLocalProgress(next));
  }

  /// 播这一条（同目录的其它集一起交给播放器，于是有上一集/下一集）。
  Future<void> play(LocalVideo video) async {
    final List<LocalVideo> siblings = state.videosInFolder(video.folder);
    await ref.read(playbackProvider.notifier).playLocal(
      showTitle: state.showTitleOf(video),
      videos: siblings.isEmpty ? <LocalVideo>[video] : siblings,
      current: video,
      startPositionMs: state.resumeMsOf(video.path),
    );
  }

  static bool _underFolder(String path, String folder) {
    final String a = p.normalize(path).toLowerCase();
    final String b = p.normalize(folder).toLowerCase();
    return a == b || a.startsWith('$b${p.separator}') || a.startsWith('$b/');
  }

  static String _describe(Object error) {
    if (error is LocalScanException) return error.message;
    return '扫描失败：$error';
  }
}

final NotifierProvider<LocalLibraryController, LocalLibraryState> localLibraryProvider =
    NotifierProvider<LocalLibraryController, LocalLibraryState>(LocalLibraryController.new);
