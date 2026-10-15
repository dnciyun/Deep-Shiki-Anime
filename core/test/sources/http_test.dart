/// HTTP 传输层单测：代理配置、SOCKS5 握手、限速、超时、退避重试、编码兜底。
///
/// 全部离线：HTTP 用 `MockClient`，SOCKS5 用内存假字节流，时钟与睡眠都是假的。
library;

import 'dart:convert';

import 'package:dsanima_core/sources/sources.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'support.dart';

/// 脚本化的双向字节流：`read(n)` 必须精确命中脚本里预置的下一段。
class FakeDuplex implements DuplexByteStream {
  FakeDuplex(this.replies);

  final List<List<int>> replies;
  final List<List<int>> writes = <List<int>>[];
  int _index = 0;

  @override
  void write(List<int> bytes) => writes.add(List<int>.of(bytes));

  @override
  Future<List<int>> read(int count) async {
    if (_index >= replies.length) {
      throw SourceException('假流脚本耗尽（还需 $count 字节）');
    }
    final chunk = replies[_index++];
    if (chunk.length != count) {
      throw StateError('脚本段长度 ${chunk.length} 与期望 $count 不符');
    }
    return chunk;
  }
}

void main() {
  group('ProxyConfig', () {
    test('findProxyString 严格照 spec §4.2 字面', () {
      expect(const ProxyConfig.none().findProxyString, 'DIRECT');
      expect(
        const ProxyConfig(mode: ProxyMode.http, host: '127.0.0.1', port: 7890)
            .findProxyString,
        'PROXY 127.0.0.1:7890',
      );
      expect(
        const ProxyConfig(
          mode: ProxyMode.http,
          host: '127.0.0.1',
          port: 7890,
          username: 'u',
          password: 'p',
        ).findProxyString,
        'PROXY u:p@127.0.0.1:7890',
      );
      expect(
        const ProxyConfig(mode: ProxyMode.socks5, host: '127.0.0.1', port: 1080)
            .findProxyString,
        'SOCKS5 127.0.0.1:1080',
      );
    });

    test('isValid / isEnabled', () {
      expect(const ProxyConfig.none().isEnabled, isFalse);
      expect(const ProxyConfig.none().isValid, isTrue);
      expect(
        const ProxyConfig(mode: ProxyMode.http, host: 'x').isValid,
        isFalse,
      );
      expect(
        const ProxyConfig(mode: ProxyMode.http, host: 'x', port: 0).isValid,
        isFalse,
      );
      expect(
        const ProxyConfig(mode: ProxyMode.http, host: 'x', port: 70000).isValid,
        isFalse,
      );
    });

    test('JSON 往返 + 值相等', () {
      const config = ProxyConfig(
        mode: ProxyMode.socks5,
        host: '10.0.0.1',
        port: 1080,
        username: 'u',
        password: 'p',
      );
      final restored = ProxyConfig.fromJson(config.toJson());
      expect(restored, config);
      expect(restored.hashCode, config.hashCode);
      expect(ProxyConfig.fromJson(<String, dynamic>{'mode': '怪东西'}).mode,
          ProxyMode.none);
    });
  });

  group('Socks5Handshake（RFC 1928 / 1929）', () {
    test('无认证：握手字节与 CONNECT 请求逐字节正确', () async {
      final stream = FakeDuplex(<List<int>>[
        <int>[0x05, 0x00], // 选择「无认证」
        <int>[0x05, 0x00, 0x00, 0x01], // CONNECT 成功，BND.ADDR 是 IPv4
        <int>[0, 0, 0, 0],
        <int>[0, 0],
      ]);
      await const Socks5Handshake(ProxyConfig.none())
          .perform(stream, 'example.invalid', 443);

      expect(stream.writes, hasLength(2));
      expect(stream.writes[0], <int>[0x05, 0x01, 0x00]);
      final connect = stream.writes[1];
      expect(connect.sublist(0, 5),
          <int>[0x05, 0x01, 0x00, 0x03, 'example.invalid'.length]);
      expect(connect.sublist(5, 5 + 'example.invalid'.length),
          utf8.encode('example.invalid'));
      expect(connect.sublist(connect.length - 2), <int>[0x01, 0xBB]); // 443
    });

    test('用户名密码认证：方法协商 + RFC1929 子协商', () async {
      final stream = FakeDuplex(<List<int>>[
        <int>[0x05, 0x02], // 代理要求用户名/密码
        <int>[0x01, 0x00], // 认证通过
        <int>[0x05, 0x00, 0x00, 0x03], // CONNECT 成功，域名寻址
        <int>[3],
        <int>[1, 2, 3],
        <int>[0x00, 0x50],
      ]);
      const config = ProxyConfig(
        mode: ProxyMode.socks5,
        host: 'p',
        port: 1080,
        username: 'alice',
        password: 's3cret',
      );
      await const Socks5Handshake(config).perform(stream, 'a.b', 80);

      expect(stream.writes[0], <int>[0x05, 0x02, 0x00, 0x02]);
      expect(stream.writes[1],
          <int>[0x01, 5, ...utf8.encode('alice'), 6, ...utf8.encode('s3cret')]);
    });

    test('代理拒绝全部认证方式 → 明确报错', () async {
      final stream = FakeDuplex(<List<int>>[
        <int>[0x05, 0xFF],
      ]);
      await expectLater(
        const Socks5Handshake(ProxyConfig.none()).perform(stream, 'a', 80),
        throwsA(isA<SourceException>().having((SourceException e) => e.message,
            'message', contains('拒绝了所有认证方式'))),
      );
    });

    test('代理要求认证但没配账号 → 明确报错', () async {
      final stream = FakeDuplex(<List<int>>[
        <int>[0x05, 0x02],
      ]);
      await expectLater(
        const Socks5Handshake(ProxyConfig.none()).perform(stream, 'a', 80),
        throwsA(isA<SourceException>().having((SourceException e) => e.message,
            'message', contains('没有填写'))),
      );
    });

    test('认证失败 → 明确报错', () async {
      final stream = FakeDuplex(<List<int>>[
        <int>[0x05, 0x02],
        <int>[0x01, 0x01],
      ]);
      const config = ProxyConfig(
          mode: ProxyMode.socks5, host: 'p', port: 1, username: 'u', password: 'bad');
      await expectLater(
        const Socks5Handshake(config).perform(stream, 'a', 80),
        throwsA(isA<SourceException>().having((SourceException e) => e.message,
            'message', contains('认证失败'))),
      );
    });

    test('CONNECT 被拒绝 → 带 SOCKS5 错误码语义', () async {
      final stream = FakeDuplex(<List<int>>[
        <int>[0x05, 0x00],
        <int>[0x05, 0x05, 0x00, 0x01],
      ]);
      await expectLater(
        const Socks5Handshake(ProxyConfig.none()).perform(stream, 'a', 80),
        throwsA(isA<SourceException>().having((SourceException e) => e.message,
            'message', contains('连接被拒绝'))),
      );
    });

    test('版本不对 / 未知地址类型 / 代理提前断开', () async {
      await expectLater(
        const Socks5Handshake(ProxyConfig.none())
            .perform(FakeDuplex(<List<int>>[<int>[0x04, 0x00]]), 'a', 80),
        throwsA(isA<SourceException>().having((SourceException e) => e.message,
            'message', contains('版本'))),
      );
      await expectLater(
        const Socks5Handshake(ProxyConfig.none()).perform(
          FakeDuplex(<List<int>>[
            <int>[0x05, 0x00],
            <int>[0x05, 0x00, 0x00, 0x09],
          ]),
          'a',
          80,
        ),
        throwsA(isA<SourceException>().having((SourceException e) => e.message,
            'message', contains('地址类型'))),
      );
      await expectLater(
        const Socks5Handshake(ProxyConfig.none())
            .perform(FakeDuplex(<List<int>>[]), 'a', 80),
        throwsA(isA<SourceException>()),
      );
    });

    test('非法目标端口 / 超长主机名', () async {
      await expectLater(
        const Socks5Handshake(ProxyConfig.none())
            .perform(FakeDuplex(<List<int>>[<int>[0x05, 0x00]]), 'a', 0),
        throwsA(isA<SourceException>().having((SourceException e) => e.message,
            'message', contains('端口非法'))),
      );
      await expectLater(
        const Socks5Handshake(ProxyConfig.none()).perform(
            FakeDuplex(<List<int>>[<int>[0x05, 0x00]]), 'x' * 300, 80),
        throwsA(isA<SourceException>().having((SourceException e) => e.message,
            'message', contains('长度非法'))),
      );
    });
  });

  group('Socks5Tunnel', () {
    test('代理配置不完整时直接报错，不尝试连接', () async {
      var connected = false;
      final tunnel = Socks5Tunnel(
        const ProxyConfig(mode: ProxyMode.socks5, host: 'x'),
        connect: (String host, int port, Duration timeout) async {
          connected = true;
          throw StateError('不该走到这里');
        },
      );
      await expectLater(
        tunnel.openConnection(Uri.parse('https://a.b/'), null, null),
        throwsA(isA<SourceException>()),
      );
      expect(connected, isFalse);
    });
  });

  group('IoHttpClientFactory', () {
    test('socks5 走 connectionFactory 而不是 findProxy（dart:io 不支持 SOCKS5）', () {
      final factory = IoHttpClientFactory(
        proxy: const ProxyConfig(
            mode: ProxyMode.socks5, host: '127.0.0.1', port: 1080),
      );
      expect(factory.describe, 'IOClient+socks5(127.0.0.1:1080)');
      // 只是构造，不发请求；create() 会装配 connectionFactory。
      final client = factory.create();
      expect(client, isNotNull);
      factory.close();
    });

    test('代理配置不完整 → create() 抛 SourceException', () {
      final factory = IoHttpClientFactory(
        proxy: const ProxyConfig(mode: ProxyMode.http, host: '127.0.0.1'),
      );
      expect(() => factory.create(), throwsA(isA<SourceException>()));
    });
  });

  group('RateLimiter（假时钟，无真实等待）', () {
    test('同 host 串行：第二个 action 必须等第一个结束', () async {
      final clock = FakeClock(DateTime.utc(2026, 1, 1));
      final limiter = RateLimiter(
        minInterval: const Duration(milliseconds: 1200),
        clock: clock.call,
        sleep: clock.sleep,
      );
      final order = <String>[];
      final first = limiter.schedule('nyaa.si', () async {
        order.add('a-start');
        await Future<void>.delayed(Duration.zero);
        order.add('a-end');
      });
      final second = limiter.schedule('nyaa.si', () async {
        order.add('b-start');
      });
      await Future.wait(<Future<void>>[first, second]);

      expect(order, <String>['a-start', 'a-end', 'b-start']);
      expect(clock.sleeps, <Duration>[const Duration(milliseconds: 1200)]);
    });

    test('最小间隔是 start-to-start', () async {
      final clock = FakeClock(DateTime.utc(2026, 1, 1));
      final limiter = RateLimiter(
        minInterval: const Duration(milliseconds: 1200),
        clock: clock.call,
        sleep: clock.sleep,
      );
      await limiter.schedule('a', () async {});
      clock.advance(const Duration(milliseconds: 500));
      await limiter.schedule('a', () async {});
      expect(clock.sleeps, <Duration>[const Duration(milliseconds: 700)]);

      clock.advance(const Duration(milliseconds: 1200));
      await limiter.schedule('a', () async {});
      expect(clock.sleeps, hasLength(1)); // 已满足间隔，不再等待
    });

    test('不同 host 互不阻塞', () async {
      final clock = FakeClock(DateTime.utc(2026, 1, 1));
      final limiter = RateLimiter(
        minInterval: const Duration(milliseconds: 1200),
        clock: clock.call,
        sleep: clock.sleep,
      );
      await limiter.schedule('nyaa.si', () async {});
      await limiter.schedule('mikanani.me', () async {});
      expect(clock.sleeps, isEmpty);
    });

    test('minInterval 可调为 0（设置页关闭限速）', () async {
      final clock = FakeClock(DateTime.utc(2026, 1, 1));
      final limiter = RateLimiter(
        minInterval: Duration.zero,
        clock: clock.call,
        sleep: clock.sleep,
      );
      await limiter.schedule('a', () async {});
      await limiter.schedule('a', () async {});
      expect(clock.sleeps, isEmpty);
      expect(limiter.minInterval, Duration.zero);
      limiter.minInterval = const Duration(seconds: 3);
      expect(limiter.minInterval, const Duration(seconds: 3));
    });
  });

  group('SourceHttp', () {
    test('固定 UA + 走注入的客户端', () async {
      final factory = textFactory('<rss version="2.0"><channel/></rss>');
      final transport = buildHttp(factory);
      await transport.fetch(Uri.parse('https://nyaa.si/?page=rss'),
          sourceId: 'nyaa');
      expect(factory.lastRequest!.headers['user-agent'],
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) DSAnima/0.1');
      expect(factory.lastRequest!.url.toString(), 'https://nyaa.si/?page=rss');
      expect(transport.requestCount, 1);
      transport.close();
      expect(factory.closed, isTrue);
    });

    test('5xx 退避重试后成功：500 → 200（退避 500ms）', () async {
      final clock = FakeClock(DateTime.utc(2026, 1, 1));
      final factory = sequenceFactory(<http.Response Function()>[
        () => http.Response('boom', 500),
        () => http.Response('<ok/>', 200),
      ]);
      final transport = buildHttp(factory, clock: clock);
      final fetched = await transport.fetch(Uri.parse('https://a.b/x'),
          sourceId: 's');
      expect(fetched.statusCode, 200);
      expect(transport.requestCount, 2);
      expect(clock.sleeps, <Duration>[const Duration(milliseconds: 500)]);
    });

    test('一直 500：共 3 次尝试（1 + 2 重试）后抛 SourceException', () async {
      final clock = FakeClock(DateTime.utc(2026, 1, 1));
      final factory = sequenceFactory(<http.Response Function()>[
        () => http.Response('boom', 500),
      ]);
      final transport = buildHttp(factory, clock: clock);
      await expectLater(
        transport.fetch(Uri.parse('https://a.b/x'), sourceId: 's'),
        throwsA(isA<SourceException>()
            .having((SourceException e) => e.statusCode, 'statusCode', 500)),
      );
      expect(transport.requestCount, 3);
      expect(clock.sleeps, <Duration>[
        const Duration(milliseconds: 500),
        const Duration(milliseconds: 1500),
      ]);
    });

    test('429 也重试', () async {
      final factory = sequenceFactory(<http.Response Function()>[
        () => http.Response('slow down', 429),
        () => http.Response('ok', 200),
      ]);
      final transport = buildHttp(factory);
      await transport.fetch(Uri.parse('https://a.b/x'), sourceId: 's');
      expect(transport.requestCount, 2);
    });

    test('404 不重试，直接抛 SourceException', () async {
      final clock = FakeClock(DateTime.utc(2026, 1, 1));
      final factory = sequenceFactory(<http.Response Function()>[
        () => http.Response('nope', 404),
      ]);
      final transport = buildHttp(factory, clock: clock);
      await expectLater(
        transport.fetch(Uri.parse('https://a.b/x'), sourceId: 's'),
        throwsA(isA<SourceException>()
            .having((SourceException e) => e.statusCode, 'statusCode', 404)
            .having((SourceException e) => e.message, 'message', contains('不可重试'))),
      );
      expect(transport.requestCount, 1);
      expect(clock.sleeps, isEmpty);
    });

    test('单请求超时（20s 可配）→ 重试 → 最终 SourceException', () async {
      final clock = FakeClock(DateTime.utc(2026, 1, 1));
      var calls = 0;
      final factory = RecordingHttpFactory((http.Request request) async {
        calls++;
        await Future<void>.delayed(const Duration(milliseconds: 60));
        return http.Response('late', 200);
      });
      final transport = buildHttp(
        factory,
        clock: clock,
        timeout: const Duration(milliseconds: 10),
      );
      await expectLater(
        transport.fetch(Uri.parse('https://a.b/x'), sourceId: 's'),
        throwsA(isA<SourceException>().having(
            (SourceException e) => e.message, 'message', contains('网络请求失败'))),
      );
      expect(calls, 3);
      expect(clock.sleeps, hasLength(2));
    });

    test('限速器对同一 host 生效（两次抓取间隔 1200ms）', () async {
      final clock = FakeClock(DateTime.utc(2026, 1, 1));
      final limiter = RateLimiter(
        minInterval: const Duration(milliseconds: 1200),
        clock: clock.call,
        sleep: clock.sleep,
      );
      final transport = buildHttp(textFactory('<rss version="2.0"><channel/></rss>'),
          clock: clock, limiter: limiter);
      await transport.fetch(Uri.parse('https://nyaa.si/a'), sourceId: 's');
      await transport.fetch(Uri.parse('https://nyaa.si/b'), sourceId: 's');
      expect(clock.sleeps, <Duration>[const Duration(milliseconds: 1200)]);
    });

    test('fetch 走 GET（重构出 _send 之后这条不能被改掉）', () async {
      final factory = textFactory('{"ok":true}',
          contentType: 'application/json; charset=utf-8');
      final transport = buildHttp(factory);
      await transport.fetch(Uri.parse('https://bangumi.moe/api/torrent/page/1'),
          sourceId: 'bangumimoe');
      expect(factory.lastRequest!.method, 'GET');
      expect(factory.lastRequest!.body, isEmpty);
      transport.close();
    });

    test('postJson：POST + application/json; charset=utf-8 + UTF-8 body', () async {
      final factory = textFactory('{"torrents":[]}',
          contentType: 'application/json; charset=utf-8');
      final transport = buildHttp(factory);
      final fetched = await transport.postJson(
        Uri.parse('https://bangumi.moe/api/torrent/search'),
        body: <String, Object?>{
          'type': 'tag',
          'tag_id': const <String>['549ef207fe682f7549f1ea90'],
          'p': 2,
        },
        sourceId: 'bangumimoe',
      );

      expect(factory.lastRequest!.method, 'POST');
      expect(factory.lastRequest!.headers['content-type'],
          'application/json; charset=utf-8');
      // UA 一样要带上（站点按 UA 挡爬虫）。
      expect(factory.lastRequest!.headers['user-agent'],
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) DSAnima/0.1');
      // 中文必须原样 UTF-8 编码：manifest 里 `body` 是解码后的字符串，
      // 拿中文关键字断言能同时盖住「编码对了」和「不是 latin1」。
      expect(factory.lastRequest!.body, contains('549ef207fe682f7549f1ea90'));
      expect(fetched.statusCode, 200);
      expect(transport.requestCount, 1);
      transport.close();
    });

    test('postJson 关键字是中文时按 UTF-8 发出去（不被 latin1 降级）', () async {
      final factory = textFactory('{"torrents":[]}',
          contentType: 'application/json; charset=utf-8');
      final transport = buildHttp(factory);
      await transport.postJson(
        Uri.parse('https://bangumi.moe/api/v2/torrent/search'),
        body: <String, Object?>{'query': '学生会'},
        sourceId: 'bangumimoe',
      );
      // `http.Request.body` 是「按 content-type 的 charset 解码后的字符串」：
      // 解回来还是「学生会」= 发出去的确实是 UTF-8 字节。
      expect(factory.lastRequest!.body, '{"query":"学生会"}');
      transport.close();
    });

    test('postJson 的 5xx 照样退避重试（走同一条流水线）', () async {
      final clock = FakeClock(DateTime.utc(2026, 1, 1));
      final factory = sequenceFactory(<http.Response Function()>[
        () => http.Response('boom', 500),
        () => http.Response('{"ok":true}', 200),
      ]);
      final transport = buildHttp(factory, clock: clock);
      await transport.postJson(
        Uri.parse('https://bangumi.moe/api/torrent/search'),
        body: <String, Object?>{'type': 'tag'},
        sourceId: 's',
      );
      expect(transport.requestCount, 2);
      expect(clock.sleeps, <Duration>[const Duration(milliseconds: 500)]);
      transport.close();
    });

    test('postJson body 不能 JSON 化 → 立刻抛，且一个请求都不发', () async {
      final factory = textFactory('{}');
      final transport = buildHttp(factory);
      await expectLater(
        transport.postJson(
          Uri.parse('https://bangumi.moe/api/torrent/search'),
          body: Object(),
          sourceId: 's',
        ),
        throwsA(isA<JsonUnsupportedObjectError>()),
      );
      expect(transport.requestCount, 0,
          reason: '编码失败是调用方的编程错误，不该被伪装成网络失败去重试');
      transport.close();
    });
  });

  group('decodeBody', () {
    test('UTF-8（含中文）', () {
      final bytes = utf8.encode('<title>葬送的芙莉莲</title>');
      final decoded = decodeBody(bytes, contentType: 'application/xml; charset=utf-8');
      expect(decoded.text, '<title>葬送的芙莉莲</title>');
      expect(decoded.encoding, 'utf-8');
      expect(decoded.usedFallback, isFalse);
    });

    test('去 UTF-8 BOM', () {
      final bytes = <int>[0xEF, 0xBB, 0xBF, ...utf8.encode('<a/>')];
      expect(decodeBody(bytes).text, '<a/>');
    });

    test('声明 latin1 → 按 latin1 解（不算降级）', () {
      final decoded =
          decodeBody(latin1.encode('caf\u00e9'), contentType: 'text/html; charset=ISO-8859-1');
      expect(decoded.text, 'café');
      expect(decoded.encoding, 'latin1');
      expect(decoded.usedFallback, isFalse);
    });

    test('声明 gbk 但字节非 UTF-8 → latin1 兜底并标记', () {
      final gbkBytes = <int>[0xD6, 0xD0, 0xCE, 0xC4]; // “中文”的 GBK 字节
      final decoded = decodeBody(gbkBytes, contentType: 'text/xml; charset=gb2312');
      expect(decoded.usedFallback, isTrue);
      expect(decoded.encoding, 'latin1(fallback)');
      expect(decoded.declaredCharset, 'gb2312');
      expect(decoded.text.length, 4);
    });

    test('无 charset 声明且非法 UTF-8 → latin1 兜底', () {
      final decoded = decodeBody(<int>[0xFF, 0xFE, 0x41]);
      expect(decoded.usedFallback, isTrue);
      expect(decoded.text, contains('A'));
    });

    test('空字节 → 空串', () {
      expect(decodeBody(const <int>[]).text, '');
    });
  });
}
