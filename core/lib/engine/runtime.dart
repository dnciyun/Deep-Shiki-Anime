/// 进程 + 客户端的轻量聚合（Provider 无关，供宿主 `app/` 直接持有）。
library;

import 'client.dart';
import 'locator.dart';
import 'process.dart';
import 'sse.dart';

/// 一个跑起来的边车：`EngineProcess`（进程）+ `EngineClient`（HTTP/SSE）。
///
/// 刻意不依赖 Riverpod / Flutter：宿主可以放进任何 DI 里，
/// 退出时调用 [dispose]，或直接调用 [EngineProcess.stop]。
class EngineRuntime {
  EngineRuntime({required this.process, required this.client});

  /// 边车进程。
  final EngineProcess process;

  /// 复用的 HTTP/SSE 客户端。
  final EngineClient client;

  /// 定位 exe → 拉起进程 → 等到就绪 → 建客户端。
  ///
  /// [exePath] 为 `null` 时用 [EngineLocator] 自动查找（显式路径优先于自动查找）。
  static Future<EngineRuntime> launch({
    String? exePath,
    required String downloadDir,
    required String stateDir,
    String? runtimeFile,
    int port = 0,
    List<String> extraArgs = const <String>[],
    EngineSpawner? spawner,
    EngineLocator? locator,
    Duration readyTimeout = EngineProcess.defaultReadyTimeout,
    Duration pollInterval = EngineProcess.defaultPollInterval,
    Map<String, String>? environment,
    String? workingDirectory,
    EngineSleep? sleep,
  }) async {
    final resolved = (locator ?? EngineLocator()).locate(exePath: exePath);
    final process = await EngineProcess.start(
      exePath: resolved,
      downloadDir: downloadDir,
      stateDir: stateDir,
      runtimeFile: runtimeFile,
      port: port,
      extraArgs: extraArgs,
      spawner: spawner,
      readyTimeout: readyTimeout,
      pollInterval: pollInterval,
      environment: environment,
      workingDirectory: workingDirectory,
      sleep: sleep,
    );
    return EngineRuntime(process: process, client: process.client);
  }

  /// 引擎根地址。
  Uri get baseUrl => client.baseUrl;

  /// 鉴权 token。
  String get token => client.token;

  /// 进程是否仍在运行。
  bool get isRunning => process.isRunning;

  /// 交给 mpv 的串流 URL（含 token）。
  Uri streamUrl(int id, int fileIndex) => client.streamUrl(id, fileIndex);

  /// 收尾：停进程 + 关连接。幂等。
  Future<void> dispose() async {
    await process.stop();
    client.close();
  }

  @override
  String toString() => 'EngineRuntime(${process.describe()})';
}
