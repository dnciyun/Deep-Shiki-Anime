/// 「起播后按正则关键字补全集」单测。
///
/// 用户原话：「播放列表里的视频不全，加逻辑，播放视频后，使用正则方式加载其他全集。」
///
/// 用例里的标题全部取自真实的种子命名（含中英混排、方括号标签、分辨率/编码尾标）；
/// loader 的用例用假 [SourcePort] 喂多页结果，不联网、不起引擎。
library;

import 'package:dsanima/domain/models.dart';
import 'package:dsanima/domain/playlist.dart';
import 'package:dsanima/domain/ports.dart';
import 'package:dsanima/domain/series_search.dart';
import 'package:dsanima/state/series_loader.dart';
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

SourcePageView page(
  List<SourceItemView> items, {
  required int page,
  bool hasNext = false,
}) => SourcePageView(
  items: items,
  page: page,
  hasNext: hasNext,
  fetchedAt: DateTime(2026, 10, 11),
);

/// 假源：按 `关键字#页码` 取预设的一页，并记录每一次请求（用来断言"翻了几页"）。
class FakeSource implements SourcePort {
  FakeSource(this.pages, {this.fail = false});

  final Map<String, SourcePageView> pages;

  /// true ⇒ 每次 search 都抛（模拟源未接通 / 网络失败）。
  final bool fail;

  final List<String> calls = <String>[];

  @override
  List<SourceOption> get sources => const <SourceOption>[];

  @override
  Future<SourcePageView> latest(String sourceId, {int page = 1}) async =>
      _pageOf(const <SourceItemView>[], page: page);

  @override
  Future<SourcePageView> search(String sourceId, String keyword, {int page = 1}) async {
    calls.add('$keyword#$page');
    if (fail) throw const PortUnavailableException('源未接通');
    return pages['$keyword#$page'] ?? _pageOf(const <SourceItemView>[], page: page);
  }

  SourcePageView _pageOf(List<SourceItemView> items, {required int page, bool hasNext = false}) =>
      SourcePageView(
        items: items,
        page: page,
        hasNext: hasNext,
        fetchedAt: DateTime(2026, 10, 11),
      );
}

void main() {
  group('seriesSearchQueryFor：从真实命名里切关键字', () {
    test('中英混排 + 组标签 + 一串尾标：只留片名，组名走宿主字段', () {
      const String title =
          '[Skymoon-Raws] 遭到流放的转生重骑士 / Tsuihou … - 01 [ViuTV][WEB-DL][CHT][1080p][AVC AAC]';
      final SeriesSearchQuery? q = seriesSearchQueryFor(title, group: 'Skymoon-Raws');
      expect(q, isNotNull);
      expect(q!.keyword, '遭到流放的转生重骑士 / Tsuihou …');
      expect(q.group, 'skymoon-raws');
      expect(q.fingerprint, isNotEmpty);
      // 中英混排的整串在源站搜不到，兜底别名要给出两个单独的名字。
      expect(q.aliasKeywords, <String>['遭到流放的转生重骑士', 'Tsuihou']);
    });

    test('[ANi] 某番 - 12 [1080P][Baha] → 某番', () {
      final SeriesSearchQuery? q =
          seriesSearchQueryFor('[ANi] 某番 - 12 [1080P][Baha]', group: 'ANi');
      expect(q!.keyword, '某番');
      expect(q.group, 'ani');
      expect(q.aliasKeywords, isEmpty, reason: '没有第二个名字就没有别名');
    });

    test('第07话 形态 → 某番', () {
      final SeriesSearchQuery? q = seriesSearchQueryFor('某番 第07话');
      expect(q!.keyword, '某番');
      expect(q.group, isNull, reason: '宿主没给组名时这里不猜（playlistFor 用的是宿主那一份）');
    });

    test('Show.S01E07.1080p → Show（尾部的点也要清掉）', () {
      expect(seriesSearchQueryFor('Show.S01E07.1080p')!.keyword, 'Show');
    });

    test('片名内部的连字符要保住（只清首尾分隔符）', () {
      final SeriesSearchQuery? q = seriesSearchQueryFor(
        '[ASW] Uchi no Otouto-domo ga Sumimasen - 13 [1080p HEVC][A1].mkv',
      );
      expect(q!.keyword, 'Uchi no Otouto-domo ga Sumimasen');
    });

    test('切不出像样关键字 → null（宁可不多搜）', () {
      const List<String> garbage = <String>[
        '',
        '   ',
        '01',
        '1080p',
        'A - 01', // 只剩一个字母
        '[ASW] - 01 [1080p]', // 只有集号
        '[Group] 1080p - 01', // 全是技术标签
        '[ASW] 某番 SP01 [1080p]', // SP/合集：不是"某一集"
        '[ASW] 某番 全集 [1080p]', // 合集：没有集号标记
      ];
      for (final String title in garbage) {
        expect(
          seriesSearchQueryFor(title, group: 'ASW'),
          isNull,
          reason: '「$title」不该拿去搜',
        );
      }
    });
  });

  group('组名归一化', () {
    test('空格/下划线/连字符写法不同也算同一个组', () {
      expect(normalizedGroupName('Skymoon-Raws'), 'skymoon-raws');
      expect(normalizedGroupName(' skymoon raws '), 'skymoon-raws');
      expect(normalizedGroupName('Skymoon_Raws'), 'skymoon-raws');
      expect(normalizedGroupName('-ASW-'), 'asw');
    });

    test('空/纯空白 → null', () {
      expect(normalizedGroupName(null), isNull);
      expect(normalizedGroupName('   '), isNull);
    });
  });

  group('isSameSeriesItem：这一批 + 新一批算不算同一部番', () {
    final SourceItemView base = item('e8', '[ASW] 某番 - 08 [1080p]');

    test('同源同组同指纹 → 是', () {
      expect(isSameSeriesItem(base, item('e5', '[ASW] 某番 - 05 [1080p]')), isTrue);
      expect(isSameSeriesItem(base, item('e9', '[ASW] 某番 - 09 [720p AVC]')), isTrue,
          reason: '尾标不同不影响：指纹切在集号处');
    });

    test('不同组 / 不同番 / 不同源 / 同一条 → 否', () {
      expect(isSameSeriesItem(base, item('x1', '[Erai-raws] 某番 - 05 [1080p]', group: 'Erai-raws')),
          isFalse);
      expect(isSameSeriesItem(base, item('x2', '[ASW] 别的番 - 05 [1080p]')), isFalse);
      expect(isSameSeriesItem(base, item('x3', '[ASW] 某番 - 05 [1080p]', sourceId: 'nyaa')),
          isFalse);
      expect(isSameSeriesItem(base, item('e8', '[ASW] 某番 - 09 [1080p]')), isFalse,
          reason: '同一条不算新增');
      expect(isSameSeriesItem(base, item('x4', '[ASW] 某番 - 05 [1080p]', group: null)), isFalse,
          reason: '组名缺失：与 playlistFor 一样保守，不归组');
    });
  });

  group('seriesPlaylistLooksIncomplete：要不要去补', () {
    test('连列表都没有（只有一集）→ 明显不全', () {
      expect(seriesPlaylistLooksIncomplete(null, const <SourceItemView>[]), isTrue);
    });

    test('列表项数 < 这一批出现过的最大集号 → 不全', () {
      final List<SourceItemView> batch = <SourceItemView>[
        item('e8', '[ASW] 某番 - 08 [1080p]'),
        item('e9', '[ASW] 某番 - 09 [1080p]'),
        item('e10', '[ASW] 某番 - 10 [1080p]'),
      ];
      final Playlist? current = playlistFor(batch, batch.first);
      expect(current!.items.length, 3);
      expect(seriesPlaylistLooksIncomplete(current, batch), isTrue,
          reason: '列表只有 8/9/10，缺的是前面几集');
    });

    test('1..10 都齐了 → 不搜（源站有请求间隔，别白打）', () {
      final List<SourceItemView> batch = <SourceItemView>[
        for (int i = 1; i <= 10; i++)
          item('e$i', '[ASW] 某番 - ${i.toString().padLeft(2, '0')} [1080p]'),
      ];
      final Playlist? current = playlistFor(batch, batch.first);
      expect(seriesPlaylistLooksIncomplete(current, batch), isFalse);
    });
  });

  group('loadSeriesPlaylist：翻页补齐', () {
    final SourceItemView base = item('e8', '[ASW] 某番 - 08 [1080p]');
    final List<SourceItemView> batch = <SourceItemView>[
      item('e8', '[ASW] 某番 - 08 [1080p]'),
      item('e9', '[ASW] 某番 - 09 [1080p]'),
      item('e10', '[ASW] 某番 - 10 [1080p]'),
    ];

    test('多页返回 → 合并出全集（翻到 hasNext=false 为止）', () async {
      final Playlist? current = playlistFor(batch, base);
      expect(current!.items.length, 3);

      final FakeSource source = FakeSource(<String, SourcePageView>{
        '某番#1': page(
          <SourceItemView>[
            item('e1', '[ASW] 某番 - 01 [1080p]'),
            item('e2', '[ASW] 某番 - 02 [1080p]'),
          ],
          page: 1,
          hasNext: true,
        ),
        '某番#2': page(
          <SourceItemView>[
            item('e3', '[ASW] 某番 - 03 [1080p]'),
            item('e4', '[ASW] 某番 - 04 [1080p]'),
            item('x5', '[ASW] 别的番 - 05 [1080p]'),
            item('g5', '[Erai-raws] 某番 - 05 [1080p]', group: 'Erai-raws'),
          ],
          page: 2, // hasNext 默认 false → 停在这里
        ),
      });

      final SeriesLoadResult result = await loadSeriesPlaylist(
        source: source,
        base: base,
        batch: batch,
        current: current,
      );

      expect(source.calls, <String>['某番#1', '某番#2']);
      expect(result.pagesFetched, 2);
      expect(result.matched, 4, reason: '别的番、别的组都不算命中');
      expect(result.playlist!.items.map((SourceItemView i) => i.id),
          <String>['e1', 'e2', 'e3', 'e4', 'e8', 'e9', 'e10']);
      expect(result.playlist!.currentIndex, 4, reason: '第 8 集合并后的下标');
      expect(result.playlist!.previous!.id, 'e4');
    });

    test('源报错 → 原样返回原列表（绝不抛）', () async {
      final Playlist? current = playlistFor(batch, base);
      final FakeSource source = FakeSource(const <String, SourcePageView>{}, fail: true);

      final SeriesLoadResult result = await loadSeriesPlaylist(
        source: source,
        base: base,
        batch: batch,
        current: current,
      );

      expect(identical(result.playlist, current), isTrue);
      expect(result.pagesFetched, 0);
      expect(result.matched, 0);
      expect(source.calls, <String>['某番#1'], reason: '源不通就别用别名再打一次');
    });

    test('关键字切不出来（合集/SP）→ 一次请求都不发', () async {
      final SourceItemView movie = item('m1', '[ASW] 某番 全集 [1080p]');
      final FakeSource source = FakeSource(const <String, SourcePageView>{});

      final SeriesLoadResult result = await loadSeriesPlaylist(
        source: source,
        base: movie,
        batch: <SourceItemView>[movie],
        current: null,
      );

      expect(source.calls, isEmpty);
      expect(result.playlist, isNull);
    });

    test('宿主没给组名 → 不搜（playlistFor 本来就不会归组）', () async {
      final SourceItemView noGroup = item('n8', '[ASW] 某番 - 08 [1080p]', group: null);
      final FakeSource source = FakeSource(const <String, SourcePageView>{});

      final SeriesLoadResult result = await loadSeriesPlaylist(
        source: source,
        base: noGroup,
        batch: <SourceItemView>[noGroup],
        current: null,
      );

      expect(source.calls, isEmpty);
      expect(result.playlist, isNull);
    });

    test('连续两页没有新同系列条目 → 收手（哪怕源还说有下一页）', () async {
      final Playlist? current = playlistFor(batch, base);
      final FakeSource source = FakeSource(<String, SourcePageView>{
        '某番#1': page(<SourceItemView>[item('x1', '[ASW] 别的番 - 01 [1080p]')],
            page: 1, hasNext: true),
        '某番#2': page(<SourceItemView>[item('x2', '[ASW] 别的番 - 02 [1080p]')],
            page: 2, hasNext: true),
        '某番#3': page(<SourceItemView>[item('e1', '[ASW] 某番 - 01 [1080p]')],
            page: 3, hasNext: true),
      });

      final SeriesLoadResult result = await loadSeriesPlaylist(
        source: source,
        base: base,
        batch: batch,
        current: current,
      );

      expect(source.calls, <String>['某番#1', '某番#2'], reason: '第 3 页不该被请求');
      expect(identical(result.playlist, current), isTrue);
    });

    test('主关键字搜不到（中英混排整串）→ 用别名兜底并补齐', () async {
      final SourceItemView mixed = item('e8', '[ASW] 某番 / Some Show - 08 [1080p]');
      final List<SourceItemView> only = <SourceItemView>[mixed];
      final Playlist? current = playlistFor(only, mixed);
      expect(current, isNull, reason: '只有一集时没有列表');

      final FakeSource source = FakeSource(<String, SourcePageView>{
        '某番 / Some Show#1': page(<SourceItemView>[item('x1', '[ASW] 别的番 - 01 [1080p]')],
            page: 1),
        '某番#1': page(<SourceItemView>[item('e7', '[ASW] 某番 / Some Show - 07 [1080p]')],
            page: 1),
      });

      final SeriesLoadResult result = await loadSeriesPlaylist(
        source: source,
        base: mixed,
        batch: only,
        current: current,
      );

      expect(source.calls, <String>['某番 / Some Show#1', '某番#1']);
      expect(result.keywordsTried.length, 2);
      expect(result.playlist!.items.map((SourceItemView i) => i.id), <String>['e7', 'e8']);
      expect(result.playlist!.currentIndex, 1);
    });

    test('主关键字就命中了 → 不再试别名', () async {
      final SourceItemView mixed = item('e8', '[ASW] 某番 / Some Show - 08 [1080p]');
      final FakeSource source = FakeSource(<String, SourcePageView>{
        '某番 / Some Show#1': page(
          <SourceItemView>[item('e7', '[ASW] 某番 / Some Show - 07 [1080p]')],
          page: 1,
        ),
      });

      final SeriesLoadResult result = await loadSeriesPlaylist(
        source: source,
        base: mixed,
        batch: <SourceItemView>[mixed],
        current: null,
      );

      expect(source.calls, <String>['某番 / Some Show#1']);
      expect(result.keywordsTried, <String>['某番 / Some Show']);
      expect(result.playlist!.items.length, 2);
    });

    test('搜到的东西不构成更长的列表 → 保持原样', () async {
      final Playlist? current = playlistFor(batch, base);
      final FakeSource source = FakeSource(<String, SourcePageView>{
        // 只有正在播的这一条（同 id）→ 合并后还是 3 集，不该替换。
        '某番#1': page(<SourceItemView>[item('e8', '[ASW] 某番 - 08 [1080p]')], page: 1),
      });

      final SeriesLoadResult result = await loadSeriesPlaylist(
        source: source,
        base: base,
        batch: batch,
        current: current,
      );

      expect(identical(result.playlist, current), isTrue);
      expect(result.matched, 0, reason: '同一条不算新增');
    });
  });
}
