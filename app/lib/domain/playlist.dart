/// 播放列表（宿主侧）：**同名同压制组**的那几集凑成一组（决策 B31 的正解）。
///
/// 用户的原始要求（原话）：
/// > 「在哪播的在哪搜，比如播放 `[Skymoon-Raws] 遭到流放的转生重骑士… - 01 [ViuTV]…`，
/// > 那么在他的播放列表里就有 `… - 01 …`、`… - 02 …`」
///
/// 2026-10-11 他又问了一次「我要的播放列表为什么没有，按照我播放的**同名同压制组**」。
/// 原因在 `state/playback.dart` 的旧实现：归组只看**同一个 torrent 的文件清单**。
/// 而 mikan 上同一部番的每一集通常是**各自一个种子**（`[ASW] 某番 - 14`、
/// `[ASW] 某番 - 15` …），于是"同一 torrent 里只有一集" ⇒ 组里永远只有 1 项 ⇒
/// 播放器按契约 §9 把上一集/下一集/播放列表按钮**全部隐藏** —— 用户看到的就是"没有"。
///
/// 所以这里按**搜索结果这一批**来归组：
/// 1. 同一个源（`sourceId`）；
/// 2. **同字幕组/压制组**（`group`，两边都必须有值 —— 保守，宁可不给也不串片）；
/// 3. **同番剧指纹**（`episodeFingerprint`：把集号及其之后的内容整段切掉）；
/// 4. 集号解析成功（解析不出来就不参与，`SP01` 之类不会混进正片）；
/// 5. 同一集号只留一条（优先留正在播的那条）。
library;

import 'episode_group.dart' show episodeFingerprint, parseEpisodeNumber;
import 'episodes.dart' show episodeNumber;
import 'models.dart';

/// 一组「同番剧 + 同压制组」的剧集 + 当前在播的那一集在里面的下标。
class Playlist {
  const Playlist(this.items, this.currentIndex);

  final List<SourceItemView> items;
  final int currentIndex;

  bool get hasPrevious => currentIndex > 0 && currentIndex < items.length;
  bool get hasNext => currentIndex >= 0 && currentIndex + 1 < items.length;
  SourceItemView? get previous => hasPrevious ? items[currentIndex - 1] : null;
  SourceItemView? get next => hasNext ? items[currentIndex + 1] : null;
}

/// 一次归组的最大条目数（防一批异常数据把列表撑爆）。
const int kPlaylistMaxItems = 200;

/// 把若干批候选并成一批（按条目 id 去重，先到先得）。
///
/// 用途：播放列表 = 「这一批搜索结果」+「整部番的剧集清单」（用户 2026-10-11：
/// 「不会有前几集，我点第8集就没有765等」）。两批之间同一个 id 可能重复出现
/// （同一集既在搜索结果里也在番剧页里），去重后顺序保持"先到先得"——
/// 搜索结果那一批在前，所以它带的字段（标题/字幕组）优先。
List<SourceItemView> mergeCandidates(Iterable<Iterable<SourceItemView>> batches) {
  final List<SourceItemView> out = <SourceItemView>[];
  final Set<String> seen = <String>{};
  for (final Iterable<SourceItemView> batch in batches) {
    for (final SourceItemView item in batch) {
      if (!seen.add(item.id)) continue;
      out.add(item);
    }
  }
  return out;
}

/// 从一批候选（搜索结果 / 番剧页的剧集列表 / 订阅命中的条目）里取出 [base] 所在的那一组。
///
/// 返回 null = 凑不出「≥2 集」（单集播放），调用方据此隐藏播放列表。
Playlist? playlistFor(
  Iterable<SourceItemView> candidates,
  SourceItemView base, {
  int maxItems = kPlaylistMaxItems,
}) {
  final String fingerprint = episodeFingerprint(base.title ?? '');
  final String? group = _normalizedGroup(base);
  final int? baseEpisode = episodeOf(base);
  if (fingerprint.isEmpty || group == null || baseEpisode == null) return null;

  final List<SourceItemView> picked = <SourceItemView>[];
  final Map<int, int> byEpisode = <int, int>{}; // 集号 → picked 下标

  void take(SourceItemView item, int episode) {
    final int? at = byEpisode[episode];
    if (at == null) {
      byEpisode[episode] = picked.length;
      picked.add(item);
      return;
    }
    // 同一集号出现两次（不同分辨率/重复条目）：**正在播的那一条优先**，
    // 其余保持先到先得 —— 列表里同一集出现两行只会让人困惑。
    if (item.id == base.id) picked[at] = item;
  }

  take(base, baseEpisode);
  for (final SourceItemView item in candidates) {
    if (item.id == base.id) continue;
    if (item.sourceId != base.sourceId) continue;
    if (_normalizedGroup(item) != group) continue;
    final int? episode = episodeOf(item);
    if (episode == null) continue;
    if (episodeFingerprint(item.title ?? '') != fingerprint) continue;
    take(item, episode);
    if (picked.length >= maxItems) break;
  }
  if (picked.length <= 1) return null;

  picked.sort((SourceItemView a, SourceItemView b) {
    final int byEpisode = (episodeOf(a) ?? 0).compareTo(episodeOf(b) ?? 0);
    if (byEpisode != 0) return byEpisode;
    return a.id.compareTo(b.id);
  });
  int index = 0;
  for (int i = 0; i < picked.length; i++) {
    if (picked[i].id == base.id) index = i;
  }
  return Playlist(List<SourceItemView>.unmodifiable(picked), index);
}

/// 字幕组/压制组：去空白转小写；空串按「没有」处理（保守：不知道组就不归组）。
String? _normalizedGroup(SourceItemView item) {
  final String text = (item.group ?? '').trim().toLowerCase();
  return text.isEmpty ? null : text;
}

/// 这一条是第几集。
///
/// 先信宿主的 `episodeHints`（core 的 `TitleParser` 写的），没有再**从标题兜底解析**
/// —— 自定义 RSS / 未来源可能没走 TitleParser，但标题里的 `- 07` 仍然是真的。
int? episodeOf(SourceItemView item) =>
    episodeNumber(item) ?? parseEpisodeNumber(item.title ?? '');
