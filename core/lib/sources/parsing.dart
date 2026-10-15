/// 源解析公共工具：日期 / 体积 / info hash / 磁力 / HTML 文本。
///
/// 所有函数**永不抛异常**，解析不出来一律返回 null —— 站点字段缺失是常态，
/// 调用方必须显式处理 null，而不是拿到伪造的默认值。
library;

import 'package:html/parser.dart' as html_parser;
import 'package:xml/xml.dart';

import 'models.dart';

/// feed XML 允许的根元素（RSS 2.0 = `rss`，Atom = `feed`，RSS 1.0 = `rdf:RDF`）。
const Set<String> feedRootNames = <String>{'rss', 'feed', 'rdf'};

/// 解析 feed XML，并校验根元素确实是 feed。
///
/// 两个容易踩的坑：
/// * `xml` 包的 `XmlTagException` **不是** `XmlParserException` 的子类，
///   只 catch 后者会让标签不匹配的异常漏出去 —— 这里统一 catch [XmlException]；
/// * 拿到 HTML 错误页时 XML 也可能解析成功（根元素 `<html>`），
///   若只看「有没有 item」会静默返回空列表 —— 这里显式抛错（禁止假成功）。
XmlDocument parseFeedDocument(
  String xmlText, {
  required String sourceId,
  String label = 'feed',
}) {
  final XmlDocument doc;
  try {
    doc = XmlDocument.parse(xmlText);
  } on XmlException catch (e) {
    throw SourceException(
      '$label 不是合法 XML（站点结构可能已变）: $e',
      sourceId: sourceId,
      cause: e,
    );
  }

  final root = doc.childElements.isEmpty ? null : doc.childElements.first;
  final name = root?.name.local.toLowerCase() ?? '';
  if (root == null || !feedRootNames.contains(name)) {
    final preview = xmlText.length > 80 ? '${xmlText.substring(0, 80)}…' : xmlText;
    throw SourceException(
      '$label 根元素是 <${name.isEmpty ? '空文档' : name}>，不是 rss/feed/RDF —— '
      '拿到的可能不是 feed（开头: ${preview.replaceAll(RegExp(r'\s+'), ' ')})',
      sourceId: sourceId,
    );
  }
  return doc;
}

/// 解析结果（含「丢弃了多少条」—— 丢弃必须可观测，不能悄悄发生）。
class ParseOutcome {
  const ParseOutcome({
    required this.items,
    this.hasNext = false,
    this.skipped = 0,
    this.warnings = const <String>[],
  });

  final List<SourceItem> items;
  final bool hasNext;

  /// 因缺少稳定 id 等硬性原因被丢弃的条目数。
  final int skipped;

  /// 非致命异常（例如某一行结构变了）。
  final List<String> warnings;

  @override
  String toString() =>
      'ParseOutcome(items=${items.length}, skipped=$skipped, hasNext=$hasNext)';
}

/// 折叠空白；输入为 null 或全空白时返回 null。
String? normalizeWhitespace(String? value) {
  if (value == null) return null;
  final s = value.replaceAll(RegExp(r'\s+'), ' ').trim();
  return s.isEmpty ? null : s;
}

/// 返回第一个非空的字符串（已去首尾空白）。
String? firstNonEmpty(Iterable<String?> values) {
  for (final v in values) {
    final s = normalizeWhitespace(v);
    if (s != null) return s;
  }
  return null;
}

/// 宽松整数解析：`"804"`、`"1 comment"`、`" 12 "` 都能得到数字；没有数字返回 null。
int? parseIntLoose(String? value) {
  if (value == null) return null;
  final m = RegExp(r'-?\d+').firstMatch(value.replaceAll(',', ''));
  if (m == null) return null;
  return int.tryParse(m.group(0)!);
}

const Map<String, int> _monthByName = <String, int>{
  'jan': 1,
  'feb': 2,
  'mar': 3,
  'apr': 4,
  'may': 5,
  'jun': 6,
  'jul': 7,
  'aug': 8,
  'sep': 9,
  'oct': 10,
  'nov': 11,
  'dec': 12,
};

const Map<String, int> _namedZoneOffsetMinutes = <String, int>{
  'ut': 0,
  'utc': 0,
  'gmt': 0,
  'z': 0,
  'est': -300,
  'edt': -240,
  'cst': -360,
  'cdt': -300,
  'mst': -420,
  'mdt': -360,
  'pst': -480,
  'pdt': -420,
  'jst': 540,
  'kst': 540,
  'cct': 480,
};

/// 解析 feed 里的日期字符串；无法识别返回 null（**不倒填当前时间**）。
///
/// 支持：
/// * RFC 822/1123：`Thu, 08 Oct 2026 13:18:50 -0000`、`... GMT`
/// * ISO 8601：`2026-10-08T21:18:53.451203`、`2026-10-08T13:18:50Z`
/// * `2026/10/08 21:18`、`2026-10-08 21:18:05`
/// * epoch 秒 / 毫秒（纯数字）
///
/// 语义：**带时区信息时返回 UTC 实例**；无时区信息时按站点本地时间返回非 UTC 实例
/// （mikan 的 `torrent/pubDate` 就是这种无时区的本地时间）。
DateTime? parseFeedDate(String? raw) {
  if (raw == null) return null;
  final s = raw.trim();
  if (s.isEmpty) return null;

  // epoch
  if (RegExp(r'^\d{9,13}$').hasMatch(s)) {
    final v = int.tryParse(s);
    if (v != null) {
      return s.length >= 12
          ? DateTime.fromMillisecondsSinceEpoch(v, isUtc: true)
          : DateTime.fromMillisecondsSinceEpoch(v * 1000, isUtc: true);
    }
  }

  // RFC 822 / 1123
  final rfc = RegExp(
    r'^(?:[A-Za-z]{3},\s*)?(\d{1,2})\s+([A-Za-z]{3})[A-Za-z]*\s+(\d{2,4})'
    r'\s+(\d{1,2}):(\d{2})(?::(\d{2}))?(?:\.\d+)?'
    r'(?:\s*([+-]\d{4}|[A-Za-z]{1,5}))?\s*$',
  ).firstMatch(s);
  if (rfc != null) {
    final day = int.parse(rfc.group(1)!);
    final month = _monthByName[rfc.group(2)!.toLowerCase()];
    var year = int.parse(rfc.group(3)!);
    final hour = int.parse(rfc.group(4)!);
    final minute = int.parse(rfc.group(5)!);
    final second = int.tryParse(rfc.group(6) ?? '') ?? 0;
    final zoneRaw = rfc.group(7);
    if (month == null) return null;
    if (year < 100) year += year < 70 ? 2000 : 1900;
    if (day < 1 || day > 31 || hour > 23 || minute > 59 || second > 60) {
      return null;
    }
    if (zoneRaw == null || zoneRaw.isEmpty) {
      return DateTime(year, month, day, hour, minute, second);
    }
    final offset = _zoneOffsetMinutes(zoneRaw);
    if (offset == null) return null;
    return DateTime.utc(year, month, day, hour, minute, second)
        .subtract(Duration(minutes: offset));
  }

  // ISO 8601：`2026-10-08T21:18:53.451203`、`2026-10-08T13:18:50Z`、
  // `2026-10-08 21:18`（Dart 接受空格分隔符，且保留小数秒）。
  //
  // ⚠️ `DateTime.tryParse` 对越界字段是**归一化**而不是返回 null
  // （`2026-13-45T99:99:99` → `2027-02-18 04:40:39`），必须先自己校验范围。
  if (_componentsInRange(s)) {
    final iso = DateTime.tryParse(s);
    if (iso != null) return iso;
  }

  // yyyy/MM/dd HH:mm[:ss]
  final slash = RegExp(
    r'^(\d{4})/(\d{1,2})/(\d{1,2})(?:[ T](\d{1,2}):(\d{2})(?::(\d{2}))?)?$',
  ).firstMatch(s);
  if (slash != null) {
    return _buildLocal(slash);
  }

  // yyyy-MM-dd HH:mm[:ss] 兜底（正常情况上面 ISO 分支已经命中）
  final dash = RegExp(
    r'^(\d{4})-(\d{1,2})-(\d{1,2})(?:[ T](\d{1,2}):(\d{2})(?::(\d{2}))?)?$',
  ).firstMatch(s);
  if (dash != null) {
    return _buildLocal(dash);
  }

  return null;
}

DateTime? _buildLocal(RegExpMatch m) {
  final year = int.parse(m.group(1)!);
  final month = int.parse(m.group(2)!);
  final day = int.parse(m.group(3)!);
  final hour = int.tryParse(m.group(4) ?? '') ?? 0;
  final minute = int.tryParse(m.group(5) ?? '') ?? 0;
  final second = int.tryParse(m.group(6) ?? '') ?? 0;
  if (month < 1 || month > 12 || day < 1 || day > _daysInMonth(year, month)) {
    return null;
  }
  if (hour > 23 || minute > 59 || second > 60) return null;
  return DateTime(year, month, day, hour, minute, second);
}

/// `DateTime.tryParse` 会把越界日期字段归一化，所以自己先校验一次。
///
/// 形状不认识时返回 true（交给 `DateTime.tryParse` 判断），识别得出的形状则严格校验。
bool _componentsInRange(String s) {
  final m = RegExp(
    r'^[+-]?(\d{4,6})-(\d{1,2})-(\d{1,2})'
    r'(?:[ T](\d{1,2})(?::(\d{1,2})(?::(\d{1,2})(?:[.,]\d+)?)?)?)?',
  ).firstMatch(s);
  if (m == null) return true;
  final year = int.parse(m.group(1)!);
  final month = int.parse(m.group(2)!);
  final day = int.parse(m.group(3)!);
  final hour = int.tryParse(m.group(4) ?? '') ?? 0;
  final minute = int.tryParse(m.group(5) ?? '') ?? 0;
  final second = int.tryParse(m.group(6) ?? '') ?? 0;
  if (year == 0) return false;
  if (month < 1 || month > 12) return false;
  if (day < 1 || day > _daysInMonth(year, month)) return false;
  if (hour > 23 || minute > 59 || second > 60) return false;
  return true;
}

/// 某年某月的天数（`month` 允许为 12）。
int _daysInMonth(int year, int month) => DateTime(year, month + 1, 0).day;

int? _zoneOffsetMinutes(String zone) {
  final z = zone.trim();
  if (z.isEmpty) return null;
  if (z == 'Z' || z == 'z') return 0;
  final sign = z[0];
  if (sign == '+' || sign == '-') {
    final digits = z.substring(1).replaceAll(':', '');
    if (digits.length != 4) return null;
    final h = int.tryParse(digits.substring(0, 2));
    final m = int.tryParse(digits.substring(2));
    if (h == null || m == null) return null;
    final total = h * 60 + m;
    return sign == '-' ? -total : total;
  }
  return _namedZoneOffsetMinutes[z.toLowerCase()];
}

/// 解析「今天 21:18」「昨天 21:18」「3 天前」「2 小时前」这类相对时间
/// （mikan 单集页的「发布日期」就是这样显示的）；无法识别时回落到 [parseFeedDate]。
///
/// [now] 必须由调用方传入（注入时钟），保证单测确定性。
DateTime? parseRelativeDate(String? raw, DateTime now) {
  if (raw == null) return null;
  final s = raw.replaceAll('\u00A0', ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
  if (s.isEmpty) return null;

  final hhmm = RegExp(r'(\d{1,2}):(\d{2})');
  final time = hhmm.firstMatch(s);
  int h = time == null ? 0 : int.parse(time.group(1)!);
  int m = time == null ? 0 : int.parse(time.group(2)!);
  if (h > 23 || m > 59) {
    h = 0;
    m = 0;
  }

  final dayStart = DateTime(now.year, now.month, now.day);
  if (s.contains('前天')) {
    final d = dayStart.subtract(const Duration(days: 2));
    return DateTime(d.year, d.month, d.day, h, m);
  }
  if (s.contains('昨天')) {
    final d = dayStart.subtract(const Duration(days: 1));
    return DateTime(d.year, d.month, d.day, h, m);
  }
  if (s.contains('今天') || s.contains('刚刚') || s.contains('分钟前') || s.contains('小时前')) {
    if (s.contains('分钟前')) {
      final n = parseIntLoose(s) ?? 0;
      return now.subtract(Duration(minutes: n));
    }
    if (s.contains('小时前')) {
      final n = parseIntLoose(s) ?? 0;
      return now.subtract(Duration(hours: n));
    }
    return DateTime(now.year, now.month, now.day, h, m);
  }
  final daysAgo = RegExp(r'(\d+)\s*天前').firstMatch(s);
  if (daysAgo != null) {
    final n = int.tryParse(daysAgo.group(1)!) ?? 0;
    return DateTime(now.year, now.month, now.day, h, m)
        .subtract(Duration(days: n));
  }
  return parseFeedDate(s);
}

/// 解析体积字符串（`5.6 GiB` / `252.7 MiB` / `1.2 GB` / `270.7 MB` / `1288490240`）。
///
/// 二进制单位用 1024，十进制单位用 1000（与站点显示口径一致）。
int? parseSizeToBytes(String? raw) {
  if (raw == null) return null;
  final s = raw
      .replaceAll('\u00A0', ' ')
      .replaceAll(',', '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (s.isEmpty) return null;

  final m = RegExp(r'^([0-9]+(?:\.[0-9]+)?)\s*([KMGTPE]?i?B)?$', caseSensitive: false)
      .firstMatch(s);
  if (m == null) return null;
  final value = double.tryParse(m.group(1)!);
  if (value == null) return null;

  final unit = (m.group(2) ?? 'B').toUpperCase();
  const factors = <String, double>{
    'B': 1,
    'KB': 1000,
    'MB': 1000 * 1000,
    'GB': 1000 * 1000 * 1000,
    'TB': 1000 * 1000 * 1000 * 1000,
    'PB': 1000 * 1000 * 1000 * 1000 * 1000,
    'KIB': 1024,
    'MIB': 1024 * 1024,
    'GIB': 1024 * 1024 * 1024,
    'TIB': 1024 * 1024 * 1024 * 1024,
    'PIB': 1024 * 1024 * 1024 * 1024 * 1024,
  };
  final factor = factors[unit];
  if (factor == null) return null;

  final bytes = value * factor;
  if (!bytes.isFinite || bytes < 0 || bytes > 9.2e18) return null;
  return bytes.round();
}

const String _base32Alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';

/// RFC 4648 base32（32 字符，无填充）→ 40 位小写 hex；非法返回 null。
String? base32ToHex(String value) {
  final s = value.trim().toUpperCase();
  if (s.length != 32) return null;
  var bits = 0;
  var buffer = 0;
  final out = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    final idx = _base32Alphabet.indexOf(s[i]);
    if (idx < 0) return null;
    buffer = (buffer << 5) | idx;
    bits += 5;
    if (bits >= 8) {
      bits -= 8;
      out.write(((buffer >> bits) & 0xFF).toRadixString(16).padLeft(2, '0'));
    }
  }
  final hex = out.toString();
  return hex.length == 40 ? hex : null;
}

/// 归一化 info hash：接受 40 位 hex 或 32 位 base32，统一输出 40 位小写 hex。
String? normalizeInfoHash(String? raw) {
  if (raw == null) return null;
  final s = raw.trim();
  if (s.isEmpty) return null;
  if (RegExp(r'^[0-9a-fA-F]{40}$').hasMatch(s)) return s.toLowerCase();
  if (RegExp(r'^[A-Za-z2-7]{32}$').hasMatch(s)) return base32ToHex(s);
  return null;
}

final RegExp _magnetPattern =
    RegExp(r'''magnet:\?[^\s"'<>\\]+''', caseSensitive: false);

/// 从任意文本（CDATA / HTML / 纯文本）里提取磁力链接。
///
/// 优先原样匹配（顺手把 `&amp;` 还原），失败再把 HTML 转成纯文本重试。
/// 返回的链接保证 `xt=urn:btih:` 是合法的 hex 或 base32。
String? extractMagnet(String? text) {
  if (text == null || text.isEmpty) return null;

  final direct = _firstValidMagnet(text.replaceAll('&amp;', '&'));
  if (direct != null) return direct;

  if (text.contains('<') || text.contains('&')) {
    final plain = htmlToPlainText(text).replaceAll('&amp;', '&');
    if (plain != text) {
      final fromPlain = _firstValidMagnet(plain);
      if (fromPlain != null) return fromPlain;
    }
  }
  return null;
}

String? _firstValidMagnet(String text) {
  for (final m in _magnetPattern.allMatches(text)) {
    final candidate = m.group(0);
    if (candidate == null) continue;
    if (infoHashFromMagnet(candidate) != null) return candidate;
  }
  return null;
}

/// 从磁力链接里取 info hash（40 hex 或 32 base32 均可）。
String? infoHashFromMagnet(String? magnet) {
  if (magnet == null || magnet.isEmpty) return null;
  final m = RegExp(r'xt=urn:btih:([0-9A-Za-z]{32,40})', caseSensitive: false)
      .firstMatch(magnet);
  if (m == null) return null;
  return normalizeInfoHash(m.group(1));
}

/// 磁力链接里的 `xt=urn:btih:` 统一改写成 40 位 hex，**其余参数原样保留**。
///
/// 为什么需要它（dmhy 源，2026-10-12）：动漫花园列表页那条**带 20 多个 tracker**
/// 的 `a.arrow-magnet` 用的是 32 位 base32 infohash，而同一行的
/// `a.download-xl[data-magnet]` 是 40 位 hex、**却不带任何 tracker**。
/// 两者是同一个 infohash；引擎侧（rqbit）对 base32 的支持没有把握，hex 才是各家通用写法。
/// base32 → hex 是**精确换算**（[base32ToHex] 按位重排，不引入任何猜测），
/// 所以这里"换 xt、留 tracker"，既不丢 tracker 又不把不确定性丢给引擎。
///
/// 返回 null = 这段文本里没有可识别的 `btih`（调用方据此决定要不要换一条磁力）。
/// 已经是 hex 时**原样返回**。
String? magnetWithHexInfoHash(String? magnet) {
  if (magnet == null) return null;
  final s = magnet.trim();
  if (s.isEmpty) return null;
  final m = RegExp(r'xt=urn:btih:([0-9A-Za-z]{32,40})', caseSensitive: false)
      .firstMatch(s);
  if (m == null) return null;
  final whole = m.group(0)!;
  final raw = m.group(1)!;
  if (RegExp(r'^[0-9a-fA-F]{40}$').hasMatch(raw)) return s;
  final hex = normalizeInfoHash(raw);
  if (hex == null) return null;
  // 只换 hash 本身：`xt=urn:btih:` 那段照抄原文（大小写不动），
  // 后面的 `&dn=` / `&tr=` 一个都不碰。
  final prefix = whole.substring(0, whole.length - raw.length);
  return s.replaceRange(m.start, m.end, '$prefix$hex');
}

/// HTML → 纯文本（去标签 + 解实体）。解析失败时退化为正则去标签。
String htmlToPlainText(String html) {
  if (html.isEmpty) return '';
  try {
    final fragment = html_parser.parseFragment(html);
    final text = fragment.text;
    if (text != null) return text.trim();
  } catch (_) {
    // 交给下面的正则兜底
  }
  return stripTags(html).trim();
}

/// 正则去标签 + 解常见实体（`html` 包不可用时使用）。
///
/// 注意：Dart 的 RegExp **不支持内联 `(?s)` 标记**（会抛 FormatException），
/// 跨行匹配必须用 `dotAll: true`。
String stripTags(String html) {
  return html
      .replaceAll(
        RegExp(r'<script.*?</script>', caseSensitive: false, dotAll: true),
        ' ',
      )
      .replaceAll(
        RegExp(r'<style.*?</style>', caseSensitive: false, dotAll: true),
        ' ',
      )
      .replaceAll(RegExp(r'<[^>]*>', dotAll: true), ' ')
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}

/// 相对 URL → 绝对 URL；无法解析返回 null。
Uri? resolveUri(Uri? base, String? href) {
  if (href == null) return null;
  final s = href.trim();
  if (s.isEmpty) return null;
  final parsed = Uri.tryParse(s);
  if (parsed == null) return null;
  if (parsed.hasScheme || base == null) return parsed;
  return base.resolveUri(parsed);
}
