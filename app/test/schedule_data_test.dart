/// 主页数据层测试：core 追番表 → 宿主视图模型、封面缓存的文件名/格式判定、
/// 番名匹配（纯函数）。**全程离线**。
///
/// 这里用的是 core 的**真实抓取 fixture**（2026-10-09 mikan 首页原文）→ 走真解析器 →
/// 再过一次宿主的映射函数，所以覆盖的是「真数据长什么样」而不是手编的假结构。
library;

import 'dart:convert';
import 'dart:io';

import 'package:dsanima/domain/models.dart';
import 'package:dsanima/domain/title_match.dart';
import 'package:dsanima/state/cover_cache.dart';
import 'package:dsanima/state/host_data.dart';
import 'package:dsanima_core/dsanima_core.dart' as core;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

final File _homeFixture =
    File('../core/test/fixtures/mikan_home_schedule.html');

/// 真实 WebP（mikan 图床实测返回的就是它，不是 jpg）。
final File _webpFixture = File('test/fixtures/cover_3887.webp');

void main() {
  group('core MikanSchedule → 宿主 ScheduleView（真实 fixture）', () {
    late core.MikanSchedule raw;
    late ScheduleView view;

    setUpAll(() {
      expect(_homeFixture.existsSync(), isTrue,
          reason: '缺 fixture ${_homeFixture.path}（core 的真实抓取样本）');
      raw = core.MikanScheduleParser.parse(
        _homeFixture.readAsStringSync(),
        url: Uri.parse('https://mikanani.me/'),
        sourceId: 'mikan',
      );
      view = toScheduleView(raw, fetchedAt: DateTime(2026, 10, 9, 12));
    });

    test('条目数、分组、fetchedAt、skipped 逐项搬运', () {
      expect(view.total, raw.entries.length);
      expect(view.total, greaterThan(50), reason: '真实首页有一百多条');
      expect(view.skipped, raw.skipped);
      expect(view.fetchedAt, DateTime(2026, 10, 9, 12));
      for (final int dow in raw.byDay.keys) {
        expect(view.day(dow).length, raw.byDay[dow]!.length,
            reason: '星期 $dow 的条目数必须一致');
      }
    });

    test('展示顺序：周一 → 周日 → 剧场版 → OVA，且只含非空的档', () {
      final List<int> days = view.displayDays;
      expect(days, isNotEmpty);
      // 前 7 个（若存在）必须按 1..6,0 的顺序
      final List<int> weekPart = days.where((int d) => d <= 6).toList();
      expect(weekPart, <int>[1, 2, 3, 4, 5, 6, 0].where(weekPart.contains).toList());
      // 两个专档排在最后
      final List<int> unslotted = days.where((int d) => d > 6).toList();
      expect(days.sublist(days.length - unslotted.length), unslotted);
    });

    test('封面/更新日期/详情链接逐字段搬运；两个专档条目保留', () {
      final ScheduleEntryView first = view.day(1).first;
      expect(first.bangumiId, isNotEmpty);
      expect(first.title, isNotNull);
      expect(first.coverUrl, isNotNull);
      expect(first.coverUrl, contains('/images/Bangumi/'));
      expect(first.coverUrl, contains('format=webp'),
          reason: '图床 URL 的 format 参数要原样保留');
      expect(first.detailUrl.toString(), contains('/Home/Bangumi/'));
      expect(first.updateLabel, contains('更新'));
      expect(first.isUnslotted, isFalse);
      expect(first.dayLabel, '周一');

      final List<ScheduleEntryView> unslotted =
          view.entries.where((ScheduleEntryView e) => e.isUnslotted).toList();
      expect(unslotted, isNotEmpty, reason: '真实首页有专档（dow 7=剧场版 / 8=OVA）条目');
      // 第二十五轮：名字照抄站点自己的 tab（以前两个都写「未定档」）。
      expect(unslotted.first.dayLabel, anyOf('剧场版', 'OVA'));
    });

    test('封面缺失 → coverUrl 为 null（UI 才能降级成灰框），不编造 URL', () {
      final core.MikanSchedule synthetic = core.MikanSchedule(
        entries: <core.MikanScheduleEntry>[
          const core.MikanScheduleEntry(
            bangumiId: '9999',
            dayOfWeek: 3,
            title: '没有封面的番',
            coverUri: null,
            rawCover: '',
            updateText: '',
          ),
        ],
        byDay: <int, List<core.MikanScheduleEntry>>{
          3: <core.MikanScheduleEntry>[
            const core.MikanScheduleEntry(
              bangumiId: '9999',
              dayOfWeek: 3,
              title: '没有封面的番',
              coverUri: null,
              rawCover: '',
              updateText: '',
            ),
          ],
        },
      );
      final ScheduleView mapped = toScheduleView(synthetic);
      expect(mapped.day(3).single.coverUrl, isNull);
      expect(mapped.day(3).single.title, '没有封面的番');
      // 更新文案与日期都没有 → 空串（不编一个日期出来）
      expect(mapped.day(3).single.updateLabel, '');
      expect(mapped.day(3).single.updatedAt, isNull);
    });
  });

  group('封面落盘：文件名与格式判定（不联网）', () {
    test('真实 WebP 文件头 → webp（mikan 的 format=webp 是真 WebP）', () {
      expect(_webpFixture.existsSync(), isTrue,
          reason: '缺素材 ${_webpFixture.path}');
      final List<int> head = _webpFixture.readAsBytesSync().sublist(0, 16);
      expect(String.fromCharCodes(head.sublist(0, 4)), 'RIFF');
      expect(String.fromCharCodes(head.sublist(8, 12)), 'WEBP');
      expect(imageExtensionOf(head), 'webp');
    });

    test('各格式文件头 → 正确扩展名；不是图片 → null（不落盘、不污染缓存）', () {
      expect(imageExtensionOf(<int>[0xFF, 0xD8, 0xFF, 0xE0]), 'jpg');
      expect(
          imageExtensionOf(<int>[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]),
          'png');
      expect(imageExtensionOf(<int>[0x47, 0x49, 0x46, 0x38, 0x39, 0x61]), 'gif');
      expect(imageExtensionOf(<int>[0x42, 0x4D, 0x00, 0x00]), 'bmp');
      expect(imageExtensionOf(utf8.encode('<html>403 Forbidden</html>')), isNull);
      expect(imageExtensionOf(<int>[]), isNull);
      expect(imageExtensionOf(<int>[0x00, 0x01, 0x02]), isNull);
    });

    test('缓存文件名稳定、可复现、URL 安全，且不同 URL 不撞车', () {
      const String a =
          'https://mikanani.me/images/Bangumi/202603/x.jpg?width=400&format=webp';
      const String b =
          'https://mikanani.me/images/Bangumi/202603/y.jpg?width=400&format=webp';
      final String stemA = coverCacheStem(a);
      expect(coverCacheStem(a), stemA, reason: '同一个 URL 必须永远算出同一个文件名');
      expect(coverCacheStem(b), isNot(stemA));
      expect(RegExp(r'^[A-Za-z0-9_\-]+$').hasMatch(stemA), isTrue,
          reason: 'base64url 字符集，Windows 文件名安全');
      expect(stemA.length, lessThan(181));
      // 超长 URL 走哈希兜底，也是安全的短名字
      final String long = coverCacheStem('https://x.test/${'a' * 400}');
      expect(RegExp(r'^fnv[0-9a-f]{8}$').hasMatch(long), isTrue);
    });

    test('封面缓存有 7 天保鲜期（spec §7.7）：过期的文件按 miss 处理', () async {
      final Directory dir =
          await Directory.systemTemp.createTemp('dsanima_cover_test_');
      addTearDown(() async => dir.delete(recursive: true));
      // ⚠️ 这一条以前有个**会随真实日期变红**的坑（2026-10-13 实测踩到）：
      // 文件 mtime 用"写文件的真实时刻"，而 clock 是写死的 2026-10-20 ——
      // 真实日期一旦走到 2026-10-13，差值正好 7 天、"超过 7 天"不成立 → 判成新鲜 → 红。
      // 所以这里**显式设定 mtime**，让"新鲜/过期"只由测试自己决定。
      const String url = 'https://cover-cache.invalid/images/Bangumi/x.jpg';
      final File cached =
          File(p.join(dir.path, '${coverCacheStem(url)}.jpg'));
      await cached.writeAsBytes(<int>[0xFF, 0xD8, 0xFF, 0xE0], flush: true);
      await cached.setLastModified(DateTime(2026, 10, 10));

      DateTime now = DateTime(2026, 10, 10);
      final HttpCoverCache fresh = HttpCoverCache(cacheDir: dir, clock: () => now);
      expect(await fresh.fileFor(url), isNotNull, reason: '刚写的文件命中');

      now = DateTime(2026, 10, 20); // 10 天后
      final HttpCoverCache stale = HttpCoverCache(
          cacheDir: dir, clock: () => now);
      // 过期 → 会去下载。主机名是 `.invalid`（RFC 2606 保留，永远解析不了），
      // 所以这条路径**不依赖真实网络**：下载失败 → null，而不是拿旧文件充数。
      expect(await stale.fileFor(url), isNull);
    });
  });

  group('番名匹配（保守，宁缺毋滥）', () {
    test('归一化：去空白/标点/括号，转小写', () {
      expect(normalizeTitleForMatch('葬送的芙莉莲 第二季'), '葬送的芙莉莲第二季');
      expect(normalizeTitleForMatch('[ANi] Frieren - 01 [1080p]'), 'anifrieren011080p');
      expect(normalizeTitleForMatch(null), '');
      expect(normalizeTitleForMatch('   '), '');
    });

    test('引擎里的 torrent 名包含番名 → 命中「已缓存」', () {
      expect(
          anyTitleContains(
              <String>['[ANi] 葬送的芙莉莲 第二季 - 01 [1080p]'], '葬送的芙莉莲 第二季'),
          isTrue);
      // 番名对不上（另一部番）→ 不命中
      expect(anyTitleContains(<String>['[ANi] 迷宫饭 - 01'], '葬送的芙莉莲'), isFalse);
    });

    test('太短的番名/标题一律不参与匹配（`01`、`SP` 会误命中）', () {
      expect(normalizeTitleForMatch('01').length, 2);
      expect(titleContained('xxx 01 xxx', '01'), isFalse);
      expect(titleContained('xxx SP xxx', 'SP'), isFalse);
      expect(anyTitleContains(<String>['anything'], '01'), isFalse);
      // 3 个字以上才允许
      expect(titleContained('[组] 迷宫饭 - 01', '迷宫饭'), isTrue);
    });

    test('同一自然日判定（今日更新角标）', () {
      expect(isSameCalendarDay(DateTime(2026, 10, 7, 23, 59), DateTime(2026, 10, 7)),
          isTrue);
      expect(isSameCalendarDay(DateTime(2026, 10, 6, 23, 59), DateTime(2026, 10, 7)),
          isFalse);
      expect(isSameCalendarDay(null, DateTime(2026, 10, 7)), isFalse);
    });
  });

  group('星期键口径', () {
    test('0=周日 … 6=周六，与 core 的 byDay 一致；7=剧场版 / 8=OVA', () {
      // 2026-10-07 是星期三
      expect(dsTodayDow(DateTime(2026, 10, 7)), 3);
      // 2026-10-11 是星期日 → 0（不是 7）
      expect(dsTodayDow(DateTime(2026, 10, 11)), 0);
      expect(dsTodayDow(DateTime(2026, 10, 12)), 1);
      expect(dsWeekdayLabel(3), '周三');
      expect(dsWeekdayLabel(0), '周日');
      // 第二十五轮：7/8 是 mikan 的两个专档，名字照抄站点 tab（以前是「未定档」）。
      expect(dsWeekdayLabel(7), '剧场版');
      expect(dsWeekdayLabel(8), 'OVA');
      // 其它越界值（占位 dow）仍回落成「未定档」，不抛 RangeError。
      expect(dsWeekdayLabel(9), '未定档');
      expect(dsWeekdayLabel(-1), '未定档');
    });
  });
}
