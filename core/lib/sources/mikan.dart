/// mikanani.me（蜜柑计划）源（spec §4.2）。
///
/// * 最新：`https://mikanani.me/RSS/Classic`；
/// * 搜索：**`https://mikanani.me/Home/Search?searchstr=<q>`（HTML 搜索页）**。
///   为什么不用 `RSS/Search`（用户 2026-10-12：「搜索内容不全，数量太少」）：
///   RSS 版上限 100 条且没有分页参数（实测），HTML 搜索页一个页面里就有 **1000 条**
///   （实测），字段还更全（大小/日期/详情页 hash 都在）。代价是响应大（实测 ~4.3 MB），
///   换来的是"一次抓完、翻页零请求"；
/// * RSS item：`title`、`link`(详情页 `/Home/Episode/<hash>`)、
///   `torrent/link+contentLength+pubDate`（命名空间 `https://mikanani.me/0.1/`）、
///   `<enclosure type="application/x-bittorrent" url="…/Download/<yyyyMMdd>/<hash>.torrent">`；
/// * **RSS 里没有 infoHash**（spec 原文），`magnet`/`infoHash` 由 HTML 详情页补齐；
/// * HTML 补充解析：`/Home/Episode/<hash>`（magnet/字幕组/大小/日期）、
///   `/Home/Bangumi/<id>`（番剧标题、字幕组列表、每集 .torrent 与 magnet）、
///   `/Home/Search`（搜索页，表格形状与番剧页一致）；
///
/// 站点抓取样本见 `core/test/fixtures/mikan_*.{xml,html}`（2026-10-08 / 10-12 抓取）。
library;

import 'dart:isolate';

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;
import 'package:xml/xml.dart';

import '../subs/title_parser.dart';
import 'cache.dart';
import 'http.dart';
import 'mikan_schedule.dart';
import 'models.dart';
import 'parsing.dart';
import 'source_client.dart';

/// mikan 站点根。
const String mikanBaseUrl = 'https://mikanani.me';

/// 超过这个长度（UTF-16 code unit ≈ 字节，页面里中日文都是实体，基本全是 ASCII）
/// 就把 mikan 页面的解析挪到子 isolate（见 [parseMikanOffThread]）。
///
/// 128KB 是量出来的：
/// * `package:html` 建整页 DOM ≈ **80ms/MB，而且全是同步的** ⇒ 128KB ≈ 10ms ≈ 半帧；
/// * 空 `Isolate.run` 的启动开销实测 **0ms**（Dart VM，5 次全 0）—— 挪走几乎不要钱，
///   所以阈值只该按"这一页解析要多久"来定，不必留余量；
/// * 实测页面大小：单集页 26KB、RSS 81KB（都留在同步路径，2~7ms）；
///   番剧页 **928KB~1MB**、搜索页 **1.8~4.3MB**（都挪走）。
///
/// ⚠️ 一开始定的是 1MB，结果 `/Home/Bangumi/3821`（928KB）刚好落在阈值下面，
/// 同步解析把主线程卡了 **113ms**（真机探针实测）—— 所以阈值按"半帧"定，不按"整数好看"定。
const int kMikanParseOffloadBytes = 128 * 1024;

/// 把 mikan 大页面的解析挪到**子 isolate**（第四十七轮）。
///
/// 为什么非挪不可：源抓取跑在 **UI isolate** 上，而 `html_parser.parse` 是同步 CPU ——
/// 用户点进动漫库详细页时，「种子」块要拿 mikan 搜索页（4.12MB）里的候选，
/// 那一次解析就把界面冻住 300~500ms（用户原话：「点进去时必卡一下」）。
/// 实测：`Isolate.run` 把整段挪走往返只要 ~260ms，**主线程全程不占**（比同步解析还快，
/// 因为同步那 460ms 里主线程什么都干不了）。
///
/// 两条约定（都踩过）：
/// * 时钟按**值**传（[now]），别把 `clock` 闭包带过去：同一页每一行本来就用同一个"现在"
///   算相对日期，语义不变；而测试里的假时钟不保证可跨 isolate。
/// * ⚠️ [compute] 必须**在顶层函数里造**（见 `_parseSearchPage` / `_parseBangumiPage`），
///   不能在 `MikanSource` 的实例方法里直接写闭包 —— Dart 的闭包按**上下文**捕获，
///   实例方法里的上下文连着 `this`，于是 `Isolate.run` 会当场抛
///   `Illegal argument in isolate message: … _Future ← RateLimiter ← SourceHttp ← MikanSource`
///   （实测 2026-10-16：把 `id` / `baseUrl` 先取成局部变量**也不够**）。
Future<T> parseMikanOffThread<T>({
  required String html,
  required DateTime now,
  required T Function(DateTime now) compute,
}) {
  if (html.length < kMikanParseOffloadBytes) {
    return Future<T>.value(compute(now));
  }
  return Isolate.run<T>(() => compute(now));
}

/// 搜索页解析的**顶层**入口（搜到的行数最多、页面最大，见 [kMikanParseOffloadBytes]）。
Future<ParseOutcome> _parseSearchPage({
  required String body,
  required String sourceId,
  required String base,
  required DateTime now,
}) => parseMikanOffThread<ParseOutcome>(
  html: body,
  now: now,
  compute: (DateTime at) => MikanSearchParser.parse(
    body,
    sourceId: sourceId,
    baseUrl: base,
    clock: () => at,
  ),
);

/// 番剧页解析的**顶层**入口（单集页面 432KB+，长番更大）。
Future<MikanBangumiDetail> _parseBangumiPage({
  required String body,
  required Uri url,
  required String sourceId,
  required String base,
  required DateTime now,
}) => parseMikanOffThread<MikanBangumiDetail>(
  html: body,
  now: now,
  compute: (DateTime at) => MikanBangumiParser.parse(
    body,
    url: url,
    sourceId: sourceId,
    baseUrl: base,
    clock: () => at,
  ),
);

/// mikan 扩展命名空间（`<torrent>` 元素）。
const String mikanTorrentNamespace = 'https://mikanani.me/0.1/';

class MikanSource extends CachedSourceClient {
  MikanSource({
    required super.http,
    required super.cache,
    this.baseUrl = mikanBaseUrl,
    super.clock,
  });

  final String baseUrl;

  @override
  String get id => 'mikan';

  @override
  String get displayName => 'Mikan（蜜柑计划）';

  @override
  bool get supportsSearch => true;

  Uri classicRssUri() => Uri.parse('$baseUrl/RSS/Classic');

  /// HTML 搜索页（**搜索实际走这条**，见类注释）。
  Uri searchHtmlUri(String keyword) => Uri.parse('$baseUrl/Home/Search')
      .replace(queryParameters: <String, String>{'searchstr': keyword});

  Uri episodeUri(String hash) => Uri.parse('$baseUrl/Home/Episode/$hash');

  Uri bangumiUri(Object bangumiId) =>
      Uri.parse('$baseUrl/Home/Bangumi/$bangumiId');

  @override
  Future<SourcePage> latest({int page = 1}) async {
    if (page < 1) {
      throw SourceException('page 必须 >= 1（收到 $page）', sourceId: id);
    }
    if (page > 1) {
      // RSS/Classic 无分页参数：返回空页，不伪造数据。
      return SourcePage.empty(page: page, fetchedAt: clock());
    }
    return loadPage(
      request: const CacheRequest.latest(),
      fetch: () async {
        final body = await http.getText(classicRssUri(), sourceId: id);
        final outcome = MikanRssParser.parse(
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
    if (page > 1) {
      // HTML 搜索页没有分页参数（`&page=2` 返回的字节与第 1 页完全相同，实测）：
      // 1000 条一次给全，所以第 2 页起就是空页，不伪造。
      return SourcePage.empty(page: page, fetchedAt: clock());
    }
    return loadPage(
      request: CacheRequest.search(q, page: page),
      fetch: () async {
        final body = await http.getText(searchHtmlUri(q), sourceId: id);
        // ⚠️ 这一页实测 1.8~4.3MB：解析走子 isolate（见 [parseMikanOffThread]）。
        final outcome = await _parseSearchPage(
          body: body,
          sourceId: id,
          base: baseUrl,
          now: clock(),
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
  Future<SourceItem?> detail(SourceItem item) async {
    final hash = episodeHashOf(item);
    final bangumiId = bangumiIdOf(item);
    if (hash == null && bangumiId == null) return null;

    final request = CacheRequest.detail(item.id);
    final cached = await cache.get(id, request);
    final cachedItem = _itemFromPayload(cached?.payload);
    if (cachedItem != null) return cachedItem;

    try {
      final SourceItem? enriched;
      if (hash != null) {
        final body = await http.getText(episodeUri(hash), sourceId: id);
        enriched = MikanEpisodeParser.parse(
          body,
          base: item,
          url: episodeUri(hash),
          sourceId: id,
          baseUrl: baseUrl,
          clock: clock,
        );
      } else {
        final body = await http.getText(bangumiUri(bangumiId!), sourceId: id);
        final parsed = await _parseBangumiPage(
          body: body,
          url: bangumiUri(bangumiId),
          sourceId: id,
          base: baseUrl,
          now: clock(),
        );
        enriched = item.copyWith(
          title: parsed.title ?? item.title,
          extra: <String, dynamic>{
            ...item.extra,
            if (parsed.title != null) 'bangumiTitle': parsed.title,
            'bangumiId': bangumiId,
            'episodeCount': parsed.episodes.length,
            'subtitleGroups': parsed.groups
                .map((MikanSubtitleGroup g) => g.toJson())
                .toList(growable: false),
            'detailFetched': true,
          },
        );
      }
      if (enriched == null) {
        throw SourceException(
          'mikan 详情页结构不认识（未找到 magnet/标题等关键字段）',
          sourceId: id,
          url: hash != null ? episodeUri(hash) : bangumiUri(bangumiId!),
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

  /// 番剧详情页（`/Home/Bangumi/<id>`）：字幕组列表 + 每集（含 `.torrent` 与 magnet）。
  ///
  /// 这是 spec §4.2 明确要求的 HTML 补充解析能力，[detail] 走不开的大列表
  /// （例如「一键全季入队」）用它。
  Future<MikanBangumiDetail> bangumi(Object bangumiId) async {
    final url = bangumiUri(bangumiId);
    final body = await http.getText(url, sourceId: id);
    return _parseBangumiPage(
      body: body,
      url: url,
      sourceId: id,
      base: baseUrl,
      now: clock(),
    );
  }

  /// 首页「本周追番更新表」（spec §7.5，主页数据源）。
  ///
  /// 取数流程与 [detail] 一致：新鲜缓存命中 → 网络 → stale 回落 → 抛错。
  /// 缓存键是**首页追番表自己那一档**（`CacheKind.schedule`）——
  /// 与 RSS「最新」(`CacheKind.latest`) 分开，两者不会互相顶掉。
  ///
  /// **注意**：返回的是「番剧在某天更新」的展示记录，**不含种子/磁力**；
  /// 要下载请用 [bangumi] 拿剧集列表（或走订阅）。
  Future<MikanSchedule> schedule() async {
    final url = Uri.parse('$baseUrl/');
    // ⚠️ 必须是**自己的**缓存键：以前这里借用了 `CacheRequest.latest()`（RSS 那条），
    // 于是首页追番表与 RSS 最新互相顶掉 —— 各自把对方的载荷判成 miss，
    // 交替调用永远打网络。见 `CacheKind.schedule`。
    final request = const CacheRequest.schedule();

    final cached = await cache.get(id, request);
    final cachedSchedule = _scheduleFromPayload(cached?.payload);
    if (cachedSchedule != null) return cachedSchedule;

    try {
      final body = await http.getText(url, sourceId: id);
      final schedule = MikanScheduleParser.parse(
        body,
        url: url,
        sourceId: id,
        baseUrl: baseUrl,
        clock: clock,
      );
      await cache.put(id, request, <String, dynamic>{
        'schedule': schedule.entries.map((e) => e.toJson()).toList(growable: false),
        'skipped': schedule.skipped,
      });
      return schedule;
    } on SourceException {
      final stale = await cache.get(id, request, allowStale: true);
      final staleSchedule = _scheduleFromPayload(stale?.payload);
      if (staleSchedule != null) return staleSchedule;
      rethrow;
    }
  }

  /// 从缓存 payload 还原追番表；结构不对返回 null（缓存损坏按 miss 处理）。
  static MikanSchedule? _scheduleFromPayload(Map<String, dynamic>? payload) {
    final raw = payload?['schedule'];
    if (raw is! List) return null;
    final entries = <MikanScheduleEntry>[];
    for (final e in raw) {
      if (e is! Map) continue;
      final parsed = MikanScheduleEntry.fromJson(Map<String, dynamic>.from(e));
      if (parsed != null) entries.add(parsed);
    }
    if (entries.isEmpty) return null;
    final byDay = <int, List<MikanScheduleEntry>>{};
    for (final e in entries) {
      byDay.putIfAbsent(e.dayOfWeek, () => <MikanScheduleEntry>[]).add(e);
    }
    for (final list in byDay.values) {
      list.sort((a, b) => a.index.compareTo(b.index));
    }
    return MikanSchedule(
      entries: List<MikanScheduleEntry>.unmodifiable(entries),
      byDay: Map<int, List<MikanScheduleEntry>>.unmodifiable(byDay),
    );
  }

  /// `/Home/Episode/<40hex>` → hash。
  static String? episodeHashOf(SourceItem item) {
    final path = item.detailUrl?.path ?? '';
    final m = RegExp(r'/Home/Episode/([0-9a-fA-F]{40})').firstMatch(path);
    if (m != null) return m.group(1)!.toLowerCase();
    final fromId = RegExp(r'^mikan:([0-9a-fA-F]{40})$').firstMatch(item.id);
    return fromId?.group(1)?.toLowerCase();
  }

  /// `/Home/Bangumi/<id>` → id。
  static String? bangumiIdOf(SourceItem item) {
    final path = item.detailUrl?.path ?? '';
    return RegExp(r'/Home/Bangumi/(\d+)').firstMatch(path)?.group(1);
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

/// mikan 字幕组。
class MikanSubtitleGroup {
  const MikanSubtitleGroup({required this.id, required this.name, this.rssUrl});

  final String id;
  final String name;
  final Uri? rssUrl;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'name': name,
        if (rssUrl != null) 'rssUrl': rssUrl.toString(),
      };

  factory MikanSubtitleGroup.fromJson(Map<String, dynamic> json) =>
      MikanSubtitleGroup(
        id: json['id']?.toString() ?? '',
        name: json['name']?.toString() ?? '',
        rssUrl: json['rssUrl'] is String
            ? Uri.tryParse(json['rssUrl'] as String)
            : null,
      );
}

/// 番剧详情页解析结果。
class MikanBangumiDetail {
  const MikanBangumiDetail({
    required this.bangumiId,
    required this.title,
    required this.groups,
    required this.episodes,
    this.skipped = 0,
    this.warnings = const <String>[],
  });

  final String bangumiId;
  final String? title;
  final List<MikanSubtitleGroup> groups;
  final List<SourceItem> episodes;
  final int skipped;
  final List<String> warnings;
}

/// mikan RSS（`/RSS/Classic`、`/RSS/Search`）解析器。
class MikanRssParser {
  const MikanRssParser._();

  static ParseOutcome parse(
    String xmlText, {
    required String sourceId,
    String baseUrl = mikanBaseUrl,
    required ClockFn clock,
  }) {
    final doc = parseFeedDocument(xmlText, sourceId: sourceId, label: 'mikan RSS');

    final base = Uri.parse('$baseUrl/');
    final items = <SourceItem>[];
    final seen = <String>{};
    var skipped = 0;
    var duplicates = 0;
    final warnings = <String>[];

    for (final node in doc.findAllElements('item')) {
      final title = _childText(node, 'title');
      final link = _childText(node, 'link');
      final guid = _childText(node, 'guid');
      final torrentNode = _childElement(node, 'torrent');

      final episodeHash = _episodeHashOf(link) ?? _torrentFileHash(node);
      final rawId = episodeHash ?? guid ?? link;
      if (rawId == null || rawId.isEmpty) {
        skipped++;
        continue;
      }
      final itemId = 'mikan:$rawId';
      if (!seen.add(itemId)) {
        // 同一集在 feed 里重复出现（mikan 常见），按 id 去重。
        duplicates++;
        continue;
      }

      final enclosure = _childElement(node, 'enclosure');
      final enclosureUrl = enclosure?.getAttribute('url');
      final enclosureLength = parseIntLoose(enclosure?.getAttribute('length'));
      final contentLength =
          parseIntLoose(_childText(torrentNode, 'contentLength')) ??
              enclosureLength;
      final pubDateRaw = firstNonEmpty(<String?>[
        _childText(torrentNode, 'pubDate'),
        _childText(node, 'pubDate'),
      ]);
      final sizeMB = _sizeFromDescription(_childText(node, 'description'));
      final parsed = TitleParser.parse(title ?? '', sourceId: sourceId);
      final fileHash = _torrentFileHash(node);

      items.add(SourceItem(
        id: itemId,
        sourceId: sourceId,
        title: title,
        detailUrl: resolveUri(base, link),
        torrentUrl: resolveUri(base, enclosureUrl)?.toString(),
        // spec §4.2：mikan RSS **没有 infoHash 与 magnet**，由 detail() 从
        // 单集页 HTML 的 magnet 补齐。这里显式留 null，绝不猜。
        magnet: null,
        infoHash: null,
        sizeBytes: contentLength ?? sizeMB,
        seeders: null,
        leechers: null,
        downloads: null,
        publishedAt: parseFeedDate(pubDateRaw),
        category: null,
        group: parsed.group,
        episodeHints: parsed.episodeHints,
        extra: <String, dynamic>{
          ...parsed.toExtra(),
          'contentLength': ?contentLength,
          // `/Download/<yyyyMMdd>/<40hex>.torrent` 里的 hash（详情页 magnet 的 btih 与它一致），
          // 但 RSS 本身没声明它是 infoHash，所以只作为线索放在 extra。
          'torrentFileHash': ?fileHash,
          'episodeHash': ?episodeHash,
          'guid': ?guid,
          if (_childText(torrentNode, 'link') != null)
            'torrentLink': _childText(torrentNode, 'link'),
          'enclosureLength': ?enclosureLength,
          if (_sizeTextFromDescription(_childText(node, 'description')) != null)
            'sizeText': _sizeTextFromDescription(_childText(node, 'description')),
        },
      ));
    }

    if (duplicates > 0) {
      warnings.add('同一 feed 里 $duplicates 条重复条目已按 id 去重');
    }
    return ParseOutcome(
      items: items,
      skipped: skipped,
      warnings: warnings,
    );
  }

  /// `https://mikanani.me/Home/Episode/<40hex>` → hash。
  static String? _episodeHashOf(String? link) {
    if (link == null) return null;
    return RegExp(r'/Home/Episode/([0-9a-fA-F]{40})').firstMatch(link)
        ?.group(1)
        ?.toLowerCase();
  }

  /// enclosure url 里的 `/Download/<yyyyMMdd>/<40hex>.torrent` → hash。
  static String? _torrentFileHash(XmlElement item) {
    final enclosure = _childElement(item, 'enclosure');
    final url = enclosure?.getAttribute('url');
    if (url == null) return null;
    return RegExp(r'/([0-9a-fA-F]{40})\.torrent').firstMatch(url)
        ?.group(1)
        ?.toLowerCase();
  }

  /// description 末尾的 `[1.2 GB]`。
  static int? _sizeFromDescription(String? description) {
    final text = _sizeTextFromDescription(description);
    return parseSizeToBytes(text);
  }

  static String? _sizeTextFromDescription(String? description) {
    if (description == null) return null;
    final m = RegExp(r'\[([^\[\]]{2,20})\]\s*$').firstMatch(description.trim());
    if (m == null) return null;
    final candidate = m.group(1)!;
    return parseSizeToBytes(candidate) == null ? null : candidate;
  }
}

/// mikan 单集页（`/Home/Episode/<hash>`）解析器：标题/大小/日期/字幕组/**magnet**。
class MikanEpisodeParser {
  const MikanEpisodeParser._();

  /// 页面结构不认识时返回 null。
  static SourceItem? parse(
    String htmlText, {
    required SourceItem base,
    required Uri url,
    required String sourceId,
    String baseUrl = mikanBaseUrl,
    required ClockFn clock,
  }) {
    final dom.Document doc;
    try {
      doc = html_parser.parse(htmlText);
    } catch (e) {
      throw SourceException('mikan 单集页解析失败: $e', sourceId: sourceId, cause: e);
    }

    final root = Uri.parse('$baseUrl/');
    final episodeTitleNode = doc.querySelector('p.episode-title');
    final bangumiTitleNode = doc.querySelector('p.bangumi-title a');

    String? rawEpisodeTitle =
        normalizeWhitespace(episodeTitleNode?.text) ?? base.title;
    // 单集页标题尾部带 `[1.2 GB]`，去掉后再进侧车做展示名。
    String? sizeText;
    if (rawEpisodeTitle != null) {
      final m = RegExp(r'\s*\[([^\[\]]{2,20})\]\s*$').firstMatch(rawEpisodeTitle);
      if (m != null && parseSizeToBytes(m.group(1)!) != null) {
        sizeText = m.group(1);
        rawEpisodeTitle =
            rawEpisodeTitle.substring(0, m.start).trim();
      }
    }

    String? group;
    String? infoSizeText;
    String? infoDateText;
    for (final p in doc.querySelectorAll('p.bangumi-info')) {
      final text = normalizeWhitespace(p.text) ?? '';
      if (text.startsWith('字幕组')) {
        group = normalizeWhitespace(
          p.querySelector('a.magnet-link-wrap')?.text ?? p.querySelector('a')?.text,
        );
      } else if (text.startsWith('文件大小')) {
        infoSizeText = text.contains('：')
            ? text.split('：').last.trim()
            : text.replaceFirst('文件大小', '').replaceAll(':', '').trim();
      } else if (text.startsWith('发布日期')) {
        infoDateText = text.contains('：')
            ? text.split('：').last.trim()
            : text.replaceFirst('发布日期', '').replaceAll(':', '').trim();
      }
    }

    String? magnet;
    String? torrentUrl;
    for (final a in doc.querySelectorAll('a')) {
      final href = a.attributes['href'] ?? '';
      if (magnet == null && href.startsWith('magnet:')) magnet = href;
      if (torrentUrl == null && href.contains('/Download/')) {
        torrentUrl = resolveUri(root, href)?.toString();
      }
    }
    magnet ??= extractMagnet(htmlText);

    final title = rawEpisodeTitle ?? bangumiTitleNode?.text;
    if (title == null && magnet == null && torrentUrl == null) return null;

    // 单集页里 `p.bangumi-title a` 指向 `/Home/Bangumi/<id>`：**整部番的剧集清单**
    // 就在那个页面上。用户 2026-10-11：「不会有前几集，我点第8集就没有765等」——
    // 播放列表要凑齐前几集，唯一可靠的来源就是这一页，所以把 id 带出去
    // （宿主再用 `bangumi()` 取全量剧集）。
    final String? bangumiId = RegExp(r'/Home/Bangumi/(\d+)')
        .firstMatch(bangumiTitleNode?.attributes['href'] ?? '')
        ?.group(1);

    final effectiveSizeText = infoSizeText ?? sizeText;
    // infoHash 只认页面里真实的 magnet；没有 magnet 就不猜（保持 base 的原值）。
    final hash = infoHashFromMagnet(magnet) ?? base.infoHash;
    final parsed = TitleParser.parse(title ?? '', sourceId: sourceId);

    return base.copyWith(
      title: title,
      detailUrl: base.detailUrl ?? url,
      torrentUrl: torrentUrl ?? base.torrentUrl,
      magnet: magnet ?? base.magnet,
      infoHash: hash ?? base.infoHash,
      sizeBytes: parseSizeToBytes(effectiveSizeText) ?? base.sizeBytes,
      publishedAt: parseRelativeDate(infoDateText, clock()) ??
          _dateFromTorrentUrl(torrentUrl) ??
          base.publishedAt,
      group: group ?? parsed.group ?? base.group,
      episodeHints:
          parsed.episodeHints.isEmpty ? base.episodeHints : parsed.episodeHints,
      extra: <String, dynamic>{
        ...base.extra,
        ...parsed.toExtra(),
        'detailFetched': true,
        if (bangumiTitleNode != null)
          'bangumiTitle': normalizeWhitespace(bangumiTitleNode.text),
        'bangumiId': ?bangumiId,
        'publishedText': ?infoDateText,
        'sizeText': ?effectiveSizeText,
      },
    );
  }

  static DateTime? _dateFromTorrentUrl(String? torrentUrl) {
    if (torrentUrl == null) return null;
    final m = RegExp(r'/Download/(\d{8})/').firstMatch(torrentUrl);
    if (m == null) return null;
    final s = m.group(1)!;
    return DateTime(
      int.parse(s.substring(0, 4)),
      int.parse(s.substring(4, 6)),
      int.parse(s.substring(6, 8)),
    );
  }
}

/// mikan 番剧详情页（`/Home/Bangumi/<id>`）解析器。
///
/// 结构：`div.subgroup-text[id]`（字幕组）与其后紧跟的
/// `table.table-striped.tbl-border`（该组的剧集列表）按文档顺序交替出现。
class MikanBangumiParser {
  const MikanBangumiParser._();

  static MikanBangumiDetail parse(
    String htmlText, {
    required Uri url,
    required String sourceId,
    String baseUrl = mikanBaseUrl,
    required ClockFn clock,
  }) {
    final dom.Document doc;
    try {
      doc = html_parser.parse(htmlText);
    } catch (e) {
      throw SourceException('mikan 番剧页解析失败: $e', sourceId: sourceId, cause: e);
    }

    final root = Uri.parse('$baseUrl/');
    final bangumiId = RegExp(r'/Home/Bangumi/(\d+)').firstMatch(url.path)?.group(1) ??
        '';
    final title = _pageTitle(doc);

    final groups = <MikanSubtitleGroup>[];
    final episodes = <SourceItem>[];
    final warnings = <String>[];
    var skipped = 0;
    MikanSubtitleGroup? current;

    final nodes = doc.querySelectorAll(
      'div.subgroup-text, table.table-striped.tbl-border',
    );
    if (nodes.isEmpty) {
      throw SourceException(
        'mikan 番剧页结构已变：既没有 div.subgroup-text 也没有剧集表格',
        sourceId: sourceId,
        url: url,
      );
    }

    for (final node in nodes) {
      final classes = node.classes;
      if (classes.contains('subgroup-text')) {
        final groupName = normalizeWhitespace(
          node.querySelector('a[href*="/Home/PublishGroup/"]')?.text,
        );
        final rssHref = node.querySelector('a.mikan-rss')?.attributes['href'];
        current = MikanSubtitleGroup(
          id: node.attributes['id'] ?? '',
          name: groupName ?? '未知字幕组',
          rssUrl: resolveUri(root, rssHref),
        );
        groups.add(current);
        continue;
      }

      // 剧集表格
      for (final row in node.querySelectorAll('tr')) {
        final item = _episodeItemFromRow(
          row,
          sourceId: sourceId,
          baseUrl: baseUrl,
          clock: clock,
          group: current,
          bangumiId: bangumiId.isEmpty ? null : bangumiId,
          bangumiTitle: title,
        );
        if (item == null) {
          // 表头行没有 <td>：那是正常的，不计入"跳过"。
          if (row.querySelectorAll('td').isEmpty) continue;
          skipped++;
          warnings.add('番剧页某行既没有 episode hash 也没有 magnet，已跳过');
          continue;
        }
        episodes.add(item);
      }
    }

    return MikanBangumiDetail(
      bangumiId: bangumiId,
      title: title,
      groups: groups,
      episodes: episodes,
      skipped: skipped,
      warnings: warnings,
    );
  }

  /// `<title>Mikan Project - 标题</title>`；也尝试 `p.bangumi-title`。
  static String? _pageTitle(dom.Document doc) {
    final fromBody = normalizeWhitespace(doc.querySelector('p.bangumi-title a')?.text);
    if (fromBody != null) return fromBody;
    final raw = normalizeWhitespace(doc.querySelector('title')?.text);
    if (raw == null) return null;
    return raw
        .replaceFirst(RegExp(r'^Mikan\s*Project\s*[-–—]\s*'), '')
        .trim();
  }
}

/// mikan 搜索页（`/Home/Search?searchstr=`）解析器。
///
/// 表格与番剧页**是同一个形状**（`table.table-striped.tbl-border` + 完全一样的 td 顺序），
/// 所以行解析共用 [_episodeItemFromRow]；区别只有两点：
/// 1. 搜索页没有 `div.subgroup-text` ⇒ 没有字幕组名（`SourceItem.group` 交给标题解析
///    的结果，或者为 null —— 不编一个"未知字幕组"的假名）；
/// 2. 搜索页一次给到 **1000 行**（实测），也**没有分页参数**，所以 `hasNext` 恒为 false。
class MikanSearchParser {
  const MikanSearchParser._();

  static ParseOutcome parse(
    String htmlText, {
    required String sourceId,
    String baseUrl = mikanBaseUrl,
    required ClockFn clock,
  }) {
    final dom.Document doc;
    try {
      doc = html_parser.parse(htmlText);
    } catch (e) {
      throw SourceException('mikan 搜索页解析失败: $e', sourceId: sourceId, cause: e);
    }

    // 先确认"这确实是一张 mikan 页面"：搜索表单在每个 mikan 页面上都有，
    // 连"没有搜索结果"的空结果页也有。所以它是"页面身份"的判据，而不是"有多少条"。
    // 拿它当门禁，是为了把"站点结构变了/被中间设备劫持"和"这次真的没搜到"分开：
    // 前者必须抛错（禁止假成功），后者是合法的空结果。
    if (doc.querySelector('input[name="searchstr"]') == null) {
      throw SourceException(
        'mikan 搜索页结构已变：页面里找不到搜索表单（input[name="searchstr"]），'
        '拿到的可能不是搜索结果页',
        sourceId: sourceId,
        url: Uri.parse('$baseUrl/Home/Search'),
      );
    }

    final items = <SourceItem>[];
    var skipped = 0;
    final warnings = <String>[];

    for (final row in doc.querySelectorAll('tr.js-search-results-row')) {
      final item = _episodeItemFromRow(
        row,
        sourceId: sourceId,
        baseUrl: baseUrl,
        clock: clock,
      );
      if (item == null) {
        skipped++;
        warnings.add('搜索页某行既没有 episode hash 也没有 magnet，已跳过');
        continue;
      }
      items.add(item);
    }

    return ParseOutcome(items: items, hasNext: false, skipped: skipped, warnings: warnings);
  }
}

/// 解析番剧页 / 搜索页表格里的**一行剧集**（两个页面表格形状相同，只写一份）。
///
/// 列顺序（实测 2026-10-12）：`td[0]` 勾选框（`input.js-episode-select[data-magnet]`）、
/// `td[1]` 标题（`a.magnet-link-wrap` → `/Home/Episode/<40hex>`，旁边
/// `a.js-magnet[data-clipboard-text]` 再给一份磁力）、`td[2]` 大小、`td[3]` 日期、
/// `td[4]` `.torrent` 直链。
///
/// 返回 null = 这一行不是可识别的剧集行（既没有 episode hash 也没有合法磁力）——
/// 调用方按"跳过"计数，**绝不塞一条空壳条目**（那会在列表里多出一行点不动的垃圾）。
SourceItem? _episodeItemFromRow(
  dom.Element row, {
  required String sourceId,
  required String baseUrl,
  required ClockFn clock,
  MikanSubtitleGroup? group,
  String? bangumiId,
  String? bangumiTitle,
}) {
  final cells = row.querySelectorAll('td');
  if (cells.length < 5) return null;

  final root = Uri.parse('$baseUrl/');
  final href = cells[1].querySelector('a.magnet-link-wrap')?.attributes['href'] ??
      cells[1].querySelector('a')?.attributes['href'];
  final hash = href == null
      ? null
      : RegExp(r'/Home/Episode/([0-9a-fA-F]{40})')
          .firstMatch(href)
          ?.group(1)
          ?.toLowerCase();
  String? magnet =
      cells[0].querySelector('input.js-episode-select')?.attributes['data-magnet'];
  if (magnet == null || infoHashFromMagnet(magnet) == null) {
    magnet = extractMagnet(
      cells[1].querySelector('a.js-magnet')?.attributes['data-clipboard-text'],
    );
  }
  if (hash == null && magnet == null) return null;

  final rowTitle =
      normalizeWhitespace(cells[1].querySelector('a.magnet-link-wrap')?.text) ??
          normalizeWhitespace(cells[1].text);
  final sizeText = normalizeWhitespace(cells[2].text);
  final dateText = normalizeWhitespace(cells[3].text);
  final torrentUrl = resolveUri(
    root,
    cells[4].querySelector('a')?.attributes['href'],
  )?.toString();
  final parsed = TitleParser.parse(rowTitle ?? '', sourceId: sourceId);

  return SourceItem(
    id: 'mikan:${hash ?? infoHashFromMagnet(magnet)}',
    sourceId: sourceId,
    title: rowTitle,
    detailUrl: hash == null ? null : Uri.parse('$baseUrl/Home/Episode/$hash'),
    torrentUrl: torrentUrl,
    magnet: magnet,
    infoHash: infoHashFromMagnet(magnet) ?? hash,
    sizeBytes: parseSizeToBytes(sizeText),
    publishedAt: parseFeedDate(dateText),
    group: group?.name ?? parsed.group,
    episodeHints: parsed.episodeHints,
    extra: <String, dynamic>{
      ...parsed.toExtra(),
      if (group != null) 'subtitleGroupId': group.id,
      'bangumiId': ?bangumiId,
      'bangumiTitle': ?bangumiTitle,
      'sizeText': ?sizeText,
      'publishedText': ?dateText,
    },
  );
}

/// 取命名空间无关的直接子元素文本（`torrent` 用默认命名空间，
/// 部分 feed 又会用前缀，按 local name 匹配最稳）。
String? _childText(XmlElement? parent, String localName) {
  if (parent == null) return null;
  final child = _childElement(parent, localName);
  return child == null ? null : normalizeWhitespace(child.innerText);
}

XmlElement? _childElement(XmlElement? parent, String localName) {
  if (parent == null) return null;
  for (final child in parent.childElements) {
    if (child.name.local == localName) return child;
  }
  return null;
}
