/// tracker **每日自动刷新**（用户 2026-10-11：「tracker加入每日刷新一次逻辑」）。
///
/// 这一层守五件事：
/// * 到期规则（null / 满 24h / 时钟回拨都算到期）—— 纯函数，时钟注入，不用真等一天；
/// * 多来源**并发**拉取 + 合并去重 + 逐来源说明（与设置页「一键更新」同一份实现）；
/// * 全部失败 → 回落离线快照，且**不写 trackerListUpdatedAt**（否则明天不会再试）；
/// * 整轮有总超时：网络烂掉也不能把启动流程挂住；
/// * **首次启动的时机**（用户 2026-10-11：「trackers 首次启动自动加载一次」）：
///   `ensureTrackersAtStartup` 必须赶在边车 `start()` 之前把列表拿到手 —— tracker 是
///   边车的进程启动参数，晚一步这一轮就白拉；反过来"未到期"时一个请求都不许发。
library;

import 'dart:async';
import 'dart:io';

import 'package:dsanima/domain/models.dart';
import 'package:dsanima/domain/ports.dart';
import 'package:dsanima/domain/trackers.dart';
import 'package:dsanima/domain/unavailable.dart';
import 'package:dsanima/state/providers.dart';
import 'package:dsanima/state/tracker_refresh.dart';
import 'package:dsanima_core/sources/kv.dart' show InMemoryKeyValueStore;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const String _urlA = 'https://example.com/a.txt';
const String _urlB = 'https://example.com/b.txt';

/// 假取数：`bodies` 里有的返回正文，`failing` 里的抛异常，其余抛"网络请求失败"。
TrackerRefreshService _service({
  Map<String, String> bodies = const <String, String>{},
  Set<String> failing = const <String>{},
  DateTime? clock,
}) => TrackerRefreshService(
  fetch: (Uri url) async {
    final String key = url.toString();
    if (failing.contains(key)) throw Exception('网络请求失败');
    final String? body = bodies[key];
    if (body != null) return body;
    throw Exception('网络请求失败');
  },
  clock: clock == null ? null : () => clock,
);

/// 只记「被启动了几次」的边车端口替身（不碰真实进程/网络）。
class _FakeBootstrap implements EngineBootstrapPort {
  int starts = 0;

  /// 最后一次 `start()` 收到的设置：验"预载到的 tracker 有没有真的喂给随后那次 start()"。
  AppSettings? lastSettings;

  @override
  bool get isRunning => starts > 0;

  @override
  Future<EngineStartOutcome> start({
    required AppSettings settings,
    required Directory supportDir,
  }) async {
    starts++;
    lastSettings = settings;
    return const EngineStartOutcome(ok: true, exePath: r'F:\Anime\rqbit-engine.exe');
  }

  @override
  Future<void> stop() async {}
}

void main() {
  group('trackerRefreshDue：到期的判据', () {
    final DateTime now = DateTime(2026, 10, 11, 12);

    test('从没更新过（null）→ 到期', () {
      expect(trackerRefreshDue(null, now), isTrue);
    });

    test('未满 24 小时 → 不到期', () {
      expect(trackerRefreshDue(now.subtract(const Duration(hours: 23)), now), isFalse);
      expect(trackerRefreshDue(now.subtract(const Duration(minutes: 1)), now), isFalse);
      expect(trackerRefreshDue(now, now), isFalse);
    });

    test('满 24 小时 → 到期（边界按 interval 算）', () {
      expect(trackerRefreshDue(now.subtract(const Duration(hours: 24)), now), isTrue);
      expect(trackerRefreshDue(now.subtract(const Duration(days: 3)), now), isTrue);
    });

    test('时钟回拨（now 早于上次更新）→ 也算到期，不能因为时间倒流就永远不更新', () {
      expect(trackerRefreshDue(now.add(const Duration(hours: 5)), now), isTrue);
    });

    test('周期可注入（单测不必等一天）', () {
      const Duration hour = Duration(hours: 1);
      expect(
        trackerRefreshDue(now.subtract(const Duration(hours: 2)), now, interval: hour),
        isTrue,
      );
      expect(
        trackerRefreshDue(now.subtract(const Duration(minutes: 30)), now, interval: hour),
        isFalse,
      );
    });
  });

  group('TrackerRefreshService：多来源 + 合并去重 + 回落快照', () {
    test('多个来源：按来源顺序合并、跨来源去重，text 是逗号分隔', () async {
      final TrackerListResult result = await _service(
        bodies: <String, String>{
          _urlA: 'udp://x:1/a\nudp://y:2/a',
          _urlB: 'udp://y:2/a\nudp://z:3/a',
        },
      ).fetchTrackerList(<String>[_urlA, _urlB]);

      expect(result.fetchedFromSources, isTrue);
      expect(result.trackers, <String>['udp://x:1/a', 'udp://y:2/a', 'udp://z:3/a']);
      expect(result.text, 'udp://x:1/a,udp://y:2/a,udp://z:3/a');
      expect(result.sources.every((TrackerSourceResult s) => s.ok), isTrue);
      expect(result.note, contains('已合并 2/2'));
      expect(result.note, contains('3 个 tracker'));
    });

    test('部分失败：拿到的那部分照用，没拿到的逐条说明原因', () async {
      final TrackerListResult result = await _service(
        bodies: <String, String>{_urlA: 'udp://x:1/a'},
        failing: <String>{_urlB},
      ).fetchTrackerList(<String>[_urlA, _urlB]);

      expect(result.fetchedFromSources, isTrue, reason: '部分成功就是成功，不该整轮回落');
      expect(result.trackers, <String>['udp://x:1/a']);
      expect(result.sources.where((TrackerSourceResult s) => s.ok).length, 1);
      expect(result.note, contains('已合并 1/2'));
      expect(result.note, contains('example.com/b.txt'), reason: '提示里要能看出是哪个来源没拿到');
    });

    test('空响应（200 但一条都没有）也算没拿到', () async {
      final TrackerListResult result = await _service(
        bodies: <String, String>{_urlA: '   \n  '},
      ).fetchTrackerList(<String>[_urlA]);

      expect(result.fetchedFromSources, isFalse);
      expect(result.trackers, builtinTrackers);
      expect(result.sources.single.error, '空响应');
    });

    test('全部失败 → 回落离线快照，逐来源说明', () async {
      final TrackerListResult result = await _service(
        failing: <String>{_urlA, _urlB},
      ).fetchTrackerList(<String>[_urlA, _urlB]);

      expect(result.fetchedFromSources, isFalse);
      expect(result.trackers, builtinTrackers);
      expect(result.sources.length, 2);
      expect(result.note, contains('全部来源都没拿到'));
      expect(result.note, contains('内置离线列表'));
    });

    test('来源清单为空 → 直接用离线快照（不试网络）', () async {
      final TrackerListResult result = await _service().fetchTrackerList(<String>[]);
      expect(result.fetchedFromSources, isFalse);
      expect(result.trackers, builtinTrackers);
      expect(result.note, contains('没有配置来源'));
    });

    test('来源清单先规范化：无效项/重复项/空白项都被丢掉', () async {
      final TrackerListResult result = await _service(
        bodies: <String, String>{_urlA: 'udp://x:1/a'},
      ).fetchTrackerList(<String>[_urlA, 'ftp://example.com/x', ' $_urlA ', '   ']);

      expect(result.sources.length, 1, reason: '只剩一条有效来源');
      expect(result.sources.single.url, _urlA);
    });

    test('整轮总超时：不挂死，按"没拿到"回落（已经拿到的照用）', () async {
      final TrackerRefreshService service = TrackerRefreshService(
        // 永不完成的取数：模拟网络栈卡住（单来源超时也被刻意调长，逼出总超时这条兜底）。
        fetch: (Uri url) => Completer<String>().future,
        sourceTimeout: const Duration(milliseconds: 300),
        totalTimeout: const Duration(milliseconds: 50),
      );
      final TrackerListResult result = await service.fetchTrackerList(<String>[_urlA]);

      expect(result.fetchedFromSources, isFalse);
      expect(result.trackers, builtinTrackers);
      expect(result.sources.single.error, contains('总超时'));
    });
  });

  group('refreshTrackersIfDue：到期才拉，真的拿到才写', () {
    final DateTime now = DateTime(2026, 10, 11, 12);

    test('未到期 → 不碰网络、不写设置', () async {
      int fetches = 0;
      int writes = 0;
      final TrackerRefreshService service = TrackerRefreshService(
        fetch: (Uri url) async {
          fetches++;
          return 'udp://x:1/a';
        },
        clock: () => now,
      );

      final TrackerRefreshOutcome outcome = await refreshTrackersIfDue(
        settings: AppSettings(
          extraTrackers: 'udp://old:1/a',
          trackerListUpdatedAt: now.subtract(const Duration(hours: 1)),
        ),
        patchSettings: (AppSettings Function(AppSettings) mutate) async => writes++,
        service: service,
      );

      expect(outcome.due, isFalse);
      expect(outcome.updated, isFalse);
      expect(fetches, 0);
      expect(writes, 0);
    });

    test('到期 + 拿到 → 写 extraTrackers（逗号分隔）与 trackerListUpdatedAt，返回 updated', () async {
      // 来源清单显式给 [_urlA]：默认清单是 ngosang 那条真 URL，替身会当成"没拿到"。
      const AppSettings base = AppSettings(
        extraTrackers: 'udp://old:1/a',
        trackerSourceUrls: <String>[_urlA],
      );
      AppSettings? written;
      final TrackerRefreshOutcome outcome = await refreshTrackersIfDue(
        settings: base,
        // 合并函数作用在"写入那一刻的最新设置"上（这里没人在拉取期间改设置，就是 base）。
        patchSettings: (AppSettings Function(AppSettings) mutate) async =>
            written = mutate(base),
        service: _service(
          bodies: <String, String>{_urlA: 'udp://x:1/a\nudp://y:2/a'},
          clock: now,
        ),
        now: now,
      );

      expect(outcome.due, isTrue);
      expect(outcome.updated, isTrue);
      expect(outcome.fellBack, isFalse);
      expect(written, isNotNull);
      expect(written!.extraTrackers, 'udp://x:1/a,udp://y:2/a');
      expect(written!.trackerListUpdatedAt, now);
      expect(written!.trackerSourceUrls, <String>[_urlA], reason: '只动 tracker 那两个字段');
    });

    test('到期 + 全部失败 → 回落快照、**不写**时间戳、不写 extraTrackers（明天还会再试）', () async {
      int writes = 0;
      final TrackerRefreshOutcome outcome = await refreshTrackersIfDue(
        settings: AppSettings(
          extraTrackers: 'udp://mine:1/a',
          trackerSourceUrls: const <String>[_urlA],
          trackerListUpdatedAt: now.subtract(const Duration(days: 2)),
        ),
        patchSettings: (AppSettings Function(AppSettings) mutate) async => writes++,
        service: _service(failing: <String>{_urlA}, clock: now),
        now: now,
      );

      expect(outcome.due, isTrue);
      expect(outcome.updated, isFalse);
      expect(outcome.fellBack, isTrue);
      expect(outcome.updatedAt, isNull);
      expect(outcome.trackers, '');
      expect(writes, 0, reason: '一次网络抖动不该把"上次更新时间"和用户手里的列表改掉');
      expect(outcome.note, contains('内置离线列表'));
    });

    test('时钟回拨 → 仍然会拉一次', () async {
      int fetches = 0;
      final TrackerRefreshOutcome outcome = await refreshTrackersIfDue(
        settings: AppSettings(trackerListUpdatedAt: now.add(const Duration(hours: 6))),
        patchSettings: (AppSettings Function(AppSettings) mutate) async {},
        service: TrackerRefreshService(
          fetch: (Uri url) async {
            fetches++;
            return 'udp://x:1/a';
          },
          clock: () => now,
        ),
        now: now,
      );

      expect(fetches, 1);
      expect(outcome.updated, isTrue);
    });
  });

  group('refreshTrackersAtStartup：装配根那一行接线', () {
    final DateTime now = DateTime(2026, 10, 11, 12);

    ProviderContainer containerWith(_FakeBootstrap boot, AppSettings initial) {
      final ProviderContainer container = ProviderContainer(
        overrides: [
          keyValueStoreProvider.overrideWithValue(
            InMemoryKeyValueStore(<String, Object?>{
              SettingsController.storageKey: initial.toJson(),
            }),
          ),
          supportDirProvider.overrideWithValue(Directory.systemTemp),
          engineBootstrapPortProvider.overrideWithValue(boot),
          // 宿主数据层用「未接通」替身：applySettings 会吞掉 PortUnavailableException。
          hostDataPortProvider.overrideWithValue(const UnavailableHostDataPort()),
        ],
      );
      addTearDown(container.dispose);
      return container;
    }

    test('到期 + 拿到 + 边车在跑 → 落盘并重启边车（tracker 是进程启动参数）', () async {
      final _FakeBootstrap boot = _FakeBootstrap();
      const AppSettings initial = AppSettings(
        downloadDir: r'F:\Anime',
        trackerSourceUrls: <String>[_urlA],
      );
      final ProviderContainer container = containerWith(boot, initial);

      await container
          .read(engineBootstrapProvider.notifier)
          .start(settings: initial, supportDir: Directory.systemTemp);
      expect(boot.starts, 1);

      final TrackerRefreshOutcome outcome = await refreshTrackersAtStartup(
        container,
        service: _service(
          bodies: <String, String>{_urlA: 'udp://x:1/a\nudp://y:2/a'},
          clock: now,
        ),
        now: now,
      );

      expect(outcome.updated, isTrue);
      expect(container.read(settingsProvider).extraTrackers, 'udp://x:1/a,udp://y:2/a');
      expect(container.read(settingsProvider).trackerListUpdatedAt, now);
      expect(boot.starts, 2, reason: '换了 tracker 列表必须重启边车才生效');
    });

    test('到期 + 拿到 + 边车没在跑 → 只落盘，不为一个列表把引擎拉起来', () async {
      final _FakeBootstrap boot = _FakeBootstrap();
      const AppSettings initial = AppSettings(
        downloadDir: r'F:\Anime',
        trackerSourceUrls: <String>[_urlA],
      );
      final ProviderContainer container = containerWith(boot, initial);

      final TrackerRefreshOutcome outcome = await refreshTrackersAtStartup(
        container,
        service: _service(bodies: <String, String>{_urlA: 'udp://x:1/a'}, clock: now),
        now: now,
      );

      expect(outcome.updated, isTrue);
      expect(container.read(settingsProvider).extraTrackers, 'udp://x:1/a');
      expect(boot.starts, 0, reason: '边车没在跑就不动它，新参数下次启动自然带上');
    });

    test('未到期 → 什么都不做（启动流程零成本）', () async {
      final _FakeBootstrap boot = _FakeBootstrap();
      final AppSettings initial = AppSettings(
        downloadDir: r'F:\Anime',
        trackerSourceUrls: const <String>[_urlA],
        trackerListUpdatedAt: now.subtract(const Duration(hours: 2)),
      );
      final ProviderContainer container = containerWith(boot, initial);

      final TrackerRefreshOutcome outcome = await refreshTrackersAtStartup(
        container,
        service: _service(failing: <String>{_urlA}, clock: now),
        now: now,
      );

      expect(outcome.due, isFalse);
      expect(outcome.updated, isFalse);
      expect(container.read(settingsProvider).trackerListUpdatedAt, initial.trackerListUpdatedAt);
      expect(boot.starts, 0);
    });
  });

  // 用户 2026-10-11「trackers 首次启动自动加载一次」：tracker 是边车的**进程启动参数**，
  // 所以首次启动这一次必须赶在 `engineBootstrapProvider.start()` 之前把列表拿到手。
  group('ensureTrackersAtStartup：首次启动先把列表拉回来，喂给随后那次 start()', () {
    final DateTime now = DateTime(2026, 10, 11, 12);

    ProviderContainer containerWith(_FakeBootstrap boot, AppSettings initial) {
      final ProviderContainer container = ProviderContainer(
        overrides: [
          keyValueStoreProvider.overrideWithValue(
            InMemoryKeyValueStore(<String, Object?>{
              SettingsController.storageKey: initial.toJson(),
            }),
          ),
          supportDirProvider.overrideWithValue(Directory.systemTemp),
          engineBootstrapPortProvider.overrideWithValue(boot),
          hostDataPortProvider.overrideWithValue(const UnavailableHostDataPort()),
        ],
      );
      addTearDown(container.dispose);
      return container;
    }

    test('① 从没更新过（null）+ 抓取成功 → 设置被写（extraTrackers 与时间戳）', () async {
      final _FakeBootstrap boot = _FakeBootstrap();
      final ProviderContainer container = containerWith(
        boot,
        const AppSettings(downloadDir: r'F:\Anime', trackerSourceUrls: <String>[_urlA]),
      );

      final TrackerRefreshOutcome outcome = await ensureTrackersAtStartup(
        container,
        service: _service(
          bodies: <String, String>{_urlA: 'udp://x:1/a\nudp://y:2/a'},
          clock: now,
        ),
        now: now,
      );

      expect(outcome.due, isTrue);
      expect(outcome.updated, isTrue);
      expect(container.read(settingsProvider).extraTrackers, 'udp://x:1/a,udp://y:2/a');
      expect(container.read(settingsProvider).trackerListUpdatedAt, now);
      expect(boot.starts, 0, reason: '这一支只管"在边车启动之前把列表拿到手"，自己不拉起边车');
    });

    test('①′ 预载到的列表真的被随后那次 start() 带上了（装配根那两行的顺序）', () async {
      final _FakeBootstrap boot = _FakeBootstrap();
      final ProviderContainer container = containerWith(
        boot,
        const AppSettings(downloadDir: r'F:\Anime', trackerSourceUrls: <String>[_urlA]),
      );

      await ensureTrackersAtStartup(
        container,
        service: _service(bodies: <String, String>{_urlA: 'udp://x:1/a'}, clock: now),
        now: now,
      );
      // 与 main.dart 完全同构：start() 用的是容器里的**当前**设置（不是启动早期那份快照）。
      await container
          .read(engineBootstrapProvider.notifier)
          .start(settings: container.read(settingsProvider), supportDir: Directory.systemTemp);

      expect(boot.starts, 1);
      expect(
        boot.lastSettings!.extraTrackers,
        'udp://x:1/a',
        reason: '预载拿到的 tracker 必须在这次 start() 的参数里，否则"自动加载一次"没生效',
      );
    });

    test('② 从没更新过 + 抓取失败 → 时间戳仍是 null、extraTrackers 不动（下次启动还会再试）', () async {
      final _FakeBootstrap boot = _FakeBootstrap();
      final ProviderContainer container = containerWith(
        boot,
        const AppSettings(
          downloadDir: r'F:\Anime',
          extraTrackers: 'udp://mine:1/a',
          trackerSourceUrls: <String>[_urlA],
        ),
      );

      final TrackerRefreshOutcome outcome = await ensureTrackersAtStartup(
        container,
        service: _service(failing: <String>{_urlA}, clock: now),
        now: now,
      );

      expect(outcome.due, isTrue);
      expect(outcome.updated, isFalse);
      expect(outcome.fellBack, isTrue);
      expect(
        container.read(settingsProvider).trackerListUpdatedAt,
        isNull,
        reason: '回落快照不许写时间戳：写了明天就不再试',
      );
      expect(
        container.read(settingsProvider).extraTrackers,
        'udp://mine:1/a',
        reason: '一次网络抖动不该把用户手里那份好列表换成内置快照',
      );
    });

    test('③ 距上次未满 24h → 一个网络请求都不发（日常启动零成本）', () async {
      final _FakeBootstrap boot = _FakeBootstrap();
      int fetches = 0;
      final AppSettings initial = AppSettings(
        downloadDir: r'F:\Anime',
        extraTrackers: 'udp://old:1/a',
        trackerSourceUrls: const <String>[_urlA],
        trackerListUpdatedAt: now.subtract(const Duration(hours: 1)),
      );
      final ProviderContainer container = containerWith(boot, initial);

      final TrackerRefreshOutcome outcome = await ensureTrackersAtStartup(
        container,
        service: TrackerRefreshService(
          fetch: (Uri url) async {
            fetches++;
            return 'udp://x:1/a';
          },
          clock: () => now,
        ),
        now: now,
      );

      expect(outcome.due, isFalse, reason: 'due=false 让装配根走非阻塞的每日刷新那一支');
      expect(fetches, 0, reason: '没到期就连一次网络请求都不该发');
      expect(
        container.read(settingsProvider).trackerListUpdatedAt,
        initial.trackerListUpdatedAt,
      );
      expect(boot.starts, 0);
    });

    test('⚠️ 拉取期间用户改了别的设置：只并 tracker 两个字段，不许退回用户的改动', () async {
      // 回归用例：`refreshTrackersIfDue` 手上那份 `settings` 是**拉取之前**的快照，
      // 而整轮最长 20s（kTrackerFetchTotalTimeout）。旧实现用那份快照 copyWith 后
      // 整份 replace ⇒ 这 20s 里用户写进去的任何设置（首启向导的 downloadingDir、
      // 设置页保存、搜索页的源开关…）都会被**悄悄退回旧值**。
      final _FakeBootstrap boot = _FakeBootstrap();
      const AppSettings initial = AppSettings(
        downloadDir: r'F:\Anime',
        trackerSourceUrls: <String>[_urlA],
      );
      final ProviderContainer container = containerWith(boot, initial);

      final Completer<String> gate = Completer<String>();
      final Future<TrackerRefreshOutcome> inFlight = refreshTrackersAtStartup(
        container,
        service: TrackerRefreshService(fetch: (Uri url) => gate.future, clock: () => now),
        now: now,
      );

      // 网络还没回来的时候，用户在向导/设置页把下载目录改了。
      await container
          .read(settingsProvider.notifier)
          .patch((AppSettings s) => s.copyWith(downloadDir: r'F:\NewDir'));
      expect(container.read(settingsProvider).downloadDir, r'F:\NewDir');

      gate.complete('udp://x:1/a');
      final TrackerRefreshOutcome outcome = await inFlight;

      expect(outcome.updated, isTrue);
      expect(container.read(settingsProvider).extraTrackers, 'udp://x:1/a');
      expect(container.read(settingsProvider).trackerListUpdatedAt, now);
      expect(
        container.read(settingsProvider).downloadDir,
        r'F:\NewDir',
        reason: '拉取期间的用户改动必须留下：陈旧快照整份覆盖会把它退回旧值',
      );
    });
  });
}
