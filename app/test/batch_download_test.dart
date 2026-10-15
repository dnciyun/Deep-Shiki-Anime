/// 批量下载的循环 + 兜错 + 一句话回报（`domain/batch_download.dart`）单测。
///
/// 用户 2026-10-12 第二十三轮：「搜索页批量选择下载」。这一层不碰 UI、不碰真端口，
/// 只钉住三件事：**没有磁力链的跳过**、**一条失败不拖累后面**、**结果能说成一句话**。
library;

import 'package:dsanima/domain/batch_download.dart';
import 'package:dsanima/domain/models.dart';
import 'package:flutter_test/flutter_test.dart';

SourceItemView item(String id, {String? magnet = 'magnet:?xt=urn:btih:x'}) => SourceItemView(
  id: id,
  sourceId: 'nyaa',
  title: '[组] 某番 - $id [1080p]',
  magnet: magnet,
);

QueueJobView jobOf(SourceItemView i) => QueueJobView(
  id: 'job-${i.id}',
  item: i,
  state: JobState.queued,
  createdAt: DateTime(2026, 10, 12, 12),
  updatedAt: DateTime(2026, 10, 12, 12),
);

void main() {
  test('可下载的逐条入队，没有磁力链的跳过（不算失败）', () async {
    final List<String> enqueued = <String>[];
    final BatchDownloadResult result = await enqueueDownloads(
      (SourceItemView i) async {
        enqueued.add(i.id);
        return jobOf(i);
      },
      <SourceItemView>[
        item('01'),
        item('02', magnet: null), // 没有磁力链：跳过，不报错
        item('03'),
      ],
    );

    expect(enqueued, <String>['01', '03']);
    expect(result.queued, 2);
    expect(result.skipped, 1);
    expect(result.failures, isEmpty);
    expect(batchDownloadSummary(result), '已加入下载队列 2 条；1 条没有磁力链，已跳过');
  });

  test('一条失败不拖累后面：失败清单带标题与原因，其余照旧入队', () async {
    final List<String> enqueued = <String>[];
    final BatchDownloadResult result = await enqueueDownloads(
      (SourceItemView i) async {
        if (i.id == '02') throw StateError('mikan 详情页拉不到磁力');
        enqueued.add(i.id);
        return jobOf(i);
      },
      <SourceItemView>[item('01'), item('02'), item('03')],
    );

    expect(enqueued, <String>['01', '03']);
    expect(result.queued, 2);
    expect(result.failures, hasLength(1));
    expect(result.failures.first, contains('02'));
    expect(result.failures.first, contains('拉不到磁力'));
    final String summary = batchDownloadSummary(result);
    expect(summary, contains('已加入下载队列 2 条'));
    expect(summary, contains('1 条失败'));
  });

  test('多条失败只报第一条 + 一句"另有 N 条"（20 条各报一遍没人看得完）', () async {
    final BatchDownloadResult result = await enqueueDownloads(
      (SourceItemView i) async => throw StateError('引擎没起'),
      <SourceItemView>[item('01'), item('02'), item('03')],
    );

    expect(result.queued, 0);
    expect(result.failures, hasLength(3));
    final String summary = batchDownloadSummary(result);
    expect(summary, contains('3 条失败'));
    expect(summary, contains('另有 2 条失败'));
  });

  test('进度回调：每条处理完一次，总数是传进来的条数（含被跳过的）', () async {
    final List<String> progress = <String>[];
    await enqueueDownloads(
      (SourceItemView i) async => jobOf(i),
      <SourceItemView>[item('01'), item('02', magnet: null), item('03')],
      onProgress: (int done, int total) => progress.add('$done/$total'),
    );
    expect(progress, <String>['1/3', '2/3', '3/3']);
  });

  test('空列表：什么都不做，摘要也不撒谎', () async {
    final BatchDownloadResult result =
        await enqueueDownloads((SourceItemView i) async => jobOf(i), const <SourceItemView>[]);
    expect(result.isEmpty, isTrue);
    expect(batchDownloadSummary(result), '已加入下载队列 0 条');
  });
}
