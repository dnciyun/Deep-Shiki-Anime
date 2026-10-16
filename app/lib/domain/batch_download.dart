/// 批量下载（用户 2026-10-12 第二十三轮：「搜索页批量选择下载」）。
///
/// 为什么不是「在 UI 里 for 一遍 `enqueueDownload`」：
/// * 每一条都要**单独**兜住失败（mikan 的 RSS 条目要先去详情页补磁力，那一步会联网；
///   一条补不到不该让整批停在中途），并回报一句"哪条为什么失败"；
/// * 串行而不是并发：一次 20 条并发打同一个站，容易被当成抓取器；
/// * 结果要能算成一句话（[batchDownloadSummary]）—— 这是**纯**的，可单测。
library;

import 'error_text.dart';
import 'models.dart';

/// 这一条能不能批量下载。
///
/// 判据 = 单条「下载」能不能点（[SourceItemView.canDownload]）：自己带源
/// （磁力 / `.torrent` 直链 / infoHash），或者有详情页链接能补链 ——
/// `enqueueDownloads` 逐条兜错，补链失败会进 `failures` 并且**说清是哪一条**。
bool canBatchDownload(SourceItemView item) => item.canDownload;

/// 批量入队只要这一个能力 —— 不依赖 `QueuePort` 那 15 个无关方法。
///
/// UI 传 `port.enqueueDownload`，测试传一个 lambda；这样这一层是纯粹的"循环 + 兜错"，
/// 不需要为它造一个假端口。
typedef EnqueueDownload = Future<QueueJobView> Function(SourceItemView item);

/// 批量入队的结果。
class BatchDownloadResult {
  const BatchDownloadResult({
    required this.queued,
    required this.skipped,
    required this.failures,
    this.failedItems = const <SourceItemView>[],
  });

  /// 真的进了下载队列的条数。
  final int queued;

  /// 没有磁力/直链、被跳过的条数（不是失败：这些条目本来就不该点「下载」）。
  final int skipped;

  /// 失败的「标题：原因」列表（按处理顺序）。
  final List<String> failures;

  /// 失败的那些**条目**（与 [failures] 一一对应，顺序相同）。
  ///
  /// 第四十二轮 UX #32：只有文案的话，UI 没法把"失败的条目"重新勾回给用户 ——
  /// 而"只勾那几条再下一次"正是这条提示让人做的事。
  final List<SourceItemView> failedItems;

  bool get isEmpty => queued == 0 && skipped == 0 && failures.isEmpty;
}

/// 逐条入队；**永不抛**（失败进 [BatchDownloadResult.failures]）。
///
/// [onProgress] 每条处理完都会回调一次（`done` 从 1 开始），UI 用它显示「加入中 3/8」。
Future<BatchDownloadResult> enqueueDownloads(
  EnqueueDownload enqueue,
  List<SourceItemView> items, {
  void Function(int done, int total)? onProgress,
}) async {
  int queued = 0;
  int skipped = 0;
  final List<String> failures = <String>[];
  final List<SourceItemView> failedItems = <SourceItemView>[];
  int done = 0;
  for (final SourceItemView item in items) {
    done++;
    if (!canBatchDownload(item)) {
      skipped++;
      onProgress?.call(done, items.length);
      continue;
    }
    try {
      await enqueue(item);
      queued++;
    } catch (error, stackTrace) {
      final DsFailure failure = describeFailure(error, stackTrace: stackTrace);
      final String reason =
          failure.hint == null ? failure.message : '${failure.message}（${failure.hint}）';
      failures.add('${item.displayTitle}：$reason');
      failedItems.add(item);
    }
    onProgress?.call(done, items.length);
  }
  return BatchDownloadResult(
    queued: queued,
    skipped: skipped,
    failures: List<String>.unmodifiable(failures),
    failedItems: List<SourceItemView>.unmodifiable(failedItems),
  );
}

/// 一句话回报（SnackBar 用）。失败只报第一条 —— 20 条各报一遍没人看得完，
/// 而"有几条失败 + 第一条是什么"足够决定要不要单独重试那几条。
String batchDownloadSummary(BatchDownloadResult result) {
  final List<String> parts = <String>['已加入下载队列 ${result.queued} 条'];
  if (result.skipped > 0) parts.add('${result.skipped} 条没有磁力链，已跳过');
  if (result.failures.isNotEmpty) {
    final String more =
        result.failures.length > 1 ? '（另有 ${result.failures.length - 1} 条失败）' : '';
    parts.add('${result.failures.length} 条失败：${result.failures.first}$more');
  }
  return parts.join('；');
}
