/// mikan 首页追番表解析单测（spec §7.5）。
///
/// fixture 是 **2026-10-09 真实抓取** 的 mikan 首页原文（`mikan_home_schedule.html`），
/// 全程离线。另一个小样本 `_tiny` 用来覆盖真实首页**没有**的边界
/// （`data-showsubscribed="true"`、缺字段、非法日期、空表 → 抛错）。
library;

import 'package:dsanima_core/sources/sources.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures.dart';

final DateTime _now = DateTime.utc(2026, 10, 9, 12);

MikanSchedule _parseReal() => MikanScheduleParser.parse(
      loadFixture('mikan_home_schedule.html'),
      url: Uri.parse('https://mikanani.me/'),
      sourceId: 'mikan',
      clock: () => _now,
    );

MikanSchedule _parseTiny(String html) => MikanScheduleParser.parse(
      html,
      url: Uri.parse('https://mikanani.me/'),
      sourceId: 'mikan',
      clock: () => _now,
    );

/// 真实首页的最小化骨架（用于构造边界）。
String _tiny({String dayOfWeek = '4', String span = '', String anchor = '', String date = ''}) =>
    '<html><body><div class="sk-bangumi" data-dayofweek="$dayOfWeek">'
    '<div class="an-box"><ul class="an-ul"><li>$span$anchor$date</li></ul></div>'
    '</div></body></html>';

void main() {
  group('真实首页（mikan_home_schedule.html）', () {
    late MikanSchedule s;

    setUpAll(() => s = _parseReal());

    test('能解析出条目，且按档位分组覆盖 0..6 + 两个专档（7=剧场版 / 8=OVA）', () {
      expect(s.entries, isNotEmpty);
      expect(s.byDay.keys, containsAll(<int>[0, 1, 2, 3, 4, 5, 6]));
      // 真实首页确实含两个专档桶（7/8），不能丢；名字照抄站点自己的 tab
      //（第二十五轮：以前 7/8 都显示成「未定档」，用户指出是剧场版与 OVA）。
      final unslotted =
          s.entries.where((MikanScheduleEntry e) => e.isUnslotted).toList();
      expect(unslotted, isNotEmpty, reason: '真实首页有专档条目，解析器必须保留');
      expect(unslotted.first.dayLabel, anyOf('剧场版', 'OVA'));
      expect(s.byDay.containsKey(7), isTrue, reason: '7 = 剧场版（站点 date-li-7 / data-row-7）');
      expect(s.byDay.containsKey(8), isTrue, reason: '8 = OVA（站点 date-li-8 / data-row-8）');
      expect(s.byDay[7]!.first.dayLabel, '剧场版');
      expect(s.byDay[8]!.first.dayLabel, 'OVA');
    });

    test('逐字段断言：番剧 id / 标题 / 封面 / 更新日期 / 详情链接', () {
      // 第一条（星期一）在抓取样本里的真实值
      final MikanScheduleEntry first = s.byDay[1]!.first;
      expect(first.bangumiId, isNotEmpty);
      expect(RegExp(r'^\d+$').hasMatch(first.bangumiId), isTrue,
          reason: 'bangumiId 应当是纯数字');
      expect(first.title, isNotNull);
      expect(first.title!.trim(), isNotEmpty);
      expect(first.dayOfWeek, 1);
      expect(first.dayLabel, '星期一');

      // 封面：解析成绝对 URL，且保留 mikan 图床的原始参数
      expect(first.coverUri, isNotNull);
      expect(first.coverUri!.host, 'mikanani.me');
      expect(first.coverUri!.path, startsWith('/images/Bangumi/'));
      expect(first.rawCover, contains('/images/Bangumi/'));
      expect(first.rawCover, contains('format=webp'),
          reason: '原始 data-src 要保留尺寸/格式参数，便于换尺寸');

      // 详情页链接指向番剧页
      expect(first.detailUrl, isNotNull);
      expect(first.detailUrl!.path, '/Home/Bangumi/${first.bangumiId}');

      // 更新日期：真实首页是「YYYY/MM/DD 更新」
      expect(first.updateText, contains('更新'));
      expect(first.updatedAt, isNotNull);
      expect(first.updatedAt!.year, 2026);
    });

    test('首页没有集数 —— 不得伪造：updateText 里不出现「第 N 话」', () {
      for (final MikanScheduleEntry e in s.entries) {
        expect(RegExp(r'第\s*\d+\s*[话集]').hasMatch(e.updateText), isFalse,
            reason: '首页 date-text 只有日期；集数要另取详情页，不能编');
      }
    });

    test('同一天内按 data-bangumiindex 升序（站点给的位次就是展示顺序）', () {
      for (final MapEntry<int, List<MikanScheduleEntry>> e in s.byDay.entries) {
        final idx = e.value.map((MikanScheduleEntry x) => x.index).toList();
        final sorted = List<int>.from(idx)..sort();
        expect(idx, sorted, reason: 'day=${e.key} 的 index 未按升序排列');
      }
    });

    test('displayDays 顺序是「周一→周日→剧场版→OVA」，且只含非空档', () {
      final days = s.displayDays;
      expect(days.first, 1, reason: '展示从星期一开始');
      expect(days, containsAll(<int>[1, 2, 3, 4, 5, 6, 0]));
      // 两个专档排在最后
      final unslottedPos = days.indexWhere((int d) => d > 6);
      if (unslottedPos >= 0) {
        expect(days.sublist(0, unslottedPos), isNot(contains(greaterThan(6))));
        expect(days.last, greaterThan(6));
      }
      for (final int d in days) {
        expect(s.byDay[d], isNotEmpty);
      }
    });

    test('toJson/fromJson 往返不丢关键字段（缓存还原用）', () {
      final MikanScheduleEntry src = s.entries.first;
      final back = MikanScheduleEntry.fromJson(src.toJson())!;
      expect(back.bangumiId, src.bangumiId);
      expect(back.dayOfWeek, src.dayOfWeek);
      expect(back.title, src.title);
      expect(back.coverUri, src.coverUri);
      expect(back.rawCover, src.rawCover);
      expect(back.updateText, src.updateText);
      expect(back.updatedAt, src.updatedAt);
      expect(back.index, src.index);
      expect(back.detailUrl, src.detailUrl);
    });

    test('subscribed 一律来自站点字段：真实样本里全为 false 时不得出现 true', () {
      // 抓取样本（2026-10-09）里 data-showsubscribed 全是 "false"，
      // 所以任何 true 都意味着解析器读错了属性 —— 这是「不臆造」的守卫。
      expect(s.entries.any((MikanScheduleEntry e) => e.subscribed), isFalse);
    });
  });

  group('边界（构造样本）', () {
    test('data-showsubscribed=true 要能读出来', () {
      final s = _parseTiny(_tiny(
        span: '<span data-src="/images/Bangumi/202603/x.jpg" data-bangumiid="1" '
            'data-bangumiindex="1" data-showsubscribed="true"></span>',
        anchor: '<a href="/Home/Bangumi/1" class="an-text" title="某番">某番</a>',
        date: '<div class="date-text">2026/10/05 更新</div>',
      ));
      expect(s.entries.single.subscribed, isTrue);
    });

    test('缺少 date-text → updatedAt 为 null，但不丢条目', () {
      final s = _parseTiny(_tiny(
        span: '<span data-src="/x.jpg" data-bangumiid="2"></span>',
        anchor: '<a href="/Home/Bangumi/2" class="an-text" title="无日期番">无日期番</a>',
      ));
      expect(s.entries.single.updatedAt, isNull);
      expect(s.entries.single.updateText, isEmpty);
      expect(s.entries.single.title, '无日期番');
    });

    test('title 属性优先于锚文本（站点会给完整名）', () {
      final s = _parseTiny(_tiny(
        span: '<span data-src="/x.jpg" data-bangumiid="3"></span>',
        anchor: '<a href="/Home/Bangumi/3" class="an-text" title="完整的中文番名">截断名…</a>',
      ));
      expect(s.entries.single.title, '完整的中文番名');
    });

    test('整条什么都认不出来 → 计入 skipped 并可观测（不静默丢）', () {
      const String emptyBlock = '<div class="sk-bangumi" data-dayofweek="3">'
          '<ul class="an-ul"><li><span></span></li></ul></div>';
      final s = _parseTiny('${_tiny()}$emptyBlock');
      expect(s.skipped, greaterThan(0));
      expect(s.warnings, isNotEmpty);
    });

    test('data-dayofweek 非法 → 整块跳过并记警告', () {
      final s = _parseTiny(
        '<html><body>'
        '<div class="sk-bangumi" data-dayofweek="abc"><ul class="an-ul"><li>'
        '<span data-src="/x.jpg" data-bangumiid="9"></span>'
        '<a href="/Home/Bangumi/9" class="an-text" title="坏块">坏块</a></li></ul></div>'
        '${_tiny(dayOfWeek: '5', span: '<span data-src="/y.jpg" data-bangumiid="10"></span>', anchor: '<a href="/Home/Bangumi/10" class="an-text" title="好块">好块</a>')}'
        '</body></html>',
      );
      expect(s.skipped, greaterThan(0));
      expect(s.entries.map((MikanScheduleEntry e) => e.title), contains('好块'));
      expect(s.entries.map((MikanScheduleEntry e) => e.title), isNot(contains('坏块')));
    });

    test('没有 sk-bangumi 根节点 → 抛 SourceException（不返回空表假装没更新）', () {
      expect(
        () => _parseTiny('<html><body><p>这不是追番表</p></body></html>'),
        throwsA(isA<SourceException>()),
      );
    });

    test('同一天被拆成多个 sk-bangumi 块 → 合并到同一个桶', () {
      final s = _parseTiny(
        '<html><body>'
        '${_tiny(dayOfWeek: '2', span: '<span data-src="/a.jpg" data-bangumiid="11" data-bangumiindex="2"></span>', anchor: '<a href="/Home/Bangumi/11" class="an-text" title="A">A</a>')}'
        '${_tiny(dayOfWeek: '2', span: '<span data-src="/b.jpg" data-bangumiid="12" data-bangumiindex="1"></span>', anchor: '<a href="/Home/Bangumi/12" class="an-text" title="B">B</a>')}'
        '</body></html>',
      );
      expect(s.byDay[2]!.length, 2);
      expect(s.byDay[2]!.map((MikanScheduleEntry e) => e.title), <String>['B', 'A'],
          reason: '合并后仍按 index 排序');
    });
  });

  group('更新日期解析', () {
    test('识别多种分隔符', () {
      expect(MikanScheduleParser.parseMikanUpdateDate('2026/10/05 更新'),
          DateTime(2026, 10, 5));
      expect(MikanScheduleParser.parseMikanUpdateDate('2026-10-05'),
          DateTime(2026, 10, 5));
      expect(MikanScheduleParser.parseMikanUpdateDate('2026.1.5 更新'),
          DateTime(2026, 1, 5));
    });

    test('越界日期必须返回 null（DateTime 会「归一化」而不是报错）', () {
      expect(MikanScheduleParser.parseMikanUpdateDate('2026/13/45 更新'), isNull);
      expect(MikanScheduleParser.parseMikanUpdateDate('2026/02/30 更新'), isNull);
      expect(MikanScheduleParser.parseMikanUpdateDate('2026/00/10 更新'), isNull);
    });

    test('没有日期 / 空串 → null', () {
      expect(MikanScheduleParser.parseMikanUpdateDate('更新'), isNull);
      expect(MikanScheduleParser.parseMikanUpdateDate(''), isNull);
      expect(MikanScheduleParser.parseMikanUpdateDate(null), isNull);
    });
  });
}
