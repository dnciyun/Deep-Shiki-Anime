/// 拉起并托管 `rqbit-engine.exe` 边车进程（spec §3.2 / §4.1）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import 'client.dart';
import 'json_tools.dart';
import 'models.dart';
import 'sse.dart';

/// runtime.json 里的就绪信息（spec §3.2）。
class EngineRuntimeInfo {
  const EngineRuntimeInfo({
    required this.schema,
    required this.pid,
    required this.port,
    required this.token,
    required this.baseUrl,
    this.downloadDir,
    this.stateDir,
    this.startedAt,
  });

  /// 解析并校验。
  ///
  /// * `baseUrl` 缺失时按 `http://127.0.0.1:<port>` 推导（容错）；
  /// * `schema` 不受支持 / `port` 非法 / `token` 为空 → 抛 [EngineException]
  ///   （这是**不兼容**，不能假装就绪）。
  factory EngineRuntimeInfo.fromJson(Map<String, dynamic> json) {
    final schema = jsonInt(json['schema'], fallback: supportedSchema);
    if (schema != supportedSchema) {
      throw EngineException(
        'runtime.json 的 schema=$schema 不受支持（本客户端支持 $supportedSchema）。'
        '边车与客户端版本不匹配，请使用仓库内配套构建。',
      );
    }
    final port = jsonInt(json['port']);
    if (port <= 0 || port > 65535) {
      throw EngineException('runtime.json 的 port=$port 非法（期望 1–65535）');
    }
    final token = (jsonString(json['token']) ?? '').trim();
    if (token.isEmpty) {
      throw EngineException('runtime.json 缺少 token：无法调用需要鉴权的端点');
    }
    final rawBaseUrl = (jsonString(json['baseUrl']) ?? '').trim();
    final Uri baseUrl;
    if (rawBaseUrl.isEmpty) {
      baseUrl = Uri.parse('http://127.0.0.1:$port');
    } else {
      final parsed = Uri.tryParse(rawBaseUrl);
      if (parsed == null || !parsed.hasScheme || parsed.host.isEmpty) {
        throw EngineException('runtime.json 的 baseUrl 非法：$rawBaseUrl');
      }
      baseUrl = parsed;
    }
    final startedAtRaw = jsonString(json['startedAt']);
    return EngineRuntimeInfo(
      schema: schema,
      pid: jsonInt(json['pid']),
      port: port,
      token: token,
      baseUrl: baseUrl,
      downloadDir: jsonString(json['downloadDir']),
      stateDir: jsonString(json['stateDir']),
      startedAt: startedAtRaw == null ? null : DateTime.tryParse(startedAtRaw),
    );
  }

  /// 本客户端支持的 runtime.json schema 版本。
  static const int supportedSchema = 1;

  /// schema 版本。
  final int schema;

  /// 边车进程 pid。
  final int pid;

  /// 实际监听端口（`--port 0` 时由系统分配）。
  final int port;

  /// 鉴权 token（64 位 hex）。
  final String token;

  /// 引擎根地址。
  final Uri baseUrl;

  /// 下载目录。
  final String? downloadDir;

  /// 状态目录。
  final String? stateDir;

  /// 启动时间。
  final DateTime? startedAt;

  /// 序列化（测试/诊断用）。
  Map<String, Object?> toJson() => <String, Object?>{
    'schema': schema,
    'pid': pid,
    'port': port,
    'token': token,
    'baseUrl': baseUrl.toString(),
    if (downloadDir != null) 'downloadDir': downloadDir,
    if (stateDir != null) 'stateDir': stateDir,
    if (startedAt != null) 'startedAt': startedAt!.toUtc().toIso8601String(),
  };

  @override
  String toString() =>
      'EngineRuntimeInfo(pid: $pid, port: $port, baseUrl: $baseUrl)';
}

/// 引擎进程句柄的抽象。
///
/// 抽出这一层是为了让「拉起进程」可注入假实现（测试禁止真起进程），
/// 而**真实实现 [IoEngineProcessHandle] 只是 `dart:io` `Process` 的 1:1 转发**，
/// 不做任何能力削减。
abstract class EngineProcessHandle {
  /// 进程 pid。
  int get pid;

  /// stdout 字节流。
  Stream<List<int>> get stdout;

  /// stderr 字节流。
  Stream<List<int>> get stderr;

  /// 进程退出码。
  Future<int> get exitCode;

  /// 发送信号；成功返回 `true`。
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]);

  /// 关闭 stdin（对「监听 stdin EOF 就退出」的进程是优雅停止信号）。
  void closeStdin();
}

/// [EngineProcessHandle] 的真实实现：直接包住 `dart:io` 的 `Process`。
class IoEngineProcessHandle implements EngineProcessHandle {
  IoEngineProcessHandle(this._process);

  final Process _process;

  /// 被包装的进程。
  Process get process => _process;

  @override
  int get pid => _process.pid;

  @override
  Stream<List<int>> get stdout => _process.stdout;

  @override
  Stream<List<int>> get stderr => _process.stderr;

  @override
  Future<int> get exitCode => _process.exitCode;

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) =>
      _process.kill(signal);

  @override
  void closeStdin() {
    try {
      // 关掉 stdin 的写端：不等这个 Future（进程可能已经退出）。
      unawaited(_process.stdin.close());
    } catch (_) {
      // 进程已退出时 stdin 可能已关闭，忽略。
    }
  }
}

/// 可注入的启动器签名（生产用 [defaultEngineSpawner]）。
typedef EngineSpawner =
    Future<EngineProcessHandle> Function(
      String executable,
      List<String> arguments, {
      String? workingDirectory,
      Map<String, String>? environment,
      bool runInShell,
    });

/// 默认启动器：真实拉起进程。
Future<EngineProcessHandle> defaultEngineSpawner(
  String executable,
  List<String> arguments, {
  String? workingDirectory,
  Map<String, String>? environment,
  bool runInShell = false,
}) async {
  final process = await Process.start(
    executable,
    arguments,
    workingDirectory: workingDirectory,
    environment: environment,
    runInShell: runInShell,
  );
  return IoEngineProcessHandle(process);
}

/// 已就绪的边车进程。
class EngineProcess {
  EngineProcess._({
    required this.executable,
    required EngineProcessHandle processHandle,
    required EngineRuntimeInfo runtimeInfo,
    required File file,
    required List<String> outTail,
    required List<String> errTail,
  }) : _handle = processHandle,
       _runtimeFile = file,
       _stdoutTail = outTail,
       _stderrTail = errTail,
       _runtime = runtimeInfo {
    unawaited(
      processHandle.exitCode.then(
        (code) {
          _exitCode = code;
          _exited = true;
        },
        onError: (Object _) {
          _exited = true;
        },
      ),
    );
  }

  /// 保留的进程输出行数（报错时回显最后几行）。
  static const int maxTailLines = 20;

  /// 默认就绪超时（spec：30s）。
  static const Duration defaultReadyTimeout = Duration(seconds: 30);

  /// 默认就绪轮询间隔。
  static const Duration defaultPollInterval = Duration(milliseconds: 150);

  final EngineProcessHandle _handle;
  final File _runtimeFile;
  final List<String> _stdoutTail;
  final List<String> _stderrTail;
  final EngineRuntimeInfo _runtime;
  EngineClient? _client;
  int? _exitCode;
  bool _exited = false;
  bool _stopped = false;

  /// 启动时使用的可执行文件路径。
  final String executable;

  /// 本次运行的 runtime.json 路径。
  String get runtimeFile => _runtimeFile.path;

  /// 边车进程 pid。
  int get pid => _runtime.pid == 0 ? _handle.pid : _runtime.pid;

  /// 实际监听端口。
  int get port => _runtime.port;

  /// 鉴权 token。
  String get token => _runtime.token;

  /// 引擎根地址。
  Uri get baseUrl => _runtime.baseUrl;

  /// runtime.json 解析结果。
  EngineRuntimeInfo get runtime => _runtime;

  /// 进程 stdout 最后若干行。
  List<String> get stdoutTail => List<String>.unmodifiable(_stdoutTail);

  /// 进程 stderr 最后若干行。
  List<String> get stderrTail => List<String>.unmodifiable(_stderrTail);

  /// 进程是否仍在运行（以退出码是否已到达为准，不猜测）。
  bool get isRunning => !_exited;

  /// 进程退出码；未退出为 `null`。
  int? get exitCode => _exitCode;

  /// 复用的 HTTP/SSE 客户端（进程存活期间同一个）。
  EngineClient get client =>
      _client ??= EngineClient(baseUrl: baseUrl, token: token);

  /// 拉起边车并等待就绪。
  ///
  /// 时序（spec §3.2）：先写 runtime.json → 再 ready → 才开始服务。
  ///
  /// 抛 [EngineStartException] 的情况（**每种都会 kill 进程、不留僵尸**）：
  /// 启动器失败、进程提前退出、就绪超时、runtime.json 说 schema 不兼容、
  /// runtime.json 一直存在但无法解析。
  static Future<EngineProcess> start({
    required String exePath,
    required String downloadDir,
    required String stateDir,
    String? runtimeFile,
    int port = 0,
    List<String> extraArgs = const <String>[],
    EngineSpawner? spawner,
    Duration readyTimeout = defaultReadyTimeout,
    Duration pollInterval = defaultPollInterval,
    Duration probeTimeout = const Duration(seconds: 2),
    Duration killGrace = const Duration(seconds: 2),
    String? workingDirectory,
    Map<String, String>? environment,
    EngineSleep? sleep,
  }) async {
    if (port < 0 || port > 65535) {
      throw ArgumentError.value(port, 'port', '端口必须在 0–65535 之间（0 = 系统分配）');
    }
    final wait = sleep ?? defaultEngineSleep;
    final started = DateTime.now();
    final downloadDirectory = Directory(downloadDir);
    final stateDirectory = Directory(stateDir);
    await downloadDirectory.create(recursive: true);
    await stateDirectory.create(recursive: true);

    final runtime = File(
      runtimeFile ?? p.join(stateDirectory.path, 'runtime.json'),
    );
    // 清掉上一次运行的残留：否则「文件存在」会被误判为本次就绪。
    await _deleteQuietly(runtime);

    // 空字符串参数必须**过滤掉**，不能透传给边车：
    // clap 会把 `""` 当成一个位置参数/值，直接 `error: unexpected argument '' found`
    // 并以 exit=2 退出，于是「引擎在就绪前退出」。宿主侧的可选参数
    // （如 `--trackers ""`）在用户没填时天然会产出空串，这是真实踩过的坑。
    // 空串永远不可能是合法 CLI 参数，静默丢弃是安全且唯一的解释。
    final filteredExtraArgs = extraArgs
        .where((a) => a.trim().isNotEmpty)
        .toList(growable: false);

    final arguments = <String>[
      '--port',
      '$port',
      '--runtime-file',
      runtime.path,
      '--download-dir',
      downloadDirectory.path,
      '--state-dir',
      stateDirectory.path,
      ...filteredExtraArgs,
    ];

    final EngineProcessHandle handle;
    try {
      handle = await (spawner ?? defaultEngineSpawner)(
        exePath,
        arguments,
        workingDirectory: workingDirectory,
        environment: environment,
        runInShell: false,
      );
    } catch (error) {
      throw EngineStartException(
        '无法启动引擎进程：$error',
        executable: exePath,
        runtimeFile: runtime.path,
        elapsed: DateTime.now().difference(started),
        cause: error,
      );
    }

    final stdoutTail = <String>[];
    final stderrTail = <String>[];
    _drain(handle.stdout, stdoutTail);
    _drain(handle.stderr, stderrTail);

    var exited = false;
    int? exitCode;
    unawaited(
      handle.exitCode.then(
        (code) {
          exitCode = code;
          exited = true;
        },
        onError: (Object _) {
          exited = true;
        },
      ),
    );

    final probeHttp = http.Client();
    final deadline = DateTime.now().add(readyTimeout);
    String? runtimeError;
    String? healthError;
    EngineRuntimeInfo? info;

    EngineStartException buildFailure(String reason) => EngineStartException(
      reason,
      executable: exePath,
      runtimeFile: runtime.path,
      stdoutTail: List<String>.unmodifiable(stdoutTail),
      stderrTail: List<String>.unmodifiable(stderrTail),
      exitCode: exitCode,
      elapsed: DateTime.now().difference(started),
    );

    try {
      while (true) {
        if (exited) {
          await _terminate(handle, grace: killGrace);
          await _deleteQuietly(runtime);
          throw buildFailure(
            '引擎进程在就绪前退出（exit=$exitCode）。'
            '常见原因：端口被占用、--state-dir/--download-dir 不可写、'
            'runtime.json 路径无权限，或 exe 与当前平台不匹配。',
          );
        }

        if (runtime.existsSync()) {
          try {
            final text = await runtime.readAsString();
            final decoded = jsonDecode(text);
            final map = jsonMap(decoded);
            if (map == null) {
              runtimeError = 'runtime.json 不是 JSON 对象：${_snippet(text)}';
            } else {
              info = EngineRuntimeInfo.fromJson(map); // schema 不兼容会直接抛
              runtimeError = null;
            }
          } on EngineException {
            await _terminate(handle, grace: killGrace);
            await _deleteQuietly(runtime);
            rethrow;
          } on FormatException catch (error) {
            runtimeError = 'runtime.json 尚未写完/无法解析：${error.message}';
          } on FileSystemException catch (error) {
            runtimeError = 'runtime.json 读取失败：${error.message}';
          }
        } else {
          runtimeError = 'runtime.json 尚未出现';
        }

        if (info != null) {
          final client = EngineClient(
            baseUrl: info.baseUrl,
            token: info.token,
            http: probeHttp,
            requestTimeout: probeTimeout,
          );
          try {
            final health = await client.health();
            if (health.ok) {
              return EngineProcess._(
                executable: exePath,
                processHandle: handle,
                runtimeInfo: info,
                file: runtime,
                outTail: stdoutTail,
                errTail: stderrTail,
              );
            }
            healthError =
                'GET /health 返回 ok=false（${health.version ?? '未知版本'}）';
          } on EngineException catch (error) {
            healthError = error.message;
          }
        }

        if (!DateTime.now().isBefore(deadline)) {
          await _terminate(handle, grace: killGrace);
          await _deleteQuietly(runtime);
          throw buildFailure(
            '引擎在 ${readyTimeout.inMilliseconds}ms 内没有就绪。'
            'runtime.json: ${runtime.path}（$runtimeError）；'
            '/health: ${healthError ?? '尚未探测'}。'
            '排查建议：① 手动运行 `"$exePath" --help` 确认可执行；'
            '② 确认 $stateDir 与 $downloadDir 可写；'
            '③ 确认端口未被占用（--port 0 一般不会冲突）；'
            '④ 看上面的 stdout/stderr 末尾行。',
          );
        }

        await wait(pollInterval);
      }
    } finally {
      probeHttp.close();
    }
  }

  /// 优雅停止：`POST /shutdown` → 关 stdin → terminate → kill。
  ///
  /// 最后删除 runtime.json。幂等：重复调用直接返回。
  Future<void> stop({
    Duration gracefulTimeout = const Duration(seconds: 3),
  }) async {
    if (_stopped) return;
    _stopped = true;
    if (isRunning) {
      try {
        await client.shutdown().timeout(const Duration(seconds: 2));
      } catch (_) {
        // 边车可能没实现 /shutdown（404）或已开始退出：继续走后面的兜底路径。
      }
      _handle.closeStdin();
      var exited = await _waitForExit(_handle, gracefulTimeout);
      if (!exited) {
        _handle.kill(ProcessSignal.sigterm);
        exited = await _waitForExit(_handle, const Duration(seconds: 1));
      }
      if (!exited) {
        _handle.kill(ProcessSignal.sigkill);
        await _waitForExit(_handle, const Duration(seconds: 1));
      }
    }
    await _deleteQuietly(_runtimeFile);
    _client?.close();
  }

  /// 诊断字符串（日志/错误提示用）。
  String describe() {
    final buffer = StringBuffer(
      'EngineProcess(pid: ${_handle.pid}, port: $port, '
      'running: $isRunning',
    );
    if (_exitCode != null) buffer.write(', exitCode: $_exitCode');
    buffer.write(')');
    if (_stderrTail.isNotEmpty) {
      buffer.write('\nstderr: ${_stderrTail.join(' | ')}');
    }
    return buffer.toString();
  }

  @override
  String toString() => describe();

  static void _drain(Stream<List<int>> stream, List<String> sink) {
    stream
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .listen(
          (line) {
            if (line.trim().isEmpty) return;
            sink.add(line);
            while (sink.length > maxTailLines) {
              sink.removeAt(0);
            }
          },
          onError: (Object _) {},
          cancelOnError: false,
        );
  }

  static Future<bool> _waitForExit(
    EngineProcessHandle handle,
    Duration timeout,
  ) async {
    try {
      await handle.exitCode.timeout(timeout);
      return true;
    } on TimeoutException {
      return false;
    }
  }

  /// 强杀：先温和 signal，再 SIGKILL，确保不留僵尸。
  static Future<void> _terminate(
    EngineProcessHandle handle, {
    required Duration grace,
  }) async {
    if (await _waitForExit(handle, const Duration(milliseconds: 200))) return;
    handle.closeStdin();
    handle.kill(ProcessSignal.sigterm);
    if (await _waitForExit(handle, grace)) return;
    handle.kill(ProcessSignal.sigkill);
    await _waitForExit(handle, grace);
  }

  static Future<void> _deleteQuietly(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {
      // 删不掉不影响主流程（下次 start 还会再删一次）。
    }
  }

  static String _snippet(String text, {int max = 200}) {
    final flat = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (flat.length <= max) return flat;
    return '${flat.substring(0, max)}…';
  }
}
