/// 「已完成」页的数据整理与删除流程单测（2026-10-12 第十四轮）。
///
/// 分三块：
/// 1. **归组**：真实命名（用户给的 VCB 命名 + 真机引擎里的 NEST 命名）归成几张卡；
/// 2. **路径**：引擎给的 `path` 是相对 `outputFolder` 的，必须拼成绝对路径才敢用；
/// 3. **删除流程**：顺序（先移除任务、再回收站）、护栏、失败与警告的如实汇报 ——
///    用**真实临时文件**验，而不是纯 mock（否则"missing 判定"这种会假装通过）。
library;

import 'dart:io';

import 'package:dsanima/domain/completed.dart';
import 'package:dsanima/domain/models.dart';
import 'package:dsanima/domain/recycle_bin.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// 造一个已下完的 torrent（本文件只关心名字/文件/目录这三样）。
EngineTorrentView torrent({
  required int id,
  required String name,
  required List<String> files,
  String? outputFolder,
  int bytes = 100,
}) =>
    EngineTorrentView(
      id: id,
      name: name,
      state: TorrentState.live,
      finished: true,
      progress: 1,
      totalBytes: bytes,
      outputFolder: outputFolder ?? r'F:\Anime\',
      files: <EngineFileView>[
        for (int i = 0; i < files.length; i++)
          EngineFileView(
            index: i,
            path: files[i],
            length: bytes ~/ files.length,
            isVideo: files[i].toLowerCase().endsWith('.mkv') ||
                files[i].toLowerCase().endsWith('.mp4'),
            complete: true,
          ),
      ],
    );

void main() {
  group('归组：按番名分类（用户：「按照名字分类」）', () {
    // 用户原话里那条命名（VCB：一等集一个种子，标题就是文件名）。
    String vcb(int ep) =>
        '[hyakuhuyu&VCB-Studio] Re Zero kara Hajimeru Isekai Seikatsu 3rd Season '
        '[$ep][Ma10p_1080p][x265_flac_aac].CHS.mp4';
    // 真机引擎里那两条（NEST：集号在名字中间，没被括号包住）。
    String nest(int ep) =>
        '[NEST] 飙马野郎 JOJO的奇妙冒险 / スティール・ボール・ラン ジョジョの奇妙な冒険 '
        '- ${ep.toString().padLeft(2, '0')} [NF WEB-DL 1080p AVC AAC][JPSC].mkv';

    test('同一部番的三集（不同种子）进同一张卡，且按集号排好', () {
      final List<CompletedGroup> groups = completedGroups(<EngineTorrentView>[
        torrent(id: 1, name: vcb(52), files: <String>['a.mp4'], bytes: 100),
        torrent(id: 2, name: vcb(51), files: <String>['b.mp4'], bytes: 200),
        torrent(id: 3, name: vcb(53), files: <String>['c.mp4'], bytes: 300),
      ]);
      expect(groups.length, 1);
      final CompletedGroup g = groups.single;
      expect(g.name, 'Re Zero kara Hajimeru Isekai Seikatsu 3rd Season',
          reason: '卡片标题 = 去掉方括号内容后的番名（用户给的期望正是这一句）');
      expect(g.episodes.map((CompletedEpisode e) => e.episode), <int>[51, 52, 53]);
      expect(g.bytes, 600);
      expect(g.episodeRangeLabel, '3 集（51–53）');
    });

    test('NEST 那种「 - 03」也要归到同一张卡（且集号解析成 3 / 4）', () {
      final List<CompletedGroup> groups = completedGroups(<EngineTorrentView>[
        torrent(id: 1, name: nest(3), files: <String>['a.mkv']),
        torrent(id: 2, name: nest(4), files: <String>['b.mkv']),
      ]);
      expect(groups.length, 1);
      expect(groups.single.name, contains('JOJO的奇妙冒险'));
      expect(groups.single.episodes.map((CompletedEpisode e) => e.episode), <int>[3, 4]);
    });

    test('两部不同的番 → 两张卡；卡间按最早集号排', () {
      final List<CompletedGroup> groups = completedGroups(<EngineTorrentView>[
        torrent(id: 1, name: vcb(51), files: <String>['a.mp4']),
        torrent(id: 2, name: nest(3), files: <String>['b.mkv']),
      ]);
      expect(groups.length, 2);
      expect(groups.first.episodes.first.episode, 3);
      expect(groups.last.episodes.first.episode, 51);
    });

    test('认不出番名的（只剩标记/纯数字）：按原始名字单独成卡，不硬凑', () {
      final List<CompletedGroup> groups = completedGroups(<EngineTorrentView>[
        torrent(id: 1, name: '[VCB-Studio][x265][1080p].mp4', files: <String>['a.mp4']),
        torrent(id: 2, name: '[VCB-Studio][x265][1080p].mp4', files: <String>['b.mp4']),
        torrent(id: 3, name: vcb(51), files: <String>['c.mp4']),
      ]);
      expect(groups.length, 2, reason: '两条同名但认不出番名的合成一张；VCB 那条自己一张');
      final CompletedGroup raw = groups.firstWhere((CompletedGroup g) => g.key.startsWith('raw:'));
      expect(raw.count, 2);
      expect(raw.name, '[VCB-Studio][x265][1080p].mp4');
    });

    test('电影/SP 这种没有集号的：集号是 null，卡片照样显示（集号位置显示「—」）', () {
      final List<CompletedGroup> groups = completedGroups(<EngineTorrentView>[
        torrent(id: 1, name: '[Group] Frieren Movie [BDRip 1080p].mkv', files: <String>['a.mkv']),
      ]);
      expect(groups.single.episodes.single.episode, isNull);
      expect(groups.single.episodes.single.episodeLabel, '—');
    });

    test('空输入 → 没有卡（UI 走空态）', () {
      expect(completedGroups(const <EngineTorrentView>[]), isEmpty);
    });
  });

  group('绝对路径：引擎给的 path 是相对 outputFolder 的', () {
    test('相对文件名拼到 outputFolder 上（真机 dump 就是这种形状）', () {
      final EngineTorrentView t = torrent(
        id: 1,
        name: 'x',
        files: <String>['ep01.mkv'],
        outputFolder: r'C:\Users\someone\Downloads\Anime',
      );
      expect(
        engineFileAbsolutePath(t, t.files.single),
        r'C:\Users\someone\Downloads\Anime\ep01.mkv',
      );
    });

    test('已经是绝对路径的原样用（不重复拼目录）', () {
      final EngineTorrentView t = torrent(
        id: 1,
        name: 'x',
        files: <String>[r'D:\Elsewhere\ep01.mkv'],
        outputFolder: r'C:\Users\someone\Downloads\Anime',
      );
      expect(engineFileAbsolutePath(t, t.files.single), r'D:\Elsewhere\ep01.mkv');
    });

    test('文件名里带 `..` 的**不折叠**（折叠后护栏就看不见它了）', () {
      final EngineTorrentView t = torrent(
        id: 1,
        name: 'x',
        files: <String>[r'..\..\Windows\System32\x.dll'],
        outputFolder: r'C:\Downloads\Anime\Show',
      );
      final String abs = engineFileAbsolutePath(t, t.files.single);
      expect(abs, contains('..'), reason: '必须让 recyclablePaths 的 `..` 护栏看得见');
      expect(recyclablePaths(<String>[abs]).isEmpty, isTrue, reason: '于是它被挡在删除之外');
    });

    test('playableAbsolutePath：挑体积最大的视频', () {
      final EngineTorrentView t = EngineTorrentView(
        id: 1,
        name: 'x',
        outputFolder: r'F:\Anime\Show',
        files: const <EngineFileView>[
          EngineFileView(index: 0, path: 'sub.ass', length: 10),
          EngineFileView(index: 1, path: 'ep01.mkv', length: 100, isVideo: true),
          EngineFileView(index: 2, path: 'ep01.1080p.mkv', length: 300, isVideo: true),
        ],
      );
      expect(playableAbsolutePath(t), r'F:\Anime\Show\ep01.1080p.mkv');
    });
  });

  group('删文件流程：先移除任务（不删文件），再进回收站', () {
    late Directory dir;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('dsanima_completed_');
    });
    tearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    EngineTorrentView onDisk(List<String> names) {
      for (final String name in names) {
        File(p.join(dir.path, name)).writeAsStringSync('x');
      }
      return EngineTorrentView(
        id: 7,
        name: '[Group] Show - 01 [1080p].mkv',
        finished: true,
        totalBytes: 2048,
        outputFolder: dir.path,
        files: <EngineFileView>[
          for (int i = 0; i < names.length; i++)
            EngineFileView(index: i, path: names[i], length: 1024, isVideo: true),
        ],
      );
    }

    test('顺序：先 removeByEngine(deleteFiles:false) 再回收站；路径是绝对的', () async {
      final EngineTorrentView t = onDisk(<String>['ep01.mkv', 'ep02.mkv']);
      final List<String> order = <String>[];
      final List<String> recycled = <String>[];

      final CompletedDeleteOutcome outcome = await deleteCompletedFiles(
        torrent: t,
        downloadRoot: dir.path,
        removeFromEngine: (int id) async {
          order.add('remove:$id');
          return null;
        },
        recycle: (List<String> paths) async {
          order.add('recycle');
          recycled.addAll(paths);
          return paths.length;
        },
      );

      expect(order, <String>['remove:7', 'recycle'],
          reason: '必须先移除任务：反过来的话引擎会把"文件消失"记成一条坏任务');
      expect(recycled, <String>[
        p.join(dir.path, 'ep01.mkv'),
        p.join(dir.path, 'ep02.mkv'),
      ]);
      expect(outcome.recycled, 2);
      expect(outcome.missing, isEmpty);
      expect(outcome.blocked, isEmpty);
      expect(outcome.failure, isNull);
    });

    test('下载根自己绝不进回收站：这种路径被护栏挡下，只报告 blocked', () async {
      // 引擎不会把 outputFolder 自己当文件路径给出来，但护栏必须挡住这种输入：
      // 这条用例喂的就是"文件路径 = `.`"（拼出来正好是下载根本身）。
      final List<String> recycled = <String>[];
      final CompletedDeleteOutcome outcome = await deleteCompletedFiles(
        torrent: EngineTorrentView(
          id: 8,
          name: 'x',
          outputFolder: dir.path,
          files: <EngineFileView>[EngineFileView(index: 0, path: '.', length: 1)],
        ),
        downloadRoot: dir.path,
        removeFromEngine: (int id) async => null,
        recycle: (List<String> paths) async {
          recycled.addAll(paths);
          return paths.length;
        },
      );
      expect(recycled, isEmpty, reason: '护栏挡下的路径一个都不许交给回收站');
      expect(outcome.blocked, isNotEmpty);
      expect(outcome.recycled, 0);
    });

    test('文件本来就不在磁盘上 → 算 missing，不算失败', () async {
      final EngineTorrentView t = torrent(
        id: 9,
        name: 'x',
        files: <String>['gone.mkv'],
        outputFolder: dir.path,
      );
      final CompletedDeleteOutcome outcome = await deleteCompletedFiles(
        torrent: t,
        downloadRoot: dir.path,
        removeFromEngine: (int id) async => null,
        recycle: (List<String> paths) async => paths.length,
      );
      expect(outcome.missing, <String>[p.join(dir.path, 'gone.mkv')]);
      expect(outcome.recycled, 1, reason: '回收站实现会把不存在的跳过（这里用假实现，按传入条数返回）');
      expect(outcome.failure, isNull);
    });

    test('回收站整步失败 → failure 有原因，engineWarning 照旧透出来', () async {
      final EngineTorrentView t = onDisk(<String>['ep01.mkv']);
      final CompletedDeleteOutcome outcome = await deleteCompletedFiles(
        torrent: t,
        downloadRoot: dir.path,
        removeFromEngine: (int id) async => '队列里没有这条记录',
        recycle: (List<String> paths) async =>
            throw const RecycleBinException('Windows 拒绝', hint: '关掉占用的播放器再试'),
      );
      expect(outcome.recycled, 0);
      expect(outcome.failure, contains('Windows 拒绝'));
      expect(outcome.failure, contains('关掉占用的播放器再试'));
      expect(outcome.engineWarning, '队列里没有这条记录',
          reason: '引擎那一步的警告不能被回收站的失败吞掉');
    });

    test('引擎的警告（记录删了但引擎没删干净）照旧透出来', () async {
      final EngineTorrentView t = onDisk(<String>['ep01.mkv']);
      final CompletedDeleteOutcome outcome = await deleteCompletedFiles(
        torrent: t,
        downloadRoot: dir.path,
        removeFromEngine: (int id) async => '引擎里已经没有这个任务',
        recycle: (List<String> paths) async => paths.length,
      );
      expect(outcome.engineWarning, '引擎里已经没有这个任务');
      expect(outcome.recycled, 1);
    });
  });
}
