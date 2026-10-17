/// nyaa.si 源（spec §4.2）。
///
/// * 最新：`https://nyaa.si/?page=rss&c=1_2&f=0`（RSS，字段最全）；
/// * 搜索：第 1 页走 RSS `?page=rss&q=…&c=1_0&f=0&s=seeders&o=desc`，
///   第 ≥2 页走 HTML 列表页 `?page=search&q=…&p=N`（RSS 无分页参数）；
/// * 详情：`/view/<id>` HTML 补 magnet（RSS 里没有 magnet，只有 `.torrent` 直链）；
/// * 动漫区固定 `c=1_2`（Anime - English-translated），可用 `c=1_0`（全部 Anime）；
/// * **搜索用另一个分类**（[NyaaSource.searchCategory]，默认 `1_0`）—— 见那个字段的注释。
///
/// 站点抓取样本见 `core/test/fixtures/nyaa_*.{xml,html}`（2026-10-08 抓取）。
library;

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;
import 'package:xml/xml.dart';

import '../subs/title_parser.dart';
import 'cache.dart';
import 'http.dart';
import 'models.dart';
import 'parse_off_thread.dart';
import 'parsing.dart';
import 'source_client.dart';

/// nyaa 站点根。
const String nyaaBaseUrl = 'https://nyaa.si';

/// 搜索默认分类：`1_0` = 全部 Anime。
const String kNyaaSearchCategory = '1_0';

class NyaaSource extends CachedSourceClient {
  NyaaSource({
    required super.http,
    required super.cache,
    this.category = '1_2',
    this.searchCategory,
    this.baseUrl = nyaaBaseUrl,
    this.sort = 'seeders',
    this.order = 'desc',
    String? id,
    String? displayName,
    super.clock,
  })  : _id = id ?? 'nyaa',
        _displayName = displayName ?? 'Nyaa（动漫区）';

  /// `1_2` = Anime - English-translated（默认，spec 冻结）；`1_0` = 全部 Anime。
  ///
  /// **只管「最新」**；搜索看 [searchCategory]。
  final String category;

  /// 搜索用分类；`null`（默认）= 自动，见 [_effectiveSearchCategory]。
  ///
  /// 为什么要与 [category] 分开（用户 2026-10-12：「搜索内容不全，数量太少」）：
  /// `1_2` 是 Anime - English-translated，中文/繁中字幕条目几乎都落在 `1_3`
  /// （Non-English-translated）里。实测同一个关键字「葬送的芙莉莲」：
  /// `c=1_2` 只回 **2** 条，`c=1_0` 回 **75** 条。
  /// 「最新」保持 spec 冻结的 `1_2` 不动 —— 那里要的是稳定的英文圈新番流，
  /// 而搜索要的是"能不能搜到"，宁可宽。
  final String? searchCategory;

  /// 搜索实际用的分类：显式给了就用它；否则**有分类的实例放宽到全部 Anime**，
  /// 本来就是"不限分类"的实例（例如 sukebei，[category] 为空）保持不限。
  ///
  /// 后半条很重要：sukebei 的分类编号与 nyaa.si 完全不是一回事（`1_2` 是
  /// Art - Doujinshi），给它硬塞一个 `1_0` 等于悄悄换了它要的东西。
  String get _effectiveSearchCategory =>
      searchCategory ?? (category.isEmpty ? '' : kNyaaSearchCategory);

  final String baseUrl;
  final String sort;
  final String order;

  final String _id;
  final String _displayName;

  @override
  String get id => _id;

  @override
  String get displayName => _displayName;

  @override
  bool get supportsSearch => true;

  Uri rssUri({String? keyword}) {
    final q = keyword?.trim() ?? '';
    final isSearch = q.isNotEmpty;
    // 分类可留空 = 不限分类（不同站点/镜像的分类编号语义不同，sukebei 的
    // 1_1/1_2 是 Art-Anime / Art-Doujinshi，与 nyaa.si 的 Anime-English 完全不是一回事，
    // 所以「不限分类」必须能表达）。
    final String effectiveCategory = isSearch ? _effectiveSearchCategory : category;
    return Uri.parse('$baseUrl/').replace(queryParameters: <String, String>{
      'page': 'rss',
      if (isSearch) 'q': q,
      if (effectiveCategory.isNotEmpty) 'c': effectiveCategory,
      'f': '0',
      if (isSearch) 's': sort,
      if (isSearch) 'o': order,
    });
  }

  Uri searchHtmlUri(String keyword, int page) =>
      Uri.parse('$baseUrl/').replace(queryParameters: <String, String>{
        'page': 'search',
        'q': keyword,
        if (_effectiveSearchCategory.isNotEmpty) 'c': _effectiveSearchCategory,
        'f': '0',
        's': sort,
        'o': order,
        'p': '$page',
      });

  Uri viewUri(String viewId) => Uri.parse('$baseUrl/view/$viewId');

  @override
  Future<SourcePage> latest({int page = 1}) async {
    if (page < 1) {
      throw SourceException('page 必须 >= 1（收到 $page）', sourceId: id);
    }
    if (page > 1) {
      // RSS 没有分页参数（spec §4.2）：返回空页并明确 hasNext=false，
      // 不伪造第 2 页数据，也不抛异常（UI 分页循环需要安全终点）。
      return SourcePage.empty(page: page, fetchedAt: clock());
    }
    return loadPage(
      request: const CacheRequest.latest(),
      fetch: () async {
        final body = await http.getText(rssUri(), sourceId: id);
        final outcome = NyaaRssParser.parse(
          body,
          sourceId: id,
          baseUrl: baseUrl,
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

  @override
  Future<SourcePage> search(String keyword, {int page = 1}) async {
    final q = keyword.trim();
    if (q.isEmpty) {
      throw SourceException('搜索关键字不能为空', sourceId: id);
    }
    if (page < 1) {
      throw SourceException('page 必须 >= 1（收到 $page）', sourceId: id);
    }
    return loadPage(
      request: CacheRequest.search(q, page: page),
      fetch: () async {
        if (page == 1) {
          final body = await http.getText(rssUri(keyword: q), sourceId: id);
          final outcome = NyaaRssParser.parse(
            body,
            sourceId: id,
            baseUrl: baseUrl,
            clock: clock,
          );
          // RSS 不提供页数信息；有结果就保守地允许 UI 继续请求第 2 页（走 HTML）。
          return SourcePage(
            items: outcome.items,
            hasNext: outcome.items.isNotEmpty,
            page: 1,
            fetchedAt: clock(),
          );
        }
        final body = await http.getText(searchHtmlUri(q, page), sourceId: id);
        // ⚠️ 一页可能几百 KB：解析在子 isolate（小页仍同步，见 [parseOffThread]）。
        final outcome = await _parseHtmlListOffThread(
          body: body,
          sourceId: id,
          baseUrl: baseUrl,
          now: clock(),
        );
        return SourcePage(
          items: outcome.items,
          hasNext: outcome.hasNext,
          page: page,
          fetchedAt: clock(),
        );
      },
    );
  }

  @override
  Future<SourceItem?> detail(SourceItem item) async {
    final viewId = viewIdOf(item);
    if (viewId == null) return null;
    final request = CacheRequest.detail(item.id);

    final cached = await cache.get(id, request);
    final cachedItem = _itemFromPayload(cached?.payload);
    if (cachedItem != null) return cachedItem;

    try {
      final body = await http.getText(viewUri(viewId), sourceId: id);
      // 详情页一般 ~20KB（同步 1ms），但别把"一般"当保证：同一入口按阈值分流。
      final enriched = await _parseDetailOffThread(
        body: body,
        base: item,
        sourceId: id,
        baseUrl: baseUrl,
        now: clock(),
      );
      if (enriched == null) {
        throw SourceException(
          'nyaa 详情页缺少可识别字段（未找到 h3.panel-title）: ${viewUri(viewId)}',
          sourceId: id,
          url: viewUri(viewId),
        );
      }
      await cache.put(id, request, <String, dynamic>{'item': enriched.toJson()});
      return enriched;
    } on SourceException {
      final stale = await cache.get(id, request, allowStale: true);
      final staleItem = _itemFromPayload(stale?.payload);
      if (staleItem != null) return staleItem;
      rethrow;
    }
  }

  /// `nyaa:2171209` / `https://nyaa.si/view/2171209` → `2171209`。
  static String? viewIdOf(SourceItem item) {
    final fromId = RegExp(r'^nyaa:(\d+)$').firstMatch(item.id);
    if (fromId != null) return fromId.group(1);
    final path = item.detailUrl?.path ?? '';
    return RegExp(r'/view/(\d+)').firstMatch(path)?.group(1);
  }
}

SourceItem? _itemFromPayload(Map<String, dynamic>? payload) {
  final raw = payload?['item'];
  if (raw is! Map) return null;
  try {
    return SourceItem.fromJson(
      raw.map((dynamic k, dynamic v) => MapEntry<String, dynamic>(k.toString(), v)),
    );
  } catch (_) {
    return null;
  }
}

/// 搜索第 ≥2 页的 HTML 列表解析**顶层**入口（1.1.0 M1/T6 起进子 isolate）。
///
/// 为什么是顶层函数：实例方法里造的闭包会连 `this` 一起捕获，`Isolate.run` 送不进去
/// （第四十七轮 mikan 实测，见 `parse_off_thread.dart` 文件头）。小页在
/// [parseOffThread] 里仍同步解析，行为与改动前一致。
Future<ParseOutcome> _parseHtmlListOffThread({
  required String body,
  required String sourceId,
  required String baseUrl,
  required DateTime now,
}) => parseOffThread<ParseOutcome>(
  text: body,
  now: now,
  compute: (DateTime at) => NyaaHtmlListParser.parse(
    body,
    sourceId: sourceId,
    baseUrl: baseUrl,
    clock: () => at,
  ),
);

/// `/view/<id>` 详情页解析**顶层**入口（1.1.0 M1/T6 起进子 isolate）。
Future<SourceItem?> _parseDetailOffThread({
  required String body,
  required SourceItem base,
  required String sourceId,
  required String baseUrl,
  required DateTime now,
}) => parseOffThread<SourceItem?>(
  text: body,
  now: now,
  compute: (DateTime at) => NyaaHtmlDetailParser.parse(
    body,
    base: base,
    sourceId: sourceId,
    baseUrl: baseUrl,
    clock: () => at,
  ),
);

/// nyaa RSS 解析器。
class NyaaRssParser {
  const NyaaRssParser._();

  static ParseOutcome parse(
    String xmlText, {
    required String sourceId,
    String baseUrl = nyaaBaseUrl,
    required ClockFn clock,
  }) {
    final doc = parseFeedDocument(xmlText, sourceId: sourceId, label: 'nyaa RSS');

    final nodes = doc.findAllElements('item').toList(growable: false);
    final items = <SourceItem>[];
    var skipped = 0;
    final warnings = <String>[];

    for (final node in nodes) {
      final title = _childText(node, 'title');
      final link = _childText(node, 'link');
      final guid = _childText(node, 'guid');
      final hash = normalizeInfoHash(_childText(node, 'infoHash'));
      final viewId = _extractViewId(guid) ?? _extractViewId(link);
      if (viewId == null) {
        skipped++;
        continue;
      }

      final sizeText = _childText(node, 'size');
      final parsed = TitleParser.parse(title ?? '', sourceId: sourceId);
      final detailUrl = (guid != null && guid.startsWith('http'))
          ? Uri.tryParse(guid)
          : Uri.parse('$baseUrl/view/$viewId');

      items.add(SourceItem(
        id: 'nyaa:$viewId',
        sourceId: sourceId,
        title: title,
        detailUrl: detailUrl,
        torrentUrl: resolveUri(Uri.parse('$baseUrl/'), link)?.toString(),
        infoHash: hash,
        sizeBytes: parseSizeToBytes(sizeText),
        seeders: parseIntLoose(_childText(node, 'seeders')),
        leechers: parseIntLoose(_childText(node, 'leechers')),
        downloads: parseIntLoose(_childText(node, 'downloads')),
        publishedAt: parseFeedDate(_childText(node, 'pubDate')),
        category: _childText(node, 'category'),
        group: parsed.group,
        episodeHints: parsed.episodeHints,
        extra: <String, dynamic>{
          ...parsed.toExtra(),
          'categoryId': _childText(node, 'categoryId'),
          'comments': parseIntLoose(_childText(node, 'comments')),
          'trusted': _yesNo(_childText(node, 'trusted')),
          'remake': _yesNo(_childText(node, 'remake')),
          'sizeText': ?sizeText,
        },
      ));
    }

    return ParseOutcome(items: items, skipped: skipped, warnings: warnings);
  }

  static bool? _yesNo(String? v) {
    if (v == null) return null;
    final s = v.trim().toLowerCase();
    if (s == 'yes' || s == 'true') return true;
    if (s == 'no' || s == 'false') return false;
    return null;
  }

  static String? _extractViewId(String? url) {
    if (url == null) return null;
    return RegExp(r'/view/(\d+)').firstMatch(url)?.group(1) ??
        RegExp(r'/download/(\d+)').firstMatch(url)?.group(1);
  }
}

/// nyaa HTML 搜索列表页解析器（`table.torrent-list`）。
class NyaaHtmlListParser {
  const NyaaHtmlListParser._();

  static ParseOutcome parse(
    String htmlText, {
    required String sourceId,
    String baseUrl = nyaaBaseUrl,
    required ClockFn clock,
  }) {
    final dom.Document doc;
    try {
      doc = html_parser.parse(htmlText);
    } catch (e) {
      throw SourceException('nyaa HTML 列表页解析失败: $e',
          sourceId: sourceId, cause: e);
    }

    final table = doc.querySelector('table.torrent-list');
    if (table == null) {
      throw SourceException(
        'nyaa HTML 结构已变：找不到 table.torrent-list',
        sourceId: sourceId,
        url: Uri.parse(baseUrl),
      );
    }

    final base = Uri.parse('$baseUrl/');
    final items = <SourceItem>[];
    var skipped = 0;
    final warnings = <String>[];

    for (final row in table.querySelectorAll('tr')) {
      final cells = row.querySelectorAll('td');
      if (cells.isEmpty) continue; // 表头行（<th>）
      if (cells.length < 8) {
        skipped++;
        warnings.add('某行只有 ${cells.length} 个单元格（期望 8），已跳过');
        continue;
      }

      final anchors = cells[2].querySelectorAll('a');
      String? torrentUrl;
      String? magnet;
      for (final a in anchors) {
        final href = a.attributes['href'] ?? '';
        if (href.startsWith('/download/') || href.contains('/download/')) {
          torrentUrl = resolveUri(base, href)?.toString();
        } else if (href.startsWith('magnet:')) {
          magnet = href;
        }
      }

      String? detailHref;
      String? title;
      for (final a in cells[1].querySelectorAll('a')) {
        final href = a.attributes['href'] ?? '';
        if (!href.contains('/view/')) continue;
        if (href.contains('#')) continue; // 评论锚点
        detailHref = href;
        title = normalizeWhitespace(a.attributes['title']) ??
            normalizeWhitespace(a.text);
        break;
      }
      final viewId = detailHref == null
          ? null
          : RegExp(r'/view/(\d+)').firstMatch(detailHref)?.group(1);
      if (viewId == null) {
        skipped++;
        warnings.add('某行找不到 /view/<id> 链接，已跳过');
        continue;
      }

      final classes = row.classes;
      final publishedAt = parseFeedDate(cells[4].attributes['data-timestamp']) ??
          parseFeedDate(cells[4].text);
      final sizeText = normalizeWhitespace(cells[3].text);
      final parsed = TitleParser.parse(title ?? '', sourceId: sourceId);

      items.add(SourceItem(
        id: 'nyaa:$viewId',
        sourceId: sourceId,
        title: title,
        detailUrl: resolveUri(base, detailHref),
        torrentUrl: torrentUrl,
        magnet: magnet,
        infoHash: infoHashFromMagnet(magnet),
        sizeBytes: parseSizeToBytes(sizeText),
        seeders: parseIntLoose(cells[5].text),
        leechers: parseIntLoose(cells[6].text),
        downloads: parseIntLoose(cells[7].text),
        publishedAt: publishedAt,
        category: normalizeWhitespace(cells[0].querySelector('a')?.attributes['title']),
        group: parsed.group,
        episodeHints: parsed.episodeHints,
        extra: <String, dynamic>{
          ...parsed.toExtra(),
          'comments': parseIntLoose(
              cells[1].querySelector('a.comments')?.text),
          // nyaa 列表行 class：success = trusted，danger = remake。
          'trusted': classes.contains('success'),
          'remake': classes.contains('danger'),
          'sizeText': ?sizeText,
          'fromHtmlList': true,
        },
      ));
    }

    return ParseOutcome(
      items: items,
      hasNext: _hasNextPage(doc),
      skipped: skipped,
      warnings: warnings,
    );
  }

  static bool _hasNextPage(dom.Document doc) {
    final next = doc.querySelector('ul.pagination li.next');
    if (next == null) return false;
    final href = next.querySelector('a')?.attributes['href'] ?? '';
    return href.isNotEmpty && !next.classes.contains('disabled');
  }
}

/// nyaa 详情页（`/view/<id>`）解析器：补 magnet、精确发布时间。
class NyaaHtmlDetailParser {
  const NyaaHtmlDetailParser._();

  /// 解析失败（页面结构不认识）时返回 null，由调用方决定抛错还是回退。
  static SourceItem? parse(
    String htmlText, {
    required SourceItem base,
    required String sourceId,
    String baseUrl = nyaaBaseUrl,
    required ClockFn clock,
  }) {
    final dom.Document doc;
    try {
      doc = html_parser.parse(htmlText);
    } catch (e) {
      throw SourceException('nyaa 详情页解析失败: $e', sourceId: sourceId, cause: e);
    }

    final titleNode = doc.querySelector('h3.panel-title');
    if (titleNode == null) return null;
    final title = normalizeWhitespace(titleNode.text) ?? base.title;

    final root = Uri.parse('$baseUrl/');
    String? magnet;
    String? torrentUrl;
    for (final a in doc.querySelectorAll('a')) {
      final href = a.attributes['href'] ?? '';
      if (magnet == null && href.startsWith('magnet:')) magnet = href;
      if (torrentUrl == null && href.contains('/download/')) {
        torrentUrl = resolveUri(root, href)?.toString();
      }
    }

    final fields = _labelValuePairs(doc.querySelector('.panel-body'));
    final hash = normalizeInfoHash(
      doc.querySelector('kbd')?.text ?? infoHashFromMagnet(magnet),
    );
    final parsed = TitleParser.parse(title ?? '', sourceId: sourceId);
    final sizeText = fields['File size'];

    return base.copyWith(
      title: title,
      detailUrl: base.detailUrl ?? Uri.parse('$baseUrl/view/${NyaaSource.viewIdOf(base) ?? ''}'),
      torrentUrl: torrentUrl ?? base.torrentUrl,
      magnet: magnet ?? base.magnet,
      infoHash: hash ?? base.infoHash,
      sizeBytes: parseSizeToBytes(sizeText) ?? base.sizeBytes,
      seeders: parseIntLoose(fields['Seeders']) ?? base.seeders,
      leechers: parseIntLoose(fields['Leechers']) ?? base.leechers,
      downloads: parseIntLoose(fields['Completed']) ?? base.downloads,
      publishedAt: parseFeedDate(
            doc.querySelector('[data-timestamp]')?.attributes['data-timestamp'],
          ) ??
          base.publishedAt,
      category: normalizeWhitespace(fields['Category']) ?? base.category,
      group: parsed.group ?? base.group,
      episodeHints:
          parsed.episodeHints.isEmpty ? base.episodeHints : parsed.episodeHints,
      extra: <String, dynamic>{
        ...base.extra,
        ...parsed.toExtra(),
        if (fields['Submitter'] != null) 'submitter': fields['Submitter'],
        if (fields['Information'] != null) 'information': fields['Information'],
        'sizeText': ?sizeText,
        'detailFetched': true,
      },
    );
  }

  /// panel-body 里的 `标签: 值` 对（标签 div 后面紧跟值 div）。
  static Map<String, String> _labelValuePairs(dom.Element? panel) {
    final out = <String, String>{};
    if (panel == null) return out;
    for (final row in panel.querySelectorAll('.row')) {
      final cols = row.children
          .where((dom.Element e) => e.localName == 'div')
          .toList(growable: false);
      for (var i = 0; i + 1 < cols.length; i += 2) {
        final rawLabel = normalizeWhitespace(cols[i].text);
        if (rawLabel == null || !rawLabel.endsWith(':')) continue;
        final label = rawLabel.substring(0, rawLabel.length - 1).trim();
        out[label] = normalizeWhitespace(cols[i + 1].text) ?? '';
      }
    }
    return out;
  }
}

/// 取命名空间无关的直接子元素文本（nyaa RSS 用 `nyaa:` 前缀，
/// 直接按 local name 匹配最稳）。
String? _childText(XmlElement parent, String localName) {
  for (final child in parent.childElements) {
    if (child.name.local == localName) return normalizeWhitespace(child.innerText);
  }
  return null;
}
