/// 队列行文案（`domain/queue_display.dart`）单测。
///
/// 用户 2026-10-12 第二十三轮：「连续点击下载时，前面下载的会出现『引擎里已经没有这个
/// 任务』」—— 真正的原因是这个判定只看 `engineId` 是否为空。这一组用例把那两个
/// **正常但 engineId 为空**的窗口钉住：排队中、正在把磁力交给引擎（等元数据）。
library;

import 'package:dsanima/domain/models.dart';
import 'package:dsanima/domain/queue_display.dart';
import 'package:flutter_test/flutter_test.dart';

QueueJobView job(
  JobState state, {
  int? engineId,
  int priority = 20,
  int attempts = 1,
}) => QueueJobView(
  id: 'job-1',
  item: const SourceItemView(
    id: 'item-1',
    sourceId: 'nyaa',
    title: '[组] 某番 - 01 [1080p]',
    magnet: 'magnet:?xt=urn:btih:abc',
  ),
  state: state,
  engineId: engineId,
  priority: priority,
  attempts: attempts,
  createdAt: DateTime(2026, 10, 12, 12),
  updatedAt: DateTime(2026, 10, 12, 12),
);

void main() {
  group('引擎侧胶囊：按真实状态说话', () {
    test('排队中（还没轮到）**不许**说「引擎里已经没有这个任务」', () {
      final QueueJobView j = job(JobState.queued);
      final ({String label, bool warn}) chip = queueEngineChip(j);
      expect(chip.label, '排队等待中：还没轮到它');
      expect(chip.warn, isFalse, reason: '排队是过程，不该报警');
      expect(chip.label, isNot(contains('引擎里已经没有')));
    });

    test('下载中但 addMagnet 还没回来（等元数据）也不许说那句话', () {
      final QueueJobView j = job(JobState.downloading);
      expect(j.engineId, isNull);
      final ({String label, bool warn}) chip = queueEngineChip(j);
      expect(chip.label, '正在把任务交给引擎…');
      expect(chip.warn, isFalse);
      expect(queueProgressText(j), '等元数据…');
    });

    test('暂停且引擎里没有它：保留第十九轮那句话（重启后确实丢了）', () {
      final QueueJobView j = job(JobState.paused);
      final ({String label, bool warn}) chip = queueEngineChip(j);
      expect(chip.label, '引擎里已经没有这个任务');
      expect(chip.warn, isTrue);
      expect(queueProgressText(j), '已暂停');
    });

    test('有 engineId 但快照里查不到：那是引擎连不上，不是队列的问题', () {
      final QueueJobView j = job(JobState.downloading, engineId: 7);
      final ({String label, bool warn}) chip = queueEngineChip(j);
      expect(chip.label, '引擎未连接：进度不可用');
      expect(chip.warn, isTrue);
      expect(queueProgressText(j), '进度不可用');
    });

    test('失败：原因在下面那一行，胶囊别再说"引擎里没有它"', () {
      final QueueJobView j = job(JobState.failed);
      expect(queueEngineChip(j).label, '没交给引擎（见下方错误）');
      expect(queueProgressText(j), '失败');
    });

    test('已完成的记录被引擎移除后：照旧说那句话（这时它是真的）', () {
      expect(queueEngineChip(job(JobState.completed)).label, '引擎里已经没有这个任务');
      expect(queueEngineChip(job(JobState.cancelled)).label, '引擎里已经没有这个任务');
      expect(queueProgressText(job(JobState.cancelled)), '已取消');
    });
  });

  test('进度列：旧文案「等待引擎…」不再出现（它会骗暂停/排队中的任务）', () {
    for (final JobState state in JobState.values) {
      expect(queueProgressText(job(state)), isNot('等待引擎…'));
    }
  });
}
