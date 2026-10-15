/// 边车启动/重启的两条不变式（审查发现的回归点）。
///
/// 1. **不许先停后失败**：`CoreEngineBootstrap.start()` 一进来就 `detach()`（真的停掉
///    正在跑的边车）。旧顺序是"detach → 接管探测 → 定位 exe"，于是用户在设置里把
///    exe 路径改错一次并保存，结果不是"报错但引擎照旧在跑"，而是**引擎直接没了**
///    （locate 抛错 → 返回 failure，旧进程已经被停掉、也没有回滚）。
/// 2. **不许并发**：设置页保存与 tracker 每日刷新会各自调一次 `applySettings` →
///    `start()`；两次并发 start 会互相 detach 掉对方刚拉起来的进程。
library;

import 'dart:async';
import 'dart:io';

import 'package:dsanima/domain/models.dart';
import 'package:dsanima/domain/ports.dart';
import 'package:dsanima/domain/unavailable.dart';
import 'package:dsanima/state/engine_bootstrap.dart';
import 'package:dsanima/state/providers.dart';
import 'package:dsanima_core/dsanima_core.dart' as core;
import 'package:dsanima_core/sources/kv.dart' show InMemoryKeyValueStore;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// 可以卡住的假边车端口：每次 `start()` 都等自己的那扇门。
class _GatedBootstrap implements EngineBootstrapPort {
  final List<AppSettings> started = <AppSettings>[];
  final List<Completer<void>> gates = <Completer<void>>[];

  int _concurrent = 0;
  int maxConcurrent = 0;

  @override
  bool get isRunning => started.isNotEmpty;

  @override
  Future<EngineStartOutcome> start({
    required AppSettings settings,
    required Directory supportDir,
  }) async {
    started.add(settings);
    _concurrent++;
    if (_concurrent > maxConcurrent) maxConcurrent = _concurrent;
    final Completer<void> gate = Completer<void>();
    gates.add(gate);
    await gate.future;
    _concurrent--;
    return const EngineStartOutcome(ok: true, exePath: 'test-engine.exe');
  }

  @override
  Future<void> stop() async {}
}

void main() {
  test('exe 路径错 → 绝不先把正在跑的边车停掉（旧顺序 detach-first 会让引擎直接没了）', () async {
    final Directory support = Directory.systemTemp.createTempSync('dsanima_bootstrap_');
    addTearDown(() {
      if (support.existsSync()) support.deleteSync(recursive: true);
    });

    // 假装现在有一个在跑的运行期（不起真进程：EngineRuntimeHolder 可以直接接管客户端）。
    final EngineRuntimeHolder holder = EngineRuntimeHolder();
    holder.attachAdopted(core.EngineClient(baseUrl: Uri.parse('http://127.0.0.1:1'), token: 't'));
    expect(holder.isAttached, isTrue);

    final CoreEngineBootstrap bootstrap = CoreEngineBootstrap(holder);
    final EngineStartOutcome outcome = await bootstrap.start(
      settings: const AppSettings(
        downloadDir: r'F:\Anime',
        enginePath: r'F:\nope\不存在\rqbit-engine.exe',
      ),
      supportDir: support,
    );

    expect(outcome.ok, isFalse, reason: '路径错就该显式失败');
    expect(outcome.message, contains('不存在'));
    expect(
      holder.isAttached,
      isTrue,
      reason: '定位失败必须发生在停掉旧引擎**之前**：否则用户改错一次路径就失去引擎',
    );
  });

  test('并发 start：排队执行，绝不互相掐掉对方刚拉起来的引擎', () async {
    final _GatedBootstrap boot = _GatedBootstrap();
    final ProviderContainer container = ProviderContainer(
      overrides: [
        keyValueStoreProvider.overrideWithValue(InMemoryKeyValueStore()),
        engineBootstrapPortProvider.overrideWithValue(boot),
        supportDirProvider.overrideWithValue(Directory.systemTemp),
        hostDataPortProvider.overrideWithValue(const UnavailableHostDataPort()),
      ],
    );
    addTearDown(container.dispose);

    const AppSettings settings = AppSettings(downloadDir: r'F:\Anime');
    final notifier = container.read(engineBootstrapProvider.notifier);
    final Future<bool> first = notifier.start(
      settings: settings,
      supportDir: Directory.systemTemp,
    );
    final Future<bool> second = notifier.start(
      settings: settings,
      supportDir: Directory.systemTemp,
    );

    await pumpEventQueue();
    expect(boot.started, hasLength(1), reason: '第二次不许在第一次还没回来时也进 port');

    boot.gates.first.complete();
    await pumpEventQueue();
    expect(boot.started, hasLength(2), reason: '第二次排到第一次结束之后再执行');

    boot.gates[1].complete();
    expect(await first, isTrue);
    expect(await second, isTrue);
    expect(
      boot.maxConcurrent,
      1,
      reason: '两次 start 绝不并发：CoreEngineBootstrap 一进来就 detach，会掐掉对方的进程',
    );
  });
}
