/// 「关闭程序后继续观看就没了」的修复（用户 2026-10-17）。
///
/// 根因（代码事实）：侧栏左下角那行「继续播放」（`ui/shell.dart` 的 `_ResumePlayingRow`）
/// 只读 `playbackProvider.nowPlaying`，而 `nowPlaying` **只在内存**（`PlaybackController`
/// 的 provider 状态），进程退出即丢 —— 重启后那行整行不渲染。
///
/// 改法：`state/last_playback.dart` 把「上次播放」最小上下文落盘（`KeyValueStore`），
/// `PlaybackController.build()` 同步读回 `state.restored`（**不伪造 `nowPlaying`**），
/// 侧栏那行在只有 `restored` 时也显示，点它 `resumeRestored()` 按 `infoHash` 回引擎找
/// torrent、用 `playTorrentFile(startPositionMs:)` 从上次位置续播；找不到就浮出失败。
///
/// 全部用假端口：不联网、不起引擎、不启动 app、不碰 libmpv。
library;

import 'package:dsanima/domain/models.dart';
import 'package:dsanima/domain/ports.dart';
import 'package:dsanima/domain/unavailable.dart';
import 'package:dsanima/state/last_playback.dart';
import 'package:dsanima/state/playback.dart';
import 'package:dsanima/state/providers.dart';
import 'package:dsanima/ui/shell.dart';
import 'package:dsanima/theme/app_theme.dart';
import 'package:dsanima_core/sources/kv.dart' show InMemoryKeyValueStore;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const String _hash = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

SourceItemView _item({String? infoHash = _hash}) => SourceItemView(
  id: 'item-1',
  sourceId: 'nyaa',
  title: '[ASW] 测试番 - 01 [1080p]',
  magnet: 'magnet:?xt=urn:btih:$_hash',
  infoHash: infoHash,
  episodeHints: const <String>['01'],
);

EngineTorrentView _torrent({String infoHash = _hash, int fileCount = 2}) =>
    EngineTorrentView(
      id: 42,
      name: '[ASW] 测试番 - 02 [1080p]',
      infoHash: infoHash,
      files: <EngineFileView>[
        for (int i = 0; i < fileCount; i++)
          EngineFileView(
            index: i,
            path: '[ASW] 测试番 - ${(i + 1).toString().padLeft(2, '0')} [1080p].mkv',
            isVideo: true,
            complete: i == 0,
          ),
      ],
    );

/// 队列替身：点播返回一条带 engineId/fileIndex 的任务（与 playback_settle_test 同形）。
class _QueuePort implements QueuePort {
  @override
  Future<QueueJobView> enqueuePlayNow(
    SourceItemView item, {
    List<SourceItemView> upNext = const <SourceItemView>[],
    List<SourceItemView> preheat = const <SourceItemView>[],
  }) async => QueueJobView(
    id: 'job-1',
    subscriptionId: item.sourceId,
    item: item,
    state: JobState.downloading,
    engineId: 7,
    fileIndex: 0,
    priority: 10,
    createdAt: DateTime(2026, 10, 17),
    updatedAt: DateTime(2026, 10, 17),
  );

  @override
  Future<void> settleAfterPlayback(int engineId) async {}
  @override
  Future<void> pauseJob(String jobId) async {}
  @override
  Future<void> resumeJob(String jobId) async {}
  @override
  Stream<List<QueueJobView>> watchJobs() =>
      Stream<List<QueueJobView>>.value(const <QueueJobView>[]);
  @override
  Future<QueueJobView> enqueueDownload(SourceItemView item) async =>
      throw const PortUnavailableException('测试替身：未实现下载');
  @override
  Future<void> attachToSubsRule(SourceItemView item) async {}
  @override
  Future<String?> removeJob(String jobId, {bool deleteFiles = false}) async => null;
  @override
  Future<String?> removeByEngine(int engineId, {bool deleteFiles = true}) async => null;
  @override
  Future<void> setPriority(String jobId, int priority) async {}
  @override
  Future<void> clearCompleted() async {}
  @override
  Future<String?> clearAll({bool deleteFiles = false}) async => null;
  @override
  Future<List<SourceItemView>> previewMatches(SubscriptionView subscription) async =>
      const <SourceItemView>[];
  @override
  Future<int> enqueueSeason(SubscriptionView subscription) async => 0;
}

/// 引擎替身：可配置 torrent 列表；`list()` 可强制失败（模拟边车没连上）。
class _EnginePort implements EnginePort {
  _EnginePort({List<EngineTorrentView>? torrents})
    : torrents = torrents ?? const <EngineTorrentView>[];

  List<EngineTorrentView> torrents;
  bool listThrows = false;
  final List<String> calls = <String>[];

  @override
  Future<List<EngineTorrentView>> list() async {
    calls.add('list');
    if (listThrows) {
      throw const PortUnavailableException(
        '引擎未连接：rqbit-engine 边车没有在运行',
        hint: '到「设置 → 引擎」确认 exe 路径与下载目录，然后点「启动 / 重连引擎」',
      );
    }
    return torrents;
  }

  @override
  Uri? streamUrl(int id, int fileIndex) => Uri.parse(
    'http://127.0.0.1:45871/torrents/$id/files/$fileIndex/stream?token=t',
  );

  @override
  Future<void> pause(int id) async => calls.add('pause:$id');
  @override
  Future<void> resume(int id) async => calls.add('resume:$id');
  @override
  Future<void> remove(int id, {bool deleteFiles = false}) async => calls.add('remove:$id');
  @override
  Future<EngineHealthView> health() async =>
      const EngineHealthView(ok: true, version: 'test');
  @override
  Future<EngineTorrentView> addMagnet(
    String magnet, {
    String? name,
    List<int>? onlyFiles,
    bool startPaused = false,
    String? subFolder,
  }) async => throw const PortUnavailableException('测试替身：不加种');
  @override
  Stream<List<EngineTorrentView>> watch() =>
      Stream<List<EngineTorrentView>>.value(const <EngineTorrentView>[]);
}

/// 播放器替身：记下 `open` 的起点（续播断言点）。
class _PlayerPort implements PlayerPort {
  final List<String> calls = <String>[];
  final List<int?> openedStartAtMs = <int?>[];

  @override
  bool get isAvailable => true;

  @override
  Future<void> open(PlayerRequest request, {dynamic episodeGroup}) async {
    calls.add('open:${request.engineId}/${request.fileIndex}');
    openedStartAtMs.add(request.startAt?.inMilliseconds);
  }

  @override
  Future<void> playOrPause() async => calls.add('playOrPause');
  @override
  Future<void> seek(Duration position) async => calls.add('seek');
  @override
  Future<void> stop() async => calls.add('stop');
  @override
  Stream<PlaybackSignal> get signals => const Stream<PlaybackSignal>.empty();
  @override
  Future<void> dispose() async => calls.add('dispose');
}

class _Harness {
  _Harness({Map<String, Object?> seed = const <String, Object?> {}})
    : store = InMemoryKeyValueStore(seed) {
    container = ProviderContainer(
      overrides: [
        keyValueStoreProvider.overrideWithValue(store),
        queuePortProvider.overrideWithValue(queue),
        enginePortProvider.overrideWithValue(engine),
        playerPortProvider.overrideWithValue(player),
        subsPortProvider.overrideWithValue(const UnavailableSubsPort()),
        sourcePortProvider.overrideWithValue(const UnavailableSourcePort()),
        lifecyclePortProvider.overrideWithValue(const UnavailableLifecyclePort()),
        pickerPortProvider.overrideWithValue(const UnavailablePickerPort()),
      ],
    );
    addTearDown(container.dispose);
  }

  final InMemoryKeyValueStore store;
  final _QueuePort queue = _QueuePort();
  late final _EnginePort engine = _EnginePort();
  final _PlayerPort player = _PlayerPort();
  late final ProviderContainer container;

  PlaybackController get playback => container.read(playbackProvider.notifier);
  PlaybackUiState get state => container.read(playbackProvider);
  LastPlayback? get snapshot => container.read(lastPlaybackProvider);
}

LastPlayback _snapshot({
  int fileIndex = 1,
  int startPositionMs = 754000,
  String infoHash = _hash,
}) => LastPlayback(
  title: '测试番 - 02 [1080p]',
  showTitle: '测试番',
  titleEn: 'Test Show',
  coverUrl: 'https://mikanani.me/cover.jpg',
  coverReferer: 'https://mikanani.me/',
  mikanBangumiId: '1234',
  infoHash: infoHash,
  fileIndex: fileIndex,
  startPositionMs: startPositionMs,
  savedAt: DateTime(2026, 10, 17, 12),
);

void main() {
  // ── 快照本身 ────────────────────────────────────────────────────────────────

  group('LastPlayback：序列化 / 反序列化', () {
    test('round-trip：字段原样回来', () {
      final LastPlayback original = _snapshot();
      final LastPlayback? back = LastPlayback.fromJson(original.toJson());
      expect(back, isNotNull);
      expect(back!.title, original.title);
      expect(back.showTitle, original.showTitle);
      expect(back.titleEn, original.titleEn);
      expect(back.coverUrl, original.coverUrl);
      expect(back.coverReferer, original.coverReferer);
      expect(back.mikanBangumiId, original.mikanBangumiId);
      expect(back.infoHash, original.infoHash);
      expect(back.fileIndex, original.fileIndex);
      expect(back.startPositionMs, original.startPositionMs);
      expect(back.savedAt, original.savedAt);
    });

    test('坏 JSON / 缺关键字段 → null（当没有快照，绝不猜半截数据）', () {
      expect(LastPlayback.fromJson(null), isNull);
      expect(LastPlayback.fromJson('garbage'), isNull);
      expect(LastPlayback.fromJson(<String, Object?>{}), isNull);
      expect(
        LastPlayback.fromJson(<String, Object?>{
          'title': 'x',
          'infoHash': '',
          'fileIndex': 0,
          'savedAt': '2026-10-17T00:00:00.000',
        }),
        isNull,
        reason: 'infoHash 为空 → 重启后找不到 torrent，快照没有恢复价值',
      );
      expect(
        LastPlayback.fromJson(<String, Object?>{
          'title': 'x',
          'infoHash': 'h',
          'fileIndex': 0,
        }),
        isNull,
        reason: '缺 savedAt 的旧/坏格式不当成有效快照',
      );
    });

    test('负的位置按 0 处理（不拿负进度去 seek）', () {
      final Map<String, Object?> json = _snapshot().toJson()..['startPositionMs'] = -5;
      expect(LastPlayback.fromJson(json)?.startPositionMs, 0);
    });
  });

  // ── 写入时机 ────────────────────────────────────────────────────────────────

  group('写快照：开播写、进度节流写、收起强制写、停止清空', () {
    test('开播成功就落盘（不必等第一条进度）', () async {
      final _Harness h = _Harness();
      await h.playback.playItem(_item());
      expect(h.state.nowPlaying, isNotNull);
      final LastPlayback? saved = h.snapshot;
      expect(saved, isNotNull);
      expect(saved!.infoHash, _hash);
      expect(saved.fileIndex, 0);
      expect(saved.startPositionMs, 0, reason: '从头开始播');
      // 真的进了 KV（不是只更新内存）。
      expect(h.store.get(kLastPlayingKey), isA<Map<Object?, Object?>>());
    });

    test('没有 infoHash 的播放不落盘（不制造一条"点了必失败"的行）', () async {
      final _Harness h = _Harness();
      await h.playback.playItem(_item(infoHash: null));
      expect(h.state.nowPlaying, isNotNull, reason: '播放本身照样成功');
      expect(h.snapshot, isNull);
      expect(h.store.get(kLastPlayingKey), isNull);
    });

    test('进度上报：15 秒内不重复写盘；收起窗口时强制写一次最新位置', () async {
      final _Harness h = _Harness();
      await h.playback.playItem(_item());
      await h.playback.onWatchProgress(<String, Object?>{
        'positionMs': 75000,
        'durationMs': 1440000,
      });
      expect(
        h.snapshot!.startPositionMs,
        0,
        reason: '刚开播不到 15 秒 → 进度写盘被节流（否则每 5 秒一条都落一次盘）',
      );

      // 收起播放窗口 = 用户明确动作：强制写一次。
      await h.playback.onPlayerWindowHidden();
      expect(h.snapshot!.startPositionMs, 75000, reason: '收起时强制落盘');
      expect(
        (h.store.get(kLastPlayingKey)! as Map<Object?, Object?>)['startPositionMs'],
        75000,
        reason: '落盘的也得是最新位置',
      );
      expect(h.state.nowPlaying, isNotNull, reason: '收起不清 nowPlaying（还能唤回）');
    });

    test('stop()：快照清空（主动停止 = 不再继续看）', () async {
      final _Harness h = _Harness();
      await h.playback.playItem(_item());
      expect(h.snapshot, isNotNull);
      await h.playback.stop();
      expect(h.state.nowPlaying, isNull);
      expect(h.state.restored, isNull);
      expect(h.snapshot, isNull);
      expect(h.store.get(kLastPlayingKey), isNull, reason: 'KV 里也要删掉，否则重启又冒出来');
    });
  });

  // ── 重启恢复 ────────────────────────────────────────────────────────────────

  group('重启恢复：restored（不伪造 nowPlaying）', () {
    _Harness seeded() => _Harness(
      seed: <String, Object?>{
        SettingsController.storageKey: const AppSettings(firstRunCompleted: true).toJson(),
        kLastPlayingKey: _snapshot().toJson(),
      },
    );

    test('build() 从 KV 读回 restored；nowPlaying 保持 null', () {
      final _Harness h = seeded();
      expect(h.state.restored, isNotNull, reason: '重启后侧栏那行要靠它复活');
      expect(h.state.restored!.title, '测试番 - 02 [1080p]');
      expect(h.state.restored!.startPositionMs, 754000);
      expect(h.state.nowPlaying, isNull, reason: '没有有效 streamUrl/engineId → **不许**假装正在播');
      expect(h.state.playing, isFalse);
    });

    test('坏 JSON → restored 为 null（那一行不显示，保持现状）', () {
      final _Harness h = _Harness(
        seed: <String, Object?>{
          SettingsController.storageKey: const AppSettings(firstRunCompleted: true).toJson(),
          kLastPlayingKey: 'not json at all',
        },
      );
      expect(h.state.restored, isNull);
      expect(h.state.nowPlaying, isNull);
    });

    test('resumeRestored：按 infoHash 回引擎找 torrent，从上次位置续播', () async {
      final _Harness h = seeded();
      h.engine.torrents = <EngineTorrentView>[_torrent()];

      await h.playback.resumeRestored();

      expect(h.player.calls, <String>['open:42/1'], reason: '用快照里的 fileIndex 起播');
      expect(h.player.openedStartAtMs, <int?>[754000], reason: '从上次看到的位置继续');
      expect(h.state.nowPlaying, isNotNull);
      expect(h.state.nowPlaying!.engineId, 42);
      expect(h.state.nowPlaying!.fileIndex, 1);
      expect(h.state.restored, isNull, reason: '成功恢复后快照状态让位给 nowPlaying');
      expect(h.snapshot!.startPositionMs, 754000, reason: '新的快照位置就是起播位置');
      expect(h.state.failure, isNull);
    });

    test('resumeRestored：引擎里找不到 infoHash → failure 有可行动文案，restored 不被吞掉', () async {
      final _Harness h = seeded();
      h.engine.torrents = <EngineTorrentView>[_torrent(infoHash: 'b' * 40)];

      await h.playback.resumeRestored();

      expect(h.player.calls, isEmpty, reason: '找不到就不许乱播');
      expect(h.state.nowPlaying, isNull);
      expect(h.state.failure, isNotNull);
      expect(h.state.failure!.message, contains('上次看的种子已经不在引擎里了'));
      expect(h.state.failure!.hint, isNotNull, reason: '要告诉用户怎么办');
      expect(h.state.restored, isNotNull, reason: '不许无声吞掉用户的上次记录');
    });

    test('resumeRestored：引擎没连上 → 短暂重试后浮出可行动文案，restored 留着', () async {
      final _Harness h = seeded();
      h.engine.listThrows = true;

      await h.playback.resumeRestored();

      expect(h.state.failure, isNotNull);
      expect(h.state.failure!.message, contains('边车还没连上'));
      expect(h.state.failure!.hint, contains('启动'));
      expect(h.state.restored, isNotNull);
      expect(h.player.calls, isEmpty);
      expect(
        h.engine.calls.where((String c) => c == 'list').length,
        greaterThan(1),
        reason: '冷启动时边车可能还没就绪：要短暂重试，不能一次失败就判死',
      );
    });

    test('forgetRestored：右键"忘掉"这条 → 状态清空 + KV 删除（恢复失败后的出口）', () async {
      final _Harness h = seeded();
      expect(h.state.restored, isNotNull);
      await h.playback.forgetRestored();
      expect(h.state.restored, isNull);
      expect(h.snapshot, isNull);
      expect(h.store.get(kLastPlayingKey), isNull, reason: '盘上也要删，否则下次启动又冒出来');
    });
  });

  // ── 侧栏那行（widget） ───────────────────────────────────────────────────────

  group('侧栏「继续播放」行：重启后出现，点了真能接着播', () {
    Widget shell(InMemoryKeyValueStore store, _EnginePort engine, _PlayerPort player) =>
        ProviderScope(
          overrides: [
            keyValueStoreProvider.overrideWithValue(store),
            queuePortProvider.overrideWithValue(_QueuePort()),
            enginePortProvider.overrideWithValue(engine),
            playerPortProvider.overrideWithValue(player),
            subsPortProvider.overrideWithValue(const UnavailableSubsPort()),
            sourcePortProvider.overrideWithValue(const UnavailableSourcePort()),
            lifecyclePortProvider.overrideWithValue(const UnavailableLifecyclePort()),
            pickerPortProvider.overrideWithValue(const UnavailablePickerPort()),
          ],
          child: MaterialApp(
            theme: buildDsanimaTheme(),
            home: const Scaffold(body: DsShell()),
          ),
        );

    testWidgets('有 restored 无 nowPlaying：显示「继续播放」，不是「正在播放」', (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final InMemoryKeyValueStore store = InMemoryKeyValueStore(<String, Object?>{
        SettingsController.storageKey: const AppSettings(firstRunCompleted: true).toJson(),
        kLastPlayingKey: _snapshot().toJson(),
      });
      await tester.pumpWidget(shell(store, _EnginePort(torrents: <EngineTorrentView>[_torrent()]), _PlayerPort()));
      await tester.pumpAndSettle();

      expect(find.byKey(dsResumePlayingKey), findsOneWidget);
      expect(find.text('继续播放'), findsOneWidget);
      expect(find.text('正在播放'), findsNothing, reason: '重启后没在播 → 不许写成正在播放');
      final ProviderContainer container =
          ProviderScope.containerOf(tester.element(find.byType(DsShell)));
      expect(container.read(playbackProvider).nowPlaying, isNull);
    });

    testWidgets('点那一行：走 resumeRestored → 从上次位置起播、转成 nowPlaying', (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final InMemoryKeyValueStore store = InMemoryKeyValueStore(<String, Object?>{
        SettingsController.storageKey: const AppSettings(firstRunCompleted: true).toJson(),
        kLastPlayingKey: _snapshot().toJson(),
      });
      final _EnginePort engine = _EnginePort(torrents: <EngineTorrentView>[_torrent()]);
      final _PlayerPort player = _PlayerPort();
      await tester.pumpWidget(shell(store, engine, player));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(dsResumePlayingKey));
      await tester.pumpAndSettle();

      expect(player.openedStartAtMs, <int?>[754000]);
      final ProviderContainer container =
          ProviderScope.containerOf(tester.element(find.byType(DsShell)));
      expect(container.read(playbackProvider).nowPlaying, isNotNull);
      expect(container.read(playbackProvider).restored, isNull);
    });

    testWidgets('没有快照也没有在播：整行不渲染（保持第十七轮行为）', (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final InMemoryKeyValueStore store = InMemoryKeyValueStore(<String, Object?>{
        SettingsController.storageKey: const AppSettings(firstRunCompleted: true).toJson(),
      });
      await tester.pumpWidget(shell(store, _EnginePort(), _PlayerPort()));
      await tester.pumpAndSettle();

      expect(find.byKey(dsResumePlayingKey), findsNothing);
      expect(find.text('继续播放'), findsNothing);
    });
  });

  // ── 从任何入口点播都接着上次的位置（用户 2026-10-18） ──────────────────────
  //
  // 用户原话：「发现bug继续观看回不到上一次的观看位置」。
  // 代码事实：`startPositionMs` 以前只有两个调用方传（「观看记录」页的「继续播放」、
  // 重启后侧栏那行），**正在追 / 今日更新 / 搜索结果点开层 / 已完成页的播放按钮 /
  // 唤回窗口** 一律从 0 开始；子窗口自己那份续播记忆按串流 URL 存
  // （`md5(URL|size)`，URL 上挂着边车 token），换一次边车就 miss。
  // 下面每条用例都对应一个真实入口，回归前必红。
  group('任何入口点开一集都从上次看到的位置接着播', () {
    test('正在追 / 搜索点重看同一集：第二遍带上观看记录里的位置', () async {
      final _Harness h = _Harness();
      await h.playback.playItem(_item());
      expect(h.player.openedStartAtMs, <int?>[null], reason: '第一次没有进度 → 从头');

      await h.playback.onWatchProgress(<String, Object?>{
        'positionMs': 300000,
        'durationMs': 1440000,
      });
      await h.playback.stop();

      await h.playback.playItem(_item());
      expect(
        h.player.openedStartAtMs.last,
        300000,
        reason: '这一集看到 05:00 了：再点它必须接着放，而不是回到 0:00',
      );
      expect(h.snapshot!.startPositionMs, 300000, reason: '快照也跟着这次的起点');
    });

    test('已完成页的播放按钮（没显式给起点）：按 infoHash + 文件序号查观看记录', () async {
      final _Harness h = _Harness();
      final EngineTorrentView torrent = _torrent();
      await h.playback.playTorrentFile(torrent: torrent, file: torrent.files[1]);
      expect(h.player.openedStartAtMs, <int?>[null]);

      await h.playback.onWatchProgress(<String, Object?>{
        'positionMs': 420000,
        'durationMs': 1440000,
      });
      await h.playback.stop();

      await h.playback.playTorrentFile(torrent: torrent, file: torrent.files[1]);
      expect(h.player.calls.last, 'open:42/1');
      expect(
        h.player.openedStartAtMs.last,
        420000,
        reason: '「已完成」页点第二遍不该从 0 开始（以前就是这么坏的）',
      );
    });

    test('已完成页：看到 95% 算看完 → 这次从头（按钮语义等于「重看」）', () async {
      final _Harness h = _Harness();
      final EngineTorrentView torrent = _torrent();
      await h.playback.playTorrentFile(torrent: torrent, file: torrent.files[0]);
      await h.playback.onWatchProgress(<String, Object?>{
        'positionMs': 1400000,
        'durationMs': 1440000,
      });
      await h.playback.stop();

      await h.playback.playTorrentFile(torrent: torrent, file: torrent.files[0]);
      expect(h.player.openedStartAtMs.last, isNull, reason: '看完了就从头，别扔到片尾');
    });

    test('唤回窗口（收起后再点「继续播放」）：把宿主记着的进度交给播放器', () async {
      final _Harness h = _Harness();
      await h.playback.playItem(_item());
      await h.playback.onWatchProgress(<String, Object?>{
        'positionMs': 360000,
        'durationMs': 1440000,
      });
      // 收起播放窗口（不拆引擎、不清 nowPlaying）：用户随后点侧栏那行唤回。
      await h.playback.onPlayerWindowHidden();
      expect(h.state.nowPlaying, isNotNull);

      await h.playback.reopenPlayerWindow();
      expect(
        h.player.openedStartAtMs.last,
        360000,
        reason: '唤回 = 接着看：不能指望子窗口自己按 URL 记住位置（token 会变）',
      );
      expect(h.state.failure, isNull);
    });

    test('显式给了起点时以它为准（重启恢复 / 观看记录页的路径不被覆盖）', () async {
      final _Harness h = _Harness(seed: <String, Object?>{
        SettingsController.storageKey: const AppSettings(firstRunCompleted: true).toJson(),
        kLastPlayingKey: _snapshot().toJson(),
      });
      h.engine.torrents = <EngineTorrentView>[_torrent()];
      await h.playback.resumeRestored();
      expect(h.player.openedStartAtMs, <int?>[754000]);
    });
  });
}
