/// ACG.RIP（`https://acg.rip/`）源 —— 动画区 `/1`、合集区 `/5`
/// （用户 2026-10-12 第 9 轮：「加入源 https://acg.rip/1 … https://acg.rip/，
/// 分区是动漫和全集的」）。
///
/// 站点实测（2026-10-12，样本见 `core/test/fixtures/acgrip_*.html`）：
/// * 首页导航就是分区：`/1` 动画、`/2` 日剧、`/3` 综艺、`/4` 音乐、`/5` 合集、`/9` 其它；
/// * 列表页 `table.post-index` 一行四格：发布者（含 `<time datetime="<unix秒>">`）、
///   标题（`span.title a[href=/t/<id>]`）、`DL`（`/t/<id>.torrent`）、大小；
/// * 翻页：`/1/page/2`，**最后一页没有 `a[rel=next]`**（拿它判 hasNext）；
/// * 搜索：`?term=<关键字>`，**在分区内生效**（实测 `/1?term=学生会` 回 30 条动画、
///   `/5?term=学生会` 回 8 条合集），翻页是 `/1/page/2?term=…`。
///
/// ## ⚠️ 这个站一处 magnet 都没有
/// 列表页与详情页实测 `magnet:` 出现 **0** 次（只有 `.torrent` 直链），而引擎加种
/// 只认 magnet / 40 位 hex infohash。所以 [detail] 会下载那个 `.torrent`
/// （实测 20–50 KB）并算出 `sha1(bencode(info))` —— infohash 的定义本身，
/// 见 `bencode.dart` 的注释（那里记了与 ACGNX 同种子的互证）。点播/下载时才走这一步，
/// 列表页不会为 30 条结果各下一份种子。
library;

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

import '../subs/title_parser.dart';
import 'bencode.dart';
import 'cache.dart';
import 'http.dart';
import 'models.dart';
import 'parse_off_thread.dart';
import 'parsing.dart';
import 'source_client.dart';

/// ACG.RIP 站点根。
const String acgRipBaseUrl = 'https://acg.rip';

/// 「动画」分区（`https://acg.rip/1`）。
const String kAcgRipAnimeCategory = '1';

/// 「合集」分区（`https://acg.rip/5`）—— 用户说的「全集」在这个站叫合集。
const String kAcgRipBatchCategory = '5';

/// 列表页解析的**顶层**入口（1.1.0 M1/T6 起进子 isolate）。
///
/// 为什么是顶层函数：实例方法里造的闭包会连 `this` 一起捕获，`Isolate.run` 送不进去
/// （第四十七轮 mikan 实测，见 `parse_off_thread.dart` 文件头）。小页在
/// [parseOffThread] 里仍同步解析，行为与改动前一致。
Future<ParseOutcome> _parseListOffThread({
  required String body,
  required String sourceId,
  required String baseUrl,
  required String categoryLabel,
  required DateTime now,
}) => parseOffThread<ParseOutcome>(
  text: body,
  now: now,
  compute: (DateTime at) => AcgRipListParser.parse(
    body,
    sourceId: sourceId,
    baseUrl: baseUrl,
    categoryLabel: categoryLabel,
    clock: () => at,
  ),
);

class AcgRipSource extends CachedSourceClient {
  AcgRipSource({
    required super.http,
    required super.cache,
    this.category = kAcgRipAnimeCategory,
    this.baseUrl = acgRipBaseUrl,
    String? id,
    String? displayName,
    super.clock,
  })  : _id = id ?? 'acgrip',
        _displayName = displayName ?? 'ACG.RIP · 动画';

  /// 分区路径段：`1` 动画、`5` 合集。
  final String category;

  final String baseUrl;
  final String _id;
  final String _displayName;

  @override
  String get id => _id;

  @override
  String get displayName => _displayName;

  @override
  bool get supportsSearch => true;

  /// 这个分区在站点上的名字（`动画` / `合集`）—— 当作条目的 `category`。
  ///
  /// 为什么敢这么填：搜索也是**在分区内**生效的（`/1?term=`），所以一条结果属于
  /// 哪个分区是站点自己给的，不是我们猜的。
  String get categoryLabel =>
      category == kAcgRipBatchCategory ? '合集' : '动画';

  /// 「最新」第 [page] 页：`/1`、`/1/page/2`。
  Uri latestUri(int page) => page <= 1
      ? Uri.parse('$baseUrl/$category')
      : Uri.parse('$baseUrl/$category/page/$page');

  /// 搜索第 [page] 页：`/1?term=…`、`/1/page/2?term=…`。
  ///
  /// 关键字走 `queryParameters`（UTF-8 百分号编码交给 `Uri`），绝不手工拼字符串。
  Uri searchUri(String keyword, int page) {
    final Uri base =
        page <= 1 ? Uri.parse('$baseUrl/$category') : Uri.parse('$baseUrl/$category/page/$page');
    return base.replace(queryParameters: <String, String>{'term': keyword});
  }

  /// 某个条目的 `.torrent` 直链。
  Uri torrentUri(String topicId) => Uri.parse('$baseUrl/t/$topicId.torrent');

  @override
  Future<SourcePage> latest({int page = 1}) async {
    if (page < 1) {
      throw SourceException('page 必须 >= 1（收到 $page）', sourceId: id);
    }
    return loadPage(
      request: CacheRequest.latest(page: page),
      fetch: () async {
        final body = await http.getText(latestUri(page), sourceId: id);
        // 一页实测 27KB/30 行：不大，但别把"一般"当保证 —— 按阈值分流。
        final outcome = await _parseListOffThread(
          body: body,
          sourceId: id,
          baseUrl: baseUrl,
          categoryLabel: categoryLabel,
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
        final body = await http.getText(searchUri(q, page), sourceId: id);
        final outcome = await _parseListOffThread(
          body: body,
          sourceId: id,
          baseUrl: baseUrl,
          categoryLabel: categoryLabel,
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

  /// 补 infohash：下载 `.torrent` 原始字节 → `sha1(bencode(info))`。
  ///
  /// 结果按 [CacheRequest.detail] 缓存（detail TTL 由设置控制），所以同一条结果反复点播
  /// 只下一次种子。**只有 infohash 是真的才返回**；算不出来就抛可行动错误，
  /// 绝不返回一个"看着能播"的假磁力。
  @override
  Future<SourceItem?> detail(SourceItem item) async {
    final topicId = AcgRipSource.topicIdOf(item);
    if (topicId == null) return null;

    final request = CacheRequest.detail(item.id);
    final cached = await cache.get(id, request);
    final cachedItem = _itemFromPayload(cached?.payload);
    if (cachedItem != null) return cachedItem;

    final uri = torrentUri(topicId);
    try {
      final fetched = await http.fetch(uri, sourceId: id);
      final infoHash = infoHashFromTorrentBytes(fetched.bytes);
      if (infoHash == null) {
        throw SourceException(
          'ACG.RIP 的种子文件里没有可识别的 info 字典（页面可能已变）: $uri',
          sourceId: id,
          url: uri,
        );
      }
      final enriched = item.copyWith(
        infoHash: infoHash,
        // 站点自己的大小是「225.2 MB」这种十进制近似值；种子内部才是精确字节数。
        sizeBytes: torrentTotalBytesFromBytes(fetched.bytes) ?? item.sizeBytes,
        torrentUrl: item.torrentUrl ?? uri.toString(),
        extra: <String, dynamic>{
          ...item.extra,
          'infoHashFromTorrent': true,
          if (torrentNameFromBytes(fetched.bytes) case final String name)
            'torrentName': name,
        },
      );
      await cache.put(id, request, <String, dynamic>{'item': enriched.toJson()});
      return enriched;
    } on SourceException {
      final stale = await cache.get(id, request, allowStale: true);
      final staleItem = _itemFromPayload(stale?.payload);
      if (staleItem != null) return staleItem;
      rethrow;
    }
  }

  /// `acgrip:365077` / `acgrip-batch:365077` / `/t/365077` → `365077`。
  ///
  /// 前缀用「源 id + `:`」，所以两个分区的实例各自生成不同的条目 id
  /// （同一条目在两个分区不会互相覆盖，也不会撞上删除墓碑）。
  static String? topicIdOf(SourceItem item) {
    final fromId = RegExp(r'^acgrip[^:]*:(\d+)$').firstMatch(item.id);
    if (fromId != null) return fromId.group(1);
    final path = item.detailUrl?.path ?? '';
    return RegExp(r'/t/(\d+)').firstMatch(path)?.group(1);
  }
}

/// ACG.RIP 列表页（`table.post-index`）解析器。
///
/// 列顺序（实测）：`0 发布者 | 1 标题 | 2 DL | 3 大小`。
class AcgRipListParser {
  const AcgRipListParser._();

  static ParseOutcome parse(
    String htmlText, {
    required String sourceId,
    String baseUrl = acgRipBaseUrl,
    String? categoryLabel,
    required ClockFn clock,
  }) {
    final dom.Document doc;
    try {
      doc = html_parser.parse(htmlText);
    } catch (e) {
      throw SourceException('ACG.RIP 列表页解析失败: $e', sourceId: sourceId, cause: e);
    }

    final table = doc.querySelector('table.post-index') ??
        doc.querySelector('table.table-hover');
    if (table == null) {
      // **不返回空列表**：拿到的可能是错误页/门户首页，"0 条结果"与"页面结构变了"
      // 对用户是两件事，静默空表会把后者伪装成前者。
      throw SourceException(
        'ACG.RIP HTML 结构已变：列表页里找不到 table.post-index',
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
      if (cells.isEmpty) continue; // 表头（<th>）行
      if (cells.length < 4) {
        skipped++;
        warnings.add('某行只有 ${cells.length} 个单元格（期望 4），已跳过');
        continue;
      }

      final anchor = cells[1].querySelector('a[href*="/t/"]') ??
          cells[1].querySelector('a');
      final href = anchor?.attributes['href'] ?? '';
      final title = normalizeWhitespace(anchor?.text) ?? '';
      final topicId = RegExp(r'/t/(\d+)').firstMatch(href)?.group(1);
      if (topicId == null || title.isEmpty) {
        skipped++;
        warnings.add('某行找不到 /t/<id> 或标题为空，已跳过');
        continue;
      }

      final time = cells[0].querySelector('time');
      final publishedRaw = time?.attributes['datetime'] ?? normalizeWhitespace(cells[0].text);
      final sizeText = normalizeWhitespace(cells[3].text);
      final torrentHref = cells[2].querySelector('a[href*=".torrent"]')?.attributes['href'];
      final team = normalizeWhitespace(cells[1].querySelector('span.label-team a')?.text);
      final parsed = TitleParser.parse(title, sourceId: sourceId);

      items.add(SourceItem(
        id: '$sourceId:$topicId',
        sourceId: sourceId,
        title: title,
        detailUrl: resolveUri(base, '/t/$topicId'),
        // 列表行里就有 `.torrent` 直链（不像 dmhy 只有磁力），照实记下来。
        torrentUrl: torrentHref == null ? null : resolveUri(base, torrentHref)?.toString(),
        // 这个站**没有磁力**：infohash 要等 detail() 下种子算，列表页不编。
        magnet: null,
        infoHash: null,
        sizeBytes: parseSizeToBytes(sizeText),
        seeders: null,
        leechers: null,
        downloads: null,
        publishedAt: parseFeedDate(publishedRaw),
        category: categoryLabel,
        group: parsed.group ?? team,
        episodeHints: parsed.episodeHints,
        extra: <String, dynamic>{
          ...parsed.toExtra(),
          'sizeText': ?sizeText,
          'team': ?team,
          'partition': ?categoryLabel,
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

  /// 有没有下一页。
  ///
  /// 为什么只看 `a[rel=next]`：ACG.RIP 的翻页条在**最后一页**只留 `上一页` 与数字，
  /// `rel="next"` 那个 `<a>` 直接不输出（实测 `/1/page/10663`），没有 disabled 类可判。
  static bool _hasNextPage(dom.Document doc) {
    for (final a in doc.querySelectorAll('a[rel="next"]')) {
      if ((a.attributes['href'] ?? '').isNotEmpty) return true;
    }
    return false;
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
