/// 测试支撑：可注入的假时钟 / 假睡眠 / 假 HTTP 工厂。
///
/// 本文件不联网，也不做任何真实等待。
library;

import 'dart:convert';

import 'package:dsanima_core/sources/sources.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 可推进的假时钟 + 假睡眠（睡眠只推进时钟，不真实等待）。
class FakeClock {
  FakeClock(this.now);

  DateTime now;

  final List<Duration> sleeps = <Duration>[];

  DateTime call() => now;

  Future<void> sleep(Duration duration) async {
    sleeps.add(duration);
    now = now.add(duration);
  }

  void advance(Duration duration) => now = now.add(duration);
}

/// 记录调用的 HTTP 客户端工厂。
class RecordingHttpFactory implements HttpClientFactory {
  RecordingHttpFactory(this.handler);

  final Future<http.Response> Function(http.Request request) handler;

  int createCount = 0;
  bool closed = false;

  /// 最近一次请求（断言 UA / URL 用）。
  http.Request? lastRequest;
  final List<Uri> requestedUris = <Uri>[];

  @override
  http.Client create() {
    createCount++;
    return MockClient((http.Request request) {
      lastRequest = request;
      requestedUris.add(request.url);
      return handler(request);
    });
  }

  @override
  void close() => closed = true;

  @override
  String get describe => 'RecordingHttpFactory';
}

/// 固定返回一段 UTF-8 文本的工厂。
RecordingHttpFactory textFactory(
  String body, {
  int statusCode = 200,
  String contentType = 'application/xml; charset=utf-8',
  List<int>? bytes,
}) {
  return RecordingHttpFactory((http.Request request) async {
    return http.Response.bytes(
      bytes ?? utf8.encode(body),
      statusCode,
      headers: <String, String>{'content-type': contentType},
    );
  });
}

/// 按调用次序返回不同响应的工厂（用于重试测试）。
RecordingHttpFactory sequenceFactory(List<http.Response Function()> steps) {
  var index = 0;
  return RecordingHttpFactory((http.Request request) async {
    final step = steps[index < steps.length ? index : steps.length - 1];
    index++;
    return step();
  });
}

/// 构造一个用假时钟 + 假睡眠驱动的 [SourceHttp]。
SourceHttp buildHttp(
  HttpClientFactory factory, {
  FakeClock? clock,
  Duration timeout = const Duration(seconds: 20),
  RateLimiter? limiter,
}) {
  final c = clock ?? FakeClock(DateTime.utc(2026, 10, 8, 12));
  return SourceHttp(
    factory: factory,
    limiter: limiter ??
        RateLimiter(
          minInterval: Duration.zero,
          clock: c.call,
          sleep: c.sleep,
        ),
    timeout: timeout,
    sleep: c.sleep,
  );
}
