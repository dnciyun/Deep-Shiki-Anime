/// 主页「今日推荐」状态（spec §7.7）。
///
/// 种子按「当天日期」固定 → 当天稳定、隔天换批；`换一批 ↻` 用递增 batch。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/bangumi.dart';
import '../domain/ports.dart';
import '../domain/unavailable.dart';
import 'schedule_provider.dart';

/// 推荐端口（真实实现在 `state/bangumi_recommend.dart`，由 main.dart 注入）。
final Provider<RecommendPort> recommendPortProvider =
    Provider<RecommendPort>((Ref ref) => const UnavailableRecommendPort());

/// 本次推荐用的种子 = **当天日期**（决策 F13：不可刷新 —— 当天稳定、隔天自动换）。
///
/// ⚠️ 原来的「换一批 ↻」批次号（`RecommendBatchController` / `recommendBatchProvider`）
/// 已在第二十九轮删除：区头那颗圆形按钮与它一起没了，主页没有任何手动刷新入口。
final Provider<int> recommendSeedProvider = Provider<int>(
  (Ref ref) => recommendSeedForDate(ref.watch(todayProvider)),
);

/// 今日推荐 5 部（一次拉取；同一天结果稳定，跨天自动换）。 
final FutureProvider<List<BangumiSubject>> recommendProvider =
    FutureProvider<List<BangumiSubject>>((Ref ref) async {
  final RecommendPort port = ref.watch(recommendPortProvider);
  if (!port.isAvailable) {
    throw const PortUnavailableException(
      '今日推荐未接通：Bangumi API 客户端没装配',
      hint: '主页其它部分照常可用；装配 BangumiRecommendPort 后自动恢复',
    );
  }
  return port.recommend(seed: ref.watch(recommendSeedProvider));
});

/// 推荐 rail 的条数（spec：5 部）。
const int recommendCount = 5;
