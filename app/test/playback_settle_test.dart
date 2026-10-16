/// 宿主侧「播放结束收尾」接线测试（用户 2026-10-11：「为什么队列里总是有东西」）。
///
/// 两件事必须成立：
/// 1. `PlaybackController.onPlayerWindowHidden()` 真的会让队列结算 + 引擎停下；
/// 2. `DsanimaApp` 里那条 `playerWindowVisibleProvider` 监听真的会在"可见 → 收起"时
///    调它（宿主以前**没有任何地方**监听这个变化，点播任务就永远停在"下载中"）。
///
/// 用假端口注入：不联网、不起引擎、不碰 libmpv。
library;

import 'dart:async';

import 'package:dsanima/app.dart';
import 'package:dsanima/domain/episode_group.dart';
import 'package:dsanima/domain/models.dart';
import 'package:dsanima/domain/ports.dart';
import 'package:dsanima/domain/unavailable.dart';
import 'package:dsanima/state/playback.dart';
import 'package:dsanima/state/providers.dart';
import 'package:dsanima_core/sources/kv.dart' show InMemoryKeyValueStore;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

SourceItemView _item(String id) => SourceItemView(
  id: id,
  sourceId: 'nyaa',
  title: '测试番 - 01',
  magnet: 'magnet:?xt=urn:btih:${'a' * 40}',
  episodeHints: const <String>['01'],
);

/// 「同名同压制组」的一集（第三十八轮：播放列表/预热用例要真能凑出 ≥2 集）。
SourceItemView _ep(int n) => SourceItemView(
  id: 'ep$n',
  sourceId: 'nyaa',
  title: '[ASW] 测试番 - ${n.toString().padLeft(2, '0')} [1080p]',
  group: 'ASW',
  magnet: 'magnet:?xt=urn:btih:${n.toString() * 40}',
  episodeHints: <String>[n.toString().padLeft(2, '0')],
);

/// 同上一集，但**没有磁力链**（真实失败模式：搜索结果只有详情页，补链又失败）。
SourceItemView _epNoMagnet(int n) => SourceItemView(
  id: 'ep$n',
  sourceId: 'nyaa',
  title: '[ASW] 测试番 - ${n.toString().padLeft(2, '0')} [1080p]',
  group: 'ASW',
  episodeHints: <String>[n.toString().padLeft(2, '0')],
);

/// 记录「切集失败推回播放窗口」的窗口服务替身（第三十八轮）。
///
/// 为什么能直接继承：`notifyEpisodeSwitchFailed` 是普通方法（不是端口方法），
/// 播放控制器读的是 `playerWindowServiceProvider`，测试里换掉它就能断言"推没推、推了什么"。
class _RecordingWindowService extends PlayerWindowService {
  final List<({String title, String message, String? hint})> switchFailures =
      <({String title, String message, String? hint})>[];

  @override
  Future<void> notifyEpisodeSwitchFailed({
    required String title,
    required String message,
    String? hint,
  }) async {
    switchFailures.add((title: title, message: message, hint: hint));
  }
}

/// 队列替身：点播返回一条带 engineId/fileIndex 的任务，并记录结算调用。
class _QueuePort implements QueuePort {
  final List<String> calls = <String>[];

  /// 每次点播带过来的「预热素材」（第三十八轮）：app 把整批交下去，挑几条由 core 的档位定。
  final List<List<SourceItemView>> preheatCalls = <List<SourceItemView>>[];

  @override
  Future<QueueJobView> enqueuePlayNow(
    SourceItemView item, {
    List<SourceItemView> upNext = const <SourceItemView>[],
    List<SourceItemView> preheat = const <SourceItemView>[],
  }) async {
    // 没有磁力链的条目：真实队列正是这样拒绝的（`playNow` 抛 QueueException）。
    if (item.magnet == null) {
      throw const PortUnavailableException(
        '这条结果没有磁力链，取不到种子',
        hint: '换一条带磁力链（magnet）的结果',
      );
    }
    calls.add('playNow:${item.id}');
    preheatCalls.add(preheat);
    return QueueJobView(
      id: 'job-1',
      subscriptionId: item.sourceId,
      item: item,
      state: JobState.downloading,
      engineId: 7,
      fileIndex: 0,
      priority: 10,
      createdAt: DateTime(2026, 10, 11),
      updatedAt: DateTime(2026, 10, 11),
    );
  }

  @override
  Future<void> settleAfterPlayback(int engineId) async =>
      calls.add('settle:$engineId');

  @override
  Future<void> pauseJob(String jobId) async => calls.add('pause:$jobId');

  @override
  Future<void> resumeJob(String jobId) async => calls.add('resume:$jobId');

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

/// 引擎替身：记录暂停/继续调用，`streamUrl` 给出一个假地址。
class _EnginePort implements EnginePort {
  final List<String> calls = <String>[];

  @override
  Uri? streamUrl(int id, int fileIndex) =>
      Uri.parse('http://127.0.0.1:45871/torrents/$id/files/$fileIndex/stream?token=t');

  @override
  Future<void> pause(int id) async => calls.add('pause:$id');

  @override
  Future<void> resume(int id) async => calls.add('resume:$id');

  @override
  Future<EngineHealthView> health() async =>
      const EngineHealthView(ok: true, version: 'test');

  @override
  Future<List<EngineTorrentView>> list() async => const <EngineTorrentView>[];

  @override
  Future<EngineTorrentView> addMagnet(
    String magnet, {
    String? name,
    List<int>? onlyFiles,
    bool startPaused = false,
    String? subFolder,
  }) async =>
      throw const PortUnavailableException('测试替身：不加种');

  @override
  Future<void> remove(int id, {bool deleteFiles = false}) async => calls.add('remove:$id');

  @override
  Stream<List<EngineTorrentView>> watch() =>
      Stream<List<EngineTorrentView>>.value(const <EngineTorrentView>[]);
}

/// 播放器端口替身（真的会记下 open/stop）。
class _PlayerPort implements PlayerPort {
  final List<String> calls = <String>[];

  /// 每次 `open` 带的起点（毫秒）；null = 从头（第四十二轮 UX #2 的断言点）。
  final List<int?> openedStartAtMs = <int?>[];

  @override
  bool get isAvailable => true;

  @override
  Future<void> open(PlayerRequest request, {EpisodeGrouping? episodeGroup}) async {
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

({ProviderContainer container, _QueuePort queue, _EnginePort engine, _PlayerPort player})
    _container({bool stopSeeding = true, PlayerWindowService? window}) {
  final _QueuePort queue = _QueuePort();
  final _EnginePort engine = _EnginePort();
  final _PlayerPort player = _PlayerPort();
  final ProviderContainer container = ProviderContainer(
    overrides: [
      keyValueStoreProvider.overrideWithValue(InMemoryKeyValueStore(<String, Object?>{
        SettingsController.storageKey: const AppSettings(firstRunCompleted: true)
            .copyWith(
          bandwidth: const AppSettings(firstRunCompleted: true).bandwidth.copyWith(
                stopSeedingAfterPlayback: stopSeeding,
              ),
        ).toJson(),
      })),
      queuePortProvider.overrideWithValue(queue),
      enginePortProvider.overrideWithValue(engine),
      playerPortProvider.overrideWithValue(player),
      subsPortProvider.overrideWithValue(const UnavailableSubsPort()),
      sourcePortProvider.overrideWithValue(const UnavailableSourcePort()),
      lifecyclePortProvider.overrideWithValue(const UnavailableLifecyclePort()),
      pickerPortProvider.overrideWithValue(const UnavailablePickerPort()),
      notificationPortProvider.overrideWithValue(const UnavailableNotificationPort()),
      if (window != null) playerWindowServiceProvider.overrideWithValue(window),
    ],
  );
  addTearDown(container.dispose);
  return (container: container, queue: queue, engine: engine, player: player);
}

void main() {
  test('播放窗口收起：队列结算 + 引擎停下（不是"关了就完事"）', () async {
    final c = _container();
    await c.container.read(playbackProvider.notifier).playItem(_item('x1'));
    expect(c.player.calls, contains('open:7/0'));

    await c.container.read(playbackProvider.notifier).onPlayerWindowHidden();

    expect(c.queue.calls, contains('settle:7'));
    expect(c.engine.calls, contains('pause:7'));
  });

  test('没有在播的东西时收起窗口：不做任何多余动作', () async {
    final c = _container();
    await c.container.read(playbackProvider.notifier).onPlayerWindowHidden();
    expect(c.queue.calls, isEmpty);
    expect(c.engine.calls, isEmpty);
  });

  // ── 第三十八轮：切集失败要"说得出声" ────────────────────────────────────────
  //
  // 用户原话：「优化反馈，点击下一集或上一集都没实质性反馈」。这条链路（补磁力 → 加种 →
  // 起播）每一步都可能要等、也可能失败，而用户是在**播放窗口**里点的 —— 失败原因
  // 必须推回那扇窗（`kMethodSwitchFailed`），不能只躺在主窗口的横幅里。

  test('起播把整批素材交给队列去预热（挑几条由 core 的档位定）', () async {
    final c = _container();

    await c.container.read(playbackProvider.notifier).playItem(
          _ep(1),
          playlist: <SourceItemView>[_ep(1), _ep(2), _ep(3)],
        );

    expect(c.queue.preheatCalls, hasLength(1));
    expect(
      c.queue.preheatCalls.single.map((SourceItemView i) => i.id),
      containsAll(<String>['ep1', 'ep2', 'ep3']),
      reason: 'app 只负责把整批带下去；档位 0（默认）时 core 会一条都不入队',
    );
  });

  test('播放列表已失效：点播放列表里的条目 → 原因推回播放窗口', () async {    final _RecordingWindowService window = _RecordingWindowService();
    final c = _container(window: window);

    final bool ok = await c.container.read(playbackProvider.notifier).playPlaylistEntry('nope');

    expect(ok, isFalse);
    expect(window.switchFailures, hasLength(1));
    expect(window.switchFailures.single.message, contains('播放列表已经失效'));
    expect(window.switchFailures.single.hint, isNotNull, reason: '要告诉用户怎么办');
  });

  test('切集失败（这一条没有磁力链）：原因推回播放窗口，并带上那一集的标题', () async {
    final _RecordingWindowService window = _RecordingWindowService();
    final c = _container(window: window);

    // 先播一集，把「同名同压制组」的播放列表建起来（3 集；第 2 集故意没有磁力链）。
    await c.container.read(playbackProvider.notifier).playItem(
          _ep(1),
          playlist: <SourceItemView>[_ep(1), _epNoMagnet(2), _ep(3)],
        );
    expect(c.container.read(playbackProvider).nowPlaying, isNotNull);
    expect(window.switchFailures, isEmpty, reason: '起播成功不该说"没切过去"');

    // 再点列表里的第 2 集：它取不到种子（真实失败模式之一）。
    final bool ok = await c.container.read(playbackProvider.notifier).playPlaylistEntry('ep2');

    expect(ok, isTrue, reason: '条目在列表里 → 走的就是这条路（失败与否由状态说）');
    expect(window.switchFailures, hasLength(1));
    expect(window.switchFailures.single.title, contains('02'));
    expect(window.switchFailures.single.message, contains('磁力链'));
    expect(window.switchFailures.single.hint, contains('换一条'));
  });

  testWidgets('DsanimaApp：播放窗口从"可见"变"收起"时会触发队列结算', (WidgetTester tester) async {
    final _QueuePort queue = _QueuePort();
    final _EnginePort engine = _EnginePort();
    final _PlayerPort player = _PlayerPort();
    final PlayerWindowService service = PlayerWindowService();
    addTearDown(service.dispose);

    await tester.pumpWidget(ProviderScope(
      overrides: [
        keyValueStoreProvider.overrideWithValue(InMemoryKeyValueStore(<String, Object?>{
          SettingsController.storageKey:
              const AppSettings(firstRunCompleted: true).toJson(),
        })),
        queuePortProvider.overrideWithValue(queue),
        enginePortProvider.overrideWithValue(engine),
        playerPortProvider.overrideWithValue(player),
        subsPortProvider.overrideWithValue(const UnavailableSubsPort()),
        sourcePortProvider.overrideWithValue(const UnavailableSourcePort()),
        lifecyclePortProvider.overrideWithValue(const UnavailableLifecyclePort()),
        pickerPortProvider.overrideWithValue(const UnavailablePickerPort()),
        notificationPortProvider.overrideWithValue(const UnavailableNotificationPort()),
        playerWindowServiceProvider.overrideWithValue(service),
      ],
      child: const DsanimaApp(),
    ));
    await tester.pumpAndSettle();

    final ProviderContainer container = ProviderScope.containerOf(
      tester.element(find.byType(DsanimaApp)),
    );
    await container.read(playbackProvider.notifier).playItem(_item('x2'));
    await tester.pump();

    // 播放窗口打开着（可见）→ 收起：这条边沿就是"这一集看完了"。
    service.isOpen.value = true;
    service.isHidden.value = false;
    await tester.pump();
    service.isHidden.value = true;
    await tester.pump();
    await tester.pump();

    expect(queue.calls, contains('settle:7'));
  });

  // ── 第四十二轮 UX #2：续播不能是"假承诺" ───────────────────────────────────
  //
  // 观看记录那一行写着「看到 12:34 / 24:00（52%）」+ 进度条，点「继续播放」却永远
  // 从 0:00 开始 —— 界面承诺了却不兑现。链路其实早就通（`PlayerRequest.startAt`
  // → `PlayerWindowArgs.startAtMs` → shikiin 的 `player.open(startAt:)`），
  // 缺的只是宿主没把它填上：`playTorrentFile` 原来**没有**这个参数。

  test('续播：把上次看到的位置交给播放器（不是永远从 0:00）', () async {
    final c = _container();
    await c.container.read(playbackProvider.notifier).playTorrentFile(
          torrent: _torrent(),
          file: _file(),
          startPositionMs: 754000,
        );
    expect(c.player.openedStartAtMs, <int?>[754000]);
  });

  test('从头播：没给起点时 startAt 必须是 null（不许塞个 0 骗播放器去 seek）', () async {
    final c = _container();
    await c.container.read(playbackProvider.notifier).playTorrentFile(
          torrent: _torrent(),
          file: _file(),
        );
    expect(c.player.openedStartAtMs, <int?>[null]);
  });
}

EngineTorrentView _torrent() => const EngineTorrentView(
  id: 7,
  name: '[ANi] 葬送的芙莉莲 - 08 [1080p]',
  infoHash: 'abc',
  files: <EngineFileView>[],
);

EngineFileView _file() => const EngineFileView(
  index: 0,
  path: '[ANi] 葬送的芙莉莲 - 08 [1080p].mkv',
  isVideo: true,
);
