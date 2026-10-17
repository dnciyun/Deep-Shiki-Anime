/// 「正在追」页要的那两路流（引擎种子 / 下载队列）的**稳定快照**（1.1.0 M1/T3）。
///
/// ## 为什么需要这一层（代码事实）
///
/// `FollowingPage.build` 旧实现直接 `ref.watch(engineTorrentsProvider)`（引擎流 **2Hz**）
/// 与 `ref.watch(queueJobsProvider)`（队列流，下载中每帧都在推）。于是：
///
/// * 只要引擎在跑，**整页**（页头统计 + 整张网格 + 每张卡）每 2Hz 重建一次；
/// * 每张卡还要把「全部种子名 × 全部任务名」用 `titlesMatch`（逐字符归一化）扫一遍，
///   一部番 N 个订阅 = N 倍扫描 —— 这一页是典型的大 O 重建大户。
///
/// 但卡片真正用到的只是**很少几个字段**（名字 / 状态 / 是否下完 / 进度整数百分比 /
/// 字节数 / 可播文件大小），进度没变时这些字段一模一样。所以这里按「卡片会读的字段」
/// 做一份签名：签名没变就**不通知下游**（Riverpod 的 `select` 用 `==` 比签名），
/// 下游 `Provider` 只在签名变化时才重算一次。
///
/// ⚠️ 别把它改成"直接 watch 原始流"：`List` 的 `==` 是身份比较，2Hz 重建会原样回来。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/models.dart';
import 'providers.dart';

/// 引擎种子里「卡片会读的字段」拼成的签名（顺序无关，内部排序）。
///
/// * `name`：卡片用它和追番名做 `titlesMatch`、也算集数；
/// * `state` / `finished`：决定算「下载中」还是「已缓存」；
/// * `progress` 只取**整数百分比**：卡片上写的就是 `下载中 N%`，再细的小数点没人看见；
/// * `totalBytes`：`已缓存 2 个种子 · 3.2 GiB` 要用；
/// * `playableFile.length` / `files.length`：「继续观看」挑的那个文件的槽位不能变
///   （文件大小变了说明换文件了，得重建）。
String followingTorrentsSignature(List<EngineTorrentView>? torrents) {
  if (torrents == null || torrents.isEmpty) return '';
  final List<String> parts = <String>[
    for (final EngineTorrentView t in torrents)
      '${t.name}\u0001${t.state.name}\u0001${t.finished ? 1 : 0}'
          '\u0001${(t.progress * 100).round()}\u0001${t.totalBytes}'
          '\u0001${t.playableFile?.length ?? 0}\u0001${t.files.length}',
  ]..sort();
  return parts.join('\u0000');
}

/// 下载队列里「卡片会读的字段」拼成的签名：标题（做匹配）+ 任务状态。
///
/// 速度/对等/剩余时间这些**卡片根本不显示**，所以不进签名 —— 它们每帧都在变，
/// 进来就等于没治。
String followingJobsSignature(List<QueueJobView>? jobs) {
  if (jobs == null || jobs.isEmpty) return '';
  final List<String> parts = <String>[
    for (final QueueJobView j in jobs)
      '${j.item.id}\u0001${j.item.displayTitle}\u0001${j.state.name}',
  ]..sort();
  return parts.join('\u0000');
}

/// 引擎种子列表的**稳定快照**：签名没变就不通知（见本文件头）。
///
/// 实现要点：`ref.watch(...select(签名))` 只负责"什么时候该重算"，
/// 真正的列表用 `ref.read` 取当前值 —— 如果这里改回 `ref.watch(engineTorrentsProvider)`，
/// 依赖就又挂到每秒两帧的原始流上了。
final Provider<List<EngineTorrentView>> followingTorrentsProvider =
    Provider<List<EngineTorrentView>>((Ref ref) {
  ref.watch<String>(
    engineTorrentsProvider.select(
      (AsyncValue<List<EngineTorrentView>> value) => followingTorrentsSignature(value.value),
    ),
  );
  return ref.read(engineTorrentsProvider).value ?? const <EngineTorrentView>[];
});

/// 下载队列的**稳定快照**（同 [followingTorrentsProvider]）。
final Provider<List<QueueJobView>> followingJobsProvider = Provider<List<QueueJobView>>((
  Ref ref,
) {
  ref.watch<String>(
    queueJobsProvider.select(
      (AsyncValue<List<QueueJobView>> value) => followingJobsSignature(value.value),
    ),
  );
  return ref.read(queueJobsProvider).value ?? const <QueueJobView>[];
});

/// 引擎流是否**已经失败**（「正在追」页要如实说"取数失败"，不能装成没有下载）。
///
/// 单独一个 `select` 出来是为了别让页面为了读 `hasError` 去 watch 整个 2Hz 流。
final Provider<bool> engineTorrentsFailedProvider = Provider<bool>((Ref ref) {
  return ref.watch(
    engineTorrentsProvider.select(
      (AsyncValue<List<EngineTorrentView>> value) => value.hasError && !value.isLoading,
    ),
  );
});

/// 队列流是否已经失败（同上）。
final Provider<bool> queueJobsFailedProvider = Provider<bool>((Ref ref) {
  return ref.watch(
    queueJobsProvider.select(
      (AsyncValue<List<QueueJobView>> value) => value.hasError && !value.isLoading,
    ),
  );
});
