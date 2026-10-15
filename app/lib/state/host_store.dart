/// 宿主侧持久化状态（不属于 core 的领域）：
/// * **继续观看**（spec §7.4 渲染图里的「继续观看」横排）；
/// * **磁盘剩余空间**（底部状态条）。
///
/// ⚠️ 第二十一轮删掉了「可清理标记」（`CleanupMarkedController`）：它只服务于
/// 「已缓存」页的「标记可清理 + 批量删除」，而那个页面按用户要求整页去掉了
/// （用户：「去掉已缓存页面，有已完成了」）。盘上遗留的 `dsanima.cleanup_marked`
/// 键没人再读，留着无害。
///
/// 全部走 core 的 `KeyValueStore`（生产 = Hive，测试 = InMemory），
/// 存的是可 JSON 序列化的结构。
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/format.dart';
import 'infra.dart';

// ─────────────────────────────────────────────────────────────────────────────
// 继续观看
// ─────────────────────────────────────────────────────────────────────────────

@immutable
class RecentPlayed {
  final String title;
  final int engineId;
  final int fileIndex;
  final DateTime at;

  /// 源条目 id（用于去重/再次点播）。
  final String? sourceItemId;

  const RecentPlayed({
    required this.title,
    required this.engineId,
    required this.fileIndex,
    required this.at,
    this.sourceItemId,
  });

  Map<String, Object?> toJson() => <String, Object?>{
        'title': title,
        'engineId': engineId,
        'fileIndex': fileIndex,
        'at': at.toIso8601String(),
        'sourceItemId': sourceItemId,
      };

  static RecentPlayed? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final Object? title = raw['title'];
    final Object? engineId = raw['engineId'];
    final Object? fileIndex = raw['fileIndex'];
    final DateTime? at = DateTime.tryParse('${raw['at']}');
    if (title is! String || engineId is! num || fileIndex is! num || at == null) {
      return null;
    }
    return RecentPlayed(
      title: title,
      engineId: engineId.toInt(),
      fileIndex: fileIndex.toInt(),
      at: at,
      sourceItemId: raw['sourceItemId'] as String?,
    );
  }
}

class RecentPlayedController extends Notifier<List<RecentPlayed>> {
  static const String storageKey = 'dsanima.recent_played';
  static const int maxEntries = 8;

  @override
  List<RecentPlayed> build() {
    final Object? raw = ref.watch(keyValueStoreProvider).get(storageKey);
    if (raw is! List) return const <RecentPlayed>[];
    return raw
        .map(RecentPlayed.fromJson)
        .whereType<RecentPlayed>()
        .toList(growable: false);
  }

  Future<void> record({
    required String title,
    required int engineId,
    required int fileIndex,
    String? sourceItemId,
  }) async {
    final RecentPlayed entry = RecentPlayed(
      title: title,
      engineId: engineId,
      fileIndex: fileIndex,
      at: DateTime.now(),
      sourceItemId: sourceItemId,
    );
    final List<RecentPlayed> next = <RecentPlayed>[
      entry,
      ...state.where((RecentPlayed r) => r.engineId != engineId),
    ].take(maxEntries).toList(growable: false);
    state = next;
    await ref
        .read(keyValueStoreProvider)
        .put(storageKey, next.map((RecentPlayed r) => r.toJson()).toList());
  }

  Future<void> remove(int engineId) async {
    final List<RecentPlayed> next = state
        .where((RecentPlayed r) => r.engineId != engineId)
        .toList(growable: false);
    state = next;
    await ref
        .read(keyValueStoreProvider)
        .put(storageKey, next.map((RecentPlayed r) => r.toJson()).toList());
  }

  Future<void> clear() async {
    state = const <RecentPlayed>[];
    await ref.read(keyValueStoreProvider).delete(storageKey);
  }
}

final NotifierProvider<RecentPlayedController, List<RecentPlayed>>
    recentPlayedProvider =
    NotifierProvider<RecentPlayedController, List<RecentPlayed>>(
        RecentPlayedController.new);

// ─────────────────────────────────────────────────────────────────────────────
// 磁盘剩余空间
// ─────────────────────────────────────────────────────────────────────────────

/// 下载目录所在盘的剩余空间（取不到 → null，UI 显示「—」）。
final diskFreeBytesProvider = FutureProvider.family<int?, String>(
    (Ref ref, String path) async {
  if (path.trim().isEmpty) return null;
  return ref.watch(diskSpaceProbeProvider).freeBytes(path);
});

/// 给状态条用的展示文本。
String formatDiskFree(int? bytes) => bytes == null ? '—' : formatBytes(bytes);
