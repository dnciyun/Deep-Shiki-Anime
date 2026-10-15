/// 「动漫库」的真实实现（第三十三轮）：Bangumi `POST /v0/search/subjects` + 条目详情。
///
/// 只有装配根（`main.dart`）知道这个类；UI/state 只认 `domain/ports.dart` 的
/// [BangumiLibraryPort]（与「今日推荐」的 `BangumiRecommendPort` 同一套做法）。
///
/// 两件必须讲清楚的事：
///
/// 1. **放送形态要在本地再过一遍**。服务端**没有** platform 过滤（实测：body 里加
///    `filter.platform` 的结果与不加**一字不差**），只能用 `filter.tag` 近似 ——
///    而标签是用户打的，实测 `tag[OVA]` 前 10 条里有 1 条 TV、1 条剧场版。
///    所以这里：服务端按 tag 粗筛 → 本地按条目自带的 `platform` 精确筛
///    （[BangumiLibraryForm.matches]）→ 不够一页就要下一页（次数见 [libraryMaxFetches]）。
/// 2. **翻页游标不是 `offset + 条数`**。上面那个"再要一页"会让一次请求吃掉服务端两段，
///    所以返回的 [BangumiLibraryPage.nextOffset] 才是下一页的起点，调用方别自己算。
/// 3. ⚠️ 第三十四轮实测：**服务端把 `limit` 封顶在 20**（要 24/25/30/50 都只回 20，
///    回显 `limit: 20`，见 `build/round34/body-probe.txt`）。"一页 24 条"因此天然要两次
///    请求 —— 每次请求按 [kLibraryServerPageCap] 要，凑满一页靠循环（[libraryMaxFetches]）。
library;

import 'dart:math' as math;

import 'package:dsanima_core/sources/kv.dart' show KeyValueStore;

import '../domain/bangumi.dart';
import '../domain/bangumi_library.dart';
import '../domain/ports.dart';

/// 进程内缓存一条的存活时间（同一次浏览里来回翻页不再打 Bangumi）。
const Duration _pageTtl = Duration(minutes: 10);

class BangumiLibraryService implements BangumiLibraryPort {
  BangumiLibraryService({
    BangumiClient? client,
    this.store,
    this.pageTtl = _pageTtl,
    DateTime Function()? clock,
  })  : client = client ?? BangumiClient(),
        _clock = clock ?? DateTime.now;

  final BangumiClient client;

  /// 可选：给了就把「条目详情」落盘（`dsanima.bangumi.subject.<id>`）。
  ///
  /// 详情页的东西（简介/标签/评分）不会变，重复点同一部没必要再等一次网络；
  /// 没给 store 时只走进程内缓存（测试里就是这么用的）。
  final KeyValueStore? store;
  final Duration pageTtl;
  final DateTime Function() _clock;

  /// 页缓存：`query.cacheKey|offset|limit` → 结果 + 落账时间。
  final Map<String, ({BangumiLibraryPage page, DateTime at})> _pages =
      <String, ({BangumiLibraryPage page, DateTime at})>{};

  /// 详情缓存（进程内）。
  final Map<int, BangumiSubject> _details = <int, BangumiSubject>{};

  /// 补充内容缓存（进程内）：角色 + 关联条目。
  final Map<int, BangumiSubjectExtra> _extras = <int, BangumiSubjectExtra>{};

  /// 缓存不许无限涨：一次浏览最多几十页，超过就整批清掉重来（比 LRU 简单，够用）。
  static const int _maxCachedPages = 120;

  @override
  bool get isAvailable => true;

  @override
  Future<BangumiLibraryPage> search(
    BangumiLibraryQuery query, {
    int offset = 0,
    int limit = kLibraryDefaultPageSize,
  }) async {
    final int start = math.max(0, offset);
    final int size = math.max(1, limit);
    final String cacheKey = '${query.cacheKey}|$start|$size';
    final ({BangumiLibraryPage page, DateTime at})? hit = _pages[cacheKey];
    if (hit != null && _clock().difference(hit.at) <= pageTtl) return hit.page;

    final List<BangumiSubject> kept = <BangumiSubject>[];
    int total = 0;
    int cursor = start;
    bool hasMore = false;

    // ⚠️ 第三十四轮：**每次请求最多要 [kLibraryServerPageCap] 条**（实测服务端把 limit
    // 封顶在 20：要 24/30/50 都只回 20）。所以一页 40 条 = 两次请求 —— 循环次数按
    // [libraryMaxFetches] 算（份数 + 本地精确筛的余量），不是写死 3。
    final int fetchLimit = math.min(size, kLibraryServerPageCap);
    final int maxFetches = libraryMaxFetches(size);
    for (int fetch = 0; fetch < maxFetches; fetch++) {
      final BangumiSubjectsPage page = await client.searchSubjectsFiltered(
        keyword: query.trimmedKeyword,
        sort: query.serverSort,
        filter: query.filter,
        limit: fetchLimit,
        offset: cursor,
      );
      total = page.total;
      for (final BangumiSubject subject in page.items) {
        if (kept.length >= size) break;
        if (query.form.matches(subject)) kept.add(subject);
      }
      // 游标推进：服务端回显的 offset 不可信时（字段缺失）退化成"自己数"。
      final int consumed = page.items.length;
      cursor = (page.offset > cursor ? page.offset : cursor) + consumed;
      final int hardEnd = libraryHardEnd(total);
      hasMore = consumed > 0 && cursor < hardEnd;
      if (libraryPageFilled(kept, size) || !hasMore) break;
    }

    final BangumiLibraryPage result = BangumiLibraryPage(
      items: List<BangumiSubject>.unmodifiable(kept),
      total: libraryHardEnd(total),
      startOffset: start,
      nextOffset: cursor,
      hasMore: hasMore,
    );
    if (_pages.length >= _maxCachedPages) _pages.clear();
    _pages[cacheKey] = (page: result, at: _clock());
    return result;
  }

  @override
  Future<BangumiSubject> detail(int id) async {
    final BangumiSubject? cached = _details[id];
    if (cached != null) return cached;

    final BangumiSubject? fromDisk = _readDetail(id);
    if (fromDisk != null) {
      _details[id] = fromDisk;
      return fromDisk;
    }

    final BangumiSubject subject = await client.subject(id);
    _details[id] = subject;
    await _writeDetail(subject);
    return subject;
  }

  /// 详情落盘。**带上原始 URL 一起存**，读回来照样能按显示尺寸抬档
  /// （[BangumiSubject.coverUrlAt] 靠 `/pic/cover/` 的形状改宽度，不需要额外字段）。
  BangumiSubject? _readDetail(int id) {
    final KeyValueStore? store = this.store;
    if (store == null) return null;
    final Object? raw = store.get('dsanima.bangumi.subject.$id');
    if (raw is! Map) return null;
    final Object? subject = raw.cast<Object?, Object?>()['subject'];
    if (subject is! Map) return null;
    try {
      return BangumiSubject.fromJson(subject.cast<String, Object?>());
    } catch (_) {
      // 盘上一条脏数据不许把详情页打崩（同 `BangumiMetaService._readCache` 的教训）。
      return null;
    }
  }

  Future<void> _writeDetail(BangumiSubject subject) async {
    final KeyValueStore? store = this.store;
    if (store == null) return;
    try {
      await store.put('dsanima.bangumi.subject.${subject.id}', <String, Object?>{
        'cachedAt': _clock().toIso8601String(),
        'subject': subject.toJson(),
      });
    } catch (_) {
      // 缓存写失败不影响这次详情。
    }
  }

  // ── 第三十七轮：角色 / 关联条目（详情页顶部信息带下面那两个全宽盒子）────────────

  /// 补充内容：角色（`/v0/subjects/{id}/characters`）+ 关联条目（`/v0/subjects/{id}/subjects`）。
  ///
  /// 三条策略（都写在 [BangumiLibraryPort.extras] 的契约里，这里是对应的实现）：
  /// 1. **各自失败各自空**：一条挂了不影响另一条 —— 这两个盒子是装饰，不配让整页变成错误页；
  /// 2. **有失败就不落盘**：一次网络抖动不该把"这部没有角色"永久钉在盘上
  ///    （第三十四轮 `_details` 落盘的同一考量）；
  /// 3. **两条都失败才抛**：调用方（详情页）才需要知道"这一块拿不到"。
  ///
  /// 两条请求会同时发出，但 [BangumiClient] 的限速闸门会把**开始时刻**排开 1.1s
  /// （Bangumi 的硬要求），所以冷启一次点开大约要多等一次往返 —— 这两个盒子在
  /// 首屏之下，用户看到的是"顶上先有内容，下面的角色块随后补上"，不会白屏等。
  @override
  Future<BangumiSubjectExtra> extras(int id) async {
    final BangumiSubjectExtra? cached = _extras[id];
    if (cached != null) return cached;

    final BangumiSubjectExtra? fromDisk = _readExtras(id);
    if (fromDisk != null) {
      _extras[id] = fromDisk;
      return fromDisk;
    }

    BangumiException? failure;
    List<BangumiCharacter> characters = const <BangumiCharacter>[];
    List<BangumiRelated> related = const <BangumiRelated>[];
    bool failed = false;

    Future<void> loadCharacters() async {
      try {
        characters = await client.characters(id);
      } catch (error) {
        failed = true;
        if (error is BangumiException) failure = error;
      }
    }

    Future<void> loadRelated() async {
      try {
        related = await client.relatedSubjects(id);
      } catch (error) {
        failed = true;
        if (error is BangumiException) failure = error;
      }
    }

    await Future.wait(<Future<void>>[loadCharacters(), loadRelated()]);

    if (characters.isEmpty && related.isEmpty && failure != null) throw failure!;

    final BangumiSubjectExtra result =
        BangumiSubjectExtra(characters: characters, related: related);
    _extras[id] = result;
    // 有失败就不写盘（下次点开还会重试）；两条都成功（哪怕真的都是空表）才落盘。
    if (!failed) await _writeExtras(id, result);
    return result;
  }

  BangumiSubjectExtra? _readExtras(int id) {
    final KeyValueStore? store = this.store;
    if (store == null) return null;
    final Object? raw = store.get('dsanima.bangumi.subject.$id.extra');
    if (raw is! Map) return null;
    try {
      return BangumiSubjectExtra.fromJson(raw.cast<String, Object?>());
    } catch (_) {
      // 盘上一条脏数据不许把详情页打崩（同 `_readDetail` 的教训）。
      return null;
    }
  }

  Future<void> _writeExtras(int id, BangumiSubjectExtra extra) async {
    final KeyValueStore? store = this.store;
    if (store == null) return;
    try {
      await store.put('dsanima.bangumi.subject.$id.extra', <String, Object?>{
        'cachedAt': _clock().toIso8601String(),
        ...extra.toJson(),
      });
    } catch (_) {
      // 缓存写失败不影响这次显示。
    }
  }

  void dispose() => client.dispose();
}