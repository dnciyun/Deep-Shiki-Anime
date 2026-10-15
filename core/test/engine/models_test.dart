import 'package:dsanima_core/dsanima_core.dart';
import 'package:flutter_test/flutter_test.dart';

/// spec §3.6 的完整 TorrentView 样本。
const Map<String, Object?> kFullTorrentView = <String, Object?>{
  'id': 3,
  'infoHash': 'abcdef0123456789abcdef0123456789abcdef01',
  'name': '[Sub] Anime - 01 [1080p]',
  'state': 'live',
  'error': null,
  'totalBytes': 1000000,
  'progressBytes': 250000,
  'uploadedBytes': 4096,
  'downloadBps': 1234567,
  'uploadBps': 789,
  'peers': 12,
  'progress': 0.25,
  'finished': false,
  'outputFolder': r'F:\downloads\[Sub] Anime - 01',
  'files': <Map<String, Object?>>[
    <String, Object?>{
      'index': 0,
      'path': 'Anime - 01.mkv',
      'length': 900000,
      'downloaded': 250000,
      'progress': 0.2777,
      'included': true,
      'mime': 'video/x-matroska',
      'isVideo': true,
      'complete': false,
    },
    <String, Object?>{
      'index': 1,
      'path': 'Anime - 01.ass',
      'length': 100000,
      'downloaded': 100000,
      'progress': 1.0,
      'included': true,
      'mime': 'text/x-ssa',
      'isVideo': false,
      'complete': true,
    },
  ],
};

Map<String, dynamic> torrentJson([Map<String, Object?> overrides = const {}]) =>
    <String, dynamic>{...kFullTorrentView, ...overrides};

Map<String, dynamic> fileJson([Map<String, Object?> overrides = const {}]) =>
    <String, dynamic>{
      'index': 0,
      'path': 'a/b.mkv',
      'length': 100,
      'downloaded': 50,
      'progress': 0.5,
      'included': true,
      'mime': 'video/x-matroska',
      'isVideo': true,
      'complete': false,
      ...overrides,
    };

void main() {
  group('EngineTorrent.fromJson 逐字段', () {
    test('完整 TorrentView', () {
      final torrent = EngineTorrent.fromJson(torrentJson());
      expect(torrent.id, 3);
      expect(torrent.infoHash, 'abcdef0123456789abcdef0123456789abcdef01');
      expect(torrent.name, '[Sub] Anime - 01 [1080p]');
      expect(torrent.state, EngineTorrentState.live);
      expect(torrent.rawState, 'live');
      expect(torrent.error, isNull);
      expect(torrent.totalBytes, 1000000);
      expect(torrent.progressBytes, 250000);
      expect(torrent.uploadedBytes, 4096);
      expect(torrent.downloadBps, 1234567);
      expect(torrent.uploadBps, 789);
      expect(torrent.peers, 12);
      expect(torrent.progress, 0.25);
      expect(torrent.finished, isFalse);
      expect(torrent.outputFolder, r'F:\downloads\[Sub] Anime - 01');
      expect(torrent.files, hasLength(2));

      final video = torrent.files[0];
      expect(video.index, 0);
      expect(video.path, 'Anime - 01.mkv');
      expect(video.length, 900000);
      expect(video.downloaded, 250000);
      expect(video.progress, 0.2777);
      expect(video.included, isTrue);
      expect(video.mime, 'video/x-matroska');
      expect(video.isVideo, isTrue);
      expect(video.complete, isFalse);
      expect(video.extension, 'mkv');
      expect(video.directory, '');
      expect(video.fileName, 'Anime - 01.mkv');

      final subtitle = torrent.files[1];
      expect(subtitle.index, 1);
      expect(subtitle.isSubtitle, isTrue);
      expect(subtitle.complete, isTrue);
    });

    test('POST /torrents 的部分响应（只有 id/infoHash/name/files）不崩', () {
      final torrent = EngineTorrent.fromJson(<String, dynamic>{
        'id': 7,
        'infoHash': 'ff' * 20,
        'name': '新增',
        'files': <Map<String, Object?>>[
          <String, Object?>{
            'index': 0,
            'path': 'ep01.mkv',
            'length': 10,
            'included': true,
            'mime': 'video/x-matroska',
            'isVideo': true,
          },
        ],
      });
      expect(torrent.id, 7);
      expect(torrent.name, '新增');
      expect(
        torrent.state,
        EngineTorrentState.initializing,
        reason: '缺 state 视为刚提交',
      );
      expect(torrent.rawState, isNull);
      expect(torrent.totalBytes, 0);
      expect(torrent.progressBytes, 0);
      expect(torrent.downloadBps, 0);
      expect(torrent.peers, 0);
      expect(torrent.finished, isFalse);
      expect(torrent.outputFolder, isNull);
      expect(torrent.files.single.downloaded, 0);
      expect(
        torrent.files.single.complete,
        isFalse,
        reason: 'length>0 且 downloaded=0',
      );
    });

    test('完全空的 JSON 也不崩（全部走默认值）', () {
      final torrent = EngineTorrent.fromJson(<String, dynamic>{});
      expect(torrent.id, 0);
      expect(torrent.infoHash, '');
      expect(torrent.name, '');
      expect(torrent.state, EngineTorrentState.initializing);
      expect(torrent.files, isEmpty);
      expect(torrent.playableFile, isNull);
      expect(torrent.downloadedSubtitleFiles, isEmpty);
    });

    test('未知 state → error 并保留原始字面量', () {
      final torrent = EngineTorrent.fromJson(
        torrentJson(<String, Object?>{'state': 'seeding', 'error': 'boom'}),
      );
      expect(torrent.state, EngineTorrentState.error);
      expect(torrent.rawState, 'seeding');
      expect(torrent.error, 'boom');
    });

    test('所有已知 state 字面量', () {
      for (final name in <String>['initializing', 'live', 'paused', 'error']) {
        final torrent = EngineTorrent.fromJson(
          torrentJson(<String, Object?>{'state': name}),
        );
        expect(torrent.state.wireName, name);
      }
    });

    test('类型不符/字符串数字都容错', () {
      final torrent = EngineTorrent.fromJson(
        torrentJson(<String, Object?>{
          'id': '3',
          'totalBytes': '1000',
          'progressBytes': 2.9,
          'peers': '12',
          'downloadBps': '1.5e3',
          'progress': '0.5',
          'finished': 0,
          'name': 42,
          'files': 'not-a-list',
        }),
      );
      expect(torrent.id, 3);
      expect(torrent.totalBytes, 1000);
      expect(torrent.progressBytes, 2, reason: 'double → int 截断');
      expect(torrent.peers, 12);
      expect(torrent.downloadBps, 1500);
      expect(torrent.progress, 0.5);
      expect(torrent.finished, isFalse);
      expect(torrent.name, '42');
      expect(torrent.files, isEmpty, reason: 'files 不是数组 → 空列表');
    });

    test('files 里的非对象元素被跳过', () {
      final torrent = EngineTorrent.fromJson(
        torrentJson(<String, Object?>{
          'files': <Object?>[
            'x',
            1,
            <String, Object?>{'index': 5, 'path': 'a.mkv'},
          ],
        }),
      );
      expect(torrent.files, hasLength(1));
      expect(torrent.files.single.index, 5);
    });
  });

  group('EngineFile 容错', () {
    test('complete 缺省按 downloaded >= length 推导', () {
      expect(
        EngineFile.fromJson(
          fileJson(<String, Object?>{'complete': null}),
        ).complete,
        isFalse,
        reason: 'downloaded=50 < length=100',
      );
      expect(
        EngineFile.fromJson(
          fileJson(<String, Object?>{'complete': null, 'downloaded': 0}),
        ).complete,
        isFalse,
      );
      expect(
        EngineFile.fromJson(
          fileJson(<String, Object?>{
            'complete': null,
            'downloaded': 0,
            'length': 0,
          }),
        ).complete,
        isFalse,
        reason: 'length=0 不能算下完',
      );
      expect(
        EngineFile.fromJson(
          fileJson(<String, Object?>{'complete': null, 'downloaded': 200}),
        ).complete,
        isTrue,
        reason: '容忍 downloaded >= length',
      );
    });

    test('progress 缺省按 downloaded/length 推导', () {
      final file = EngineFile.fromJson(
        fileJson(<String, Object?>{
          'progress': null,
          'downloaded': 25,
          'length': 100,
        }),
      );
      expect(file.progress, 0.25);
      expect(
        EngineFile.fromJson(
          fileJson(<String, Object?>{'progress': null, 'length': 0}),
        ).progress,
        0.0,
      );
    });

    test('isVideo 缺省时按 mime + 扩展名推导', () {
      final byExtension = EngineFile.fromJson(
        fileJson(<String, Object?>{
          'isVideo': null,
          'mime': null,
          'path': 'x/y.MP4',
        }),
      );
      expect(byExtension.isVideo, isTrue, reason: '大小写不敏感');
      expect(byExtension.extension, 'mp4');

      final byMime = EngineFile.fromJson(
        fileJson(<String, Object?>{
          'isVideo': null,
          'mime': 'video/webm',
          'path': 'x/y.bin',
        }),
      );
      expect(byMime.isVideo, isTrue);

      final neither = EngineFile.fromJson(
        fileJson(<String, Object?>{
          'isVideo': null,
          'mime': 'application/octet-stream',
          'path': 'x/y.txt',
        }),
      );
      expect(neither.isVideo, isFalse);
    });

    test('视频扩展名集合覆盖 spec 列表', () {
      for (final extension in <String>[
        'mkv',
        'mp4',
        'webm',
        'avi',
        'mov',
        'ts',
        'm2ts',
        'flv',
        'wmv',
      ]) {
        expect(kVideoExtensions, contains(extension));
        expect(
          EngineFile.fromJson(
            fileJson(<String, Object?>{
              'isVideo': null,
              'mime': null,
              'path': 'a.$extension',
            }),
          ).isVideo,
          isTrue,
          reason: extension,
        );
      }
    });

    test('字幕扩展名与路径解析（Windows 反斜杠）', () {
      final file = EngineFile.fromJson(
        fileJson(<String, Object?>{'path': r'Season 1\ep01.ASS'}),
      );
      expect(file.isSubtitle, isTrue);
      expect(file.directory, 'Season 1');
      expect(file.fileName, 'ep01.ASS');

      for (final extension in <String>['ass', 'srt', 'sub', 'ssa']) {
        expect(
          EngineFile.fromJson(
            fileJson(<String, Object?>{'path': 'a.$extension'}),
          ).isSubtitle,
          isTrue,
        );
      }
      expect(
        EngineFile.fromJson(
          fileJson(<String, Object?>{'path': 'noext'}),
        ).extension,
        '',
      );
      expect(
        EngineFile.fromJson(
          fileJson(<String, Object?>{'path': '.hidden'}),
        ).extension,
        '',
        reason: '点开头是隐藏文件不是扩展名',
      );
    });

    test('included 缺省视为 true', () {
      final file = EngineFile.fromJson(
        fileJson(<String, Object?>{'included': null}),
      );
      expect(file.included, isTrue);
    });

    test('copyWith 只改指定字段', () {
      final file = EngineFile.fromJson(fileJson());
      final updated = file.copyWith(downloaded: 100, complete: true);
      expect(updated.downloaded, 100);
      expect(updated.complete, isTrue);
      expect(updated.path, file.path);
      expect(updated.index, file.index);
    });
  });

  group('playableFile / 字幕', () {
    EngineTorrent torrentWith(List<Map<String, Object?>> files) =>
        EngineTorrent.fromJson(<String, dynamic>{
          'id': 1,
          'name': 't',
          'files': files,
        });

    test('多版本同捆取体积最大的视频', () {
      final torrent = torrentWith(<Map<String, Object?>>[
        <String, Object?>{
          'index': 0,
          'path': 'ep01 [720p].mkv',
          'length': 100,
          'isVideo': true,
          'mime': 'video/x-matroska',
        },
        <String, Object?>{
          'index': 1,
          'path': 'ep01 [1080p].mkv',
          'length': 900,
          'isVideo': true,
          'mime': 'video/x-matroska',
        },
        <String, Object?>{
          'index': 2,
          'path': 'cover.jpg',
          'length': 5000,
          'isVideo': false,
          'mime': 'image/jpeg',
        },
      ]);
      expect(torrent.playableFile!.index, 1);
    });

    test('没有视频文件时返回 null（不猜图片/压缩包）', () {
      final torrent = torrentWith(<Map<String, Object?>>[
        <String, Object?>{
          'index': 0,
          'path': 'readme.txt',
          'length': 10,
          'isVideo': false,
        },
      ]);
      expect(torrent.playableFile, isNull);
      expect(torrent.downloadedSubtitleFiles, hasLength(0));
    });

    test('字幕只取与主视频同目录的', () {
      final torrent = torrentWith(<Map<String, Object?>>[
        <String, Object?>{
          'index': 0,
          'path': 'S1/ep01.mkv',
          'length': 900,
          'isVideo': true,
        },
        <String, Object?>{'index': 1, 'path': 'S1/ep01.ass', 'length': 10},
        <String, Object?>{'index': 2, 'path': 'S1/ep01.srt', 'length': 10},
        <String, Object?>{'index': 3, 'path': 'S2/ep02.ass', 'length': 10},
        <String, Object?>{'index': 4, 'path': 'cover.jpg', 'length': 10},
      ]);
      expect(torrent.downloadedSubtitleFiles.map((f) => f.index), <int>[1, 2]);
      expect(torrent.subtitleFiles.map((f) => f.index), <int>[
        1,
        2,
      ], reason: '别名一致');
    });

    test('没有主视频时退化为全部字幕', () {
      final torrent = torrentWith(<Map<String, Object?>>[
        <String, Object?>{'index': 0, 'path': 'S1/a.ass', 'length': 10},
        <String, Object?>{'index': 1, 'path': 'S2/b.srt', 'length': 10},
      ]);
      expect(torrent.downloadedSubtitleFiles.map((f) => f.index), <int>[0, 1]);
    });

    test('allIncludedComplete 只看 included 的文件', () {
      final torrent = torrentWith(<Map<String, Object?>>[
        <String, Object?>{
          'index': 0,
          'path': 'a.mkv',
          'length': 1,
          'complete': true,
        },
        <String, Object?>{
          'index': 1,
          'path': 'b.mkv',
          'length': 1,
          'complete': false,
        },
        <String, Object?>{
          'index': 2,
          'path': 'c.mkv',
          'length': 1,
          'complete': false,
          'included': false,
        },
      ]);
      expect(torrent.allIncludedComplete, isFalse);
      final onlyIncluded = torrentWith(<Map<String, Object?>>[
        <String, Object?>{
          'index': 0,
          'path': 'a.mkv',
          'length': 1,
          'complete': true,
        },
        <String, Object?>{
          'index': 1,
          'path': 'b.mkv',
          'length': 1,
          'complete': false,
          'included': false,
        },
      ]);
      expect(onlyIncluded.allIncludedComplete, isTrue);
    });
  });

  group('applyProgress 合并 SSE 增量', () {
    final torrent = EngineTorrent.fromJson(torrentJson());

    test('按索引合并字节数/完成态', () {
      final merged = torrent.applyProgress(
        EngineProgress.fromJson(<String, dynamic>{
          'id': 3,
          'progressBytes': 500000,
          'totalBytes': 1000000,
          'downloadBps': 10,
          'uploadBps': 1,
          'peers': 20,
          'finished': false,
          'files': <Map<String, Object?>>[
            <String, Object?>{
              'index': 0,
              'downloaded': 500000,
              'complete': false,
              'progress': 0.55,
            },
            <String, Object?>{
              'index': 1,
              'downloaded': 100000,
              'complete': true,
              'progress': 1.0,
            },
          ],
          'completedFiles': <int>[1],
        }),
      );
      expect(merged.progressBytes, 500000);
      expect(merged.progress, 0.5, reason: 'progress 事件不带总进度，按字节换算');
      expect(merged.peers, 20);
      expect(merged.files[0].downloaded, 500000);
      expect(merged.files[0].progress, 0.55);
      expect(merged.files[0].path, 'Anime - 01.mkv', reason: '静态字段保留');
      expect(merged.files[1].complete, isTrue);
    });

    test('id 不匹配时原样返回', () {
      final merged = torrent.applyProgress(
        EngineProgress.fromJson(<String, dynamic>{
          'id': 99,
          'progressBytes': 1,
        }),
      );
      expect(identical(merged, torrent), isTrue);
    });

    test('本地没有的索引被忽略（不会造出缺 path 的假文件）', () {
      final merged = torrent.applyProgress(
        EngineProgress.fromJson(<String, dynamic>{
          'id': 3,
          'files': <Map<String, Object?>>[
            <String, Object?>{'index': 42, 'downloaded': 1, 'complete': true},
          ],
        }),
      );
      expect(merged.files, hasLength(2));
      expect(merged.files.map((f) => f.index), <int>[0, 1]);
    });

    test('事件 totalBytes=0 时保留本地总字节数', () {
      final merged = torrent.applyProgress(
        EngineProgress.fromJson(<String, dynamic>{
          'id': 3,
          'progressBytes': 100,
        }),
      );
      expect(merged.totalBytes, 1000000);
      expect(merged.progress, closeTo(0.0001, 1e-9));
    });
  });

  group('EngineProgress / completedFiles', () {
    test('completedFiles 兼容数字与字符串', () {
      final progress = EngineProgress.fromJson(<String, dynamic>{
        'id': 1,
        'completedFiles': <Object?>[0, '2', 3.0, null, 'x'],
      });
      expect(progress.completedFiles, <int>{0, 2, 3});
    });

    test('completedFiles 缺省为空集合', () {
      final progress = EngineProgress.fromJson(<String, dynamic>{'id': 1});
      expect(progress.completedFiles, isEmpty);
      expect(progress.files, isEmpty);
      expect(progress.finished, isFalse);
    });

    test('事件名与 spec 一致', () {
      expect(EngineSnapshot(const []).name, 'snapshot');
      expect(
        EngineTorrentAdded(
          EngineTorrent.fromJson(const <String, dynamic>{}),
        ).name,
        'torrent_added',
      );
      expect(
        EngineProgress.fromJson(const <String, dynamic>{'id': 1}).name,
        'progress',
      );
      expect(
        EngineStateChanged.fromJson(const <String, dynamic>{'id': 1}).name,
        'state',
      );
      expect(const EngineTorrentRemoved(1).name, 'torrent_removed');
      expect(const EngineHeartbeat().name, 'heartbeat');
    });
  });

  group('EngineHealth', () {
    test('完整字段', () {
      final health = EngineHealth.fromJson(<String, dynamic>{
        'ok': true,
        'version': '0.1.0',
        'sessions': 2,
      });
      expect(health.ok, isTrue);
      expect(health.version, '0.1.0');
      expect(health.sessions, 2);
    });

    test('缺字段容错：ok 缺省视为 true（HTTP 200 本身即可用信号）', () {
      final health = EngineHealth.fromJson(<String, dynamic>{});
      expect(health.ok, isTrue);
      expect(health.version, isNull);
      expect(health.sessions, 0);
    });

    test('ok=false 明确可用', () {
      expect(EngineHealth.fromJson(<String, dynamic>{'ok': false}).ok, isFalse);
      expect(EngineHealth.fromJson(<String, dynamic>{'ok': 0}).ok, isFalse);
    });
  });

  group('EngineAddResult（§3.5 三形态）', () {
    test('Ready：isReady / torrent / engineId / infoHash', () {
      final torrent = EngineTorrent.fromJson(torrentJson());
      final result = EngineAddReady(torrent);
      expect(result.isReady, isTrue);
      expect(result.torrent, same(torrent));
      expect(result.engineId, 3);
      expect(result.infoHash, torrent.infoHash);
      expect(result.phase, isNull);
      expect(result.toString(), contains('EngineAddReady'));
    });

    test('Ready：id 缺失（0）时 engineId 为 null，不假装有 id', () {
      final result = EngineAddReady(
        EngineTorrent.fromJson(<String, dynamic>{}),
      );
      expect(result.engineId, isNull);
      expect(result.isReady, isTrue);
      expect(result.infoHash, isNull, reason: 'infoHash 为空串也算缺失');
    });

    test('Resolving：没有 id，只能靠 infoHash 等 SSE', () {
      const result = EngineAddResolving(infoHash: 'abc', phase: 'metadata');
      expect(result.isReady, isFalse);
      expect(result.torrent, isNull);
      expect(result.engineId, isNull);
      expect(result.infoHash, 'abc');
      expect(result.phase, 'metadata');
      expect(result.toString(), contains('abc'));
    });

    test('TimedOut：phase=initializing 带 id 时 engineId 可用', () {
      const withId = EngineAddTimedOut(
        infoHash: 'abc',
        phase: 'initializing',
        id: 12,
        metadataTimeoutMs: 30000,
      );
      expect(withId.isReady, isFalse);
      expect(withId.engineId, 12);
      expect(withId.metadataTimeoutMs, 30000);

      const withoutId = EngineAddTimedOut(infoHash: 'abc', phase: 'metadata');
      expect(withoutId.engineId, isNull);
      expect(withoutId.metadataTimeoutMs, isNull);
    });
  });

  group('EngineException', () {
    test('字段与谓词', () {
      final error = EngineException(
        'unauthorized',
        statusCode: 401,
        uri: Uri.parse('http://127.0.0.1:1/torrents'),
        method: 'GET',
      );
      expect(error.isUnauthorized, isTrue);
      expect(error.isNotFound, isFalse);
      expect(error.isMetadataTimeout, isFalse);
      expect(error.toString(), contains('401'));
      expect(error.toString(), contains('http://127.0.0.1:1/torrents'));

      expect(EngineException('x', statusCode: 404).isNotFound, isTrue);
      expect(
        EngineException('metadata_timeout', statusCode: 504).isMetadataTimeout,
        isTrue,
      );
      expect(
        EngineException('x', body: 'raw-body').toString(),
        contains('raw-body'),
      );
    });

    test('EngineStartException 回显 stdout/stderr 末尾行', () {
      final error = EngineStartException(
        '引擎在 30000ms 内没有就绪',
        executable: r'C:\x\rqbit-engine.exe',
        runtimeFile: r'C:\x\runtime.json',
        stdoutTail: const <String>['binding 127.0.0.1:0', 'ready'],
        stderrTail: const <String>['error: port busy'],
        exitCode: 3,
        elapsed: const Duration(seconds: 30),
        cause: 'boom',
      );
      final text = error.toString();
      expect(text, contains(r'C:\x\rqbit-engine.exe'));
      expect(text, contains('binding 127.0.0.1:0'));
      expect(text, contains('error: port busy'));
      expect(text, contains('退出码: 3'));
      expect(error, isA<EngineException>());
    });
  });
}
