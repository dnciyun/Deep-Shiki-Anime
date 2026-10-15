/// 「正在追」状态：本地追番标记（spec §7.6）。
///
/// 只是把「用户点过追番的番」收进一个本地列表 —— **不建订阅、不自动下载**。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/bangumi.dart';
import '../domain/following_store.dart';
import '../domain/models.dart';
import '../domain/title_match.dart';
import 'infra.dart';

/// 追番记录的稳定 id。
///
/// 优先级：mikan 番剧 id（主页追的）→ Bangumi id（推荐/详情页追的）→ 归一化番名。
/// 这样同一部番从不同入口追番不会出现两条记录。
String followingIdFor({
  String? mikanBangumiId,
  int? bgmId,
  String? title,
}) {
  final String m = (mikanBangumiId ?? '').trim();
  if (m.isNotEmpty) return 'mikan:$m';
  if (bgmId != null && bgmId > 0) return 'bgm:$bgmId';
  return 'title:${normalizeTitleForMatch(title)}';
}

/// 从主页海报卡（mikan 追番表条目）构造追番记录。
///
/// 首页条目**只有更新日期，没有集数**（spec §7.5 禁止伪造），所以这里
/// 不写 `totalEpisodes`；评分/英文名也没有（那是 Bangumi 的东西）。
FollowingEntry followingEntryFromSchedule(
  ScheduleEntryView entry, {
  DateTime? now,
}) =>
    FollowingEntry(
      id: followingIdFor(
          mikanBangumiId: entry.bangumiId, title: entry.title),
      title: entry.displayTitle,
      coverUrl: entry.coverUrl,
      mikanBangumiId:
          entry.bangumiId.trim().isEmpty ? null : entry.bangumiId.trim(),
      addedAt: now ?? DateTime.now(),
    );

/// 从 Bangumi 条目（今日推荐 / 详情页）构造追番记录。
FollowingEntry followingEntryFromBangumi(
  BangumiSubject subject, {
  DateTime? now,
}) =>
    FollowingEntry(
      id: followingIdFor(bgmId: subject.id, title: subject.displayTitle),
      title: subject.displayTitle,
      titleEn: subject.alternateTitle,
      coverUrl: subject.coverUrl,
      coverReferer: bangumiCoverReferer,
      bgmId: subject.id,
      score: subject.score,
      airDate: subject.date,
      totalEpisodes: subject.eps,
      addedAt: now ?? DateTime.now(),
    );

/// 追番列表（内存态 + Hive 持久化）。
class FollowingController extends Notifier<List<FollowingEntry>> {
  FollowingStore get _store =>
      FollowingStore(ref.read(keyValueStoreProvider));

  @override
  List<FollowingEntry> build() => _store.load();

  bool isFollowing(String id) =>
      state.any((FollowingEntry e) => e.id == id);

  /// 追番 / 取消追番；返回 true = 现在已追。
  Future<bool> toggle(FollowingEntry entry) async {
    final bool now = await _store.toggle(entry);
    state = _store.load();
    return now;
  }

  Future<void> remove(String id) async {
    await _store.remove(id);
    state = _store.load();
  }

  /// 记一笔最近观看（「正在追」的第二排序键）。
  Future<void> touch(String id) async {
    await _store.touch(id);
    state = _store.load();
  }
}

final NotifierProvider<FollowingController, List<FollowingEntry>>
    followingProvider =
    NotifierProvider<FollowingController, List<FollowingEntry>>(
        FollowingController.new);

/// 侧栏徽标用的追番数量。
final Provider<int> followingCountProvider =
    Provider<int>((Ref ref) => ref.watch(followingProvider).length);
