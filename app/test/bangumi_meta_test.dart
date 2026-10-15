/// Bangumi 元数据匹配与缓存测试（spec §7.8）。
///
/// **全程离线**：用 lead 抓的真实详情 fixture（`core/test/fixtures/bangumi_subject_*.json`，
/// 带 BOM，读之前剥掉）。这些 fixture 正好也是**裸对象形状**的回归样本
/// （`/v0/subjects/{id}` 没有 `data` 包裹）。
library;

import 'dart:io';

import 'package:dsanima/domain/bangumi.dart';
import 'package:dsanima/domain/bangumi_match.dart';
import 'package:dsanima/state/bangumi_meta.dart';
import 'package:dsanima_core/sources/kv.dart' show InMemoryKeyValueStore;
import 'package:flutter_test/flutter_test.dart';

/// 真实详情 fixture（自测向量，spec §7.8 记过）。
const Map<String, int> detailFixtures = <String, int>{
  '葬送的芙莉莲': 400602,
  '药屋少女的呢喃': 420628,
  '迷宫饭': 395378,
  '胆大党': 467461,
  '青之箱': 460306,
};

/// 读 fixture 并**剥 BOM**（这些 JSON 带 `\uFEFF`，不剥 `jsonDecode` 会炸）。
String readFixture(String name) {
  final File file = File('../core/test/fixtures/$name');
  expect(file.existsSync(), isTrue, reason: '缺 fixture ${file.path}');
  return file.readAsStringSync().replaceFirst('\uFEFF', '');
}

BangumiSubject loadDetail(int id) =>
    parseBangumiSubject(readFixture('bangumi_subject_$id.json'));

/// 假客户端：只回放 fixture，不发一个字节的网络请求。
class FixtureBangumiClient extends BangumiClient {
  FixtureBangumiClient({this.detail, this.searchResults = const <BangumiSubject>[]});

  final BangumiSubject? detail;
  final List<BangumiSubject> searchResults;
  int searchCalls = 0;
  int detailCalls = 0;

  @override
  Future<List<BangumiSubject>> searchSubjects(String keyword,
      {int maxResults = 10}) async {
    searchCalls++;
    return searchResults;
  }

  @override
  Future<BangumiSubject> subject(int id) async {
    detailCalls++;
    final BangumiSubject? d = detail;
    if (d == null) throw BangumiException('没有 fixture');
    return d;
  }
}

void main() {
  group('真实详情 fixture（裸对象形状 + BOM）', () {
    test('每个自测向量的 id / 中文名 / 评分 / 标签都对得上', () {
      const Map<int, double> expectedScore = <int, double>{
        400602: 8.5,
        420628: 7.5,
        395378: 7.9,
        467461: 7.5,
        460306: 6.8,
      };
      for (final MapEntry<String, int> e in detailFixtures.entries) {
        final BangumiSubject s = loadDetail(e.value);
        expect(s.id, e.value);
        expect(s.nameCn, e.key, reason: 'fixture 的中文名应当与向量一致');
        expect(s.score, expectedScore[e.value]);
        expect(s.tags, isNotEmpty);
        expect(s.type, 2);
        // 详情接口给的是 https + /r/100/ 缩放前缀（列表接口才是 http 无前缀）
        expect(s.coverUrl, startsWith('https://lain.bgm.tv/'));
      }
    });

    test('形如 `{data:…}` 也认（三种响应形状都要能处理）', () {
      final String raw = readFixture('bangumi_subject_400602.json');
      expect(parseBangumiSubject('{"data":$raw}').id, 400602);
      expect(parseBangumiSubject('[$raw]').id, 400602);
    });
  });

  group('匹配（宁缺毋滥）', () {
    late List<BangumiSubject> all;

    setUpAll(() {
      all = <BangumiSubject>[
        for (final int id in detailFixtures.values) loadDetail(id),
      ];
    });

    test('同名（归一化后）命中，置信度 exact', () {
      final BangumiMatch? match = bestBangumiMatch('葬送的芙莉莲', all);
      expect(match, isNotNull);
      expect(match!.subject.id, 400602);
      expect(match.confidence, BangumiMatchConfidence.exact);
    });

    test('带季数/装饰后缀也能命中（包含匹配 + 校验通过）', () {
      final BangumiMatch? match = bestBangumiMatch('葬送的芙莉莲 第二季', all);
      expect(match?.subject.id, 400602);
      expect(match?.confidence, BangumiMatchConfidence.contained);
    });

    test('完全对不上 → null（不拿第一部来充数）', () {
      expect(bestBangumiMatch('去势默示录', all), isNull);
      expect(bestBangumiMatch('', all), isNull);
      expect(bestBangumiMatch(null, all), isNull);
      // 太短的名字不参与匹配（`01` / `SP` 会误命中）
      expect(bestBangumiMatch('01', all), isNull);
    });

    test('短片不能顶替正片：话数校验挡掉 1 话的「迷你动画」', () {
      const BangumiSubject short = BangumiSubject(
        id: 999,
        nameCn: '葬送的芙莉莲 迷你动画',
        name: 'Frieren mini',
        date: '2023-10-01',
        eps: 1,
        score: 7.0,
        coverUrl: 'https://lain.bgm.tv/x.jpg',
        type: 2,
      );
      final BangumiMatch? match = bestBangumiMatch(
        '葬送的芙莉莲',
        <BangumiSubject>[short, loadDetail(400602)],
        episodes: 28,
      );
      expect(match?.subject.id, 400602, reason: '正片（28 话）必须赢过 1 话短片');
      // 只给短片时宁可不匹配
      expect(bestBangumiMatch('葬送的芙莉莲', <BangumiSubject>[short], episodes: 28),
          isNull);
    });

    test('年份差太多不匹配（同名翻拍/不同季靠年份卡住）', () {
      const BangumiSubject old = BangumiSubject(
        id: 1,
        nameCn: '迷宫饭',
        date: '1998-01-01',
        eps: 24,
        score: 7.0,
        coverUrl: 'https://lain.bgm.tv/x.jpg',
        type: 2,
      );
      expect(bestBangumiMatch('迷宫饭', <BangumiSubject>[old], year: 2024), isNull);
      expect(bestBangumiMatch('迷宫饭', <BangumiSubject>[old], year: 1998), isNotNull);
    });

    test('非动画条目（type != 2）直接排除', () {
      const BangumiSubject book = BangumiSubject(
        id: 2,
        nameCn: '迷宫饭',
        date: '2024-01-01',
        eps: 14,
        score: 8.0,
        coverUrl: 'https://lain.bgm.tv/x.jpg',
        type: 1,
      );
      expect(bestBangumiMatch('迷宫饭', <BangumiSubject>[book]), isNull);
    });
  });

  group('元数据服务（缓存 + 静默降级）', () {
    test('命中后用详情补齐，并写进缓存（第二次不再打接口）', () async {
      final InMemoryKeyValueStore store = InMemoryKeyValueStore();
      final FixtureBangumiClient client = FixtureBangumiClient(
        detail: loadDetail(400602),
        searchResults: <BangumiSubject>[loadDetail(400602)],
      );
      final BangumiMetaService service =
          BangumiMetaService(store: store, client: client);

      final BangumiLookup first = await service.lookup('葬送的芙莉莲');
      expect(first.matched, isTrue);
      expect(first.subject!.id, 400602);
      expect(first.subject!.score, 8.5);
      expect(client.searchCalls, 1);
      expect(client.detailCalls, 1);

      // 换一个服务实例（模拟重启）→ 只读缓存（缓存键是归一化后的**查询名**）
      final FixtureBangumiClient cold = FixtureBangumiClient();
      final BangumiMetaService reopened =
          BangumiMetaService(store: store, client: cold);
      final BangumiLookup second = await reopened.lookup('葬送的芙莉莲');
      expect(second.subject!.id, 400602, reason: '同一个查询名走磁盘缓存');
      // 查询名带季数后缀 → 是另一条缓存键（不折叠不同季），但**匹配**仍能命中正片
      final BangumiLookup withSeason =
          await BangumiMetaService(store: store, client: client)
              .lookup('葬送的芙莉莲 第二季');
      expect(withSeason.subject!.id, 400602);
      expect(client.searchCalls, 2, reason: '不同查询名各自缓存，不互相覆盖');
    });

    test('匹配不上 → matched=false（UI 显示「未匹配到 Bangumi」）', () async {
      final BangumiMetaService service = BangumiMetaService(
        store: InMemoryKeyValueStore(),
        client: FixtureBangumiClient(
          searchResults: <BangumiSubject>[loadDetail(400602)],
        ),
      );
      final BangumiLookup lookup = await service.lookup('去势默示录');
      expect(lookup.matched, isFalse);
      expect(lookup.error, isNull);
    });

    test('接口失败 → 静默降级（不抛，error 有值）', () async {
      final BangumiMetaService service = BangumiMetaService(
        store: InMemoryKeyValueStore(),
        client: _FailingClient(),
      );
      final BangumiLookup lookup = await service.lookup('葬送的芙莉莲');
      expect(lookup.matched, isFalse);
      expect(lookup.error, isNotNull, reason: '失败要能观测，但绝不抛给 UI');
    });

    test('太短的名字不发请求', () async {
      final FixtureBangumiClient client = FixtureBangumiClient();
      final BangumiMetaService service =
          BangumiMetaService(store: InMemoryKeyValueStore(), client: client);
      await service.lookup('01');
      expect(client.searchCalls, 0);
    });

    test('缓存过期（7 天）后重新查', () async {
      final InMemoryKeyValueStore store = InMemoryKeyValueStore();
      DateTime now = DateTime(2026, 10, 1);
      final FixtureBangumiClient client = FixtureBangumiClient(
        detail: loadDetail(395378),
        searchResults: <BangumiSubject>[loadDetail(395378)],
      );
      final BangumiMetaService service = BangumiMetaService(
          store: store, client: client, clock: () => now);
      await service.lookup('迷宫饭');
      expect(client.searchCalls, 1);

      now = DateTime(2026, 10, 3);
      await BangumiMetaService(store: store, client: client, clock: () => now)
          .lookup('迷宫饭');
      expect(client.searchCalls, 1, reason: '3 天内命中缓存');

      now = DateTime(2026, 10, 20);
      await BangumiMetaService(store: store, client: client, clock: () => now)
          .lookup('迷宫饭');
      expect(client.searchCalls, 2, reason: '超过 7 天要重查');
    });

    test('⚠️ 缓存记录被写坏（cachedAt 不是字符串）→ 按 miss 处理，不抛 TypeError', () async {
      // 缓存是"加速手段"，坏记录只能当没命中：旧实现 `map['cachedAt'] as String?`
      // 在字段被写成别的类型时直接抛 TypeError，而 `_readCache` 没有 try/catch ——
      // 一次磁盘上的脏数据就能把整个页面打崩。
      final InMemoryKeyValueStore store = InMemoryKeyValueStore();
      final FixtureBangumiClient client = FixtureBangumiClient(
        detail: loadDetail(395378),
        searchResults: <BangumiSubject>[loadDetail(395378)],
      );
      await BangumiMetaService(store: store, client: client).lookup('迷宫饭');
      expect(client.searchCalls, 1);

      // 把落盘的每条记录都写坏（cachedAt 变成数字）。
      for (final String key in store.keys.toList()) {
        await store.put(key, <String, Object?>{'cachedAt': 12345});
      }

      final BangumiLookup lookup =
          await BangumiMetaService(store: store, client: client).lookup('迷宫饭');
      expect(client.searchCalls, 2, reason: '坏记录当 miss：重新查一次');
      expect(lookup.error, isNull, reason: '重新查是成功的，不该报错');
    });
  });
}

class _FailingClient extends BangumiClient {
  @override
  Future<List<BangumiSubject>> searchSubjects(String keyword,
          {int maxResults = 10}) async =>
      throw BangumiException('模拟网络失败');

  @override
  Future<BangumiSubject> subject(int id) async =>
      throw BangumiException('模拟网络失败');
}
