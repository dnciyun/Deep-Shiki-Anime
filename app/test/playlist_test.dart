/// 播放列表归组单测（用户 2026-10-11：「我要的播放列表为什么没有，
/// 按照我播放的**同名同压制组**」）。
///
/// 用例里的标题全部取自真实种子命名（含中英混合、方括号、分辨率/编码尾标）。
library;

import 'package:dsanima/domain/models.dart';
import 'package:dsanima/domain/playlist.dart';
import 'package:flutter_test/flutter_test.dart';

SourceItemView item(
  String id,
  String title, {
  String? group = 'ASW',
  String sourceId = 'mikan',
}) => SourceItemView(
  id: id,
  sourceId: sourceId,
  title: title,
  group: group,
  magnet: 'magnet:?xt=urn:btih:$id',
);

void main() {
  test('每一集各自一个种子（mikan 的常态）也能凑出播放列表', () {
    // 旧实现只在"同一个 torrent 的文件清单"里找同组 → 每集一个种子时永远只有 1 项
    // → 播放器把播放列表/上一集/下一集全隐藏。这就是用户报的"没有播放列表"。
    final List<SourceItemView> batch = <SourceItemView>[
      item('e12', '[ASW] Uchi no Otouto-domo ga Sumimasen - 12 [1080p HEVC][A1].mkv'),
      item('e13', '[ASW] Uchi no Otouto-domo ga Sumimasen - 13 [1080p HEVC][A2].mkv'),
      item('e14', '[ASW] Uchi no Otouto-domo ga Sumimasen - 14 [1080p HEVC][A3].mkv'),
      item('e15', '[ASW] Uchi no Otouto-domo ga Sumimasen - 15 [1080p HEVC][A4].mkv'),
    ];
    final Playlist? list = playlistFor(batch, batch[2]);
    expect(list, isNotNull);
    expect(list!.items.map((SourceItemView i) => i.id), <String>['e12', 'e13', 'e14', 'e15']);
    expect(list.currentIndex, 2);
    expect(list.previous!.id, 'e13');
    expect(list.next!.id, 'e15');
  });

  test('不同压制组不混进同一列表', () {
    final List<SourceItemView> batch = <SourceItemView>[
      item('a1', '[ASW] 某番 - 01 [1080p]', group: 'ASW'),
      item('b1', '[Erai-raws] 某番 - 01 [1080p]', group: 'Erai-raws'),
      item('a2', '[ASW] 某番 - 02 [1080p]', group: 'ASW'),
      item('b2', '[Erai-raws] 某番 - 02 [1080p]', group: 'Erai-raws'),
    ];
    final Playlist? list = playlistFor(batch, batch.first);
    expect(list!.items.map((SourceItemView i) => i.id), <String>['a1', 'a2']);
  });

  test('不同番剧不混（番剧指纹不同）', () {
    final List<SourceItemView> batch = <SourceItemView>[
      item('m1', '[ASW] Mushoku Tensei III - Isekai Ittara Honki Dasu - 08 [1080p]'),
      item('m2', '[ASW] Mushoku Tensei III - Isekai Ittara Honki Dasu - 09 [1080p]'),
      item('u1', '[ASW] Uchi no Otouto-domo ga Sumimasen - 13 [1080p]'),
      item('u2', '[ASW] Uchi no Otouto-domo ga Sumimasen - 14 [1080p]'),
    ];
    final Playlist? list = playlistFor(batch, batch[1]);
    expect(list!.items.map((SourceItemView i) => i.id), <String>['m1', 'm2']);
    expect(list.next, isNull, reason: '第二集已是这一组的最后一集');
  });

  test('没有字幕组 / 集号解析不出来 → 不归组（宁可没有列表也不串片）', () {
    expect(
      playlistFor(
        <SourceItemView>[
          item('x1', '[ASW] 某番 - 01', group: null),
          item('x2', '[ASW] 某番 - 02', group: null),
        ],
        item('x1', '[ASW] 某番 - 01', group: null),
      ),
      isNull,
    );
    expect(
      playlistFor(
        <SourceItemView>[
          item('y1', '[ASW] 某番 SP01 [1080p]'),
          item('y2', '[ASW] 某番 SP02 [1080p]'),
        ],
        item('y1', '[ASW] 某番 SP01 [1080p]'),
      ),
      isNull,
      reason: 'SP 这种没有集号的条目不该进正片列表',
    );
  });

  test('只有一集 → null（单集播放，播放列表按钮隐藏）', () {
    final SourceItemView only =
        item('solo', '[ASW] 某番 - 03 [1080p]');
    expect(playlistFor(<SourceItemView>[only], only), isNull);
  });

  test('同一集号有两条（不同分辨率）：只留一行，且正在播的那条优先', () {
    final List<SourceItemView> batch = <SourceItemView>[
      item('p1', '[ASW] 某番 - 01 [1080p HEVC]'),
      item('p1x', '[ASW] 某番 - 01 [720p AVC]'),
      item('p2', '[ASW] 某番 - 02 [1080p HEVC]'),
    ];
    final Playlist? fromFirst = playlistFor(batch, batch[0]);
    expect(fromFirst!.items.map((SourceItemView i) => i.id), <String>['p1', 'p2']);
    final Playlist? fromSecond = playlistFor(batch, batch[1]);
    expect(fromSecond!.items.first.id, 'p1x', reason: '正在播的是 720p 那条，列表里就该显示它');
    expect(fromSecond.currentIndex, 0);
  });

  test('不同源（nyaa/mikan）之间不互相归组', () {
    final List<SourceItemView> batch = <SourceItemView>[
      item('n1', '[ASW] 某番 - 01 [1080p]', sourceId: 'nyaa'),
      item('m1', '[ASW] 某番 - 01 [1080p]', sourceId: 'mikan'),
      item('n2', '[ASW] 某番 - 02 [1080p]', sourceId: 'nyaa'),
    ];
    final Playlist? list = playlistFor(batch, batch.first);
    expect(list!.items.map((SourceItemView i) => i.id), <String>['n1', 'n2']);
  });

  test('只跟「这一批」归组会丢前几集 → 并上整部番的清单后 7/6/5 都在', () {
    // 用户 2026-10-11 第五次报障原话：「而且不会有前几集，我点第8集就没有765等」。
    // 原因：从「今日更新」点第 8 集时，这一批里只有今天发过的 8/9/10，
    // 前几集从来没进过这一批。解法是把 mikan 番剧页（/Home/Bangumi/<id>）
    // 的整部番清单并进来（`HostDataPort.seriesEpisodes`）。
    final List<SourceItemView> todayBatch = <SourceItemView>[
      item('e8', '[ASW] 某番 - 08 [1080p]'),
      item('e9', '[ASW] 某番 - 09 [1080p]'),
      item('e10', '[ASW] 某番 - 10 [1080p]'),
    ];
    final List<SourceItemView> wholeSeries = <SourceItemView>[
      for (int i = 1; i <= 10; i++) item('e$i', '[ASW] 某番 - ${i.toString().padLeft(2, '0')} [1080p]'),
    ];

    // 旧行为（只用这一批）：列表里只有 3 集、第 8 集前面什么都没有。
    final Playlist? onlyBatch = playlistFor(todayBatch, todayBatch.first);
    expect(onlyBatch!.items.length, 3);
    expect(onlyBatch.hasPrevious, isFalse, reason: '这就是"点第8集没有765"');

    // 新行为（并上整部番的清单）：第 8 集左边有 7/6/5 … 一直到 1。
    final List<SourceItemView> merged =
        mergeCandidates(<Iterable<SourceItemView>>[todayBatch, wholeSeries]);
    final Playlist? list = playlistFor(merged, todayBatch.first);
    expect(list, isNotNull);
    expect(list!.items.length, 10);
    expect(list.currentIndex, 7, reason: '第 8 集在列表里的下标');
    expect(list.previous!.id, 'e7');
    expect(list.items[list.currentIndex - 3].id, 'e5', reason: '用户点名要的 7/6/5');
    expect(list.items.first.id, 'e1');
  });

  test('并批次时按 id 去重，先到先得（搜索结果那份字段优先）', () {
    final List<SourceItemView> a = <SourceItemView>[item('x1', '[ASW] 某番 - 01 [1080p]')];
    final List<SourceItemView> b = <SourceItemView>[
      item('x1', '[ASW] 某番 - 01 [1080p 其它写法]'),
      item('x2', '[ASW] 某番 - 02 [1080p]'),
    ];
    final List<SourceItemView> merged =
        mergeCandidates(<Iterable<SourceItemView>>[a, b]);
    expect(merged.map((SourceItemView i) => i.id), <String>['x1', 'x2']);
    expect(merged.first.title, '[ASW] 某番 - 01 [1080p]');
  });
}
