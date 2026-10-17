/// 动漫库的领域层 + 端口层（第三十三轮）。
///
/// 这里钉的全部是**实测出来的接口事实**（`tool/round33_bangumi_probe*.py`），
/// 因为写错一个参数的后果不是"少几个结果"，而是 **HTTP 400 或整段筛选被静默忽略**：
/// * `filter.rating` 必须是**字符数组**（写成对象 → 400 `expected=[]string, got=object`）；
/// * 分页只能走**查询串**（body 里的 `limit`/`offset` 会被忽略）；
/// * `filter.platform` 会被忽略 ⇒ 放送形态 = 服务端 `tag` 粗筛 + **本地按 platform 精确筛**。
library;

import 'dart:convert';

import 'package:dsanima/domain/bangumi.dart';
import 'package:dsanima/domain/bangumi_library.dart';
import 'package:dsanima/state/bangumi_library.dart';
import 'package:dsanima_core/sources/kv.dart' show InMemoryKeyValueStore;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 一条条目（只给测试要看的字段）。
Map<String, Object?> _subject(int id, String title, {String? platform, double? score}) =>
    <String, Object?>{
      'id': id,
      'type': 2,
      'name': 'Name $id',
      'name_cn': title,
      'date': '2024-01-06',
      'platform': platform,
      'eps': 12,
      'rating': <String, Object?>{'score': score, 'rank': 100, 'total': 1000},
      'images': <String, Object?>{'grid': 'https://lain.bgm.tv/r/100/pic/cover/l/x/$id.jpg'},
      'tags': <Object?>[
        <String, Object?>{'name': 'TV', 'count': 10},
      ],
    };

/// 记下每一次请求（URL + 解析后的 body）。
class _Recorder {
  final List<http.Request> requests = <http.Request>[];
  final List<Map<String, Object?>> bodies = <Map<String, Object?>>[];
}

/// 假 Bangumi：按 offset 回答，记录请求。
BangumiClient _client(
  _Recorder rec, {
  required List<Map<String, Object?>> Function(Uri url) answer,
  int status = 200,
  int total = 100,
  Map<String, Object?>? errorBody,
}) =>
    BangumiClient(
      client: MockClient((http.Request request) async {
        rec.requests.add(request);
        final Map<String, Object?> body =
            request.body.isEmpty ? <String, Object?>{} : jsonDecode(request.body) as Map<String, Object?>;
        rec.bodies.add(body);
        if (status != 200) {
          return http.Response(
            jsonEncode(errorBody ?? <String, Object?>{'title': 'Bad Request', 'description': 'sort not supported'}),
            status,
            headers: <String, String>{'content-type': 'application/json; charset=utf-8'},
          );
        }
        return http.Response(
          jsonEncode(<String, Object?>{'data': answer(request.url), 'total': total, 'limit': 24, 'offset': 0}),
          200,
          headers: <String, String>{'content-type': 'application/json; charset=utf-8'},
        );
      }),
      // 测试里不要把 1.1s 的限速闸门真的等到（那是给 Bangumi 面子，不是给用例的）。
      minInterval: Duration.zero,
      retries: 0,
    );

void main() {
  group('查询模型（纯函数）', () {
    test('年份/季度 → air_date 区间（全年 = 到次年 1 月 1 日）', () {
      expect(const BangumiLibraryQuery(year: 2024).airDate, <String>['>=2024-01-01', '<2025-01-01']);
      expect(const BangumiLibraryQuery(year: 2024, quarter: 2).airDate,
          <String>['>=2024-04-01', '<2024-07-01']);
      expect(const BangumiLibraryQuery(year: 2024, quarter: 4).airDate,
          <String>['>=2024-10-01', '<2025-01-01'], reason: '10 月番跨年');
      expect(const BangumiLibraryQuery().airDate, isNull);
    });

    test('评分下限 → rating 是**字符数组**（实测写成对象直接 400）', () {
      expect(const BangumiLibraryQuery(minScore: 7).ratingFilter, <String>['>=7']);
      expect(const BangumiLibraryQuery(minScore: 7.5).ratingFilter, <String>['>=7.5']);
      expect(const BangumiLibraryQuery().ratingFilter, isNull);
    });

    test('filter：type 恒为 [2]，形态与标签一起进 tag（服务端多个标签取交集）', () {
      expect(const BangumiLibraryQuery().filter['type'], <int>[2]);
      expect(const BangumiLibraryQuery(form: BangumiLibraryForm.movie).filter['tag'],
          <String>['剧场版']);
      expect(
        const BangumiLibraryQuery(form: BangumiLibraryForm.tv, tag: '百合').filter['tag'],
        <String>['TV', '百合'],
      );
      expect(const BangumiLibraryQuery(tag: '科幻').filter['tag'], <String>['科幻']);
      // 没选的关键不许出现（省得服务端解析没用的条件）。
      final Map<String, Object?> bare = const BangumiLibraryQuery().filter;
      expect(bare.containsKey('rating'), isFalse);
      expect(bare.containsKey('air_date'), isFalse);
    });

    test('sort：有关键词按相关度（match），没有才用用户选的那档', () {
      expect(const BangumiLibraryQuery(sort: BangumiLibrarySort.score).serverSort, 'score');
      expect(
        const BangumiLibraryQuery(keyword: '芙莉莲', sort: BangumiLibrarySort.score).serverSort,
        'match',
      );
    });

    test('候选数量级：total 封顶 1000（实测宽查询一律 1000）', () {
      expect(libraryHardEnd(29598), kLibraryTotalCap);
      expect(libraryHardEnd(251), 251);
      expect(libraryHardEnd(0), 0);
    });

    test('每页条数 = 列数 × 行数（整行）：列 1..14 全都整除，写死 24 条的年代结束', () {
      // ⚠️ 第三十四轮（用户：「动漫库缺少6个才填满一页」）：一页是 24 条时，10 列下
      // 24 = 2 整行 + 4 条 → 最后一行空 6 个位置。一页只能是"列数的整数倍"。
      expect(kLibraryRows, 4);
      for (int cols = 1; cols <= 14; cols++) {
        final int size = libraryPageSize(cols);
        expect(size, cols * kLibraryRows);
        expect(size % cols, 0, reason: '$cols 列时一页必须正好整行');
      }
      expect(libraryPageSize(0), kLibraryDefaultPageSize, reason: '还不知道列数时的兜底');
      expect(24 % 10, 4, reason: '用户报的那个形状：24 条在 10 列下缺 6 个位置');
      expect(libraryPageSize(10), 40);
    });

    test('服务端一次只给 20 条（实测）⇒ 凑满一页要请求几次', () {
      expect(kLibraryServerPageCap, 20, reason: '要 24/25/30/50 都只回 20，回显也是 20');
      expect(libraryMaxFetches(20), 4, reason: '1 次拿满 + 3 次本地精确筛的余量');
      expect(libraryMaxFetches(40), 5);
      expect(libraryMaxFetches(48), 6);
      expect(libraryMaxFetches(240), 8, reason: '封顶 8 次 —— 不做"无限刷 Bangumi"');
    });

    test('description / cacheKey：筛选条件都进得去，且相等的查询 key 相同', () {
      const BangumiLibraryQuery q = BangumiLibraryQuery(
        keyword: '芙莉莲',
        year: 2024,
        quarter: 1,
        form: BangumiLibraryForm.tv,
        minScore: 8,
        tag: '百合',
      );
      expect(q.description, '「芙莉莲」 · 2024 年 1 月番 · TV · ≥8 分 · 类型「百合」');
      expect(q.isDefault, isFalse);
      expect(const BangumiLibraryQuery().description, '全部动画');
      expect(const BangumiLibraryQuery().isDefault, isTrue);
      // 值相等（筛选条每改一格都会整份换掉对象，状态控制器靠它判断"真的变了"）。
      expect(q, BangumiLibraryQuery.fromJson(q.toJson()));
      expect(q.hashCode, BangumiLibraryQuery.fromJson(q.toJson()).hashCode);
      expect(q.cacheKey, isNot(const BangumiLibraryQuery(keyword: '芙莉莲').cacheKey));
    });

    test('cacheKey 必须含标签（第四十四轮）：少了它，"只换类型"会命中上一档的页缓存', () {
      // 用户：「加入类型的筛选」。而 cacheKey 同时是**页缓存键**（`cacheKey|offset|limit`）
      // 与**在途去重键** —— 它漏掉 tag 的话：点了「异世界」会拿到上一次无标签那一页
      // （最多错 10 分钟），筛选在途改标签那次查询则根本不发。
      const BangumiLibraryQuery a = BangumiLibraryQuery(tag: '异世界');
      const BangumiLibraryQuery b = BangumiLibraryQuery(tag: '校园');
      const BangumiLibraryQuery none = BangumiLibraryQuery();
      expect(a.cacheKey, isNot(b.cacheKey));
      expect(a.cacheKey, isNot(none.cacheKey));
      expect(a.cacheKey, isNot(const BangumiLibraryQuery(form: BangumiLibraryForm.tv).cacheKey));
      // 大小写/空白不影响 == 的写法与 cacheKey 保持一致（否则同一次查询会有两个键）。
      expect(const BangumiLibraryQuery(tag: ' 异世界 ').cacheKey, a.cacheKey);
      expect(a.cacheKey, contains('t=异世界'));
    });

    test('类型清单：都是实测有内容的标签，没有重复、没有空串', () {
      // 清单本身是 `tool/round44_genre_probe.py` 本机实测挑出来的（每个 ≥176 条）。
      // 这里只钉"清单的形状"：非空、无重复、无空白、名字都不带首尾空格。
      expect(kLibraryGenreTags, isNotEmpty);
      expect(kLibraryGenreTags.toSet(), hasLength(kLibraryGenreTags.length), reason: '不许重复');
      for (final String tag in kLibraryGenreTags) {
        expect(tag.trim(), tag);
        expect(tag, isNotEmpty);
      }
      // 用户点名的三个必须在里面（原话：「比如异世界 玄幻 校园这些」）。
      expect(kLibraryGenreTags, containsAll(<String>['异世界', '玄幻', '校园']));
      // 实测只有个位数条目的两个复合标签**故意不收**（点了等于给一屏空结果）。
      expect(isLibraryGenre('奇幻冒险'), isFalse);
      expect(isLibraryGenre('悬疑推理'), isFalse);
      expect(isLibraryGenre(' 异世界 '), isTrue, reason: '两头的空白不算另一个标签');
    });

    test('放送形态的本地精确判据：platform 必须就是它', () {
      final BangumiSubject tv = BangumiSubject.fromJson(_subject(1, 'A', platform: 'TV'));
      final BangumiSubject other = BangumiSubject.fromJson(_subject(2, 'B', platform: '其他'));
      expect(BangumiLibraryForm.tv.matches(tv), isTrue);
      expect(BangumiLibraryForm.tv.matches(other), isFalse);
      expect(BangumiLibraryForm.any.matches(other), isTrue);
    });
  });

  group('端口：请求怎么发', () {
    test('分页走查询串、body 只放 keyword/sort/filter/rating 数组', () async {
      final _Recorder rec = _Recorder();
      final BangumiLibraryService port = BangumiLibraryService(
        client: _client(rec,
            total: 1,
            answer: (Uri _) => <Map<String, Object?>>[_subject(1, 'A', platform: 'TV')]),
      );

      await port.search(
        const BangumiLibraryQuery(
          keyword: '葬送的芙莉莲',
          year: 2024,
          quarter: 1,
          form: BangumiLibraryForm.tv,
          minScore: 7,
          tag: '百合',
        ),
        offset: 24,
        // 一页 48 条（12 列 × 4 行）：服务端单次封顶 20，所以这一页天然要 3 次请求。
        limit: 48,
      );

      expect(rec.requests, hasLength(1), reason: '这一局的假服务端只回 1 条 ⇒ 一次就到底');
      expect(rec.requests.single.url.queryParameters['limit'], '20', reason: '要 48 也只发 20（实测封顶）');
      final Uri url = rec.requests.single.url;
      expect(url.path, '/v0/search/subjects');
      expect(url.queryParameters['limit'], '20');
      expect(url.queryParameters['offset'], '24', reason: 'body 里放 offset 会被服务端忽略');
      expect(rec.requests.single.headers['User-Agent'], isNotEmpty, reason: 'Bangumi 要 UA');

      final Map<String, Object?> body = rec.bodies.single;
      expect(body['keyword'], '葬送的芙莉莲');
      expect(body['sort'], 'match', reason: '有关键词就按相关度');
      final Map<String, Object?> filter = (body['filter'] as Map).cast<String, Object?>();
      expect(filter['type'], <int>[2]);
      expect(filter['rating'], <String>['>=7'], reason: '必须是字符数组');
      expect(filter['air_date'], <String>['>=2024-01-01', '<2024-04-01']);
      expect(filter['tag'], <String>['TV', '百合']);
    });

    test('4xx 时把 Bangumi 自己给的理由带出来（少一次猜谜）', () async {
      final _Recorder rec = _Recorder();
      final BangumiLibraryService port = BangumiLibraryService(
        client: _client(rec, answer: (Uri _) => const <Map<String, Object?>>[], status: 400),
      );
      await expectLater(
        port.search(const BangumiLibraryQuery(sort: BangumiLibrarySort.score)),
        throwsA(
          isA<BangumiException>().having(
            (BangumiException e) => e.toString(),
            'message',
            allOf(contains('非 200'), contains('sort not supported')),
          ),
        ),
      );
    });
  });

  group('端口：放送形态的本地精确筛 + 凑页', () {
    test('服务端标签串味的条目被剔掉，不够一页就再要一页，游标跟着走', () async {
      final _Recorder rec = _Recorder();
      // 第一页：2 条 TV + 1 条「其他」（tag[TV] 实测会串味）；第二页：2 条 TV。
      final BangumiLibraryService port = BangumiLibraryService(
        client: _client(rec, answer: (Uri url) {
          final int offset = int.parse(url.queryParameters['offset'] ?? '0');
          if (offset == 0) {
            return <Map<String, Object?>>[
              _subject(1, 'A', platform: 'TV'),
              _subject(2, 'B', platform: '其他'),
              _subject(3, 'C', platform: 'TV'),
            ];
          }
          return <Map<String, Object?>>[
            _subject(4, 'D', platform: 'TV'),
            _subject(5, 'E', platform: 'TV'),
          ];
        }),
      );

      final BangumiLibraryPage page = await port.search(
        const BangumiLibraryQuery(form: BangumiLibraryForm.tv),
        offset: 0,
        limit: 4,
      );

      expect(page.items.map((BangumiSubject s) => s.id), <int>[1, 3, 4, 5],
          reason: '「其他」那条被本地剔掉，缺的一条从下一页补齐');
      expect(rec.requests, hasLength(2), reason: '第一页没凑够 → 再要一页');
      expect(rec.requests[1].url.queryParameters['offset'], '3', reason: '游标 = 上一条消费掉的条数');
      expect(page.nextOffset, 5, reason: '下一页从第 5 条开始（不是 offset + 本页条数）');
      expect(page.total, 100);
      expect(page.hasMore, isTrue);
    });

    test('一页 40 条：服务端单次只给 20（实测）⇒ 拆成两次请求，两次的 limit 都是 20', () async {
      final _Recorder rec = _Recorder();
      final BangumiLibraryService port = BangumiLibraryService(
        client: _client(rec, total: 1000, answer: (Uri url) {
          final int offset = int.parse(url.queryParameters['offset'] ?? '0');
          return <Map<String, Object?>>[
            for (int i = 0; i < 20; i++)
              _subject(offset * 100 + i, 'A${offset + i}', platform: 'TV'),
          ];
        }),
      );

      final BangumiLibraryPage page =
          await port.search(const BangumiLibraryQuery(), limit: libraryPageSize(10));

      expect(page.items, hasLength(40), reason: '10 列 × 4 行 = 40 条，一页正好 4 整行');
      expect(rec.requests, hasLength(2), reason: '40 条 = 两次 20 条（服务端封顶 20）');
      expect(rec.requests[0].url.queryParameters['limit'], '20');
      expect(rec.requests[0].url.queryParameters['offset'], '0');
      expect(rec.requests[1].url.queryParameters['limit'], '20');
      expect(rec.requests[1].url.queryParameters['offset'], '20', reason: '游标吃掉第一段的 20 条');
      expect(page.nextOffset, 40);
      expect(page.startOffset, 0);
      expect(page.hasMore, isTrue);
    });

    test('同一页查询第二次不再打网络（进程内缓存）', () async {
      final _Recorder rec = _Recorder();
      final BangumiLibraryService port = BangumiLibraryService(
        client: _client(rec,
            total: 1,
            answer: (Uri _) => <Map<String, Object?>>[_subject(1, 'A', platform: 'TV')]),
      );
      await port.search(const BangumiLibraryQuery(), limit: 4);
      await port.search(const BangumiLibraryQuery(), limit: 4);
      expect(rec.requests, hasLength(1));
    });

    test('条目详情只取一次（第二次走缓存）', () async {
      final _Recorder rec = _Recorder();
      final BangumiLibraryService port = BangumiLibraryService(
        client: BangumiClient(
          client: MockClient((http.Request request) async {
            rec.requests.add(request);
            return http.Response(
              jsonEncode(_subject(42, '芙莉莲', platform: 'TV', score: 8.5)),
              200,
              headers: <String, String>{'content-type': 'application/json; charset=utf-8'},
            );
          }),
          minInterval: Duration.zero,
          retries: 0,
        ),
      );
      final BangumiSubject first = await port.detail(42);
      final BangumiSubject second = await port.detail(42);
      expect(first.id, 42);
      expect(second.score, 8.5);
      expect(rec.requests, hasLength(1), reason: '详情不会变，第二次直接命中缓存');
      expect(rec.requests.single.url.path, '/v0/subjects/42');
    });
  });

  // ── 第三十七轮：角色 / 关联条目（详情页信息带下面那两个通栏盒子）────────────────
  group('端口：角色 + 关联条目（extras）', () {
    /// 假 Bangumi：`/characters` 与 `/subjects` 各回一段，其余路径 404。
    BangumiLibraryService port(
      _Recorder rec, {
      required String characters,
      required String related,
      bool failCharacters = false,
      bool failRelated = false,
    }) =>
        BangumiLibraryService(
          client: BangumiClient(
            client: MockClient((http.Request request) async {
              rec.requests.add(request);
              final String path = request.url.path;
              if (path.endsWith('/characters')) {
                if (failCharacters) return http.Response('{"title":"boom"}', 500);
                return http.Response(characters, 200,
                    headers: <String, String>{'content-type': 'application/json; charset=utf-8'});
              }
              if (path.endsWith('/subjects')) {
                if (failRelated) return http.Response('{"title":"boom"}', 500);
                return http.Response(related, 200,
                    headers: <String, String>{'content-type': 'application/json; charset=utf-8'});
              }
              return http.Response('{}', 404);
            }),
            minInterval: Duration.zero,
            retries: 0,
          ),
        );

    const String characters = '[{"id":1,"name":"フリーレン","relation":"主角",'
        '"images":{"large":"https://lain.bgm.tv/pic/crt/l/x/1.jpg"},'
        '"actors":[{"name":"種﨑敦美"}]}]';
    const String related = '[{"id":2,"name":"第2期","name_cn":"第二季","relation":"续集",'
        '"images":{"grid":"https://lain.bgm.tv/r/100/pic/cover/l/x/2.jpg"},"type":2}]';

    test('两条端点各打一次，解析出角色与关联条目', () async {
      final _Recorder rec = _Recorder();
      final BangumiSubjectExtra extra =
          await port(rec, characters: characters, related: related).extras(42);

      expect(extra.characters.single.name, 'フリーレン');
      expect(extra.characters.single.actorName, '種﨑敦美');
      expect(extra.related.single.relation, '续集');
      expect(extra.related.single.subject.displayTitle, '第二季');
      expect(
        rec.requests.map((http.Request r) => r.url.path).toList()..sort(),
        <String>['/v0/subjects/42/characters', '/v0/subjects/42/subjects'],
      );
    });

    test('第二次点开同一部：一块都不打网络（进程内缓存）', () async {
      final _Recorder rec = _Recorder();
      final BangumiLibraryService svc = port(rec, characters: characters, related: related);
      await svc.extras(42);
      await svc.extras(42);
      expect(rec.requests, hasLength(2), reason: '两次点开，一共只该有那两条请求');
    });

    test('一条挂了不影响另一条（角色块是装饰，不配让整页变错误页）', () async {
      final _Recorder rec = _Recorder();
      final BangumiSubjectExtra extra = await port(
        rec,
        characters: characters,
        related: related,
        failCharacters: true,
      ).extras(42);
      expect(extra.characters, isEmpty);
      expect(extra.related.single.relation, '续集', reason: '另一条照常给');
    });

    test('两条都回 [] ⇒ 空表（实测孤独摇滚就是），不算失败', () async {
      final _Recorder rec = _Recorder();
      final BangumiSubjectExtra extra =
          await port(rec, characters: '[]', related: '[]').extras(42);
      expect(extra.isEmpty, isTrue);
    });

    test('两条都挂了 ⇒ 抛（交给 UI 决定要不要提示），且**不落盘**缓存', () async {
      final InMemoryKeyValueStore store = InMemoryKeyValueStore();
      final _Recorder rec = _Recorder();
      final BangumiLibraryService svc = BangumiLibraryService(
        store: store,
        client: BangumiClient(
          client: MockClient((http.Request request) async {
            rec.requests.add(request);
            return http.Response('{"title":"boom"}', 500);
          }),
          minInterval: Duration.zero,
          retries: 0,
        ),
      );
      await expectLater(svc.extras(7), throwsA(isA<BangumiException>()));
      expect(store.get('dsanima.bangumi.subject.7.extra'), isNull,
          reason: '一次网络抖动不许把"这部没有角色"永久钉在盘上');
    });

    test('成功的两块会落盘：**换一个服务实例**（重开应用）也能本地读回，一块都不打网络', () async {
      final InMemoryKeyValueStore store = InMemoryKeyValueStore();
      final _Recorder rec = _Recorder();
      final BangumiLibraryService first = BangumiLibraryService(
        store: store,
        client: BangumiClient(
          client: MockClient((http.Request request) async {
            rec.requests.add(request);
            final String path = request.url.path;
            return http.Response(path.endsWith('/characters') ? characters : related, 200,
                headers: <String, String>{'content-type': 'application/json; charset=utf-8'});
          }),
          minInterval: Duration.zero,
          retries: 0,
        ),
      );
      await first.extras(42);
      expect(store.get('dsanima.bangumi.subject.42.extra'), isNotNull, reason: '成功才落盘');

      // 第二个实例 = 重开应用（进程内缓存空了），但 store 还在。
      final _Recorder rec2 = _Recorder();
      final BangumiLibraryService second = BangumiLibraryService(
        store: store,
        client: BangumiClient(
          client: MockClient((http.Request request) async {
            rec2.requests.add(request);
            return http.Response('[]', 200);
          }),
          minInterval: Duration.zero,
          retries: 0,
        ),
      );
      final BangumiSubjectExtra back = await second.extras(42);
      expect(rec2.requests, isEmpty, reason: '落盘缓存命中 ⇒ 一块都不打网络');
      expect(back.characters.single.name, 'フリーレン');
      expect(back.related.single.relation, '续集');
    });
  });

  // ── 1.1.0 M1/T7：详情落盘的保鲜期 ────────────────────────────────────────────
  //
  // 旧实现 `_readDetail` 把 `cachedAt` 读出来**从来不比较**：盘上那份永远有效，
  // 用户看到的评分/集数/名字永远是"第一次打开那天"的。现在主键结构不动，旁边加一个
  // `dsanima.bangumi.subject.<id>.fresh` 兄弟键存时间，读的时候按 3 天判过期。
  group('详情落盘保鲜期（1.1.0 M1/T7）', () {
    final DateTime now = DateTime.utc(2026, 10, 17, 20);

    InMemoryKeyValueStore storeWith({
      required DateTime cachedAt,
      DateTime? freshAt,
    }) => InMemoryKeyValueStore(<String, Object?>{
      'dsanima.bangumi.subject.7': <String, Object?>{
        'cachedAt': cachedAt.toIso8601String(),
        'subject': _subject(7, '旧名字', platform: 'TV', score: 6.5),
      },
      if (freshAt != null) 'dsanima.bangumi.subject.7.fresh': freshAt.toIso8601String(),
    });

    BangumiLibraryService svc(InMemoryKeyValueStore store, _Recorder rec) =>
        BangumiLibraryService(
          store: store,
          clock: () => now,
          client: BangumiClient(
            client: MockClient((http.Request request) async {
              rec.requests.add(request);
              return http.Response(
                jsonEncode(_subject(7, '新名字', platform: 'TV', score: 8.9)),
                200,
                headers: <String, String>{'content-type': 'application/json; charset=utf-8'},
              );
            }),
            minInterval: Duration.zero,
            retries: 0,
          ),
        );

    test('旧数据（没有 .fresh 兄弟键）：照常命中、不重拉，并补上键从今天算保鲜期', () async {
      final InMemoryKeyValueStore store = storeWith(
        cachedAt: now.subtract(const Duration(days: 400)),
      );
      final _Recorder rec = _Recorder();
      final BangumiSubject back = await svc(store, rec).detail(7);

      expect(rec.requests, isEmpty, reason: '老数据不许被一次性判过期（否则升完级每部番都重拉）');
      expect(back.displayTitle, '旧名字');
      await pumpEventQueue();
      expect(store.get('dsanima.bangumi.subject.7.fresh'), isNotNull,
          reason: '要补一个时间戳，让保鲜期从今天算起');
    });

    test('有 .fresh 且在 3 天内：命中，不打网络', () async {
      final InMemoryKeyValueStore store = storeWith(
        cachedAt: now.subtract(const Duration(days: 2)),
        freshAt: now.subtract(const Duration(days: 2)),
      );
      final _Recorder rec = _Recorder();
      final BangumiSubject back = await svc(store, rec).detail(7);

      expect(rec.requests, isEmpty);
      expect(back.displayTitle, '旧名字');
    });

    test('有 .fresh 但超过 3 天：重新拉，并把主键与兄弟键一起覆盖', () async {
      final InMemoryKeyValueStore store = storeWith(
        cachedAt: now.subtract(const Duration(days: 30)),
        freshAt: now.subtract(const Duration(days: 4)),
      );
      final _Recorder rec = _Recorder();
      final BangumiSubject back = await svc(store, rec).detail(7);

      expect(rec.requests, hasLength(1), reason: '过期要真的去拉一次');
      expect(back.displayTitle, '新名字');
      final Map<Object?, Object?> main =
          (store.get('dsanima.bangumi.subject.7')! as Map).cast<Object?, Object?>();
      expect((main['subject']! as Map<Object?, Object?>)['name_cn'], '新名字',
          reason: '主键要被新数据覆盖');
      expect(store.get('dsanima.bangumi.subject.7.fresh'), now.toIso8601String(),
          reason: '存回时间要跟着更新');
    });

    test('主键结构不变：盘上还是 {cachedAt, subject} 两个字段（回滚到旧版能读）', () async {
      final InMemoryKeyValueStore store = storeWith(
        cachedAt: now.subtract(const Duration(days: 30)),
        freshAt: now.subtract(const Duration(days: 4)),
      );
      await svc(store, _Recorder()).detail(7);
      final Map<Object?, Object?> main =
          (store.get('dsanima.bangumi.subject.7')! as Map).cast<Object?, Object?>();
      expect(main.keys.toSet(), <Object?>{'cachedAt', 'subject'},
          reason: '1.1.0 往主键里加字段 = 旧版读不懂 = 破坏回滚红线');
    });
  });
}
