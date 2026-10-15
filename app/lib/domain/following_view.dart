/// 「正在追」页的视图模型（纯函数，可单测，spec §7.6）。
///
/// 把三份真实数据合成一张卡：
/// * 本地追番标记（[FollowingEntry]）；
/// * mikan 追番表（下次更新日 / 今天有没有更）；
/// * 引擎 torrent + 队列任务（下载中 / 队列中 / 已缓存 集数与体积、追到第几话）。
///
/// **不编字段**：拿不到就不显示那一行，而不是填 0 或占位。
library;

import 'package:flutter/foundation.dart';

import 'format.dart';
import 'following_store.dart';
import 'models.dart';
import 'title_match.dart';

/// 卡片左上角角标（spec §7.6：`在追` / `下载中` / `队列中`）。
enum FollowingStatus {
  watching('在追'),
  downloading('下载中'),
  queued('队列中');

  const FollowingStatus(this.label);
  final String label;
}

/// 顶部筛选条。
///
/// ⚠️ 第四个 chip 是 **`无档期`** 而不是 `已完结`：本周 mikan 追番表只放**正在播**的，
/// 老番 / 未开播 / 已完结 / 停播都会落到「表里没有」这一支，
/// 把它们一律标成「已完结」是**说错话**（Lead 明确要求改）。
/// 真要显示「已完结」只有一条路：有上映日期 + 总话数，按周播推算最后一话已经播完
/// （见 [inferFinished]），推不出来就显示中性的「无档期」。
enum FollowingFilter {
  all('全部'),
  updated('有更新'),
  downloading('下载中'),
  unslotted('无档期');

  const FollowingFilter(this.label);
  final String label;
}

/// 从 Bangumi 的「上映日期 + 总话数」推断是否已完结。
///
/// 按周播算最后一话的日期，再留 30 天余量；**证据不足一律返回 null**（不猜、不显示）。
bool? inferFinished({String? airDate, int? eps, required DateTime now}) {
  final DateTime? start = DateTime.tryParse((airDate ?? '').trim());
  if (start == null || eps == null || eps <= 0) return null;
  final DateTime lastAired = start.add(Duration(days: eps * 7 + 30));
  return now.isAfter(lastAired);
}

@immutable
class FollowingCard {
  const FollowingCard({
    required this.entry,
    required this.status,
    required this.hasNoSlot,
    required this.isFinished,
    required this.hasUpdate,
    this.nextUpdate,
    this.progressLabel,
    this.stateText,
    this.torrent,
    this.playableFile,
    this.job,
    this.updatedToday,
    this.daysUntilUpdate,
  });

  final FollowingEntry entry;
  final FollowingStatus status;

  /// 本周 mikan 追番表里没有它（老番/未开播/已完结/停播都可能）。
  /// **这只是「没档期」，不是「已完结」。**
  final bool hasNoSlot;

  /// **能推断出来**才为 true（上映日期 + 总话数 → 最后一话已播完）；推断不出就是 false。
  final bool isFinished;

  /// mikan 说今天更了新一集。
  final bool hasUpdate;

  /// `周三 更新` / `剧场版` / `OVA` / `已完结`（推断出来时）/ `无档期`。
  final String? nextUpdate;

  /// `第 12 话 / 共 24 话`（缺哪半边就只显示半边；都没有 → null）。
  final String? progressLabel;

  /// `下载中 62%` / `队列中 · 等待下载` / `已缓存 7 集 · 3.6 GiB`。
  final String? stateText;

  /// 引擎里匹配到的 torrent（「继续观看」用）。
  final EngineTorrentView? torrent;
  final EngineFileView? playableFile;
  final QueueJobView? job;

  /// mikan 原文的更新日期（`2026/10/08 更新`）。
  final String? updatedToday;

  /// 距下次更新还有几天（0 = 今天）。未知为 null。
  final int? daysUntilUpdate;
}

/// 把一份追番记录对上 mikan 追番表里的那条。
ScheduleEntryView? scheduleEntryFor(
  FollowingEntry entry,
  ScheduleView? schedule,
) {
  if (schedule == null) return null;
  for (final ScheduleEntryView e in schedule.entries) {
    if (titlesMatch(e.title, entry.title)) return e;
  }
  return null;
}

/// 生成「正在追」页的卡片列表（已按规格排序 + 过滤）。
///
/// 排序（spec §7.6）：下次更新最近的在前（今天更新的最前，其次按距下次更新的天数），
/// 再其次最近观看，最后按加入时间。
///
/// 「档期」判据是 mikan 追番表；**表里没有 ≠ 已完结**（见 [FollowingFilter] 的说明）。
List<FollowingCard> buildFollowingCards({
  required List<FollowingEntry> entries,
  required ScheduleView? schedule,
  required List<QueueJobView> jobs,
  required List<EngineTorrentView> torrents,
  required DateTime now,
  int todayDow = 0,
  FollowingFilter filter = FollowingFilter.all,
}) {
  final List<FollowingCard> cards = <FollowingCard>[
    for (final FollowingEntry entry in entries)
      _buildCard(
        entry: entry,
        schedule: schedule,
        jobs: jobs,
        torrents: torrents,
        now: now,
        todayDow: todayDow,
      ),
  ];

  final List<FollowingCard> kept = switch (filter) {
    FollowingFilter.all => cards,
    FollowingFilter.updated =>
      cards.where((FollowingCard c) => c.hasUpdate).toList(),
    FollowingFilter.downloading => cards
        .where((FollowingCard c) => c.status == FollowingStatus.downloading)
        .toList(),
    FollowingFilter.unslotted =>
      cards.where((FollowingCard c) => c.hasNoSlot).toList(),
  };

  kept.sort((FollowingCard a, FollowingCard b) {
    // ① 今天更新的最前（有档期的次之，已完结/无档期的最后）
    final int ra = a.hasUpdate
        ? 0
        : (a.daysUntilUpdate != null ? 1 : 2);
    final int rb = b.hasUpdate
        ? 0
        : (b.daysUntilUpdate != null ? 1 : 2);
    if (ra != rb) return ra.compareTo(rb);
    // ② 下载中/队列中优先（用户正在等的东西）
    final int sa = a.status == FollowingStatus.watching ? 1 : 0;
    final int sb = b.status == FollowingStatus.watching ? 1 : 0;
    if (sa != sb) return sa.compareTo(sb);
    // ③ 下次更新最近的在前
    if (a.daysUntilUpdate != null && b.daysUntilUpdate != null &&
        a.daysUntilUpdate != b.daysUntilUpdate) {
      return a.daysUntilUpdate!.compareTo(b.daysUntilUpdate!);
    }
    // ④ 最近观看
    final DateTime? wa = a.entry.lastWatchedAt;
    final DateTime? wb = b.entry.lastWatchedAt;
    if (wa != null && wb != null && wa != wb) return wb.compareTo(wa);
    if (wa != null && wb == null) return -1;
    if (wa == null && wb != null) return 1;
    // ⑤ 加入时间
    return b.entry.addedAt.compareTo(a.entry.addedAt);
  });
  return List<FollowingCard>.unmodifiable(kept);
}

FollowingCard _buildCard({
  required FollowingEntry entry,
  required ScheduleView? schedule,
  required List<QueueJobView> jobs,
  required List<EngineTorrentView> torrents,
  required DateTime now,
  required int todayDow,
}) {
  final ScheduleEntryView? slot = scheduleEntryFor(entry, schedule);
  final bool hasUpdate =
      slot != null && isSameCalendarDay(slot.updatedAt, now);

  final List<QueueJobView> matchedJobs = jobs
      .where((QueueJobView j) => titlesMatch(j.item.title, entry.title))
      .toList();
  final List<EngineTorrentView> matchedTorrents = torrents
      .where((EngineTorrentView t) => titlesMatch(t.name, entry.title))
      .toList();

  QueueJobView? activeJob;
  QueueJobView? queuedJob;
  for (final QueueJobView job in matchedJobs) {
    if (job.state == JobState.downloading && activeJob == null) activeJob = job;
    if (job.state == JobState.queued && queuedJob == null) queuedJob = job;
  }
  EngineTorrentView? activeTorrent;
  final List<EngineTorrentView> cachedTorrents = <EngineTorrentView>[];
  for (final EngineTorrentView t in matchedTorrents) {
    final bool done = t.finished || t.progress >= 1;
    if (done) {
      cachedTorrents.add(t);
    } else if (activeTorrent == null && t.state == TorrentState.live) {
      activeTorrent = t;
    }
  }

  final FollowingStatus status = (activeJob != null || activeTorrent != null)
      ? FollowingStatus.downloading
      : (queuedJob != null ? FollowingStatus.queued : FollowingStatus.watching);

  // 进度：追到第几话来自引擎/队列里匹配到的最大集数，总话数来自追番记录（有才显示）。
  final int? watchedEpisode = _maxEpisode(<String?>[
    for (final EngineTorrentView t in matchedTorrents) t.name,
    for (final QueueJobView j in matchedJobs) j.item.displayTitle,
  ]);
  final String? progressLabel = _progressLabel(watchedEpisode, entry.totalEpisodes);

  final String? stateText = _stateText(
    status: status,
    activeTorrent: activeTorrent,
    activeJob: activeJob,
    matchedJobs: matchedJobs,
    cachedTorrents: cachedTorrents,
  );

  // 「继续观看」的目标：优先正在下的那个 torrent，其次已下完里最大的。
  final List<EngineTorrentView> candidates = <EngineTorrentView>[
    ?activeTorrent,
    ...cachedTorrents,
  ]..sort((EngineTorrentView a, EngineTorrentView b) =>
      (b.playableFile?.length ?? 0).compareTo(a.playableFile?.length ?? 0));

  final EngineTorrentView? playableTorrent =
      candidates.isEmpty ? null : candidates.first;

  final bool hasNoSlot = slot == null;
  // 「已完结」只在证据够时出现：有上映日期 + 总话数，且按周播推算已播完。
  final bool isFinished =
      hasNoSlot && (inferFinished(airDate: entry.airDate, eps: entry.totalEpisodes, now: now) ?? false);
  final int? daysUntil = slot == null || slot.isUnslotted
      ? null
      : ((slot.dayOfWeek - todayDow) % 7 + 7) % 7;

  return FollowingCard(
    entry: entry,
    status: status,
    hasNoSlot: hasNoSlot,
    isFinished: isFinished,
    hasUpdate: hasUpdate,
    nextUpdate: slot == null
        ? (isFinished ? '已完结' : '无档期')
        // 专档（mikan 的 7=剧场版 / 8=OVA）：写档位名，不加「更新」（它们不是每周固定档）。
        : (slot.isUnslotted ? dsWeekdayLabel(slot.dayOfWeek) : '${dsWeekdayLabel(slot.dayOfWeek)} 更新'),
    progressLabel: progressLabel,
    stateText: stateText,
    torrent: playableTorrent,
    playableFile: playableTorrent?.playableFile,
    job: activeJob ?? queuedJob,
    updatedToday: slot?.updateLabel,
    daysUntilUpdate: daysUntil,
  );
}

String? _progressLabel(int? watched, int? total) {
  if (watched == null && total == null) return null;
  if (watched == null) return '共 $total 话';
  final String ep = '第 ${watched.toString().padLeft(2, '0')} 话';
  return total == null ? ep : '$ep / 共 $total 话';
}

/// 从种子/任务名里抽「第几话」。
///
/// 只认**有分隔符前缀 + 有结尾边界**的数字：`- 11`、` - 01 `、`[03]`、`第 3 集`；
/// `1080p`、`2026/10/07`、`HEVC10bit` 这类都不是集数（否则「第 1080 话」就出来了）。
final RegExp _episodePattern = RegExp(
  r'[-\[\(（【\s]+(\d{1,4})(?=\s*$|[\s\]\)）】]|话|集|v\d)',
);

int? _maxEpisode(List<String?> titles) {
  int? best;
  for (final String? title in titles) {
    if (title == null) continue;
    for (final RegExpMatch m in _episodePattern.allMatches(title)) {
      final int? v = int.tryParse(m.group(1)!);
      if (v != null && v > 0 && v < 2000 && (best == null || v > best)) best = v;
    }
  }
  return best;
}

String? _stateText({
  required FollowingStatus status,
  required EngineTorrentView? activeTorrent,
  required QueueJobView? activeJob,
  required List<QueueJobView> matchedJobs,
  required List<EngineTorrentView> cachedTorrents,
}) {
  if (activeTorrent != null) {
    final int pct = (activeTorrent.progress * 100).round().clamp(0, 100);
    return '下载中 $pct%';
  }
  if (activeJob != null) return '下载中 · 队列任务';
  if (status == FollowingStatus.queued) return '队列中 · 等待下载';
  if (cachedTorrents.isNotEmpty) {
    int bytes = 0;
    for (final EngineTorrentView t in cachedTorrents) {
      bytes += t.totalBytes;
    }
    return '已缓存 ${cachedTorrents.length} 个种子 · ${formatBytes(bytes)}';
  }
  if (matchedJobs.isNotEmpty) return '队列中 · 等待下载';
  return null;
}
