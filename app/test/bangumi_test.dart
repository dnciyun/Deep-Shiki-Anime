/// Bangumi 客户端与「全年代随机」选择器测试（spec §7.7）。
///
/// **全程离线**：用 lead 抓的真实响应 fixture（`core/test/fixtures/bangumi_subjects_*.json`），
/// 不联网、不打 Bangumi。
library;

import 'dart:convert';
import 'dart:io';

import 'package:dsanima/domain/bangumi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 实测过的 4 个真实 offset 的响应（`/v0/subjects?type=2&limit=20&offset=N`）。
const List<int> fixtureOffsets = <int>[0, 5000, 15000, 28000];

String fixturePath(int offset) =>
    '../core/test/fixtures/bangumi_subjects_$offset.json';

BangumiSubjectsPage loadPage(int offset) {
  final File file = File(fixturePath(offset));
  expect(file.existsSync(), isTrue, reason: '缺 fixture ${file.path}');
  return parseBangumiSubjectsPage(file.readAsStringSync());
}

List<List<BangumiSubject>> loadWindows() =>
    <List<BangumiSubject>>[for (final int o in fixtureOffsets) loadPage(o).items];

void main() {
  group('真实响应解析', () {
    test('分页字段与条目字段逐项对得上（total=29521、limit=20）', () {
      final BangumiSubjectsPage page = loadPage(0);
      expect(page.total, greaterThan(20000),
          reason: 'Bangumi 动画库共两万多部（实测 29521）');
      expect(page.limit, 20);
      expect(page.offset, 0);
      expect(page.items, hasLength(20));

      final BangumiSubject first = page.items.first;
      expect(first.id, greaterThan(0));
      expect(first.displayTitle, isNotEmpty);
      expect(first.coverUrl, isNotNull);
      expect(first.coverUrl, startsWith('https://lain.bgm.tv/'));
      expect(first.tags, isNotEmpty);
    });

    test('单个 offset 窗口「年代很窄」（这正是必须多窗口均衡的原因）', () {
      final List<int> years = <int>[
        for (final BangumiSubject s in loadPage(0).items)
          if (s.year != null) s.year!,
      ];
      expect(years, isNotEmpty);
      final int span = years.reduce((int a, int b) => a > b ? a : b) -
          years.reduce((int a, int b) => a < b ? a : b);
      expect(span, lessThanOrEqualTo(40),
          reason: 'offset 切片按 id 排序，单窗口只覆盖很窄的一段历史（实测 1979~2008）');
    });

    test('残缺项真的存在：窗口里混着缺 date / 缺评分 / 缺封面的条目', () {
      int missingDate = 0;
      int missingScoreOrCover = 0;
      for (final int offset in <int>[15000, 28000]) {
        for (final BangumiSubject s in loadPage(offset).items) {
          if (s.airDateLabel.isEmpty) missingDate++;
          if (s.score == null || (s.coverUrl ?? '').isEmpty) {
            missingScoreOrCover++;
          }
        }
      }
      expect(missingDate, greaterThan(0),
          reason: '实测 15000/28000 两个窗口里有缺 date 的条目，过滤器必须挡掉');
      expect(missingScoreOrCover, greaterThan(0));
    });

    test('name_cn 可能是空串 → displayTitle 回落到原名（不显示空白）', () {
      const BangumiSubject s = BangumiSubject(
        id: 1,
        name: 'Kanon',
        nameCn: '',
      );
      expect(s.displayTitle, 'Kanon');
      expect(s.alternateTitle, isNull, reason: '原名与展示名相同就不重复显示');
      const BangumiSubject cn = BangumiSubject(id: 2, name: 'Frieren', nameCn: '葬送的芙莉莲');
      expect(cn.displayTitle, '葬送的芙莉莲');
      expect(cn.alternateTitle, 'Frieren');
    });

    test('不是 JSON / 结构不认识 → BangumiException（不静默返回空）', () {
      expect(() => parseBangumiSubjectsPage('<html>500</html>'),
          throwsA(isA<BangumiException>()));
      expect(() => parseBangumiSubjectsPage('{"foo":1}'),
          isNot(throwsA(isA<BangumiException>())),
          reason: '对象里没有 data 就当空页，不算错误');
      expect(parseBangumiSubjectsPage('{"foo":1}').items, isEmpty);
    });

    test('详情端点返回的是条目对象本身（live 探针实测，没有 data 包层）', () {
      // 形状取自实测：GET /v0/subjects/37254
      const String body = '{"id":37254,"name":"宇宙骑士BLADE II","name_cn":"",'
          '"date":"1994-07-21","eps":3,"platform":"OVA",'
          '"images":{"grid":"https://lain.bgm.tv/r/100/pic/cover/l/x.jpg"},'
          '"rating":{"score":5.2,"rank":3000,"total":100},'
          '"tags":[{"name":"OVA","count":60}],"type":2}';
      final BangumiSubject s = parseBangumiSubject(body);
      expect(s.id, 37254);
      expect(s.displayTitle, '宇宙骑士BLADE II', reason: 'name_cn 为空串要回落原名');
      expect(s.date, '1994-07-21');
      expect(s.score, 5.2);
      expect(s.eps, 3);
      expect(s.tags, <String>['OVA']);

      // 也兼容 {data:{…}} 与裸数组两种包裹
      expect(parseBangumiSubject('{"data":$body}').id, 37254);
      expect(parseBangumiSubject('[$body]').id, 37254);
      expect(() => parseBangumiSubject('{"foo":1}'),
          throwsA(isA<BangumiException>()));
    });
  });

  group('推荐选择器（防年代聚簇）', () {
    test('4 个窗口均衡抽 5 部：条目不来自同一个窗口', () {
      final List<List<BangumiSubject>> windows = loadWindows();
      final List<BangumiSubject> picked =
          selectRecommendations(windows, seed: 20261009, want: 5, perWindow: 2);

      expect(picked, hasLength(5));
      expect(picked.map((BangumiSubject s) => s.id).toSet(), hasLength(5),
          reason: '不能有重复条目');
      for (final BangumiSubject s in picked) {
        expect(s.isComplete, isTrue, reason: '残缺项（缺 date / 无评分 / 无封面）必须被过滤');
      }
      expect(distinctWindowCount(picked, windows), greaterThanOrEqualTo(3),
          reason: '5 部里至少来自 3 个不同窗口，否则就是「某一年代专题」');
    });

    test('抽出的条目跨年代（比单窗口宽）', () {
      final List<List<BangumiSubject>> windows = loadWindows();
      final List<BangumiSubject> picked =
          selectRecommendations(windows, seed: 7, want: 5, perWindow: 2);
      final List<int> years = <int>[
        for (final BangumiSubject s in picked) s.year!,
      ];
      final int span =
          years.reduce((int a, int b) => a > b ? a : b) -
              years.reduce((int a, int b) => a < b ? a : b);
      expect(span, greaterThan(10), reason: '全年代随机：跨年代组合，不是同一年扎堆');
    });

    test('同一种子结果稳定；换种子会变', () {
      final List<List<BangumiSubject>> windows = loadWindows();
      List<int> ids(int seed) => selectRecommendations(windows,
              seed: seed, want: 5, perWindow: 2)
          .map((BangumiSubject s) => s.id)
          .toList();

      expect(ids(20261009), ids(20261009), reason: '当天内必须稳定（同一批次不跳）');
      final List<int> base = ids(20261009);
      bool anyDifferent = false;
      for (int seed = 1; seed <= 20; seed++) {
        if (ids(seed).toString() != base.toString()) anyDifferent = true;
      }
      expect(anyDifferent, isTrue, reason: '「换一批」必须真的换得动');
    });

    test('候选不足 5 部时不报错，返回能拿到的全部', () {
      final List<BangumiSubject> one = <BangumiSubject>[
        const BangumiSubject(
          id: 1,
          name: 'A',
          nameCn: '甲',
          date: '2001-01-01',
          score: 7.5,
          coverUrl: 'https://lain.bgm.tv/x.jpg',
        ),
      ];
      final List<BangumiSubject> picked = selectRecommendations(
        <List<BangumiSubject>>[one, const <BangumiSubject>[]],
        seed: 1,
        want: 5,
      );
      expect(picked, hasLength(1));
      expect(selectRecommendations(const <List<BangumiSubject>>[], seed: 1), isEmpty);
    });

    test('窗口里的残缺项一个都不会被选中', () {
      const BangumiSubject good = BangumiSubject(
        id: 10,
        name: 'Good',
        date: '2010-04-01',
        score: 8,
        coverUrl: 'https://lain.bgm.tv/g.jpg',
      );
      const BangumiSubject noDate = BangumiSubject(
          id: 11, name: 'NoDate', score: 8, coverUrl: 'https://lain.bgm.tv/n.jpg');
      const BangumiSubject noScore = BangumiSubject(
          id: 12, name: 'NoScore', date: '2010-04-01', coverUrl: 'https://lain.bgm.tv/n.jpg');
      const BangumiSubject noCover =
          BangumiSubject(id: 13, name: 'NoCover', date: '2010-04-01', score: 8);
      const BangumiSubject zeroScore = BangumiSubject(
          id: 14, name: 'Zero', date: '2010-04-01', score: 0, coverUrl: 'https://lain.bgm.tv/z.jpg');

      final List<BangumiSubject> picked = selectRecommendations(
        <List<BangumiSubject>>[
          <BangumiSubject>[noDate, noScore, noCover, zeroScore, good],
        ],
        seed: 3,
        want: 5,
      );
      expect(picked.map((BangumiSubject s) => s.id), <int>[10]);
    });
  });

  group('随机 offset（间隔均匀，防止窗口挨在一起）', () {
    test('4 个 offset 落在 4 个互不相同的分段里，且都在合法范围内', () {
      const int total = 29521;
      final List<int> offsets =
          recommendOffsets(seed: 20261009, total: total, windows: 4, limit: 20);
      expect(offsets, hasLength(4));
      for (final int o in offsets) {
        expect(o, inInclusiveRange(0, total - 20));
      }
      final int band = (total - 20 + 1) ~/ 4;
      final Set<int> bands =
          offsets.map((int o) => (o / band).floor()).toSet();
      expect(bands, hasLength(4), reason: '每个窗口来自不同分段，才谈得上「相距较远」');
      // 升序后相邻间隔至少一个分段的量级
      final List<int> sorted = <int>[...offsets]..sort();
      for (int i = 1; i < sorted.length; i++) {
        expect(sorted[i] - sorted[i - 1], greaterThan(0));
      }
    });

    test('种子按当天固定：同一天同样子，隔天换种子', () {
      final DateTime day = DateTime(2026, 10, 9);
      expect(recommendSeedForDate(day), recommendSeedForDate(DateTime(2026, 10, 9, 23)));
      expect(recommendSeedForDate(day),
          isNot(recommendSeedForDate(DateTime(2026, 10, 10))));
      expect(recommendSeedWithBatch(recommendSeedForDate(day), 1),
          isNot(recommendSeedWithBatch(recommendSeedForDate(day), 0)));
    });

    test('total 很小时不炸（offset 全 0）', () {
      expect(recommendOffsets(seed: 1, total: 5, windows: 4, limit: 20),
          everyElement(0));
      expect(recommendOffsets(seed: 1, total: 0, windows: 4, limit: 20),
          everyElement(0));
    });
  });

  group('JSON 往返（缓存用）', () {
    test('条目 toJson/fromJson 保留评分/日期/封面/标签', () {
      final BangumiSubject original = loadPage(0).items.first;
      final BangumiSubject back =
          BangumiSubject.fromJson(jsonDecode(jsonEncode(original.toJson())) as Map<String, Object?>);
      expect(back.id, original.id);
      expect(back.displayTitle, original.displayTitle);
      expect(back.date, original.date);
      expect(back.score, original.score);
      expect(back.coverUrl, original.coverUrl);
      expect(back.eps, original.eps);
      // coverage: name_cn 为空的条目也要能往返
      const BangumiSubject emptyCn = BangumiSubject(id: 9, name: 'X', nameCn: '');
      final BangumiSubject back2 =
          BangumiSubject.fromJson(emptyCn.toJson().cast<String, Object?>());
      expect(back2.displayTitle, 'X');
    });
  });

  // ── 第十七轮：真机缺陷「搜索失败：操作失败：type 'int' is not a subtype of
  //    type 'List<Object?>?' in type cast」 ──
  //
  // 缺陷根因（**实测响应体**，2026-10-12 在本机 curl + 真机截图两条路都验过）：
  // 旧搜索接口 `GET /search/subject/女友的朋友?type=2&responseGroup=small&max_results=3`
  // 回的是 `{"results":693,"list":[…]}` —— `results` 是**命中条数（int）**，数组在
  // `list` 里。老代码 `decoded['results'] as List<Object?>?` 把这个 int 当数组 cast。
  // 下面两条 fixture 就是那次实测的原文（截取到字段够用为止，id/name 都是真的）。
  group('搜索响应：`results` 是条数、条目在 `list` 里（第十七轮真机缺陷）', () {
    // 实测响应（原样截取；`女友的朋友` 搜出来第一条就是正确的那个条目）。
    const String searchBody = '{"results":693,"list":['
        '{"id":647220,"url":"http://bgm.tv/subject/647220","type":2,'
        '"name":"彼女の友達","name_cn":"女友的朋友","summary":"","air_date":"",'
        '"air_weekday":0,"images":{"large":"http://lain.bgm.tv/pic/cover/l/x.jpg",'
        '"common":"http://lain.bgm.tv/pic/cover/c/x.jpg",'
        '"medium":"http://lain.bgm.tv/pic/cover/m/x.jpg",'
        '"small":"http://lain.bgm.tv/pic/cover/s/x.jpg",'
        '"grid":"http://lain.bgm.tv/pic/cover/g/x.jpg"}},'
        '{"id":17883,"name":"僕は友達が少ない","name_cn":"我的朋友很少",'
        '"air_date":"2011-10-07","eps":12,'
        '"images":{"grid":"http://lain.bgm.tv/pic/cover/g/y.jpg"},'
        '"rating":{"score":6.8,"rank":1500,"total":9000}}]}';

    test('`results`(int) + `list`(数组) 能解析出候选（不再抛类型错）', () {
      final List<BangumiSubject> items = parseBangumiSearchResults(searchBody);
      expect(items, hasLength(2));
      expect(items.first.id, 647220);
      expect(items.first.displayTitle, '女友的朋友', reason: '中文名优先');
      expect(items.first.coverUrl, endsWith('/g/x.jpg'), reason: '封面取 images.grid');
      expect(items[1].score, 6.8);
      expect(items[1].date, '2011-10-07');
    });

    test('`results`(int) 不会被当成数组 —— 界面文案里那句「操作失败：type int …」不许再出现', () {
      // 只有条数、没有 list（改版/被裁过）：空候选，不抛。
      expect(parseBangumiSearchResults('{"results":693}'), isEmpty);
      // 一条都没有：空候选，不抛。
      expect(parseBangumiSearchResults('{"results":0,"list":[]}'), isEmpty);
      // `results` 自己就是数组（有些镜像/中间层会这么包）：认它。
      expect(parseBangumiSearchResults('{"results":[{"id":1,"name":"A"}]}'),
          hasLength(1));
    });

    test('也认 `data`（新接口形状）与裸数组', () {
      expect(parseBangumiSearchResults('{"data":[{"id":7,"name":"A"}]}'), hasLength(1));
      expect(parseBangumiSearchResults('[{"id":8,"name":"B"}]'), hasLength(1));
    });

    test('不是 JSON / 完全不是对象 → BangumiException（这一条才算真错误）', () {
      expect(() => parseBangumiSearchResults('<html>502</html>'),
          throwsA(isA<BangumiException>()));
      expect(parseBangumiSearchResults('{"foo":1}'), isEmpty,
          reason: '形状不认识 = 没有候选，不是异常');
    });

    test('条目字段换类型（`tags` 是 int / `images` 是字符串）也不许炸', () {
      final List<BangumiSubject> items = parseBangumiSearchResults(
        '{"list":[{"id":5,"name":"A","tags":3,"images":"oops","rating":"x"}]}',
      );
      expect(items, hasLength(1));
      expect(items.first.id, 5);
      expect(items.first.tags, isEmpty);
      expect(items.first.coverUrl, isNull);
      expect(items.first.score, isNull);
    });
  });

  // ── 用户 2026-10-12 第二十轮：「bangumi 的封面很糊」────────────────────────────
  //
  // 真因：代码一直拿 `images.grid` 当封面用，而 grid = `/r/100/` —— **只有 100 像素宽**，
  // 放到 208pt 的海报卡上（本机缩放 1.25 ⇒ 需要 260 设备像素）等于放大 2.6 倍。
  // 真机实测的档位只有四档：`/r/100/` 100×150、`/r/200/` 200×300、`/r/400/` 400×600、
  // `/r/800/` ≤800（源更小就封顶）；`/r/150/`、`/r/250/`、`/r/300/`、`/r/500/`
  // 全部 **HTTP 400** —— 所以只能往上抬到这几档，不能自己算宽度。
  group('封面尺寸档（第二十轮）', () {
    const String grid =
        'https://lain.bgm.tv/r/100/pic/cover/l/8a/b2/312427_D2ZNm.jpg';
    const String original =
        'https://lain.bgm.tv/pic/cover/l/8a/b2/312427_D2ZNm.jpg';

    test('想要的宽度只往上抬到图床认的四档（实测别的宽度会 400）', () {
      expect(bangumiCoverWidths, <int>[100, 200, 400, 800]);
      expect(snapBangumiCoverWidth(1), 100);
      expect(snapBangumiCoverWidth(50), 100, reason: '40pt 缩略图（本机 ≈50 设备像素）继续用 100');
      expect(snapBangumiCoverWidth(100), 100);
      expect(snapBangumiCoverWidth(101), 200);
      expect(snapBangumiCoverWidth(185), 200, reason: '148pt 推荐卡 × 1.25 = 185');
      expect(snapBangumiCoverWidth(200), 200);
      expect(snapBangumiCoverWidth(260), 400, reason: '208pt 海报卡 × 1.25 = 260');
      expect(snapBangumiCoverWidth(800), 800);
      expect(snapBangumiCoverWidth(4000), 800, reason: '超过最大档就取最大档，绝不写一个会被 400 的宽度');
    });

    test('已有宽度前缀的 URL：换掉那个数字，其余原样', () {
      expect(bangumiCoverAt(grid, 400),
          'https://lain.bgm.tv/r/400/pic/cover/l/8a/b2/312427_D2ZNm.jpg');
      expect(bangumiCoverAt(grid, 260),
          'https://lain.bgm.tv/r/400/pic/cover/l/8a/b2/312427_D2ZNm.jpg',
          reason: '260 抬到 400 那一档');
      expect(bangumiCoverAt(grid, 50), grid, reason: '缩略图档位不变 → URL 不变（缓存不白下）');
    });

    test('原图 URL（没有宽度前缀）：在前面插一段 /r/<宽>', () {
      expect(bangumiCoverAt(original, 200),
          'https://lain.bgm.tv/r/200/pic/cover/l/8a/b2/312427_D2ZNm.jpg');
    });

    // ⚠️ 第二十一轮的回归钉：上一版往**老式** URL 里无脑插 `/r/<宽>`，
    // 而 `/r/400/pic/cover/g/…`、`/r/400/pic/cover/c/…` 真机实测是 HTTP 400 —— 于是
    // 「已完成」页（封面走旧搜索接口 `/search/subject/{q}`）的封面**全部加载不出来**。
    // 正确做法：**先归一化到 `l`（原图）那一份，再抬档**（实测 `/r/400/pic/cover/l/…` = 200）。
    test('老式 URL（旧搜索接口的 /pic/cover/<字母>/）一律归一化到 l 再抬档', () {
      const String oldGrid = 'http://lain.bgm.tv/pic/cover/g/af/7e/656083_B22Yt.jpg';
      expect(bangumiCoverAt(oldGrid, 400),
          'http://lain.bgm.tv/r/400/pic/cover/l/af/7e/656083_B22Yt.jpg');
      expect(bangumiCoverAt(oldGrid, 50),
          'http://lain.bgm.tv/r/100/pic/cover/l/af/7e/656083_B22Yt.jpg');
      // 旧的 common / medium / small 目录同样只认 l 那一份
      for (final String letter in <String>['c', 'm', 's']) {
        expect(
          bangumiCoverAt('http://lain.bgm.tv/pic/cover/$letter/af/7e/656083_B22Yt.jpg', 200),
          'http://lain.bgm.tv/r/200/pic/cover/l/af/7e/656083_B22Yt.jpg',
        );
      }
      // 已经是带前缀的、但源不是 l（真机上不该出现；出现也不能原样交出去）
      expect(
        bangumiCoverAt('https://lain.bgm.tv/r/100/pic/cover/c/af/7e/656083_B22Yt.jpg', 400),
        'https://lain.bgm.tv/r/400/pic/cover/l/af/7e/656083_B22Yt.jpg',
      );
    });

    test('不认识的形状一律原样返回（宁可照旧，也不交一个 400 的 URL）', () {
      const String weird = 'https://lain.bgm.tv/pic/cover/x/af/7e/656083_B22Yt.jpg';
      expect(bangumiCoverAt(weird, 400), weird);
    });

    test('不是 Bangumi 封面（mikan 等别的源）→ 原样返回，绝不改别人的 URL', () {
      const String mikan =
          'https://mikanani.me/images/Bangumi/202610/abc.jpg?format=webp';
      expect(bangumiCoverAt(mikan, 400), mikan);
      expect(bangumiCoverAt('https://example.com/a.jpg', 800), 'https://example.com/a.jpg');
    });

    test('null / 空白 / 宽度还没算出来 → 不编 URL', () {
      expect(bangumiCoverAt(null, 400), isNull);
      expect(bangumiCoverAt('   ', 400), isNull);
      expect(bangumiCoverAt(grid, 0), grid, reason: '宽度 0 = 还没布局，别乱降档');
    });

    test('BangumiSubject.coverUrlAt：从存量的 grid URL 抬档（老数据不用迁移）', () {
      final BangumiSubject s = BangumiSubject.fromJson(<String, Object?>{
        'id': 312427,
        'name': 'テスト',
        'images': <String, Object?>{'grid': grid, 'large': original},
      });
      expect(s.coverUrl, grid, reason: '解析仍然存 grid（存量数据的形状不变）');
      expect(s.coverUrlAt(400), contains('/r/400/pic/cover/'));
      expect(s.coverUrlAt(50), grid);

      // grid 缺失时才退到原图那一份。
      final BangumiSubject onlyLarge = BangumiSubject.fromJson(<String, Object?>{
        'id': 1,
        'images': <String, Object?>{'large': original},
      });
      expect(onlyLarge.coverUrl, isNull);
      expect(onlyLarge.coverUrlAt(200), contains('/r/200/pic/cover/'));
    });
  });

  // ── 第三十四轮：详情端点还有三样以前没解析、所以详情页"太空了"的东西 ──────────
  //
  // 用户原话：「动漫库点的详细页，太空了优化下」。要填满就得先把这三样解析出来
  // （它们**只有详情端点**给，搜索端点不给），形状全部照本机实测
  // （`tool/round34_subject_probe.py`，2026-10-15，`build/round34/subject-probe.txt`）。
  group('详情端点的补充字段（评分分布 / 收藏统计 / 资料表）', () {
    /// 实测响应截取（`GET /v0/subjects/400602`，字段值原样）。
    const String detailBody = '{"id":400602,"type":2,"name":"Sousou no Frieren",'
        '"name_cn":"葬送的芙莉莲","date":"2023-09-29","eps":28,"platform":"TV",'
        '"images":{"grid":"https://lain.bgm.tv/r/100/pic/cover/l/x.jpg"},'
        '"rating":{"rank":43,"total":36596,"score":8.5,'
        '"count":{"1":129,"2":37,"3":53,"4":112,"5":356,"6":1101,'
        '"7":3727,"8":10609,"9":12961,"10":7511}},'
        '"collection":{"on_hold":2030,"dropped":766,"wish":7061,'
        '"collect":54970,"doing":11847},'
        '"infobox":[{"key":"中文名","value":"葬送的芙莉莲"},'
        '{"key":"别名","value":[{"v":"Frieren: Beyond Journey\'s End"},'
        '{"v":"Sousou no Frieren"}]},{"key":"话数","value":"28"},'
        '{"key":"放送星期","value":"星期五"}],'
        '"summary":"勇者一行打败魔王之后的旅程。",'
        '"tags":[{"name":"治愈","count":8129}]}';

    test('rating.count → 1..10 的票数表；inbox 的两种值形状都接得住', () {
      final BangumiSubject s = parseBangumiSubject(detailBody);
      expect(s.ratingCounts[10], 7511);
      expect(s.ratingCounts[1], 129);
      expect(s.ratingAt(9), 12961);
      expect(s.ratingAt(0), 0, reason: '没有那一档就是 0（不编进表里）');
      expect(s.hasRatingBreakdown, isTrue);
      expect(s.ratingVotes, 36596, reason: '十档之和 = 端点给的 total');
      expect(s.score, 8.5);
      expect(s.rank, 43);
    });

    test('infobox 解析成「键 + 字符串列表」：字符串与 [{v:…}] 两种都行', () {
      final BangumiSubject s = parseBangumiSubject(detailBody);
      expect(s.infobox, hasLength(4));
      expect(s.infobox.first.key, '中文名');
      expect(s.infobox.first.text, '葬送的芙莉莲');
      final BangumiInfoboxItem alias = s.infobox[1];
      expect(alias.key, '别名');
      expect(alias.values, <String>["Frieren: Beyond Journey's End", 'Sousou no Frieren']);
      expect(alias.text, "Frieren: Beyond Journey's End / Sousou no Frieren",
          reason: '多项用「 / 」接起来（详情页就是这么画的）');
    });

    test('collection 五项 + 总数；不是对象就当「没有统计」（不编数字）', () {
      final BangumiSubject s = parseBangumiSubject(detailBody);
      expect(s.collection!.wish, 7061);
      expect(s.collection!.collect, 54970);
      expect(s.collection!.doing, 11847);
      expect(s.collection!.onHold, 2030);
      expect(s.collection!.dropped, 766);
      expect(s.collection!.total, 76674);
      expect(s.collection!.isEmpty, isFalse);

      expect(BangumiCollection.fromJson(null), isNull);
      expect(BangumiCollection.fromJson('x'), isNull);
      expect(BangumiCollection.fromJson(<String, Object?>{'foo': 1}), isNull,
          reason: '认不出形状 = 没有统计，而不是"五项都是 0"');
      expect(BangumiCollection.fromJson(<String, Object?>{'wish': 3})!.total, 3);
    });

    test('脏字段不许把整条炸掉（count 换类型 / 键越界 / infobox 是 int）', () {
      final BangumiSubject s = BangumiSubject.fromJson(<String, Object?>{
        'id': 7,
        'rating': <String, Object?>{
          'score': 6.0,
          'count': <Object?, Object?>{'10': '7511', '11': 9, 'x': 1, 3: 4},
        },
        'collection': 3,
        'infobox': 42,
      });
      expect(s.ratingCounts, <int, int>{3: 4}, reason: '字符串票数、越界键、非数字键都被剔除');
      expect(s.ratingAt(3), 4);
      expect(s.collection, isNull);
      expect(s.infobox, isEmpty);
      expect(s.score, 6.0, reason: '一个脏字段不影响同一条里的其它字段');
    });

    test('往返缓存保留这三样（第二次点开同一部是本地读）', () {
      final BangumiSubject s = parseBangumiSubject(detailBody);
      final BangumiSubject back = BangumiSubject.fromJson(
          jsonDecode(jsonEncode(s.toJson())) as Map<String, Object?>);
      expect(back.ratingCounts, s.ratingCounts);
      expect(back.ratingVotes, 36596);
      expect(back.collection!.total, 76674);
      expect(back.infobox.map((BangumiInfoboxItem i) => i.key), <String>['中文名', '别名', '话数', '放送星期']);
      expect(back.infobox[1].text, s.infobox[1].text);

      // 没有这三样的条目（搜索端点那种）往返也不许凭空长出来。
      final BangumiSubject bare = BangumiSubject.fromJson(<String, Object?>{
        'id': 7,
        'name_cn': '只有搜索字段的条目',
        'score': 7.0,
      });
      final BangumiSubject bareBack = BangumiSubject.fromJson(
          jsonDecode(jsonEncode(bare.toJson())) as Map<String, Object?>);
      expect(bareBack.ratingCounts, isEmpty);
      expect(bareBack.collection, isNull);
      expect(bareBack.infobox, isEmpty);
      expect(bareBack.score, 7.0);
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // 第五十一轮：官方源站挂掉（Cloudflare 52x）时要「快速失败」，不要一次等 40s
  // ───────────────────────────────────────────────────────────────────────────
  //
  // 真机实测（2026-10-17）：api.bgm.tv 的列表/搜索端点全部回 **522**，而 Cloudflare
  // 要 ~19.8s 才吐这句错误；旧客户端把 5xx 一律当「抖动」再重试一次 ⇒ 一次失败 ~40s。
  // 动漫库一页要打好几次请求，用户看到的就是「接口返不回来」。
  group('BangumiClient：52x 不重试 + 熔断', () {
    const String emptyPage = '{"total":0,"limit":1,"offset":0,"data":[]}';

    BangumiClient clientThatCounts(
      List<int> statuses, {
      required void Function() onRequest,
      DateTime Function()? clock,
    }) {
      int index = 0;
      return BangumiClient(
        minInterval: Duration.zero,
        // 测试里没有真的 ~19.8s 可等：用状态码序列复现行为，重试/熔断逻辑与耗时无关。
        client: MockClient((http.Request request) async {
          onRequest();
          final int code =
              statuses[index < statuses.length ? index : statuses.length - 1];
          index++;
          return http.Response(code == 522 ? 'error code: 522' : emptyPage, code);
        }),
        clock: clock,
      );
    }

    test('522 只打一次请求（不重试），错误码原样带出来', () async {
      int requests = 0;
      final BangumiClient client =
          clientThatCounts(<int>[522], onRequest: () => requests++);
      await expectLater(
        client.subjects(limit: 1, offset: 0),
        throwsA(isA<BangumiException>()
            .having((BangumiException e) => e.statusCode, 'statusCode', 522)),
      );
      expect(requests, 1, reason: '52x 是源站连不上，重试只是把同一次 ~19.8s 的超时再等一遍');
    });

    test('一次 522 之后熔断：冷却窗口内的请求立刻失败，一个请求都不发', () async {
      int requests = 0;
      DateTime now = DateTime(2026, 10, 17, 12);
      final BangumiClient client = clientThatCounts(
        <int>[522, 200],
        onRequest: () => requests++,
        clock: () => now,
      );

      await expectLater(
        client.subjects(limit: 1, offset: 0),
        throwsA(isA<BangumiException>()),
      );
      expect(requests, 1);

      // 熔断窗口（默认 60s）内：立即失败、不发请求 —— 页面「重试」不会再卡几十秒。
      final Stopwatch watch = Stopwatch()..start();
      now = now.add(const Duration(seconds: 10));
      await expectLater(
        client.subject(395378),
        throwsA(isA<BangumiException>()
            .having((BangumiException e) => e.statusCode, 'statusCode', 522)),
      );
      watch.stop();
      expect(requests, 1, reason: '熔断期间不许真的发请求');
      expect(watch.elapsed, lessThan(const Duration(seconds: 1)));
    });

    test('熔断会自己解除：窗口过后照常发，成功一条就清掉熔断', () async {
      int requests = 0;
      DateTime now = DateTime(2026, 10, 17, 12);
      final BangumiClient client = clientThatCounts(
        <int>[522, 200, 200],
        onRequest: () => requests++,
        clock: () => now,
      );

      await expectLater(
        client.subjects(limit: 1, offset: 0),
        throwsA(isA<BangumiException>()),
      );
      now = now.add(const Duration(seconds: 61));
      final BangumiSubjectsPage page = await client.subjects(limit: 1, offset: 0);
      expect(page.items, isEmpty);
      expect(requests, 2, reason: '窗口过了要再试一次（不能永远熔断）');

      // 成功之后熔断已清：下一次照样真的发（不会因为"上一次失败过"就被挡）。
      await client.subjects(limit: 1, offset: 0);
      expect(requests, 3);
    });

    test('502（通用 5xx，不是 Cloudflare）仍然重试一次 —— 原有语义不动', () async {
      int requests = 0;
      final BangumiClient client =
          clientThatCounts(<int>[502, 200], onRequest: () => requests++);
      await client.subjects(limit: 1, offset: 0);
      expect(requests, 2, reason: '502 是真正的"抖动"，重试一次仍是对的');
    });
  });
}
