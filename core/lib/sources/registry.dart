/// 源注册表（spec §4.2）。
///
/// * 默认注册 `nyaa`（动漫区）、`mikan`、`dmhy`（动漫花园）；
/// * [register] 是「可自行添加其他网站解析」的公开入口 —— 实现 [SourceClient] 即可接入；
/// * [addRss] / [addRssUrl] 是自定义订阅的快捷入口（内部构造 [RssSource]）。
///
/// 注册顺序 = 源下拉的顺序：
/// * 2026-10-12（第 7 轮）加 dmhy 时定下的规矩是「中文资源排在最后」——
///   mikan 关键词搜索一次给 1000 条但只有番剧，dmhy 覆盖面更杂
///   （日劇/音樂/遊戲都在），nyaa 那边又偏英文圈；
/// * **2026-10-12（第 9 轮）**用户给的四个地址里有三个站、每个站要「动漫 + 全集」
///   两个分区，于是每站注册**两个实例**（各自独立 id，缓存键与条目 id 都不会撞）：
///   `dmhy` / `dmhy-batch`、`acgrip` / `acgrip-batch`、`acgnx` / `acgnx-batch`。
///   顺序保持「按站分组」，与用户给的清单一致；
/// * **2026-10-12（第 10 轮）**再加 `bangumi.moe`（番組、萌え），同样按分区两个实例：
///   `bangumimoe`（動畫 = tag `Donga`）与 `bangumimoe-collection`（動畫合集 =
///   `Donga` + `Collection`，AND 语义）。站点是 SPA，走它的 JSON API（见
///   `bangumi_moe.dart`）。
/// * **2026-10-12（第 14 轮）**每个源多带一个 [SourcePartition]：注册时声明，
///   宿主「聚合搜索」的「聚合 / 动漫 / 全集」三档直接读它（[partitionOf]）——
///   见 `SourcePartition` 的注释（为什么不从 id 猜）。
/// * **2026-10-12（第 24 轮）**用户「ACG.rip bangumi.moe 去除全集源」：
///   `acgrip-batch` 与 `bangumimoe-collection` 两个实例**删掉注册**（站点本身照旧）。
///   「全集」档现在只剩两个真正按季度全集分区搜的实例：`dmhy-batch` / `acgnx-batch`
///   —— 它们的**搜索 URL 也都带上了各自的分区参数**（第二十四轮修：「还是会搜到单集」，
///   见 `dmhy.dart` / `acgnx.dart` 里 `searchUri` 的注释与真机探针
///   `build/probe-scope/probe-scope-filters.log`）。
library;

import 'acgnx.dart';
import 'acgrip.dart';
import 'bangumi_moe.dart';
import 'cache.dart';
import 'dmhy.dart';
import 'http.dart';
import 'mikan.dart';
import 'models.dart';
import 'nyaa.dart';
import 'rss.dart';
import 'source_client.dart';

class SourceRegistry {
  SourceRegistry({
    required HttpClientFactory http,
    required SourceCache cache,
    required RateLimiter limiter,
    required this.proxy,
    ClockFn? clock,
    bool registerDefaults = true,
    String nyaaCategory = '1_2',
    Duration requestTimeout = const Duration(seconds: 20),
    int maxRetries = 2,
  }) : _cache = cache,
       _clock = clock ?? DateTime.now {
    final factory = _effectiveFactory(http);
    _transport = SourceHttp(
      factory: factory,
      limiter: limiter,
      timeout: requestTimeout,
      maxRetries: maxRetries,
    );
    if (registerDefaults) {
      register(NyaaSource(
        http: _transport,
        cache: cache,
        category: nyaaCategory,
        clock: _clock,
      ));
      register(MikanSource(http: _transport, cache: cache, clock: _clock));
      register(DmhySource(http: _transport, cache: cache, clock: _clock));
      // 第 9 轮：每站两个分区（动漫 / 全集），见本文件头部注释。
      register(
        DmhySource(
          http: _transport,
          cache: cache,
          clock: _clock,
          id: 'dmhy-batch',
          displayName: '动漫花园 · 季度全集（DMHY）',
          animeSortId: kDmhyBatchSortId,
        ),
        partition: SourcePartition.collection,
      );
      register(AcgRipSource(http: _transport, cache: cache, clock: _clock));
      // ⚠️ 第二十四轮：`acgrip-batch`（ACG.RIP · 合集）**删掉了** ——
      // 用户 2026-10-12「ACG.rip bangumi.moe 去除全集源」。真机实测（第二十四轮探针）：
      // `acg.rip/5?term=蜡笔小新` 只有 **1 条**（虽然确实是合集），这个站没有能用的季度全集区。
      // 站点本身（動畫区 `/1`）照旧注册。
      register(AcgnxSource(http: _transport, cache: cache, clock: _clock));
      register(
        AcgnxSource(
          http: _transport,
          cache: cache,
          clock: _clock,
          id: 'acgnx-batch',
          displayName: 'ACGNX · 季度全集',
          feedId: kAcgnxBatchFeed,
        ),
        partition: SourcePartition.collection,
      );
      // 第 10 轮：bangumi.moe（番組、萌え）。
      // ⚠️ 第二十四轮：`bangumimoe-collection`（動畫合集）**删掉了** ——
      // 用户 2026-10-12「ACG.rip bangumi.moe 去除全集源」。真机实测（第二十四轮探针）：
      // 这个站的关键字搜索 `GET /api/v2/torrent/search?query=` **不接受 tag 过滤**
      //（「蜡笔小新」只回 3 条、全是单集），而带 tag 的 `POST /api/torrent/search`
      // 是**分区列表**接口、不吃关键字 —— 也就是说它做不到"只搜合集"。
      register(BangumiMoeSource(http: _transport, cache: cache, clock: _clock));
    }
  }

  /// 当前代理配置（UI 显示用）。
  ///
  /// 注意：代理真正生效的位置是注入的 [HttpClientFactory]；
  /// 若传入的是 [IoHttpClientFactory] 且其 proxy 与本参数不一致，本类会以本参数为准重建。
  final ProxyConfig proxy;

  final SourceCache _cache;
  final ClockFn _clock;
  late final SourceHttp _transport;
  final Map<String, SourceClient> _clients = <String, SourceClient>{};

  /// 每个源 id 的分区（第 14 轮，见 [SourcePartition]）。
  ///
  /// 与 [_clients] 分开存：分区是**这次注册**的属性，不是 `SourceClient` 实现类的属性
  /// （同一个 `DmhySource` 类既可以是动漫分区也可以是全集分区），所以它不该塞进
  /// `SourceClient` 的签名里（那是 spec §4.2 的冻结签名）。
  final Map<String, SourcePartition> _partitions = <String, SourcePartition>{};

  SourceCache get cache => _cache;

  /// 共享抓取器（自定义 [SourceClient] 实现可以直接用它）。
  SourceHttp get transport => _transport;

  /// 已注册的源（注册顺序）。
  List<SourceClient> get clients =>
      List<SourceClient>.unmodifiable(_clients.values);

  /// 按 id 找源；`nyaa` / `mikan` / `rss:<订阅id>`。
  SourceClient? byId(String id) => _clients[id];

  /// 这个源属于哪个分区（宿主「聚合搜索」的 聚合 / 动漫 / 全集 三档读它）。
  ///
  /// 没声明过的一律当 [SourcePartition.anime]：宿主现在注册的源里只有「合集」那四个
  /// 需要显式声明，剩下的默认就是动漫分区；未注册的 id 也走这条默认（读它的人
  /// 本来就该先确认源存在）。
  SourcePartition partitionOf(String id) =>
      _partitions[id] ?? SourcePartition.anime;

  /// 注册（或替换同 id 的）源。
  ///
  /// [partition] 只在传了的时候覆盖：重新注册一个 id 时忘了带分区，不该把原来
  /// 声明的「合集」悄悄降级成「动漫」。
  void register(
    SourceClient c, {
    SourcePartition? partition,
  }) {
    _clients[c.id] = c;
    if (partition != null) _partitions[c.id] = partition;
  }

  /// 注销；返回是否真的移除了。
  bool unregister(String id) {
    _partitions.remove(id);
    return _clients.remove(id) != null;
  }

  /// 新建一个自定义 RSS 源并注册（自定义订阅入口）。
  ///
  /// 分区默认算 [SourcePartition.anime]：这个入口本来就是给「番剧 RSS」用的
  /// （mikan 的 `/RSS/Bangumi?...`、各站番剧订阅源）。要别的分区请自己
  /// [register] 并显式给 `partition`。
  RssSource addRss({
    required String feedId,
    required Uri feedUrl,
    String? displayName,
  }) {
    final source = RssSource(
      feedId: feedId,
      feedUrl: feedUrl,
      http: _transport,
      cache: _cache,
      displayName: displayName,
      clock: _clock,
    );
    register(source, partition: SourcePartition.anime);
    return source;
  }

  /// 用 feed URL 直接建源；未给 feedId 时用 URL 的 sha1 前 12 位（稳定、可重复）。
  RssSource addRssUrl(String feedUrl, {String? feedId, String? displayName}) {
    final parsed = Uri.tryParse(feedUrl.trim());
    if (parsed == null || !parsed.hasScheme) {
      throw SourceException('不是合法的 feed URL: "$feedUrl"');
    }
    return addRss(
      feedId: feedId ?? shortHash(parsed.toString()),
      feedUrl: parsed,
      displayName: displayName ?? parsed.host,
    );
  }

  /// 关闭底层 HTTP 客户端。
  void dispose() => _transport.close();

  HttpClientFactory _effectiveFactory(HttpClientFactory provided) {
    if (provided is IoHttpClientFactory && provided.proxy != proxy) {
      return IoHttpClientFactory(
        proxy: proxy,
        connectionTimeout: provided.connectionTimeout,
      );
    }
    return provided;
  }
}
