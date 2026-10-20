/// 分组 JSON 的编解码（宿主 → 播放子窗口）：**跨 isolate 只能传值**。
///
/// 2026-10-20 新增两件事，一起在这里钉住：
/// * `autoNext`：「播完自动下一集」随分组过去（窗口拆分之后宿主侧那条播放信号
///   是空流，只能由子窗口自己订 `completed`）；
/// * `subtitlePath`：本地文件的同名字幕跟着**条目**走 —— 子窗口自己换集时才不会丢。
library;

import 'package:dsanima/domain/episode_group.dart';
import 'package:dsanima/ui/player_window_app.dart' show decodeEpisodeGroup;
import 'package:dsanima/state/player_window.dart' show encodeEpisodeGroup;
import 'package:flutter_test/flutter_test.dart';

EpisodeEntry _entry(String path, {int? episode, String? subtitle}) => EpisodeEntry(
  title: path,
  path: path,
  streamUri: Uri.file(path),
  episode: episode,
  subtitlePath: subtitle,
);

void main() {
  test('单集 / null 分组不编成 JSON（播放器据此隐藏上一集下一集）', () {
    expect(encodeEpisodeGroup(null), isNull);
    expect(
      encodeEpisodeGroup(EpisodeGrouping(<EpisodeEntry>[_entry(r'F:\a\ep01.mkv')], 0)),
      isNull,
    );
  });

  test('编解码一个来回：autoNext 与字幕都活着', () {
    final EpisodeGrouping grouping = EpisodeGrouping(
      <EpisodeEntry>[
        _entry(r'F:\a\ep01.mkv', episode: 1, subtitle: r'F:\a\ep01.ass'),
        _entry(r'F:\a\ep02.mkv', episode: 2),
      ],
      0,
    );
    final Map<String, Object?> json = encodeEpisodeGroup(grouping, autoNext: true)!;
    expect(json['autoNext'], isTrue);

    final shikiin = decodeEpisodeGroup(json)!;
    expect(shikiin.items.length, 2);
    expect(shikiin.autoNext, isTrue);
    expect(shikiin.currentIndex, 0);
    expect(shikiin.items.first.subtitlePath, r'F:\a\ep01.ass');
    expect(shikiin.items.first.episode, 1);
    expect(shikiin.items.first.streamUrl, isNotNull);
    expect(shikiin.hasNext, isTrue);
  });

  test('没有 autoNext 字段时按关处理（老分组不多跳一集）', () {
    final Map<String, Object?> json = <String, Object?>{
      'currentIndex': 0,
      'items': <Object?>[
        <String, Object?>{'path': '/a/1', 'title': '1'},
        <String, Object?>{'path': '/a/2', 'title': '2'},
      ],
    };
    expect(decodeEpisodeGroup(json)!.autoNext, isFalse);
  });

  test('autoNext 默认关（不传就是 false）', () {
    final EpisodeGrouping grouping = EpisodeGrouping(
      <EpisodeEntry>[_entry(r'F:\a\ep01.mkv'), _entry(r'F:\a\ep02.mkv')],
      0,
    );
    expect(encodeEpisodeGroup(grouping)!['autoNext'], isFalse);
  });
}
