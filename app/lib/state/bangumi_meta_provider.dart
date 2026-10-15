/// Bangumi 元数据查询 provider（spec §7.8）。
///
/// 未装配时返回「没匹配上」而不是报错：**元数据是锦上添花，缺了不能挡路**
/// （首启向导、番剧详情页都必须照常可用）。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/bangumi_match.dart';
import '../state/bangumi_meta.dart';

/// 元数据服务（真实实现在 `state/bangumi_meta.dart`，由 main.dart 注入）。
final Provider<BangumiMetaService?> bangumiMetaProvider =
    Provider<BangumiMetaService?>((Ref ref) => null);

/// 查询键（record 结构相等 → family 不会重复建）。
typedef BangumiLookupQuery = ({String title, int? year, int? episodes});

/// 按番名查 Bangumi 条目（带 7 天磁盘缓存；**永不抛**）。
final bangumiLookupProvider =
    FutureProvider.family<BangumiLookup, BangumiLookupQuery>(
        (Ref ref, BangumiLookupQuery query) async {
  final BangumiMetaService? service = ref.watch(bangumiMetaProvider);
  if (service == null || query.title.trim().isEmpty) {
    return const BangumiLookup();
  }
  return service.lookup(query.title, year: query.year, episodes: query.episodes);
});

/// 匹配是否够格显示（UI 直接用它决定要不要渲染封面）。
bool bangumiLookupIsUsable(BangumiLookup lookup) =>
    lookup.match != null &&
    lookup.match!.confidence.score >= bangumiMinConfidence;
