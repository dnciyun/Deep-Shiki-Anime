import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsanima_core/dsanima_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// 假的进程句柄：**不起真进程**，但完整实现 handle 接口（kill/stdin/退出码/输出流）。
class FakeEngineProcessHandle implements EngineProcessHandle {
  FakeEngineProcessHandle({
    this.pid = 4242,
    this.exitOnKill = true,
    this.exitOnCloseStdin = false,
    this.exitOnKillCode = 0,
  });

  @override
  final int pid;
  final bool exitOnKill;
  final bool exitOnCloseStdin;
  final int exitOnKillCode;

  final List<ProcessSignal> kills = <ProcessSignal>[];
  bool stdinClosed = false;

  final StreamController<List<int>> _stdout = StreamController<List<int>>();
  final StreamController<List<int>> _stderr = StreamController<List<int>>();
  final Completer<int> _exit = Completer<int>();

  @override
  Stream<List<int>> get stdout => _stdout.stream;

  @override
  Stream<List<int>> get stderr => _stderr.stream;

  @override
  Future<int> get exitCode => _exit.future;

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    kills.add(signal);
    if (exitOnKill) completeExit(exitOnKillCode);
    return true;
  }

  @override
  void closeStdin() {
    stdinClosed = true;
    if (exitOnCloseStdin) completeExit(0);
  }

  void completeExit(int code) {
    if (!_exit.isCompleted) _exit.complete(code);
  }

  void emitStdout(String text) => _stdout.add(utf8.encode('$text\n'));

  void emitStderr(String text) => _stderr.add(utf8.encode('$text\n'));

  bool get terminated => kills.isNotEmpty || stdinClosed;

  bool get exited => _exit.isCompleted;

  Future<void> dispose() async {
    // 注意：**没有监听者时 `StreamController.close()` 的 future 永不完成**
    //（done 事件没人接收），await 它会让 tearDown 挂死。这里只触发关闭，不等。
    unawaited(_stdout.close());
    unawaited(_stderr.close());
  }
}

/// 本地 HttpServer 桩（回环，**不联网**），模拟边车的 /health 与 /shutdown。
class StubEngineServer {
  StubEngineServer._(this.server);

  final HttpServer server;
  final List<String> requests = <String>[];

  int healthStatus = 200;
  String healthBody = '{"ok":true,"version":"stub-0.1","sessions":0}';
  bool shutdownSupported = true;
  int shutdownCount = 0;

  Uri get baseUrl => Uri.parse('http://127.0.0.1:${server.port}');

  int get port => server.port;

  static Future<StubEngineServer> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final stub = StubEngineServer._(server);
    server.listen((request) async {
      stub.requests.add('${request.method} ${request.uri.path}');
      final response = request.response;
      if (request.uri.path == '/health') {
        response.statusCode = stub.healthStatus;
        response.headers.contentType = ContentType.json;
        response.write(stub.healthBody);
      } else if (request.uri.path == '/shutdown') {
        if (stub.shutdownSupported) {
          stub.shutdownCount++;
          response.statusCode = 200;
          response.headers.contentType = ContentType.json;
          response.write('{"ok":true}');
        } else {
          response.statusCode = 404;
          response.write('{"error":"not_found"}');
        }
      } else {
        response.statusCode = 404;
        response.write('{"error":"not_found"}');
      }
      await response.close();
    });
    return stub;
  }

  Future<void> close() => server.close(force: true);
}

/// 原子写 runtime.json（tmp + rename），与 spec §3.2 一致。
Future<void> writeRuntimeFile(
  String path, {
  required int port,
  int schema = 1,
  String token = 'testtoken',
  Object? pid = 1234,
  String? baseUrl,
}) async {
  final file = File(path);
  await file.parent.create(recursive: true);
  final tmp = File('$path.tmp');
  await tmp.writeAsString(
    jsonEncode(<String, Object?>{
      'schema': schema,
      'pid': pid,
      'port': port,
      'token': token,
      'baseUrl': baseUrl ?? 'http://127.0.0.1:$port',
      'downloadDir': r'F:\dl',
      'stateDir': r'F:\state',
      'startedAt': '2026-10-09T12:00:00Z',
    }),
  );
  await tmp.rename(path);
}

/// 构造一个假启动器：可选「先做点事」(before，模拟边车写 runtime.json) 与
/// 「立刻做点事」(immediate，模拟刚起来就退出/打日志)。
EngineSpawner fakeSpawner({
  required FakeEngineProcessHandle handle,
  Future<void> Function()? before,
  void Function(FakeEngineProcessHandle handle)? immediate,
  List<String>? captureArgs,
}) {
  return (
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    bool runInShell = false,
  }) async {
    captureArgs?.addAll(arguments);
    immediate?.call(handle);
    if (before != null) await before();
    return handle;
  };
}

void main() {
  late Directory workDir;
  late String runtimeFile;
  late FakeEngineProcessHandle handle;

  setUp(() async {
    workDir = await Directory.systemTemp.createTemp('dsanima_process_test');
    runtimeFile = p.join(workDir.path, 'state', 'runtime.json');
    handle = FakeEngineProcessHandle();
    addTearDown(() async {
      await handle.dispose();
      if (workDir.existsSync()) await workDir.delete(recursive: true);
    });
  });

  /// 换一个行为不同的假句柄（并单独登记清理）。
  FakeEngineProcessHandle useHandle({
    bool exitOnKill = true,
    bool exitOnCloseStdin = false,
  }) {
    handle = FakeEngineProcessHandle(
      exitOnKill: exitOnKill,
      exitOnCloseStdin: exitOnCloseStdin,
    );
    addTearDown(handle.dispose);
    return handle;
  }

  Future<EngineProcess> startWith({
    EngineSpawner? spawner,
    int port = 0,
    List<String> extraArgs = const <String>[],
    Duration readyTimeout = const Duration(milliseconds: 400),
    Duration pollInterval = const Duration(milliseconds: 20),
    String? runtimePath,
  }) {
    return EngineProcess.start(
      exePath: r'C:\fake\rqbit-engine.exe',
      downloadDir: p.join(workDir.path, 'downloads'),
      stateDir: p.join(workDir.path, 'state'),
      runtimeFile: runtimePath ?? runtimeFile,
      port: port,
      extraArgs: extraArgs,
      spawner: spawner ?? fakeSpawner(handle: handle),
      readyTimeout: readyTimeout,
      pollInterval: pollInterval,
      killGrace: const Duration(milliseconds: 50),
    );
  }

  group('EngineProcess.start 就绪判定', () {
    test('runtime.json 不出现：超时报错、kill 进程、不留僵尸、回显 stderr', () async {
      final spawner = fakeSpawner(
        handle: handle,
        immediate: (fake) {
          fake.emitStdout('binding 127.0.0.1:0');
          fake.emitStderr('error: state dir not writable');
        },
      );

      await expectLater(
        startWith(
          spawner: spawner,
          readyTimeout: const Duration(milliseconds: 250),
        ),
        throwsA(
          isA<EngineStartException>()
              .having((e) => e.message, 'message', contains('没有就绪'))
              .having((e) => e.message, 'message', contains('排查建议'))
              .having(
                (e) => e.stdoutTail.join('|'),
                'stdout',
                contains('binding 127.0.0.1:0'),
              )
              .having(
                (e) => e.stderrTail.join('|'),
                'stderr',
                contains('state dir not writable'),
              )
              .having(
                (e) => e.executable,
                'executable',
                r'C:\fake\rqbit-engine.exe',
              )
              .having((e) => e.runtimeFile, 'runtimeFile', runtimeFile)
              .having((e) => e.elapsed, 'elapsed', isNotNull),
        ),
      );
      expect(handle.terminated, isTrue, reason: '启动失败必须 kill，不留僵尸');
      expect(handle.exited, isTrue, reason: '假进程应已被终止');
      expect(
        File(runtimeFile).existsSync(),
        isFalse,
        reason: '失败后要清掉 runtime.json',
      );
      expect(handle.kills, isNotEmpty);
    });

    test('进程在就绪前退出：立刻报错并带退出码', () async {
      final spawner = fakeSpawner(
        handle: handle,
        immediate: (fake) => fake.completeExit(3),
      );
      await expectLater(
        startWith(spawner: spawner),
        throwsA(
          isA<EngineStartException>()
              .having((e) => e.message, 'message', contains('就绪前退出'))
              .having((e) => e.message, 'message', contains('exit=3'))
              .having((e) => e.exitCode, 'exitCode', 3),
        ),
      );
    });

    test('runtime.json 出现了但 /health 一直不通：超时并回显 health 错误', () async {
      final server = await StubEngineServer.start();
      addTearDown(server.close);
      server.healthStatus = 500;
      server.healthBody = '{"error":"starting"}';

      final spawner = fakeSpawner(
        handle: handle,
        before: () async {
          await Future<void>.delayed(const Duration(milliseconds: 10));
          await writeRuntimeFile(runtimeFile, port: server.port);
        },
      );

      await expectLater(
        startWith(
          spawner: spawner,
          readyTimeout: const Duration(milliseconds: 300),
        ),
        throwsA(
          isA<EngineStartException>()
              .having((e) => e.message, 'message', contains('没有就绪'))
              .having((e) => e.message, 'message', contains('/health'))
              .having((e) => e.message, 'message', contains('HTTP 500')),
        ),
      );
      expect(server.requests, contains('GET /health'));
      expect(handle.terminated, isTrue);
    });

    test('runtime.json schema 不兼容：立刻报错并终止进程', () async {
      final spawner = fakeSpawner(
        handle: handle,
        before: () => writeRuntimeFile(runtimeFile, port: 12345, schema: 2),
      );
      await expectLater(
        startWith(spawner: spawner),
        throwsA(
          isA<EngineException>().having(
            (e) => e.message,
            'message',
            contains('schema=2 不受支持'),
          ),
        ),
      );
      expect(handle.terminated, isTrue);
    });

    test('runtime.json 端口非法：立刻报错', () async {
      final spawner = fakeSpawner(
        handle: handle,
        before: () => writeRuntimeFile(runtimeFile, port: 0),
      );
      await expectLater(
        startWith(spawner: spawner),
        throwsA(
          isA<EngineException>().having(
            (e) => e.message,
            'message',
            contains('port=0 非法'),
          ),
        ),
      );
    });

    test('启动前清掉陈旧 runtime.json（否则会被误判为本次就绪）', () async {
      await writeRuntimeFile(runtimeFile, port: 65000);
      expect(File(runtimeFile).existsSync(), isTrue);

      await expectLater(
        startWith(readyTimeout: const Duration(milliseconds: 200)),
        throwsA(
          isA<EngineStartException>().having(
            (e) => e.message,
            'message',
            contains('没有就绪'),
          ),
        ),
      );
      expect(File(runtimeFile).existsSync(), isFalse);
    });

    test('spawner 抛异常 → EngineStartException（含原始错误）', () async {
      Future<EngineProcessHandle> throwingSpawner(
        String executable,
        List<String> arguments, {
        String? workingDirectory,
        Map<String, String>? environment,
        bool runInShell = false,
      }) async {
        throw const ProcessException(
          'rqbit-engine.exe',
          <String>[],
          'The system cannot find the file',
        );
      }

      await expectLater(
        startWith(spawner: throwingSpawner),
        throwsA(
          isA<EngineStartException>()
              .having((e) => e.message, 'message', contains('无法启动引擎进程'))
              .having(
                (e) => e.message,
                'message',
                contains('cannot find the file'),
              )
              .having((e) => e.cause, 'cause', isA<ProcessException>()),
        ),
      );
    });

    test('端口参数越界 → ArgumentError（不发进程）', () async {
      await expectLater(startWith(port: 70000), throwsA(isA<ArgumentError>()));
      expect(handle.kills, isEmpty);
    });
  });

  group('EngineProcess.start 成功路径 + stop', () {
    test('传给边车的参数顺序与 runtime.json 内容', () async {
      final server = await StubEngineServer.start();
      addTearDown(server.close);
      final capturedArgs = <String>[];

      final spawner = fakeSpawner(
        handle: handle,
        captureArgs: capturedArgs,
        immediate: (fake) => fake.emitStdout('engine started'),
        before: () => writeRuntimeFile(runtimeFile, port: server.port),
      );

      final process = await startWith(
        spawner: spawner,
        extraArgs: const <String>[
          '--trackers',
          'udp://tracker.example:1337/announce',
        ],
      );
      addTearDown(process.stop);

      expect(capturedArgs, <String>[
        '--port',
        '0',
        '--runtime-file',
        runtimeFile,
        '--download-dir',
        p.join(workDir.path, 'downloads'),
        '--state-dir',
        p.join(workDir.path, 'state'),
        '--trackers',
        'udp://tracker.example:1337/announce',
      ]);
      expect(process.port, server.port);
      expect(process.token, 'testtoken');
      expect(process.baseUrl, Uri.parse('http://127.0.0.1:${server.port}'));
      expect(process.runtimeFile, runtimeFile);
      expect(process.pid, 1234);
      expect(process.isRunning, isTrue);
      expect(process.runtime.downloadDir, r'F:\dl');
      expect(process.runtime.startedAt, DateTime.utc(2026, 10, 9, 12));
      expect(process.stdoutTail, contains('engine started'));

      // 真实 HTTP 往返（回环）：客户端可用，streamUrl 带 token。
      expect((await process.client.health()).ok, isTrue);
      final url = process.client.streamUrl(3, 1);
      expect(url.path, '/torrents/3/files/1/stream');
      expect(url.queryParameters['token'], 'testtoken');
      expect(process.describe(), contains('running: true'));
      expect(process.toString(), contains('EngineProcess'));
    });

    test('空/空白 extraArgs 被丢弃：不能把 "" 透传给 clap（真机踩过）', () async {
      final server = await StubEngineServer.start();
      addTearDown(server.close);
      final capturedArgs = <String>[];

      final spawner = fakeSpawner(
        handle: handle,
        captureArgs: capturedArgs,
        before: () => writeRuntimeFile(runtimeFile, port: server.port),
      );

      // 复现宿主的真实命令行：可选参数没填时天然产出空串。
      // rqbit-engine 用 clap：`""` 会让它 `error: unexpected argument '' found`
      // 并 exit=2，表现为「引擎在就绪前退出」，UI 永远卡在「连接中」。
      final process = await startWith(
        spawner: spawner,
        extraArgs: const <String>[
          '--trackers',
          '',
          '   ', // 纯空白同样不是合法参数
          'udp://tracker.example:1337/announce',
          '',
          '--upload-limit-kbps',
          '100',
        ],
      );
      addTearDown(process.stop);

      expect(
        capturedArgs,
        <String>[
          '--port',
          '0',
          '--runtime-file',
          runtimeFile,
          '--download-dir',
          p.join(workDir.path, 'downloads'),
          '--state-dir',
          p.join(workDir.path, 'state'),
          // 合法的按原顺序保留，空串与纯空白全部消失。
          '--trackers',
          'udp://tracker.example:1337/announce',
          '--upload-limit-kbps',
          '100',
        ],
        reason: '空字符串参数必须被过滤，否则边车 clap 解析失败直接退出',
      );
      expect(
        capturedArgs.any((a) => a.trim().isEmpty),
        isFalse,
        reason: '任何位置都不允许出现空/空白参数',
      );
      expect(process.port, server.port);
    });

    test(
      'stop 走优雅路径：POST /shutdown → 关 stdin，不用 kill，并删 runtime.json',
      () async {
        final server = await StubEngineServer.start();
        addTearDown(server.close);
        useHandle(exitOnCloseStdin: true);

        final spawner = fakeSpawner(
          handle: handle,
          before: () => writeRuntimeFile(runtimeFile, port: server.port),
        );

        final process = await startWith(spawner: spawner);
        expect(process.isRunning, isTrue);

        await process.stop();

        expect(server.shutdownCount, 1, reason: '优雅停止必须先请求 /shutdown');
        expect(handle.stdinClosed, isTrue);
        expect(handle.kills, isEmpty, reason: '优雅退出成功就不该 kill');
        expect(process.isRunning, isFalse);
        expect(File(runtimeFile).existsSync(), isFalse);

        await process.stop(); // 幂等
        expect(server.shutdownCount, 1);
      },
    );

    test('stop 回退路径：/shutdown 404 → terminate 兜底', () async {
      final server = await StubEngineServer.start();
      addTearDown(server.close);
      server.shutdownSupported = false;
      useHandle(exitOnCloseStdin: false, exitOnKill: true);

      final spawner = fakeSpawner(
        handle: handle,
        before: () => writeRuntimeFile(runtimeFile, port: server.port),
      );

      final process = await startWith(spawner: spawner);
      await process.stop(gracefulTimeout: const Duration(milliseconds: 50));

      expect(handle.stdinClosed, isTrue);
      expect(handle.kills, contains(ProcessSignal.sigterm));
      expect(process.isRunning, isFalse);
      expect(File(runtimeFile).existsSync(), isFalse);
      expect(server.requests, contains('GET /health'));
      expect(server.requests, contains('POST /shutdown'));
    });

    test('进程自己退出后 isRunning 变 false', () async {
      final server = await StubEngineServer.start();
      addTearDown(server.close);
      final spawner = fakeSpawner(
        handle: handle,
        before: () => writeRuntimeFile(runtimeFile, port: server.port),
      );
      final process = await startWith(spawner: spawner);
      expect(process.isRunning, isTrue);
      handle.completeExit(0);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(process.isRunning, isFalse);
      expect(process.exitCode, 0);
    });
  });

  group('EngineRuntimeInfo 解析', () {
    test('完整字段', () {
      final info = EngineRuntimeInfo.fromJson(<String, dynamic>{
        'schema': 1,
        'pid': 12345,
        'port': 45871,
        'token': 'deadbeef',
        'baseUrl': 'http://127.0.0.1:45871',
        'downloadDir': r'F:\dl',
        'stateDir': r'F:\state',
        'startedAt': '2026-10-09T12:00:00Z',
      });
      expect(info.schema, 1);
      expect(info.pid, 12345);
      expect(info.port, 45871);
      expect(info.token, 'deadbeef');
      expect(info.baseUrl, Uri.parse('http://127.0.0.1:45871'));
      expect(info.downloadDir, r'F:\dl');
      expect(info.stateDir, r'F:\state');
      expect(info.startedAt, DateTime.utc(2026, 10, 9, 12));
      expect(info.toJson()['port'], 45871);
      expect(info.toString(), contains('45871'));
    });

    test('缺 baseUrl → 按 port 推导', () {
      final info = EngineRuntimeInfo.fromJson(<String, dynamic>{
        'schema': 1,
        'port': 45871,
        'token': 'x',
      });
      expect(info.baseUrl, Uri.parse('http://127.0.0.1:45871'));
      expect(info.pid, 0);
      expect(info.startedAt, isNull);
    });

    test('非法 startedAt → null 而不是崩', () {
      final info = EngineRuntimeInfo.fromJson(<String, dynamic>{
        'port': 1,
        'token': 'x',
        'startedAt': 'not-a-date',
      });
      expect(info.startedAt, isNull);
    });

    test('缺 token / 非法 port / 非法 baseUrl / 不支持的 schema → EngineException', () {
      Matcher throwsWith(String fragment) => throwsA(
        isA<EngineException>().having(
          (e) => e.message,
          'message',
          contains(fragment),
        ),
      );
      expect(
        () => EngineRuntimeInfo.fromJson(<String, dynamic>{'port': 1}),
        throwsWith('缺少 token'),
      );
      expect(
        () => EngineRuntimeInfo.fromJson(<String, dynamic>{
          'port': 0,
          'token': 'x',
        }),
        throwsWith('port=0 非法'),
      );
      expect(
        () => EngineRuntimeInfo.fromJson(<String, dynamic>{
          'port': 1,
          'token': 'x',
          'baseUrl': 'not a url',
        }),
        throwsWith('baseUrl 非法'),
      );
      expect(
        () => EngineRuntimeInfo.fromJson(<String, dynamic>{
          'schema': 9,
          'port': 1,
          'token': 'x',
        }),
        throwsWith('schema=9 不受支持'),
      );
    });
  });

  group('EngineRuntime 聚合', () {
    test('launch 定位 exe → 起进程 → 可 stop；dispose 幂等', () async {
      final server = await StubEngineServer.start();
      addTearDown(server.close);
      useHandle(exitOnCloseStdin: true);

      final spawner = fakeSpawner(
        handle: handle,
        before: () => writeRuntimeFile(runtimeFile, port: server.port),
      );
      final locator = EngineLocator(
        environment: const <String, String>{},
        currentDirectory: r'C:\repo',
        resolvedExecutable: r'C:\repo\app.exe',
        fileExists: (path) => path == r'C:\repo\rqbit-engine.exe',
      );

      final runtime = await EngineRuntime.launch(
        exePath: r'C:\repo\rqbit-engine.exe',
        downloadDir: p.join(workDir.path, 'downloads'),
        stateDir: p.join(workDir.path, 'state'),
        runtimeFile: runtimeFile,
        spawner: spawner,
        locator: locator,
        readyTimeout: const Duration(seconds: 2),
        pollInterval: const Duration(milliseconds: 20),
      );

      expect(runtime.isRunning, isTrue);
      expect(runtime.baseUrl, Uri.parse('http://127.0.0.1:${server.port}'));
      expect(runtime.token, 'testtoken');
      expect(runtime.streamUrl(1, 0).queryParameters['token'], 'testtoken');
      expect((await runtime.client.health()).version, 'stub-0.1');
      expect(runtime.toString(), contains('EngineRuntime'));

      await runtime.dispose();
      expect(runtime.isRunning, isFalse);
      await runtime.dispose();
    });
  });

  group('默认启动器（只测失败路径，不真起进程）', () {
    test('exe 不存在时抛 ProcessException，供 start 包装成可行动错误', () async {
      // 不会产生任何进程：OS 在 spawn 阶段就拒绝了。
      // 单测其余部分一律用注入的 FakeEngineProcessHandle（task-3 要求禁止真起进程）。
      await expectLater(
        defaultEngineSpawner(
          r'C:\definitely-missing-dir\rqbit-engine.exe',
          const <String>['--port', '0'],
        ),
        throwsA(isA<ProcessException>()),
      );
    });
  });
}
