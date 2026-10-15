/// 引擎边车的数据模型与异常类型（spec §3.6 / §4.1）。
///
/// 字段名与边车 JSON 逐条对应，**不得自行改名**。
/// 所有 `fromJson` 都是容错的：缺字段用默认值，类型不符用默认值，
/// 未知 `state` 归 [EngineTorrentState.error]（`EngineTorrent.rawState` 保留原始字面量）。
library;

import 'json_tools.dart';

/// 边车给出的 torrent 状态（spec §3.6：`initializing|live|paused|error`）。
enum EngineTorrentState {
  /// 正在找元数据 / 初始化。
  initializing('initializing'),

  /// 正在下载或做种。
  live('live'),

  /// 已暂停。
  paused('paused'),

  /// 出错（也是「无法识别的 state 字面量」的归口）。
  error('error');

  const EngineTorrentState(this.wireName);

  /// 与边车 JSON 中 `state` 字段一致的字面量。
  final String wireName;

  /// 解析 `state` 字段。
  ///
  /// * 缺失 / 空字符串 → [EngineTorrentState.initializing]（刚提交、还没上报状态）
  /// * 未知字面量 → [EngineTorrentState.error]（**不抛异常、不崩**）
  static EngineTorrentState parse(Object? raw) {
    if (raw is! String) return EngineTorrentState.initializing;
    final value = raw.trim();
    if (value.isEmpty) return EngineTorrentState.initializing;
    for (final state in EngineTorrentState.values) {
      if (state.wireName == value) return state;
    }
    return EngineTorrentState.error;
  }
}

/// 视频扩展名（spec §3.6 的 `isVideo` 判据）。
const Set<String> kVideoExtensions = <String>{
  'mkv',
  'mp4',
  'webm',
  'avi',
  'mov',
  'ts',
  'm2ts',
  'flv',
  'wmv',
};

/// 外挂字幕扩展名（spec §4.1 的 `downloadedSubtitleFiles`）。
const Set<String> kSubtitleExtensions = <String>{'ass', 'srt', 'sub', 'ssa'};

/// 从 torrent 内相对路径取出的小写扩展名（无扩展名 → 空字符串）。
String pathExtension(String path) {
  final base = path.split(RegExp(r'[\\/]')).last;
  final dot = base.lastIndexOf('.');
  if (dot <= 0 || dot == base.length - 1) return '';
  return base.substring(dot + 1).toLowerCase();
}

/// 从 torrent 内相对路径取出目录部分（正斜杠归一化，无目录 → 空字符串）。
String pathDirectory(String path) {
  final normalized = path.replaceAll('\\', '/');
  final slash = normalized.lastIndexOf('/');
  if (slash < 0) return '';
  return normalized.substring(0, slash);
}

/// `TorrentView.files[]` 的一项（spec §3.6）。
class EngineFile {
  const EngineFile({
    required this.index,
    required this.path,
    required this.length,
    required this.downloaded,
    required this.progress,
    required this.included,
    required this.mime,
    required this.isVideo,
    required this.complete,
  });

  /// 容错解析：缺字段用默认值；`complete` 缺省时按 `downloaded >= length` 推导。
  factory EngineFile.fromJson(Map<String, dynamic> json) {
    final path = jsonString(json['path']) ?? '';
    final length = jsonInt(json['length']);
    final downloaded = jsonInt(json['downloaded']);
    final mime = jsonString(json['mime']);
    final extension = pathExtension(path);
    final isVideoRaw = json['isVideo'];
    final isVideo = isVideoRaw == null
        ? (mime?.startsWith('video/') ?? false) ||
              kVideoExtensions.contains(extension)
        : jsonBool(isVideoRaw);
    final completeRaw = json['complete'];
    final progressRaw = json['progress'];
    return EngineFile(
      index: jsonInt(json['index']),
      path: path,
      length: length,
      downloaded: downloaded,
      progress: progressRaw == null
          ? (length > 0 ? downloaded / length : 0.0)
          : jsonDouble(progressRaw),
      included: json['included'] == null ? true : jsonBool(json['included']),
      mime: mime,
      isVideo: isVideo,
      complete: completeRaw == null
          ? (length > 0 && downloaded >= length)
          : jsonBool(completeRaw),
    );
  }

  /// torrent 内原始文件索引（回传给 `/stream` 必须原样使用）。
  final int index;

  /// torrent 内相对路径。
  final String path;

  /// 文件总字节数。
  final int length;

  /// 已下载字节数。
  final int downloaded;

  /// 0.0–1.0 下载进度。
  final double progress;

  /// 是否被 `onlyFiles` 选中（未选中的文件不会下载）。
  final bool included;

  /// 边车给出的 MIME（可能缺省）。
  final String? mime;

  /// 是否视频（边车判定；缺省时按 mime + 扩展名推导）。
  final bool isVideo;

  /// 是否已下完（边车判定；缺省时按 `downloaded >= length` 推导）。
  final bool complete;

  /// 小写扩展名（无扩展名 → 空字符串）。
  String get extension => pathExtension(path);

  /// 所在目录（正斜杠归一化）。
  String get directory => pathDirectory(path);

  /// 是否是外挂字幕文件。
  bool get isSubtitle => kSubtitleExtensions.contains(extension);

  /// 文件展示名（去掉目录）。
  String get fileName => path.split(RegExp(r'[\\/]')).last;

  EngineFile copyWith({
    int? index,
    String? path,
    int? length,
    int? downloaded,
    double? progress,
    bool? included,
    String? mime,
    bool? isVideo,
    bool? complete,
  }) {
    return EngineFile(
      index: index ?? this.index,
      path: path ?? this.path,
      length: length ?? this.length,
      downloaded: downloaded ?? this.downloaded,
      progress: progress ?? this.progress,
      included: included ?? this.included,
      mime: mime ?? this.mime,
      isVideo: isVideo ?? this.isVideo,
      complete: complete ?? this.complete,
    );
  }

  @override
  String toString() =>
      'EngineFile(index: $index, path: $path, length: $length, '
      'downloaded: $downloaded, complete: $complete, isVideo: $isVideo)';
}

/// `progress` SSE 事件里附带的最小文件进度（spec §3.9）。
///
/// 与 [EngineFile] 的区别：不携带 path/mime 等静态信息，只有变化量。
class EngineFileProgress {
  const EngineFileProgress({
    required this.index,
    required this.downloaded,
    required this.complete,
    required this.progress,
  });

  factory EngineFileProgress.fromJson(Map<String, dynamic> json) {
    return EngineFileProgress(
      index: jsonInt(json['index']),
      downloaded: jsonInt(json['downloaded']),
      complete: jsonBool(json['complete']),
      progress: jsonDouble(json['progress']),
    );
  }

  /// torrent 内原始文件索引。
  final int index;

  /// 已下载字节数。
  final int downloaded;

  /// 是否已下完。
  final bool complete;

  /// 0.0–1.0 下载进度。
  final double progress;

  @override
  String toString() =>
      'EngineFileProgress(index: $index, downloaded: $downloaded, complete: $complete)';
}

/// `TorrentView`（spec §3.6）。
class EngineTorrent {
  const EngineTorrent({
    required this.id,
    required this.infoHash,
    required this.name,
    required this.state,
    this.rawState,
    this.error,
    required this.totalBytes,
    required this.progressBytes,
    required this.uploadedBytes,
    required this.downloadBps,
    required this.uploadBps,
    required this.peers,
    required this.progress,
    required this.finished,
    this.outputFolder,
    required this.files,
  });

  /// 容错解析 `TorrentView` **或** `POST /torrents` 的部分响应
  /// （后者只有 `id/infoHash/name/files`，其余字段走默认值）。
  factory EngineTorrent.fromJson(Map<String, dynamic> json) {
    final files = <EngineFile>[];
    for (final raw in jsonList(json['files'])) {
      final map = jsonMap(raw);
      if (map != null) files.add(EngineFile.fromJson(map));
    }
    final rawState = jsonString(json['state']);
    return EngineTorrent(
      id: jsonInt(json['id']),
      infoHash: jsonString(json['infoHash']) ?? '',
      name: jsonString(json['name']) ?? '',
      state: EngineTorrentState.parse(json['state']),
      rawState: rawState,
      error: jsonString(json['error']),
      totalBytes: jsonInt(json['totalBytes']),
      progressBytes: jsonInt(json['progressBytes']),
      uploadedBytes: jsonInt(json['uploadedBytes']),
      downloadBps: jsonDouble(json['downloadBps']),
      uploadBps: jsonDouble(json['uploadBps']),
      peers: jsonInt(json['peers']),
      progress: jsonDouble(json['progress']),
      finished: jsonBool(json['finished']),
      outputFolder: jsonString(json['outputFolder']),
      files: List<EngineFile>.unmodifiable(files),
    );
  }

  /// 引擎分配的整数 id（回传所有端点用）。
  final int id;

  /// 40 位 info hash（小写十六进制）。
  final String infoHash;

  /// 展示名。
  final String name;

  /// 归一化状态；未知字面量归 [EngineTorrentState.error]。
  final EngineTorrentState state;

  /// 原始 `state` 字面量（便于诊断未知状态）。
  final String? rawState;

  /// 出错原因（`state == error` 时有意义）。
  final String? error;

  /// 总字节数。
  final int totalBytes;

  /// 已下载字节数。
  final int progressBytes;

  /// 已上传字节数。
  final int uploadedBytes;

  /// 当前下载速度（bytes/s）。
  final double downloadBps;

  /// 当前上传速度（bytes/s）。
  final double uploadBps;

  /// 已连接 peer 数。
  final int peers;

  /// 0.0–1.0 总进度。
  final double progress;

  /// 是否已完成（下载完毕）。
  final bool finished;

  /// 落盘目录（`downloadDir/subFolder`）。
  final String? outputFolder;

  /// 文件列表（`POST /torrents` 的响应不含 `downloaded/complete`）。
  final List<EngineFile> files;

  /// 交给 mpv 的主视频文件。
  ///
  /// 规则（spec §4.1）：在 `isVideo == true` 的文件里取体积最大者；
  /// 没有标记为视频的文件时返回 `null`（不猜、不假装）。
  EngineFile? get playableFile {
    EngineFile? best;
    for (final file in files) {
      if (!file.isVideo) continue;
      if (best == null || file.length > best.length) best = file;
    }
    return best;
  }

  /// 外挂字幕候选：与主视频同目录的 `.ass/.srt/.sub/.ssa`（spec §4.1）。
  ///
  /// 找不到主视频时退化为「所有字幕文件」。
  List<EngineFile> get downloadedSubtitleFiles {
    final main = playableFile;
    final subtitles = files.where((file) => file.isSubtitle);
    if (main == null) return List<EngineFile>.unmodifiable(subtitles);
    final directory = main.directory;
    return List<EngineFile>.unmodifiable(
      subtitles.where((file) => file.directory == directory),
    );
  }

  /// [downloadedSubtitleFiles] 的别名（task-3 用词）。
  List<EngineFile> get subtitleFiles => downloadedSubtitleFiles;

  /// 是否所有被选中的文件都已下完。
  bool get allIncludedComplete =>
      files.where((file) => file.included).every((file) => file.complete);

  /// 把 `progress` SSE 事件合并进本地快照（供 UI 少打 `/torrents/{id}`）。
  ///
  /// 只更新事件里出现的文件索引；未在本地文件列表里的索引会被忽略
  /// （本地视图可能是 `POST /torrents` 的部分响应，缺 path 无法补全）。
  EngineTorrent applyProgress(EngineProgress event) {
    if (event.id != id) return this;
    final mergedTotal = event.totalBytes > 0 ? event.totalBytes : totalBytes;
    final byIndex = <int, EngineFileProgress>{
      for (final file in event.files) file.index: file,
    };
    final merged = <EngineFile>[];
    for (final file in files) {
      final update = byIndex[file.index];
      merged.add(
        update == null
            ? file
            : file.copyWith(
                downloaded: update.downloaded,
                complete: update.complete,
                progress: update.progress,
              ),
      );
    }
    return EngineTorrent(
      id: id,
      infoHash: infoHash,
      name: name,
      state: state,
      rawState: rawState,
      error: error,
      totalBytes: mergedTotal,
      progressBytes: event.progressBytes,
      uploadedBytes: uploadedBytes,
      downloadBps: event.downloadBps,
      uploadBps: event.uploadBps,
      peers: event.peers,
      // progress 事件不带总进度字段（spec §3.9），按字节数换算。
      progress: mergedTotal > 0 ? event.progressBytes / mergedTotal : progress,
      finished: event.finished,
      outputFolder: outputFolder,
      files: List<EngineFile>.unmodifiable(merged),
    );
  }

  @override
  String toString() =>
      'EngineTorrent(id: $id, name: $name, state: ${state.wireName}, '
      'progress: $progressBytes/$totalBytes, files: ${files.length})';
}

/// `POST /torrents` 的结果（spec §3.5 最终契约，三种形态）。
///
/// **注意：202 / 504 都不是失败**——引擎仍在后台解析元数据，
/// 成功后还会从 SSE 补发一次 `torrent_added`。所以调用方拿到
/// [EngineAddResolving] / [EngineAddTimedOut] 时应该：
///
/// 1. 记下 [infoHash]（这是后续关联引擎实例的唯一钥匙）；
/// 2. UI 显示「解析中」加载态；
/// 3. 用 `EngineClient.addedFrom(events())` 等 `torrent_added`，
///    或 `EngineClient.torrentByInfoHash()` / `waitForTorrent()` 查询；
/// 4. 拿到 `EngineTorrent.id` 之后才能 `streamUrl()`。
///
/// 变体与 spec 的对应：`200` → [EngineAddReady]、`202` → [EngineAddResolving]、
/// `504 metadata_timeout` → [EngineAddTimedOut]。
///
/// **边车现状**（engine-dev 实测确认）：in-flight 去重之后**不会发 202**——
/// 同一 infoHash 重复提交会等同一个结果，返回与首个请求相同的 200/504 形状。
/// [EngineAddResolving] 作为 spec §3.5 的前向兼容分支保留（收到也能正确处理）。
sealed class EngineAddResult {
  const EngineAddResult();

  /// 已知的 info hash（三种形态都可能带；缺失时为 `null`）。
  String? get infoHash;

  /// 元数据是否已就绪（只有就绪才能拿 id 播放）。
  bool get isReady;

  /// 就绪时的 torrent（未就绪为 `null`）。
  EngineTorrent? get torrent;

  /// 引擎侧阶段（`metadata` / `initializing`），仅 202/504 有。
  String? get phase;

  /// 引擎侧整数 id（若已知）。
  ///
  /// * [EngineAddReady]：就是 `torrent.id`；
  /// * [EngineAddTimedOut]：`phase == 'initializing'` 时边车会带上 `id`，
  ///   此时可以先用 `EngineClient.get(id)` 轮询，等 `state` 变 `live` 再播放；
  /// * 其余为 `null`（还没注册进 session）。
  int? get engineId;
}

/// `200`：元数据就绪，`torrent.id` 可直接用于 `streamUrl`。
final class EngineAddReady extends EngineAddResult {
  const EngineAddReady(this.torrent);

  /// 已注册进引擎的 torrent；同时实现基类的 [EngineAddResult.torrent]。
  @override
  final EngineTorrent torrent;

  @override
  String? get infoHash => torrent.infoHash.isEmpty ? null : torrent.infoHash;

  @override
  bool get isReady => true;

  @override
  String? get phase => null;

  @override
  int? get engineId => torrent.id > 0 ? torrent.id : null;

  @override
  String toString() => 'EngineAddReady($torrent)';
}

/// `202`：引擎已在后台解析元数据（**还没有 id，不能播放**）。
///
/// 也可能是「同一 infoHash 重复提交命中 in-flight 表」：引擎复用了同一个后台任务。
/// 注：当前边车不会发 202（见 [EngineAddResult] 的说明），此分支为前向兼容保留。
final class EngineAddResolving extends EngineAddResult {
  const EngineAddResolving({this.infoHash, this.phase});

  @override
  final String? infoHash;

  @override
  final String? phase;

  @override
  bool get isReady => false;

  @override
  EngineTorrent? get torrent => null;

  @override
  int? get engineId => null;

  @override
  String toString() => 'EngineAddResolving(infoHash: $infoHash, phase: $phase)';
}

/// `504 metadata_timeout`：超时了，但**任务仍在后台找元数据**。
///
/// `phase == 'initializing'` 时边车会带上 [id]（元数据已到手、session 还没就绪），
/// 此时可以先 `EngineClient.get(id)` 轮询；`phase == 'metadata'` 时只有
/// [infoHash]，要等 SSE `torrent_added`。
final class EngineAddTimedOut extends EngineAddResult {
  const EngineAddTimedOut({
    this.infoHash,
    this.phase,
    this.id,
    this.metadataTimeoutMs,
  });

  @override
  final String? infoHash;

  @override
  final String? phase;

  /// `phase == 'initializing'` 时边车给出的整数 id（否则 `null`）。
  final int? id;

  /// 引擎本次使用的元数据超时（毫秒）。
  final int? metadataTimeoutMs;

  @override
  bool get isReady => false;

  @override
  EngineTorrent? get torrent => null;

  @override
  int? get engineId => id;

  @override
  String toString() =>
      'EngineAddTimedOut(infoHash: $infoHash, phase: $phase, id: $id, '
      'metadataTimeoutMs: $metadataTimeoutMs)';
}

/// `GET /health` 响应（spec §3.4）。
class EngineHealth {
  const EngineHealth({required this.ok, this.version, this.sessions = 0});

  /// 容错解析：`ok` 缺省视为 `true`（HTTP 200 本身就是可用信号）。
  factory EngineHealth.fromJson(Map<String, dynamic> json) {
    return EngineHealth(
      ok: json['ok'] == null ? true : jsonBool(json['ok']),
      version: jsonString(json['version']),
      sessions: jsonInt(json['sessions']),
    );
  }

  /// 是否健康。
  final bool ok;

  /// 边车版本号。
  final String? version;

  /// 当前会话数。
  final int sessions;

  @override
  String toString() =>
      'EngineHealth(ok: $ok, version: $version, sessions: $sessions)';
}

/// `GET /events` 的事件基类。
///
/// sealed 变体与 spec §4.1 的对应关系：
/// `Snapshot` → [EngineSnapshot]、`Added` → [EngineTorrentAdded]、
/// `Progress` → [EngineProgress]、`StateChanged` → [EngineStateChanged]、
/// `Removed` → [EngineTorrentRemoved]、`Heartbeat` → [EngineHeartbeat]。
sealed class EngineEvent {
  const EngineEvent();

  /// 事件名（与 SSE `event:` 字段一致）。
  String get name;
}

/// `snapshot`：连接建立后的全量快照。
final class EngineSnapshot extends EngineEvent {
  const EngineSnapshot(this.torrents);

  /// 当前全部 torrent。
  final List<EngineTorrent> torrents;

  @override
  String get name => 'snapshot';

  @override
  String toString() => 'EngineSnapshot(${torrents.length} torrents)';
}

/// `torrent_added`：新 torrent（含一次性 infoHash）。
final class EngineTorrentAdded extends EngineEvent {
  const EngineTorrentAdded(this.torrent);

  /// 新增的 torrent。
  final EngineTorrent torrent;

  @override
  String get name => 'torrent_added';

  @override
  String toString() => 'EngineTorrentAdded($torrent)';
}

/// `progress`：进度增量。
final class EngineProgress extends EngineEvent {
  const EngineProgress({
    required this.id,
    required this.progressBytes,
    required this.totalBytes,
    required this.downloadBps,
    required this.uploadBps,
    required this.peers,
    required this.finished,
    required this.files,
    required this.completedFiles,
  });

  factory EngineProgress.fromJson(Map<String, dynamic> json) {
    final files = <EngineFileProgress>[];
    for (final raw in jsonList(json['files'])) {
      final map = jsonMap(raw);
      if (map != null) files.add(EngineFileProgress.fromJson(map));
    }
    final completed = <int>{};
    for (final raw in jsonList(json['completedFiles'])) {
      if (raw is num || raw is String) completed.add(jsonInt(raw));
    }
    return EngineProgress(
      id: jsonInt(json['id']),
      progressBytes: jsonInt(json['progressBytes']),
      totalBytes: jsonInt(json['totalBytes']),
      downloadBps: jsonDouble(json['downloadBps']),
      uploadBps: jsonDouble(json['uploadBps']),
      peers: jsonInt(json['peers']),
      finished: jsonBool(json['finished']),
      files: List<EngineFileProgress>.unmodifiable(files),
      completedFiles: Set<int>.unmodifiable(completed),
    );
  }

  /// torrent id。
  final int id;

  /// 已下载字节数。
  final int progressBytes;

  /// 总字节数。
  final int totalBytes;

  /// 当前下载速度（bytes/s）。
  final double downloadBps;

  /// 当前上传速度（bytes/s）。
  final double uploadBps;

  /// 已连接 peer 数。
  final int peers;

  /// 是否已完成。
  final bool finished;

  /// 文件级进度增量。
  final List<EngineFileProgress> files;

  /// 已下完的文件索引集合。
  ///
  /// **这是「本集下完 → 预取下一集」的唯一判据**（spec §3.9 / §4.3），
  /// 不要靠轮询猜测。事件里该数组非空时必须被消费。
  final Set<int> completedFiles;

  @override
  String get name => 'progress';

  @override
  String toString() =>
      'EngineProgress(id: $id, bytes: $progressBytes/$totalBytes, '
      'completedFiles: $completedFiles)';
}

/// `state`：状态迁移。
final class EngineStateChanged extends EngineEvent {
  const EngineStateChanged({
    required this.id,
    required this.state,
    this.error,
    this.rawState,
  });

  factory EngineStateChanged.fromJson(Map<String, dynamic> json) {
    return EngineStateChanged(
      id: jsonInt(json['id']),
      state: EngineTorrentState.parse(json['state']),
      error: jsonString(json['error']),
      rawState: jsonString(json['state']),
    );
  }

  /// torrent id。
  final int id;

  /// 归一化状态（未知字面量 → [EngineTorrentState.error]）。
  final EngineTorrentState state;

  /// 出错原因。
  final String? error;

  /// 原始 `state` 字面量。
  final String? rawState;

  @override
  String get name => 'state';

  @override
  String toString() =>
      'EngineStateChanged(id: $id, state: ${state.wireName}, error: $error)';
}

/// `torrent_removed`：torrent 已被移除。
final class EngineTorrentRemoved extends EngineEvent {
  const EngineTorrentRemoved(this.id);

  /// torrent id。
  final int id;

  @override
  String get name => 'torrent_removed';

  @override
  String toString() => 'EngineTorrentRemoved($id)';
}

/// `heartbeat`：每 15s 一次的保活帧。
final class EngineHeartbeat extends EngineEvent {
  const EngineHeartbeat();

  @override
  String get name => 'heartbeat';

  @override
  String toString() => 'EngineHeartbeat()';
}

/// 引擎调用失败（spec §4.1：所有方法失败都抛它）。
class EngineException implements Exception {
  EngineException(
    this.message, {
    this.statusCode,
    this.uri,
    this.method,
    this.body,
    this.cause,
  });

  /// 人类可读、可行动的失败原因。
  final String message;

  /// HTTP 状态码；非 HTTP 失败（超时/连接被拒/解析失败）为 `null`。
  final int? statusCode;

  /// 出错的 URL。
  final Uri? uri;

  /// HTTP 方法。
  final String? method;

  /// 原始响应体（已截断），便于排查。
  final String? body;

  /// 底层异常。
  final Object? cause;

  /// 是否鉴权失败（token 不对）。
  bool get isUnauthorized => statusCode == 401;

  /// 是否端点不存在（例如边车没实现 `/shutdown`）。
  bool get isNotFound => statusCode == 404;

  /// 是否元数据超时（`POST /torrents` 返回 504）。
  bool get isMetadataTimeout =>
      statusCode == 504 || message.contains('metadata_timeout');

  @override
  String toString() {
    final buffer = StringBuffer('EngineException');
    if (statusCode != null) buffer.write('[${statusCode ?? ''}]');
    buffer.write(': $message');
    if (uri != null) buffer.write(' ($method ${uri ?? ''})');
    if (body != null && body!.isNotEmpty) {
      buffer.write('\n  响应体: ${body!}');
    }
    if (cause != null) buffer.write('\n  原因: $cause');
    return buffer.toString();
  }
}

/// 引擎进程启动失败（含最后几行 stdout/stderr，便于直接排查）。
class EngineStartException extends EngineException {
  EngineStartException(
    super.message, {
    required this.executable,
    this.runtimeFile,
    this.stdoutTail = const <String>[],
    this.stderrTail = const <String>[],
    this.exitCode,
    this.elapsed,
    super.cause,
  });

  /// 尝试启动的可执行文件路径。
  final String executable;

  /// 期待的 runtime.json 路径。
  final String? runtimeFile;

  /// 进程 stdout 的最后若干行。
  final List<String> stdoutTail;

  /// 进程 stderr 的最后若干行。
  final List<String> stderrTail;

  /// 若进程已退出，退出码。
  final int? exitCode;

  /// 从 spawn 到放弃所经过的时间。
  final Duration? elapsed;

  @override
  String toString() {
    final buffer = StringBuffer('EngineStartException: $message');
    buffer.write('\n  可执行文件: $executable');
    if (runtimeFile != null) buffer.write('\n  runtime.json: $runtimeFile');
    if (elapsed != null) buffer.write('\n  已等待: ${elapsed!.inMilliseconds}ms');
    if (exitCode != null) buffer.write('\n  退出码: $exitCode');
    if (stdoutTail.isNotEmpty) {
      buffer.write('\n  stdout 最后 ${stdoutTail.length} 行:');
      for (final line in stdoutTail) {
        buffer.write('\n    $line');
      }
    }
    if (stderrTail.isNotEmpty) {
      buffer.write('\n  stderr 最后 ${stderrTail.length} 行:');
      for (final line in stderrTail) {
        buffer.write('\n    $line');
      }
    }
    return buffer.toString();
  }
}
