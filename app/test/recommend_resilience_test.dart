/// 「今日推荐拉取失败」的回归钉（第三十一轮，用户 2026-10-15）。
///
/// 真机实测（2026-10-15，本机 curl 同一批 URL）：Bangumi `/v0/subjects` 单次耗时在
/// **0.24s ~ 35.9s** 之间剧烈抖动（`offset=15000` → 35.9s、`offset=0` → 21s，
/// 隔几分钟再打同一批 → 0.2s）。而旧实现是 **4 个窗口串行 + 任何一个窗口抛异常就整次
/// 推荐失败 + 25s 超时**，于是一踩到慢响应就变成"今日推荐拉取失败"。
///
/// 现在三件事必须成立，本文件的用例逐个钉住：
/// 1. 4 个窗口**并发**发（发车时刻仍至少隔 `minInterval`），且**单窗口失败不致命**；
/// 2. 真的全挂了要**说实话**（抛异常，不是返回空列表假装成功）；
/// 3. 抖动型失败（超时/5xx）**重试一次**，4xx（参数/权限）不重试。
///
/// 全程离线：`package:http/testing.dart` 的 MockClient，不打 Bangumi。
library;

import 'dart:convert';

import 'package:dsanima/domain/bangumi.dart';
import 'package:dsanima/state/bangumi_recommend.dart';
import 'package:dsanima_core/sources/kv.dart' show InMemoryKeyValueStore;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 全库总数（真机实测 29521；窗口位置按它算）。
const int kTotal = 29521;

/// 一页合成响应：每个窗口的条目 id 落在**只属于这个 offset** 的区间里，
/// 于是"推荐结果来自哪几个窗口"可以直接从 id 看出来。
String pageBody({required int offset, int total = kTotal, int count = 20}) =>
    jsonEncode(<String, Object?>{
      'total': total,
      'limit': count,
      'offset': offset,
      'data': <Object?>[
        for (int i = 0; i < count; i++)
          <String, Object?>{
            'id': offset + i + 1,
            // 日期错开，避免 selectRecommendations 排序时把同一窗口的挤在一起。
            'date': '19${80 + (i % 20)}-01-01',
            'name': 'item-${offset + i + 1}',
            'images': <String, Object?>{
              'grid': 'https://lain.bgm.tv/r/100/pic/cover/l/x/${offset}_$i.jpg',
            },
            'rating': <String, Object?>{'score': 7.5},
            'eps': 12,
          },
      ],
    });

int offsetOf(http.Request request) =>
    int.parse(request.url.queryParameters['offset'] ?? '0');

/// 这个 id 落在第几个窗口里（每个窗口的 id 区间是 `(offset, offset+20]`）。
int? windowOf(int id, List<int> offsets) {
  for (int i = 0; i < offsets.length; i++) {
    if (id > offsets[i] && id <= offsets[i] + 20) return i;
  }
  return null;
}

/// 客户端：把每个请求记进 [log]，行为由 [behaviour] 决定。
BangumiClient clientWith(
  Future<http.Response> Function(http.Request request, int attempt) behaviour, {
  Duration minInterval = Duration.zero,
  Duration timeout = const Duration(seconds: 2),
  int retries = 1,
}) {
  final Map<int, int> attempts = <int, int>{};
  return BangumiClient(
    minInterval: minInterval,
    timeout: timeout,
    retries: retries,
    client: MockClient((http.Request request) {
      final int n = (attempts[offsetOf(request)] ?? 0) + 1;
      attempts[offsetOf(request)] = n;
      return behaviour(request, n);
    }),
  );
}

void main() {
  group('推荐端口：4 个窗口并发 + 单窗口失败不致命', () {
    test('全部窗口成功：5 部、来自多个窗口、结果落缓存', () async {
      final InMemoryKeyValueStore store = InMemoryKeyValueStore();
      int requests = 0;
      final BangumiClient client = clientWith((http.Request request, int _) async {
        requests++;
        return http.Response(pageBody(offset: offsetOf(request)), 200,
            headers: <String, String>{'content-type': 'application/json'});
      });
      final BangumiRecommendPort port =
          BangumiRecommendPort(store: store, client: client);
      addTearDown(port.dispose);

      final List<BangumiSubject> picked = await port.recommend(seed: 20261015);

      expect(picked, hasLength(5));
      // 1 次拿 total + 最多 4 个窗口（某个窗口正好是 offset=0 时会复用第一页）。
      expect(requests, inInclusiveRange(4, 5));
      final List<int> offsets =
          recommendOffsets(seed: 20261015, total: kTotal, windows: 4, limit: 20);
      final Set<int> windows = <int>{
        for (final BangumiSubject s in picked)
          if (windowOf(s.id, offsets) case final int w) w,
      };
      expect(windows.length, greaterThanOrEqualTo(2),
          reason: '按窗口均衡抽取：5 部不能全从同一个窗口薅（否则必然挤在同一年代）');
      expect(store.putCount, 1, reason: '结果要落缓存（同一天不再打 Bangumi）');
    });

    test('其中一个窗口超时：**仍然给出 5 部**（旧实现是整次失败）', () async {
      final InMemoryKeyValueStore store = InMemoryKeyValueStore();
      final List<int> offsets =
          recommendOffsets(seed: 20261015, total: kTotal, windows: 4, limit: 20);
      final int victim = offsets.reduce((int a, int b) => a > b ? a : b);
      final BangumiClient client = clientWith((http.Request request, int _) async {
        final int offset = offsetOf(request);
        if (offset == victim) {
          // 慢到超时（真机 offset=15000 实测 35.9s，比 25s 的超时还长）。
          await Future<void>.delayed(const Duration(milliseconds: 400));
          return http.Response(pageBody(offset: offset), 200);
        }
        return http.Response(pageBody(offset: offset), 200);
      }, timeout: const Duration(milliseconds: 80), retries: 0);
      final BangumiRecommendPort port =
          BangumiRecommendPort(store: store, client: client);
      addTearDown(port.dispose);

      final List<BangumiSubject> picked = await port.recommend(seed: 20261015);
      expect(picked, hasLength(5), reason: '少一个窗口也必须出结果，不能"今天没有推荐"');
    });

    test('除首页外所有窗口都挂：抛异常说实话（不返回空列表假装成功）', () async {
      final InMemoryKeyValueStore store = InMemoryKeyValueStore();
      final BangumiClient client = clientWith((http.Request request, int _) async {
        final int offset = offsetOf(request);
        if (offset == 0) return http.Response(pageBody(offset: 0), 200);
        return http.Response('boom', 503);
      }, retries: 0);
      final BangumiRecommendPort port =
          BangumiRecommendPort(store: store, client: client);
      addTearDown(port.dispose);

      await expectLater(
        port.recommend(seed: 20261015),
        throwsA(isA<BangumiException>().having(
            (BangumiException e) => e.message, 'message', contains('全部失败'))),
      );
      expect(store.putCount, 0, reason: '失败不落缓存，下次还得再试');
    });

    test('拿 total 的那一页失败：照旧失败（没有 total 就没法把窗口摊到全年代）', () async {
      final InMemoryKeyValueStore store = InMemoryKeyValueStore();
      final BangumiClient client = clientWith((http.Request request, int _) async {
        return http.Response('boom', 503);
      }, retries: 0);
      final BangumiRecommendPort port =
          BangumiRecommendPort(store: store, client: client);
      addTearDown(port.dispose);

      await expectLater(
        port.recommend(seed: 20261015),
        throwsA(isA<BangumiException>()),
      );
    });

    test('同一 seed 第二次：走缓存，一个请求都不再发', () async {
      final InMemoryKeyValueStore store = InMemoryKeyValueStore();
      int requests = 0;
      final BangumiClient client = clientWith((http.Request request, int _) async {
        requests++;
        return http.Response(pageBody(offset: offsetOf(request)), 200);
      });
      final BangumiRecommendPort port =
          BangumiRecommendPort(store: store, client: client);
      addTearDown(port.dispose);

      final List<BangumiSubject> first = await port.recommend(seed: 20261015);
      final int after = requests;
      final List<BangumiSubject> second = await port.recommend(seed: 20261015);

      expect(second.map((BangumiSubject s) => s.id), first.map((BangumiSubject s) => s.id));
      expect(requests, after, reason: '同一天重启/重进主页不该再打 Bangumi');
    });
  });

  group('BangumiClient：超时 45s、抖动重试一次、4xx 不重试', () {
    test('默认超时放宽到 45s（实测有 35.9s 的正常慢响应，25s 会误杀）', () {
      final BangumiClient client = BangumiClient();
      addTearDown(client.dispose);
      expect(client.timeout, greaterThanOrEqualTo(const Duration(seconds: 40)));
    });

    test('5xx（抖动型）重试一次后成功', () async {
      final BangumiClient client = clientWith((http.Request request, int attempt) async {
        if (attempt == 1) return http.Response('bad gateway', 502);
        return http.Response(pageBody(offset: offsetOf(request)), 200);
      });
      addTearDown(client.dispose);

      final BangumiSubjectsPage page = await client.subjects(limit: 20, offset: 0);
      expect(page.items, hasLength(20));
    });

    test('404（参数/权限问题）不重试，异常里带状态码', () async {
      int attempts = 0;
      final BangumiClient client = clientWith((http.Request request, int _) async {
        attempts++;
        return http.Response('not found', 404);
      });
      addTearDown(client.dispose);

      await expectLater(
        client.subjects(limit: 20, offset: 0),
        throwsA(isA<BangumiException>()
            .having((BangumiException e) => e.statusCode, 'statusCode', 404)),
      );
      expect(attempts, 1, reason: '4xx 重试没意义，别浪费配额');
    });

    test('429 会重试（限流是暂时的）', () async {
      int attempts = 0;
      final BangumiClient client = clientWith((http.Request request, int attempt) async {
        attempts++;
        if (attempt == 1) return http.Response('slow down', 429);
        return http.Response(pageBody(offset: offsetOf(request)), 200);
      });
      addTearDown(client.dispose);

      await client.subjects(limit: 20, offset: 0);
      expect(attempts, 2);
    });
  });

  group('限速闸门：并发 + 开始时刻至少隔 minInterval', () {
    test('4 个并发请求：发车时刻隔开，但**响应互相不等**（总耗时≈最慢的一个）', () async {
      const Duration gap = Duration(milliseconds: 60);
      const Duration work = Duration(milliseconds: 150);
      final List<DateTime> starts = <DateTime>[];
      final List<DateTime> ends = <DateTime>[];
      final BangumiClient client = clientWith((http.Request request, int _) async {
        starts.add(DateTime.now());
        await Future<void>.delayed(work);
        ends.add(DateTime.now());
        return http.Response(pageBody(offset: offsetOf(request)), 200);
      }, minInterval: gap);

      final DateTime began = DateTime.now();
      await Future.wait(<Future<BangumiSubjectsPage>>[
        for (final int offset in <int>[0, 7000, 14000, 21000])
          client.subjects(limit: 20, offset: offset),
      ]);
      final Duration total = DateTime.now().difference(began);

      expect(starts, hasLength(4));
      // ① 发车时刻至少隔（大致）minInterval —— 别违规连打。
      for (int i = 1; i < starts.length; i++) {
        final int ms = starts[i].difference(starts[i - 1]).inMilliseconds;
        expect(ms, greaterThanOrEqualTo(gap.inMilliseconds - 15),
            reason: '第 $i 个请求与上一个只隔了 ${ms}ms（闸门失效）');
      }
      // ② 串行实现里"下一个开始"必然晚于"上一个结束"；并发实现必须有重叠。
      expect(starts[1].isBefore(ends[0]), isTrue,
          reason: '旧实现是串行 await：四个窗口的耗时是四个之和。这里要求它们重叠');
      expect(total.inMilliseconds, lessThan(work.inMilliseconds * 3),
          reason: '总耗时应该≈最慢的那个（$work），而不是四个之和（实测 ${total.inMilliseconds}ms）');
    });
  });
}
