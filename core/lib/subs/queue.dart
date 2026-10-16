/// 下载队列调度（spec §4.3）。
///
/// 这是「边下边播 → 下完本集 → 下下一集」的实现处：
/// * 并发下载默认 1（可调 1–3）；取 `queued` 中 `priority` 最小、再按 `createdAt` 最旧；
/// * 点播：立即 `addMagnet` 并马上把 `streamUrl` 交给播放器（不等下完）；
/// * 预热：**起播时**就把「后面 N 集」入队（priority 100）并启动（第三十八轮），
///   以及收到某 `fileIndex` 的 `completedFiles` 事件后继续补后面的（priority 100）；
/// * 省流量：`preheatAhead`（**默认 0 = 关闭**）/ `stopSeedingAfterPlayback` /
///   `deleteAfterPlayed` / `excludePatterns` 全部生效；
/// * **「本集下完」判据**：`completedFiles` 含本集文件索引，**或**引擎 `finished`，
///   **或** 字节数下满（`progressBytes >= totalBytes`）—— 三条独立证据任一成立即可，
///   见 [onProgress]（用户 2026-10-12 第 9 轮：「下载100%了还是不完成」）；
/// * 引擎就绪后 [reconcileWithEngine] 按引擎**状态**再对一次账，兜住漏掉的进度事件；
/// * 重启后 `downloading` 的 job 依据引擎 torrent 列表重新对齐（同 infoHash 视为同一任务）。
///
/// ## 五条「绝不自动下载 / 一定删得掉」硬规矩
///
/// 旧行为是「重启就把盘上的 `queued` 拉起来下」，加上订阅规则默认 `autoDownload=true`，
/// 表现就是**打开应用自己下几部没人要的番，而且怎么删都删不掉**（用户 2026-10-10）。
/// 现在：
/// 1. [load] 恢复出来的 `queued`/`downloading` 任务一律 `paused` 并记进 [_deferred]，
///    **只有用户明确点「继续」**才会被 [pump] 拉起；
/// 2. [reconcileWithEngine] 发现引擎里没有该任务时，标成 `paused` 而不是重新排队 —— 不再
///    自作主张重新 `addMagnet`；
/// 3. [removeJob] 是**真删**（连记录一起删）并写一条"别再自动入队"的墓碑，[enqueue] 默认
///    不会把墓碑上的条目拉回来（用户手点下载才算重新要）；
/// 4. **引擎侧也归零**：边车会从 session 自己恢复 torrent 接着传，所以 [load] +
///    [reconcileWithEngine] 会把恢复出来的任务在引擎里 `pause()` 掉 —— "重启不自动下载"
///    不能只管 Dart 这一半；
/// 5. **删不掉是 bug，不是状态**：引擎那一步（404 / 边车没起）失败**只回报提示**，
///    绝不阻断本地记录删除与墓碑落地（[removeJob] / [removeByEngine] / [clearAll]）；
/// 6. **下完的那份种子不跟着队列一起删**（用户 2026-10-12 第十九轮：「队列中移除了不应该把
///    已完成里也移除」）：「已完成」页读的就是引擎里 `finished` 的那批种子，
///    所以「移除（不含文件）」「清空队列」都只管队列记录，引擎那条留着 —— 判据见
///    [_keepEngineTorrent]；「删除含文件」是明确要连文件删，照旧连引擎一起删。
///
/// 配套：**播放结束要收尾**（[settleAfterPlayback]，用户 2026-10-11 选的"留记录但收尾"）。
/// 宿主以前没人在播放窗口收起时通知队列，点播建的任务就永远停在"下载中"。
///
/// 引擎依赖**本文件自己定义的抽象端口** [TorrentEnginePort]，
/// **不 import `core/lib/engine/`** —— 引擎客户端（③）在宿主层实现该端口即可对接。
library;

import 'dart:async';

import '../sources/kv.dart';
import '../sources/models.dart';
import 'rules.dart';

/// 任务状态（spec §4.3 冻结）。
enum JobState { queued, downloading, paused, completed, failed, cancelled }

/// 队列层异常。
class QueueException implements Exception {
  QueueException(this.message, {this.jobId});

  final String message;
  final String? jobId;

  @override
  String toString() =>
      'QueueException: $message${jobId == null ? '' : ' [job=$jobId]'}';
}

/// 一个下载任务。
class QueueJob {
  QueueJob({
    required this.id,
    required this.subscriptionId,
    required this.item,
    this.state = JobState.queued,
    this.engineId,
    this.fileIndex,
    this.priority = QueueManager.playbackPriority,
    this.attempts = 0,
    this.error,
    required this.createdAt,
    required this.updatedAt,
  });

  String id;
  String subscriptionId;
  SourceItem item;
  JobState state;
  int? engineId;
  int? fileIndex;

  /// 数字小 = 优先；自动预取 100，用户点播 10。
  int priority;
  int attempts;
  String? error;
  DateTime createdAt;
  DateTime updatedAt;

  /// 自动预取任务（可被省流量策略拦住）。
  bool get isPrefetch => priority >= QueueManager.prefetchPriority;

  /// 相对下载目录（记在 `item.extra` 里，随任务一起持久化）。
  String? get saveSubFolder => item.extra['saveSubFolder'] as String?;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'subscriptionId': subscriptionId,
        'item': item.toJson(),
        'state': state.name,
        if (engineId != null) 'engineId': engineId,
        if (fileIndex != null) 'fileIndex': fileIndex,
        'priority': priority,
        'attempts': attempts,
        if (error != null) 'error': error,
        'createdAt': createdAt.toUtc().toIso8601String(),
        'updatedAt': updatedAt.toUtc().toIso8601String(),
      };

  factory QueueJob.fromJson(Map<String, dynamic> json) => QueueJob(
        id: json['id']?.toString() ?? '',
        subscriptionId: json['subscriptionId']?.toString() ?? '',
        item: SourceItem.fromJson(
          (json['item'] as Map).map((dynamic k, dynamic v) =>
              MapEntry<String, dynamic>(k.toString(), v)),
        ),
        state: JobState.values.firstWhere(
          (JobState s) => s.name == json['state'],
          orElse: () => JobState.queued,
        ),
        engineId: (json['engineId'] as num?)?.toInt(),
        fileIndex: (json['fileIndex'] as num?)?.toInt(),
        priority: (json['priority'] as num?)?.toInt() ??
            QueueManager.playbackPriority,
        attempts: (json['attempts'] as num?)?.toInt() ?? 0,
        error: json['error'] as String?,
        createdAt: _requiredDate(json['createdAt'], 'createdAt'),
        updatedAt: _requiredDate(json['updatedAt'], 'updatedAt'),
      );

  QueueJob copyWith({
    String? id,
    String? subscriptionId,
    SourceItem? item,
    JobState? state,
    int? engineId,
    int? fileIndex,
    int? priority,
    int? attempts,
    String? error,
    DateTime? createdAt,
    DateTime? updatedAt,
    bool clearError = false,
    bool clearEngineId = false,
  }) =>
      QueueJob(
        id: id ?? this.id,
        subscriptionId: subscriptionId ?? this.subscriptionId,
        item: item ?? this.item,
        state: state ?? this.state,
        engineId: clearEngineId ? null : (engineId ?? this.engineId),
        fileIndex: fileIndex ?? this.fileIndex,
        priority: priority ?? this.priority,
        attempts: attempts ?? this.attempts,
        error: clearError ? null : (error ?? this.error),
        createdAt: createdAt ?? this.createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
      );

  @override
  String toString() =>
      'QueueJob($id, ${state.name}, p=$priority, engine=$engineId, '
      '${item.title ?? item.id})';
}

/// 持久化记录里的时间字段必须存在且合法，否则视为损坏记录让上层跳过。
DateTime _requiredDate(Object? value, String field) {
  final parsed = value is String ? DateTime.tryParse(value) : null;
  if (parsed == null) {
    throw FormatException('持久化的 QueueJob.$field 缺失或非法: "$value"');
  }
  return parsed;
}

/// 引擎里的文件（本端口自己的最小模型，不依赖 `core/lib/engine/`）。
class EngineFileInfo {
  const EngineFileInfo({
    required this.index,
    required this.path,
    required this.length,
    this.isVideo = false,
    this.included = true,
  });

  final int index;
  final String path;
  final int length;
  final bool isVideo;
  final bool included;
}

/// `addMagnet` 的结果。
class EngineAddedTorrent {
  const EngineAddedTorrent({
    required this.id,
    this.infoHash,
    this.name,
    this.files = const <EngineFileInfo>[],
  });

  final int id;
  final String? infoHash;
  final String? name;
  final List<EngineFileInfo> files;

  static const Set<String> subtitleExtensions = <String>{
    '.ass',
    '.srt',
    '.sub',
    '.ssa',
    '.vtt',
  };

  /// 主视频文件：视频里体积最大的那个（多版本同捆时取主视频）。
  int? get playableFileIndex {
    final videos = files.where((EngineFileInfo f) => f.isVideo).toList();
    if (videos.isEmpty) return null;
    videos.sort((EngineFileInfo a, EngineFileInfo b) => b.length.compareTo(a.length));
    return videos.first.index;
  }

  /// 视频 + 外挂字幕的索引（`onlyFiles` 用）。
  List<int> get videoAndSubtitleIndexes => files
      .where((EngineFileInfo f) =>
          f.isVideo || isSubtitlePath(f.path))
      .map((EngineFileInfo f) => f.index)
      .toList(growable: false);

  static bool isSubtitlePath(String path) {
    final lower = path.toLowerCase();
    return subtitleExtensions.any(lower.endsWith);
  }
}

/// 引擎里已有 torrent 的最小引用（重启对齐用）。
class EngineTorrentRef {
  const EngineTorrentRef({
    required this.id,
    this.infoHash,
    this.name,
    this.finished = false,
    this.progress,
    this.paused = false,
  });

  final int id;
  final String? infoHash;
  final String? name;

  /// 引擎是否已经报过「这个种子下完了」。
  final bool finished;

  /// 0.0–1.0 总进度（引擎不给就是 null，**不当成 0**）。
  final double? progress;

  /// 引擎当前是否已把这条 torrent 暂停（`state == paused`）。
  ///
  /// 为什么要有（用户 2026-10-12 第十二轮「下载完后自动上传做种，设置里做种是关的」）：
  /// 宿主「不做种」时要把下完的 torrent 暂停，而对账时必须能分清
  /// 「已经停过的」和「还在跑的」，不然每次对账都会去打扰一遍引擎。
  final bool paused;

  /// 引擎侧能不能算「下完了」。
  ///
  /// 用户 2026-10-12 第 9 轮「下载100%了还是不完成」用的就是它：进度**事件**会丢
  /// （订阅晚于边车启动、连接断过），但引擎的当前**状态**不会 —— 对账按状态说话。
  bool get isComplete => finished || (progress ?? 0) >= 1;
}

/// 引擎进度事件（对应边车 SSE 的 `progress`）。
///
/// 「本集下完」的三条判据见 [QueueManager.onProgress]：`completedFiles` /
/// `finished` / 字节数下满。
class EngineProgressTick {
  const EngineProgressTick({
    required this.id,
    this.infoHash,
    this.progressBytes,
    this.totalBytes,
    this.downloadBps,
    this.uploadBps,
    this.peers,
    this.finished = false,
    this.paused = false,
    this.completedFiles = const <int>{},
  });

  final int id;
  final String? infoHash;
  final int? progressBytes;
  final int? totalBytes;
  final int? downloadBps;
  final int? uploadBps;
  final int? peers;
  final bool finished;

  /// 引擎当前把这个 torrent 标成 `paused`。
  ///
  /// 「不做种」是**状态**而不是一次性动作（用户 2026-10-12 第十二轮）：只要一条
  /// torrent 还是「下完 + 没暂停」，就该被暂停。引擎每个进度事件都会重发状态，
  /// 所以队列可以幂等地纠正 —— 不用记「我暂停过谁」，那种记账在引擎重启/换运行期之后
  /// 就是错的（引擎会从 session 恢复 torrent，状态全变）。
  final bool paused;

  final Set<int> completedFiles;

  @override
  String toString() => 'EngineProgressTick(id=$id, completed=$completedFiles, '
      'finished=$finished, paused=$paused)';
}

/// 引擎端口（本文件定义，宿主负责用 `EngineClient` 实现它）。
abstract class TorrentEnginePort {
  /// 加磁力；返回引擎 id 与文件列表。
  Future<EngineAddedTorrent> addMagnet(
    String magnet, {
    String? name,
    List<int>? onlyFiles,
    bool startPaused = false,
    String? subFolder,
  });

  /// 引擎当前全部 torrent（重启对齐用）。
  Future<List<EngineTorrentRef>> listTorrents();

  Future<void> pause(int id);

  Future<void> resume(int id);

  Future<void> remove(int id, {bool deleteFiles = false});

  /// 进度流（对应边车 `GET /events`）。
  Stream<EngineProgressTick> progress();

  /// 交给播放器的串流 URL。
  Uri streamUrl(int id, int fileIndex);
}

/// `excludePatterns` 的正则编译缓存。
///
/// `isExcluded` 会在"每个任务每次 pump"里被调用（几十次/轮），每次都重新编正则没必要。
/// 键 = 模式原文；值 = 编译结果，`null` = 这条不是合法正则（走子串回落）。
final Map<String, RegExp?> _excludeRegexCache = <String, RegExp?>{};

RegExp? _excludeRegex(String pattern) {
  if (_excludeRegexCache.containsKey(pattern)) return _excludeRegexCache[pattern];
  RegExp? compiled;
  try {
    compiled = RegExp(pattern, caseSensitive: false);
  } on FormatException {
    compiled = null;
  }
  // 用户能加的条数是个位数；这个上限只为防"配置文件被塞进几千条"。
  if (_excludeRegexCache.length > 256) _excludeRegexCache.clear();
  _excludeRegexCache[pattern] = compiled;
  return compiled;
}

/// 省流量策略（spec §4.3「设置加入省流量列表」）。
class BandwidthPolicy {  const BandwidthPolicy({
    this.preheatAhead = 0,
    this.stopSeedingAfterPlayback = false,
    this.stopSeedingAfterDownload = false,
    this.deleteAfterPlayed = false,
    this.maxConcurrent = 1,
    this.excludePatterns = const <String>[],
  });

  /// 提前预热后几集（第三十八轮；用户原话「添加逻辑默认关闭，可提前预热后几集」）。
  ///
  /// **0 = 关闭，而且是默认**：只有正在播的那一集会被启动，队列里其它集保持
  /// `queued` 不动 —— 与旧的 `prefetchNext = false` 同义。旧实现默认是 `true`
  /// （「下完本集自动下下一集」），也就是"应用自己往队列里加任务"；用户这一轮要求
  /// 默认关掉，所以**旧键 `prefetchNext` 从 [fromJson] 里删掉了**（读了它等于
  /// 老配置继续自动添加）。
  ///
  /// `N ∈ 1..3` = **起播时**就把后面 N 集加进队列并启动：用户点「下一集」时那一集的
  /// 种子已经在引擎里、元数据早就绪 ⇒ 不用再等「补磁力 → addMagnet 等元数据」那一段。
  /// 为什么做成**档位**而不是开关：用户要的是"能提前预热**后几集**"，不是"能不能预取一集"。
  ///
  /// 代价要写清楚（设置页文案照这个说）：它是**真下载**，会提前吃带宽和磁盘。
  final int preheatAhead;

  /// true ⇒ 播放结束/切集时对该 torrent `pause()`（不再上传）。
  final bool stopSeedingAfterPlayback;

  /// true ⇒ **下载完成的那一刻就 `pause()` 该 torrent**（= 不做种、不上传）。
  ///
  /// 用户 2026-10-12 第十二轮报的就是它：「修复下载完后，自动上传做种问题，设置关着的做种」。
  /// 设置页那个「开启做种」开关关掉时只把 `--seed-ratio` 传成 **0**，而边车的语义是
  /// 「`>0` 才在达到比例后暂停，**0 = 不做任何做种干预**」
  /// （`engine/src/state.rs` 的 `maybe_stop_seeding`：`if state.seed_ratio <= 0.0 … return`）
  /// ⇒ 关掉开关反而等于"永远做种，宿主也不管"。这条策略把开关真正接上：
  /// 宿主把 `seedEnabled == false` 映射成 true（`app/lib/state/host_data.dart` 的
  /// `toCorePolicy`，那个参数是 `required`，忘了传编译不过），于是下完立刻 `pause()`；
  /// 暂停的 torrent 不再上传，而**已下载区间照旧可读**（播放不受影响，见边车 `/stream` 注释）。
  ///
  /// 注意语义边界：它管的是**下完以后**。下载过程中的上传是 BT 协议本身的一部分
  /// （不给别人传就没有别人给你传），这里不碰，也不该碰。
  ///
  /// core 自身默认 **false**（保持中性：库不知道宿主那个开关叫什么名字），
  /// 产品默认「不做种」由宿主映射给出 —— 见上面 `toCorePolicy` 的 `required`。
  final bool stopSeedingAfterDownload;

  /// true ⇒ 播放结束后删除任务与文件。
  final bool deleteAfterPlayed;

  /// 并发下载数（spec：可调 1–3，超出范围会被夹到 [1,3]）。
  final int maxConcurrent;

  /// 命中的番剧/规则一律不预取（省流量列表，UI 可编辑）。
  final List<String> excludePatterns;

  /// 生效的并发数。
  int get effectiveMaxConcurrent => maxConcurrent < 1 ? 1 : (maxConcurrent > 3 ? 3 : maxConcurrent);

  /// 生效的预热量：0（关）… 3。再多既吃带宽也吃磁盘，档位就到这里。
  int get effectivePreheatAhead => preheatAhead < 0 ? 0 : (preheatAhead > 3 ? 3 : preheatAhead);

  /// [text] 是否命中省流量列表。
  ///
  /// 第四十二轮 UX #25：这个列表在界面上叫「排除**正则**」，示例也是正则
  /// （`合集|总集篇|HEVC.*10bit`），而实现原来是**大小写不敏感的子串匹配** ——
  /// 用户照着示例填 `合集|总集篇`，当子串永远匹配不到任何东西，于是"设了没反应"，
  /// 一句解释都没有（静默假成功，`docs/HANDOFF.md` §9 明令禁止）。
  ///
  /// 现在按界面承诺走正则；**编不出来**的（老版本存下的、从配置文件导进来的）
  /// 退回子串匹配 —— 那是尽力而为，不是假装正则生效。
  bool isExcluded(String? text) {
    if (text == null || text.isEmpty) return false;
    for (final p in excludePatterns) {
      final pattern = p.trim();
      if (pattern.isEmpty) continue;
      final RegExp? re = _excludeRegex(pattern);
      if (re != null) {
        if (re.hasMatch(text)) return true;
        continue;
      }
      // 不是合法正则：按子串匹配（老数据/导入数据）。
      if (text.toLowerCase().contains(pattern.toLowerCase())) return true;
    }
    return false;
  }

  BandwidthPolicy copyWith({
    int? preheatAhead,
    bool? stopSeedingAfterPlayback,
    bool? stopSeedingAfterDownload,
    bool? deleteAfterPlayed,
    int? maxConcurrent,
    List<String>? excludePatterns,
  }) =>
      BandwidthPolicy(
        preheatAhead: preheatAhead ?? this.preheatAhead,
        stopSeedingAfterPlayback:
            stopSeedingAfterPlayback ?? this.stopSeedingAfterPlayback,
        stopSeedingAfterDownload:
            stopSeedingAfterDownload ?? this.stopSeedingAfterDownload,
        deleteAfterPlayed: deleteAfterPlayed ?? this.deleteAfterPlayed,
        maxConcurrent: maxConcurrent ?? this.maxConcurrent,
        excludePatterns: excludePatterns ?? this.excludePatterns,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'preheatAhead': preheatAhead,
        'stopSeedingAfterPlayback': stopSeedingAfterPlayback,
        'stopSeedingAfterDownload': stopSeedingAfterDownload,
        'deleteAfterPlayed': deleteAfterPlayed,
        'maxConcurrent': maxConcurrent,
        'excludePatterns': excludePatterns,
      };

  /// 读盘：新键 `preheatAhead` 缺省 **0**（关）。
  ///
  /// ⚠️ 旧键 `prefetchNext` **故意不读**（第三十八轮）：它的旧默认是 `true`
  /// （自动下下一集），读了它等于把用户刚要求的"默认关闭"又打开回去。
  factory BandwidthPolicy.fromJson(Map<String, dynamic> json) => BandwidthPolicy(
        preheatAhead: (json['preheatAhead'] as num?)?.toInt() ?? 0,
        stopSeedingAfterPlayback: json['stopSeedingAfterPlayback'] == true,
        stopSeedingAfterDownload: json['stopSeedingAfterDownload'] == true,
        deleteAfterPlayed: json['deleteAfterPlayed'] == true,
        maxConcurrent: (json['maxConcurrent'] as num?)?.toInt() ?? 1,
        excludePatterns: (json['excludePatterns'] as List?)
                ?.map((dynamic e) => e.toString())
                .toList() ??
            const <String>[],
      );
}

/// 点播结果：任务 + 可以立刻交给播放器的串流 URL。
class PlaybackTicket {
  const PlaybackTicket({required this.job, required this.streamUrl});

  final QueueJob job;
  final Uri streamUrl;
}

/// 队列调度器。
class QueueManager {
  QueueManager({
    required this.engine,
    required this.store,
    BandwidthPolicy? policy,
    DateTime Function()? clock,
    this.idGenerator,
    this.jobsKey = 'jobs',
    this.removedKey = removedItemsKey,
    this.autoPump = true,
  })  : _policy = policy ?? const BandwidthPolicy(),
        _clock = clock ?? DateTime.now;

  /// 用户点播优先级。
  static const int playbackPriority = 10;

  /// 自动预取优先级。
  static const int prefetchPriority = 100;

  /// 「已被用户移除、别再自动入队」的墓碑持久化键。
  static const String removedItemsKey = 'queue.removed';

  /// 墓碑最多留多少条（够覆盖用户手动删过的批次，不至于无限长）。
  static const int maxRemovedEntries = 500;

  /// 引擎端口（宿主用 `EngineClient` 实现）。
  final TorrentEnginePort engine;

  /// 持久化后端（生产 = Hive 的 `queue` box）。
  final KeyValueStore store;

  final DateTime Function() _clock;

  /// 任务 id 生成器（可注入，单测可得到稳定 id）。
  final String Function()? idGenerator;

  final String jobsKey;

  /// [removedItemsKey] 的可注入版本（单测用）。
  final String removedKey;

  /// 每次状态变化后是否自动 [pump]（单测可关掉，手动控制时序）。
  final bool autoPump;

  BandwidthPolicy _policy;
  final List<QueueJob> _jobs = <QueueJob>[];
  final Map<String, List<SourceItem>> _catalogues = <String, List<SourceItem>>{};
  final List<String> _loadWarnings = <String>[];

  /// 从盘上恢复、**等用户明确要求**才允许启动的任务（重启后绝不自动下载）。
  final Set<String> _deferred = <String>{};

  /// 用户移除过的条目 id / infoHash：订阅自动入队时跳过。
  final Set<String> _removed = <String>{};

  StreamSubscription<EngineProgressTick>? _progressSub;
  final StreamController<List<QueueJob>> _changes =
      StreamController<List<QueueJob>>.broadcast();
  bool _pumping = false;
  bool _pumpRequested = false;

  /// 正在启动中的任务（jobId → 那次 `addMagnet` 的 Future），见 [_start]。
  final Map<String, Future<void>> _starting = <String, Future<void>>{};

  int _idSeq = 0;
  String? _playingItemId;
  String? _playingSubscriptionId;

  /// 当前任务快照（不可变视图）。
  List<QueueJob> get jobs => List<QueueJob>.unmodifiable(_jobs);

  /// 状态变化流（每次持久化后推送一份完整快照）。
  Stream<List<QueueJob>> get changes => _changes.stream;

  BandwidthPolicy get policy => _policy;

  /// 加载时被跳过的损坏记录说明（诊断用）。
  List<String> get loadWarnings => List<String>.unmodifiable(_loadWarnings);

  /// 当前正在播放的条目 id（省流量策略用）。
  String? get playingItemId => _playingItemId;

  /// 该任务是否在「等用户明确要求」状态（重启恢复出来的任务）。
  bool isDeferred(String jobId) => _deferred.contains(jobId);

  /// 该条目是否被用户移除过（订阅自动入队会跳过这些）。
  bool isRemoved(SourceItem item) => _isRemoved(item);

  QueueJob? byId(String id) {
    for (final job in _jobs) {
      if (job.id == id) return job;
    }
    return null;
  }

  /// 引擎 id 对应的任务。
  QueueJob? byEngineId(int engineId) {
    for (final job in _jobs) {
      if (job.engineId == engineId) return job;
    }
    return null;
  }

  void setPolicy(BandwidthPolicy policy) {
    // 「做种」→「不做种」这一刻要**立刻**停掉已经下完的：只等下一次进度事件不行 ——
    // 下完且空闲的种子可能很久都不再有变化事件（用户 2026-10-12 第十二轮）。
    final bool turnedOffSeeding =
        policy.stopSeedingAfterDownload && !_policy.stopSeedingAfterDownload;
    _policy = policy;
    if (autoPump) unawaited(pump());
    if (turnedOffSeeding) unawaited(_pauseCompletedTorrents());
  }

  /// 从持久化恢复。
  ///
  /// 恢复出来的 `queued` **与 `downloading`** 任务立刻改成 **`paused`** 并记进
  /// [_deferred]：**重启不自动下载**，等用户在队列页点「继续」。旧行为是恢复后直接
  /// `pump()` 把盘上所有 `queued` 全下起来，用户看到的就是"打开应用自己在下东西"。
  ///
  /// 为什么 `downloading` 也要降级（用户 2026-10-11「队列里总是有东西」）：
  /// 旧实现把 `downloading` 留给 [reconcileWithEngine] 重新绑定，而边车自己会从 session
  /// 把 torrent 恢复出来接着传 —— 结果是"重启后它又自己跑起来了"，队列里那一条也永远
  /// 停在"下载中"。既然「重启绝不自动下载」是硬规矩，那就在**引擎侧**也成立：
  /// 恢复后统一暂停，[reconcileWithEngine] 负责把引擎那一份也 `pause()` 掉。
  Future<void> load() async {
    _loadWarnings.clear();
    _jobs.clear();
    _deferred.clear();
    _removed
      ..clear()
      ..addAll(_readRemoved());
    bool deferredAny = false;
    final raw = store.get(jobsKey);
    if (raw is List) {
      for (final entry in raw) {
        if (entry is! Map) {
          _loadWarnings.add('跳过损坏的队列记录（不是 JSON 对象）: $entry');
          continue;
        }
        try {
          final QueueJob job = QueueJob.fromJson(entry.map(
            (dynamic k, dynamic v) => MapEntry<String, dynamic>(k.toString(), v),
          ));
          _jobs.add(job);
          if (job.state == JobState.queued || job.state == JobState.downloading) {
            job.state = JobState.paused;
            job.error = job.error ?? '应用重启后任务不会自动继续：点「继续」才会接着下。';
            _deferred.add(job.id);
            deferredAny = true;
          } else if (job.state == JobState.paused) {
            _deferred.add(job.id);
          }
        } catch (e) {
          _loadWarnings.add('跳过损坏的队列记录: $e');
        }
      }
    }
    if (deferredAny) await _persist();
    _emit();
  }

  /// 订阅引擎进度流（幂等）。
  void start() {
    _progressSub ??= engine.progress().listen(
      (EngineProgressTick tick) {
        unawaited(onProgress(tick));
      },
      onError: (Object e) {
        _loadWarnings.add('引擎进度流错误: $e');
      },
    );
  }

  Future<void> dispose() async {
    await _progressSub?.cancel();
    _progressSub = null;
    await _changes.close();
  }

  /// 记录「当前在播哪一集」（省流量策略下只允许启动这一集）。
  void markPlaying(SourceItem? item, {String? subscriptionId}) {
    _playingItemId = item?.id;
    _playingSubscriptionId = subscriptionId ?? _playingSubscriptionId;
  }

  /// 订阅刷新时把候选条目喂进来（预取「下一集」的素材）。
  ///
  /// [rule] 非空时只保留命中该规则的条目（保证预取沿用订阅的过滤条件）。
  void addCandidates(
    String subscriptionId,
    List<SourceItem> items, {
    SubsRule? rule,
  }) {
    final filtered = <SourceItem>[];
    for (final item in items) {
      if (rule != null && !rule.matches(item)) continue;
      filtered.add(item);
    }
    _catalogues[subscriptionId] = filtered;
  }

  /// 显式入队（UI「下载」按钮）。默认用户优先级。
  ///
  /// * **同一条目（`item.id`）已经有任务** → 直接复用那条，不会重复入队、**也不会把
  ///   已完成的重置回队列**（重置就等于"每次订阅刷新都把看过的一集再下一遍"）；
  /// * `explicit: false`（订阅自动入队）时，用户移除过的条目直接跳过；
  /// * `explicit: true`（用户手点）时，用户移除过的条目算「重新要」，清掉墓碑。
  ///
  /// 返回 null = 这次没有入队（被墓碑挡掉了）。
  Future<QueueJob?> enqueue(
    SourceItem item, {
    required String subscriptionId,
    int priority = playbackPriority,
    String? saveSubFolder,
    bool explicit = false,
  }) async {
    final QueueJob? open = _openJobFor(item);
    if (open != null) return open;
    if (explicit) {
      await _forgetRemoved(item);
    } else if (_isRemoved(item)) {
      return null; // 用户删过这一集：订阅自动入队不再拉回来
    }
    final job = QueueJob(
      id: _nextId(),
      subscriptionId: subscriptionId,
      item: saveSubFolder == null || saveSubFolder.isEmpty
          ? item
          : item.copyWith(extra: <String, dynamic>{
              ...item.extra,
              'saveSubFolder': saveSubFolder,
            }),
      priority: priority,
      createdAt: _clock(),
      updatedAt: _clock(),
    );
    _jobs.add(job);
    await _afterMutation();
    return job;
  }

  /// 点播：立即 `addMagnet` + 立刻给出 `streamUrl`（不等下完）。
  ///
  /// [onlyFiles] 由调用方在已知文件列表时给出；磁力链在元数据就绪前拿不到文件列表，
  /// 因此这里**不会**替调用方猜 —— 传 null 表示交给引擎决定。
  ///
  /// 同一条目已经在下载 → 直接把现有那条的 `streamUrl` 交出去（不重复 `addMagnet`）；
  /// 已经暂停 → `resume` 后交出去。这样点播不会在队列里堆出重复任务。
  ///
  /// [preheat]（第三十八轮）：这一批里属于"当前集之后"的条目，按策略档位
  /// [BandwidthPolicy.effectivePreheatAhead] 预热几条。传进来的是**整批**（搜索批次 /
  /// 番剧页剧集清单），挑哪几条由 core 定（集号排序、跳过合集/省流量命中/已有任务的）。
  /// 档位为 0（默认关）时这一步是空操作。
  ///
  /// ⚠️ 预热是**入队**（多几条 priority 100 的任务），几条 `_persist()` 加起来是毫秒级，
  /// 但不能挡在"出画面"前面 —— 所以这里 `await` 的只是入队，真正的 `addMagnet`
  /// 交给 [pump] 在后台跑。
  Future<PlaybackTicket> playNow(
    SourceItem item, {
    String? subscriptionId,
    List<int>? onlyFiles,
    String? subFolder,
    List<SourceItem> preheat = const <SourceItem>[],
    int priority = playbackPriority,
  }) async {
    final magnet = item.bestMagnet;
    if (magnet == null) {
      throw QueueException(
        '条目「${item.title ?? item.id}」既没有磁力链接也没有 infoHash，无法播放',
      );
    }
    markPlaying(item, subscriptionId: subscriptionId);

    final QueueJob? open = _openJobFor(item, includeCompleted: false);
    if (open != null) {
      final int? engineId = open.engineId;
      final int? fileIndex = open.fileIndex;
      if (open.state == JobState.downloading &&
          engineId != null &&
          fileIndex != null) {
        await _preheatFor(item, preheat, subscriptionId);
        return PlaybackTicket(
          job: open,
          streamUrl: engine.streamUrl(engineId, fileIndex),
        );
      }
      if (open.state == JobState.paused &&
          engineId != null &&
          fileIndex != null) {
        await engine.resume(engineId);
        open
          ..state = JobState.downloading
          ..updatedAt = _clock();
        _deferred.remove(open.id);
        await _afterMutation();
        await _preheatFor(item, preheat, subscriptionId);
        return PlaybackTicket(
          job: open,
          streamUrl: engine.streamUrl(engineId, fileIndex),
        );
      }
    }

    final job = open ??
        (await enqueue(
          item,
          subscriptionId: subscriptionId ?? '',
          priority: priority,
          saveSubFolder: subFolder,
          explicit: true,
        ))!;
    await _start(job, magnet: magnet, onlyFiles: onlyFiles);
    if (job.state != JobState.downloading || job.engineId == null || job.fileIndex == null) {
      throw QueueException(
        '无法开始播放：${job.error ?? '引擎未返回可播放的视频文件'}',
        jobId: job.id,
      );
    }
    await _preheatFor(item, preheat, subscriptionId);
    return PlaybackTicket(
      job: job,
      streamUrl: engine.streamUrl(job.engineId!, job.fileIndex!),
    );
  }

  /// [playNow] 的预热收尾（三个返回点共用）：把这一批里"当前集之后"的 N 集入队。
  ///
  /// 入队成功会自己 `_afterMutation()` → `pump()` 在后台把它们的 `addMagnet` 发出去。
  Future<void> _preheatFor(
    SourceItem current,
    List<SourceItem> batch,
    String? subscriptionId,
  ) async {
    if (batch.isEmpty) return;
    if (_policy.effectivePreheatAhead <= 0) return;
    try {
      await preheatFrom(
        batch,
        current: current,
        subscriptionId: subscriptionId ?? '',
      );
    } catch (_) {
      // 预热只是"让下一次切换快一点"：它失败**绝不能**影响这次起播。
    }
  }

  /// 预热该订阅里「当前集之后」的最多 [count] 集（缺省 = 策略档位）。
  ///
  /// 返回**真正入队**的那几条；空列表表示无需/不应预热（关着 / 没有候选 /
  /// 全都被省流量列表或墓碑挡住）。素材来自 [addCandidates] 喂进来的 `_catalogues`。
  Future<List<QueueJob>> preheat(
    String subscriptionId, {
    required String afterItemId,
    int? count,
  }) async {
    final int want = count ?? _policy.effectivePreheatAhead;
    if (want <= 0) return const <QueueJob>[];

    final catalogue = _catalogues[subscriptionId];
    if (catalogue == null || catalogue.isEmpty) return const <QueueJob>[];

    SourceItem? current;
    for (final item in catalogue) {
      if (item.id == afterItemId) current = item;
    }
    if (current == null) {
      for (final job in _jobs) {
        if (job.item.id == afterItemId) current = job.item;
      }
    }
    if (current == null) return const <QueueJob>[];
    if (_policy.isExcluded(current.title)) return const <QueueJob>[];

    return _enqueuePreheat(
      _preheatCandidates(catalogue, current, want),
      subscriptionId: subscriptionId,
    );
  }

  /// 按**调用方当场给的清单**预热（第三十八轮起播那条路）。
  ///
  /// 与 [preheat] 的区别只在素材从哪来：订阅那条走 `_catalogues`（刷新时喂进来的候选），
  /// 这条走调用方手上的清单（搜索批次 / 番剧页剧集清单）—— 搜索页点播根本没有订阅 id，
  /// 靠 `_catalogues` 永远预热不了，而"点了下一集要等半天"最常见的场景恰恰是它。
  Future<List<QueueJob>> preheatFrom(
    List<SourceItem> items, {
    required SourceItem current,
    String subscriptionId = '',
    int? count,
  }) async {
    final int want = count ?? _policy.effectivePreheatAhead;
    if (want <= 0 || items.isEmpty) return const <QueueJob>[];
    if (_policy.isExcluded(current.title)) return const <QueueJob>[];

    // 素材里可能混进"补过详情的副本"（同 id 不同标题）：先去重，再挑。
    final Map<String, SourceItem> catalog = <String, SourceItem>{};
    for (final item in items) {
      catalog.putIfAbsent(item.id, () => item);
    }
    catalog.putIfAbsent(current.id, () => current);

    return _enqueuePreheat(
      _preheatCandidates(catalog.values.toList(growable: false), current, want),
      subscriptionId: subscriptionId,
    );
  }

  /// 从 [catalogue] 里挑出 `current` 之后最近的 [want] 集（合集/省流量命中/已有任务的跳过）。
  ///
  /// 判据与旧 `prefetchNext` 完全一致（只多了"挑 want 条"这一层）：集号解析得出来、
  /// 比当前集大、不是合集（体积巨大）、没被省流量列表挡住、队列里没有它的任务。
  List<SourceItem> _preheatCandidates(
    List<SourceItem> catalogue,
    SourceItem current,
    int want,
  ) {
    final int? currentEpisode = _episodeNumber(current);
    if (currentEpisode == null) return const <SourceItem>[];

    final candidates = <SourceItem>[];
    for (final item in catalogue) {
      if (item.id == current.id) continue;
      if (item.extra['isBatch'] == true) continue;
      if (_policy.isExcluded(item.title)) continue;
      final int? ep = _episodeNumber(item);
      if (ep == null || ep <= currentEpisode) continue;
      if (_hasOpenJob(item.id)) continue;
      candidates.add(item);
    }
    candidates.sort((SourceItem a, SourceItem b) =>
        _episodeNumber(a)!.compareTo(_episodeNumber(b)!));
    return candidates.length > want ? candidates.sublist(0, want) : candidates;
  }

  /// 把挑好的候选按 [prefetchPriority] 入队（墓碑挡掉的跳过，继续试下一条）。
  Future<List<QueueJob>> _enqueuePreheat(
    List<SourceItem> candidates, {
    required String subscriptionId,
  }) async {
    final out = <QueueJob>[];
    for (final item in candidates) {
      final QueueJob? job = await enqueue(
        item,
        subscriptionId: subscriptionId,
        priority: prefetchPriority,
      );
      if (job == null) continue; // 被「用户已移除」的墓碑挡掉
      job.error = null;
      out.add(job);
    }
    return out;
  }

  /// 调度一轮：把可启动的 queued 任务交给引擎（**一次交满并发上限**）。
  ///
  /// 可能因为 `addMagnet` 等元数据而耗时（磁力链最长 130s），
  /// UI 调用时**不要 await**（内部已做重入保护）。
  ///
  /// ## 为什么是「一起交」而不是一条一条 await（用户 2026-10-12 第二十三轮）
  /// 旧实现是 `while (...) { await _start(next); }`：`addMagnet` 对磁力链是**在 HTTP
  /// 请求里同步等元数据**（边车语义，最长 `kDefaultMetadataRequestTimeout` = 130s），
  /// 于是第 1 条等不到元数据时，第 2、3 条连 `addMagnet` 都没发生 —— 「并发下载数」
  /// 只在**没人卡住**的时候生效，而用户连点下载时正好每条都在卡。
  ///
  /// 现在先把这一批挑出来、**全部交给引擎**，再 `await Future.wait` 等它们各自的
  /// 元数据结果。上限照旧成立：`_start` → `_doStart` 会在它的第一个 `await` 之前
  /// **同步**把状态改成 `downloading`，所以下一轮 `_nextQueued()` 不会再挑到同一条。
  Future<void> pump() async {
    if (_pumping) {
      _pumpRequested = true;
      return;
    }
    _pumping = true;
    try {
      do {
        _pumpRequested = false;
        final List<Future<void>> starting = <Future<void>>[];
        while (true) {
          final next = _nextQueued();
          if (next == null) break;
          // 「并发下载数」管的是**用户任务**；预热任务（priority 100）另算 ——
          // 第三十八轮：档位开成 N 就是"后 N 集提前下"，拿用户那个 1–3 的并发上限
          // 去卡它，预热会一直排在"正在看的那一集"后面（那一集整集都在下），
          // 等于永远预热不了。所以这里只数**非预热**的下载中任务。
          if (!next.isPrefetch &&
              _countUserDownloading() >= _policy.effectiveMaxConcurrent) {
            break;
          }
          final magnet = next.item.bestMagnet;
          if (magnet == null) {
            next.state = JobState.failed;
            next.error = '条目既没有磁力链接也没有 infoHash，无法下载';
            next.updatedAt = _clock();
            await _persist();
            _emit();
            continue;
          }
          starting.add(_start(next, magnet: magnet));
        }
        if (starting.isEmpty) continue; // 没得启动：等 do-while 条件收尾
        await Future.wait(starting);
      } while (_pumpRequested);
    } finally {
      _pumping = false;
    }
  }

  /// 引擎进度事件：本集下完 → `completed`；「不做种」时下完 → 立刻暂停。
  ///
  /// ## 判据（用户 2026-10-12 第 9 轮修正）
  /// 1. **`completedFiles` 含本集的文件索引** —— 首选，语义最精确；
  /// 2. `finished == true` —— 引擎自己说"这个种子下完了"；
  /// 3. `progressBytes >= totalBytes`（且 totalBytes > 0）—— 字节数已满。
  ///
  /// 为什么原来只认 (1) 不够：进度是**事件流**，订阅晚一步或断一次，
  /// 「已完成」这个事件就永远补不回来，任务卡在「下载中」不再变化
  /// （真机证据：引擎 09:24:23 报 torrent finished，队列表里那条任务的 `updatedAt`
  /// 停在 09:22:30 再没动过；根因见宿主 `EngineRuntimeHolder`/`QueueEngineBridge`
  /// 的订阅自愈）。判据 (2)(3) 是同一件事的另外两个独立证据，不靠事件送达。
  Future<void> onProgress(EngineProgressTick tick) async {
    // ⓪ 不做种（用户 2026-10-12 第十二轮「下载完后，自动上传做种问题，设置关着的做种」）：
    //    整个种子下完的那一刻就 `pause()` 它 —— 暂停的 torrent 不再上传，而已下载区间
    //    照旧可读（播放不受影响）。
    //
    //    刻意放在最前面，而且**不要求这条 tick 有对应的队列任务**：设置里关着做种是对
    //    整台机器生效的（引擎里可能有手工加进来的、或上次会话留下的种子）。
    //    幂等靠 `tick.paused`（引擎每次都重发状态）——已经停过的不再打扰引擎。
    if (_policy.stopSeedingAfterDownload && !tick.paused && _tickComplete(tick)) {
      await _tryEnginePause(tick.id);
    }

    final completedNow = <QueueJob>[];
    for (final job in _jobs) {
      if (job.engineId != tick.id) continue;
      if (job.state != JobState.downloading) continue;
      final index = job.fileIndex;
      final bool done = (index != null && tick.completedFiles.contains(index)) ||
          tick.finished ||
          _bytesComplete(tick);
      if (!done) continue;
      job.state = JobState.completed;
      job.error = null;
      job.updatedAt = _clock();
      completedNow.add(job);
    }
    if (completedNow.isEmpty) return;

    await _persist();
    _emit();

    for (final job in completedNow) {
      await _maybePrefetch(job);
    }
  }

  /// 这一条 tick 是否已经「整个种子下完」（`finished` 或字节数下满）。
  ///
  /// 与 [onProgress] 里那条**按集**的判据分开：单集下完（`completedFiles` 含本集）
  /// 不代表整个种子下完，不该因此停上传 —— 停了还在下的那几集也就停了。
  static bool _tickComplete(EngineProgressTick tick) =>
      tick.finished || _bytesComplete(tick);

  /// 字节数是否已经满了（`progressBytes >= totalBytes`，两者都要有且总量 > 0）。
  static bool _bytesComplete(EngineProgressTick tick) {
    final total = tick.totalBytes;
    final done = tick.progressBytes;
    if (total == null || done == null || total <= 0) return false;
    return done >= total;
  }

  /// 播放结束 / 切集：按省流量策略停做种或删文件。
  Future<void> onPlaybackFinished(int engineId, {SourceItem? next}) async {
    final job = byEngineId(engineId);
    if (_policy.stopSeedingAfterPlayback) {
      await engine.pause(engineId);
    }
    if (_policy.deleteAfterPlayed) {
      await engine.remove(engineId, deleteFiles: true);
      if (job != null) {
        job.state = JobState.completed;
        job.updatedAt = _clock();
      }
    }
    if (job != null && job.item.id == _playingItemId) {
      markPlaying(next);
    }
    await _persist();
    _emit();
    if (autoPump) unawaited(pump());
  }

  /// 播放**结束**（播放窗口收起/彻底关闭、不再看这一集）：把这次点播留下的任务收尾。
  ///
  /// 语义由用户 2026-10-11 当面选定 ——「**留记录但收尾**」：
  /// * 这一集**已经下完**（进度事件已把任务标成 `completed`）→ 保持 `completed`；
  /// * **没下完** → `paused`（想接着下就点「继续」）；
  /// * 引擎侧不再偷偷跑：一律 `pause()`，除非「省流量 → 播放结束停做种」被关掉**并且**
  ///   这一集已经下完（那种组合下用户明确想继续做种）；
  /// * 「省流量 → 播放完删除任务与文件」打开时沿用旧行为：删 torrent（连文件）+ `completed`。
  ///
  /// 为什么不顺手把记录删掉：用户要的是「队列干净 + 一定删得掉」，不是「我下的东西自己
  /// 消失」。留着才看得见、才能一键删（[removeJob] 现在也不会被引擎错误卡住）。
  ///
  /// 为什么必须有这条：宿主以前**没有任何地方**在播放窗口收起时通知队列（`PlaybackController.stop()`
  /// 全仓无人调用），于是点播建的那条 `downloading` 任务永远停在"下载中"，边车也一直
  /// 挂着那个 torrent —— 这正是用户报的「队列里总是有东西」。
  Future<void> settleAfterPlayback(int engineId) async {
    final QueueJob? job = byEngineId(engineId);
    if (job == null) {
      // 没有队列记录（例如直接在「已缓存」页点播）：按策略收拾引擎就够了。
      if (_policy.stopSeedingAfterPlayback) await _tryEnginePause(engineId);
      return;
    }
    if (_policy.deleteAfterPlayed) {
      await _tryEngineRemove(engineId, deleteFiles: true);
      job
        ..state = JobState.completed
        ..error = null
        ..updatedAt = _clock();
      await _afterMutation();
      return;
    }
    final bool complete = job.state == JobState.completed;
    if (!(complete && !_policy.stopSeedingAfterPlayback)) {
      await _tryEnginePause(engineId);
    }
    job
      ..state = complete ? JobState.completed : JobState.paused
      ..error = complete
          ? null
          : '播放已结束：任务停在暂停，不会在后台继续下。点「继续」才会接着下。'
      ..updatedAt = _clock();
    await _afterMutation();
  }

  /// 暂停任务。
  Future<void> pauseJob(String jobId) async {
    final job = byId(jobId);
    if (job == null) throw QueueException('任务不存在', jobId: jobId);
    if (job.state == JobState.completed ||
        job.state == JobState.cancelled ||
        job.state == JobState.failed) {
      throw QueueException('任务处于 ${job.state.name}，无法暂停', jobId: jobId);
    }
    final engineId = job.engineId;
    if (engineId != null && job.state == JobState.downloading) {
      await engine.pause(engineId);
    }
    job.state = JobState.paused;
    job.updatedAt = _clock();
    await _afterMutation();
  }

  /// 继续任务。
  ///
  /// 这里也是「重启恢复出来的任务」唯一被允许重新启动的入口：清掉 [_deferred] 之后
  /// 才可能被 [pump] 拉起。
  Future<void> resumeJob(String jobId) async {
    final job = byId(jobId);
    if (job == null) throw QueueException('任务不存在', jobId: jobId);
    if (job.state != JobState.paused && job.state != JobState.failed) {
      throw QueueException('任务处于 ${job.state.name}，无法继续', jobId: jobId);
    }
    _deferred.remove(jobId);
    final engineId = job.engineId;
    if (engineId != null) {
      await engine.resume(engineId);
      job.state = JobState.downloading;
    } else {
      job.state = JobState.queued;
    }
    job.error = null;
    job.updatedAt = _clock();
    await _afterMutation();
  }

  /// **移除任务**：从队列里彻底删掉这条记录（可选连文件一起删），并记一条墓碑
  /// （条目 id / infoHash），订阅自动入队不会再把这一集拉回来。用户手点「下载」
  /// 才算重新要（会清掉墓碑）。
  ///
  /// 旧实现叫 `cancelJob`，只把状态改成 `cancelled` 而把记录留在盘上 —— 于是重启后
  /// 「对齐」又把引擎里的 torrent 绑回来，用户怎么删都删不掉（实测踩过的严重问题）。
  ///
  /// 返回值：`null` = 队列与引擎都处理干净；非空字符串 = **队列记录已经删掉了**，但引擎
  /// 那一步没成功（一句给用户看的话）。调用方可以选择把它显示出来。
  ///
  /// ⚠️ 为什么引擎失败**绝不能**中断删除（用户 2026-10-11「队列里总是有东西，还删不掉」）：
  /// 旧实现第一件事就是 `await engine.remove(...)` 且不兜异常。只要引擎回 404
  /// （`no_such_torrent`：用户先在「已缓存」页删过那个 torrent、或边车重启后 id 变了），
  /// 异常就把**记录删除 + 墓碑**一起打断 —— 用户看到的是一条既删不掉、重启后又冒出来的
  /// 任务。队列记录与墓碑都只在本地下，必须无条件落地。
  ///
  /// ⚠️ **已经下完的那份种子不删**（用户 2026-10-12 第十九轮：「队列中移除了不应该把已完成
  /// 里也移除」）：用户心里「下完 = 本地文件」，而「已完成」页的数据源正是引擎里的
  /// `finished` 种子（宿主 `completedGroupsProvider → cachedTorrentsProvider`）。所以
  /// 「移除（不含文件）」如果顺手删掉引擎那条记录，用户看到的就是「我在队列里清一下，
  /// 已完成里的片也没了」—— 文件明明还在磁盘上。判据见 [_keepEngineTorrent]。
  Future<String?> removeJob(String jobId, {bool deleteFiles = false}) async {
    final job = byId(jobId);
    if (job == null) throw QueueException('任务不存在', jobId: jobId);
    final engineId = job.engineId;
    String? warning;
    if (engineId != null && !await _keepEngineTorrent(job, deleteFiles: deleteFiles)) {
      warning = await _tryEngineRemove(engineId, deleteFiles: deleteFiles);
    }
    await _forgetJobs(<QueueJob>[job]);
    return warning;
  }

  /// 从**引擎侧**删掉一个 torrent，并把队列里绑着它的任务一并清掉（含墓碑）。
  ///
  /// 「已缓存」页的数据源就是引擎 torrent 列表，那里的「删除」只能走这条路。旧实现只调
  /// 引擎端口删除，队列完全不知情 —— 于是队列里留下一条永远「下载中」、进度又查不到的
  /// 幽灵任务，而且它绑的 engineId 在引擎里已经没了，点删除还会 404
  /// （用户 2026-10-11「队列里总是有东西，还删不掉」的双重成因）。
  ///
  /// 队列里没有对应任务时也照样删引擎那一份（直接加磁力/旧任务的情况）。
  Future<String?> removeByEngine(int engineId, {bool deleteFiles = true}) async {
    final matches =
        _jobs.where((QueueJob j) => j.engineId == engineId).toList(growable: false);
    final String? warning = await _tryEngineRemove(engineId, deleteFiles: deleteFiles);
    await _forgetJobs(matches);
    return warning;
  }

  /// 清空队列（可选连文件一起删）。批量版 [removeJob]，返回值同它。
  ///
  /// 「已下完的那份种子不删」这条规则与 [removeJob] 完全一致（用户第十九轮）：
  /// 清空队列是**整理队列**，不是「把已完成的东西抹掉」。
  Future<String?> clearAll({bool deleteFiles = false}) async {
    final List<QueueJob> jobs = List<QueueJob>.of(_jobs);
    // 整批只问引擎一次「哪些已经下完」（逐条问 = N 次请求）。本地就能判定的情况
    // （要删文件 / 队列状态已经是 completed / 没有 engineId）不必打扰引擎。
    final bool needsEngineLookup = !deleteFiles &&
        jobs.any((QueueJob j) => j.engineId != null && j.state != JobState.completed);
    final Set<int>? completeIds = needsEngineLookup ? await _completeEngineIds() : null;
    // 第四十二轮 UX #31：旧实现是 `warning ??= await _tryEngineRemove(...)` ——
    // 只有**第一条**失败被回报，后面对话框一关，剩下的失败谁也不知道。
    // 现在全部收齐再合成一句话（单条时文案与旧版完全一致，测试与用户看到的都不变）。
    final List<String> warnings = <String>[];
    for (final QueueJob job in jobs) {
      final engineId = job.engineId;
      if (engineId == null) continue;
      if (await _keepEngineTorrent(job, deleteFiles: deleteFiles, completeIds: completeIds)) {
        continue;
      }
      final String? warning =
          await _tryEngineRemove(engineId, deleteFiles: deleteFiles);
      if (warning != null) warnings.add(warning);
    }
    await _forgetJobs(jobs);
    if (warnings.isEmpty) return null;
    if (warnings.length == 1) return warnings.first;
    return '${warnings.first}（另有 ${warnings.length - 1} 条同样没删掉）';
  }

  /// 清理已完成任务记录（不影响引擎里的 torrent）。
  Future<void> clearCompleted() async {
    _jobs.removeWhere((QueueJob j) => j.state == JobState.completed);
    await _afterMutation();
  }

  /// 重启后对齐 + 用引擎状态纠正「下载中」的任务。
  ///
  /// ① 把「重启恢复出来的、用户还没接手的」任务（[_deferred] 里的 `paused`）
  /// 按 infoHash（其次按名称）重新绑定引擎 id，并**把引擎那一份暂停**。
  /// 引擎里已经没有的，保持 `paused` 并给出原因 —— 绝不自动重新下载。
  ///
  /// ⚠️ ① 这一档**不会**让任务跑起来：`paused` + [_deferred] 的组合在 [pump] 里是不可
  /// 启动的（见 [_isStartable]），引擎侧也在这一步被 `pause()`。理由见 [load]：边车会从
  /// session 恢复 torrent 并继续传，"重启不自动下载"必须在引擎侧也成立（用户 2026-10-11）。
  ///
  /// ② **本次会话里正在下的任务**：引擎说下完了（`finished` / 进度 100%）就补成
  /// `completed`（用户 2026-10-12 第 9 轮「下载100%了还是不完成」）。这一步是"按状态
  /// 对账"，能兜住 [onProgress] 那条事件流漏掉的事件（订阅晚于边车启动、连接断过 ——
  /// 详见宿主 `QueueEngineBridge.progress` 的自愈注释）；漏事件时的表现就是任务永远
  /// 停在「下载中」，而首页卡片读的是另一个订阅，于是显示「下载中 100%」。
  ///
  /// 为什么放在这个函数里：它已经是"引擎就绪后跑一次"的那个钩子
  /// （宿主在 `EngineBootstrapController.start()` 成功分支里调 `reconcile()`）。
  Future<void> reconcileWithEngine() async {
    final List<EngineTorrentRef> torrents;
    try {
      torrents = await engine.listTorrents();
    } catch (error) {
      // 边车没起来 / 请求超时 / 地址不通：这一轮对账做不了，但**绝不抛**。
      //
      // 宿主是在 `EngineBootstrapController.start()` 的成功分支里 await 这一步的，
      // 而那里只吞 `PortUnavailableException` —— 别的异常会从 `main.dart` 那条
      // `unawaited(start())` 冒成启动期的未处理异常：队列既不显示原因，
      // 用户也看不到"为什么任务停在那儿"。所以按 `_pauseCompletedTorrents` 的老规矩：
      // 记一条可观测的警告，然后当作这一轮没做（下次引擎就绪时还会再试）。
      final String message = '引擎就绪后对账失败：${_briefError(error)}（任务状态可能停在上一轮）';
      if (!_loadWarnings.contains(message)) _loadWarnings.add(message);
      return;
    }
    final completedNow = <QueueJob>[];
    for (final job in _jobs) {
      if (job.state == JobState.paused && _deferred.contains(job.id)) {
        final match = _findTorrent(torrents, job);
        if (match != null) {
          job.engineId = match.id;
          if (match.infoHash != null && job.item.infoHash == null) {
            job.item = job.item.copyWith(infoHash: match.infoHash);
          }
          job.error = job.fileIndex == null
              ? '已重新绑定引擎任务，但重启前未记录文件索引，等引擎返回后可继续'
              : '应用重启后不会自动继续：点「继续」才会接着下。';
          await _tryEnginePause(match.id);
        } else {
          job.engineId = null;
          job.error = '应用重启后引擎里没有这个任务：已暂停，不会自动重新下载。要下就点「继续」。';
        }
        job.updatedAt = _clock();
        continue;
      }
      if (job.state != JobState.downloading) continue;
      final match = _findTorrent(torrents, job);
      if (match == null || !match.isComplete) continue;
      job.state = JobState.completed;
      job.error = null;
      job.updatedAt = _clock();
      completedNow.add(job);
    }
    await _persist();
    _emit();
    // 补判出来的"已完成"同样要触发预取（与 [onProgress] 一致）。
    for (final job in completedNow) {
      await _maybePrefetch(job);
    }
    // 不做种：引擎里**已经下完、又还在跑**的 torrent 一律暂停 —— 按状态对账，
    // 不依赖任何一次事件。用户第十二轮报的那批里就有一部分是上一次会话留下的
    //（`--seed-ratio 0` 从来不干预，而那时宿主也没有任何地方停过它们）。
    if (_policy.stopSeedingAfterDownload) await _pauseCompletedTorrents();
    if (autoPump) unawaited(pump());
  }

  /// 把引擎里「已经下完、且还在跑（未暂停）」的 torrent 全部 `pause()`。
  ///
  /// 为什么需要它而不是只靠进度事件：一条下完且没人连的种子可能**很久都不再有变化**，
  /// 事件流不响，而"不做种"必须对它成立。对账（[reconcileWithEngine]）与
  /// 开关从「做种」切到「不做种」（[setPolicy]）都会走到这里。
  ///
  /// 失败**不抛**：边车没起来时这只是"暂时做不到"，不该卡住宿主保存设置。
  Future<void> _pauseCompletedTorrents() async {
    try {
      final List<EngineTorrentRef> torrents = await engine.listTorrents();
      for (final EngineTorrentRef ref in torrents) {
        if (ref.isComplete && !ref.paused) await _tryEnginePause(ref.id);
      }
    } catch (error) {
      final String message = '不做种：读取引擎任务失败（${_briefError(error)}）';
      if (!_loadWarnings.contains(message)) _loadWarnings.add(message);
    }
  }

  // ---------------------------------------------------------------- internals

  /// 同一条目（`item.id`）已有的任务。
  ///
  /// 只按 `item.id` 去重，**不按 infoHash**：合集种子里同一 infoHash 对应多集，
  /// 按 hash 合并会把「第 2 集」误判成「第 1 集已在下载」。
  ///
  /// [includeCompleted] 默认 true（入队语义：下过就不该再下）；
  /// `playNow` 传 false —— 已完成的一集仍然要能重新交给播放器。
  QueueJob? _openJobFor(SourceItem item, {bool includeCompleted = true}) {
    for (final job in _jobs) {
      if (job.item.id != item.id) continue;
      switch (job.state) {
        case JobState.queued:
        case JobState.downloading:
        case JobState.paused:
          return job;
        case JobState.completed:
          if (includeCompleted) return job;
        case JobState.failed:
        case JobState.cancelled:
          break;
      }
    }
    return null;
  }

  bool _isRemoved(SourceItem item) {
    if (_removed.contains(item.id)) return true;
    final hash = item.infoHash;
    return hash != null && hash.isNotEmpty && _removed.contains(hash.toLowerCase());
  }

  Future<void> _forgetRemoved(SourceItem item) async {
    bool changed = _removed.remove(item.id);
    final hash = item.infoHash;
    if (hash != null && hash.isNotEmpty) {
      changed = _removed.remove(hash.toLowerCase()) || changed;
    }
    if (changed) await _persistRemoved();
  }

  /// 真删记录 + 记墓碑 + 落盘 + 推流（[removeJob] / [removeByEngine] / [clearAll] 共用）。
  ///
  /// 这里刻意**不看引擎**：墓碑是"别再自动入队"的唯一凭据，必须与引擎状态无关地落地。
  Future<void> _forgetJobs(Iterable<QueueJob> jobs) async {
    bool changed = false;
    for (final QueueJob job in jobs) {
      _removed.add(job.item.id);
      final hash = job.item.infoHash;
      if (hash != null && hash.isNotEmpty) _removed.add(hash.toLowerCase());
      _deferred.remove(job.id);
      final int before = _jobs.length;
      _jobs.removeWhere((QueueJob j) => j.id == job.id);
      changed = _jobs.length != before || changed;
    }
    if (!changed) return;
    await _persistRemoved();
    await _afterMutation();
  }

  /// 队列里移除任务时，**引擎里那份种子要不要留着**（[removeJob] / [clearAll] 共用）。
  ///
  /// 规则（用户 2026-10-12 第十九轮问答选定）：
  /// * 「删除含文件」= 用户明确要连文件一起删 → 引擎那份照旧删掉（文件都没了，「已完成」
  ///   里留一条点不开的卡片才是错的）；
  /// * 队列状态已经是 `completed` → 留着；
  /// * 队列状态不是 `completed`、但**引擎说这个种子已经下完** → 也留着。为什么不只信
  ///   队列状态：真机上出现过「下完了、进度 100%、任务还停在 `downloading`」（第十二轮
  ///   「下载100%了还是不完成」）—— 那种任务被当成"没下完"删掉引擎记录，「已完成」页
  ///   同样会少一条；
  /// * 引擎读不到（边车没起）→ 不当作已下完：这时删除本来也会失败，会原样回报提示。
  ///
  /// [completeIds] 给批量调用方（[clearAll]）复用一次查询结果；null = 需要时自己查。
  Future<bool> _keepEngineTorrent(
    QueueJob job, {
    bool deleteFiles = false,
    Set<int>? completeIds,
  }) async {
    if (deleteFiles) return false;
    if (job.state == JobState.completed) return true;
    final int? engineId = job.engineId;
    if (engineId == null) return false;
    final Set<int> complete = completeIds ?? await _completeEngineIds();
    return complete.contains(engineId);
  }

  /// 引擎里**已经下完**的 torrent id（读不到 = 空集）。
  ///
  /// 失败不抛、也不往 [_loadWarnings] 里写：调用方紧接着就要去删引擎，真的连不上会在
  /// 那一步回报一句给用户；在这里多记一条只会在下次启动时冒出一个过期的告警。
  Future<Set<int>> _completeEngineIds() async {
    try {
      final List<EngineTorrentRef> refs = await engine.listTorrents();
      return <int>{
        for (final EngineTorrentRef ref in refs)
          if (ref.isComplete) ref.id,
      };
    } catch (_) {
      return <int>{};
    }
  }

  /// 引擎侧删除：**永不抛**。失败只回报一句提示（理由见 [removeJob]）。
  Future<String?> _tryEngineRemove(int engineId, {required bool deleteFiles}) async {
    try {
      await engine.remove(engineId, deleteFiles: deleteFiles);
      return null;
    } catch (error) {
      final String brief = _briefError(error);
      _loadWarnings.add('引擎删除失败（id=$engineId）：$brief');
      return deleteFiles
          ? '队列记录已清理，但引擎没删掉（$brief）：文件可能还留在下载目录里。'
          : '队列记录已清理，但引擎没删掉（$brief）：引擎里可能已经没有这个任务了。';
    }
  }

  /// 引擎侧暂停：失败同样不抛（边车没起来/任务已移除都不该卡住本地动作）。
  Future<void> _tryEnginePause(int engineId) async {
    try {
      await engine.pause(engineId);
    } catch (error) {
      _loadWarnings.add('引擎暂停失败（id=$engineId）：${_briefError(error)}');
    }
  }

  static String _briefError(Object error) {
    final String text = '$error'.replaceAll('\n', ' ').trim();
    return text.length <= 120 ? text : '${text.substring(0, 117)}…';
  }

  List<String> _readRemoved() {
    final Object? raw = store.get(removedKey);
    if (raw is! List) return const <String>[];
    return <String>[
      for (final Object? e in raw)
        if (e != null && '$e'.isNotEmpty) '$e',
    ];
  }

  Future<void> _persistRemoved() async {
    final List<String> all = _removed.toList(growable: false);
    final List<String> capped = all.length <= maxRemovedEntries
        ? all
        : all.sublist(all.length - maxRemovedEntries);
    await store.put(removedKey, capped);
  }

  EngineTorrentRef? _findTorrent(List<EngineTorrentRef> torrents, QueueJob job) {
    final hash = job.item.infoHash?.toLowerCase();
    if (hash != null && hash.isNotEmpty) {
      for (final t in torrents) {
        if (t.infoHash?.toLowerCase() == hash) return t;
      }
    }
    final engineId = job.engineId;
    if (engineId != null) {
      for (final t in torrents) {
        if (t.id == engineId) return t;
      }
    }
    final title = job.item.title;
    if (title != null && title.isNotEmpty) {
      for (final t in torrents) {
        if (t.name == title) return t;
      }
    }
    return null;
  }

  /// 启动一条任务（交给引擎 `addMagnet`）。
  ///
  /// **同一个任务只允许一次启动在飞**：`enqueue()` 内部会 `_afterMutation()` → 调度一轮
  /// `pump()`（`unawaited`），而 `playNow()` 拿到同一条任务后还会再 `_start` 一次 ——
  /// 两条路都走到这里，同一个种子就会被 `addMagnet` **两遍**（多一次 HTTP，且有些引擎
  /// 会因此重置任务状态）。这里是唯一的收口点：第二次调用直接等第一次的结果。
  Future<void> _start(
    QueueJob job, {
    required String magnet,
    List<int>? onlyFiles,
  }) {
    final Future<void>? inflight = _starting[job.id];
    if (inflight != null) return inflight;
    late final Future<void> attempt;
    attempt = _doStart(job, magnet: magnet, onlyFiles: onlyFiles).whenComplete(() {
      // 摘掉 in-flight 记录：返回值是 Map 里存着的那个 Future（调用方正在 await
      // 它），不是丢了一个没人等的任务。
      // ignore: discarded_futures
      if (identical(_starting[job.id], attempt)) _starting.remove(job.id);
    });
    _starting[job.id] = attempt;
    return attempt;
  }

  Future<void> _doStart(
    QueueJob job, {
    required String magnet,
    List<int>? onlyFiles,
  }) async {
    _deferred.remove(job.id); // 真的开始下了：不再算「等用户决定」
    job.state = JobState.downloading;
    job.attempts += 1;
    job.updatedAt = _clock();
    job.error = null;
    await _persist();
    _emit();
    try {
      final added = await engine.addMagnet(
        magnet,
        name: job.item.title,
        onlyFiles: onlyFiles,
        subFolder: job.saveSubFolder,
      );
      job.engineId = added.id;
      job.fileIndex = added.playableFileIndex;
      if (job.item.infoHash == null && added.infoHash != null) {
        job.item = job.item.copyWith(infoHash: added.infoHash);
      }
      if (job.fileIndex == null) {
        job.state = JobState.failed;
        job.error = '种子内没有可识别的视频文件（${added.files.length} 个文件）';
      }
    } catch (e) {
      job.state = JobState.failed;
      job.error = _startFailureText(e);
    }
    job.updatedAt = _clock();
    await _persist();
    _emit();
  }

  /// 「加种失败」给用户看的一句话（第四十二轮 UX #7）。
  ///
  /// 旧实现是 `job.error = 'addMagnet 失败: $e'`，界面上那一行就是
  /// `错误：addMagnet 失败: EngineException[504]: metadata_timeout (POST http://…)`，
  /// 后面还可能跟着「响应体: …」「原因: …」好几行。失败的任务**没有别的信息源**
  /// （这就是那一行存在的全部意义），所以它必须是"发生了什么 + 怎么办"：
  /// * 504（元数据超时）几乎是磁力太冷门/没人做种，用户能做的是换一条种子；
  /// * 401/403 是边车 token 不对，重启边车就好；
  /// * 404 是接口对不上，多半是 exe 不是随包那个。
  /// 认不出的异常只留**第一行**并截断 —— 不把库内部结构倒给用户。
  String _startFailureText(Object e) {
    final String first = e.toString().split('\n').first.trim();
    final RegExpMatch? m =
        RegExp(r'^EngineException\[(\d+)\]:\s*(.*)$').firstMatch(first);
    if (m != null) {
      final int code = int.parse(m.group(1)!);
      final String why = _shorten(m.group(2)!);
      return switch (code) {
        504 => '拿不到种子元数据（引擎等超时了）：这一步要连上做种者，'
            '磁力太冷门或没人做种就会失败 —— 换一条种子，或稍后再试',
        401 || 403 => '边车拒绝了这次加种（HTTP $code）：到「设置 → 引擎」重启一次边车',
        404 => '边车不认这个接口（HTTP 404）：版本可能对不上，'
            '到「设置 → 引擎」确认用的是随包的 rqbit-engine.exe',
        _ => '加种失败（HTTP $code）：$why',
      };
    }
    return '加种失败：${_shorten(first)}';
  }

  static String _shorten(String raw, {int max = 140}) {
    final String oneLine = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
    return oneLine.length <= max ? oneLine : '${oneLine.substring(0, max)}…';
  }

  /// 本集下完 → 继续把后面的补到"档位那么多"（第三十八轮：从 1 集变成 N 集）。
  Future<void> _maybePrefetch(QueueJob completed) async {
    if (_policy.effectivePreheatAhead <= 0) return;
    if (completed.subscriptionId.isEmpty) return;
    if (_policy.isExcluded(completed.item.title)) return;
    await preheat(
      completed.subscriptionId,
      afterItemId: completed.item.id,
    );
  }

  bool _hasOpenJob(String itemId) {
    for (final job in _jobs) {
      if (job.item.id != itemId) continue;
      switch (job.state) {
        case JobState.queued:
        case JobState.downloading:
        case JobState.paused:
        case JobState.completed:
          return true;
        case JobState.failed:
        case JobState.cancelled:
          break;
      }
    }
    return false;
  }

  /// 正在下载的**用户任务**数（预热任务不算，见 [pump] 里的说明）。
  int _countUserDownloading() => _jobs
      .where((QueueJob j) => j.state == JobState.downloading && !j.isPrefetch)
      .length;

  /// 取 `queued` 中 priority 最小、再按 createdAt 最旧；同时应用省流量策略。
  QueueJob? _nextQueued() {
    final candidates = _jobs.where(_isStartable).toList();
    if (candidates.isEmpty) return null;
    candidates.sort((QueueJob a, QueueJob b) {
      final byPriority = a.priority.compareTo(b.priority);
      if (byPriority != 0) return byPriority;
      final byCreated = a.createdAt.compareTo(b.createdAt);
      if (byCreated != 0) return byCreated;
      return a.id.compareTo(b.id);
    });
    return candidates.first;
  }

  bool _isStartable(QueueJob job) {
    if (job.state != JobState.queued) return false;
    // 重启恢复出来的任务：只有用户点过「继续」才会从这里出去（见 resumeJob / _start）。
    if (_deferred.contains(job.id)) return false;
    if (!job.isPrefetch) return true;
    if (_policy.effectivePreheatAhead <= 0) {
      // 省流量（默认档）：只允许「当前正在播的那一集」。
      return _playingItemId != null && job.item.id == _playingItemId;
    }
    if (_policy.isExcluded(job.item.title)) return false;
    if (_policy.isExcluded(job.subscriptionId)) return false;
    return true;
  }

  /// 单一集数（`01` / `S01E02`）；合集或识别不出返回 null。
  static int? _episodeNumber(SourceItem item) {
    final hints = item.episodeHints;
    if (hints.length != 1) return null;
    final hint = hints.first;
    final season = RegExp(r'^S(\d{1,2})E(\d{1,3})$').firstMatch(hint);
    if (season != null) {
      return int.parse(season.group(1)!) * 1000 + int.parse(season.group(2)!);
    }
    return int.tryParse(hint);
  }

  String _nextId() {
    final custom = idGenerator;
    if (custom != null) return custom();
    _idSeq++;
    return 'job-${_clock().microsecondsSinceEpoch}-$_idSeq';
  }

  Future<void> _afterMutation() async {
    await _persist();
    _emit();
    if (autoPump) unawaited(pump());
  }

  Future<void> _persist() =>
      store.put(jobsKey, _jobs.map((QueueJob j) => j.toJson()).toList());

  void _emit() {
    if (_changes.isClosed) return;
    _changes.add(List<QueueJob>.unmodifiable(_jobs));
  }
}
