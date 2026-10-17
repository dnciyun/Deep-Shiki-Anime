/// 1.1.0 M1/T6：解析下放子 isolate 的**路由 / 等价 / 错误保真**测试。
///
/// 三组证据：
/// 1. **路由**：小于 [kParseOffloadBytes] 的页在**调用方 isolate** 当场算完（小负载
///    同步走）；到阈值的页进子 isolate —— 用 `Isolate.current.debugName` 探测
///    （helper 里起了 `debugName: 'dsanima-parse'`），不靠计时，机器快慢都不假红假绿。
/// 2. **等价**：同一份大页（真实原页，或把真实 `<tr>` 复制到真站点一页的大小），
///    同步解析与后台解析**逐字段**一致（`SourceItem.toJson()` 全量比对 +
///    `hasNext` / `skipped` / `warnings`）。端到端再过一遍四个源的公开入口。
/// 3. **错误**：大页上抛的 `SourceException` / `DmhyNotListPageException` /
///    `SourceNoResultsException` 跨 isolate 后**类型与文案都不变** —— dmhy 的
///    「临时页自动重试一次」与宿主的「0 条换短名补搜」都靠类型认，这条一坏就是静默失效。
library;

import 'dart:convert';
import 'dart:isolate';

import 'package:dsanima_core/sources/sources.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'fixtures.dart';
import 'support.dart';

final DateTime _t = DateTime.utc(2026, 10, 8, 12);

/// [parseOffThread] 起子 isolate 时用的 debugName（探测路由用）。
const String _offloadDebugName = 'dsanima-parse';

/// 把页面里所有 `<tr>…</tr>` 原样复制 [copies] 份（第一份保留原位，其余插到
/// `</tbody>` / `</table>` 之前），把真实小样本放大到真站点一页的大小。
///
/// 为什么复制行而不是补空白：复制行同时放大**建 DOM**与**逐行解析**两段开销
/// （补空白只放大前者）；解析结果完全由真实行结构决定，复制出来的每一行与原件一致。
String _amplifyRows(String html, {required int copies}) {
  final List<String> rows = RegExp(r'<tr\b[\s\S]*?</tr>', caseSensitive: false)
      .allMatches(html)
      .map((RegExpMatch m) => m.group(0)!)
      .toList(growable: false);
  expect(rows, isNotEmpty, reason: 'fixture 里应该有 <tr>');
  final int tbody = html.lastIndexOf('</tbody>');
  final int at = tbody >= 0 ? tbody : html.lastIndexOf('</table>');
  expect(at, greaterThan(0), reason: 'fixture 里应该有表格闭合标签');
  final String block =
      List<String>.filled(copies - 1, rows.join('\n')).join('\n');
  return html.replaceRange(at, at, block);
}

/// 补空白把页面抬过阈值（DOM 与解析结果都不变，只测"路由"时用）。
String _padAboveThreshold(String html) =>
    html + (' ' * (kParseOffloadBytes + 1));

void _expectSameOutcome(
  ParseOutcome sync,
  ParseOutcome off, {
  required String label,
}) {
  expect(off.items, hasLength(sync.items.length), reason: '$label：条数');
  for (int i = 0; i < sync.items.length; i++) {
    expect(
      off.items[i].toJson(),
      sync.items[i].toJson(),
      reason: '$label：第 ${i + 1} 条逐字段（id=${sync.items[i].id}）',
    );
  }
  expect(off.hasNext, sync.hasNext, reason: '$label：hasNext');
  expect(off.skipped, sync.skipped, reason: '$label：skipped');
  expect(off.warnings, sync.warnings, reason: '$label：warnings');
}

void _expectSameItem(SourceItem? sync, SourceItem? off, {required String label}) {
  expect(off == null, sync == null, reason: '$label：null 与否');
  if (sync != null) {
    expect(off!.toJson(), sync.toJson(), reason: '$label：逐字段');
  }
}

/// 抓一次同步抛出的 [SourceException]（没有抛就返回 null）。
SourceException? _catchSyncError(void Function() body) {
  try {
    body();
    return null;
  } on SourceException catch (e) {
    return e;
  }
}

/// 抓一次后台解析抛出的异常（没有抛就返回 null）。
Future<Object?> _catchOffThreadError(Future<Object?> Function() body) async {
  try {
    await body();
    return null;
  } catch (e) {
    return e;
  }
}

FakeClock _newClock() => FakeClock(_t);

NyaaSource _buildNyaa(RecordingHttpFactory factory, FakeClock clock) => NyaaSource(
      http: buildHttp(factory, clock: clock),
      cache: SourceCache(store: InMemoryKeyValueStore(), clock: clock.call),
      clock: clock.call,
    );

DmhySource _buildDmhy(RecordingHttpFactory factory, FakeClock clock) => DmhySource(
      http: buildHttp(factory, clock: clock),
      cache: SourceCache(store: InMemoryKeyValueStore(), clock: clock.call),
      clock: clock.call,
    );

AcgRipSource _buildAcgRip(RecordingHttpFactory factory, FakeClock clock) =>
    AcgRipSource(
      http: buildHttp(factory, clock: clock),
      cache: SourceCache(store: InMemoryKeyValueStore(), clock: clock.call),
      clock: clock.call,
    );

MikanSource _buildMikan(RecordingHttpFactory factory, FakeClock clock) =>
    MikanSource(
      http: buildHttp(factory, clock: clock),
      cache: SourceCache(store: InMemoryKeyValueStore(), clock: clock.call),
      clock: clock.call,
    );

void main() {
  group('路由：小负载同步、大负载进子 isolate', () {
    test('小于阈值 → compute 在调用方 isolate **当场**算完（不是排到事件循环后面）',
        () async {
      String? where;
      final Future<int> pending = parseOffThread<int>(
        text: 'x' * (kParseOffloadBytes - 1),
        now: _t,
        compute: (DateTime at) {
          where = Isolate.current.debugName ?? '<caller>';
          return 1;
        },
      );
      // compute 在 parseOffThread 返回前就跑完了：小页与改动前一样，仍同步。
      expect(where, isNotNull);
      expect(where, isNot(_offloadDebugName));
      expect(await pending, 1);
    });

    test('到阈值 → 进子 isolate（不是看耗时，看 debugName）', () async {
      expect(Isolate.current.debugName, isNot(_offloadDebugName));
      final String where = await parseOffThread<String>(
        text: 'x' * kParseOffloadBytes,
        now: _t,
        compute: (DateTime at) => Isolate.current.debugName ?? '<caller>',
      );
      expect(where, _offloadDebugName);
    });

    test('阈值边界：-1 同步、恰好 +0 后台', () async {
      final List<String> where = <String>[];
      for (final int len in <int>[kParseOffloadBytes - 1, kParseOffloadBytes]) {
        where.add(await parseOffThread<String>(
          text: 'x' * len,
          now: _t,
          compute: (DateTime at) => Isolate.current.debugName ?? '<caller>',
        ));
      }
      expect(where[0], isNot(_offloadDebugName));
      expect(where[1], _offloadDebugName);
    });
  });

  group('等价：同一份大页，同步解析 == 后台解析（逐字段）', () {
    test('nyaa HTML 列表页（真实 75 行 / 123KB 原页）', () async {
      final String html = loadFixture('nyaa_search.html');
      expect(html.length, greaterThanOrEqualTo(kParseOffloadBytes),
          reason: '必须是真·大页，否则测的还是同步路径');
      final ParseOutcome sync =
          NyaaHtmlListParser.parse(html, sourceId: 'nyaa', clock: () => _t);
      final ParseOutcome off = await parseOffThread<ParseOutcome>(
        text: html,
        now: _t,
        compute: (DateTime at) => NyaaHtmlListParser.parse(
          html,
          sourceId: 'nyaa',
          clock: () => at,
        ),
      );
      _expectSameOutcome(sync, off, label: 'nyaa 列表');
      expect(off.items, hasLength(75));
    });

    test('nyaa 详情页（真实 18KB 页补到 > 64KB）', () async {
      // 详情页没有列表行可复制（标签是 div 对），补空白只抬长度、DOM 原样 ——
      // 这条测的是"路由 + 等价"，不假装它是真·大详情页。
      final String html =
          _padAboveThreshold(loadFixture('nyaa_view_2090638.html'));
      expect(html.length, greaterThanOrEqualTo(kParseOffloadBytes));
      const SourceItem base = SourceItem(
        id: 'nyaa:2090638',
        sourceId: 'nyaa',
        title: '旧标题',
      );
      final SourceItem? sync = NyaaHtmlDetailParser.parse(
        html,
        base: base,
        sourceId: 'nyaa',
        clock: () => _t,
      );
      final SourceItem? off = await parseOffThread<SourceItem?>(
        text: html,
        now: _t,
        compute: (DateTime at) => NyaaHtmlDetailParser.parse(
          html,
          base: base,
          sourceId: 'nyaa',
          clock: () => at,
        ),
      );
      _expectSameItem(sync, off, label: 'nyaa 详情');
      expect(off, isNotNull);
    });

    test('dmhy 列表页（真实 4 行复制到 ~120KB）', () async {
      final String html = _amplifyRows(
        loadFixture('dmhy_list.html'),
        copies: 10,
      );
      expect(html.length, greaterThanOrEqualTo(kParseOffloadBytes));
      final ParseOutcome sync = DmhyListParser.parse(
        html,
        sourceId: 'dmhy',
        clock: () => _t,
        pageUri: Uri.parse('https://share.dmhy.org/topics/list'),
      );
      final ParseOutcome off = await parseOffThread<ParseOutcome>(
        text: html,
        now: _t,
        compute: (DateTime at) => DmhyListParser.parse(
          html,
          sourceId: 'dmhy',
          clock: () => at,
          pageUri: Uri.parse('https://share.dmhy.org/topics/list'),
        ),
      );
      _expectSameOutcome(sync, off, label: 'dmhy 列表');
      expect(off.items.length, greaterThanOrEqualTo(30));
    });

    test('acgrip 列表页（真实 3 行复制到 ~100KB）', () async {
      final String html = _amplifyRows(
        loadFixture('acgrip_list.html'),
        copies: 50,
      );
      expect(html.length, greaterThanOrEqualTo(kParseOffloadBytes));
      final ParseOutcome sync = AcgRipListParser.parse(
        html,
        sourceId: 'acgrip',
        clock: () => _t,
        categoryLabel: '动画',
      );
      final ParseOutcome off = await parseOffThread<ParseOutcome>(
        text: html,
        now: _t,
        compute: (DateTime at) => AcgRipListParser.parse(
          html,
          sourceId: 'acgrip',
          clock: () => at,
          categoryLabel: '动画',
        ),
      );
      _expectSameOutcome(sync, off, label: 'acgrip 列表');
      expect(off.items.length, greaterThanOrEqualTo(100));
    });

    test('mikan 搜索页（真实 3 行复制到 ~180KB）', () async {
      final String html = _amplifyRows(
        loadFixture('mikan_search.html'),
        copies: 20,
      );
      expect(html.length, greaterThanOrEqualTo(kParseOffloadBytes));
      final ParseOutcome sync = MikanSearchParser.parse(
        html,
        sourceId: 'mikan',
        clock: () => _t,
      );
      final ParseOutcome off = await parseOffThread<ParseOutcome>(
        text: html,
        now: _t,
        compute: (DateTime at) => MikanSearchParser.parse(
          html,
          sourceId: 'mikan',
          clock: () => at,
        ),
      );
      _expectSameOutcome(sync, off, label: 'mikan 搜索');
      expect(off.items.length, greaterThanOrEqualTo(3));
    });

    test('mikan 番剧页（真实 69KB 原页，新阈值下走后台）', () async {
      final String html = loadFixture('mikan_bangumi_4094.html');
      expect(html.length, greaterThanOrEqualTo(kParseOffloadBytes),
          reason: '第四十七轮的 128KB 阈值下它留在同步；64KB 之后应当走后台');
      final Uri url = Uri.parse('https://mikanani.me/Home/Bangumi/4094');
      final MikanBangumiDetail sync = MikanBangumiParser.parse(
        html,
        url: url,
        sourceId: 'mikan',
        clock: () => _t,
      );
      final MikanBangumiDetail off = await parseOffThread<MikanBangumiDetail>(
        text: html,
        now: _t,
        compute: (DateTime at) => MikanBangumiParser.parse(
          html,
          url: url,
          sourceId: 'mikan',
          clock: () => at,
        ),
      );
      expect(off.title, sync.title);
      expect(off.episodes.length, sync.episodes.length);
      for (int i = 0; i < sync.episodes.length; i++) {
        expect(off.episodes[i].toJson(), sync.episodes[i].toJson(),
            reason: '第 ${i + 1} 集逐字段');
      }
      expect(off.groups.length, sync.groups.length);
      expect(off.skipped, sync.skipped);
    });
  });

  group('端到端（假 HTTP）：源真的走了后台解析，结果与同步解析一致', () {
    test('NyaaSource.search 第 2 页（HTML 列表）', () async {
      final String html = loadFixture('nyaa_search.html');
      final FakeClock clock = _newClock();
      final RecordingHttpFactory factory =
          textFactory(html, contentType: 'text/html; charset=utf-8');
      final NyaaSource source = _buildNyaa(factory, clock);

      final SourcePage page = await source.search('Frieren', page: 2);

      expect(factory.requestedUris.single.queryParameters['page'], 'search');
      final ParseOutcome sync = NyaaHtmlListParser.parse(
        html,
        sourceId: 'nyaa',
        clock: clock.call,
      );
      _expectSameOutcome(
        sync,
        ParseOutcome(items: page.items, hasNext: page.hasNext),
        label: 'nyaa search 端到端',
      );
      expect(page.items, hasLength(75));
    });

    test('NyaaSource.detail（真实 18KB 页补到 > 64KB）', () async {
      final String html =
          _padAboveThreshold(loadFixture('nyaa_view_2090638.html'));
      expect(html.length, greaterThanOrEqualTo(kParseOffloadBytes));
      final FakeClock clock = _newClock();
      final RecordingHttpFactory factory =
          textFactory(html, contentType: 'text/html; charset=utf-8');
      final NyaaSource source = _buildNyaa(factory, clock);
      const SourceItem item = SourceItem(
        id: 'nyaa:2090638',
        sourceId: 'nyaa',
        title: '旧标题',
      );

      final SourceItem? enriched = await source.detail(item);

      final SourceItem? sync = NyaaHtmlDetailParser.parse(
        html,
        base: item,
        sourceId: 'nyaa',
        clock: clock.call,
      );
      _expectSameItem(sync, enriched, label: 'nyaa detail 端到端');
      expect(enriched!.extra['detailFetched'], isTrue);
    });

    test('DmhySource.latest（列表页复制到 ~120KB）', () async {
      final String html = _amplifyRows(loadFixture('dmhy_list.html'), copies: 10);
      expect(html.length, greaterThanOrEqualTo(kParseOffloadBytes));
      final FakeClock clock = _newClock();
      final RecordingHttpFactory factory =
          textFactory(html, contentType: 'text/html; charset=utf-8');
      final DmhySource source = _buildDmhy(factory, clock);

      final SourcePage page = await source.latest();

      final ParseOutcome sync = DmhyListParser.parse(
        html,
        sourceId: 'dmhy',
        clock: clock.call,
        pageUri: source.latestUri(1),
      );
      _expectSameOutcome(
        sync,
        ParseOutcome(items: page.items, hasNext: page.hasNext),
        label: 'dmhy latest 端到端',
      );
    });

    test('AcgRipSource.latest（列表页复制到 ~100KB）', () async {
      final String html = _amplifyRows(loadFixture('acgrip_list.html'), copies: 50);
      expect(html.length, greaterThanOrEqualTo(kParseOffloadBytes));
      final FakeClock clock = _newClock();
      final RecordingHttpFactory factory =
          textFactory(html, contentType: 'text/html; charset=utf-8');
      final AcgRipSource source = _buildAcgRip(factory, clock);

      final SourcePage page = await source.latest();

      final ParseOutcome sync = AcgRipListParser.parse(
        html,
        sourceId: 'acgrip',
        clock: clock.call,
        categoryLabel: source.categoryLabel,
      );
      _expectSameOutcome(
        sync,
        ParseOutcome(items: page.items, hasNext: page.hasNext),
        label: 'acgrip latest 端到端',
      );
    });

    test('MikanSource.search（搜索页复制到 ~180KB）', () async {
      final String html =
          _amplifyRows(loadFixture('mikan_search.html'), copies: 20);
      expect(html.length, greaterThanOrEqualTo(kParseOffloadBytes));
      final FakeClock clock = _newClock();
      final RecordingHttpFactory factory =
          textFactory(html, contentType: 'text/html; charset=utf-8');
      final MikanSource source = _buildMikan(factory, clock);

      final SourcePage page = await source.search('葬送的芙莉莲');

      final ParseOutcome sync = MikanSearchParser.parse(
        html,
        sourceId: 'mikan',
        clock: clock.call,
      );
      _expectSameOutcome(
        sync,
        ParseOutcome(items: page.items, hasNext: page.hasNext),
        label: 'mikan search 端到端',
      );
    });
  });

  group('错误：类型 / 文案跨 isolate 不变', () {
    test('dmhy 临时页（大页）→ 仍是 DmhyNotListPageException，文案逐字一致', () async {
      final String small = loadFixture('dmhy_not_list_page.html');
      final String big = _padAboveThreshold(small);
      final SourceException? syncErr = _catchSyncError(
        () => DmhyListParser.parse(small, sourceId: 'dmhy', clock: () => _t),
      );
      expect(syncErr, isA<DmhyNotListPageException>());

      final Object? offErr = await _catchOffThreadError(
        () => parseOffThread<ParseOutcome>(
          text: big,
          now: _t,
          compute: (DateTime at) =>
              DmhyListParser.parse(big, sourceId: 'dmhy', clock: () => at),
        ),
      );

      expect(offErr, isA<DmhyNotListPageException>(),
          reason: '类型一丢，DmhySource 的「自动重试一次」就静默失效');
      expect((offErr! as SourceException).message, syncErr!.message);
      expect((offErr as SourceException).sourceId, syncErr.sourceId);
    });

    test('dmhy 0 条（大页）→ 仍是 SourceNoResultsException，文案逐字一致', () async {
      final String small = loadFixture('dmhy_search_empty.html');
      final String big = _padAboveThreshold(small);
      final SourceException? syncErr = _catchSyncError(
        () => DmhyListParser.parse(small, sourceId: 'dmhy', clock: () => _t),
      );
      expect(syncErr, isA<SourceNoResultsException>());

      final Object? offErr = await _catchOffThreadError(
        () => parseOffThread<ParseOutcome>(
          text: big,
          now: _t,
          compute: (DateTime at) =>
              DmhyListParser.parse(big, sourceId: 'dmhy', clock: () => at),
        ),
      );

      expect(offErr, isA<SourceNoResultsException>(),
          reason: '类型一丢，宿主就不知道那是「词不对」而不是「源坏了」');
      expect((offErr! as SourceException).message, syncErr!.message);
    });

    test('nyaa 结构不认识（大页）→ SourceException 文案逐字一致', () async {
      final String small = loadEdgeFixture('nyaa_no_table.html');
      final String big = _padAboveThreshold(small);
      final SourceException? syncErr = _catchSyncError(
        () => NyaaHtmlListParser.parse(small, sourceId: 'nyaa', clock: () => _t),
      );
      expect(syncErr, isNotNull);

      final Object? offErr = await _catchOffThreadError(
        () => parseOffThread<ParseOutcome>(
          text: big,
          now: _t,
          compute: (DateTime at) =>
              NyaaHtmlListParser.parse(big, sourceId: 'nyaa', clock: () => at),
        ),
      );

      expect(offErr, isA<SourceException>());
      expect((offErr! as SourceException).message, syncErr!.message);
    });

    test('acgrip 结构不认识（大页）→ SourceException 文案逐字一致', () async {
      final String small = loadEdgeFixture('nyaa_no_table.html');
      final String big = _padAboveThreshold(small);
      final SourceException? syncErr = _catchSyncError(
        () => AcgRipListParser.parse(small, sourceId: 'acgrip', clock: () => _t),
      );
      expect(syncErr, isNotNull);

      final Object? offErr = await _catchOffThreadError(
        () => parseOffThread<ParseOutcome>(
          text: big,
          now: _t,
          compute: (DateTime at) =>
              AcgRipListParser.parse(big, sourceId: 'acgrip', clock: () => at),
        ),
      );

      expect(offErr, isA<SourceException>());
      expect((offErr! as SourceException).message, syncErr!.message);
    });

    test('dmhy 端到端：两次都是**大**临时页 → 照样重试一次，异常类型/文案不变', () async {
      final String temp = _padAboveThreshold(loadFixture('dmhy_not_list_page.html'));
      final RecordingHttpFactory factory = sequenceFactory(
        <http.Response Function()>[
          for (int i = 0; i < 2; i++)
            () => http.Response.bytes(
                  utf8.encode(temp),
                  200,
                  headers: <String, String>{
                    'content-type': 'text/html; charset=utf-8',
                  },
                ),
        ],
      );
      final FakeClock clock = _newClock();
      final DmhySource source = _buildDmhy(factory, clock);

      await expectLater(
        source.search('命运石之门'),
        throwsA(
          isA<DmhyNotListPageException>().having(
            (DmhyNotListPageException e) => e.message,
            'message',
            contains('已自动重试一次，两次都是这个页面'),
          ),
        ),
      );
      expect(factory.requestedUris, hasLength(2),
          reason: '跨 isolate 后重试逻辑仍生效（且只重试一次）');
    });

    test('dmhy 端到端：第一张**大**临时页、第二张正常大页 → 用户无感', () async {
      final String temp = _padAboveThreshold(loadFixture('dmhy_not_list_page.html'));
      final String list = _amplifyRows(loadFixture('dmhy_list.html'), copies: 10);
      final RecordingHttpFactory factory = sequenceFactory(
        <http.Response Function()>[
          () => http.Response.bytes(utf8.encode(temp), 200, headers: <String, String>{
            'content-type': 'text/html; charset=utf-8',
          }),
          () => http.Response.bytes(utf8.encode(list), 200, headers: <String, String>{
            'content-type': 'text/html; charset=utf-8',
          }),
        ],
      );
      final FakeClock clock = _newClock();
      final DmhySource source = _buildDmhy(factory, clock);

      final SourcePage page = await source.search('葬送的芙莉莲');

      expect(page.items.length, greaterThanOrEqualTo(30));
      expect(factory.requestedUris, hasLength(2));
    });
  });
}
