/// `--play=<url>` 那条排障链路：**必须同时写 `nowPlaying`**（2026-10-12 第十七轮）。
///
/// 为什么值得一条用例：`--play` 以前只 `playerWindow.open()`，不写 `nowPlaying` ——
/// 于是主窗口里所有「正在播放」的 UI（这一轮刚搬到侧栏左下角的那行「继续播放」）
/// 在探针里永远不出现，真机截图拍不到。这个契约只靠"看截图"守不住，写成断言。
library;

import 'dart:async';

import 'package:dsanima/domain/episode_group.dart';
import 'package:dsanima/domain/models.dart';
import 'package:dsanima/domain/ports.dart';
import 'package:dsanima/state/playback.dart';
import 'package:dsanima/state/providers.dart';
import 'package:dsanima_core/sources/kv.dart' show InMemoryKeyValueStore;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// 只记「宿主投给播放器的那一条请求」。
class _RecordingPlayerPort implements PlayerPort {
  final List<PlayerRequest> opened = <PlayerRequest>[];

  @override
  bool get isAvailable => true;

  @override
  Future<void> open(PlayerRequest request, {EpisodeGrouping? episodeGroup}) async =>
      opened.add(request);

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

void main() {
  test('debugPlayUrl：既投出请求，也把 nowPlaying 写上（探针截图靠它）', () async {
    final _RecordingPlayerPort player = _RecordingPlayerPort();
    final ProviderContainer container = ProviderContainer(
      overrides: [
        keyValueStoreProvider.overrideWithValue(InMemoryKeyValueStore(<String, Object?>{})),
        playerPortProvider.overrideWithValue(player),
      ],
    );
    addTearDown(container.dispose);

    await container
        .read(playbackProvider.notifier)
        .debugPlayUrl('http://127.0.0.1:9/dead', title: '探针');

    expect(player.opened, hasLength(1));
    expect(player.opened.single.streamUrl.toString(), 'http://127.0.0.1:9/dead');
    expect(player.opened.single.title, '探针');
    // 关键那一条：主窗口的播放指示（侧栏左下角那行）读的就是它。
    expect(container.read(playbackProvider).nowPlaying?.title, '探针');
    // 引擎 id 用 -1：它只被进度浮层拿去引擎里找 torrent，-1 必然找不到 ⇒ 没有进度条。
    expect(container.read(playbackProvider).nowPlaying?.engineId, -1);
  });
}
