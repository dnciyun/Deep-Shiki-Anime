/// 同剧集归组的单元测试（决策 B31）。
///
/// 用用户给的真实命名做样例 —— 这条规则的价值全在真实番剧命名上，
/// 用编造的名字测不出问题。
library;

import 'package:dsanima/domain/episode_group.dart';
import 'package:dsanima/domain/models.dart';
import 'package:dsanima/domain/ports.dart';
import 'package:dsanima/state/playback.dart' show episodeGroupingFor;
import 'package:flutter_test/flutter_test.dart';

/// 只给流地址的假引擎端口（`episodeGroupingFor` 要用）。
class _UrlEngine implements EnginePort {
  @override
  Uri? streamUrl(int id, int fileIndex) =>
      Uri.parse('http://127.0.0.1:1/torrents/$id/files/$fileIndex/stream?token=t');

  @override
  Future<EngineHealthView> health() async => const EngineHealthView(ok: false);

  @override
  Future<List<EngineTorrentView>> list() async => const <EngineTorrentView>[];

  @override
  Future<EngineTorrentView> addMagnet(
    String magnet, {
    String? name,
    List<int>? onlyFiles,
    bool startPaused = false,
    String? subFolder,
  }) async => throw const PortUnavailableException('测试替身：不加种');

  @override
  Future<void> pause(int id) async {}

  @override
  Future<void> resume(int id) async {}

  @override
  Future<void> remove(int id, {bool deleteFiles = false}) async {}

  @override
  Stream<List<EngineTorrentView>> watch() =>
      const Stream<List<EngineTorrentView>>.empty();
}

void main() {
  group('集号解析', () {
    test('真实番剧命名', () {
      // 用户原话里那一条
      expect(
        parseEpisodeNumber(
            '[Skymoon-Raws] 遭到流放的转生重骑士凭借游戏知识大开无双 / '
            'Tsuihou sareta Tensei Juukishi wa Game Chishiki de Musou suru - 01 '
            '[ViuTV][WEB-DL][CHT][1080p][AVC AAC].mkv'),
        1,
      );
      expect(parseEpisodeNumber('Show - 12 [1080p].mkv'), 12);
      expect(parseEpisodeNumber('[Group] Show EP07.mkv'), 7);
      expect(parseEpisodeNumber('[Group] Show S02E11 1080p.mkv'), 11);
      expect(parseEpisodeNumber('葬送的芙莉莲 第03话.mkv'), 3);
      expect(parseEpisodeNumber('Show_05_简繁.mkv'), 5);
      expect(parseEpisodeNumber('Show [03].mkv'), 3);
    });

    test('分辨率/年份绝不能被当成集号', () {
      expect(parseEpisodeNumber('Show 1080p.mkv'), isNull);
      expect(parseEpisodeNumber('Show 2160p HDR.mkv'), isNull);
      expect(parseEpisodeNumber('Show 2019.mkv'), isNull);
      expect(parseEpisodeNumber('Show 720p x264.mkv'), isNull);
    });

    test('没有集号的文件不参与归组', () {
      expect(parseEpisodeNumber('Movie [BDRip][1080p].mkv'), isNull);
      expect(parseEpisodeNumber('Show SP.mkv'), isNull);
    });
  });

  group('第十二/十三轮：引擎文件清单那条路（episodeGroupingFor）', () {
    // 合并种子（一个 torrent 里好几集）走的就是这条路：标题 = 文件名，path = 串流 URL。
    // 原实现把集号解析**留给** `groupEpisodes`，而它拿 `e.path`（串流 URL）解析 ——
    // basename 是 `stream?token=…`，一个数字都没有 ⇒ 每一集都被丢掉 ⇒ 整组返回 null
    // ⇒ 播放器连「上一集 / 下一集 / 播放列表」都不显示。
    EngineTorrentView vcbBatch() => EngineTorrentView(
      id: 3,
      name: '[hyakuhuyu&VCB-Studio] Re Zero 3rd Season [Ma10p_1080p]',
      state: TorrentState.live,
      files: <EngineFileView>[
        for (int i = 0; i < 3; i++)
          EngineFileView(
            index: i,
            path:
                r'F:\Anime\ReZero3\[hyakuhuyu&VCB-Studio] Re Zero kara Hajimeru '
                'Isekai Seikatsu 3rd Season [${51 + i}][Ma10p_1080p][x265_flac_aac].CHS.mp4',
            length: 1000,
            isVideo: true,
            complete: true,
          ),
      ],
    );

    test('一个 torrent 里好几集 → 能归出组，集号来自**文件名**', () {
      final EpisodeGrouping? g = episodeGroupingFor(
        torrent: vcbBatch(),
        fileIndex: 0,
        engine: _UrlEngine(),
      );
      expect(g, isNotNull, reason: '合并种子必须有播放列表（上一集/下一集）');
      expect(g!.entries.map((EpisodeEntry e) => e.episode).toList(), <int>[51, 52, 53]);
      expect(g.hasNext, isTrue);
      expect(g.next!.streamUri.toString(),
          'http://127.0.0.1:1/torrents/3/files/1/stream?token=t');
      expect(g.entries.first.title, contains('[51]'));
    });

    test('文件名里没有集号的（电影/SP）不参与归组', () {
      final EngineTorrentView movie = EngineTorrentView(
        id: 9,
        name: 'movie',
        files: <EngineFileView>[
          const EngineFileView(
              index: 0, path: r'F:\Anime\Movie [BDRip][1080p].mkv', isVideo: true),
          const EngineFileView(
              index: 1, path: r'F:\Anime\Movie [BDRip][1080p].ass', isVideo: false),
        ],
      );
      expect(
        episodeGroupingFor(torrent: movie, fileIndex: 0, engine: _UrlEngine()),
        isNull,
        reason: '解析不出集号 → 宁可没有列表，也不要把不相干的文件凑成"上一集"',
      );
    });
  });

  group('归组', () {
    EpisodeEntry e(String name, {String dir = r'F:\Anime\Show'}) =>
        EpisodeEntry(title: name, path: '$dir\\$name');

    test('同目录同名不同集 → 同组，按集号升序，index 指向当前集', () {
      final List<EpisodeEntry> all = <EpisodeEntry>[
        e('[Skymoon-Raws] Show / Tsuihou - 03 [ViuTV][1080p].mkv'),
        e('[Skymoon-Raws] Show / Tsuihou - 01 [ViuTV][1080p].mkv'),
        e('[Skymoon-Raws] Show / Tsuihou - 02 [ViuTV][1080p].mkv'),
      ];
      final EpisodeGrouping? g = groupEpisodes(
          all, r'F:\Anime\Show\[Skymoon-Raws] Show / Tsuihou - 01 [ViuTV][1080p].mkv');
      expect(g, isNotNull);
      expect(g!.entries.map((EpisodeEntry x) => x.episode).toList(),
          <int>[1, 2, 3], reason: '必须按集号升序');
      expect(g.currentIndex, 0);
      expect(g.hasPrev, isFalse);
      expect(g.hasNext, isTrue);
      expect(g.next!.episode, 2);
    });

    test('不同字幕组 / 不同目录 / 不同番 → 不进同一组', () {
      final List<EpisodeEntry> all = <EpisodeEntry>[
        e('[GroupA] Show - 01.mkv'),
        e('[GroupB] Show - 02.mkv'), // 换组 → 指纹不同
        e('Show - 02.mkv', dir: r'F:\Anime\Other'), // 换目录
        e('Other Show - 02.mkv'), // 换番名 → 指纹不同
      ];
      final EpisodeGrouping? g =
          groupEpisodes(all, r'F:\Anime\Show\[GroupA] Show - 01.mkv');
      // 只有自己一集够格（换组/换目录/换番都不算）→ 返回 null，UI 隐藏上一/下一集
      expect(g, isNull);
    });

    test('同一个组内只有两集时也要能给出下一集', () {
      final List<EpisodeEntry> all = <EpisodeEntry>[
        e('[GroupA] Show - 01.mkv'),
        e('[GroupA] Show - 02.mkv'),
      ];
      final EpisodeGrouping? g =
          groupEpisodes(all, r'F:\Anime\Show\[GroupA] Show - 01.mkv');
      expect(g, isNotNull);
      expect(g!.entries.length, 2);
      expect(g.currentIndex, 0);
      expect(g.next!.episode, 2);
      expect(g.hasPrev, isFalse);
    });

    test('04 集的 1080p 与 720p 两版同集号 → 都进组且顺序稳定', () {
      final List<EpisodeEntry> all = <EpisodeEntry>[
        e('Show - 01 [1080p].mkv'),
        e('Show - 01 [720p].mkv'),
        e('Show - 02 [1080p].mkv'),
      ];
      final EpisodeGrouping? g = groupEpisodes(all, r'F:\Anime\Show\Show - 01 [720p].mkv');
      expect(g, isNotNull);
      expect(g!.entries.length, 3);
      expect(g.entries.map((EpisodeEntry x) => x.episode).toList(),
          <int>[1, 1, 2]);
      expect(g.entries[g.currentIndex].path, r'F:\Anime\Show\Show - 01 [720p].mkv');
    });

    test('当前集不在候选里 → null（不猜一个"像是下一集"的东西）', () {
      final List<EpisodeEntry> all = <EpisodeEntry>[e('Show - 01.mkv')];
      expect(groupEpisodes(all, r'F:\Anime\Show\Show - 09.mkv'), isNull);
    });

    test('单集 → null（UI 不该显示上一集/下一集按钮）', () {
      final List<EpisodeEntry> all = <EpisodeEntry>[e('Show - 01.mkv')];
      expect(groupEpisodes(all, r'F:\Anime\Show\Show - 01.mkv'), isNull);
    });

    test('网流场景：串流 URL 被带进组里（MediaItem 要用它）', () {
      final List<EpisodeEntry> all = <EpisodeEntry>[
        EpisodeEntry(
            title: 'Show 01',
            path: 'http://127.0.0.1:1/torrents/3/files/0/stream',
            streamUri: Uri.parse('http://127.0.0.1:1/torrents/3/files/0/stream'),
            episode: 1),
        EpisodeEntry(
            title: 'Show 02',
            path: 'http://127.0.0.1:1/torrents/3/files/1/stream',
            streamUri: Uri.parse('http://127.0.0.1:1/torrents/3/files/1/stream'),
            episode: 2),
      ];
      final EpisodeGrouping? g = groupEpisodes(
          all, 'http://127.0.0.1:1/torrents/3/files/0/stream');
      expect(g, isNotNull);
      expect(g!.hasPrev, isFalse);
      expect(g.hasNext, isTrue);
      expect(g.next!.streamUri.toString(),
          'http://127.0.0.1:1/torrents/3/files/1/stream');
    });

    test('指纹：集号之后的内容（分辨率/字幕组尾标）不参与比较', () {
      final String a = episodeFingerprint(
          '[Skymoon-Raws] 遭到流放的转生重骑士 / Tsuihou - 01 '
          '[ViuTV][WEB-DL][CHT][1080p][AVC AAC].mkv');
      final String b = episodeFingerprint(
          '[Skymoon-Raws] 遭到流放的转生重骑士 / Tsuihou - 02 '
          '[ViuTV][WEB-DL][CHT][1080p][AVC AAC].mkv');
      expect(a, b, reason: '01 与 02 必须归到同一部番');
      // 指纹 = 集号**之前**那一段（取紧邻集号的那节做稳定键）：
      // 不含集号本身，也不含集号之后的尾标（1080p / 字幕组 / 编码）。
      // 这段正是同一部番各集之间唯一不变的部分，所以够用且抗噪。
      expect(a, 'tsuihou');
      expect(a, isNot(contains('1080p')));
      expect(a, isNot(contains('01')));
    });
  });
}
