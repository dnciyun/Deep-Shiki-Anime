/// 解析工具单测（日期 / 体积 / info hash / 磁力 / HTML 文本）。
///
/// 全部离线，使用 `test/fixtures/` 下的真实站点片段与合成边界样本。
library;

import 'package:dsanima_core/sources/sources.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('parseFeedDate', () {
    test('RFC 822 带 -0000 时区 → UTC 实例', () {
      final d = parseFeedDate('Thu, 08 Oct 2026 13:18:50 -0000');
      expect(d, isNotNull);
      expect(d!.isUtc, isTrue);
      expect(d, DateTime.utc(2026, 10, 8, 13, 18, 50));
    });

    test('RFC 822 带 +0800 时区 → 换算到 UTC', () {
      final d = parseFeedDate('Thu, 08 Oct 2026 13:18:50 +0800');
      expect(d, DateTime.utc(2026, 10, 8, 5, 18, 50));
    });

    test('RFC 822 无时区 → 站点本地时间（非 UTC）', () {
      final d = parseFeedDate('Thu, 08 Oct 2026 13:18:50');
      expect(d, isNotNull);
      expect(d!.isUtc, isFalse);
      expect(d.year, 2026);
      expect(d.month, 10);
      expect(d.day, 8);
      expect(d.hour, 13);
    });

    test('mikan 的 ISO 本地时间保留小数秒', () {
      final d = parseFeedDate('2026-10-08T21:18:53.451203');
      expect(d, isNotNull);
      expect(d!.isUtc, isFalse);
      expect(d, DateTime(2026, 10, 8, 21, 18, 53, 451, 203));
    });

    test('ISO 带 Z 时区', () {
      expect(parseFeedDate('2026-10-08T13:18:50Z'),
          DateTime.utc(2026, 10, 8, 13, 18, 50));
    });

    test('nyaa 列表页 data-timestamp 的 epoch 秒', () {
      final d = parseFeedDate('1774623653');
      expect(d, isNotNull);
      expect(d!.isUtc, isTrue);
      expect(d.millisecondsSinceEpoch, 1774623653000);
      expect(d.toIso8601String(), startsWith('2026-03-27T15:00:53'));
    });

    test('mikan 番剧页的 yyyy/MM/dd HH:mm', () {
      final d = parseFeedDate('2026/10/08 21:18');
      expect(d, DateTime(2026, 10, 8, 21, 18));
    });

    test('非法日期一律 null（不回落当前时间）', () {
      expect(parseFeedDate('昨天下午'), isNull);
      expect(parseFeedDate('2026-13-45T99:99:99'), isNull);
      expect(parseFeedDate('Thu, 08 Xxx 2026 13:18:50 -0000'), isNull);
      expect(parseFeedDate(''), isNull);
      expect(parseFeedDate('   '), isNull);
      expect(parseFeedDate(null), isNull);
      expect(parseFeedDate('99/99/9999'), isNull);
      expect(parseFeedDate('2026-02-31T10:00:00'), isNull); // tryParse 会归一化成 3/3
    });
  });

  group('parseRelativeDate（mikan 单集页「发布日期：今天 21:18」）', () {
    final now = DateTime(2026, 10, 8, 22, 0);

    test('今天/昨天/前天', () {
      expect(parseRelativeDate('今天 21:18', now), DateTime(2026, 10, 8, 21, 18));
      expect(parseRelativeDate('昨天 21:18', now), DateTime(2026, 10, 7, 21, 18));
      expect(parseRelativeDate('前天 23:00', now), DateTime(2026, 10, 6, 23, 0));
    });

    test('N 天前 / N 小时前 / N 分钟前', () {
      expect(parseRelativeDate('3 天前', now), DateTime(2026, 10, 5, 0, 0));
      expect(parseRelativeDate('2 小时前', now), DateTime(2026, 10, 8, 20, 0));
      expect(parseRelativeDate('30 分钟前', now), DateTime(2026, 10, 8, 21, 30));
    });

    test('识别不了就回落 parseFeedDate / null', () {
      expect(parseRelativeDate('2026/10/08 21:18', now), DateTime(2026, 10, 8, 21, 18));
      expect(parseRelativeDate('某个说不清的时间', now), isNull);
      expect(parseRelativeDate(null, now), isNull);
    });
  });

  group('parseSizeToBytes', () {
    test('二进制单位 GiB/MiB', () {
      expect(parseSizeToBytes('5.6 GiB'), 6012954214);
      expect(parseSizeToBytes('252.7 MiB'), 264975155);
      expect(parseSizeToBytes('1.4 GiB'), 1503238554);
      expect(parseSizeToBytes('11.4GiB'), 12240656794); // 11.4 * 1024^3
    });

    test('十进制单位 GB/MB（nyaa/mikan 混用两种口径）', () {
      expect(parseSizeToBytes('1.2 GB'), 1200000000);
      expect(parseSizeToBytes('270.7 MB'), 270700000);
      expect(parseSizeToBytes('1.2GB'), 1200000000);
    });

    test('纯字节数与千分位', () {
      expect(parseSizeToBytes('1288490240'), 1288490240);
      expect(parseSizeToBytes('1,234,567'), 1234567);
      expect(parseSizeToBytes('283864064'), 283864064);
    });

    test('不识别的输入 → null', () {
      expect(parseSizeToBytes('很大'), isNull);
      expect(parseSizeToBytes('-5 MB'), isNull);
      expect(parseSizeToBytes(''), isNull);
      expect(parseSizeToBytes(null), isNull);
      expect(parseSizeToBytes('12 XB'), isNull);
    });
  });

  group('info hash 归一化（hex / base32）', () {
    test('40 位 hex 统一小写', () {
      expect(normalizeInfoHash('3A1CBCFC711BB7A21F2741433119773C23AC081D'),
          '3a1cbcfc711bb7a21f2741433119773c23ac081d');
    });

    test('32 位 base32 → 40 位 hex（真实 dmhy feed 的 enclosure）', () {
      expect(base32ToHex('FCEBW3EH7SPCQAOGGTKKGXMRV7D7EXRO'),
          '28881b6c87fc9e2801c634d4a35d91afc7f25e2e');
      expect(normalizeInfoHash('ARNWOT3O47XFM4DCDO4ZIQDQIUHK4CI6'),
          '045b674f6ee7ee5670621bb9944070450eae091e');
    });

    test('非法输入 → null', () {
      expect(normalizeInfoHash('zzz'), isNull);
      expect(normalizeInfoHash('3a1cbcfc711bb7a21f2741433119773c23ac081'), isNull);
      expect(normalizeInfoHash('FCEBW3EH7SPCQAOGGTKKGXMRV7D7EXR'), isNull);
      expect(normalizeInfoHash('FCEBW3EH7SPCQAOGGTKKGXMRV7D7EXR0'), isNull);
      expect(normalizeInfoHash(null), isNull);
    });
  });

  group('磁力提取', () {
    test('HTML 属性里的 &amp; 会被还原', () {
      const html =
          '<a href="magnet:?xt=urn:btih:bd167d148570f2c7ece6c15bd90d3901acb6d79c&amp;dn=x&amp;tr=http%3A%2F%2Fa">m</a>';
      final magnet = extractMagnet(html);
      expect(magnet, isNotNull);
      expect(magnet, contains('xt=urn:btih:bd167d148570f2c7ece6c15bd90d3901acb6d79c'));
      expect(magnet, contains('&dn=x&tr='));
    });

    test('CDATA 纯文本里的磁力', () {
      const cdata =
          '前言\nmagnet:?xt=urn:btih:979729c737fbed10e72ef82690b6aaea7beaa23b\n后记';
      expect(infoHashFromMagnet(extractMagnet(cdata)),
          '979729c737fbed10e72ef82690b6aaea7beaa23b');
    });

    test('base32 磁力也能识别', () {
      final magnet = extractMagnet(
          'magnet:?xt=urn:btih:FCEBW3EH7SPCQAOGGTKKGXMRV7D7EXRO&dn=&tr=udp://x');
      expect(infoHashFromMagnet(magnet),
          '28881b6c87fc9e2801c634d4a35d91afc7f25e2e');
    });

    test('没有合法 btih 的 magnet 视为无效 → null', () {
      expect(extractMagnet('magnet:?xt=urn:btih:zzz&dn=x'), isNull);
      expect(extractMagnet('这件事没有磁力链接'), isNull);
      expect(extractMagnet(null), isNull);
      expect(extractMagnet(''), isNull);
    });
  });

  group('magnetWithHexInfoHash（dmhy 的 base32 磁力换 hex）', () {
    test('base32 换 hex，tracker 一个不少', () {
      const raw =
          'magnet:?xt=urn:btih:7BSRIRFCYCZ767R5UPF5OXNFR327BHQZ&dn=&tr=udp%3A%2F%2Fa&tr=http%3A%2F%2Fb';
      final out = magnetWithHexInfoHash(raw);
      expect(out, isNotNull);
      expect(out, contains('xt=urn:btih:f8651444a2c0b3ff7e3da3cbd75da58ef5f09e19'));
      expect(out, isNot(contains('7BSRIRFCYCZ767R5UPF5OXNFR327BHQZ')));
      expect('&tr='.allMatches(out!).length, 2);
    });

    test('本来就是 hex → 原样返回（连大小写都不动）', () {
      const raw = 'magnet:?xt=urn:btih:F8651444A2C0B3FF7E3DA3CBD75DA58EF5F09E19&dn=x';
      expect(magnetWithHexInfoHash(raw), raw);
    });

    test('没有可识别的 btih → null（调用方据此换一条磁力）', () {
      expect(magnetWithHexInfoHash('magnet:?xt=urn:btih:zzz&dn=x'), isNull);
      expect(magnetWithHexInfoHash('https://example.com/x.torrent'), isNull);
      expect(magnetWithHexInfoHash(null), isNull);
      expect(magnetWithHexInfoHash('   '), isNull);
    });
  });

  group('HTML 文本', () {
    test('htmlToPlainText 去标签解实体', () {
      expect(
        htmlToPlainText('<a href="http://x">#2171210 | 标题 | 5.6 GiB</a>'),
        '#2171210 | 标题 | 5.6 GiB',
      );
    });

    test('stripTags 的 dotAll 回归（Dart 不支持内联 (?s)，曾会抛 FormatException）',
        () {
      const html = '<script>\nvar a = "<b>";\n</script>\n<p>hello&nbsp;world &amp; more</p>';
      final text = stripTags(html);
      expect(text, contains('hello world & more'));
      expect(text, isNot(contains('<p>')));
    });
  });

  group('杂项', () {
    test('normalizeWhitespace / firstNonEmpty / parseIntLoose', () {
      expect(normalizeWhitespace('  a\n\tb '), 'a b');
      expect(normalizeWhitespace('   '), isNull);
      expect(firstNonEmpty(<String?>[null, '  ', 'x', 'y']), 'x');
      expect(firstNonEmpty(<String?>[null, '']), isNull);
      expect(parseIntLoose('804'), 804);
      expect(parseIntLoose('1 comment'), 1);
      expect(parseIntLoose('没有数字'), isNull);
      expect(parseIntLoose(null), isNull);
    });

    test('resolveUri 相对/绝对/非法', () {
      final base = Uri.parse('https://nyaa.si/');
      expect(resolveUri(base, '/view/1')?.toString(), 'https://nyaa.si/view/1');
      expect(resolveUri(base, 'https://x/y')?.toString(), 'https://x/y');
      expect(resolveUri(base, null), isNull);
      expect(resolveUri(base, '   '), isNull);
    });
  });
}
