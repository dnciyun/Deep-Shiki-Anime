/// HTTP 传输层：代理 / 限速 / 超时 / 重试 / 编码兜底。
///
/// 契约：spec §4.2。全仓 HTTP 统一使用 `package:http`。
///
/// 关键设计：**时钟、睡眠、HTTP 客户端、Socket 全部可注入**，
/// 因此限速与重试逻辑可以在单测里完全确定性地验证，不需要联网、不需要 `sleep`。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import 'models.dart';

/// 代理模式。字段名照 spec §4.2 冻结：`mode: none|http|socks5`。
enum ProxyMode { none, http, socks5 }

/// 源抓取代理配置（**只作用于源抓取**，不影响边车回环串流）。
class ProxyConfig {
  const ProxyConfig({
    this.mode = ProxyMode.none,
    this.host,
    this.port,
    this.username,
    this.password,
  });

  const ProxyConfig.none() : this();

  final ProxyMode mode;
  final String? host;
  final int? port;
  final String? username;
  final String? password;

  bool get isEnabled => mode != ProxyMode.none;

  /// 配置是否完整（启用时代理必须有 host 与 1..65535 的 port）。
  bool get isValid {
    if (!isEnabled) return true;
    final h = host;
    final p = port;
    return h != null && h.isNotEmpty && p != null && p > 0 && p <= 65535;
  }

  /// spec §4.2 字面要求的 `findProxy` 字符串。
  ///
  /// ⚠️ `dart:io` 的 `HttpClient.findProxy` **只认** `DIRECT` 与 `PROXY host:port`
  /// （见 `dart-sdk/lib/_http/http_impl.dart` 的 `_ProxyConfiguration`，其他 token 直接抛
  /// `HttpException("Invalid proxy configuration …")`），所以 [ProxyMode.socks5] 这一串
  /// **不能**直接交给 `findProxy`。[IoHttpClientFactory] 对 socks5 走
  /// `HttpClient.connectionFactory` 自建隧道（见 [Socks5Handshake]）。
  String get findProxyString {
    switch (mode) {
      case ProxyMode.none:
        return 'DIRECT';
      case ProxyMode.http:
        final auth = (username != null && username!.isNotEmpty)
            ? '$username:$password@'
            : '';
        return 'PROXY $auth$host:$port';
      case ProxyMode.socks5:
        return 'SOCKS5 $host:$port';
    }
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'mode': mode.name,
        if (host != null) 'host': host,
        if (port != null) 'port': port,
        if (username != null) 'username': username,
        if (password != null) 'password': password,
      };

  factory ProxyConfig.fromJson(Map<String, dynamic> json) {
    final modeName = json['mode'] as String?;
    final mode = ProxyMode.values.firstWhere(
      (ProxyMode m) => m.name == modeName,
      orElse: () => ProxyMode.none,
    );
    return ProxyConfig(
      mode: mode,
      host: json['host'] as String?,
      port: (json['port'] as num?)?.toInt(),
      username: json['username'] as String?,
      password: json['password'] as String?,
    );
  }

  @override
  String toString() =>
      isEnabled ? 'ProxyConfig(${mode.name} $host:$port)' : 'ProxyConfig(none)';

  @override
  bool operator ==(Object other) =>
      other is ProxyConfig &&
      other.mode == mode &&
      other.host == host &&
      other.port == port &&
      other.username == username &&
      other.password == password;

  @override
  int get hashCode => Object.hash(mode, host, port, username, password);
}

/// HTTP 客户端工厂：让单测注入 `MockClient`，生产注入带代理的 `IOClient`。
abstract class HttpClientFactory {
  /// 新建客户端。调用方负责通过 [close] 释放。
  http.Client create();

  /// 释放工厂持有的资源（默认无操作）。
  void close() {}

  /// 人类可读描述，用于错误信息。
  String get describe;
}

/// 生产实现：`package:http` 的 [IOClient] + `dart:io` 的 `HttpClient`。
///
/// * `http` → `HttpClient.findProxy`（spec 字面要求）
/// * `socks5` → `HttpClient.connectionFactory` + 自实现 SOCKS5 隧道
///   （`dart:io` 的 `findProxy` 不支持 SOCKS5，见 [ProxyConfig.findProxyString]）
class IoHttpClientFactory implements HttpClientFactory {
  IoHttpClientFactory({
    this.proxy = const ProxyConfig.none(),
    this.connectionTimeout = const Duration(seconds: 20),
    this.socketConnector,
  });

  final ProxyConfig proxy;
  final Duration connectionTimeout;

  /// 建立 TCP 连接的方式（可注入假实现 → SOCKS5 隧道单测不碰真实 socket）。
  final SocketConnector? socketConnector;

  http.Client? _cached;

  @override
  String get describe =>
      proxy.isEnabled ? 'IOClient+${proxy.mode.name}(${proxy.host}:${proxy.port})' : 'IOClient';

  @override
  http.Client create() {
    final existing = _cached;
    if (existing != null) return existing;

    if (proxy.isEnabled && !proxy.isValid) {
      throw SourceException(
        '代理配置不完整（mode=${proxy.mode.name} 需要 host 与 1..65535 的 port）',
      );
    }

    final io = HttpClient()..connectionTimeout = connectionTimeout;
    if (proxy.mode == ProxyMode.http) {
      final findProxy = proxy.findProxyString;
      io.findProxy = (Uri _) => findProxy;
    } else if (proxy.mode == ProxyMode.socks5) {
      // 不用 findProxy（dart:io 不支持 SOCKS5），走自定义连接工厂。
      io.findProxy = (Uri _) => 'DIRECT';
      final tunnel = Socks5Tunnel(
        proxy,
        connect: socketConnector ?? _defaultSocketConnector,
        connectionTimeout: connectionTimeout,
      );
      io.connectionFactory = tunnel.openConnection;
    }
    final client = IOClient(io);
    _cached = client;
    return client;
  }

  @override
  void close() {
    _cached?.close();
    _cached = null;
  }

  static Future<Socket> _defaultSocketConnector(
    String host,
    int port,
    Duration timeout,
  ) =>
      Socket.connect(host, port, timeout: timeout);
}

/// 建立 TCP 连接的最小抽象（便于单测注入内存假实现）。
typedef SocketConnector = Future<Socket> Function(
  String host,
  int port,
  Duration timeout,
);

/// 双向字节流：SOCKS5 握手只依赖这个接口，因此握手字节可以用内存假流逐字节断言。
abstract class DuplexByteStream {
  /// 写出（必须整段写出）。
  void write(List<int> bytes);

  /// 读满 [count] 字节；对端提前关闭时抛 [SourceException]。
  Future<List<int>> read(int count);
}

/// 包在真实 `Socket` 上的 [DuplexByteStream]。
class SocketByteStream implements DuplexByteStream {
  SocketByteStream(this._socket) : _iterator = StreamIterator<Uint8List>(_socket);

  final Socket _socket;
  final StreamIterator<Uint8List> _iterator;
  final List<int> _buffer = <int>[];

  @override
  void write(List<int> bytes) => _socket.add(bytes);

  @override
  Future<List<int>> read(int count) async {
    while (_buffer.length < count) {
      final bool hasNext;
      try {
        hasNext = await _iterator.moveNext();
      } on SocketException catch (e) {
        throw SourceException('SOCKS5 代理连接中断: ${e.message}', cause: e);
      }
      if (!hasNext) {
        throw SourceException('SOCKS5 代理提前关闭连接（还需 $count 字节）');
      }
      _buffer.addAll(_iterator.current);
    }
    final out = _buffer.sublist(0, count);
    _buffer.removeRange(0, count);
    return out;
  }
}

/// SOCKS5 握手（RFC 1928 + RFC 1929 用户名/密码认证）。
///
/// 独立成类是为了**可单测**：直接用 [DuplexByteStream] 假流验证握手字节与错误分支。
class Socks5Handshake {
  const Socks5Handshake(this.config);

  final ProxyConfig config;

  static const int version = 0x05;
  static const int authNone = 0x00;
  static const int authUserPass = 0x02;
  static const int authNoAcceptable = 0xFF;
  static const int cmdConnect = 0x01;
  static const int atypDomain = 0x03;

  /// 与代理握手并请求 CONNECT 到 `host:port`。
  Future<void> perform(DuplexByteStream stream, String host, int port) async {
    final user = config.username;
    final pass = config.password ?? '';
    final wantsAuth = user != null && user.isNotEmpty;

    // 1) 问候。
    final methods = wantsAuth ? <int>[authNone, authUserPass] : <int>[authNone];
    stream.write(<int>[version, methods.length, ...methods]);
    final hello = await stream.read(2);
    if (hello[0] != version) {
      throw SourceException('SOCKS5 代理返回了不支持的版本 ${hello[0]}');
    }
    final method = hello[1];
    if (method == authNoAcceptable) {
      throw SourceException('SOCKS5 代理拒绝了所有认证方式（0xFF）');
    }
    if (method == authUserPass) {
      if (!wantsAuth) {
        throw SourceException('SOCKS5 代理要求用户名/密码认证，但配置里没有填写');
      }
      final userBytes = utf8.encode(user);
      final passBytes = utf8.encode(pass);
      if (userBytes.length > 255 || passBytes.length > 255) {
        throw SourceException('SOCKS5 用户名或密码超过 255 字节');
      }
      stream.write(<int>[
        0x01,
        userBytes.length,
        ...userBytes,
        passBytes.length,
        ...passBytes,
      ]);
      final authReply = await stream.read(2);
      if (authReply[1] != 0x00) {
        throw SourceException('SOCKS5 用户名/密码认证失败（状态 ${authReply[1]}）');
      }
    } else if (method != authNone) {
      throw SourceException('不支持的 SOCKS5 认证方式 0x${method.toRadixString(16)}');
    }

    // 2) CONNECT（域名寻址，避免本地 DNS 泄漏）。
    final hostBytes = utf8.encode(host);
    if (hostBytes.isEmpty || hostBytes.length > 255) {
      throw SourceException('SOCKS5 目标主机名长度非法: "$host"');
    }
    if (port <= 0 || port > 65535) {
      throw SourceException('SOCKS5 目标端口非法: $port');
    }
    stream.write(<int>[
      version,
      cmdConnect,
      0x00,
      atypDomain,
      hostBytes.length,
      ...hostBytes,
      (port >> 8) & 0xFF,
      port & 0xFF,
    ]);
    final reply = await stream.read(4);
    if (reply[0] != version) {
      throw SourceException('SOCKS5 CONNECT 回复版本非法 ${reply[0]}');
    }
    if (reply[1] != 0x00) {
      throw SourceException('SOCKS5 CONNECT 失败: ${_replyMessage(reply[1])}');
    }
    // 3) 消费 BND.ADDR / BND.PORT。
    switch (reply[3]) {
      case 0x01:
        await stream.read(4);
      case 0x03:
        final len = await stream.read(1);
        await stream.read(len[0]);
      case 0x04:
        await stream.read(16);
      default:
        throw SourceException(
          'SOCKS5 CONNECT 回复含未知地址类型 0x${reply[3].toRadixString(16)}',
        );
    }
    await stream.read(2);
  }

  static String _replyMessage(int rep) {
    switch (rep) {
      case 0x01:
        return '通用失败';
      case 0x02:
        return '规则不允许';
      case 0x03:
        return '网络不可达';
      case 0x04:
        return '主机不可达';
      case 0x05:
        return '连接被拒绝';
      case 0x06:
        return 'TTL 超时';
      case 0x07:
        return '命令不支持';
      case 0x08:
        return '地址类型不支持';
      default:
        return '未知错误 0x${rep.toRadixString(16)}';
    }
  }
}

/// 把 `HttpClient.connectionFactory` 接到 SOCKS5 隧道上。
class Socks5Tunnel {
  Socks5Tunnel(
    this.config, {
    required this.connect,
    this.connectionTimeout = const Duration(seconds: 20),
  });

  final ProxyConfig config;

  /// TCP 连接建立器（可注入假实现）。
  final SocketConnector connect;

  final Duration connectionTimeout;

  Future<ConnectionTask<Socket>> openConnection(
    Uri url,
    String? proxyHost,
    int? proxyPort,
  ) async {
    if (!config.isValid) {
      throw SourceException('SOCKS5 代理配置不完整: $config');
    }
    final targetPort = url.hasPort
        ? url.port
        : (url.scheme == 'https' ? 443 : 80);
    final socket = await connect(config.host!, config.port!, connectionTimeout);
    try {
      await Socks5Handshake(config).perform(
        SocketByteStream(socket),
        url.host,
        targetPort,
      );
    } catch (_) {
      socket.destroy();
      rethrow;
    }
    return ConnectionTask.fromSocket(
      Future<Socket>.value(socket),
      () => socket.destroy(),
    );
  }
}

/// 时钟（可注入，单测用假时钟）。
typedef ClockFn = DateTime Function();

/// 睡眠（可注入，单测用「立即完成 + 推进假时钟」）。
typedef SleepFn = Future<void> Function(Duration duration);

/// 每 host 串行 + 最小间隔限速器。
///
/// * 同一 host 的请求**严格串行**（前一个 action 完成后才可能开始下一个）；
/// * 同一 host 两次 action **开始**的间隔 ≥ [minInterval]（start-to-start，标准限速语义）；
/// * 不同 host 互不阻塞；
/// * 时钟与睡眠可注入 → 单测无需真实等待。
class RateLimiter {
  RateLimiter({
    this.minInterval = const Duration(milliseconds: 1200),
    ClockFn? clock,
    SleepFn? sleep,
  })  : _clock = clock ?? DateTime.now,
        _sleep = sleep ?? Future<void>.delayed;

  /// 最小间隔（spec §4.2：默认 1200ms，设置页可调）。
  Duration minInterval;

  final ClockFn _clock;
  final SleepFn _sleep;

  final Map<String, Future<void>> _tails = <String, Future<void>>{};
  final Map<String, DateTime> _lastStarted = <String, DateTime>{};

  /// 当前还在排队的 host 数（诊断用）。
  int get pendingHosts => _tails.length;

  /// 串行 + 限速执行 [action]。
  Future<T> schedule<T>(String host, Future<T> Function() action) async {
    final key = host.toLowerCase();
    final previous = _tails[key] ?? Future<void>.value();
    final done = Completer<void>();
    _tails[key] = done.future;

    await previous;
    try {
      final last = _lastStarted[key];
      if (last != null && minInterval > Duration.zero) {
        final elapsed = _clock().difference(last);
        final wait = minInterval - elapsed;
        if (wait > Duration.zero) await _sleep(wait);
      }
      _lastStarted[key] = _clock();
      return await action();
    } finally {
      done.complete();
    }
  }
}

/// 一次成功的 HTTP 抓取结果（含编码信息）。
class HttpFetch {
  const HttpFetch({
    required this.url,
    required this.statusCode,
    required this.body,
    required this.encoding,
    required this.headers,
    this.bytes = const <int>[],
    this.declaredCharset,
    this.encodingFallback = false,
  });

  final Uri url;
  final int statusCode;
  final String body;

  /// 响应**原始字节**。
  ///
  /// 为什么要留着（用户 2026-10-12 第 9 轮，ACG.RIP 源）：那个站的列表/详情页
  /// 一处 magnet 都没有，只有 `.torrent` 直链 —— infohash 必须对**原始字节**算
  /// `sha1(bencode(info))`（见 `bencode.dart`），文本解码后的 body 已经晚了
  /// （键序/整数写法一变 hash 就全错）。文本调用方继续用 [body] 即可。
  ///
  /// 默认空列表是为了不破坏既有构造点（测试里手搓 `HttpFetch` 的地方）。
  final List<int> bytes;

  /// 实际使用的编码名。
  final String encoding;

  /// Content-Type 里声明的 charset（没有则 null）。
  final String? declaredCharset;

  /// 是否走了「非 UTF-8 兜底」（破坏性降级，调用方可记录告警）。
  final bool encodingFallback;

  final Map<String, String> headers;
}

/// 抓取器：固定 UA + 20s 超时 + 2 次退避重试 + 每 host 限速。
class SourceHttp {
  SourceHttp({
    required this.factory,
    RateLimiter? limiter,
    this.timeout = const Duration(seconds: 20),
    this.maxRetries = 2,
    this.retryBackoff = const <Duration>[
      Duration(milliseconds: 500),
      Duration(milliseconds: 1500),
    ],
    SleepFn? sleep,
  })  : _limiter = limiter ?? RateLimiter(),
        _sleep = sleep ?? Future<void>.delayed;

  /// spec §4.2 冻结的 User-Agent。
  static const String userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) DSAnima/0.1';

  /// 扩展名 → 是否走 HTML 解析（用于「解析失败时给出可读错误」）。
  static const Set<String> htmlContentTypes = <String>{'text/html', 'application/xhtml+xml'};

  /// HTTP 客户端工厂（可注入 `MockClient`）。
  final HttpClientFactory factory;

  final RateLimiter _limiter;
  final SleepFn _sleep;
  final Duration timeout;
  final int maxRetries;
  final List<Duration> retryBackoff;

  http.Client? _client;
  int _requestCount = 0;

  /// 已发出的 HTTP 请求数（诊断 / 测试用）。
  int get requestCount => _requestCount;

  RateLimiter get limiter => _limiter;

  http.Client _ensureClient() => _client ??= factory.create();

  /// 抓取并做编码解码；非 2xx 抛 [SourceException]。
  Future<HttpFetch> fetch(
    Uri url, {
    required String sourceId,
    Map<String, String>? headers,
  }) =>
      _send('GET', url, sourceId: sourceId, headers: headers);

  /// POST 一段 JSON（UTF-8）并做同样的解码/限速/重试；非 2xx 抛 [SourceException]。
  ///
  /// 为什么需要它（用户 2026-10-12 第 10 轮，bangumi.moe 源）：那个站的**分类分区列表**
  /// 只有 `POST /api/torrent/search`（body `{type:'tag', tag_id, p}`），GET 版本一律 404
  /// （`GET /api/torrent/search?...` 实测返回 `{"errno":404,"message":"Page Not Found"}`）。
  /// 源客户端如果自己 new 一个 `http.Client` 去 POST，就会**绕过**这一整层
  /// （代理、每 host 串行 + 最小间隔、超时、退避重试、编码兜底）——
   /// 设置页里的代理与请求间隔会白设。所以把 POST 能力补在传输层，而不是绕开它。
  Future<HttpFetch> postJson(
    Uri url, {
    required Object body,
    required String sourceId,
    Map<String, String>? headers,
  }) =>
      _send('POST', url, sourceId: sourceId, headers: headers, jsonBody: body);

  Future<HttpFetch> _send(
    String method,
    Uri url, {
    required String sourceId,
    Map<String, String>? headers,
    Object? jsonBody,
  }) async {
    // 客户端/代理配置错误要立刻炸出来，不要被当成「网络错误」重试 3 次。
    _ensureClient();
    // body 编码放在重试循环**之外**：编不出来（比如塞了不能 JSON 化的对象）是调用方的
    // 编程错误，不该被伪装成「网络请求失败（第 1 次尝试）」。
    final String? encodedBody = jsonBody == null ? null : jsonEncode(jsonBody);
    final host = url.host;
    SourceException? lastError;
    for (var attempt = 0; attempt <= maxRetries; attempt++) {
      if (attempt > 0) {
        final idx = (attempt - 1).clamp(0, retryBackoff.length - 1);
        await _sleep(retryBackoff[idx]);
      }

      final http.Response response;
      try {
        response = await _limiter.schedule(host, () {
          _requestCount++;
          final client = _ensureClient();
          final requestHeaders = <String, String>{
            HttpHeaders.userAgentHeader: userAgent,
            ...?headers,
          };
          if (encodedBody == null) {
            return client.get(url, headers: requestHeaders).timeout(timeout);
          }
          return client
              .post(
                url,
                headers: <String, String>{
                  ...requestHeaders,
                  HttpHeaders.contentTypeHeader: 'application/json; charset=utf-8',
                },
                body: encodedBody,
              )
              .timeout(timeout);
        });
      } catch (e) {
        // 网络层错误（SocketException / ClientException / TimeoutException / HttpException）
        lastError = SourceException(
          '$method ${url.path} 网络请求失败（第 ${attempt + 1} 次尝试）: $e',
          sourceId: sourceId,
          url: url,
          cause: e,
        );
        continue;
      }

      if (response.statusCode >= 200 && response.statusCode < 300) {
        final decoded = decodeBody(
          response.bodyBytes,
          contentType: response.headers[HttpHeaders.contentTypeHeader],
        );
        return HttpFetch(
          url: url,
          statusCode: response.statusCode,
          body: decoded.text,
          bytes: response.bodyBytes,
          encoding: decoded.encoding,
          declaredCharset: decoded.declaredCharset,
          encodingFallback: decoded.usedFallback,
          headers: response.headers,
        );
      }

      final retryable = response.statusCode >= 500 || response.statusCode == 429;
      lastError = SourceException(
        retryable
            ? '$method ${url.path} → HTTP ${response.statusCode}（已退避重试 $attempt 次仍失败）'
            : '$method ${url.path} → HTTP ${response.statusCode}（不可重试状态码）',
        sourceId: sourceId,
        url: url,
        statusCode: response.statusCode,
      );
      if (!retryable) throw lastError;
    }
    throw lastError ?? SourceException('请求失败', sourceId: sourceId, url: url);
  }

  /// 抓取并返回文本。
  Future<String> getText(
    Uri url, {
    required String sourceId,
    Map<String, String>? headers,
  }) async =>
      (await fetch(url, sourceId: sourceId, headers: headers)).body;

  void close() {
    _client?.close();
    _client = null;
    factory.close();
  }
}

/// 解码结果。
class DecodedBody {
  const DecodedBody({
    required this.text,
    required this.encoding,
    this.declaredCharset,
    this.usedFallback = false,
  });

  final String text;
  final String encoding;
  final String? declaredCharset;

  /// 是否因 UTF-8 解码失败而降级到 latin1。
  final bool usedFallback;
}

/// 从响应字节解码文本，**永不抛异常**。
///
/// 规则（spec §4.2 + 交付要求「非 UTF-8 兜底」）：
/// 1. 去掉 UTF-8 BOM；
/// 2. 优先按 Content-Type 声明的 charset；`utf-8/utf8/us-ascii/ascii` 之外只认 latin1 系；
/// 3. 声明缺失或声明为 gbk/big5/shift_jis 等 dart:convert 不支持的编码时，
///    先严格尝试 UTF-8；
/// 4. UTF-8 解码失败 → latin1 兜底（字节无损映射，不会丢数据也不会崩），
///    `usedFallback=true`，调用方须在结果里标注而不是假装成功。
DecodedBody decodeBody(List<int> bytes, {String? contentType}) {
  var data = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
  if (data.length >= 3 &&
      data[0] == 0xEF &&
      data[1] == 0xBB &&
      data[2] == 0xBF) {
    data = Uint8List.sublistView(data, 3);
  }

  final declared = _charsetOf(contentType);
  final normalized = declared?.toLowerCase().replaceAll('"', '').trim();

  if (normalized != null &&
      (normalized == 'latin1' ||
          normalized == 'latin-1' ||
          normalized == 'iso-8859-1' ||
          normalized == 'windows-1252' ||
          normalized == 'cp1252')) {
    return DecodedBody(
      text: latin1.decode(data, allowInvalid: true),
      encoding: 'latin1',
      declaredCharset: declared,
    );
  }

  try {
    return DecodedBody(
      text: utf8.decode(data),
      encoding: 'utf-8',
      declaredCharset: declared,
    );
  } on FormatException {
    return DecodedBody(
      text: latin1.decode(data, allowInvalid: true),
      encoding: 'latin1(fallback)',
      declaredCharset: declared,
      usedFallback: true,
    );
  }
}

String? _charsetOf(String? contentType) {
  if (contentType == null || contentType.isEmpty) return null;
  final m = RegExp(r'charset\s*=\s*([^\s;]+)', caseSensitive: false)
      .firstMatch(contentType);
  return m?.group(1);
}
