/// ACGNX（末日動漫資源庫，`https://share.acgnx.se/`）源 —— 動畫与季度全集
/// （用户 2026-10-12 第 9 轮：「加入源 … https://share.acgnx.se/sort-1-1.html …，
/// 分区是动漫和全集的」）。
///
/// ## ⚠️ 这个站的网页进不去，只能走 RSS
/// 实测（2026-10-12，本机直连）：`/sort-1-1.html`、`/search-*.html`、甚至站点根
/// 全部返回 **403 `Just a moment...`**（Cloudflare 人机挑战，需要跑 JS + cookie），
/// 换 UA、加 `Accept-Language`、带 cookie 罐都没用；而 **RSS 端点 200 正常**。
/// 所以本源只用 RSS：
/// * 動畫 → `https://share.acgnx.se/rss-1.xml`
/// * 季度全集 → `https://share.acgnx.se/rss-2.xml`
/// * 搜索 → `https://share.acgnx.se/rss.xml?keyword=<关键字>`（实测有效：频道标题变成
///   「關鍵字 学生会 的檢索結果」，50 条全是命中项）
///
/// ## 与别的源相比少什么
/// * RSS 一次 50 条，**没有翻页参数**（实测 `?page=2` / `?p=2` 原样返回第 1 页）→
///   第 ≥2 页返回空页并 `hasNext=false`，**不重复喂同一批**（那会让翻页永远点得动）；
/// * RSS 里**没有做种/下载数** → `seeders` / `leechers` / `downloads` 一律 null，
///   不编 0；
/// * 体积从 `<description>` 的纯文本里取（`… | 16.9GB | 季度全集 | <infohash>`），
///   因为 `enclosure length="1"` 是假值（dmhy 的 RSS 也是这个坑，见 `dmhy.dart`）。
///
/// 站点抓取样本见 `core/test/fixtures/acgnx_{anime,batch,search}.xml`（2026-10-12 抓取）。
library;

import 'package:xml/xml.dart';

import '../subs/title_parser.dart';
import 'cache.dart';
import 'http.dart';
import 'models.dart';
import 'parsing.dart';
import 'source_client.dart';

/// ACGNX 资源站根（网页域名 `acgnx.se` 同理，但只有这个 host 的 RSS 可用）。
const String acgnxBaseUrl = 'https://share.acgnx.se';

/// 「動畫」分区（`rss-1.xml`）。
const String kAcgnxAnimeFeed = '1';

/// 「季度全集」分区（`rss-2.xml`）—— 用户说的「全集」。
const String kAcgnxBatchFeed = '2';

class AcgnxSource extends CachedSourceClient {
  AcgnxSource({
    required super.http,
    required super.cache,
    this.feedId = kAcgnxAnimeFeed,
    this.baseUrl = acgnxBaseUrl,
    String? id,
    String? displayName,
    super.clock,
  })  : _id = id ?? 'acgnx',
        _displayName = displayName ?? 'ACGNX · 動畫';

  /// 分区 feed id：`1` 動畫、`2` 季度全集。
  final String feedId;

  final String baseUrl;
  final String _id;
  final String _displayName;

  @override
  String get id => _id;

  @override
  String get displayName => _displayName;

  /// 关键字搜索走 `rss.xml?keyword=`，实测有效。
  @override
  bool get supportsSearch => true;

  /// 分区显示名（当作条目的 `category` 兜底）。
  String get categoryLabel => feedId == kAcgnxBatchFeed ? '季度全集' : '動畫';

  /// 分区 feed：`https://share.acgnx.se/rss-1.xml`。
  Uri latestUri(int page) => Uri.parse('$baseUrl/rss-$feedId.xml');

  /// 搜索 feed：`https://share.acgnx.se/rss.xml?keyword=…&sort_id=<分区>`。
  ///
  /// **RSS 搜索端点也认 `sort_id`**（用户 2026-10-12 第二十四轮：「还是会搜到单集」）。
  /// 真机实测（`build/probe-scope/probe-scope-filters.log`，关键词「蜡笔小新」）：
  ///
  /// | URL | 条数 | 合集 | 单集 |
  /// |---|---|---|---|
  /// | `rss.xml?keyword=…`（旧实现） | 50 | 0 | 13（其余认不出，也都是单集） |
  /// | `rss.xml?keyword=…&sort_id=2` | 30 | 17 | 0 |
  /// | `rss.xml?keyword=…&sort_id=1` | 50 | 0 | 13（= 不带，動畫分区本来就全部命中） |
  ///
  /// 所以两个实例都带上自己的分区：`acgnx` → 1（動畫）、`acgnx-batch` → 2（季度全集）。
  Uri searchUri(String keyword, int page) =>
      Uri.parse('$baseUrl/rss.xml').replace(
        queryParameters: <String, String>{
          'keyword': keyword,
          'sort_id': feedId,
        },
      );

  @override
  Future<SourcePage> latest({int page = 1}) async {
    if (page < 1) {
      throw SourceException('page 必须 >= 1（收到 $page）', sourceId: id);
    }
    if (page > 1) {
      // RSS 没有翻页参数（实测 `?page=2` 就是第 1 页）：返回空页，让翻页到此为止。
      return SourcePage.empty(page: page, fetchedAt: clock());
    }
    return loadPage(
      request: const CacheRequest.latest(),
      fetch: () => _load(latestUri(page)),
    );
  }

  @override
  Future<SourcePage> search(String keyword, {int page = 1}) async {
    final q = keyword.trim();
    if (q.isEmpty) {
      throw SourceException('搜索关键字不能为空', sourceId: id);
    }
    if (page < 1) {
      throw SourceException('page 必须 >= 1（收到 $page）', sourceId: id);
    }
    if (page > 1) {
      return SourcePage.empty(page: page, fetchedAt: clock());
    }
    final request = CacheRequest.search(q);
    return loadPage(request: request, fetch: () => _load(searchUri(q, page)));
  }

  Future<SourcePage> _load(Uri uri) async {
    final body = await http.getText(uri, sourceId: id);
    final outcome = AcgnxFeedParser.parse(
      body,
      sourceId: id,
      baseUrl: baseUrl,
      fallbackCategory: categoryLabel,
      clock: clock,
    );
    return SourcePage(
      items: outcome.items,
      // RSS 是单页 feed：永远没有下一页（别假装有）。
      hasNext: false,
      page: 1,
      fetchedAt: clock(),
    );
  }
}

/// ACGNX RSS 解析器。
///
/// 字段来源（逐条实测）：
/// * `title`（CDATA，站点把 `&` 写成 `&amp;`，这里解码常见实体）；
/// * `link` / `guid`：`show-<infohash>.html`（hash 的**第二来源**）；
/// * `author`（CDATA）：字幕组 / 发布组；
/// * `enclosure@url`：真正的 magnet（带 `tr=`）；
/// * `category`：站点分类（CDATA，如 `季度全集`）；
/// * `description`（CDATA 里是 HTML）：`组名 | 标题 | 16.9GB | 分类 | <infohash>`。
class AcgnxFeedParser {
  const AcgnxFeedParser._();

  static ParseOutcome parse(
    String xmlText, {
    required String sourceId,
    String baseUrl = acgnxBaseUrl,
    String? fallbackCategory,
    required ClockFn clock,
  }) {
    final doc = parseFeedDocument(xmlText, sourceId: sourceId, label: 'ACGNX RSS');

    final items = <SourceItem>[];
    final seen = <String>{};
    var skipped = 0;
    var duplicates = 0;
    final warnings = <String>[];

    for (final node in doc.findAllElements('item')) {
      final rawTitle = _childText(node, 'title');
      final title = rawTitle == null ? null : _unescapeEntities(rawTitle);
      final link = _childText(node, 'link') ?? _childText(node, 'guid');

      final enclosure = _enclosure(node);
      final magnet = extractMagnet(_unescapeEntities(enclosure?.getAttribute('url')));      final description = _childText(node, 'description');
      final plain = description == null ? null : htmlToPlainText(description);

      final infoHash = firstNonEmpty(<String?>[
        infoHashFromMagnet(magnet),
        _hashFromShowUrl(link),
        _hashFromDescription(plain),
      ]);

      final identity = infoHash ?? link ?? title;
      if (identity == null) {
        skipped++;
        warnings.add('某条 item 既没有 link 也没有 title，已跳过');
        continue;
      }
      final id = '$sourceId:$identity';
      if (!seen.add(id)) {
        duplicates++;
        continue;
      }

      final parsedTitle = title ?? '';
      final parsed = TitleParser.parse(parsedTitle, sourceId: sourceId);

      items.add(SourceItem(
        id: id,
        sourceId: sourceId,
        title: title,
        detailUrl: resolveUri(Uri.parse('$baseUrl/'), link),
        // ACGNX 的 enclosure 就是磁力，不是 .torrent 直链 —— 不编一个不存在的直链。
        torrentUrl: null,
        magnet: magnet,
        infoHash: infoHash,
        sizeBytes: _sizeFromDescription(plain),
        // RSS 里没有做种/下载数：留 null，不填 0（0 会被当成"没人做种"）。
        seeders: null,
        leechers: null,
        downloads: null,
        publishedAt: parseFeedDate(_childText(node, 'pubDate')),
        category: firstNonEmpty(<String?>[
          _childText(node, 'category'),
          fallbackCategory,
        ]),
        group: firstNonEmpty(<String?>[
          _childText(node, 'author'),
          parsed.group,
        ]),
        episodeHints: parsed.episodeHints,
        extra: <String, dynamic>{
          ...parsed.toExtra(),
          'descriptionText': ?plain,
          'fromRssFeed': true,
        },
      ));
    }

    if (duplicates > 0) {
      warnings.add('同一 feed 里 $duplicates 条重复条目已按 id 去重');
    }

    return ParseOutcome(
      items: items,
      // 单页 feed：没有"下一页"这回事。
      hasNext: false,
      skipped: skipped,
      warnings: warnings,
    );
  }

  /// `… | 16.9GB | 季度全集 | <hash>`：取第一个能当体积解析的分段。
  ///
  /// 为什么按 `|` 分段找而不是正则抓第一个 `数字+单位`：描述里的**标题**本身常带
  /// `1080P`、`[01-12]` 这种数字串，直接抓会抓错段。
  static int? _sizeFromDescription(String? plain) {
    if (plain == null) return null;
    for (final part in plain.split('|')) {
      final bytes = parseSizeToBytes(normalizeWhitespace(part));
      if (bytes != null) return bytes;
    }
    return null;
  }

  /// `https://share.acgnx.se/show-<40hex>.html` → 40 位 hex。
  static String? _hashFromShowUrl(String? link) {
    if (link == null) return null;
    return normalizeInfoHash(
      RegExp(r'show-([0-9a-fA-F]{40})\.html').firstMatch(link)?.group(1),
    );
  }

  /// 描述末尾通常再写一遍 infohash（magnet 缺失时的兜底）。
  static String? _hashFromDescription(String? plain) {
    if (plain == null) return null;
    final matches = RegExp(r'\b([0-9a-fA-F]{40})\b').allMatches(plain);
    for (final m in matches) {
      final hash = normalizeInfoHash(m.group(1));
      if (hash != null) return hash;
    }
    return null;
  }

  /// 站点在 **CDATA 里**也把 `&` 写成 `&amp;`（生成器统一转义），这里只解常见实体。
  ///
  /// 为什么不用 `htmlToPlainText`：那会把标题里的 `[`/`]` 之外的 `<` `>` 一并当标签吃掉，
  /// 而标题里的实体只有这五个；窄替换更可预测。输入为 null 时返回 null。
  static String? _unescapeEntities(String? raw) => raw
      ?.replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'");

  static XmlElement? _enclosure(XmlElement node) {
    for (final child in node.childElements) {
      if (child.name.local != 'enclosure') continue;
      final url = child.getAttribute('url');
      if (url == null || url.isEmpty) continue;
      final type = (child.getAttribute('type') ?? '').toLowerCase();
      if (type == 'application/x-bittorrent' || url.startsWith('magnet:')) {
        return child;
      }
    }
    return null;
  }

  static String? _childText(XmlElement node, String localName) {
    for (final child in node.childElements) {
      if (child.name.local != localName) continue;
      return normalizeWhitespace(child.innerText);
    }
    return null;
  }
}
