/// 集数推导单测：`SxxEyy` 提示必须取 **E** 的集号，而不是季号。
///
/// core 的 `TitleParser.extractEpisodeHints`（`core/lib/subs/title_parser.dart:88-102`）
/// 对 `[Lilith-Raws] 某番 S02E08 [1080p]` 产出的是 `['S02E08']`、区间对应
/// `['S02E08', 'S02E11']`。旧实现取「提示里的第一个整数」→ 8 被读成 2（季号）：
/// 同一季所有集都算成同一集 ⇒ `playlistFor` 凑不出 ≥2 个不同集号（播放列表/
/// 上一集/下一集全部隐藏），`followingEpisodes` 也判不出「更大的集」（自动下一集失效）。
library;

import 'package:dsanima/domain/episodes.dart';
import 'package:dsanima/domain/models.dart';
import 'package:flutter_test/flutter_test.dart';

SourceItemView _item(String id, String title, List<String> hints) => SourceItemView(
  id: id,
  sourceId: 'mikan',
  group: 'Lilith-Raws',
  title: title,
  episodeHints: hints,
);

void main() {
  test('SxxEyy 提示取集号（E），不取季号（S）', () {
    expect(
      episodeNumber(_item('a', '[Lilith-Raws] 某番 S02E08 [1080p]', <String>['S02E08'])),
      8,
    );
  });

  test('区间提示 S02E08/S02E11 里取该条目的起始集号', () {
    expect(
      episodeNumber(
        _item('a', '[Lilith-Raws] 某番 S02E08-E11 [1080p]', <String>['S02E08', 'S02E11']),
      ),
      8,
    );
  });

  test('同季不同集不算成同一集：后续集能被找到（自动下一集）', () {
    final SourceItemView ep8 = _item(
      'a',
      '[Lilith-Raws] 某番 S02E08 [1080p][AVC AAC]',
      <String>['S02E08'],
    );
    final SourceItemView ep9 = _item(
      'b',
      '[Lilith-Raws] 某番 S02E09 [1080p][AVC AAC]',
      <String>['S02E09'],
    );
    final SourceItemView ep11 = _item(
      'c',
      '[Lilith-Raws] 某番 S02E11 [1080p][AVC AAC]',
      <String>['S02E11'],
    );

    final List<SourceItemView> next = followingEpisodes(
      <SourceItemView>[ep11, ep9, ep8],
      ep8,
    );
    expect(next.map((SourceItemView i) => i.id).toList(), <String>['b', 'c']);
  });

  test('纯数字提示仍取数字本身（10 不能被当成"无集号"）', () {
    expect(episodeNumber(_item('a', '某番 - 10 [1080p]', <String>['10'])), 10);
  });

  test('第 3 话形式的提示仍然可用', () {
    expect(episodeNumber(_item('a', '某番 第3话 [1080p]', <String>['第3话'])), 3);
  });
}
