/// 集数推导（宿主侧）：从一堆结果里找出「同一部番、同一字幕组的后续集」。
///
/// 只做保守推断：集数解析失败、字幕组不同、来源不同 → 不算下一集。
/// core 的 QueueManager 接通后，正式预取由它负责（`episodeHints` 递增 + 规则命中）；
/// 这里的列表只用于「立即播放时把同批结果里的后续集带上」，供自动下一集使用。
library;

import 'models.dart';

/// `S01E02` / `S02E08-E11` 这类「季-集」提示：只认 **E** 后面那个号。
///
/// core 的 `TitleParser.extractEpisodeHints`（`core/lib/subs/title_parser.dart:88-102`）
/// 对 `… S02E08 …` 产出 `['S02E08']`、对区间产出 `['S02E08', 'S02E11']`。
/// 取「提示里的第一个整数」会拿到 **季号**（`S02E08` → 2），于是同一季的所有集
/// 都被算成同一集：`playlistFor` 凑不出 ≥2 个不同集号（播放列表/上一集/下一集全隐藏），
/// `followingEpisodes` 也判不出"更大的集"（自动下一集失效）。
final RegExp _kSeasonEpisodeHint = RegExp(r'[Ss]\d{1,2}\s*[Ee][Pp]?\s*(\d{1,3})');

/// 取集数提示里的集号（`01` / `S01E02` / `第3话` → 1 / 2 / 3）。
int? episodeNumber(SourceItemView item) {
  for (final String hint in item.episodeHints) {
    final RegExpMatch? season = _kSeasonEpisodeHint.firstMatch(hint);
    if (season != null) {
      final int? value = int.tryParse(season.group(1)!);
      if (value != null) return value;
    }
    final RegExpMatch? match = RegExp(r'(\d{1,4})').firstMatch(hint);
    if (match == null) continue;
    final int? value = int.tryParse(match.group(1)!);
    if (value != null) return value;
  }
  return null;
}

/// 从**标题或文件名**里抽集数（`- 03`、`[03]`、`第 3 集`、` 11`）—— 认不出返回 null。
///
/// 与 [episodeNumber] 的分工：那个读的是 core `TitleParser` 已经写好的 `episodeHints`
/// （搜索/订阅条目都有）；这个给**只有文件名**的场景用（「已完成」页点播时，
/// 手上只有 torrent 名与文件路径，没有条目）。
///
/// 只认"有分隔符前缀 + 有结尾边界"的数字：`1080p`、`2026/10/07`、`HEVC10bit`
/// 都不是集数（否则会出现「第 1080 话」）。同一口径见 `following_view.dart` 的
/// `_episodePattern`——两处都在做"从标题认集数"，但一份在渲染卡片、一份在记账，
/// 刻意不互相 import（卡片那侧的规则还带"追到第几话"的取最大值语义）。
final RegExp _kEpisodeInTitle = RegExp(
  r'[-\[\(（【\s]+(\d{1,4})(?=\s*$|[\s\]\)）】]|话|集|v\d)',
);

int? episodeNumberFromTitle(String title) {
  int? best;
  for (final RegExpMatch m in _kEpisodeInTitle.allMatches(title)) {
    final int? v = int.tryParse(m.group(1)!);
    if (v != null && v > 0 && v < 2000 && (best == null || v > best)) best = v;
  }
  return best;
}

/// 与 [base] 同源、同字幕组、集数更大的结果，按集数升序。
List<SourceItemView> followingEpisodes(
  Iterable<SourceItemView> all,
  SourceItemView base,
) {
  final int? baseEpisode = episodeNumber(base);
  if (baseEpisode == null) return const <SourceItemView>[];
  final List<SourceItemView> out = all
      .where((SourceItemView item) =>
          item.id != base.id &&
          item.sourceId == base.sourceId &&
          item.group == base.group &&
          (episodeNumber(item) ?? -1) > baseEpisode)
      .toList();
  out.sort((SourceItemView a, SourceItemView b) =>
      (episodeNumber(a) ?? 0).compareTo(episodeNumber(b) ?? 0));
  return out;
}
