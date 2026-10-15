/// 引擎 HTTP + SSE 客户端（spec §3：边车契约；§4.1：Dart 侧接口）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io' show SocketException;

import 'package:http/http.dart' as http;

import 'json_tools.dart';
import 'models.dart';
import 'sse.dart';

/// `POST /torrents` 的默认请求超时。
///
/// 边车自己等元数据默认 120s（超时返回 504），所以客户端必须留出余量，
/// 否则磁力链还在找 peer 的时候就被我们自己的超时掐断。
const Duration kDefaultMetadataRequestTimeout = Duration(seconds: 130);

/// 引擎的默认请求超时（普通端点）。
const Duration kDefaultRequestTimeout = Duration(seconds: 20);

/// 引擎的默认建连超时（SSE 拿响应头）。
const Duration kDefaultConnectTimeout = Duration(seconds: 15);

/// HTTP + SSE 客户端。
///
/// * 除 `GET /health` 外所有请求带 `Authorization: Bearer <token>`；
/// * 所有失败（超时/连不上/非 2xx/非 JSON）统一抛 [EngineException]，
///   **绝不返回空对象假装成功**；
/// * [events] 断线自动重连，指数退避 1s → 30s。
class EngineClient {
  EngineClient({
    required this.baseUrl,
    required this.token,
    http.Client? http,
    this.requestTimeout = kDefaultRequestTimeout,
    this.connectTimeout = kDefaultConnectTimeout,
  }) : _http = http ?? _createHttpClient(),
       _ownsHttp = http == null;

  static http.Client _createHttpClient() => http.Client();

  /// 引擎根地址（来自 runtime.json 的 `baseUrl`）。
  final Uri baseUrl;

  /// 引擎 token（来自 runtime.json 的 `token`）。
  final String token;

  /// 普通请求超时。
  final Duration requestTimeout;

  /// SSE 建连（拿响应头）超时。
  final Duration connectTimeout;

  final http.Client _http;
  final bool _ownsHttp;
  bool _closed = false;

  /// 客户端是否已关闭。
  bool get isClosed => _closed;

  // ── 端点 ────────────────────────────────────────────────────────────────

  /// `GET /health`（免鉴权）。
  Future<EngineHealth> health() async {
    final response = await _send('GET', '/health', authenticated: false);
    return EngineHealth.fromJson(_decodeObject(response, '/health'));
  }

  /// `POST /torrents`：磁力链（spec §3.5 最终契约）。
  ///
  /// 返回 [EngineAddResult]，**三种形态都不是「异常」**：
  /// * `200` → [EngineAddReady]：`id` 到手，可以直接 `streamUrl()` 播放；
  /// * `202` → [EngineAddResolving]：引擎在后台解析元数据（也可能是同一 infoHash
  ///   命中 in-flight 表），**没有 id**。**当前边车不会发 202**（engine-dev 实测：
  ///   in-flight 去重后复用同一个 200/504 结果），此分支为契约前向兼容保留；
  /// * `504 metadata_timeout` → [EngineAddTimedOut]：超时，任务仍在后台继续。
  ///   `phase == 'initializing'` 时结果里还带 `engineId`，可以直接 `get(id)` 轮询。
  ///
  /// **调用方拿到 202/504 后必须**：记下 `result.infoHash` → UI 显示解析中 →
  /// 监听 `events()` 里的 `torrent_added`（可用 [addedFrom] 过滤），
  /// 或调用 [torrentByInfoHash] / [waitForTorrent]，拿到 `id` 后再播放。
  /// 不要把 infoHash 丢掉：它是关联引擎实例的唯一钥匙。
  ///
  /// [metadataTimeout] 会作为 `metadataTimeoutMs` 传给边车（覆盖其默认值），
  /// 同时请求超时取 `metadataTimeout + 10s`。
  Future<EngineAddResult> addMagnet(
    String magnet, {
    String? name,
    List<int>? onlyFiles,
    bool startPaused = false,
    String? subFolder,
    Duration? metadataTimeout,
  }) {
    final trimmed = magnet.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError.value(magnet, 'magnet', '磁力链不能为空');
    }
    return _addTorrent(
      <String, Object?>{
        'magnet': trimmed,
        if (name != null && name.isNotEmpty) 'name': name,
        'onlyFiles': ?onlyFiles,
        'startPaused': startPaused,
        if (subFolder != null && subFolder.isNotEmpty) 'subFolder': subFolder,
        if (metadataTimeout != null)
          'metadataTimeoutMs': metadataTimeout.inMilliseconds,
      },
      timeout: metadataTimeout == null
          ? kDefaultMetadataRequestTimeout
          : metadataTimeout + const Duration(seconds: 10),
    );
  }

  /// `POST /torrents`：`.torrent` 原始字节（base64 上传）。语义同 [addMagnet]。
  Future<EngineAddResult> addTorrentBytes(
    List<int> bytes, {
    String? name,
    List<int>? onlyFiles,
    bool startPaused = false,
    String? subFolder,
    Duration? metadataTimeout,
  }) {
    if (bytes.isEmpty) {
      throw ArgumentError.value(bytes, 'bytes', '.torrent 字节不能为空');
    }
    return _addTorrent(
      <String, Object?>{
        'torrentBase64': base64Encode(bytes),
        if (name != null && name.isNotEmpty) 'name': name,
        'onlyFiles': ?onlyFiles,
        'startPaused': startPaused,
        if (subFolder != null && subFolder.isNotEmpty) 'subFolder': subFolder,
        if (metadataTimeout != null)
          'metadataTimeoutMs': metadataTimeout.inMilliseconds,
      },
      timeout: metadataTimeout == null
          ? kDefaultMetadataRequestTimeout
          : metadataTimeout + const Duration(seconds: 10),
    );
  }

  /// 解析 `POST /torrents` 的 200 / 202 / 504 三种形态。
  ///
  /// 其他状态码（含 500、504 但 `error != metadata_timeout`）仍然抛
  /// [EngineException]——不能把真正的失败伪装成「解析中」。
  Future<EngineAddResult> _addTorrent(
    Map<String, Object?> payload, {
    required Duration timeout,
  }) async {
    final response = await _send(
      'POST',
      '/torrents',
      body: payload,
      timeout: timeout,
      acceptStatuses: const <int>{202, 504},
    );
    switch (response.statusCode) {
      case 202:
        final map = _decodeObject(response, '/torrents');
        final infoHash = jsonString(map['infoHash']);
        final status = jsonString(map['status']);
        if (status != 'resolving' && infoHash == null) {
          throw EngineException(
            '引擎返回 202 但既没有 status=resolving 也没有 infoHash，无法关联后续事件：'
            '${_snippet(response.body)}',
            statusCode: 202,
            uri: response.request?.url,
            method: 'POST',
          );
        }
        return EngineAddResolving(
          infoHash: infoHash,
          phase: jsonString(map['phase']),
        );
      case 504:
        final Object? decoded;
        try {
          decoded = jsonDecode(response.body.trim());
        } on FormatException {
          throw EngineException(
            '引擎返回 504 但响应体不是 JSON，无法确认是元数据超时：'
            '${_snippet(response.body)}',
            statusCode: 504,
            uri: response.request?.url,
            method: 'POST',
            body: _snippet(response.body),
          );
        }
        final map = jsonMap(decoded);
        final error = map == null ? null : jsonString(map['error']);
        if (error != 'metadata_timeout') {
          throw EngineException(
            '引擎返回 504（error=${error ?? '未知'}）而不是 metadata_timeout',
            statusCode: 504,
            uri: response.request?.url,
            method: 'POST',
            body: _snippet(response.body),
          );
        }
        return EngineAddTimedOut(
          infoHash: map == null ? null : jsonString(map['infoHash']),
          phase: map == null ? null : jsonString(map['phase']),
          // phase=initializing 时边车会带上 id，可直接 get(id) 轮询。
          id: map == null || map['id'] == null ? null : jsonInt(map['id']),
          metadataTimeoutMs: map == null
              ? null
              : jsonInt(map['metadataTimeoutMs']),
        );
      default:
        final map = _decodeObject(response, '/torrents');
        return EngineAddReady(EngineTorrent.fromJson(map));
    }
  }

  /// `GET /torrents`。
  Future<List<EngineTorrent>> list() async {
    final response = await _send('GET', '/torrents');
    final decoded = _decodeJson(response, '/torrents');
    final List<Object?> items;
    if (decoded is List) {
      items = List<Object?>.from(decoded);
    } else {
      final map = jsonMap(decoded);
      if (map == null) {
        // 既不是数组也不是对象：这是协议错误，不能返回空列表假装成功。
        throw EngineException(
          '引擎在 /torrents 返回了既不是数组也不是对象的 JSON：${_snippet(response.body)}',
          statusCode: response.statusCode,
          uri: response.request?.url,
          method: response.request?.method,
        );
      }
      items = jsonList(map['torrents']);
    }
    final torrents = <EngineTorrent>[];
    for (final raw in items) {
      final map = jsonMap(raw);
      if (map != null) torrents.add(EngineTorrent.fromJson(map));
    }
    return List<EngineTorrent>.unmodifiable(torrents);
  }

  /// `GET /torrents/{id}`（含 `files[]`）。
  Future<EngineTorrent> get(int id) async {
    final response = await _send('GET', '/torrents/$id');
    return EngineTorrent.fromJson(_decodeObject(response, '/torrents/$id'));
  }

  /// `GET /torrents/{infoHash}`（重启后按 infoHash 对齐用）。
  ///
  /// 接受 **40 位十六进制**（自动小写化）或 **32 位 base32**（原样使用，边车用
  /// `TorrentIdOrHash::parse` 两种都认）。格式不合法抛 [ArgumentError]，不会发请求。
  ///
  /// 边车对「不存在」返回 `404 no_such_torrent`，对「格式非法」返回
  /// `400 bad_id`——两者含义不同，[torrentByInfoHash] 只把 404 映射成 `null`。
  Future<EngineTorrent> getByHash(String infoHash) async {
    final raw = infoHash.trim();
    final String hash;
    if (_hexInfoHash.hasMatch(raw.toLowerCase())) {
      hash = raw.toLowerCase();
    } else if (_base32InfoHash.hasMatch(raw)) {
      hash = raw;
    } else {
      throw ArgumentError.value(
        infoHash,
        'infoHash',
        '需要 40 位十六进制或 32 位 base32 info hash',
      );
    }
    final response = await _send('GET', '/torrents/$hash');
    return EngineTorrent.fromJson(_decodeObject(response, '/torrents/$hash'));
  }

  static final RegExp _hexInfoHash = RegExp(r'^[0-9a-f]{40}$');
  static final RegExp _base32InfoHash = RegExp(r'^[a-zA-Z2-7]{32}$');

  /// `POST /torrents/{id}/pause`。
  Future<void> pause(int id) => _send('POST', '/torrents/$id/pause');

  /// `POST /torrents/{id}/resume`。
  Future<void> resume(int id) => _send('POST', '/torrents/$id/resume');

  /// `DELETE /torrents/{id}?deleteFiles=…`。
  Future<void> remove(int id, {bool deleteFiles = false}) => _send(
    'DELETE',
    '/torrents/$id',
    query: <String, String>{'deleteFiles': deleteFiles.toString()},
  );

  /// `POST /shutdown`：请求边车优雅退出。
  ///
  /// 边车若未实现该端点会返回 404，调用方（`EngineProcess.stop`）据此回退到
  /// 关 stdin / 杀进程。**不吞异常**，避免「以为停了其实没停」。
  Future<void> shutdown() => _send('POST', '/shutdown');

  /// `PATCH /limits`：设置限速（bytes/s，`0` = 不限；缺省字段表示不改）。
  ///
  /// 可选端点：边车没实现会 404，调用方自行决定是否提示。
  Future<void> setLimits({int? downloadBps, int? uploadBps}) {
    if (downloadBps == null && uploadBps == null) {
      throw ArgumentError('setLimits 至少要给 downloadBps 或 uploadBps 之一');
    }
    return _send(
      'PATCH',
      '/limits',
      body: <String, Object?>{
        'downloadBps': ?downloadBps,
        'uploadBps': ?uploadBps,
      },
    );
  }

  /// 按 infoHash 查引擎实例；**未注册（元数据还没到手）返回 `null`**，不抛 404。
  ///
  /// 202/504 之后用它轮询「解析好了没」，或者用 [waitForTorrent]。
  /// 注意：只有 404（`no_such_torrent`）会被映射成 `null`；
  /// 非法格式的 400（`bad_id`）与 5xx 照旧抛 [EngineException]。
  Future<EngineTorrent?> torrentByInfoHash(String infoHash) async {
    try {
      return await getByHash(infoHash);
    } on EngineException catch (error) {
      if (error.isNotFound) return null;
      rethrow;
    }
  }

  /// 等某个 infoHash 的元数据就绪（202/504 之后的关联路径）。
  ///
  /// 内部轮询 `/torrents/{infoHash}`（引擎在后台解析，注册后就能查到）。
  /// 超时抛 [EngineException]（可行动：提示仍可用 [torrentByInfoHash] 复查）。
  /// 也可以改用 SSE：`addedFrom(events())` 等 `torrent_added`。
  Future<EngineTorrent> waitForTorrent(
    String infoHash, {
    Duration timeout = const Duration(minutes: 5),
    Duration pollInterval = const Duration(milliseconds: 500),
    EngineSleep? sleep,
  }) async {
    final wait = sleep ?? defaultEngineSleep;
    final deadline = DateTime.now().add(timeout);
    while (true) {
      final torrent = await torrentByInfoHash(infoHash);
      if (torrent != null) return torrent;
      if (!DateTime.now().isBefore(deadline)) {
        throw EngineException(
          '等待 infoHash=$infoHash 的元数据超时（${timeout.inSeconds}s）。'
          '引擎可能仍在后台找 peer：可稍后用 torrentByInfoHash() 复查，'
          '或检查 tracker/DHT 连通性。',
          uri: _uri('/torrents/$infoHash'),
          method: 'GET',
        );
      }
      await wait(pollInterval);
    }
  }

  /// 从**已经在跑的** SSE 事件流里挑出 `torrent_added`（不新开连接）。
  ///
  /// ```dart
  /// final sse = client.events();
  /// client.addedFrom(sse).listen((added) { /* 匹配 infoHash → 拿到 id */ });
  /// ```
  static Stream<EngineTorrentAdded> addedFrom(Stream<EngineEvent> events) =>
      events
          .where((event) => event is EngineTorrentAdded)
          .cast<EngineTorrentAdded>();

  /// 交给 mpv 的播放 URL：`<baseUrl>/torrents/{id}/files/{idx}/stream?token=…`。
  ///
  /// mpv 直接拉这个 URL，所以 token 必须挂在查询参数上（spec §3.3）。
  ///
  /// 注意（spec §3.8）：边车在**未下载区间**会挂起请求而不是报错
  /// （这是 mpv seek 需要的背压），`pause` 之后已下载区间的 Range 仍可读。
  /// 宿主不要用「请求 stream 看它会不会报错」来判断文件是否可播，
  /// 要用 `EngineFile.complete` / `EngineProgress.completedFiles`。
  Uri streamUrl(int id, int fileIndex) => _uri(
    '/torrents/$id/files/$fileIndex/stream',
    <String, String>{'token': token},
  );

  // ── SSE ────────────────────────────────────────────────────────────────

  /// `GET /events`：SSE 全量进度流。
  ///
  /// 断线自动重连（指数退避 [EngineBackoff]，默认 1s → 30s），重连后边车会
  /// 立刻补发一次 `snapshot`，因此消费方要按「快照可重复」处理。
  ///
  /// 退避只在**连接健康存活**过（存活时长 ≥ [healthyConnectionAge]）之后才重置：
  /// 若「连上就断」也重置，退避永远停在 1s，等于没有退避。
  ///
  /// * 连接失败/断开不会进 `Stream.error`，而是静默重连；需要观测时传
  ///   [onDisconnect]。
  /// * 未知事件名、非法 JSON 帧被丢弃（不打断流），需要观测时传
  ///   [onUnknownEvent] / [onProtocolError]。
  /// * 取消订阅（`StreamSubscription.cancel`）立即生效：不用等完退避。
  ///   这里刻意**不用 `async*`**——`async*` 生成器只在 `yield` 处观察取消，
  ///   引擎连不上（永不 yield）时 `await subscription.cancel()` 会永久挂住。
  Stream<EngineEvent> events({
    EngineBackoff? backoff,
    EngineSleep? sleep,
    Duration healthyConnectionAge = const Duration(seconds: 20),
    void Function(Object error, Duration retryIn)? onDisconnect,
    void Function(String event, String data)? onUnknownEvent,
    void Function(String reason)? onProtocolError,
  }) {
    final effectiveBackoff = backoff ?? EngineBackoff();
    final injectedSleep = sleep;
    final stopSignal = Completer<void>();
    StreamSubscription<String>? bodySubscription;
    Completer<void>? bodyDoneCompleter;
    var stopped = false;

    /// 可被「取消订阅」立刻打断的退避等待。
    Future<void> waitOrStop(Duration duration) {
      if (stopped) return Future<void>.value();
      if (injectedSleep == null) {
        // 生产路径：可取消的 Timer，取消后不留悬挂定时器。
        final done = Completer<void>();
        final timer = Timer(duration, () {
          if (!done.isCompleted) done.complete();
        });
        unawaited(
          stopSignal.future.then((_) {
            timer.cancel();
            if (!done.isCompleted) done.complete();
          }),
        );
        return done.future;
      }
      // 测试路径：注入的 sleep 负责记录/压缩退避序列。
      return Future.any<void>(<Future<void>>[
        injectedSleep(duration),
        stopSignal.future,
      ]);
    }

    late final StreamController<EngineEvent> controller;
    var runStarted = false;

    void emit(EngineEvent event) {
      if (stopped || controller.isClosed) return;
      controller.add(event);
    }

    void emitFrames(List<SseFrame> frames) {
      for (final frame in frames) {
        final event = _decodeFrame(frame, onUnknownEvent, onProtocolError);
        if (event != null) emit(event);
      }
    }

    Future<void> backoffThenRetry(EngineBackoff backoff, Object error) async {
      final delay = backoff.next();
      onDisconnect?.call(error, delay);
      await waitOrStop(delay);
    }

    Future<void> run() async {
      while (!stopped && !_closed) {
        final http.StreamedResponse response;
        try {
          response = await _sendEventRequest();
        } catch (error) {
          await backoffThenRetry(effectiveBackoff, error);
          continue;
        }
        if (stopped || _closed) return;

        if (response.statusCode != 200) {
          String detail = 'HTTP ${response.statusCode}';
          try {
            final body = await response.stream.bytesToString();
            if (body.trim().isNotEmpty) {
              detail = 'HTTP ${response.statusCode}: ${body.trim()}';
            }
          } catch (_) {
            // 读不了错误体不影响重连决策
          }
          if (response.statusCode == 401 || response.statusCode == 403) {
            onProtocolError?.call(
              'SSE 鉴权失败（HTTP ${response.statusCode}）：token 不正确，重连不会成功',
            );
          }
          await backoffThenRetry(
            effectiveBackoff,
            EngineException(
              'SSE 连接被拒绝（$detail）',
              statusCode: response.statusCode,
              uri: _uri('/events'),
              method: 'GET',
            ),
          );
          continue;
        }

        final connectedAt = DateTime.now();
        final decoder = SseDecoder();
        final bodyDone = Completer<void>();
        bodyDoneCompleter = bodyDone;
        Object? streamError;
        bodySubscription = response.stream
            .transform(const Utf8Decoder(allowMalformed: true))
            .listen(
              (chunk) => emitFrames(decoder.add(chunk)),
              onError: (Object error) {
                streamError = error;
                if (!bodyDone.isCompleted) bodyDone.complete();
              },
              onDone: () {
                if (!bodyDone.isCompleted) bodyDone.complete();
              },
              cancelOnError: true,
            );
        await bodyDone.future;
        bodySubscription = null;
        bodyDoneCompleter = null;
        emitFrames(decoder.close());
        if (stopped || _closed) return;

        if (_survivedLongEnough(connectedAt, healthyConnectionAge)) {
          effectiveBackoff.reset();
        }
        await backoffThenRetry(
          effectiveBackoff,
          streamError ??
              EngineException(
                'SSE 连接被对端关闭，准备重连',
                uri: _uri('/events'),
                method: 'GET',
              ),
        );
      }
    }

    controller = StreamController<EngineEvent>(
      onListen: () {
        if (runStarted) return;
        runStarted = true;
        unawaited(
          run()
              .catchError((Object error, StackTrace stackTrace) {
                // 循环自身出 bug 也不能让整个 app 崩：上报并结束这条流。
                onProtocolError?.call('SSE 重连循环异常终止：$error');
              })
              .whenComplete(() {
                if (!controller.isClosed) unawaited(controller.close());
              }),
        );
      },
      onCancel: () {
        stopped = true;
        if (!stopSignal.isCompleted) stopSignal.complete();
        final subscription = bodySubscription;
        bodySubscription = null;
        if (subscription != null) unawaited(subscription.cancel());
        // cancel() 不会触发 onDone：手动唤醒等待中的重连循环，避免它悬挂。
        final bodyDone = bodyDoneCompleter;
        if (bodyDone != null && !bodyDone.isCompleted) bodyDone.complete();
      },
    );
    return controller.stream;
  }

  static bool _survivedLongEnough(
    DateTime connectedAt,
    Duration healthyConnectionAge,
  ) => DateTime.now().difference(connectedAt) >= healthyConnectionAge;

  EngineEvent? _decodeFrame(
    SseFrame frame,
    void Function(String event, String data)? onUnknownEvent,
    void Function(String reason)? onProtocolError,
  ) {
    final event = EngineEventCodec.decode(frame);
    if (event != null) return event;
    final name = frame.event;
    if (name == null || name.isEmpty) {
      onProtocolError?.call('收到没有 event 名的 SSE 帧，已忽略: ${_snippet(frame.data)}');
    } else if (!_knownEvents.contains(name)) {
      onUnknownEvent?.call(name, frame.data);
    } else {
      onProtocolError?.call(
        '事件 $name 的 data 无法解析，已忽略: ${_snippet(frame.data)}',
      );
    }
    return null;
  }

  static const Set<String> _knownEvents = <String>{
    'snapshot',
    'torrent_added',
    'progress',
    'state',
    'torrent_removed',
    'heartbeat',
  };

  // ── 生命周期 ────────────────────────────────────────────────────────────

  /// 关闭底层连接（仅当客户端自己创建了 `http.Client`）。
  void close() {
    if (_closed) return;
    _closed = true;
    if (_ownsHttp) _http.close();
  }

  // ── 内部实现 ────────────────────────────────────────────────────────────

  Uri _uri(String path, [Map<String, String>? query]) {
    var basePath = baseUrl.path;
    if (basePath.endsWith('/')) {
      basePath = basePath.substring(0, basePath.length - 1);
    }
    // 手工重建而不是 replace(fragment: '')：后者会留下一个多余的 '#'。
    return Uri(
      scheme: baseUrl.scheme.isEmpty ? 'http' : baseUrl.scheme,
      userInfo: baseUrl.userInfo.isEmpty ? null : baseUrl.userInfo,
      host: baseUrl.host,
      port: baseUrl.hasPort ? baseUrl.port : null,
      path: '$basePath$path',
      queryParameters: query,
    );
  }

  Future<http.StreamedResponse> _sendEventRequest() async {
    if (_closed) {
      throw EngineException(
        'EngineClient 已关闭',
        uri: _uri('/events'),
        method: 'GET',
      );
    }
    final uri = _uri('/events');
    final request = http.Request('GET', uri)
      ..headers['accept'] = 'text/event-stream'
      ..headers['cache-control'] = 'no-cache'
      ..headers['authorization'] = 'Bearer $token';
    try {
      return await _http.send(request).timeout(connectTimeout);
    } on TimeoutException catch (error) {
      throw EngineException(
        'SSE 建连超时（${connectTimeout.inSeconds}s）',
        uri: uri,
        method: 'GET',
        cause: error,
      );
    } on SocketException catch (error) {
      throw EngineException(
        '无法连接引擎：${error.message}',
        uri: uri,
        method: 'GET',
        cause: error,
      );
    } on http.ClientException catch (error) {
      throw EngineException(
        'SSE 请求失败：${error.message}',
        uri: uri,
        method: 'GET',
        cause: error,
      );
    }
  }

  Future<http.Response> _send(
    String method,
    String path, {
    Object? body,
    Map<String, String>? query,
    Duration? timeout,
    bool authenticated = true,
    Set<int> acceptStatuses = const <int>{},
  }) async {
    if (_closed) {
      throw EngineException(
        'EngineClient 已关闭',
        uri: _uri(path),
        method: method,
      );
    }
    final uri = _uri(path, query);
    final request = http.Request(method, uri);
    request.headers['accept'] = 'application/json';
    if (authenticated) request.headers['authorization'] = 'Bearer $token';
    if (body != null) {
      request.headers['content-type'] = 'application/json; charset=utf-8';
      request.body = jsonEncode(body);
    }
    final limit = timeout ?? requestTimeout;
    final http.Response response;
    try {
      final streamed = await _http.send(request).timeout(limit);
      response = await http.Response.fromStream(streamed).timeout(limit);
    } on TimeoutException catch (error) {
      throw EngineException(
        '引擎请求超时（${limit.inSeconds}s）：$method ${uri.path}',
        uri: uri,
        method: method,
        cause: error,
      );
    } on SocketException catch (error) {
      throw EngineException(
        '无法连接引擎：${error.message}',
        uri: uri,
        method: method,
        cause: error,
      );
    } on http.ClientException catch (error) {
      throw EngineException(
        '引擎请求失败：${error.message}',
        uri: uri,
        method: method,
        cause: error,
      );
    }
    final isSuccess = response.statusCode >= 200 && response.statusCode < 300;
    if (!isSuccess && !acceptStatuses.contains(response.statusCode)) {
      throw EngineException(
        _describeError(response),
        statusCode: response.statusCode,
        uri: uri,
        method: method,
        body: _snippet(response.body),
      );
    }
    return response;
  }

  Object? _decodeJson(http.Response response, String path) {
    final body = response.body.trim();
    if (body.isEmpty) {
      throw EngineException(
        '引擎在 $path 返回了空响应体（期望 JSON）',
        statusCode: response.statusCode,
        uri: response.request?.url,
        method: response.request?.method,
      );
    }
    try {
      return jsonDecode(body);
    } on FormatException catch (error) {
      throw EngineException(
        '引擎在 $path 返回了非 JSON 响应：${_snippet(body)}',
        statusCode: response.statusCode,
        uri: response.request?.url,
        method: response.request?.method,
        cause: error,
      );
    }
  }

  Map<String, dynamic> _decodeObject(http.Response response, String path) {
    final decoded = _decodeJson(response, path);
    final map = jsonMap(decoded);
    if (map == null) {
      throw EngineException(
        '引擎在 $path 返回了非对象 JSON：${_snippet(response.body)}',
        statusCode: response.statusCode,
        uri: response.request?.url,
        method: response.request?.method,
      );
    }
    return map;
  }

  String _describeError(http.Response response) {
    final body = response.body.trim();
    if (body.isNotEmpty) {
      try {
        final decoded = jsonDecode(body);
        final map = jsonMap(decoded);
        final message = map == null ? null : jsonString(map['error']);
        if (message != null && message.isNotEmpty) {
          return 'HTTP ${response.statusCode} $message';
        }
      } on FormatException {
        // 不是 JSON：直接用原文
      }
      return 'HTTP ${response.statusCode} ${response.reasonPhrase ?? ''}: ${_snippet(body)}'
          .trim();
    }
    final reason = response.reasonPhrase;
    return reason == null || reason.isEmpty
        ? 'HTTP ${response.statusCode}'
        : 'HTTP ${response.statusCode} $reason';
  }

  static String _snippet(String body, {int max = 200}) {
    final text = body.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (text.length <= max) return text;
    return '${text.substring(0, max)}…（共 ${text.length} 字符）';
  }
}
