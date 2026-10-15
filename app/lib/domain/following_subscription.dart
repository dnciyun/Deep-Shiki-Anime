/// 「正在追」里的**字幕组订阅**（第二十七轮）。
///
/// 用户原话：「移除订阅，功能同步至正在追。优化正在追，直接调用 mikan 的 rss 订阅，
/// 在字幕组的旁边，可以直接订阅，订阅可在正在追内标记已看过，已看过的在旁边打上勾」。
///
/// 模型：一个订阅 = **一部番的一个字幕组**，feed 就是 mikan 番剧页 `a.mikan-rss` 上那个
/// 每字幕组的 RSS 地址（`/RSS/Bangumi?bangumiId=…&subgroupid=…`，core 的
/// `MikanSubtitleGroup.rssUrl` 已经解析出来了）。番剧 id / 字幕组名 / 组 id 存在
/// 订阅的 `sourceParams` 里（core 原样持久化），于是「这一部番订阅了哪些组」是**精确匹配**，
/// 不需要拿番名去猜。
///
/// 为什么订阅不建"自动下载规则"：这里的订阅是**追更 + 手动下载**（点开层有「下载全部 /
/// 单集下载」）。所以默认规则只留过滤用的空壳（include 与 exclude 都留空），
/// `autoDownload = false` —— 默认排除规则里有 `HEVC.*10bit`，照它过滤会把这一组的
/// HEVC 集直接藏起来（那是看不见数据，不是省事）。
library;

import 'episodes.dart';
import 'following_store.dart';
import 'format.dart';
import 'models.dart';
import 'watch_history.dart';

/// 订阅的 `sourceParams` 键（番剧 id / 字幕组名 / 字幕组 id / 番名）。
const String kSubParamBangumiId = 'bangumiId';
const String kSubParamGroupId = 'groupId';
const String kSubParamGroupName = 'groupName';
const String kSubParamShowTitle = 'showTitle';

/// 这个订阅属于哪一部番（mikan 番剧 id）。
String? subscriptionBangumiId(SubscriptionView sub) {
  final String v = (sub.sourceParams[kSubParamBangumiId] ?? '').trim();
  return v.isEmpty ? null : v;
}

/// 这个订阅是哪个字幕组。
String? subscriptionGroupName(SubscriptionView sub) {
  final String v = (sub.sourceParams[kSubParamGroupName] ?? '').trim();
  return v.isEmpty ? null : v;
}

/// 订阅列表里属于这一部番的那些（顺序照订阅表）。
List<SubscriptionView> subscriptionsOf(FollowingEntry entry, List<SubscriptionView> subs) {
  final String id = (entry.mikanBangumiId ?? '').trim();
  if (id.isEmpty) return const <SubscriptionView>[];
  return subs
      .where((SubscriptionView s) => subscriptionBangumiId(s) == id)
      .toList(growable: false);
}

/// 这一部番 + 这个字幕组是不是已经订阅了（「订阅」按钮的选中态）。
SubscriptionView? subscriptionForGroup(
  List<SubscriptionView> subs, {
  required String bangumiId,
  required String groupName,
}) {
  for (final SubscriptionView s in subs) {
    if (subscriptionBangumiId(s) == bangumiId && subscriptionGroupName(s) == groupName) {
      return s;
    }
  }
  return null;
}

/// 造一条「字幕组订阅」（点「订阅」时用）。
///
/// [id] 由调用方给（`sub-<微秒>`，与既有订阅 id 同一形状），便于测试钉住。
SubscriptionView buildGroupSubscription({
  required String id,
  required String ruleId,
  required String bangumiId,
  required String groupName,
  String? groupId,
  required String showTitle,
  required String feedUrl,
  DateTime? now,
}) {
  final String label = showTitle.trim().isEmpty ? groupName : '${showTitle.trim()} · $groupName';
  return SubscriptionView(
    id: id,
    name: label,
    feedUrl: feedUrl,
    sourceKind: 'rss',
    sourceParams: <String, String>{
      kSubParamBangumiId: bangumiId,
      kSubParamGroupName: groupName,
      if ((groupId ?? '').trim().isNotEmpty) kSubParamGroupId: groupId!.trim(),
      if (showTitle.trim().isNotEmpty) kSubParamShowTitle: showTitle.trim(),
    },
    rules: <SubsRuleView>[
      // include / exclude 都留空 = 这一组的集全要（见文件头：默认 exclude 会藏数据）。
      SubsRuleView(id: ruleId, name: '全部剧集', excludeRegex: ''),
    ],
    refreshInterval: const Duration(minutes: 30),
    enabled: true,
  );
}

/// 一条订阅条目的展示用集号（`01` / `S01E02` / 空）。
String? episodeLabelOf(SourceItemView item) =>
    item.episodeHints.isEmpty ? null : formatEpisodeHints(item.episodeHints);

/// 一条订阅条目对应的「已看过」键（与观看记录同一套口径）。
///
/// [group] 取订阅的字幕组名（mikan RSS 里没有 group 字段，feed 本身就是按组分的）。
String subscriptionItemWatchKey({
  required String bangumiId,
  required String title,
  required String group,
  required SourceItemView item,
}) => watchRecordId(
  mikanBangumiId: bangumiId,
  title: title,
  group: group,
  episode: episodeNumber(item),
  episodeLabel: episodeLabelOf(item),
);

/// 一组条目 → 去重后的「已看过」键（下载全部/算总勾都用它）。
List<String> subscriptionItemWatchKeys({
  required String bangumiId,
  required String title,
  required String group,
  required List<SourceItemView> items,
}) {
  final List<String> out = <String>[];
  for (final SourceItemView item in items) {
    final String key = subscriptionItemWatchKey(
      bangumiId: bangumiId,
      title: title,
      group: group,
      item: item,
    );
    if (!out.contains(key)) out.add(key);
  }
  return out;
}
