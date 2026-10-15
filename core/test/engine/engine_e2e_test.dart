import 'dart:async';
import 'dart:io';

import 'package:dsanima_core/dsanima_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// 真实边车的端到端冒烟测试（spec §6.4 的自动化版本）。
///
/// **默认跳过**：只有显式设置环境变量 `DSANIMA_ENGINE_E2E=1` 才会运行，
/// 因此日常 `flutter test` 仍然满足 task-3 的硬约束「禁止联网、禁止真起进程」。
///
/// 手动跑：
/// ```pwsh
/// $env:DSANIMA_ENGINE_E2E='1'; cd core; flutter test test/engine/engine_e2e_test.dart
/// ```
///
/// 它验证的正是单测无法覆盖的真实路径：`defaultEngineSpawner` +
/// `IoEngineProcessHandle` + runtime.json 就绪轮询 + 真实 HTTP/SSE + stop 收尾。
void main() {
  final enabled = Platform.environment['DSANIMA_ENGINE_E2E'] == '1';
  final exePath = enabled ? _locateEngine() : null;
  final skipReason = !enabled
      ? '端到端测试默认跳过：设置 DSANIMA_ENGINE_E2E=1 后运行（需要已构建的 rqbit-engine）'
      : (exePath == null
            ? '未找到 rqbit-engine 可执行文件：先执行 `cd engine && cargo build --release`，'
                  '或设置 DSANIMA_ENGINE 环境变量'
            : null);

  group('真实边车端到端', () {
    late Directory workDir;
    late EngineProcess process;

    setUp(() async {
      workDir = await Directory.systemTemp.createTemp('dsanima_e2e');
      process = await EngineProcess.start(
        exePath: exePath!,
        downloadDir: p.join(workDir.path, 'downloads'),
        stateDir: p.join(workDir.path, 'state'),
        readyTimeout: const Duration(seconds: 30),
      );
    });

    tearDown(() async {
      await process.stop();
      if (workDir.existsSync()) await workDir.delete(recursive: true);
    });

    test(
      'start → runtime.json 就绪 → /health → /torrents → stop',
      () async {
        expect(process.isRunning, isTrue);
        expect(File(process.runtimeFile).existsSync(), isTrue);
        expect(process.port, greaterThan(0));
        expect(process.token, isNotEmpty);

        final health = await process.client.health();
        expect(health.ok, isTrue, reason: '/health 必须返回 ok=true');

        final torrents = await process.client.list();
        expect(torrents, isA<List<EngineTorrent>>());

        final url = process.client.streamUrl(1, 0);
        expect(url.path, '/torrents/1/files/0/stream');
        expect(url.queryParameters['token'], process.token);

        // 鉴权：错误 token 必须被拒（spec §3.3）。
        final badClient = EngineClient(
          baseUrl: process.baseUrl,
          token: 'wrong-token',
        );
        addTearDown(badClient.close);
        await expectLater(
          badClient.list(),
          throwsA(
            isA<EngineException>().having(
              (e) => e.statusCode,
              'statusCode',
              401,
            ),
          ),
        );

        await process.stop();
        expect(process.isRunning, isFalse);
        expect(
          File(process.runtimeFile).existsSync(),
          isFalse,
          reason: 'stop 要清掉 runtime.json',
        );
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );

    test(
      'GET /events 连接后立即收到 snapshot（spec §3.9）',
      () async {
        final events = <EngineEvent>[];
        final gotSnapshot = Completer<void>();
        final subscription = process.client.events().listen((event) {
          events.add(event);
          if (event is EngineSnapshot && !gotSnapshot.isCompleted) {
            gotSnapshot.complete();
          }
        });
        addTearDown(subscription.cancel);

        await gotSnapshot.future.timeout(const Duration(seconds: 15));
        expect(events.whereType<EngineSnapshot>(), hasLength(1));
        expect(events.first, isA<EngineSnapshot>(), reason: '第一个事件必须是全量快照');
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );
  }, skip: skipReason);
}

String? _locateEngine() {
  try {
    return EngineLocator().locate();
  } on EngineException {
    return null;
  }
}
