/// 起播后的「补全集」：拿正在播的那一条的标题切出关键字，去**同一个源**翻页搜索，
/// 把这一批结果里没有的其它集并进播放列表。
///
/// 用户原话：
/// > 播放列表里的视频不全，加逻辑，播放视频后，使用正则方式加载其他全集。
///
/// 为什么要在归组之外再加这一层：播放列表的候选只有「这一批搜索结果」+
/// 「mikan 番剧页的整部番清单」两处（见 `state/playback.dart` 的 `_playlistFor`），
/// nyaa / 自定义 RSS / mikan 搜不到番剧页时，列表里就只有"这一批出现过"的集号。
/// 关键字搜索是第三处来源：它不需要番剧页，nyaa 与 RSS 源也能用。
///
/// 三条硬约束（写在这里就是为了以后别被改掉）：
/// 1. **绝不抛**：任何失败都静默返回原列表 —— 播放列表少几集不该让播放失败；
/// 2. **有界**：页数、连续空页数、别名次数都有上限，源站不封顶，我们不能打爆它；
/// 3. **不缩水**：只有"新列表包含正在播的这一集、且集数严格变多"时才替换。
library;

import 'package:flutter/foundation.dart';

import '../domain/models.dart';
import '../domain/playlist.dart';
import '../domain/ports.dart';
import '../domain/series_search.dart';

/// 一次补全最多翻几页。
///
/// 4 页是"够用且克制"的取值：mikan 的关键字搜索一次给全（`hasNext=false`），
/// 自然只发一次请求；nyaa 有关键字分页，但源站有请求间隔限制（`sourceRequestIntervalMs`），
/// 翻太多页会让"补全集"变成对源站的扫描。
const int kSeriesLoadMaxPages = 4;

/// 连续这么多页都没有新的同系列条目就收手。
///
/// 关键字搜索结果里同系列条目本来就稀疏（一个关键字会命中一堆别的番），但连着两页
/// 一条都没有，再往下翻大概率也没有 —— 页数上限之外再加一道，省请求。
const int kSeriesLoadIdlePages = 2;

/// 别名兜底最多试几次（见 `series_search.dart` 的 `aliasKeywords`）。
const int kSeriesLoadMaxAliasTries = 2;

/// 一次补全的结果。调用方只关心 [playlist]（没变就是原对象），其余字段是给测试与
/// 诊断用的可观测信息（"翻了没翻、命中了几个"）。
@immutable
class SeriesLoadResult {
  const SeriesLoadResult({
    required this.playlist,
    this.pagesFetched = 0,
    this.keywordsTried = const <String>[],
    this.matched = 0,
  });

  /// 补全后的播放列表；没变时就是传进来的 [current]（同一个对象，便于调用方判等）。
  final Playlist? playlist;

  /// 真的发出去的请求页数（失败的那一页不算）。
  final int pagesFetched;

  /// 依次试过哪些关键字（第一个是主关键字，后面是别名）。
  final List<String> keywordsTried;

  /// 命中的同系列条目条数（已按 id 去重）。
  final int matched;
}

/// 播放列表是不是**明显不全**（要不要去补全的判据）。
///
/// 判据（为什么不能"每次起播都搜一下"）：
/// * [current] == null ⇒ 连"同名同压制组"的组都没凑出来（只有一集），明显不全；
/// * 列表项数 < 这一批里出现过的最大集号 ⇒ 中间缺集。例如这一批出现过第 10 集、
///   列表却只有 3 项，缺的一定是前面几集。
///
/// 两条都不成立时列表已经齐了（或这一批只有一集），再搜只是白打源站。
bool seriesPlaylistLooksIncomplete(
  Playlist? current,
  Iterable<SourceItemView> batch,
) {
  if (current == null) return true;
  int maxEpisode = 0;
  for (final SourceItemView item in batch) {
    final int? episode = episodeOf(item);
    if (episode != null && episode > maxEpisode) maxEpisode = episode;
  }
  return current.items.length < maxEpisode;
}

/// 按关键字翻页搜索并补全播放列表；**任何失败都返回 [current]**（绝不抛）。
///
/// [base] 必须是**原始条目**（正在播的那一条，基准）：补过详情的副本标题可能与同批
/// 其它条目不完全一样，拿它当基准会把自己的集数算丢 —— 与 `_playlistFor` 同一个理由。
/// [batch] 是这一批已有候选（搜索结果 / 番剧页清单），会被一起合并去重。
Future<SeriesLoadResult> loadSeriesPlaylist({
  required SourcePort source,
  required SourceItemView base,
  List<SourceItemView> batch = const <SourceItemView>[],
  Playlist? current,
  int maxPages = kSeriesLoadMaxPages,
  int idlePages = kSeriesLoadIdlePages,
  int maxAliasTries = kSeriesLoadMaxAliasTries,
  int maxItems = kPlaylistMaxItems,
}) async {
  final SeriesSearchQuery? query =
      seriesSearchQueryFor(base.title ?? '', group: base.group);
  // 关键字切不出来（合集 / 只有集号 / 全是标签），或宿主没解析出压制组
  // （`playlistFor` 拿不到组名本来就不会归组）：什么都不做，原样返回。
  if (query == null || normalizedGroupName(base.group) == null) {
    return SeriesLoadResult(playlist: current);
  }

  final List<SourceItemView> found = <SourceItemView>[];
  final Set<String> foundIds = <String>{};
  final List<String> tried = <String>[];
  int pages = 0;

  /// 用 [keyword] 从第 1 页开始翻；返回"这个源现在是否可用"（第一页就成功）。
  ///
  /// 每页都独立 try/catch：中途某一页失败就停在这一页，用已经拿到的部分继续 ——
  /// 半个列表也比原列表全。
  Future<bool> fetchPages(String keyword, int pageLimit) async {
    int idle = 0;
    int usable = 0;
    for (int page = 1; page <= pageLimit; page++) {
      final SourcePageView result;
      try {
        result = await source.search(base.sourceId, keyword, page: page);
      } catch (_) {
        break;
      }
      usable++;
      pages++;
      int fresh = 0;
      for (final SourceItemView item in result.items) {
        if (!isSameSeriesItem(base, item)) continue;
        // 同一条可能在多页里重复出现（源的排序不稳），只按第一次算"新增"。
        if (!foundIds.add(item.id)) continue;
        found.add(item);
        fresh++;
      }
      // ① 源说没有了，或 ② 这一页没有任何新同系列条目且已经连着空了几页。
      if (!result.hasNext) break;
      if (fresh == 0) {
        idle++;
        if (idle >= idlePages) break;
      } else {
        idle = 0;
      }
    }
    return usable > 0;
  }

  try {
    tried.add(query.keyword);
    final bool sourceAlive = await fetchPages(query.keyword, maxPages);
    // 第一页就报错 ⇒ 这个源现在不通，用别名再打它只是重复失败。
    if (sourceAlive && found.isEmpty) {
      for (final String alias in query.aliasKeywords.take(maxAliasTries)) {
        tried.add(alias);
        await fetchPages(alias, 1);
        if (found.isNotEmpty) break;
      }
    }
  } catch (_) {
    // 兜底：连翻页循环之外的意外（比如端口实现抛了同步异常）也不许影响播放。
  }

  try {
    final List<SourceItemView> merged =
        mergeCandidates(<Iterable<SourceItemView>>[batch, found]);
    final Playlist? candidate = playlistFor(merged, base, maxItems: maxItems);
    // 3. 不缩水：新列表必须**含正在播的这一集**、且集数严格变多才替换。
    //    （`playlistFor` 一定把 base 收进列表，这里仍然判一次 —— 判据明写，
    //    免得以后有人换掉 playlistFor 的实现时静默退化成"列表被换成了别的组"。）
    final int before = current?.items.length ?? 0;
    if (candidate == null ||
        candidate.items.length <= before ||
        !candidate.items.any((SourceItemView item) => item.id == base.id)) {
      return SeriesLoadResult(
        playlist: current,
        pagesFetched: pages,
        keywordsTried: tried,
        matched: found.length,
      );
    }
    return SeriesLoadResult(
      playlist: candidate,
      pagesFetched: pages,
      keywordsTried: tried,
      matched: found.length,
    );
  } catch (_) {
    // 合并/归组是纯函数，理论上不会抛；真抛了也只退化成"没补到"。
    return SeriesLoadResult(
      playlist: current,
      pagesFetched: pages,
      keywordsTried: tried,
      matched: found.length,
    );
  }
}
