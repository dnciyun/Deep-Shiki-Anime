/// 自定义 RSS / Atom 订阅源（spec §4.2）。
///
/// 解析能力：
/// * RSS 2.0 与 Atom（`item` / `entry`、`link` / `link@href`、`pubDate` /
///   `published` / `updated`）；
/// * `enclosure`（优先 `application/x-bittorrent`，也接受 url 直接是 magnet）；
/// * `content:encoded` / `description` / `summary` / `content` 里的
///   `magnet:?xt=urn:btih:<40hex|32base32>` 正则兜底；
/// * mikan 扩展命名空间 `torrent/{link,contentLength,pubDate}`；
/// * ezrss `torrent:infoHash` / `torrent:contentLength`、`media:content@fileSize`。
///
/// `id = 'rss:<feedId>:<guid>'`；同一订阅重复抓取**按 id 去重**（spec 要求）。
///
/// 站点抓取样本：`core/test/fixtures/generic_dmhy.xml`（enclosure 是 base32 磁力、
/// description 里含 magnet）、`core/test/fixtures/generic_acgrip.xml`
/// （`torrent:contentLength` + `media:content@fileSize`）。均为 2026-10-08 抓取。
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:xml/xml.dart';

import '../subs/title_parser.dart';
import 'cache.dart';
import 'http.dart';
import 'models.dart';
import 'parsing.dart';
import 'source_client.dart';

class RssSource extends CachedSourceClient {
  RssSource({
    required this.feedId,
    required this.feedUrl,
    required super.http,
    required super.cache,
    String? displayName,
    super.clock,
  }) : displayName = displayName ?? 'RSS（$feedId）';

  /// 订阅 id（`sourceId` = `rss:<feedId>`）。
  final String feedId;

  /// feed URL。
  final Uri feedUrl;

  /// 展示名（未提供时用 `RSS（<feedId>）`）。
  @override
  final String displayName;

  @override
  String get id => 'rss:$feedId';

  /// 通用 RSS 没有统一的搜索接口（spec §4.2）。
  @override
  bool get supportsSearch => false;

  @override
  Future<SourcePage> latest({int page = 1}) async {
    if (page < 1) {
      throw SourceException('page 必须 >= 1（收到 $page）', sourceId: id);
    }
    if (page > 1) {
      // 通用 feed 没有分页参数：空页 + hasNext=false，不伪造数据。
      return SourcePage.empty(page: page, fetchedAt: clock());
    }
    return loadPage(
      request: const CacheRequest.latest(),
      fetch: () async {
        final body = await http.getText(feedUrl, sourceId: id);
        final outcome = RssParser.parse(
          body,
          feedId: feedId,
          sourceId: id,
          clock: clock,
        );
        return SourcePage(
          items: outcome.items,
          hasNext: false,
          page: 1,
          fetchedAt: clock(),
        );
      },
    );
  }

  /// 通用 RSS 不支持搜索 —— 抛明确异常，**不返回空列表假装成功**。
  @override
  Future<SourcePage> search(String keyword, {int page = 1}) async {
    throw SourceException(
      '自定义 RSS 订阅（$id）不支持关键字搜索：请改用 nyaa / mikan 源，'
      '或直接在订阅页查看该 feed 的最新条目',
      sourceId: id,
      url: feedUrl,
    );
  }
}

/// 通用 RSS/Atom 解析器。
class RssParser {
  const RssParser._();

  static ParseOutcome parse(
    String xmlText, {
    required String feedId,
    required String sourceId,
    required ClockFn clock,
  }) {
    final doc = parseFeedDocument(xmlText, sourceId: sourceId, label: 'RSS');

    var nodes = doc.findAllElements('item').toList(growable: false);
    if (nodes.isEmpty) {
      nodes = doc.findAllElements('entry').toList(growable: false);
    }

    final items = <SourceItem>[];
    final seen = <String>{};
    var skipped = 0;
    var duplicates = 0;
    final warnings = <String>[];

    for (final node in nodes) {
      final title = _entryTitle(node);
      final link = _entryLink(node);
      final guid = firstNonEmpty(<String?>[
        _childText(node, 'guid'),
        _childText(node, 'id'),
      ]);
      final torrentNode = _childElement(node, 'torrent');

      final identity = guid ?? link ?? title;
      if (identity == null) {
        skipped++;
        continue;
      }
      final id = 'rss:$feedId:${guid ?? identity}';
      if (!seen.add(id)) {
        duplicates++;
        continue;
      }

      final enclosure = _bitTorrentEnclosure(node);
      final enclosureUrl = enclosure?.getAttribute('url');
      final enclosureType = enclosure?.getAttribute('type');
      final enclosureLength = parseIntLoose(enclosure?.getAttribute('length'));

      final contentText = firstNonEmpty(<String?>[
        _childText(node, 'encoded'),
        _childText(node, 'content'),
        _childText(node, 'description'),
        _childText(node, 'summary'),
      ]);

      final magnet = _pickMagnet(<String?>[
        enclosureUrl,
        extractMagnet(contentText),
      ]);
      final torrentUrl = _pickTorrentUrl(<String?>[
        enclosureUrl,
        _childText(torrentNode, 'link'),
        _atomEnclosureHref(node),
      ]);

      final infoHash = firstNonEmpty(<String?>[
        normalizeInfoHash(_childText(node, 'infoHash')),
        infoHashFromMagnet(magnet),
      ]);

      final sizeBytes = parseIntLoose(_childText(node, 'contentLength')) ??
          enclosureLength ??
          parseIntLoose(_childText(node, 'length')) ??
          _mediaFileSize(node) ??
          _sizeFromTitle(title);

      final publishedAt = parseFeedDate(firstNonEmpty(<String?>[
        _childText(torrentNode, 'pubDate'),
        _childText(node, 'pubDate'),
        _childText(node, 'published'),
        _childText(node, 'updated'),
        _childText(node, 'date'),
      ]));

      final parsed = TitleParser.parse(title ?? '', sourceId: sourceId);

      items.add(SourceItem(
        id: id,
        sourceId: sourceId,
        title: title,
        detailUrl: resolveUri(null, link),
        torrentUrl: torrentUrl,
        magnet: magnet,
        infoHash: infoHash,
        sizeBytes: sizeBytes,
        publishedAt: publishedAt,
        category: firstNonEmpty(<String?>[
          _childText(node, 'category'),
        ]),
        group: parsed.group,
        episodeHints: parsed.episodeHints,
        extra: <String, dynamic>{
          ...parsed.toExtra(),
          'guid': ?guid,
          'enclosureType': ?enclosureType,
          'enclosureLength': ?enclosureLength,
          if (contentText != null) 'contentPreview': _preview(contentText),
        },
      ));
    }

    if (duplicates > 0) {
      warnings.add('同一 feed 里 $duplicates 条重复条目已按 id 去重');
    }
    if (items.isEmpty && nodes.isEmpty) {
      warnings.add('feed 里没有任何 item/entry（空 feed 是合法结果，不是错误）');
    }

    return ParseOutcome(
      items: items,
      skipped: skipped,
      warnings: warnings,
    );
  }

  static String? _entryTitle(XmlElement node) {
    final raw = _childText(node, 'title');
    if (raw == null) return null;
    final type = _childElement(node, 'title')?.getAttribute('type');
    if (type == 'html' || raw.contains('<')) {
      return normalizeWhitespace(htmlToPlainText(raw)) ?? raw;
    }
    return raw;
  }

  static String? _entryLink(XmlElement node) {
    // Atom：<link rel="alternate" href="…" />
    for (final child in node.childElements) {
      if (child.name.local != 'link') continue;
      final href = child.getAttribute('href');
      if (href == null || href.isEmpty) continue;
      final rel = child.getAttribute('rel');
      if (rel == null || rel == 'alternate') return normalizeWhitespace(href);
    }
    return _childText(node, 'link');
  }

  static String? _atomEnclosureHref(XmlElement node) {
    for (final child in node.childElements) {
      if (child.name.local != 'link') continue;
      if (child.getAttribute('rel') != 'enclosure') continue;
      final href = child.getAttribute('href');
      if (href != null && href.isNotEmpty) return normalizeWhitespace(href);
    }
    return null;
  }

  /// 优先 `application/x-bittorrent` 的 enclosure；否则取第一个像种子的。
  static XmlElement? _bitTorrentEnclosure(XmlElement node) {
    XmlElement? fallback;
    for (final child in node.childElements) {
      if (child.name.local != 'enclosure') continue;
      final url = child.getAttribute('url');
      if (url == null || url.isEmpty) continue;
      final type = (child.getAttribute('type') ?? '').toLowerCase();
      if (type == 'application/x-bittorrent') return child;
      if (url.startsWith('magnet:') || url.endsWith('.torrent')) {
        fallback ??= child;
      }
    }
    return fallback;
  }

  static String? _pickMagnet(List<String?> candidates) {
    for (final c in candidates) {
      final m = extractMagnet(c);
      if (m != null) return m;
    }
    return null;
  }

  static String? _pickTorrentUrl(List<String?> candidates) {
    for (final c in candidates) {
      if (c == null) continue;
      final s = c.trim();
      if (s.isEmpty) continue;
      if (s.startsWith('magnet:')) continue;
      if (!s.startsWith('http://') && !s.startsWith('https://')) continue;
      return s;
    }
    return null;
  }

  static int? _mediaFileSize(XmlElement node) {
    for (final child in node.childElements) {
      if (child.name.local != 'content') continue;
      final size = parseIntLoose(child.getAttribute('fileSize'));
      if (size != null) return size;
    }
    return null;
  }

  static int? _sizeFromTitle(String? title) {
    if (title == null) return null;
    final m = RegExp(r'\[([^\[\]]{2,20})\]\s*$').firstMatch(title.trim());
    if (m == null) return null;
    return parseSizeToBytes(m.group(1)!);
  }

  static String _preview(String text) {
    final plain = normalizeWhitespace(htmlToPlainText(text)) ?? '';
    return plain.length > 240 ? '${plain.substring(0, 240)}…' : plain;
  }
}

XmlElement? _childElement(XmlElement? parent, String localName) {
  if (parent == null) return null;
  for (final child in parent.childElements) {
    if (child.name.local == localName) return child;
  }
  return null;
}

String? _childText(XmlElement? parent, String localName) {
  if (parent == null) return null;
  final child = _childElement(parent, localName);
  if (child == null) return null;
  // Atom 的 <link href> 没有文本；这里只处理文本型字段。
  return normalizeWhitespace(child.innerText);
}

/// 供外部（例如 registry 的 feedId 生成）使用的稳定短 hash。
String shortHash(String input) =>
    sha1.convert(utf8.encode(input)).toString().substring(0, 12);
