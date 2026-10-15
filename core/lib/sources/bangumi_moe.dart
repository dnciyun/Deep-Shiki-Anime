/// bangumi.moe（番組、萌え，`https://bangumi.moe/`）源
/// （用户 2026-10-12 第 10 轮：「再添加源 https://bangumi.moe/」）。
///
/// ## 为什么走 JSON API 而不是抓网页
/// 站点是 AngularJS SPA：`GET /` 只有 4 KB 的空壳（列表全靠 JS 拉接口），HTML 里
/// **一个字的内容都没有**。而它的 JSON API 是公开的，字段比网页还全：
/// magnet、infoHash、体积、做种/下载/完成数、发布时间、分类 tag、字幕组 team_id，
/// 一次给全。实测的三个端点：
///
/// | 用途 | 请求 | 返回 |
/// |---|---|---|
/// | 分区列表 | `POST /api/torrent/search` body `{type:'tag', tag_id:[…], p:<n>}` | `{torrents[30], count, page_count?}` |
/// | 关键词搜索 | `GET /api/v2/torrent/search?query=<kw>`（第 2 页起加 `&p=<n>`） | `{torrents[30], count, page_count, success}` |
/// | 字幕组改名 | `POST /api/team/fetch` body `{_ids:[…]}` | `[{_id, name, …}]` |
///
/// 三个都实测过（样本见 `core/test/fixtures/bangumi_moe_*.json`，
/// 抓取时间/命令记在 `core/test/fixtures/README.md`）。
///
/// * **分区只能用 POST**：`GET /api/torrent/search?…` 一律 404
///   （`{"errno":404,"message":"Page Not Found"}`），所以本源的列表走 POST —— 这也是
///   `SourceHttp.postJson` 存在的原因（见那里的说明：自己 new http.Client 会绕过代理/限速）。
/// * **`page_count` 只在 `p=1` 时给**：`p>=2` 的响应只有 `{torrents}`。所以
///   `hasNext` 第 1 页用站点原话（`page < page_count`），之后只能按「这一页满没满
///   30 条」推 —— 站点每页固定 30 条，不满就是到底了（实测最后一页 20 条 / 5 条）。
/// * **关键词搜索是全站的**：v2 接口**不接受**分区过滤（带 `tag_id` 实测返回空对象
///   `{}`），所以两个分区实例的搜索结果一样。这是站点限制，不是本源的实现取舍 ——
///   宁可如实说「搜索全站」，也不在前端偷偷按分类过滤（那会让翻页莫名变空）。
///   分类名也如实取站点自己报的那个（v2 搜索的响应内嵌 `category_tag`），
///   只有分区列表（响应里没有该字段）才用源自己的分区名。
/// * 限流：短时间内猛打会回 `{"success":false,"message":"too frequently"}`。本源把它
///   当**错误**抛（附可行动文案），绝不当成「0 条结果」—— 后者会把「被限流」伪装成
///   「没搜到」。正常使用（一次点击一次请求 + 设置页的请求间隔）不会撞上。
/// * 不需要 `detail()`：列表里 magnet/infoHash 就已经有了（不像 ACG.RIP 只有 `.torrent`
///   直链，要下种子算 hash）。字幕组名是**锦上添花**：换不到就让 `group` 留空，
///   绝不让列表失败。
///
/// ## 两个分区（与第 9 轮的 dmhy / acgrip / acgnx 同样的做法）
/// * `bangumimoe`（動畫）= tag `Donga`；
/// * `bangumimoe-collection`（動畫合集）= `Donga` **且** `Collection`
///   （实测 count=3213 / page_count=108；只给 `Collection` 是 10574 条，会把电影、
///   音乐、游戏、真人剧的合集一起拉进来 —— 这是个看番工具，不该那样）。
library;

import 'dart:convert';

import '../subs/title_parser.dart';
import 'cache.dart';
import 'http.dart';
import 'models.dart';
import 'parsing.dart';
import 'source_client.dart';

/// 站点根。
const String bangumiMoeBaseUrl = 'https://bangumi.moe';

/// 「動畫」分类 tag（站点内部名 `Donga`，`locale.zh_cn = 动画`）。
const String kBangumiMoeDongaTagId = '549ef207fe682f7549f1ea90';

/// 「合集」标签（misc 类型的 `Collection`）。
const String kBangumiMoeCollectionTagId = '54967e14ff43b99e284d0bf7';

/// 動畫分区：只带 `Donga`。
const List<String> kBangumiMoeAnimeTags = <String>[kBangumiMoeDongaTagId];

/// 動畫合集分区：`Donga` + `Collection`（tag 之间是 **AND**：实测返回的每条都同时带
/// 这两个 tag，count 也正好落在「只带 Donga」与「只带 Collection」之间）。
const List<String> kBangumiMoeAnimeCollectionTags = <String>[
  kBangumiMoeDongaTagId,
  kBangumiMoeCollectionTagId,
];

/// 站点每页条数（实测 `/api/torrent/page/N` 与 `POST /api/torrent/search` 都是 30）。
const int kBangumiMoePageSize = 30;

/// bangumi.moe 源（一个实例 = 一个分区）。
class BangumiMoeSource extends CachedSourceClient {
  BangumiMoeSource({
    required super.http,
    required super.cache,
    this.baseUrl = bangumiMoeBaseUrl,
    List<String>? tagIds,
    this.partitionLabel = '動畫',
    String? id,
    String? displayName,
    super.clock,
  })  : tagIds = List<String>.unmodifiable(tagIds ?? kBangumiMoeAnimeTags),
        _id = id ?? 'bangumimoe',
        _displayName = displayName ?? 'Bangumi.moe · 動畫' {
    if (this.tagIds.isEmpty) {
      throw ArgumentError(
        'tagIds 不能为空：这个源是按 tag 分区的'
        '（動畫 = Donga；動畫合集 = Donga + Collection），'
        '站点也没有「不带 tag 的分区列表」这种 GET 端点',
      );
    }
  }

  final String baseUrl;

  /// 分区标签（多个 = 同时带这些标签）。
  final List<String> tagIds;

  /// 进 `SourceItem.category` 的分区名（列表接口不返回分区名本身）。
  final String partitionLabel;

  final String _id;
  final String _displayName;

  /// 最近一次解析里被丢掉的条目数 / 非致命告警（诊断用，与 [SourceCache.lastError]
  /// 同一风格：可观测，但不进 `SourcePage`）。
  int lastSkipped = 0;
  List<String> lastWarnings = const <String>[];

  @override
  String get id => _id;

  @override
  String get displayName => _displayName;

  @override
  bool get supportsSearch => true;

  /// 分区列表端点（**POST**，见库注释：GET 版本 404）。
  Uri latestUri() => Uri.parse('$baseUrl/api/torrent/search');

  /// 分区列表第 [page] 页的请求体。
  Map<String, Object?> latestBody(int page) => <String, Object?>{
    'type': 'tag',
    'tag_id': tagIds,
    'p': page,
  };

  /// 关键词搜索 URL。
  ///
  /// 第 1 页**不带** `p`（站点第 1 页本来就不给这个参数，`?query=…&p=1` 实测同结果，
  /// 少一个参数少一次校验分歧）；第 2 页起带上。
  /// 中文关键字走 `queryParameters`（UTF-8 百分号编码交给 Uri），绝不手工拼字符串。
  Uri searchUri(String keyword, int page) => Uri.parse('$baseUrl/api/v2/torrent/search')
      .replace(
        queryParameters: <String, String>{
          'query': keyword,
          if (page > 1) 'p': '$page',
        },
      );

  /// 字幕组批量改名端点（POST）。
  Uri teamFetchUri() => Uri.parse('$baseUrl/api/team/fetch');

  /// 条目详情页（网页，给人点的）。
  Uri detailUriOf(String torrentId) => Uri.parse('$baseUrl/torrent/$torrentId');

  /// `.torrent` 直链。
  ///
  /// 站点自己的前端就是这么拼的：
  /// `"/download/torrent/" + _id + "/" + title.replace(/[<>:"/\\|*?]/g, "_") + ".torrent"`。
  /// 这里照抄同一套替换，剩下的交给 [Uri.encodeComponent]（中文/空格百分号编码）。
  Uri torrentUriOf(String torrentId, String title) {
    final String safe = title.replaceAll(RegExp(r'[<>:"/\\|?*]'), '_');
    return Uri.parse(
      '$baseUrl/download/torrent/$torrentId/${Uri.encodeComponent(safe)}.torrent',
    );
  }

  @override
  Future<SourcePage> latest({int page = 1}) async {
    _requirePage(page);
    return loadPage(
      request: CacheRequest.latest(page: page),
      fetch: () async {
        final HttpFetch fetched = await http.postJson(
          latestUri(),
          body: latestBody(page),
          sourceId: id,
        );
        return _buildPage(fetched.body, page: page);
      },
    );
  }

  @override
  Future<SourcePage> search(String keyword, {int page = 1}) async {
    final String q = keyword.trim();
    if (q.isEmpty) {
      throw SourceException('搜索关键字不能为空', sourceId: id);
    }
    _requirePage(page);
    return loadPage(
      request: CacheRequest.search(q, page: page),
      fetch: () async {
        final String body = await http.getText(searchUri(q, page), sourceId: id);
        return _buildPage(body, page: page);
      },
    );
  }

  /// JSON 文本 → 一页条目（先解析、再换字幕组名、最后建条目）。
  ///
  /// 三段分开是为了**只 `jsonDecode` 一次**：字幕组名要等一次网络往返才知道，
  /// 如果"解析 → 换名 → 再解析"就会把几十 KB 的 JSON 解两遍。
  Future<SourcePage> _buildPage(String body, {required int page}) async {
    final BangumiMoeRawPage raw = BangumiMoeParser.readPage(body, sourceId: id);
    final Map<String, String> teams = await _teamNames(raw.teamIds);
    lastSkipped = raw.skipped;
    lastWarnings = raw.warnings;
    return SourcePage(
      items: <SourceItem>[
        for (final Map<String, dynamic> torrent in raw.torrents)
          BangumiMoeParser.toItem(
            torrent,
            sourceId: id,
            partitionLabel: partitionLabel,
            detailUri: detailUriOf,
            torrentUri: torrentUriOf,
            teamNames: teams,
          ),
      ],
      hasNext: _hasNext(raw, page),
      page: page,
      fetchedAt: clock(),
    );
  }

  /// 「还有下一页」：站点只在第 1 页给 `page_count`，之后只能按"这一页满不满"推。
  bool _hasNext(BangumiMoeRawPage raw, int page) {
    final int? pageCount = raw.pageCount;
    if (pageCount != null) return page < pageCount;
    return raw.torrents.length >= kBangumiMoePageSize;
  }

  void _requirePage(int page) {
    if (page < 1) {
      throw SourceException('page 必须 >= 1（收到 $page）', sourceId: id);
    }
  }

  /// team_id → 字幕组名（进程内记忆，见库注释：换不到就让 group 留空）。
  final Map<String, String> _teamNamesCache = <String, String>{};

  Future<Map<String, String>> _teamNames(List<String> ids) async {
    final List<String> unknown = <String>{
      for (final String teamId in ids)
        if (teamId.isNotEmpty && !_teamNamesCache.containsKey(teamId)) teamId,
    }.toList(growable: false);
    if (unknown.isEmpty) return _teamNamesCache;
    try {
      final HttpFetch fetched = await http.postJson(
        teamFetchUri(),
        body: <String, Object?>{'_ids': unknown},
        sourceId: id,
      );
      for (final Map<String, dynamic> team in BangumiMoeParser.readTeams(
        fetched.body,
      )) {
        final Object? teamId = team['_id'];
        final Object? name = team['name'];
        if (teamId is String && name is String && name.trim().isNotEmpty) {
          _teamNamesCache[teamId] = name.trim();
        }
      }
    } catch (_) {
      // 换不到名字不影响列表：v2 搜索的响应里自带 team.name，那条路不依赖这个接口；
      // 列表这条路的 group 就先留空。下一次列表请求（缓存过期后）会再试。
    }
    return _teamNamesCache;
  }
}

/// 一页 JSON 的"原始"形态：还带着 `_id` / `team_id`，没换成 [SourceItem]。
class BangumiMoeRawPage {
  const BangumiMoeRawPage({
    required this.torrents,
    this.pageCount,
    this.count,
    this.skipped = 0,
    this.warnings = const <String>[],
  });

  final List<Map<String, dynamic>> torrents;

  /// 站点给的总页数；`p>=2` 的响应里**没有**这个字段（所以是 nullable）。
  final int? pageCount;

  /// 站点给的命中总数（同样是第 1 页才有）。
  final int? count;

  final int skipped;
  final List<String> warnings;

  /// 这一页里**还需要另外换名字**的 team id。
  ///
  /// 记录自带 `team.name` 的（v2 搜索的响应就是这种）不算 —— 否则明明已经拿到名字，
  /// 还要为一个已经知道答案的问题多打一次网络。
  List<String> get teamIds => <String>[
    for (final Map<String, dynamic> t in torrents)
      if (t['team_id'] is String &&
          BangumiMoeParser.embeddedTeamName(t) == null)
        t['team_id'] as String,
  ];

  @override
  String toString() =>
      'BangumiMoeRawPage(torrents=${torrents.length}, pageCount=$pageCount, '
      'count=$count, skipped=$skipped)';
}

/// bangumi.moe JSON 解析器（纯函数，永不联网）。
class BangumiMoeParser {
  const BangumiMoeParser._();

  /// 解析 `{torrents:[…], count, page_count}`；结构不对/站点限流一律抛
  /// [SourceException]（**不返回空列表演戏**：0 条结果是合法状态，但"被限流"和
  /// "接口结构变了"不是）。
  static BangumiMoeRawPage readPage(String body, {required String sourceId}) {
    final Object? decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException catch (e) {
      throw SourceException(
        'bangumi.moe 返回的不是 JSON（可能撞上了反爬/错误页，站点结构也可能已变）: '
        '${_snippet(body)}',
        sourceId: sourceId,
        cause: e,
      );
    }
    final Map<String, dynamic>? map = decoded is Map
        ? decoded.map(
            (dynamic k, dynamic v) => MapEntry<String, dynamic>(k.toString(), v),
          )
        : null;
    final Object? rawList = map?['torrents'];
    if (map == null || rawList is! List) {
      // 限流时它回 `{"success":false,"message":"too frequently"}`：必须抛，
      // 不能当成 0 条 —— 那等于把「被限流」说成「没搜到」。
      final Object? message = map?['message'];
      final String detail = message is String && message.trim().isNotEmpty
          ? message.trim()
          : _snippet(body);
      throw SourceException(
        'bangumi.moe 没有给出结果列表（站点原话：$detail）'
        '${detail.toLowerCase().contains('frequently') ? '｜稍等几秒再试一次（站点限流）' : ''}',
        sourceId: sourceId,
      );
    }

    final torrents = <Map<String, dynamic>>[];
    final warnings = <String>[];
    var skipped = 0;
    for (final Object? raw in rawList) {
      if (raw is! Map) {
        skipped++;
        warnings.add('某条记录不是 JSON 对象，已跳过');
        continue;
      }
      final Map<String, dynamic> torrent = raw.map(
        (dynamic k, dynamic v) => MapEntry<String, dynamic>(k.toString(), v),
      );
      final String torrentId = _stringOf(torrent['_id']) ?? '';
      final String title = _stringOf(torrent['title']) ?? '';
      if (torrentId.isEmpty || title.isEmpty) {
        skipped++;
        warnings.add('某条记录缺 _id 或 title，已跳过（没有稳定 id 就没法入队/去重）');
        continue;
      }
      torrents.add(torrent);
    }

    return BangumiMoeRawPage(
      torrents: torrents,
      pageCount: _intOf(map['page_count']),
      count: _intOf(map['count']),
      skipped: skipped,
      warnings: warnings,
    );
  }

  /// 解析 `POST /api/team/fetch` 的响应（`[{_id, name, …}]`）；坏数据返回空表
  /// （字幕组名丢了不该让整页失败）。
  static List<Map<String, dynamic>> readTeams(String body) {
    final Object? decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException {
      return const <Map<String, dynamic>>[];
    }
    if (decoded is! List) return const <Map<String, dynamic>>[];
    return <Map<String, dynamic>>[
      for (final Object? raw in decoded)
        if (raw is Map)
          raw.map(
            (dynamic k, dynamic v) =>
                MapEntry<String, dynamic>(k.toString(), v),
          ),
    ];
  }

  /// 一条 torrent 记录 → [SourceItem]。
  ///
  /// [teamNames] 是 `team_id → 名字` 的记忆表；记录里若自带 `team.name`
  /// （v2 搜索的响应就是这种）优先用记录里那份。
  static SourceItem toItem(
    Map<String, dynamic> raw, {
    required String sourceId,
    required String partitionLabel,
    required Uri Function(String torrentId) detailUri,
    required Uri Function(String torrentId, String title) torrentUri,
    Map<String, String> teamNames = const <String, String>{},
  }) {
    final String torrentId = _stringOf(raw['_id']) ?? '';
    final String title = _stringOf(raw['title']) ?? '';
    final String? magnet = extractMagnet(_stringOf(raw['magnet']));
    final String? sizeText = normalizeWhitespace(_stringOf(raw['size']));
    final TitleParseResult parsed = TitleParser.parse(title, sourceId: sourceId);
    final String? teamName = _teamNameOf(raw, teamNames) ?? parsed.group;
    final List<Object?> content = raw['content'] is List
        ? List<Object?>.from(raw['content'] as List)
        : const <Object?>[];
    final Map<String, dynamic>? sync = raw['sync'] is Map
        ? (raw['sync'] as Map).map(
            (dynamic k, dynamic v) =>
                MapEntry<String, dynamic>(k.toString(), v),
          )
        : null;

    return SourceItem(
      id: '$sourceId:$torrentId',
      sourceId: sourceId,
      title: title,
      detailUrl: detailUri(torrentId),
      // 列表里就有 .torrent 直链与磁力两条路；磁力优先（bestMagnet）。
      torrentUrl: torrentUri(torrentId, title).toString(),
      magnet: magnet,
      infoHash:
          normalizeInfoHash(_stringOf(raw['infoHash'])) ??
          infoHashFromMagnet(magnet),
      sizeBytes: parseSizeToBytes(sizeText),
      // ⚠️ 0 是站点真实上报的值（刚发布的种子就是 0），不是"拿不到" —— 别换成 null。
      seeders: _intOf(raw['seeders']),
      leechers: _intOf(raw['leechers']),
      downloads: _intOf(raw['downloads']),
      publishedAt: parseFeedDate(_stringOf(raw['publish_time'])),
      // 分类：站点自己报了就用它的（v2 搜索的响应内嵌 `category_tag`），
      // 没报就用源自己的分区名（分区列表的响应里没有 `category_tag`，而那张列表
      // 本来就是按 tag 取的 —— 分区名就是真话）。
      category: embeddedCategoryName(raw) ?? partitionLabel,
      group: teamName,
      episodeHints: parsed.episodeHints,
      extra: <String, dynamic>{
        ...parsed.toExtra(),
        'group': ?teamName,
        'sizeText': ?sizeText,
        'torrentId': torrentId,
        'categoryTagId': ?normalizeWhitespace(_stringOf(raw['category_tag_id'])),
        'teamId': ?normalizeWhitespace(_stringOf(raw['team_id'])),
        'partition': partitionLabel,
        'fromJsonApi': true,
        'fileCount': content.length,
        if (sync != null && sync.isNotEmpty)
          'syncedSites': <String>[
            for (final String site in sync.keys)
              if (sync[site] is String && (sync[site] as String).trim().isNotEmpty)
                site,
          ],
      },
    );
  }

  /// 记录里自带的 `team.name`（v2 搜索的响应会内嵌团队对象；分区列表不会）。
  static String? embeddedTeamName(Map<String, dynamic> raw) {
    final Object? team = raw['team'];
    if (team is Map) {
      final String? name = normalizeWhitespace(_stringOf(team['name']));
      if (name != null) return name;
    }
    return null;
  }

  /// 记录里自带的**分类名**（v2 搜索的响应内嵌 `category_tag`）。
  ///
  /// 取 `locale` 里的中文名（繁中优先，与源自己的分区名 `動畫` 用字一致），
  /// 再退到 `name`（站点内部名，例如 `Donga`）。分区列表的响应里没有这个字段
  /// —— 那种情况下调用方用分区名（见 [toItem] 的 `category`）。
  static String? embeddedCategoryName(Map<String, dynamic> raw) {
    final Object? tag = raw['category_tag'];
    if (tag is! Map) return null;
    final Object? locale = tag['locale'];
    if (locale is Map) {
      for (final String key in <String>['zh_tw', 'zh_cn', 'ja', 'en']) {
        final String? value = normalizeWhitespace(_stringOf(locale[key]));
        if (value != null) return value;
      }
    }
    return normalizeWhitespace(_stringOf(tag['name']));
  }

  /// 记录里自带的 `team.name` 优先（v2 搜索的响应会内嵌），其次查记忆表。
  static String? _teamNameOf(
    Map<String, dynamic> raw,
    Map<String, String> teamNames,
  ) {
    final String? embedded = embeddedTeamName(raw);
    if (embedded != null) return embedded;
    final String? teamId = _stringOf(raw['team_id']);
    if (teamId == null) return null;
    return teamNames[teamId];
  }
}

String? _stringOf(Object? value) {
  if (value is String) return value;
  if (value is num) return value.toString();
  return null;
}

int? _intOf(Object? value) {
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value.trim());
  return null;
}

String _snippet(String body, {int max = 200}) {
  final String flat = body.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (flat.length <= max) return flat;
  return '${flat.substring(0, max)}…（共 ${flat.length} 字符）';
}
