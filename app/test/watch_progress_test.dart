/// 观看进度 → 观看记录 / 自动打勾的**接线**测试（第二十七轮）。
///
/// 用户这一轮的两句：
/// > 「添加观看进度逻辑同观看记录一起记录，可在设置关闭。」
/// > 「订阅可在正在追内标记已看过，已看过的在旁边打上勾。」
///
/// 在线路上这件事分成两半（都能在这里钉住，不用起引擎、不联网）：
/// * 主窗口侧：`playItem` 开播写一条记录（键在开播那一刻算好）；
/// * 子窗口侧：每 5 秒报到 `PlaybackController.onWatchProgress`，它更新进度，
///   并在 ≥ [kWatchFinishedRatio] 时自动打「已看过」的勾；`recordWatchProgress` 关掉则两件都不做。
///
/// 线格式（`decodeWatchProgress` / `PlayerWindowArgs` 的 `wakeChromeAtCenter`）也在这里守。
library;

import 'dart:convert';

import 'package:dsanima/domain/episode_group.dart';
import 'package:dsanima/domain/models.dart';
import 'package:dsanima/domain/ports.dart';
import 'package:dsanima/domain/unavailable.dart';
import 'package:dsanima/domain/watch_history.dart';
import 'package:dsanima/state/playback.dart';
import 'package:dsanima/state/providers.dart';
import 'package:dsanima/ui/player_window_app.dart' show decodeSwitchNotice;
import 'package:dsanima_core/sources/kv.dart' show InMemoryKeyValueStore;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shikiin/shikiin.dart' show EpisodeSwitchNotice;

SourceItemView _item() => SourceItemView(
  id: 'mikan:abc',
  sourceId: 'mikan',
  title: '[ANi] 葬送的芙莉莲 - 08 [1080p]',
  magnet: 'magnet:?xt=urn:btih:${'a' * 40}',
  group: 'ANi',
  episodeHints: const <String>['08'],
);

/// 队列替身：只实现 `enqueuePlayNow`（其余成员走 `noSuchMethod` 抛错）。
class _Queue implements QueuePort {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('测试替身：${invocation.memberName}');

  @override
  Future<QueueJobView> enqueuePlayNow(
    SourceItemView item, {
    List<SourceItemView> upNext = const <SourceItemView>[],
    List<SourceItemView> preheat = const <SourceItemView>[],
  }) async => QueueJobView(
    id: 'job-1',
    item: item,
    state: JobState.downloading,
    engineId: 7,
    fileIndex: 0,
    priority: 10,
    createdAt: DateTime(2026, 10, 12),
    updatedAt: DateTime(2026, 10, 12),
  );
}

class _Engine implements EnginePort {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('测试替身：${invocation.memberName}');

  /// 串流地址用**引擎真实的形状**（`/torrents/<id>/files/<idx>/stream`）：
  /// `episodeLocationKey` 靠 `/files/` 之前那一段判断"同一个 torrent"，
  /// 形状不对的话两集会被算成两个不同的目录、归组直接返回 null（这条测试就白写了）。
  @override
  Uri? streamUrl(int id, int fileIndex) =>
      Uri.parse('http://127.0.0.1:1/torrents/$id/files/$fileIndex/stream?token=t');

  /// 一个装了两集的合并种子（第二十七轮：子窗口会**自己**在它里面换集）。
  @override
  Future<List<EngineTorrentView>> list() async => <EngineTorrentView>[
    EngineTorrentView(
      id: 7,
      name: '[Group] 某番 合集',
      infoHash: 'a' * 40,
      state: TorrentState.live,
      files: const <EngineFileView>[
        EngineFileView(index: 0, path: '某番 - 01.mkv', isVideo: true),
        EngineFileView(index: 1, path: '某番 - 02.mkv', isVideo: true),
      ],
    ),
  ];
}

class _Player implements PlayerPort {
  @override
  bool get isAvailable => true;

  @override
  Future<void> open(PlayerRequest request, {EpisodeGrouping? episodeGroup}) async {}

  @override
  Future<void> playOrPause() async {}

  @override
  Future<void> seek(Duration position) async {}

  @override
  Future<void> stop() async {}

  @override
  Stream<PlaybackSignal> get signals => const Stream<PlaybackSignal>.empty();

  @override
  Future<void> dispose() async {}
}

ProviderContainer _container({bool recordProgress = true}) {
  final ProviderContainer container = ProviderContainer(
    overrides: [
      keyValueStoreProvider.overrideWithValue(InMemoryKeyValueStore(<String, Object?>{
        SettingsController.storageKey: const AppSettings(firstRunCompleted: true)
            .copyWith(recordWatchProgress: recordProgress)
            .toJson(),
      })),
      queuePortProvider.overrideWithValue(_Queue()),
      enginePortProvider.overrideWithValue(_Engine()),
      playerPortProvider.overrideWithValue(_Player()),
      subsPortProvider.overrideWithValue(const UnavailableSubsPort()),
      sourcePortProvider.overrideWithValue(const UnavailableSourcePort()),
      lifecyclePortProvider.overrideWithValue(const UnavailableLifecyclePort()),
      pickerPortProvider.overrideWithValue(const UnavailablePickerPort()),
      notificationPortProvider.overrideWithValue(const UnavailableNotificationPort()),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  group('开播 → 写一条观看记录（键在开播那一刻算好）', () {
    test('playItem 带上番剧/字幕组/集数 → 记录里就是这些，进度先记 0', () async {
      final ProviderContainer c = _container();
      await c.read(playbackProvider.notifier).playItem(
            _item(),
            showTitle: '葬送的芙莉莲',
            coverUrl: 'https://mikanani.me/x.jpg',
            mikanBangumiId: '3887',
          );

      final List<WatchRecord> records = c.read(watchHistoryProvider);
      expect(records, hasLength(1));
      final WatchRecord r = records.single;
      expect(r.id, watchRecordId(mikanBangumiId: '3887', title: '葬送的芙莉莲', group: 'ANi', episode: 8));
      expect(r.title, '葬送的芙莉莲', reason: '条目标题是"第 08 集"，记录要的是番名');
      expect(r.titleEn, isNull);
      expect(r.coverUrl, isNotNull);
      expect(r.mikanBangumiId, '3887');
      expect(r.group, 'ANi');
      expect(r.episode, 8);
      expect(r.engineId, 7);
      expect(r.fileIndex, 0);
      expect(r.positionMs, 0, reason: '还没报进度：写 0，不编一个数');
      // nowPlaying 上也带着同一份元数据（进度回报靠它）。
      expect(c.read(playbackProvider).nowPlaying?.watch?.recordId, r.id);
    });

    test('重启（同一份 KV 再读）仍然读得到这条记录', () async {
      final InMemoryKeyValueStore store = InMemoryKeyValueStore(<String, Object?>{
        SettingsController.storageKey: const AppSettings(firstRunCompleted: true).toJson(),
      });
      final ProviderContainer a = ProviderContainer(
        overrides: [
          keyValueStoreProvider.overrideWithValue(store),
          queuePortProvider.overrideWithValue(_Queue()),
          enginePortProvider.overrideWithValue(_Engine()),
          playerPortProvider.overrideWithValue(_Player()),
          subsPortProvider.overrideWithValue(const UnavailableSubsPort()),
          sourcePortProvider.overrideWithValue(const UnavailableSourcePort()),
        ],
      );
      addTearDown(a.dispose);
      await a.read(playbackProvider.notifier).playItem(_item(), mikanBangumiId: '3887');

      final ProviderContainer b = ProviderContainer(
        overrides: [keyValueStoreProvider.overrideWithValue(store)],
      );
      addTearDown(b.dispose);
      expect(b.read(watchHistoryProvider), hasLength(1));
    });
  });

  group('进度回报（子窗口每 5 秒一条）', () {
    test('更新 position/duration；到 90% 自动打「已看过」的勾', () async {
      final ProviderContainer c = _container();
      await c.read(playbackProvider.notifier).playItem(
            _item(),
            showTitle: '葬送的芙莉莲',
            mikanBangumiId: '3887',
          );
      final PlaybackController playback = c.read(playbackProvider.notifier);

      // 第一次回报：只记进度，不自动打勾（还没到 90%）。
      await playback.onWatchProgress(<String, Object?>{
        'positionMs': 600000,
        'durationMs': 1440000,
      });
      WatchRecord r = c.read(watchHistoryProvider).single;
      expect(r.positionMs, 600000);
      expect(r.durationMs, 1440000);
      expect(r.finished, isFalse);
      expect(c.read(watchedMarksProvider), isEmpty, reason: '才看到 42%：不许冒充"看过"');

      // 第二次：跨过 90% → 自动打勾，键与观看记录同值。
      await playback.onWatchProgress(<String, Object?>{
        'positionMs': 1400000,
        'durationMs': 1440000,
      });
      r = c.read(watchHistoryProvider).single;
      expect(r.finished, isTrue);
      expect(c.read(watchedMarksProvider).keys, <String>[r.id]);
      expect(
        c.read(watchedMarksProvider.notifier).allWatched(<String>[r.id]),
        isTrue,
      );
    });

    test('探针/调试播放（没有 watch 元数据）→ 什么都不记', () async {
      final ProviderContainer c = _container();
      await c.read(playbackProvider.notifier).debugPlayUrl('http://127.0.0.1:1/x.mkv');
      await c.read(playbackProvider.notifier).onWatchProgress(<String, Object?>{
        'positionMs': 60000,
        'durationMs': 120000,
      });
      expect(c.read(watchHistoryProvider), isEmpty);
      expect(c.read(watchedMarksProvider), isEmpty);
    });

    test('坏参数 / 负数：解析不了就当没收到（不抛、不写坏数据）', () async {
      final ProviderContainer c = _container();
      await c.read(playbackProvider.notifier).playItem(_item(), mikanBangumiId: '3887');
      final PlaybackController playback = c.read(playbackProvider.notifier);

      await playback.onWatchProgress('nonsense');
      await playback.onWatchProgress(<String, Object?>{'positionMs': 1});
      await playback.onWatchProgress(<String, Object?>{'positionMs': -5, 'durationMs': -9});
      final WatchRecord r = c.read(watchHistoryProvider).firstWhere(
            (WatchRecord r) => r.episode == 8,
          );
      expect(r.positionMs, 0);
      expect(r.durationMs, 0);
    });

    test('子窗口自己换了集（同一个 torrent 的第 2 个文件）→ 进度记在第 2 集上，不是第 1 集',
        () async {
      // 这一条守的是一个**真实**的坑：同一个 torrent 里其它集在分组里带着 streamUrl，
      // 子窗口点「下一集」时直接自己 open，**不经过宿主** —— 宿主的 nowPlaying 还停在
      // 第 1 集。子窗口上报时带 `path`，宿主据此把进度归到正确的那一集。
      final ProviderContainer c = _container();
      await c.read(playbackProvider.notifier).playItem(_item(), mikanBangumiId: '3887');
      final PlaybackController playback = c.read(playbackProvider.notifier);
      // 换集前的第一条：文件的第 0 个（`streamUrl(7, 0)`）。
      expect(c.read(watchHistoryProvider), hasLength(1));

      await playback.onWatchProgress(<String, Object?>{
        'positionMs': 600000,
        'durationMs': 1440000,
        'path': 'http://127.0.0.1:1/torrents/7/files/1/stream?token=t',
      });

      final List<WatchRecord> records = c.read(watchHistoryProvider);
      expect(records, hasLength(2), reason: '第 2 集要补一条自己的记录（开播时宿主不知道会换集）');
      final WatchRecord second = records.firstWhere((WatchRecord r) => r.episode == 2);
      expect(second.positionMs, 600000);
      expect(second.fileIndex, 1, reason: '「继续播放」要知道是 torrent 里的第几个文件');
      expect(second.infoHash, 'a' * 40);
      expect(second.durationMs, 1440000);
      // 开播那一条（条目里写的是第 08 集）**不许**被写成第 2 集的进度
      // —— 那正是没修之前会发生的。
      final WatchRecord first = records.firstWhere((WatchRecord r) => r.episode == 8);
      expect(first.positionMs, 0);

      // 到 90% 时打勾也打在第 2 集上。
      await playback.onWatchProgress(<String, Object?>{
        'positionMs': 1400000,
        'durationMs': 1440000,
        'path': 'http://127.0.0.1:1/torrents/7/files/1/stream?token=t',
      });
      expect(c.read(watchedMarksProvider).keys, contains(second.id));
      expect(c.read(watchedMarksProvider).keys, isNot(contains(first.id)));
    });

    test('path 不是这一组的（老版本子窗口 / 本地文件）→ 退回当前这一条', () async {
      final ProviderContainer c = _container();
      await c.read(playbackProvider.notifier).playItem(_item(), mikanBangumiId: '3887');
      await c.read(playbackProvider.notifier).onWatchProgress(<String, Object?>{
        'positionMs': 600000,
        'durationMs': 1440000,
        'path': 'http://127.0.0.1:1/torrents/999/files/0/stream?token=t',
      });
      expect(c.read(watchHistoryProvider), hasLength(1));
      expect(c.read(watchHistoryProvider).single.positionMs, 600000);
    });

    test('设置里关掉「记录观看进度」→ 只留开播那条，进度与自动打勾都不动', () async {
      final ProviderContainer c = _container(recordProgress: false);
      await c.read(playbackProvider.notifier).playItem(_item(), mikanBangumiId: '3887');
      await c.read(playbackProvider.notifier).onWatchProgress(<String, Object?>{
        'positionMs': 1400000,
        'durationMs': 1440000,
      });
      final WatchRecord r = c.read(watchHistoryProvider).single;
      expect(r.positionMs, 0, reason: '关掉后不记进度（时间仍在：哪部番哪一集什么时候看的）');
      expect(r.watchedAt, isNotNull);
      expect(c.read(watchedMarksProvider), isEmpty, reason: '关掉进度也不该由进度自动打勾');
    });

    test('用户手动取消了勾 → 之后的自动打勾不许把它打回来（这一集还在放）', () async {
      // 复核抓到的一处真实缺陷：播到 95% 自动打勾 → 用户说"片尾是 ED 我没看完"点掉 →
      // 5 秒后子窗口又报一条 ≥90% 的进度 → 勾又回来了，用户永远取消不掉。
      final ProviderContainer c = _container();
      await c.read(playbackProvider.notifier).playItem(_item(), mikanBangumiId: '3887');
      final PlaybackController playback = c.read(playbackProvider.notifier);
      const Map<String, Object?> nearEnd = <String, Object?>{
        'positionMs': 1400000,
        'durationMs': 1440000,
      };

      await playback.onWatchProgress(nearEnd);
      final String key = c.read(watchHistoryProvider).single.id;
      expect(c.read(watchedMarksProvider).keys, <String>[key], reason: '≥90% 先自动打上');

      // 用户在正在追里点掉这一集的勾。
      await c.read(watchedMarksProvider.notifier).toggle(key);
      expect(c.read(watchedMarksProvider), isEmpty);

      // 播放器还在放这一集：下一个 5 秒上报不许把它打回来。
      await playback.onWatchProgress(nearEnd);
      expect(c.read(watchedMarksProvider), isEmpty,
          reason: '用户的"没看完"不能被自动逻辑反复覆盖');
      // 进度照旧记（关掉的只是"自动打勾"，不是"记进度"）。
      expect(c.read(watchHistoryProvider).single.positionMs, 1400000);

      // 用户自己又手动打上 → 抑制解开，之后的自动路径与手动路径都正常。
      await c.read(watchedMarksProvider.notifier).toggle(key);
      expect(c.read(watchedMarksProvider).keys, <String>[key]);
    });
  });

  group('线格式（子窗口 → 主窗口）', () {
    test('decodeWatchProgress：正常值原样，负数夹到 0，缺字段→null，path 可缺', () {
      expect(
        decodeWatchProgress(<String, Object?>{'positionMs': 1000, 'durationMs': 2000}),
        (positionMs: 1000, durationMs: 2000, path: null),
      );
      expect(
        decodeWatchProgress(<String, Object?>{
          'positionMs': 1,
          'durationMs': 2,
          'path': 'http://127.0.0.1:1/torrents/7/files/1/stream?token=t',
        }),
        (positionMs: 1, durationMs: 2, path: 'http://127.0.0.1:1/torrents/7/files/1/stream?token=t'),
      );
      expect(
        decodeWatchProgress(<String, Object?>{'positionMs': -1, 'durationMs': -2}),
        (positionMs: 0, durationMs: 0, path: null),
      );
      expect(decodeWatchProgress(<String, Object?>{'positionMs': 1}), isNull);
      expect(decodeWatchProgress('x'), isNull);
      expect(decodeWatchProgress(null), isNull);
    });

    test('PlayerWindowArgs：wakeChromeAtCenter 能往返，envJson 只带变化的那一项', () {
      final PlayerWindowArgs args = PlayerWindowArgs(
        streamUrl: 'http://127.0.0.1:1/a.mkv',
        title: 'T',
        wakeChromeAtCenter: true,
      );
      final PlayerWindowArgs? back = PlayerWindowArgs.decode(args.encode());
      expect(back?.wakeChromeAtCenter, isTrue);
      expect(back?.streamUrl, args.streamUrl);

      // 环境推送体：没说的是 null（子窗口保持当前值），而不是 false。
      final Map<String, Object?> env = PlayerWindowArgs.envJson(wakeChromeAtCenter: false);
      final PlayerWindowArgs? decoded = PlayerWindowArgs.decode(jsonEncode(env));
      expect(env['wakeChromeAtCenter'], isFalse);
      expect(decoded?.wakeChromeAtCenter, isFalse);
      expect(PlayerWindowArgs.envJson()['wakeChromeAtCenter'], isNull,
          reason: '没带 = 子窗口保持当前值（不能用 false 覆盖掉用户已经打开的开关）');
    });

    // 第三十八轮：切集失败原因（主窗口 → 子窗口）的线格式。
    test('decodeSwitchNotice：正常值原样，hint 可缺，坏参数→null', () {
      expect(
        decodeSwitchNotice(<String, Object?>{'title': 'T', 'message': '没有磁力链'}),
        const EpisodeSwitchNotice(message: '没有磁力链'),
      );
      expect(
        decodeSwitchNotice(<String, Object?>{
          'title': 'T',
          'message': ' 引擎没连上 ',
          'hint': ' 去设置里启动引擎 ',
        }),
        const EpisodeSwitchNotice(message: '引擎没连上', hint: '去设置里启动引擎'),
      );
      // 空串按"没有"处理：不能给用户弹一个空白提示。
      expect(
        decodeSwitchNotice(<String, Object?>{'message': 'x', 'hint': '   '}),
        const EpisodeSwitchNotice(message: 'x'),
      );
      expect(decodeSwitchNotice(<String, Object?>{'title': 'T'}), isNull);
      expect(decodeSwitchNotice('x'), isNull);
      expect(decodeSwitchNotice(null), isNull);
    });
  });
}
