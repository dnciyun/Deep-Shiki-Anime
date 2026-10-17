/// 「改一条设置要不要重启边车」的守卫 + 限速热更新（1.1.0 M1/T4）。
///
/// 这一层是自动保存的**前提**：`applySettings` 原来无条件重启边车（一次 ~3.5s、
/// 还会打断正在下载的连接），开着自动保存时"换个主题"都会重启一次引擎。
///
/// 1.1.0 M1/T4 改了一条口径：**限速不再算"必须重启"**——只改限速时先发
/// `PATCH /limits` 热更新（kbps 按 KiB/s 换算成字节/秒，见 `settings_effect.dart`）；
/// 边车不支持（404/405）或引擎没连上才回退重启，并**明确**告诉用户（不许静默当成功）。
/// 其余规则照旧：
/// * 下载目录 / 引擎路径 / 做种比 / tracker 变了 → 必须重启；
/// * 外观、TTL、省流量策略、源、订阅…→ **不许**重启。
library;

import 'dart:convert';
import 'dart:io';

import 'package:dsanima/domain/models.dart';
import 'package:dsanima/domain/ports.dart';
import 'package:dsanima/domain/settings_effect.dart';
import 'package:dsanima/domain/unavailable.dart';
import 'package:dsanima/state/engine_bootstrap.dart';
import 'package:dsanima/state/providers.dart';
import 'package:dsanima_core/dsanima_core.dart' as core;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 假边车的 HTTP 层：只认 `PATCH /limits`，把请求原样记下来供断言。
///
/// 用**真的** `core.EngineClient` + 假 transport（而不是假 client）：
/// 这样断言的是"边车真正会收到的请求体"（方法/路径/JSON 单位），
/// 连 404 的映射（`EngineException.statusCode`）也走真实客户端代码。
class _FakeSidecar {
  _FakeSidecar({this.limitsStatusCode = 200});

  /// `PATCH /limits` 的响应码；404/405 = 老边车没这个端点。
  final int limitsStatusCode;

  /// 收到过的 `PATCH /limits` 请求（按顺序）。
  final List<({String method, String path, Map<String, dynamic> body})> patches =
      <({String method, String path, Map<String, dynamic> body})>[];

  http.Client httpClient() => MockClient((http.Request request) async {
    if (request.method == 'PATCH' && request.url.path == '/limits') {
      patches.add((
        method: request.method,
        path: request.url.path,
        body: jsonDecode(request.body) as Map<String, dynamic>,
      ));
      if (limitsStatusCode != 200) {
        return http.Response(
          '{"error":"not_found"}',
          limitsStatusCode,
          headers: <String, String>{'content-type': 'application/json'},
        );
      }
      return http.Response(
        '{"downloadBps":0,"uploadBps":0}',
        200,
        headers: <String, String>{'content-type': 'application/json'},
      );
    }
    // 其它端点（`detach()` 会打 POST /shutdown）一律 404：与"旧边车没实现"一致。
    return http.Response(
      '{"error":"not_found"}',
      404,
      headers: <String, String>{'content-type': 'application/json'},
    );
  });
}

/// 真 `CoreEngineBootstrap` 的子类：只把 `start()` 换成计数，不碰真实进程。
///
/// **必须**继承真实实现：`EngineLifecyclePort` 只有认出 `CoreEngineBootstrap`
/// 才拿得到运行期 client（端口抽象只承诺 start/stop）。
class _CountingBootstrap extends CoreEngineBootstrap {
  _CountingBootstrap(super.holder);

  /// 被 `applySettings` 触发了几次真正的"重启/启动"。
  int starts = 0;

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

/// 一套"真 provider 图 + 假边车 HTTP + 计数启动器"的测试装置。
class _Harness {
  _Harness({int limitsStatusCode = 200})
    : sidecar = _FakeSidecar(limitsStatusCode: limitsStatusCode) {
    holder.attachAdopted(
      core.EngineClient(
        baseUrl: Uri.parse('http://127.0.0.1:9'),
        token: 'test-token',
        http: sidecar.httpClient(),
      ),
    );
    container = ProviderContainer(
      overrides: [
        supportDirProvider.overrideWithValue(Directory.systemTemp),
        engineBootstrapPortProvider.overrideWithValue(boot),
        // 宿主数据层用「未接通」替身：applySettings 会吞掉 PortUnavailableException，
        // 于是这些用例只看"边车被启动/热更新了几次"。
        hostDataPortProvider.overrideWithValue(const UnavailableHostDataPort()),
      ],
    );
  }

  final EngineRuntimeHolder holder = EngineRuntimeHolder();
  final _FakeSidecar sidecar;
  late final _CountingBootstrap boot = _CountingBootstrap(holder);
  late final ProviderContainer container;

  LifecyclePort get lifecycle => container.read(lifecyclePortProvider);
}

void main() {
  const AppSettings base = AppSettings(downloadDir: r'F:\Anime');

  group('字段表：谁需要重启、谁可以热更新', () {
    test('只能靠重启的进程参数：下载目录 / 引擎路径 / 做种比 / tracker', () {
      expect(engineRestartRequired(base, base.copyWith(downloadDir: r'D:\Anime')), isTrue);
      expect(engineRestartRequired(base, base.copyWith(enginePath: r'C:\e.exe')), isTrue);
      expect(engineRestartRequired(base, base.copyWith(seedRatio: 2)), isTrue);
      expect(engineRestartRequired(base, base.copyWith(extraTrackers: 'udp://x:1/a')), isTrue);
    });

    test('只改限速 → 不需要重启（走热更新），上下行都算', () {
      final AppSettings uploadOnly = base.copyWith(uploadLimitKbps: 999);
      final AppSettings downloadOnly = base.copyWith(downloadLimitKbps: 999);
      for (final AppSettings next in <AppSettings>[uploadOnly, downloadOnly]) {
        expect(engineRestartRequired(base, next), isFalse, reason: '限速有 PATCH /limits 热更新通道');
        expect(engineLimitsChanged(base, next), isTrue);
        expect(engineLimitsOnlyChanged(base, next), isTrue);
      }
      expect(engineRestartRequired(base, base), isFalse);
      expect(engineLimitsOnlyChanged(base, base), isFalse);
    });

    test('限速 + 下载目录一起改 → 需要重启（靠重启一起生效，不该先试热更）', () {
      final AppSettings next = base.copyWith(
        downloadLimitKbps: 512,
        downloadDir: r'D:\Anime',
      );
      expect(engineRestartRequired(base, next), isTrue);
      expect(engineLimitsChanged(base, next), isTrue);
      expect(engineLimitsOnlyChanged(base, next), isFalse, reason: '目录变了就没得省，必须重启');
    });

    test('宿主侧就能换的设置：不许重启边车（否则每次保存都白等 3.5 秒）', () {
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
        // 全仓没有任何 `--proxy-*` 进程参数。
        base.copyWith(proxyMode: ProxyMode.socks5),
        base.copyWith(proxyHost: '10.0.0.9'),
        base.copyWith(proxyPort: 1081),
        base.copyWith(proxyUsername: 'u'),
        base.copyWith(proxyPassword: 'p'),
      ];
      for (final AppSettings next in onlyHostSide) {
        expect(engineRestartRequired(base, next), isFalse, reason: '这些改完宿主侧重建即可：${next.toJson()}');
        expect(engineLimitsOnlyChanged(base, next), isFalse, reason: '没改限速就不该走热更新：${next.toJson()}');
      }
    });

    test('engineRestartReasons 不再把限速算进来（限速那条文案由 applySettings 自己拼）', () {
      expect(
        engineRestartReasons(base, base.copyWith(downloadLimitKbps: 1, seedRatio: 1)),
        <String>['做种比'],
        reason: '限速走热更新，不再算"必须重启"的原因',
      );
      expect(
        engineRestartReasons(
          base,
          base.copyWith(
            downloadDir: r'D:\Anime',
            enginePath: r'C:\e.exe',
            seedRatio: 2,
            extraTrackers: 'udp://x:1/a',
          ),
        ),
        <String>['下载目录', '引擎路径', '做种比', 'tracker 列表'],
      );
    });
  });

  group('kbps → bytes/s 换算（与边车启动参数同一口径）', () {
    test('×1024；0 = 不限原样传 0；超过 u32 上限饱和到 u32::MAX', () {
      expect(limitKbpsToBps(0), 0, reason: '0 = 不限：边车 to_limit(0) → None');
      expect(limitKbpsToBps(1), 1024);
      expect(limitKbpsToBps(100), 102400, reason: '上传默认 100 KiB/s');
      expect(limitKbpsToBps(512), 524288);
      expect(limitKbpsToBps(4194303), 4294966272, reason: '还没到上限的最后一档');
      expect(limitKbpsToBps(4194304), kEngineMaxLimitBytesPerSecond, reason: '×1024 会超 u32 → 饱和');
      expect(
        limitKbpsToBps(9007199254740991),
        kEngineMaxLimitBytesPerSecond,
        reason: '设置页不校验上限；先比上限再乘，绝不会溢出成负数',
      );
      expect(limitKbpsToBps(-5), 0, reason: '设置页挡了负数，纯函数也按"不限"兜底');
    });

    test('engineLimitsPatch 只带变了的那一路（缺省 = 不改）', () {
      expect(
        engineLimitsPatch(base, base.copyWith(uploadLimitKbps: 200)),
        (downloadBps: null, uploadBps: 204800),
      );
      expect(
        engineLimitsPatch(base, base.copyWith(downloadLimitKbps: 512)),
        (downloadBps: 524288, uploadBps: null),
      );
      expect(
        engineLimitsPatch(base, base.copyWith(uploadLimitKbps: 200, downloadLimitKbps: 4096)),
        (downloadBps: 4194304, uploadBps: 204800),
      );
    });
  });

  group('EngineLifecyclePort：限速热更新（假边车，不起真进程）', () {
    test('只改限速 → restarts == 0 且 PATCH /limits 收到换算后的 bytes/s', () async {
      final _Harness h = _Harness();
      addTearDown(h.container.dispose);

      // 首次：还没有"在跑的进程" → 必须启动（顺便把 launchedWith 基线种下）。
      await h.lifecycle.applySettings(base);
      expect(h.boot.starts, 1, reason: '还没跑起来时必须启动');
      expect(h.sidecar.patches, isEmpty, reason: '第一次是启动，不是热更新');

      final AppSettings faster = base.copyWith(
        uploadLimitKbps: 200,
        downloadLimitKbps: 4096,
      );
      await h.lifecycle.applySettings(faster);
      expect(h.boot.starts, 1, reason: '只改限速不许重启边车（省 ~3.5s、不打断正在下载的连接）');
      expect(h.sidecar.patches, hasLength(1));
      expect(h.sidecar.patches.single.method, 'PATCH');
      expect(h.sidecar.patches.single.path, '/limits');
      expect(h.sidecar.patches.single.body, <String, dynamic>{
        'downloadBps': 4096 * 1024,
        'uploadBps': 200 * 1024,
      });
      // 成功文案：说清"这次没重启"（1.1.0 M1/T4：用户要知道这次省了 3.5s）。
      expect(h.container.read(engineApplyNoteProvider), contains('限速已热更新'));

      // 「已生效设置」对齐：同一份设置再保存一次 → 不该重复热更（launchedWith 已推进）。
      await h.lifecycle.applySettings(faster);
      expect(h.boot.starts, 1);
      expect(h.sidecar.patches, hasLength(1), reason: '热更新成功后 launchedWith 必须跟上，否则每次都白发一遍');

      // 只改外观 → 既不重启也不热更，也不该留下上一轮的"已热更新"话术。
      await h.lifecycle.applySettings(faster.copyWith(themeId: 'b_mono'));
      expect(h.boot.starts, 1);
      expect(h.sidecar.patches, hasLength(1));
      expect(h.container.read(engineApplyNoteProvider), isNull,
          reason: '没碰边车就不该说边车的结局（上一轮的话术要清掉）');

      // 再只改一路（只改上传）→ 只热更那一路，不带 downloadBps。
      await h.lifecycle.applySettings(faster.copyWith(uploadLimitKbps: 300));
      expect(h.boot.starts, 1);
      expect(h.sidecar.patches, hasLength(2));
      expect(h.sidecar.patches.last.body, <String, dynamic>{'uploadBps': 300 * 1024});
    });

    test('边车不支持 PATCH /limits（404）→ 回退重启 + 成功文案里说明「需要重启边车」', () async {
      final _Harness h = _Harness(limitsStatusCode: 404);
      addTearDown(h.container.dispose);
      await h.lifecycle.applySettings(base);
      expect(h.boot.starts, 1);

      // ⚠️ 重启**成功**时不许抛异常（那会把一次成功的保存画成红色失败横幅）；
      // 「这次是靠重启生效的、以后还会重启」走 engineApplyNoteProvider 进成功文案。
      final AppSettings slower = base.copyWith(downloadLimitKbps: 512);
      await h.lifecycle.applySettings(slower);
      final String note = h.container.read(engineApplyNoteProvider)!;
      expect(note, contains('这个引擎版本不支持热改限速'));
      expect(note, contains('需要重启边车'));
      expect(note, contains('以后每次改限速仍会重启'));
      expect(h.boot.starts, 2, reason: '热更新不行 → 走原来的重启路径让限速生效');
      expect(h.sidecar.patches, hasLength(1), reason: '先试过热更新才会回退');
      expect(h.sidecar.patches.single.body, <String, dynamic>{'downloadBps': 512 * 1024});
    });

    test('引擎没连上（运行期被摘掉）→ 回退重启 + 明确说「没连上、需要重启边车」', () async {
      final _Harness h = _Harness();
      addTearDown(h.container.dispose);
      await h.lifecycle.applySettings(base);
      expect(h.boot.starts, 1);

      await h.holder.detach();
      expect(h.holder.client, isNull, reason: '模拟边车死了/没接上');

      await h.lifecycle.applySettings(base.copyWith(uploadLimitKbps: 300));
      final String note = h.container.read(engineApplyNoteProvider)!;
      expect(note, contains('没连上'));
      expect(note, contains('需要重启边车'));
      expect(h.boot.starts, 2, reason: '没连上也要把重启路径走通');
      expect(h.sidecar.patches, isEmpty, reason: '没 client 就不可能发出 PATCH');
    });

    test('其它进程参数变了 → 照旧重启（不退化、不蹭热更新）', () async {
      final _Harness h = _Harness();
      addTearDown(h.container.dispose);
      await h.lifecycle.applySettings(base);
      expect(h.boot.starts, 1);

      // 限速 + 下载目录一起改：目录只能重启，限速跟着新进程参数一起生效。
      final AppSettings dirAndLimits = base.copyWith(
        downloadDir: r'D:\Anime',
        uploadLimitKbps: 900,
      );
      await h.lifecycle.applySettings(dirAndLimits);
      expect(h.boot.starts, 2, reason: '下载目录变了必须重启');
      expect(h.sidecar.patches, isEmpty, reason: '这次不该先试热更新');

      // 引擎路径 / 做种比 / tracker 同理。
      await h.lifecycle.applySettings(dirAndLimits.copyWith(seedRatio: 2));
      expect(h.boot.starts, 3);
      await h.lifecycle.applySettings(dirAndLimits.copyWith(seedRatio: 2, extraTrackers: 'udp://x:1/a'));
      expect(h.boot.starts, 4);
      expect(h.sidecar.patches, isEmpty);
    });
  });
}
