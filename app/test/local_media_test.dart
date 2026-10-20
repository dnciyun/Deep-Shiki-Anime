/// `domain/local_media.dart` 的纯逻辑测试（不碰磁盘、不起引擎）。
///
/// 钉住的都是"会悄悄错"的地方：
/// * 字幕配对（同目录、同名 / 带语言段、扩展名优先级）——配错比不配更糟；
/// * 集号排序（认不出集号的排在有集号之后、不编一个"第 1 集"）；
/// * `file:` URI 与真实路径的互转（中文 / 空格 / 百分号编码）；
/// * 进度该不该留（刚打开不记、看完清掉、条数上限）。
library;

import 'package:dsanima/domain/local_media.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

LocalFileStat _f(String path, {int size = 1000, DateTime? at}) =>
    LocalFileStat(path: path, sizeBytes: size, modifiedAt: at);

void main() {
  group('扩展名', () {
    test('认视频 / 认字幕（大小写不敏感）', () {
      expect(isLocalVideoPath(r'F:\a\Show - 01.mkv'), isTrue);
      expect(isLocalVideoPath(r'F:\a\Show - 01.MP4'), isTrue);
      expect(isLocalVideoPath(r'F:\a\Show - 01.rmvb'), isTrue);
      expect(isLocalVideoPath(r'F:\a\Show - 01.ass'), isFalse);
      expect(isLocalVideoPath(r'F:\a\note.txt'), isFalse);
      expect(isLocalVideoPath(r'F:\a\noext'), isFalse);
      expect(isLocalVideoPath(r'F:\a\image.iso'), isFalse, reason: 'iso 得先挂载，不收');

      expect(isLocalSubtitlePath(r'F:\a\Show - 01.ass'), isTrue);
      expect(isLocalSubtitlePath(r'F:\a\Show - 01.srt'), isTrue);
      expect(isLocalSubtitlePath(r'F:\a\Show - 01.mkv'), isFalse);
    });
  });

  group('扫描结果整理', () {
    test('只留视频；字幕按同目录同名配对', () {
      final String dir = p.join('F:', 'Anime', 'Show');
      final List<LocalVideo> videos = localVideosFrom(
        folder: p.join('F:', 'Anime'),
        files: <LocalFileStat>[
          _f(p.join(dir, 'Show - 01.mkv')),
          _f(p.join(dir, 'Show - 02.mkv')),
          _f(p.join(dir, 'Show - 01.ass')),
          _f(p.join(dir, 'Show - 02.zh.srt')),
          _f(p.join(dir, 'cover.jpg')),
          _f(p.join(dir, 'notes.txt')),
        ],
      );
      expect(videos.map((LocalVideo v) => p.basename(v.path)), <String>['Show - 01.mkv', 'Show - 02.mkv']);
      expect(p.basename(videos[0].subtitlePath!), 'Show - 01.ass');
      expect(p.basename(videos[1].subtitlePath!), 'Show - 02.zh.srt',
          reason: '带语言段（.zh）也要配上');
      expect(videos[0].folder, dir, reason: '所在目录要记下来（归组/分段靠它）');
    });

    test('字幕扩展名优先级：ass > ssa > srt > vtt', () {
      final String dir = p.join('F:', 'Anime', 'Show');
      final List<LocalVideo> videos = localVideosFrom(
        folder: p.join('F:', 'Anime'),
        files: <LocalFileStat>[
          _f(p.join(dir, 'Show - 01.mkv')),
          _f(p.join(dir, 'Show - 01.srt')),
          _f(p.join(dir, 'Show - 01.vtt')),
          _f(p.join(dir, 'Show - 01.ass')),
        ],
      );
      expect(p.basename(videos.single.subtitlePath!), 'Show - 01.ass');
    });

    test('完全同名的字幕优先于带语言段的', () {
      final String dir = p.join('F:', 'Anime', 'Show');
      final List<LocalVideo> videos = localVideosFrom(
        folder: p.join('F:', 'Anime'),
        files: <LocalFileStat>[
          _f(p.join(dir, 'Show - 01.mkv')),
          _f(p.join(dir, 'Show - 01.zh.ass')),
          _f(p.join(dir, 'Show - 01.srt')),
        ],
      );
      expect(p.basename(videos.single.subtitlePath!), 'Show - 01.srt');
    });

    test('别的番的字幕不会硬挂上来', () {
      final String dir = p.join('F:', 'Anime', 'Show');
      final List<LocalVideo> videos = localVideosFrom(
        folder: p.join('F:', 'Anime'),
        files: <LocalFileStat>[
          _f(p.join(dir, 'Show - 01.mkv')),
          _f(p.join(dir, 'Another Show - 01.ass')),
        ],
      );
      expect(videos.single.subtitlePath, isNull);
    });

    test('排序：集号升序，认不出集号的排在后面', () {
      final String dir = p.join('F:', 'Anime', 'Show');
      final List<LocalVideo> videos = localVideosFrom(
        folder: p.join('F:', 'Anime'),
        files: <LocalFileStat>[
          _f(p.join(dir, 'Show - 03.mkv')),
          _f(p.join(dir, 'Show - 01.mkv')),
          _f(p.join(dir, 'Show - 02.mkv')),
          _f(p.join(dir, 'Menu.mkv')),
        ],
      );
      expect(videos.map((LocalVideo v) => v.episode), <int?>[1, 2, 3, null]);
      expect(videos.last.title, 'Menu');
    });

    test('集号来自文件名（沿用 episode_group 的解析）', () {
      final String dir = p.join('F:', 'Anime', 'Show');
      final LocalVideo v = localVideosFrom(
        folder: p.join('F:', 'Anime'),
        files: <LocalFileStat>[_f(p.join(dir, '[Group] Show - 07 [1080p].mkv'))],
      ).single;
      expect(v.episode, 7, reason: '分辨率 1080p 不能被当成集号');
    });
  });

  group('目录分段', () {
    test('按目录分成多段，根目录排最前，标题是相对路径', () {
      final String root = p.join('F:', 'Anime');
      final String s1 = p.join(root, 'Show', 'S1');
      final String s2 = p.join(root, 'Other');
      final List<LocalFolderGroup> groups = localGroupsOf(<LocalScanResult>[
        LocalScanResult(
          folder: root,
          videos: <LocalVideo>[
            ...localVideosFrom(folder: root, files: <LocalFileStat>[_f(p.join(root, 'movie.mkv'))]),
            ...localVideosFrom(folder: root, files: <LocalFileStat>[
              _f(p.join(s2, 'Other - 01.mkv')),
              _f(p.join(s2, 'Other - 02.mkv')),
            ]),
            ...localVideosFrom(folder: root, files: <LocalFileStat>[
              _f(p.join(s1, 'Show - 02.mkv')),
              _f(p.join(s1, 'Show - 01.mkv')),
            ]),
          ],
        ),
      ], order: <String, int>{root: 0});
      expect(groups.map((LocalFolderGroup g) => g.label), <String>['Anime', p.join('Other'), p.join('Show', 'S1')]);
      expect(groups.first.rootFolder, root);
      expect(groups.last.videos.map((LocalVideo v) => v.episode), <int?>[1, 2]);
      expect(groups.last.totalBytes, 2000);
    });

    test('扫失败的文件夹不产出分段（原因留在结果里）', () {
      final List<LocalFolderGroup> groups = localGroupsOf(<LocalScanResult>[
        const LocalScanResult(folder: r'F:\Offline', error: '盘掉线了'),
      ]);
      expect(groups, isEmpty);
    });
  });

  group('file: URI 与真实路径', () {
    test('中文 / 空格 / 反斜杠都能还原', () {
      const String path = r'F:\Ai\アニメ 番剧\第01話 [1080p].mkv';
      final String uri = localFileUriText(path);
      expect(uri.startsWith('file:'), isTrue);
      expect(Uri.parse(uri).scheme, 'file');
      expect(localPathOf(uri), path);
      expect(localPathOf(path), path, reason: '真实路径原样返回');
    });

    test('网流 / 空串不算本地路径', () {
      expect(localPathOf('http://127.0.0.1:9/torrents/1/files/0/stream'), isEmpty);
      expect(localPathOf('https://example.invalid/a.mkv'), isEmpty);
      expect(localPathOf(''), isEmpty);
    });

    test('Uri.parse 直接吃 Windows 路径是错的（这就是要转 file: 的原因）', () {
      expect(Uri.parse(r'F:\a\b.mkv').scheme, 'f',
          reason: 'scheme 变成盘符 → 播放器那边打不开');
      expect(Uri.parse(localFileUriText(r'F:\a\b.mkv')).scheme, 'file');
    });
  });

  group('进度', () {
    test('刚打开（<5 秒）不记；看完（>=90%）清掉；其余留着', () {
      expect(localProgressToKeep(positionMs: 3000, durationMs: 1440000), isNull);
      expect(localProgressToKeep(positionMs: 60000, durationMs: 1440000), 60000);
      expect(localProgressToKeep(positionMs: 1300000, durationMs: 1440000), isNull,
          reason: '90% 以上算看完，下次从头播');
      expect(localProgressToKeep(positionMs: 60000, durationMs: 0), 60000,
          reason: '时长未知时只按"看过 5 秒以上"判');
    });

    test('读盘脏数据：非 map / 非数字 的条目直接丢掉，不影响其它条', () {
      final Map<String, LocalProgress> read = readLocalProgress(<String, Object?>{
        r'F:\a\b.mkv': <String, Object?>{'positionMs': 1234},
        r'F:\a\c.mkv': 'not a map',
        r'F:\a\d.mkv': <String, Object?>{'positionMs': 'x'},
        '': <String, Object?>{'positionMs': 5},
      });
      expect(read.keys, <String>[r'F:\a\b.mkv']);
      expect(read[r'F:\a\b.mkv']!.positionMs, 1234);
      expect(read[r'F:\a\b.mkv']!.durationMs, 0);
    });

    test('文件夹清单去重 / 去空 / 丢非字符串', () {
      expect(
        readLocalFolders(<Object?>[r'F:\Anime', r'F:\Anime', '  ', 42, r'F:\Other']),
        <String>[r'F:\Anime', r'F:\Other'],
      );
      expect(readLocalFolders('oops'), isEmpty);
    });

    test('修剪：丢掉刚打开的与看完的，按最近更新截断', () {
      final DateTime base = DateTime(2026, 10, 20);
      final Map<String, LocalProgress> pruned = pruneLocalProgress(<String, LocalProgress>{
        'a': LocalProgress(positionMs: 100, durationMs: 100000, updatedAt: base),
        'b': LocalProgress(positionMs: 60000, durationMs: 100000, updatedAt: base),
        'c': LocalProgress(positionMs: 95000, durationMs: 100000, updatedAt: base),
      });
      expect(pruned.keys, <String>['b']);
    });

    test('编码成 JSON 时省掉 0 时长', () {
      final Map<String, Object?> json = encodeLocalProgress(<String, LocalProgress>{
        r'F:\a\b.mkv': LocalProgress(positionMs: 60000),
      });
      final Map<String, Object?> first = json[r'F:\a\b.mkv']! as Map<String, Object?>;
      expect(first['positionMs'], 60000);
      expect(first.containsKey('durationMs'), isFalse);
    });
  });

  group('归组条目', () {
    test('同目录的连续集能归成一组（交给 groupEpisodes）', () {
      final String dir = p.join('F:', 'Anime', 'Show');
      final List<LocalVideo> videos = localVideosFrom(
        folder: p.join('F:', 'Anime'),
        files: <LocalFileStat>[
          _f(p.join(dir, 'Show - 01.mkv')),
          _f(p.join(dir, 'Show - 02.mkv')),
          _f(p.join(dir, 'Show - 01.ass')),
        ],
      );
      final entries = localEpisodeEntries(videos);
      expect(entries.length, 2);
      expect(entries.first.path, videos.first.path);
      expect(entries.first.subtitlePath, isNotNull, reason: '字幕要跟着条目走（换集不丢）');
    });
  });
}
