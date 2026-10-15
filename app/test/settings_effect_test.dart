/// 「改一条设置要不要重启边车」的守卫（用户 2026-10-11 第二阶段清单第 6 项：
/// 设置页自动保存）。
///
/// 这一层是自动保存的**前提**：`applySettings` 原来无条件重启边车（一次 ~3.5s、
/// 还会打断正在下载的连接），开着自动保存时"换个主题"都会重启一次引擎。
/// 所以规则要钉死：
/// * 进程参数（下载目录/exe/限速/做种/tracker/代理）变了 → 必须重启；
/// * 其余（外观、TTL、省流量策略、源、订阅…）→ **不许**重启。
library;

import 'dart:io';

import 'package:dsanima/domain/models.dart';
import 'package:dsanima/domain/ports.dart';
import 'package:dsanima/domain/settings_effect.dart';
import 'package:dsanima/domain/unavailable.dart';
import 'package:dsanima/state/providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// 只记「被启动了几次」的边车端口替身（不碰真实进程/网络）。
class _FakeBootstrap implements EngineBootstrapPort {
  int starts = 0;

  @override
  bool get isRunning => starts > 0;

  @override
  Future<EngineStartOutcome> start({
    required AppSettings settings,
    required Directory supportDir,
  }) async {
    starts++;
    return const EngineStartOutcome(ok: true, exePath: r'F:\Anime\rqbit-engine.exe');
  }

  @override
  Future<void> stop() async {}
}

void main() {
  test('进程参数清单：这些变了必须重启边车', () {
    const AppSettings base = AppSettings(downloadDir: r'F:\Anime');
    expect(engineRestartRequired(base, base.copyWith(downloadDir: r'D:\Anime')), isTrue);
    expect(engineRestartRequired(base, base.copyWith(enginePath: r'C:\e.exe')), isTrue);
    expect(engineRestartRequired(base, base.copyWith(uploadLimitKbps: 999)), isTrue);
    expect(engineRestartRequired(base, base.copyWith(downloadLimitKbps: 999)), isTrue);
    expect(engineRestartRequired(base, base.copyWith(seedRatio: 2)), isTrue);
    expect(engineRestartRequired(base, base.copyWith(extraTrackers: 'udp://x:1/a')), isTrue);
  });

  test('宿主侧就能换的设置：不许重启边车（否则每次保存都白等 3.5 秒）', () {
    const AppSettings base = AppSettings(downloadDir: r'F:\Anime');
    final List<AppSettings> onlyHostSide = <AppSettings>[
      base.copyWith(themeId: 'b_mono'),
      base.copyWith(carouselShape: 'portrait'),
      base.copyWith(sourceCacheTtlSeconds: 60),
      base.copyWith(sourceDetailCacheTtlSeconds: 60),
      base.copyWith(sourceRequestIntervalMs: 50),
      base.copyWith(defaultSourceId: 'nyaa'),
      base.copyWith(autoPlayNext: false),
      base.copyWith(sukebeiEnabled: true),
      base.copyWith(backgroundResident: true),
      base.copyWith(complianceAccepted: true),
      base.copyWith(firstRunCompleted: true),
      base.copyWith(bandwidth: const BandwidthPolicy(preheatAhead: 2, maxConcurrent: 3)),
      base.copyWith(trackerListUpdatedAt: DateTime(2026, 10, 11)),
      base.copyWith(trackerSourceUrls: <String>['https://example.com/list.txt']),
      // 做种开关：真正生效的是**宿主侧**的 `queue.setPolicy(stopSeedingAfterDownload:)`
      // （`host_data.dart:203`）—— `--seed-ratio 0` 在边车里的语义是"不做任何做种干预"，
      // 表达不了这个开关。
      base.copyWith(seedEnabled: true),
      // 代理：只用于**抓取**（宿主侧 `SourceRegistry` 的 proxy 配置，`host_data.dart:383`），
      // 全仓没有任何 `--proxy-*` 进程参数。把它们算进"进程参数"会白白重启边车、
      // 打断正在下载的连接，而进程参数一个都没变。
      base.copyWith(proxyMode: ProxyMode.socks5),
      base.copyWith(proxyHost: '10.0.0.9'),
      base.copyWith(proxyPort: 1081),
      base.copyWith(proxyUsername: 'u'),
      base.copyWith(proxyPassword: 'p'),
    ];
    for (final AppSettings next in onlyHostSide) {
      expect(engineRestartRequired(base, next), isFalse, reason: '这些改完宿主侧重建即可：${next.toJson()}');
    }
    expect(engineRestartRequired(base, base), isFalse);
    expect(engineRestartReasons(base, base.copyWith(downloadLimitKbps: 1, seedRatio: 1)), <String>[
      '下载限速',
      '做种比',
    ]);
  });

  test('EngineLifecyclePort：只在进程参数变了时才真的重启（不然自动保存不敢开）', () async {
    final _FakeBootstrap boot = _FakeBootstrap();
    // 不写显式类型：交给 `ProviderContainer(overrides: ...)` 的形参上下文推断即可
    //（本机 riverpod 3.4.3 没把 `Override` 从这个 barrel 导出）。
    final ProviderContainer container = ProviderContainer(
      overrides: [
        supportDirProvider.overrideWithValue(Directory.systemTemp),
        engineBootstrapPortProvider.overrideWithValue(boot),
        // 宿主数据层用「未接通」替身：applySettings 会吞掉 PortUnavailableException，
        // 于是这条测试只看边车被启动了没有。
        hostDataPortProvider.overrideWithValue(const UnavailableHostDataPort()),
      ],
    );
    final LifecyclePort lifecycle = container.read(lifecyclePortProvider);

    const AppSettings base = AppSettings(downloadDir: r'F:\Anime');
    // 首次：还没有"在跑的进程" → 必须启动。
    await lifecycle.applySettings(base);
    expect(boot.starts, 1, reason: '还没跑起来时必须启动');

    // 只改外观 → 不重启（这就是自动保存能 1s 一落地的原因）。
    await lifecycle.applySettings(
      base.copyWith(themeId: 'b_mono', homeCoverSize: 'l'),
    );
    expect(boot.starts, 1, reason: '改外观不该重启边车');

    // 改进程参数 → 必须重启。
    await lifecycle.applySettings(base.copyWith(downloadLimitKbps: 512));
    expect(boot.starts, 2, reason: '限速是进程参数，必须重启才生效');

    // 再改一次同样的值：launchedWith 已经是它了 → 不重启。
    await lifecycle.applySettings(base.copyWith(downloadLimitKbps: 512));
    expect(boot.starts, 2, reason: '同样的设置不该反复重启');

    container.dispose();
  });
}
