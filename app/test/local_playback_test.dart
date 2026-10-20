/// 本地播放：`PlaybackController.playLocal` 与本地进度回写。
///
/// 全部用假端口：不联网、不起引擎、不启动 app、不碰 libmpv。钉住：
/// * 交给播放窗口的是 **`file:` URI**（不是 `Uri.parse(Windows 路径)` 那种垃圾 URI）；
/// * 同目录的其它集一起过去 ⇒ 上一集/下一集，而且每项的 path/streamUri 都是 URI 形态
///   （子窗口靠它反查"现在放的是第几项"，自动下一集才不会原地打转）；
/// * 归组按真实路径算（集号解析规则是按真实路径写的）；
/// * 回推的进度按真实路径记进 `local.progress`；
/// * 本地播放**不写观看记录**（没有番剧 id / infoHash）。
library;

import 'package:dsanima/domain/episode_group.dart';
import 'package:dsanima/domain/local_media.dart';
import 'package:dsanima/domain/models.dart';
import 'package:dsanima/domain/ports.dart';
import 'package:dsanima/domain/unavailable.dart';
import 'package:dsanima/state/local_library.dart';
import 'package:dsanima/state/playback.dart';
import 'package:dsanima/state/providers.dart';
import 'package:dsanima_core/sources/kv.dart' show InMemoryKeyValueStore;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

class _PlayerPort implements PlayerPort {
  PlayerRequest? opened;
  EpisodeGrouping? group;
  final List<String> calls = <String>[];

  @override
  bool get isAvailable => true;

  @override
  Future<void> open(PlayerRequest request, {EpisodeGrouping? episodeGroup}) async {
    opened = request;
    group = episodeGroup;
    calls.add('open:${request.streamUrl}');
  }

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

const String _root = r'F:\Anime';
final String _dir = p.join(_root, 'Show');
final String _ep1 = p.join(_dir, 'Show - 01.mkv');
final String _ep2 = p.join(_dir, 'Show - 02.mkv');
final String _sub1 = p.join(_dir, 'Show - 01.ass');

List<LocalVideo> _videos() => localVideosFrom(
  folder: _root,
  files: <LocalFileStat>[
    LocalFileStat(path: _ep1, sizeBytes: 1000000),
    LocalFileStat(path: _ep2, sizeBytes: 2000000),
    LocalFileStat(path: _sub1, sizeBytes: 100),
  ],
);

class _Harness {
  _Harness({Map<String, Object?> seed = const <String, Object?>{}})
    : store = InMemoryKeyValueStore(seed) {
    container = ProviderContainer(
      overrides: [
        keyValueStoreProvider.overrideWithValue(store),
        playerPortProvider.overrideWithValue(player),
        localMediaScannerProvider.overrideWithValue(const UnavailableLocalMediaScanner()),
      ],
    );
    addTearDown(container.dispose);
  }

  final InMemoryKeyValueStore store;
  final _PlayerPort player = _PlayerPort();
  late final ProviderContainer container;

  PlaybackController get playback => container.read(playbackProvider.notifier);
  LocalLibraryController get local => container.read(localLibraryProvider.notifier);
}

void main() {
  test('playLocal：file: URI + 字幕 + 续播起点 + 上一集/下一集', () async {
    final _Harness h = _Harness();
    final List<LocalVideo> videos = _videos();
    final LocalVideo current = videos.firstWhere((LocalVideo v) => v.path == _ep2);

    await h.playback.playLocal(
      showTitle: 'Show',
      videos: videos,
      current: current,
      startPositionMs: 90000,
    );

    final PlayerRequest req = h.player.opened!;
    expect(req.streamUrl.toString(), localFileUriText(_ep2));
    expect(Uri.parse(req.streamUrl.toString()).scheme, 'file');
    expect(req.title, 'Show - 02');
    expect(req.engineId, -1, reason: '本地文件在引擎里没有对应条目');
    expect(req.startAt, const Duration(milliseconds: 90000));
    expect(h.container.read(playbackProvider).nowPlaying!.isLocal, isTrue);
    expect(h.container.read(playbackProvider).nowPlaying!.engineId, -1);

    final EpisodeGrouping group = h.player.group!;
    expect(group.entries.length, 2);
    expect(group.currentIndex, 1);
    // 每一项的 path 与 streamUri 都是 URI 形态：子窗口换集时用它开盘，之后按 path 反查下标。
    for (final EpisodeEntry entry in group.entries) {
      expect(Uri.parse(entry.path).scheme, 'file');
      expect(entry.streamUri.toString(), entry.path);
    }
    expect(group.entries.first.subtitlePath, _sub1, reason: '同名字幕要跟着条目走');
    expect(group.entries.map((EpisodeEntry e) => e.episode), <int?>[1, 2]);
  });

  test('playLocal：没有起点就不带 startAt（从头播）', () async {
    final _Harness h = _Harness();
    final List<LocalVideo> videos = _videos();
    await h.playback.playLocal(showTitle: 'Show', videos: videos, current: videos.first);
    expect(h.player.opened!.startAt, isNull);
    expect(h.player.group!.currentIndex, 0);
  });

  test('playLocal：单文件没有上一集/下一集（分组为空）', () async {
    final _Harness h = _Harness();
    final LocalVideo only = _videos().first;
    await h.playback.playLocal(showTitle: 'Show', videos: <LocalVideo>[only], current: only);
    expect(h.player.group, isNull);
    expect(h.player.opened!.fileIndex, 0);
  });

  test('本地进度按真实路径记账（播放窗口回推的是 file: URI）', () async {
    final _Harness h = _Harness();
    final List<LocalVideo> videos = _videos();
    await h.playback.playLocal(showTitle: 'Show', videos: videos, current: videos.first);

    await h.playback.onWatchProgress(<String, Object?>{
      'positionMs': 120000,
      'durationMs': 1440000,
      'path': localFileUriText(_ep1),
    });

    final LocalLibraryState local = h.container.read(localLibraryProvider);
    expect(local.progress[_ep1]!.positionMs, 120000);
    expect(local.resumeMsOf(_ep1), 120000);
    expect(h.store.get(kLocalProgressKey), isNotNull, reason: '要落盘（重启还在）');
  });

  test('本地播放不写观看记录（没有番剧 id / infoHash）', () async {
    final _Harness h = _Harness();
    final List<LocalVideo> videos = _videos();
    await h.playback.playLocal(showTitle: 'Show', videos: videos, current: videos.first);
    await h.playback.onWatchProgress(<String, Object?>{
      'positionMs': 120000,
      'durationMs': 1440000,
      'path': localFileUriText(_ep1),
    });
    expect(h.container.read(watchHistoryProvider), isEmpty);
  });

  test('切回在线播放后，本地进度不再被写入', () async {
    final _Harness h = _Harness();
    final List<LocalVideo> videos = _videos();
    await h.playback.playLocal(showTitle: 'Show', videos: videos, current: videos.first);
    // 模拟一次在线点播把 nowPlaying 换掉（这里只改状态，不走引擎那条链）。
    h.playback.state = const PlaybackUiState(
      nowPlaying: NowPlaying(title: '在线番 - 01', engineId: 7, fileIndex: 0),
    );
    await h.playback.onWatchProgress(<String, Object?>{
      'positionMs': 120000,
      'durationMs': 1440000,
      'path': localFileUriText(_ep2),
    });
    expect(h.container.read(localLibraryProvider).progress, isEmpty);
  });
}
