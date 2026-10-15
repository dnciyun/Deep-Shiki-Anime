/// **core 引擎适配层**：把 `dsanima_core` 的 `EngineRuntime`（进程 + HTTP/SSE）
/// 接到宿主的 `EnginePort` / `EngineBootstrapPort` 上。
///
/// ⚠️ 只有 `main.dart`（装配根）可以 import 本文件。
/// UI / state 层一律只依赖 `domain/ports.dart` 的抽象：
/// 这样上游 `core/lib/engine/` 正在重构时，宿主的 `flutter analyze`、
/// widget 测试仍然能独立跑绿（并行开发的硬要求）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsanima_core/dsanima_core.dart' as core;
import 'package:path/path.dart' as p;

import '../domain/download_dir.dart';
import '../domain/models.dart';
import '../domain/ports.dart';

/// 边车运行期的持有者（可为空）。
///
/// 两种来源：
/// * **本进程拉起的**（`EngineRuntime`，退出时 `dispose`）；
/// * **接管已在运行的**（spec §7.3 Q14：下次启动自动接管，不得起两个；
///   退出时用 `POST /shutdown` 优雅停）。
///
/// 用可变持有者而不是把运行期塞进 provider：设置页改完下载目录/限速后要能
/// **换一个**运行期实例，而 `ProviderScope` 的 override 是启动时固定的。
class EngineRuntimeHolder {
  core.EngineRuntime? _runtime;
  core.EngineClient? _adopted;

  final StreamController<void> _attached = StreamController<void>.broadcast();

  core.EngineClient? get client => _runtime?.client ?? _adopted;

  /// 运行期是否已就绪（自建或接管都算）。
  bool get isAttached => client != null;

  /// 是否是接管来的（UI/日志用）。
  bool get isAdopted => _runtime == null && _adopted != null;

  /// 「运行期接上了」的信号（自建或接管都算；换运行期会再发一次）。
  ///
  /// 为什么必须有这条信号（用户 2026-10-12 第 9 轮：「下载100%了还是不完成」）：
  /// `main.dart` 在**边车启动之前**就 `await hostData.init()` → `queue.start()`
  /// 订阅进度流，那一刻 [client] 还是 null；而 `QueueManager.start()` 是
  /// `_progressSub ??=`，**再也不会重建订阅**。旧实现此时拿到的是一个
  /// `Stream.error`，于是引擎之后发多少「已完成」事件队列都收不到 —— 任务永远停在
  /// 「下载中」，预取下一集也一起失效（真机证据：引擎 09:24:23 报 torrent finished，
  /// 队列那条任务的 `updatedAt` 停在 09:22:30 再没动过）。
  /// 有了这条信号，队列的进度订阅可以在**边车就绪 / 换运行期**时自动接上。
  Stream<void> get onAttach => _attached.stream;

  void attach(core.EngineRuntime runtime) {
    _runtime = runtime;
    _adopted = null;
    _notifyAttached();
  }

  void attachAdopted(core.EngineClient client) {
    _adopted = client;
    _runtime = null;
    _notifyAttached();
  }

  Uri? streamUrl(int id, int fileIndex) => client?.streamUrl(id, fileIndex);

  /// 停掉并摘掉当前运行期（幂等）。
  Future<void> detach() async {
    final core.EngineRuntime? rt = _runtime;
    final core.EngineClient? ad = _adopted;
    _runtime = null;
    _adopted = null;
    if (rt != null) {
      try {
        await rt.dispose();
      } catch (_) {
        // 收尾失败不改变「已摘掉」这个事实；进程若还在，下次启动会另起一个。
      }
      return;
    }
    if (ad != null) {
      try {
        await ad.shutdown();
      } catch (_) {
        // 边车没实现 /shutdown 时忽略：进程不归我们拉，无权限杀。
      }
      ad.close();
    }
  }

  void _notifyAttached() {
    if (_attached.isClosed) return;
    _attached.add(null);
  }
}

/// 「引擎可能还没就绪」的流包装：接上之前等待、接上之后转发，换运行期自动换源。
///
/// 关键性质（每条都有用例，见 `app/test/engine_progress_test.dart`）：
/// * 订阅时 `clientOf()` 为 null → **不报错、不结束**，等 `reattachSignals` 来了再接；
/// * 订阅时已经就绪 → 立刻接上，不用等下一次信号；
/// * 换运行期（设置页重启边车 / 下次启动接管）→ 取消上一个内层订阅，接新的；
/// * 内层流报错或结束（边车被杀、SSE 断开）→ 外层继续活着，等下一次信号。
///
/// 泛型 `C` 只为可测：真实调用是 `core.EngineClient`，测试里用假类型即可，
/// 不必起边车。
Stream<T> resilientEngineStream<T, C extends Object>({
  required C? Function() clientOf,
  required Stream<void> reattachSignals,
  required Stream<T> Function(C client) open,
}) {
  late final StreamController<T> out;
  StreamSubscription<T>? inner;
  StreamSubscription<void>? signals;
  C? current;

  void connect() {
    final C? client = clientOf();
    if (client == null || identical(client, current)) return;
    current = client;
    unawaited(inner?.cancel());
    inner = open(client).listen(
      out.add,
      onError: (Object _) => current = null,
      onDone: () => current = null,
    );
  }

  out = StreamController<T>(
    onListen: () {
      signals = reattachSignals.listen((void _) => connect());
      connect();
    },
    onCancel: () async {
      await signals?.cancel();
      await inner?.cancel();
    },
  );
  return out.stream;
}

const PortUnavailableException _notConnected = PortUnavailableException(
  '引擎未连接：rqbit-engine 边车没有在运行',
  hint: '到「设置 → 引擎」确认 exe 路径与下载目录，然后点「启动 / 重连引擎」',
);

/// `EnginePort` 的真实实现（core `EngineRuntime`）。
class CoreEnginePort implements EnginePort {
  CoreEnginePort(this._holder);

  final EngineRuntimeHolder _holder;

  core.EngineClient? get _client => _holder.client;

  core.EngineClient _requireClient() {
    final core.EngineClient? client = _client;
    if (client == null) throw _notConnected;
    return client;
  }

  @override
  Future<EngineHealthView> health() async {
    final core.EngineHealth health = await _requireClient().health();
    return EngineHealthView(
      ok: health.ok,
      version: health.version ?? '',
      sessions: health.sessions,
    );
  }

  @override
  Future<EngineTorrentView> addMagnet(
    String magnet, {
    String? name,
    List<int>? onlyFiles,
    bool startPaused = false,
    String? subFolder,
  }) async {
    final core.EngineAddResult result = await _requireClient().addMagnet(
      magnet,
      name: name,
      onlyFiles: onlyFiles,
      startPaused: startPaused,
      subFolder: subFolder,
    );
    return _requireReady(result);
  }

  /// 三种形态分开处理——**不能**把「还没就绪」当成成功（spec §3.5）。
  EngineTorrentView _requireReady(core.EngineAddResult result) {
    final core.EngineTorrent? torrent = result.torrent;
    if (torrent != null) return toView(torrent);
    final String hash = result.infoHash == null ? '' : '（info hash ${result.infoHash}）';
    return switch (result) {
      core.EngineAddResolving() => throw PortUnavailableException(
        '元数据还在获取中，暂时没有文件列表$hash',
        hint:
            '磁力链首次连 peer 可能需要十几秒到两分钟；稍后重试，'
            '或到「队列」页等它出现后再点播',
      ),
      core.EngineAddTimedOut() => throw PortUnavailableException(
        '等待元数据超时$hash',
        hint:
            '任务仍在后台继续找元数据；稍后重试通常能直接命中缓存。'
            '长期无进展就换一条更新鲜（或热度更高）的结果',
      ),
      _ => throw PortUnavailableException(
        '引擎没有给出可用的种子$hash',
        hint: '稍后重试；若持续出现，请把「设置 → 引擎」下方的日志发出来',
      ),
    };
  }

  @override
  Future<List<EngineTorrentView>> list() async {
    final List<core.EngineTorrent> torrents = await _requireClient().list();
    return torrents.map(toView).toList(growable: false);
  }

  @override
  Future<void> pause(int id) => _requireClient().pause(id);

  @override
  Future<void> resume(int id) => _requireClient().resume(id);

  @override
  Future<void> remove(int id, {bool deleteFiles = false}) =>
      _requireClient().remove(id, deleteFiles: deleteFiles);

  @override
  Stream<List<EngineTorrentView>> watch() {
    final core.EngineClient? client = _client;
    if (client == null) {
      // ⚠️ 这里**故意**保留「未连接就报错」：UI 要的是可行动错误 + 重试按钮
      //（「已完成」页的 onRetry 就是 `ref.invalidate(engineTorrentsProvider)`），
      // 而 UI 这个订阅本来就建在边车就绪之后（就绪时 start() 会 invalidate 重订）。
      // 队列那条订阅相反：它建在边车之前且**不会重建**，所以那边走自愈包装
      //（见 [QueueEngineBridge.progress] 与 [resilientEngineStream]）。
      return Stream<List<EngineTorrentView>>.error(_notConnected);
    }
    return engineSnapshotStream(client);
  }

  @override
  Uri? streamUrl(int id, int fileIndex) => _holder.streamUrl(id, fileIndex);
}

/// SSE → 全量快照列表（`snapshot` 可重复；`progress` 按索引合并）。
///
/// 顶层函数而不是 [CoreEnginePort] 的私有方法：队列那条进度流也要用同一份解析
/// （否则两处各写一遍，迟早走偏）。调用方负责保证 `client` 非空。
Stream<List<EngineTorrentView>> engineSnapshotStream(core.EngineClient client) async* {
  final Map<int, core.EngineTorrent> current = <int, core.EngineTorrent>{};
  await for (final core.EngineEvent event in client.events()) {
    bool changed = true;
    switch (event) {
      case core.EngineSnapshot snapshot:
        current
          ..clear()
          ..addEntries(
            snapshot.torrents.map(
              (core.EngineTorrent t) => MapEntry<int, core.EngineTorrent>(t.id, t),
            ),
          );
      case core.EngineTorrentAdded added:
        current[added.torrent.id] = added.torrent;
      case core.EngineTorrentRemoved removed:
        current.remove(removed.id);
      case core.EngineProgress progress:
        final core.EngineTorrent? existing = current[progress.id];
        if (existing == null) {
          changed = false; // 没见过这个 torrent：等 snapshot/added 补全文件列表
        } else {
          current[progress.id] = existing.applyProgress(progress);
        }
      case core.EngineStateChanged stateChanged:
        // 状态事件不带文件列表，回查一次 `GET /torrents/{id}`。
        try {
          current[stateChanged.id] = await client.get(stateChanged.id);
        } catch (_) {
          changed = false;
        }
      case core.EngineHeartbeat():
        changed = false;
    }
    if (changed) yield sortedTorrentViews(current.values);
  }
}

/// 引擎侧 torrent → 视图列表（按 id 升序，顺序稳定便于 UI diff）。
List<EngineTorrentView> sortedTorrentViews(Iterable<core.EngineTorrent> torrents) {
  final List<EngineTorrentView> views = torrents.map(toView).toList(growable: false);
  views.sort((EngineTorrentView a, EngineTorrentView b) => a.id.compareTo(b.id));
  return List<EngineTorrentView>.unmodifiable(views);
}

/// core 模型 → 宿主视图模型（字段名一致，纯搬运）。
EngineTorrentView toView(core.EngineTorrent t) => EngineTorrentView(
  id: t.id,
  infoHash: t.infoHash,
  name: t.name,
  state: switch (t.state) {
    core.EngineTorrentState.initializing => TorrentState.initializing,
    core.EngineTorrentState.live => TorrentState.live,
    core.EngineTorrentState.paused => TorrentState.paused,
    core.EngineTorrentState.error => TorrentState.error,
  },
  error: t.error,
  totalBytes: t.totalBytes,
  progressBytes: t.progressBytes,
  uploadedBytes: t.uploadedBytes,
  downloadBps: t.downloadBps,
  uploadBps: t.uploadBps,
  peers: t.peers,
  progress: t.progress,
  finished: t.finished,
  outputFolder: t.outputFolder ?? '',
  files: t.files
      .map(
        (core.EngineFile f) => EngineFileView(
          index: f.index,
          path: f.path,
          length: f.length,
          downloaded: f.downloaded,
          progress: f.progress,
          included: f.included,
          mime: f.mime,
          isVideo: f.isVideo,
          complete: f.complete,
        ),
      )
      .toList(growable: false),
);

/// **队列用的引擎端口**（core `TorrentEnginePort`）实现。
///
/// 和 [CoreEnginePort] 的区别：队列需要「元数据没就绪时**等** SSE
/// `torrent_added`」的语义，而不是立刻失败——否则磁力链首连稍慢就会被判失败。
/// 这里用 core 冻结的 `waitForTorrent` 等就绪；超时给可行动文案。
class QueueEngineBridge implements core.TorrentEnginePort {
  QueueEngineBridge(this._holder);

  final EngineRuntimeHolder _holder;

  core.EngineClient _requireClient() {
    final core.EngineClient? client = _holder.client;
    if (client == null) throw _notConnected;
    return client;
  }

  @override
  Future<core.EngineAddedTorrent> addMagnet(
    String magnet, {
    String? name,
    List<int>? onlyFiles,
    bool startPaused = false,
    String? subFolder,
  }) async {
    final core.EngineClient client = _requireClient();
    final core.EngineAddResult result = await client.addMagnet(
      magnet,
      name: name,
      onlyFiles: onlyFiles,
      startPaused: startPaused,
      subFolder: subFolder,
    );
    final core.EngineTorrent? ready = result.torrent;
    if (ready != null) return _toAdded(ready);

    // 504 但 body 带了 id（phase == initializing）：元数据已到手，直接轮询到 live。
    final int? knownId = result.engineId;
    if (knownId != null) {
      final DateTime deadline = DateTime.now().add(const Duration(seconds: 60));
      while (DateTime.now().isBefore(deadline)) {
        final core.EngineTorrent torrent = await client.get(knownId);
        if (torrent.state != core.EngineTorrentState.initializing) {
          return _toAdded(torrent);
        }
        await Future<void>.delayed(const Duration(milliseconds: 700));
      }
    }

    // 否则等 SSE `torrent_added`（core 冻结的 waitForTorrent）。
    final String? hash = result.infoHash;
    if (hash == null || hash.isEmpty) {
      throw PortUnavailableException(
        '引擎没有返回 info hash，无法等待元数据就绪',
        hint: '稍后重试；若持续出现请把「设置 → 引擎」下方的日志发出来',
      );
    }
    try {
      final core.EngineTorrent torrent = await client.waitForTorrent(
        hash,
        timeout: const Duration(seconds: 120),
      );
      return _toAdded(torrent);
    } catch (error) {
      throw PortUnavailableException(
        '等待元数据超时（$hash）',
        hint:
            '磁力链可能缺 tracker / 没有可连的 peer；'
            '可以在「设置 → 引擎」一键写入内置 tracker 后重试，或换一条更新鲜的结果',
      );
    }
  }

  core.EngineAddedTorrent _toAdded(core.EngineTorrent torrent) => core.EngineAddedTorrent(
    id: torrent.id,
    infoHash: torrent.infoHash.isEmpty ? null : torrent.infoHash,
    name: torrent.name,
    files: torrent.files
        .map(
          (core.EngineFile f) => core.EngineFileInfo(
            index: f.index,
            path: f.path,
            length: f.length,
            isVideo: f.isVideo,
            included: f.included,
          ),
        )
        .toList(growable: false),
  );

  @override
  Future<List<core.EngineTorrentRef>> listTorrents() async {
    final List<core.EngineTorrent> torrents = await _requireClient().list();
    return torrents
        .map(
          (core.EngineTorrent t) => core.EngineTorrentRef(
            id: t.id,
            infoHash: t.infoHash.isEmpty ? null : t.infoHash,
            name: t.name,
            // 对账要靠这两个字段判「引擎说下完了」（用户 2026-10-12 第 9 轮）。
            finished: t.finished,
            progress: t.progress,
            // 「不做种」的对账还要分清"已经停过的"和"还在跑的"（第十二轮）。
            paused: t.state == core.EngineTorrentState.paused,
          ),
        )
        .toList(growable: false);
  }

  @override
  Future<void> pause(int id) => _requireClient().pause(id);

  @override
  Future<void> resume(int id) => _requireClient().resume(id);

  @override
  Future<void> remove(int id, {bool deleteFiles = false}) =>
      _requireClient().remove(id, deleteFiles: deleteFiles);

  @override
  Uri streamUrl(int id, int fileIndex) {
    final Uri? url = _holder.streamUrl(id, fileIndex);
    if (url == null) throw _notConnected;
    return url;
  }

  /// SSE → core 的进度 tick（「本集下完」判据见 core `QueueManager.onProgress`）。
  ///
  /// ## 为什么包一层 [resilientEngineStream]（用户 2026-10-12 第 9 轮）
  /// 这条流是 [core.QueueManager.start] 订阅的，而 `start()` 在
  /// **边车启动之前**就被调用（`main.dart` 先 `await hostData.init()`，之后才
  /// `engineBootstrapProvider.start()`），且 `QueueManager.start()` 用 `??=` 记着订阅
  /// ——**一辈子只订一次**。旧实现此时 `_holder.client == null`，直接拿到一个
  /// `Stream.error`：于是整个会话里引擎发多少「已完成」事件队列都收不到，
  /// 任务永远停在「下载中」（真机证据：引擎 09:24:23 报 torrent finished，队列那条
  /// 任务的 `updatedAt` 停在 09:22:30 再没动过；首页卡片读的是另一个订阅，所以显示
  /// 「下载中 100%」）。现在：没就绪就等，边车接上/换运行期自动接上新的一条。
  @override
  Stream<core.EngineProgressTick> progress() =>
      resilientEngineStream<core.EngineProgressTick, core.EngineClient>(
        clientOf: () => _holder.client,
        reattachSignals: _holder.onAttach,
        open: _ticksOf,
      );

  /// 一个运行期的 SSE → 进度 tick。
  ///
  /// 一个 tick 只能带一个 torrent：取「最近有变化」的语义做不到，
  /// 因此这里逐个发（队列按 id 匹配，多余的会被忽略）。
  Stream<core.EngineProgressTick> _ticksOf(core.EngineClient client) =>
      engineSnapshotStream(client).expand(
        (List<EngineTorrentView> torrents) => torrents.map(_toTick),
      );
}

core.EngineProgressTick _toTick(EngineTorrentView t) => core.EngineProgressTick(
  id: t.id,
  infoHash: t.infoHash.isEmpty ? null : t.infoHash,
  progressBytes: t.progressBytes,
  totalBytes: t.totalBytes,
  downloadBps: t.downloadBps.round(),
  uploadBps: t.uploadBps.round(),
  peers: t.peers,
  finished: t.finished,
  // 「不做种」靠它幂等：引擎每次进度事件都会重发状态，队列据此只停一次
  //（用户 2026-10-12 第十二轮：关着做种却一直在上传）。
  paused: t.state == TorrentState.paused,
  completedFiles: <int>{
    for (final EngineFileView f in t.files)
      if (f.complete) f.index,
  },
);

/// `EngineBootstrapPort` 的真实实现：定位 exe → 拉起进程 → 等 runtime.json 就绪。
class CoreEngineBootstrap implements EngineBootstrapPort {
  CoreEngineBootstrap(this._holder);

  final EngineRuntimeHolder _holder;

  @override
  bool get isRunning => _holder.isAttached;

  @override
  Future<EngineStartOutcome> start({
    required AppSettings settings,
    required Directory supportDir,
  }) async {
    // 用户 2026-10-11：「下载目录默认在 C:\Users\<用户名>\Downloads\Anime」——
    // 设置里没填就**用默认目录**，不再拦着用户先去设置页填一遍。
    // 只有连默认目录都解析不出来（没有 USERPROFILE / HOMEDRIVE+HOMEPATH 的老系统）
    // 才维持原来那条可行动报错：不猜盘符，也不假装有目录。
    final String downloadDir = effectiveDownloadDir(settings.downloadDir);
    if (downloadDir.isEmpty) {
      return EngineStartOutcome.failure('还没有设置下载目录，引擎无法启动', hint: '到「设置 → 引擎」选择下载目录（或用首启向导的第二步）');
    }

    // ① **先定位 exe**（纯查询，不动任何正在运行的东西）。
    //
    // ⚠️ 顺序是有意的：`detach()` 是真的把正在跑的边车停掉。旧顺序是"先 detach 再
    // locate"，于是用户在设置里把路径改错一次并保存 → locate 抛错 → 返回 failure，
    // 而旧引擎已经被停掉、也没有回滚：用户看到的是"改了个错路径，引擎直接没了"。
    // 定位失败必须在 detach **之前**返回，旧引擎原样留着继续跑。
    final String exePath;
    try {
      exePath = core.EngineLocator().locate(exePath: settings.enginePath);
    } catch (error) {
      final String message = error.toString();
      return EngineStartOutcome.failure(
        message,
        hint: message.contains('未找到')
            ? '把 rqbit-engine.exe 放到应用目录，或在「设置 → 引擎」手填绝对路径'
                '（正在运行的引擎保持原状，没有被停掉）'
            : '检查「设置 → 引擎」里的路径是否指向真实存在的 rqbit-engine.exe'
                '（正在运行的引擎保持原状，没有被停掉）',
      );
    }

    await _holder.detach();
    final DateTime startedAt = DateTime.now();
    final Directory stateDir = Directory(p.join(supportDir.path, 'engine'));
    try {
      // ② 先试**接管**已在运行的边车（spec §7.3 Q14：不得起两个）。
      final core.EngineClient? adopted = await _tryAdopt(stateDir);
      if (adopted != null) {
        _holder.attachAdopted(adopted);
        return EngineStartOutcome(
          ok: true,
          exePath: '（接管已在运行的引擎 ${adopted.baseUrl}）',
          startup: DateTime.now().difference(startedAt),
          baseUrl: adopted.baseUrl.toString(),
        );
      }
      // ③ 没有在跑的，才自己拉起（exePath 已在上面定位好，失败也不会走到这里）。
      final List<String> extraArgs = <String>[
        '--seed-ratio',
        settings.seedRatio.toString(),
        '--upload-limit-kbps',
        '${settings.uploadLimitKbps}',
        '--download-limit-kbps',
        '${settings.downloadLimitKbps}',
        if (settings.extraTrackers.trim().isNotEmpty) ...<String>[
          '--trackers',
          settings.extraTrackers.trim(),
        ],
        '--log-file',
        p.join(stateDir.path, 'engine.log'),
      ];
      // 兜底：命令行里**绝不能出现空字符串**。clap 会把空参数当成「多余的位置参数」
      // 直接报 `unexpected argument "" found` 并 exit=2，引擎永远起不来
      // （实测踩到过：`--trackers ""` 就足以让边车启动失败，而 UI 只显示「连接中」）。
      // 这里统一剔除，避免任何上游拼参失误再次演变成「引擎起不来」。
      final List<String> safeArgs = extraArgs
          .where((String a) => a.trim().isNotEmpty)
          .toList(growable: false);
      final core.EngineRuntime runtime = await core.EngineRuntime.launch(
        exePath: exePath,
        downloadDir: downloadDir,
        stateDir: stateDir.path,
        extraArgs: safeArgs,
      );
      _holder.attach(runtime);
      return EngineStartOutcome(
        ok: true,
        exePath: exePath,
        startup: DateTime.now().difference(startedAt),
        baseUrl: runtime.client.baseUrl.toString(),
      );
    } catch (error) {
      // EngineLocator / EngineStartException 都自带可行动信息。
      final String message = error.toString();
      final String hint = message.contains('未找到')
          ? '把 rqbit-engine.exe 放到应用目录，或在「设置 → 引擎」手填绝对路径'
          : '看「设置 → 引擎」下方的错误详情；边车日志在 <支持目录>/engine/engine.log';
      return EngineStartOutcome.failure(message, hint: hint);
    }
  }

  /// 读 `runtime.json` 并探活；成功返回可用的客户端（**不新起进程**）。
  Future<core.EngineClient?> _tryAdopt(Directory stateDir) async {
    final File runtimeFile = File(p.join(stateDir.path, 'runtime.json'));
    core.EngineClient? client;
    try {
      if (!await runtimeFile.exists()) return null;
      final Object? decoded = jsonDecode(await runtimeFile.readAsString());
      if (decoded is! Map) return null;
      final core.EngineRuntimeInfo info = core.EngineRuntimeInfo.fromJson(
        decoded.cast<String, dynamic>(),
      );
      client = core.EngineClient(baseUrl: info.baseUrl, token: info.token);
      final core.EngineHealth health = await client.health().timeout(const Duration(seconds: 3));
      if (!health.ok) {
        client.close();
        return null;
      }
      return client;
    } catch (_) {
      // 残留/损坏的 runtime.json：当作「没有在跑的引擎」，继续自己拉起。
      client?.close();
      return null;
    }
  }

  @override
  Future<void> stop() => _holder.detach();
}
