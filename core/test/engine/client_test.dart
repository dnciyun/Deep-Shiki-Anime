import 'dart:async';
import 'dart:convert';

import 'package:dsanima_core/dsanima_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 本文件**不联网、不起进程**：全部走 `package:http/testing.dart` 的 MockClient。
const Map<String, String> kJsonHeaders = <String, String>{
  'content-type': 'application/json; charset=utf-8',
};

final Uri kBaseUrl = Uri.parse('http://127.0.0.1:45871');

http.Response jsonResponse(Object body, [int statusCode = 200]) =>
    http.Response(jsonEncode(body), statusCode, headers: kJsonHeaders);

/// 记录请求并固定回同一个响应。
class _Recorder {
  final List<http.Request> requests = <http.Request>[];

  EngineClient client(
    Future<http.Response> Function(http.Request request) handler, {
    Duration requestTimeout = const Duration(seconds: 20),
    Duration connectTimeout = const Duration(seconds: 15),
    Uri? baseUrl,
    String token = 'tok',
  }) {
    final mock = MockClient((request) {
      requests.add(request);
      return handler(request);
    });
    return EngineClient(
      baseUrl: baseUrl ?? kBaseUrl,
      token: token,
      http: mock,
      requestTimeout: requestTimeout,
      connectTimeout: connectTimeout,
    );
  }
}

Map<String, dynamic> bodyOf(http.Request request) =>
    jsonDecode(request.body) as Map<String, dynamic>;

const Map<String, Object?> kTorrentViewJson = <String, Object?>{
  'id': 3,
  'infoHash': 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  'name': 'Anime 01',
  'state': 'live',
  'totalBytes': 100,
  'progressBytes': 50,
  'progress': 0.5,
  'files': <Map<String, Object?>>[
    <String, Object?>{
      'index': 0,
      'path': 'ep01.mkv',
      'length': 100,
      'downloaded': 50,
      'isVideo': true,
      'mime': 'video/x-matroska',
    },
  ],
};

void main() {
  group('health', () {
    test('GET /health 免鉴权（不带 Authorization）', () async {
      final recorder = _Recorder();
      final client = recorder.client(
        (_) async => jsonResponse(<String, Object?>{
          'ok': true,
          'version': '0.1.0',
          'sessions': 1,
        }),
      );
      final health = await client.health();
      expect(health.ok, isTrue);
      expect(health.version, '0.1.0');
      expect(health.sessions, 1);

      final request = recorder.requests.single;
      expect(request.method, 'GET');
      expect(request.url.toString(), 'http://127.0.0.1:45871/health');
      expect(request.headers.containsKey('authorization'), isFalse);
    });

    test('带路径前缀的 baseUrl 也能拼对', () async {
      final recorder = _Recorder();
      final client = recorder.client(
        (_) async => jsonResponse(<String, Object?>{'ok': true}),
        baseUrl: Uri.parse('http://127.0.0.1:45871/api/'),
      );
      await client.health();
      expect(recorder.requests.single.url.path, '/api/health');
    });
  });

  group('POST /torrents', () {
    test('addMagnet 请求体、鉴权头、URL', () async {
      final recorder = _Recorder();
      final client = recorder.client(
        (_) async => jsonResponse(kTorrentViewJson),
      );
      final result = await client.addMagnet(
        'magnet:?xt=urn:btih:abc',
        name: 'Anime 01',
        onlyFiles: <int>[0, 2],
        startPaused: true,
        subFolder: 'Anime/S01',
        metadataTimeout: const Duration(seconds: 5),
      );
      expect(result, isA<EngineAddReady>());
      expect(result.isReady, isTrue);
      expect(result.torrent!.id, 3);
      expect(result.infoHash, 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa');
      expect(result.phase, isNull);

      final request = recorder.requests.single;
      expect(request.method, 'POST');
      expect(request.url.toString(), 'http://127.0.0.1:45871/torrents');
      expect(request.headers['authorization'], 'Bearer tok');
      expect(request.headers['content-type'], contains('application/json'));
      expect(bodyOf(request), <String, Object?>{
        'magnet': 'magnet:?xt=urn:btih:abc',
        'name': 'Anime 01',
        'onlyFiles': <int>[0, 2],
        'startPaused': true,
        'subFolder': 'Anime/S01',
        'metadataTimeoutMs': 5000,
      });
    });

    test('可选参数缺省时不进请求体', () async {
      final recorder = _Recorder();
      final client = recorder.client(
        (_) async => jsonResponse(kTorrentViewJson),
      );
      await client.addMagnet('magnet:?xt=urn:btih:abc');
      final body = bodyOf(recorder.requests.single);
      expect(body.containsKey('onlyFiles'), isFalse);
      expect(body.containsKey('name'), isFalse);
      expect(body.containsKey('subFolder'), isFalse);
      expect(body.containsKey('metadataTimeoutMs'), isFalse);
      expect(body['startPaused'], isFalse);
    });

    test('空磁力链直接 ArgumentError，不发请求', () async {
      final recorder = _Recorder();
      final client = recorder.client(
        (_) async => jsonResponse(kTorrentViewJson),
      );
      expect(() => client.addMagnet('   '), throwsArgumentError);
      expect(recorder.requests, isEmpty);
    });

    test('addTorrentBytes 走 base64', () async {
      final recorder = _Recorder();
      final client = recorder.client(
        (_) async => jsonResponse(kTorrentViewJson),
      );
      await client.addTorrentBytes(<int>[1, 2, 3, 4]);
      final body = bodyOf(recorder.requests.single);
      expect(body['torrentBase64'], base64Encode(<int>[1, 2, 3, 4]));
      expect(body.containsKey('magnet'), isFalse);
    });

    test('addMagnet 默认超时远大于普通请求超时（服务端要等 120s 元数据）', () async {
      final recorder = _Recorder();
      final client = recorder.client((_) async {
        await Future<void>.delayed(const Duration(milliseconds: 120));
        return jsonResponse(kTorrentViewJson);
      }, requestTimeout: const Duration(milliseconds: 40));
      final result = await client.addMagnet('magnet:?xt=urn:btih:abc');
      expect(result.torrent!.id, 3);
      expect(
        kDefaultMetadataRequestTimeout.inSeconds,
        greaterThanOrEqualTo(130),
      );
    });

    test('metadataTimeout 覆盖请求超时', () async {
      final recorder = _Recorder();
      final client = recorder.client((_) async {
        await Future<void>.delayed(const Duration(milliseconds: 120));
        return jsonResponse(kTorrentViewJson);
      }, requestTimeout: const Duration(milliseconds: 40));
      await client.addMagnet(
        'magnet:?xt=urn:btih:abc',
        metadataTimeout: const Duration(milliseconds: 200),
      );
      expect(bodyOf(recorder.requests.single)['metadataTimeoutMs'], 200);
    });

    test(
      '504 metadata_timeout → EngineAddTimedOut（保留 infoHash，不抛异常）',
      () async {
        final client = _Recorder().client(
          (_) async => jsonResponse(<String, Object?>{
            'error': 'metadata_timeout',
            'phase': 'metadata',
            'infoHash': 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
            'metadataTimeoutMs': 120000,
          }, 504),
        );
        final result = await client.addMagnet('magnet:?xt=urn:btih:abc');
        expect(result, isA<EngineAddTimedOut>());
        expect(result.isReady, isFalse);
        expect(result.torrent, isNull, reason: '超时没有 id，不能假装可以播放');
        expect(result.infoHash, 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb');
        expect(result.phase, 'metadata');
        expect(result.engineId, isNull, reason: 'phase=metadata 时边车不带 id');
        expect(
          (result as EngineAddTimedOut).metadataTimeoutMs,
          120000,
          reason: '默认留足 120s，超时后任务仍在后台继续',
        );
        expect(result.toString(), contains('120000'));
      },
    );

    test('504 phase=initializing 带 id → engineId 可用（可直接 get(id) 轮询）', () async {
      final client = _Recorder().client(
        (_) async => jsonResponse(<String, Object?>{
          'error': 'metadata_timeout',
          'phase': 'initializing',
          'infoHash': 'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee',
          'metadataTimeoutMs': 30000,
          'id': 12,
        }, 504),
      );
      final result = await client.addMagnet('magnet:?xt=urn:btih:abc');
      expect(result, isA<EngineAddTimedOut>());
      expect(result.isReady, isFalse, reason: '还没 live，不能直接播放');
      expect(result.engineId, 12);
      expect((result as EngineAddTimedOut).id, 12);
      expect(result.toString(), contains('id: 12'));
    });

    test(
      '202 resolving → EngineAddResolving（没有 id，等 SSE torrent_added）',
      () async {
        final client = _Recorder().client(
          (_) async => jsonResponse(<String, Object?>{
            'status': 'resolving',
            'phase': 'metadata',
            'infoHash': 'cccccccccccccccccccccccccccccccccccccccc',
          }, 202),
        );
        final result = await client.addMagnet('magnet:?xt=urn:btih:abc');
        expect(result, isA<EngineAddResolving>());
        expect(result.isReady, isFalse);
        expect(result.torrent, isNull);
        expect(result.infoHash, 'cccccccccccccccccccccccccccccccccccccccc');
        expect(result.phase, 'metadata');
        expect(result.toString(), contains('EngineAddResolving'));
        expect(result.toString(), contains('cccccccc'));
      },
    );

    test('504 但不是 metadata_timeout → 仍然抛 EngineException', () async {
      final client = _Recorder().client(
        (_) async =>
            jsonResponse(<String, Object?>{'error': 'gateway_down'}, 504),
      );
      await expectLater(
        client.addMagnet('magnet:?xt=urn:btih:abc'),
        throwsA(
          isA<EngineException>()
              .having((e) => e.statusCode, 'statusCode', 504)
              .having((e) => e.message, 'message', contains('gateway_down')),
        ),
      );
    });

    test('500 仍然抛 EngineException（真失败不能伪装成解析中）', () async {
      final client = _Recorder().client(
        (_) async => jsonResponse(<String, Object?>{'error': 'boom'}, 500),
      );
      await expectLater(
        client.addMagnet('magnet:?xt=urn:btih:abc'),
        throwsA(
          isA<EngineException>().having((e) => e.statusCode, 'statusCode', 500),
        ),
      );
    });

    test('202 既没有 status=resolving 也没有 infoHash → 抛错（无法关联）', () async {
      final client = _Recorder().client(
        (_) async => jsonResponse(<String, Object?>{'status': 'whatever'}, 202),
      );
      await expectLater(
        client.addMagnet('magnet:?xt=urn:btih:abc'),
        throwsA(
          isA<EngineException>().having((e) => e.statusCode, 'statusCode', 202),
        ),
      );
    });
  });

  group('infoHash 关联（202/504 之后）', () {
    const String hash = 'dddddddddddddddddddddddddddddddddddddddd';

    test('torrentByInfoHash：404 → null（元数据还没到手）', () async {
      final client = _Recorder().client(
        (_) async => jsonResponse(<String, Object?>{'error': 'not_found'}, 404),
      );
      expect(await client.torrentByInfoHash(hash), isNull);
    });

    test('torrentByInfoHash：真失败照样抛（不吞 500）', () async {
      final client = _Recorder().client(
        (_) async => jsonResponse(<String, Object?>{'error': 'boom'}, 500),
      );
      await expectLater(
        client.torrentByInfoHash(hash),
        throwsA(
          isA<EngineException>().having((e) => e.statusCode, 'statusCode', 500),
        ),
      );
    });

    test('torrentByInfoHash：命中时返回 torrent（小写化后请求）', () async {
      final recorder = _Recorder();
      final client = recorder.client(
        (_) async => jsonResponse(kTorrentViewJson),
      );
      final torrent = await client.torrentByInfoHash(hash.toUpperCase());
      expect(torrent!.id, 3);
      expect(recorder.requests.single.url.path, '/torrents/$hash');
    });

    test('torrentByInfoHash：400 bad_id 照旧抛错（别当成「还没就绪」）', () async {
      final client = _Recorder().client(
        (_) async => jsonResponse(<String, Object?>{
          'error': 'bad_id',
          'message': '非法 id',
        }, 400),
      );
      await expectLater(
        client.torrentByInfoHash(hash),
        throwsA(
          isA<EngineException>()
              .having((e) => e.statusCode, 'statusCode', 400)
              .having((e) => e.message, 'message', contains('bad_id')),
        ),
      );
    });

    test('torrentByInfoHash：base32 infoHash 原样透传（边车两种都认）', () async {
      final recorder = _Recorder();
      final client = recorder.client(
        (_) async => jsonResponse(kTorrentViewJson),
      );
      const base32 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
      expect(await client.torrentByInfoHash(base32), isNotNull);
      expect(recorder.requests.single.url.path, '/torrents/$base32');
    });

    test('waitForTorrent：轮询到元数据就绪就返回', () async {
      var calls = 0;
      final sleeps = <Duration>[];
      final client = _Recorder().client((_) async {
        calls++;
        if (calls < 3) {
          return jsonResponse(<String, Object?>{'error': 'not_found'}, 404);
        }
        return jsonResponse(kTorrentViewJson);
      });
      final torrent = await client.waitForTorrent(
        hash,
        pollInterval: const Duration(milliseconds: 5),
        sleep: (duration) async => sleeps.add(duration),
      );
      expect(torrent.id, 3);
      expect(calls, 3);
      expect(sleeps, hasLength(2));
    });

    test('waitForTorrent：超时抛可行动错误', () async {
      final client = _Recorder().client(
        (_) async => jsonResponse(<String, Object?>{'error': 'not_found'}, 404),
      );
      await expectLater(
        client.waitForTorrent(
          hash,
          timeout: Duration.zero,
          sleep: (duration) async {},
        ),
        throwsA(
          isA<EngineException>()
              .having((e) => e.message, 'message', contains('超时'))
              .having((e) => e.message, 'message', contains(hash)),
        ),
      );
    });

    test('addedFrom 过滤既有 SSE 流（不新开连接）', () async {
      final controller = StreamController<EngineEvent>();
      final added = EngineClient.addedFrom(controller.stream);
      final seen = <EngineTorrentAdded>[];
      final done = Completer<void>();
      final subscription = added.listen(seen.add, onDone: done.complete);

      controller.add(const EngineHeartbeat());
      controller.add(
        EngineTorrentAdded(
          EngineTorrent.fromJson(<String, dynamic>{
            'id': 7,
            'infoHash': hash,
            'name': '解析完成的剧集',
          }),
        ),
      );
      await controller.close();
      await done.future;
      await subscription.cancel();

      expect(seen, hasLength(1));
      expect(seen.single.torrent.id, 7);
      expect(seen.single.torrent.infoHash, hash);
    });
  });

  group('GET /torrents', () {
    test('list 解析 {torrents:[...]}', () async {
      final recorder = _Recorder();
      final client = recorder.client(
        (_) async => jsonResponse(<String, Object?>{
          'torrents': <Map<String, Object?>>[kTorrentViewJson],
        }),
      );
      final torrents = await client.list();
      expect(torrents, hasLength(1));
      expect(torrents.single.id, 3);
      expect(torrents.single.files.single.path, 'ep01.mkv');
      expect(recorder.requests.single.method, 'GET');
      expect(recorder.requests.single.url.path, '/torrents');
      expect(recorder.requests.single.headers['authorization'], 'Bearer tok');
    });

    test('list 容忍裸数组与缺 torrents 字段', () async {
      final bare = _Recorder().client(
        (_) async => jsonResponse(<Map<String, Object?>>[kTorrentViewJson]),
      );
      expect((await bare.list()).single.id, 3);

      final empty = _Recorder().client(
        (_) async => jsonResponse(<String, Object?>{}),
      );
      expect(await empty.list(), isEmpty);
    });

    test('list 遇到非数组 JSON → EngineException（不假成功）', () async {
      final client = _Recorder().client((_) async => jsonResponse('nope'));
      await expectLater(
        client.list(),
        throwsA(
          isA<EngineException>()
              .having((e) => e.message, 'message', contains('既不是数组也不是对象'))
              .having((e) => e.statusCode, 'statusCode', 200),
        ),
      );
    });

    test('空响应体 → EngineException', () async {
      final client = _Recorder().client((_) async => http.Response('', 200));
      await expectLater(
        client.list(),
        throwsA(
          isA<EngineException>().having(
            (e) => e.message,
            'message',
            contains('空响应体'),
          ),
        ),
      );
    });

    test('get 走 /torrents/{id} 并解析 files[]', () async {
      final recorder = _Recorder();
      final client = recorder.client(
        (_) async => jsonResponse(kTorrentViewJson),
      );
      final torrent = await client.get(3);
      expect(torrent.files.single.downloaded, 50);
      expect(recorder.requests.single.url.path, '/torrents/3');
    });

    test('get 遇到非对象 JSON → EngineException', () async {
      final client = _Recorder().client((_) async => jsonResponse(<int>[1, 2]));
      await expectLater(
        client.get(3),
        throwsA(
          isA<EngineException>().having(
            (e) => e.message,
            'message',
            contains('非对象 JSON'),
          ),
        ),
      );
    });

    test('getByHash 校验 40 位 hex 并原样小写化', () async {
      final recorder = _Recorder();
      final client = recorder.client(
        (_) async => jsonResponse(kTorrentViewJson),
      );
      final hash = 'AB' * 20;
      await client.getByHash(hash);
      expect(
        recorder.requests.single.url.path,
        '/torrents/${hash.toLowerCase()}',
      );

      expect(() => client.getByHash('not-a-hash'), throwsArgumentError);
      expect(recorder.requests, hasLength(1));

      // 32 位 base32 也接受（边车 TorrentIdOrHash::parse 两种都认）。
      const base32 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
      await client.getByHash(base32);
      expect(recorder.requests[1].url.path, '/torrents/$base32');

      // 40 位但含非 hex 字符 → 依然拒绝。
      expect(() => client.getByHash('z' * 40), throwsArgumentError);
      expect(recorder.requests, hasLength(2));
    });
  });

  group('控制端点', () {
    test('pause / resume / shutdown 都是 POST', () async {
      final recorder = _Recorder();
      final client = recorder.client(
        (_) async => jsonResponse(<String, Object?>{}),
      );
      await client.pause(3);
      await client.resume(3);
      await client.shutdown();
      expect(
        recorder.requests.map((r) => '${r.method} ${r.url.path}'),
        <String>[
          'POST /torrents/3/pause',
          'POST /torrents/3/resume',
          'POST /shutdown',
        ],
      );
      expect(
        recorder.requests.every(
          (r) => r.headers['authorization'] == 'Bearer tok',
        ),
        isTrue,
      );
    });

    test('remove 带 deleteFiles 查询参数', () async {
      final recorder = _Recorder();
      final client = recorder.client((_) async => http.Response('', 204));
      await client.remove(3, deleteFiles: true);
      await client.remove(4);
      final first = recorder.requests[0];
      expect(first.method, 'DELETE');
      expect(first.url.path, '/torrents/3');
      expect(first.url.queryParameters['deleteFiles'], 'true');
      expect(recorder.requests[1].url.queryParameters['deleteFiles'], 'false');
    });

    test('setLimits 走 PATCH /limits（可选端点）', () async {
      final recorder = _Recorder();
      final client = recorder.client(
        (_) async => jsonResponse(<String, Object?>{}),
      );
      await client.setLimits(downloadBps: 1024, uploadBps: 0);
      final request = recorder.requests.single;
      expect(request.method, 'PATCH');
      expect(request.url.path, '/limits');
      expect(request.headers['authorization'], 'Bearer tok');
      expect(bodyOf(request), <String, Object?>{
        'downloadBps': 1024,
        'uploadBps': 0,
      });

      expect(() => client.setLimits(), throwsArgumentError);
      await client.setLimits(uploadBps: 2048);
      expect(bodyOf(recorder.requests[1]), <String, Object?>{
        'uploadBps': 2048,
      });
    });
  });

  group('错误映射', () {
    test('401 → EngineException(statusCode: 401) 且不回退为空对象', () async {
      final client = _Recorder().client(
        (_) async =>
            jsonResponse(<String, Object?>{'error': 'unauthorized'}, 401),
      );
      await expectLater(
        client.list(),
        throwsA(
          isA<EngineException>()
              .having((e) => e.statusCode, 'statusCode', 401)
              .having((e) => e.isUnauthorized, 'isUnauthorized', isTrue)
              .having((e) => e.message, 'message', contains('unauthorized')),
        ),
      );
    });

    test('404 → isNotFound（用于 /shutdown 回退判断）', () async {
      final client = _Recorder().client(
        (_) async => jsonResponse(<String, Object?>{'error': 'not_found'}, 404),
      );
      await expectLater(
        client.shutdown(),
        throwsA(
          isA<EngineException>().having(
            (e) => e.isNotFound,
            'isNotFound',
            isTrue,
          ),
        ),
      );
    });

    test('非 JSON 错误体也保留原文片段', () async {
      final client = _Recorder().client(
        (_) async => http.Response('<html>boom</html>', 500),
      );
      await expectLater(
        client.health(),
        throwsA(
          isA<EngineException>()
              .having((e) => e.statusCode, 'statusCode', 500)
              .having((e) => e.message, 'message', contains('boom'))
              .having((e) => e.body, 'body', contains('html')),
        ),
      );
    });

    test('超时 → EngineException（不是 TimeoutException 泄漏出去）', () async {
      final client = _Recorder().client((_) async {
        await Future<void>.delayed(const Duration(milliseconds: 200));
        return jsonResponse(<String, Object?>{'ok': true});
      }, requestTimeout: const Duration(milliseconds: 30));
      await expectLater(
        client.health(),
        throwsA(
          isA<EngineException>()
              .having((e) => e.statusCode, 'statusCode', isNull)
              .having((e) => e.message, 'message', contains('超时'))
              .having((e) => e.uri?.path, 'uri', '/health'),
        ),
      );
    });

    test('连不上（ClientException）→ EngineException', () async {
      final client = _Recorder().client(
        (_) async => throw http.ClientException('Connection refused'),
      );
      await expectLater(
        client.health(),
        throwsA(
          isA<EngineException>().having(
            (e) => e.message,
            'message',
            contains('Connection refused'),
          ),
        ),
      );
    });

    test('close() 之后调用端点 → EngineException，且幂等', () async {
      final client = _Recorder().client(
        (_) async => jsonResponse(<String, Object?>{}),
      );
      client.close();
      client.close();
      expect(client.isClosed, isTrue);
      await expectLater(client.list(), throwsA(isA<EngineException>()));
    });
  });

  group('streamUrl', () {
    test('拼出带 token 的播放 URL', () {
      final client = EngineClient(
        baseUrl: kBaseUrl,
        token: 'secret-token',
        http: MockClient((_) async => http.Response('', 200)),
      );
      final url = client.streamUrl(3, 2);
      expect(
        url.toString(),
        'http://127.0.0.1:45871/torrents/3/files/2/stream?token=secret-token',
      );
      expect(url.path, '/torrents/3/files/2/stream');
      expect(url.queryParameters['token'], 'secret-token');
    });

    test('baseUrl 带尾部斜杠 / 路径前缀时不会出现双斜杠', () {
      final trailing = EngineClient(
        baseUrl: Uri.parse('http://127.0.0.1:1/'),
        token: 't',
        http: MockClient((_) async => http.Response('', 200)),
      );
      expect(trailing.streamUrl(1, 0).path, '/torrents/1/files/0/stream');

      final prefixed = EngineClient(
        baseUrl: Uri.parse('http://127.0.0.1:1/engine'),
        token: 't',
        http: MockClient((_) async => http.Response('', 200)),
      );
      expect(
        prefixed.streamUrl(1, 0).path,
        '/engine/torrents/1/files/0/stream',
      );
    });
  });

  group('events（SSE）', () {
    test('请求头、分帧解析与断线退避重连', () async {
      final requests = <http.BaseRequest>[];
      var calls = 0;
      final sleeps = <Duration>[];
      final client = EngineClient(
        baseUrl: kBaseUrl,
        token: 'tok',
        http: MockClient.streaming((request, bodyStream) async {
          requests.add(request);
          calls++;
          final controller = StreamController<List<int>>();
          if (calls < 4) {
            // 前三次：收到一帧后连接立刻断，逼出三轮退避。
            controller.add(utf8.encode('event: heartbeat\ndata: {}\n\n'));
          } else {
            controller.add(
              utf8.encode(
                'event: snapshot\ndata: {"torrents":[{"id":1,"name":"x"}]}\n\n',
              ),
            );
          }
          unawaited(controller.close());
          return http.StreamedResponse(
            http.ByteStream(controller.stream),
            200,
            headers: const <String, String>{
              'content-type': 'text/event-stream',
            },
          );
        }),
      );

      final events = <EngineEvent>[];
      final gotSnapshot = Completer<void>();
      final subscription = client
          .events(
            sleep: (duration) async {
              sleeps.add(duration);
              await Future<void>.delayed(const Duration(milliseconds: 2));
            },
          )
          .listen((event) {
            events.add(event);
            if (event is EngineSnapshot && !gotSnapshot.isCompleted) {
              gotSnapshot.complete();
            }
          });

      await gotSnapshot.future.timeout(const Duration(seconds: 5));
      expect(sleeps, <Duration>[
        const Duration(seconds: 1),
        const Duration(seconds: 2),
        const Duration(seconds: 4),
      ]);
      await subscription.cancel();
      expect(events.whereType<EngineHeartbeat>(), hasLength(3));
      final snapshot = events.whereType<EngineSnapshot>().first;
      expect(snapshot.torrents.single.name, 'x');
      expect(calls, 4, reason: '每次断线都要重连');

      final firstRequest = requests.first;
      expect(firstRequest.method, 'GET');
      expect(firstRequest.url.toString(), 'http://127.0.0.1:45871/events');
      expect(firstRequest.headers['authorization'], 'Bearer tok');
      expect(firstRequest.headers['accept'], 'text/event-stream');
      expect(firstRequest.headers['cache-control'], 'no-cache');
    });

    test('跨 chunk 截断（含 UTF-8 半字符）与多行 data', () async {
      const name = '中文名字';
      final payload =
          'event: torrent_added\n'
          'data: {"torrent":\n'
          'data: {"id":1,"name":"$name"}}\n\n';
      final bytes = utf8.encode(payload);
      final headIndex = utf8
          .encode(payload.substring(0, payload.indexOf('中')))
          .length;
      final cuts = <List<int>>[
        bytes.sublist(0, headIndex + 1), // 切在「中」的 3 字节中间
        bytes.sublist(headIndex + 1, headIndex + 5), // 再切在换行符中间
        bytes.sublist(headIndex + 5),
      ];
      var served = 0;
      final client = EngineClient(
        baseUrl: kBaseUrl,
        token: 'tok',
        http: MockClient.streaming((request, bodyStream) async {
          served++;
          final controller = StreamController<List<int>>();
          if (served == 1) {
            for (final chunk in cuts) {
              controller.add(chunk);
            }
          } else {
            controller.add(utf8.encode('event: heartbeat\ndata: {}\n\n'));
          }
          unawaited(controller.close());
          return http.StreamedResponse(http.ByteStream(controller.stream), 200);
        }),
      );

      final events = <EngineEvent>[];
      final got = Completer<void>();
      final subscription = client
          .events(
            sleep: (duration) async =>
                Future<void>.delayed(const Duration(milliseconds: 2)),
          )
          .listen((event) {
            events.add(event);
            if (event is EngineTorrentAdded && !got.isCompleted) got.complete();
          });

      await got.future.timeout(const Duration(seconds: 5));
      await subscription.cancel();
      final added = events.whereType<EngineTorrentAdded>().single;
      expect(added.torrent.id, 1);
      expect(added.torrent.name, name, reason: '多行 data 拼接 + UTF-8 截断都要还原正确');
    });

    test('未知事件与非法 JSON 只回调上报，不打断流', () async {
      final unknown = <String>[];
      final protocolErrors = <String>[];
      var served = 0;
      final client = EngineClient(
        baseUrl: kBaseUrl,
        token: 'tok',
        http: MockClient.streaming((request, bodyStream) async {
          served++;
          final controller = StreamController<List<int>>();
          if (served == 1) {
            controller.add(utf8.encode('event: brand_new\ndata: {"a":1}\n\n'));
            controller.add(utf8.encode('event: progress\ndata: {oops\n\n'));
            controller.add(utf8.encode(': comment only\n\n'));
            controller.add(utf8.encode('event: heartbeat\ndata: {}\n\n'));
          } else {
            controller.add(utf8.encode('event: heartbeat\ndata: {}\n\n'));
          }
          unawaited(controller.close());
          return http.StreamedResponse(http.ByteStream(controller.stream), 200);
        }),
      );

      final gotHeartbeat = Completer<void>();
      final subscription = client
          .events(
            sleep: (duration) async =>
                Future<void>.delayed(const Duration(milliseconds: 2)),
            onUnknownEvent: (event, data) => unknown.add(event),
            onProtocolError: protocolErrors.add,
          )
          .listen((event) {
            if (event is EngineHeartbeat && !gotHeartbeat.isCompleted) {
              gotHeartbeat.complete();
            }
          });

      await gotHeartbeat.future.timeout(const Duration(seconds: 5));
      await subscription.cancel();
      expect(unknown, <String>['brand_new']);
      expect(protocolErrors, hasLength(1));
      expect(protocolErrors.single, contains('progress'));
    });

    test('SSE 401：上报鉴权失败并继续按退避重试', () async {
      final disconnects = <Object>[];
      final protocolErrors = <String>[];
      final sleeps = <Duration>[];
      var calls = 0;
      final client = EngineClient(
        baseUrl: kBaseUrl,
        token: 'bad',
        http: MockClient.streaming((request, bodyStream) async {
          calls++;
          if (calls == 1) {
            return http.StreamedResponse(
              http.ByteStream(
                Stream<List<int>>.value(
                  utf8.encode('{"error":"unauthorized"}'),
                ),
              ),
              401,
              headers: kJsonHeaders,
            );
          }
          final controller = StreamController<List<int>>();
          controller.add(
            utf8.encode('event: snapshot\ndata: {"torrents":[]}\n\n'),
          );
          unawaited(controller.close());
          return http.StreamedResponse(http.ByteStream(controller.stream), 200);
        }),
      );

      final gotSnapshot = Completer<void>();
      final subscription = client
          .events(
            sleep: (duration) async {
              sleeps.add(duration);
              await Future<void>.delayed(const Duration(milliseconds: 2));
            },
            onDisconnect: (error, retryIn) => disconnects.add(error),
            onProtocolError: protocolErrors.add,
          )
          .listen((event) {
            if (event is EngineSnapshot && !gotSnapshot.isCompleted) {
              gotSnapshot.complete();
            }
          });

      await gotSnapshot.future.timeout(const Duration(seconds: 5));
      await subscription.cancel();

      expect(disconnects.whereType<EngineException>().first.statusCode, 401);
      expect(protocolErrors.single, contains('鉴权失败'));
      expect(sleeps.first, const Duration(seconds: 1));
    });

    test('取消订阅后停止重连', () async {
      var calls = 0;
      final client = EngineClient(
        baseUrl: kBaseUrl,
        token: 'tok',
        http: MockClient.streaming((request, bodyStream) async {
          calls++;
          final controller = StreamController<List<int>>();
          controller.add(utf8.encode('event: heartbeat\ndata: {}\n\n'));
          unawaited(controller.close());
          return http.StreamedResponse(http.ByteStream(controller.stream), 200);
        }),
      );

      final subscription = client
          .events(
            sleep: (duration) async =>
                Future<void>.delayed(const Duration(milliseconds: 1)),
          )
          .listen((_) {});
      await Future<void>.delayed(const Duration(milliseconds: 25));
      await subscription.cancel();
      final afterCancel = calls;
      expect(afterCancel, greaterThan(0));
      await Future<void>.delayed(const Duration(milliseconds: 25));
      expect(calls, afterCancel, reason: '取消后不得继续发请求');
    });

    test('close() 后 events 流结束', () async {
      var calls = 0;
      final client = EngineClient(
        baseUrl: kBaseUrl,
        token: 'tok',
        http: MockClient.streaming((request, bodyStream) async {
          calls++;
          final controller = StreamController<List<int>>();
          controller.add(utf8.encode('event: heartbeat\ndata: {}\n\n'));
          unawaited(controller.close());
          return http.StreamedResponse(http.ByteStream(controller.stream), 200);
        }),
      );
      final done = Completer<void>();
      client
          .events(
            sleep: (duration) async =>
                Future<void>.delayed(const Duration(milliseconds: 1)),
          )
          .listen((_) {}, onDone: done.complete);
      await Future<void>.delayed(const Duration(milliseconds: 15));
      client.close();
      await done.future.timeout(const Duration(seconds: 5));
      final afterClose = calls;
      await Future<void>.delayed(const Duration(milliseconds: 15));
      expect(calls, afterClose);
    });

    test('退避只在连接健康存活过后才重置（连上就断必须继续退避）', () async {
      var calls = 0;
      final healthy = <Duration>[];
      final flapping = <Duration>[];

      Future<void> collect(
        List<Duration> sleeps,
        Duration healthyAge,
        Completer<void> done,
      ) async {
        final client = EngineClient(
          baseUrl: kBaseUrl,
          token: 'tok',
          http: MockClient.streaming((request, bodyStream) async {
            calls++;
            final controller = StreamController<List<int>>();
            controller.add(utf8.encode('event: heartbeat\ndata: {}\n\n'));
            unawaited(controller.close());
            return http.StreamedResponse(
              http.ByteStream(controller.stream),
              200,
            );
          }),
        );
        final subscription = client
            .events(
              healthyConnectionAge: healthyAge,
              sleep: (duration) async {
                sleeps.add(duration);
                if (sleeps.length >= 3 && !done.isCompleted) done.complete();
                await Future<void>.delayed(const Duration(milliseconds: 1));
              },
            )
            .listen((_) {});
        await done.future.timeout(const Duration(seconds: 5));
        await subscription.cancel();
      }

      // 默认 20s 健康阈值：连接只活了毫秒级 → 退避必须继续升级。
      await collect(flapping, const Duration(seconds: 20), Completer<void>());
      expect(flapping, <Duration>[
        const Duration(seconds: 1),
        const Duration(seconds: 2),
        const Duration(seconds: 4),
      ]);

      // 健康阈值 0：每次都算健康存活 → 每次重置回 1s。
      await collect(healthy, Duration.zero, Completer<void>());
      expect(healthy, <Duration>[
        const Duration(seconds: 1),
        const Duration(seconds: 1),
        const Duration(seconds: 1),
      ]);
      expect(calls, greaterThanOrEqualTo(6), reason: '两个阶段各至少 3 次连接');
    });

    test('引擎完全不可达时取消订阅能立刻完成（async* 会永久挂住）', () async {
      var calls = 0;
      final client = EngineClient(
        baseUrl: kBaseUrl,
        token: 'tok',
        connectTimeout: const Duration(milliseconds: 10),
        http: MockClient.streaming((request, bodyStream) async {
          calls++;
          // 永远拿不到响应头 → 这条 SSE 流永远不会 yield 任何事件。
          await Future<void>.delayed(const Duration(milliseconds: 500));
          return http.StreamedResponse(
            http.ByteStream(Stream<List<int>>.empty()),
            200,
          );
        }),
      );

      final subscription = client
          .events(
            sleep: (duration) async =>
                Future<void>.delayed(const Duration(milliseconds: 1)),
          )
          .listen((_) {});
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(calls, greaterThan(0), reason: '应该已经在重试');

      // 关键断言：取消必须立刻完成，而不是等 500ms/退避结束甚至永久挂住。
      await subscription.cancel().timeout(const Duration(seconds: 2));
      final afterCancel = calls;
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(calls, afterCancel, reason: '取消后不得继续重连');
    });

    test('建连超时也走重连（不抛给消费方）', () async {
      final disconnects = <Object>[];
      final client = EngineClient(
        baseUrl: kBaseUrl,
        token: 'tok',
        connectTimeout: const Duration(milliseconds: 20),
        http: MockClient.streaming((request, bodyStream) async {
          await Future<void>.delayed(const Duration(milliseconds: 200));
          return http.StreamedResponse(
            http.ByteStream(Stream<List<int>>.empty()),
            200,
          );
        }),
      );
      final gotDisconnect = Completer<void>();
      final subscription = client
          .events(
            sleep: (duration) async =>
                Future<void>.delayed(const Duration(milliseconds: 2)),
            onDisconnect: (error, retryIn) {
              disconnects.add(error);
              if (!gotDisconnect.isCompleted) gotDisconnect.complete();
            },
          )
          .listen((_) {});
      await gotDisconnect.future.timeout(const Duration(seconds: 5));
      await subscription.cancel();
      expect(
        disconnects.whereType<EngineException>().first.message,
        contains('建连超时'),
      );
    });
  });
}
