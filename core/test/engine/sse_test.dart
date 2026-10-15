import 'package:dsanima_core/dsanima_core.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SseDecoder 分帧', () {
    test('单个完整帧', () {
      final decoder = SseDecoder();
      final frames = decoder.add('event: heartbeat\ndata: {}\n\n');
      expect(frames, hasLength(1));
      expect(frames.single.event, 'heartbeat');
      expect(frames.single.data, '{}');
    });

    test('多行 data 用 \\n 连接', () {
      final decoder = SseDecoder();
      final frames = decoder.add(
        'event: progress\ndata: {"id":1,\ndata: "peers":7}\n\n',
      );
      expect(frames, hasLength(1));
      expect(frames.single.data, '{"id":1,\n"peers":7}');
    });

    test('data 冒号后无空格也合法', () {
      final decoder = SseDecoder();
      final frames = decoder.add('data:{"ok":true}\n\n');
      expect(frames.single.data, '{"ok":true}');
      expect(frames.single.event, isNull);
    });

    test('CRLF 行尾', () {
      final decoder = SseDecoder();
      final frames = decoder.add('event: heartbeat\r\ndata: {}\r\n\r\n');
      expect(frames, hasLength(1));
      expect(frames.single.event, 'heartbeat');
    });

    test('跨 chunk 截断：一行被切成两半', () {
      final decoder = SseDecoder();
      expect(decoder.add('event: hear'), isEmpty);
      expect(decoder.add('tbeat\nda'), isEmpty);
      final frames = decoder.add('ta: {}\n\n');
      expect(frames, hasLength(1));
      expect(frames.single.event, 'heartbeat');
      expect(frames.single.data, '{}');
    });

    test('跨 chunk 截断：\\r\\n 被切成两半', () {
      final decoder = SseDecoder();
      expect(decoder.add('event: heartbeat\r'), isEmpty);
      final frames = decoder.add('\ndata: {}\r\n\r\n');
      expect(frames, hasLength(1));
      expect(frames.single.event, 'heartbeat');
    });

    test('独立 \\r 行尾（下一个 chunk 才到）也能正确切行', () {
      final decoder = SseDecoder();
      expect(decoder.add('event: state\r'), isEmpty);
      expect(decoder.add('data: {"id":1}\r'), isEmpty);
      final frames = decoder.add('\r');
      expect(frames, hasLength(1));
      expect(frames.single.event, 'state');
      expect(frames.single.data, '{"id":1}');
    });

    test('多个帧在同一次 add 中吐出', () {
      final decoder = SseDecoder();
      final frames = decoder.add(
        'event: heartbeat\ndata: {}\n\n'
        'event: torrent_removed\ndata: {"id":9}\n\n',
      );
      expect(frames.map((f) => f.event), <String>[
        'heartbeat',
        'torrent_removed',
      ]);
    });

    test('注释行（: 开头）被忽略', () {
      final decoder = SseDecoder();
      final frames = decoder.add(
        ': keepalive\n\nevent: heartbeat\ndata: {}\n\n',
      );
      expect(frames, hasLength(1));
      expect(frames.single.event, 'heartbeat');
    });

    test('未知字段被忽略，不产生帧', () {
      final decoder = SseDecoder();
      final frames = decoder.add('retry: 5000\nfoo: bar\n\n');
      expect(frames, isEmpty);
    });

    test('data 为空时不派发，且重置事件名', () {
      final decoder = SseDecoder();
      expect(decoder.add('event: heartbeat\n\n'), isEmpty);
      final frames = decoder.add('data: {}\n\n');
      expect(frames, hasLength(1));
      expect(frames.single.event, isNull, reason: '空 data 那一帧必须把 event 名一起重置');
    });

    test('BOM 被剥掉', () {
      final decoder = SseDecoder();
      final frames = decoder.add('\uFEFFevent: heartbeat\ndata: {}\n\n');
      expect(frames, hasLength(1));
      expect(frames.single.event, 'heartbeat');
    });

    test('close() 冲刷没有空行收尾的最后一帧', () {
      final decoder = SseDecoder();
      expect(decoder.add('event: heartbeat\ndata: {}'), isEmpty);
      final frames = decoder.close();
      expect(frames, hasLength(1));
      expect(frames.single.event, 'heartbeat');
      expect(frames.single.data, '{}');
    });

    test('reset() 清空残留状态', () {
      final decoder = SseDecoder();
      decoder.add('event: heartbeat\ndata: {"a"');
      decoder.reset();
      final frames = decoder.add('event: state\ndata: {"id":2}\n\n');
      expect(frames, hasLength(1));
      expect(frames.single.event, 'state');
      expect(frames.single.data, '{"id":2}');
    });

    test('空 chunk 直接忽略', () {
      final decoder = SseDecoder();
      expect(decoder.add(''), isEmpty);
    });
  });

  group('EngineEventCodec 解码', () {
    EngineEvent? decode(String event, String data) =>
        EngineEventCodec.decode(SseFrame(event: event, data: data));

    test('snapshot', () {
      final event = decode(
        'snapshot',
        '{"torrents":[{"id":1,"name":"a"},{"id":2,"name":"b"}]}',
      );
      expect(event, isA<EngineSnapshot>());
      final snapshot = event! as EngineSnapshot;
      expect(snapshot.torrents.map((t) => t.id), <int>[1, 2]);
      expect(snapshot.name, 'snapshot');
    });

    test('snapshot 缺 torrents 字段 → 空快照（不崩）', () {
      final snapshot = decode('snapshot', '{}')! as EngineSnapshot;
      expect(snapshot.torrents, isEmpty);
    });

    test('torrent_added', () {
      final event = decode(
        'torrent_added',
        '{"torrent":{"id":3,"infoHash":"abc","name":"剧集","state":"live"}}',
      );
      final added = event! as EngineTorrentAdded;
      expect(added.torrent.id, 3);
      expect(added.torrent.name, '剧集');
      expect(added.torrent.state, EngineTorrentState.live);
    });

    test('torrent_added 缺 torrent 字段 → null（不崩）', () {
      expect(decode('torrent_added', '{}'), isNull);
    });

    test('progress 带 completedFiles', () {
      final event = decode(
        'progress',
        '{"id":3,"progressBytes":1,"totalBytes":2,"downloadBps":0,"uploadBps":0,'
            '"peers":7,"finished":false,'
            '"files":[{"index":0,"downloaded":0,"complete":false,"progress":0.0}],'
            '"completedFiles":[0]}',
      );
      final progress = event! as EngineProgress;
      expect(progress.id, 3);
      expect(progress.peers, 7);
      expect(progress.files.single.index, 0);
      expect(progress.completedFiles, <int>{0});
    });

    test('progress 缺 id → null（不能让 id=0 的假事件污染 UI）', () {
      expect(decode('progress', '{"progressBytes":1}'), isNull);
    });

    test('state（未知 state 归 error）', () {
      final event = decode('state', '{"id":3,"state":"weird","error":null}');
      final changed = event! as EngineStateChanged;
      expect(changed.state, EngineTorrentState.error);
      expect(changed.rawState, 'weird');
    });

    test('torrent_removed', () {
      final removed =
          decode('torrent_removed', '{"id":9}')! as EngineTorrentRemoved;
      expect(removed.id, 9);
    });

    test('heartbeat：data 为空也要吐出来（保活信号）', () {
      expect(decode('heartbeat', ''), isA<EngineHeartbeat>());
      expect(decode('heartbeat', '{}'), isA<EngineHeartbeat>());
    });

    test('未知事件名 → null（不抛、不断流）', () {
      expect(decode('something_new', '{"a":1}'), isNull);
    });

    test('没有事件名 → null', () {
      expect(decode('', '{}'), isNull);
      expect(EngineEventCodec.decode(const SseFrame(data: '{}')), isNull);
    });

    test('非法 JSON → null', () {
      expect(decode('progress', '{not json'), isNull);
      expect(decode('snapshot', 'null'), isNull);
    });

    test('字符串 id 也能解析（容错）', () {
      final removed =
          decode('torrent_removed', '{"id":"9"}')! as EngineTorrentRemoved;
      expect(removed.id, 9);
    });
  });

  group('EngineBackoff 指数退避', () {
    test('默认 1s → 30s 封顶', () {
      final backoff = EngineBackoff();
      expect(backoff.peek, const Duration(seconds: 1));
      final delays = <Duration>[
        backoff.next(),
        backoff.next(),
        backoff.next(),
        backoff.next(),
        backoff.next(),
        backoff.next(),
        backoff.next(),
      ];
      expect(delays, <Duration>[
        const Duration(seconds: 1),
        const Duration(seconds: 2),
        const Duration(seconds: 4),
        const Duration(seconds: 8),
        const Duration(seconds: 16),
        const Duration(seconds: 30),
        const Duration(seconds: 30),
      ]);
    });

    test('reset() 后重新从 initial 开始', () {
      final backoff = EngineBackoff();
      backoff.next();
      backoff.next();
      expect(backoff.peek, const Duration(seconds: 4));
      backoff.reset();
      expect(backoff.next(), const Duration(seconds: 1));
    });

    test('可自定义 initial/max/factor', () {
      final backoff = EngineBackoff(
        initial: const Duration(milliseconds: 100),
        max: const Duration(milliseconds: 500),
        factor: 3,
      );
      expect(
        <Duration>[backoff.next(), backoff.next(), backoff.next()],
        <Duration>[
          const Duration(milliseconds: 100),
          const Duration(milliseconds: 300),
          const Duration(milliseconds: 500),
        ],
      );
    });
  });
}
