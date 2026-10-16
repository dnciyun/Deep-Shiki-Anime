/// 队列排序的纯逻辑测试（用户 2026-10-10 第 1 轮问答：要能按名称 / 状态 / 大小等排序）。
///
/// 排序是"用户找不到任务"的直接原因，所以规则要钉死：同键时用 id 兜底保证稳定，
/// `priority` 模式必须**完全等于**历史行为（那条路径还挂着拖拽改优先级）。
///
/// 末尾两条是**落盘**（用户 2026-10-11 第二阶段清单第 5 项）：选过的排序维度要能
/// 熬过一次重启（用同一个键值存储造第二个容器模拟重启）。
library;

import 'package:dsanima/domain/models.dart';
import 'package:dsanima/domain/queue_sort.dart';
import 'package:dsanima/state/providers.dart';
import 'package:dsanima_core/sources/kv.dart' show InMemoryKeyValueStore;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

QueueJobView job(
  String id, {
  required String title,
  JobState state = JobState.queued,
  int priority = 10,
  int? sizeBytes,
  int day = 1,
}) {
  return QueueJobView(
    id: id,
    item: SourceItemView(id: 'item-$id', title: title, sourceId: 'mikan', sizeBytes: sizeBytes),
    state: state,
    priority: priority,
    createdAt: DateTime(2026, 10, day),
    updatedAt: DateTime(2026, 10, day),
  );
}

void main() {
  test('默认按优先级（数字小 = 先下），同优先级按加入时间', () {
    final List<QueueJobView> jobs = <QueueJobView>[
      job('c', title: 'C', priority: 100, day: 3),
      job('a', title: 'A', priority: 10, day: 2),
      job('b', title: 'B', priority: 10, day: 1),
    ];
    expect(sortQueueJobs(jobs, QueueSortOrder.priority).map((QueueJobView j) => j.id), <String>[
      'b',
      'a',
      'c',
    ]);
  });

  test('按名称：数字段按数值比（第 9 集在第 10 集之前）', () {
    final List<QueueJobView> jobs = <QueueJobView>[
      job('x', title: '番剧 第 10 集'),
      job('y', title: '番剧 第 9 集'),
      job('z', title: '阿凡达'),
    ];
    expect(
      sortQueueJobs(jobs, QueueSortOrder.name).map((QueueJobView j) => j.displayTitle),
      <String>['番剧 第 9 集', '番剧 第 10 集', '阿凡达'],
    );
  });

  test('按状态：还在动的排前面（下载中 → 排队 → 已暂停 → 已完成 → 失败 → 已取消）', () {
    final List<QueueJobView> jobs = <QueueJobView>[
      job('done', title: 'D', state: JobState.completed),
      job('dl', title: 'A', state: JobState.downloading),
      job('fail', title: 'E', state: JobState.failed),
      job('pause', title: 'C', state: JobState.paused),
      job('queue', title: 'B', state: JobState.queued),
      job('cancel', title: 'F', state: JobState.cancelled),
    ];
    expect(sortQueueJobs(jobs, QueueSortOrder.state).map((QueueJobView j) => j.id), <String>[
      'dl',
      'queue',
      'pause',
      'done',
      'fail',
      'cancel',
    ]);
  });

  test('按大小：大的在前，未知大小沉底', () {
    final List<QueueJobView> jobs = <QueueJobView>[
      job('mid', title: 'mid', sizeBytes: 500),
      job('big', title: 'big', sizeBytes: 900),
      job('unknown', title: 'unknown'),
    ];
    expect(sortQueueJobs(jobs, QueueSortOrder.size).map((QueueJobView j) => j.id), <String>[
      'big',
      'mid',
      'unknown',
    ]);
  });

  test('按加入时间：新的在前', () {
    final List<QueueJobView> jobs = <QueueJobView>[
      job('old', title: 'old', day: 1),
      job('new', title: 'new', day: 9),
      job('mid', title: 'mid', day: 5),
    ];
    expect(sortQueueJobs(jobs, QueueSortOrder.added).map((QueueJobView j) => j.id), <String>[
      'new',
      'mid',
      'old',
    ]);
  });

  test('不改原列表（返回新列表）', () {
    final List<QueueJobView> jobs = <QueueJobView>[
      job('b', title: 'B', priority: 20),
      job('a', title: 'A', priority: 10),
    ];
    sortQueueJobs(jobs, QueueSortOrder.priority);
    expect(jobs.map((QueueJobView j) => j.id), <String>['b', 'a']);
  });

  test('排序结果稳定：同键时按 id 兜底，不随输入顺序抖动', () {
    final List<QueueJobView> jobs = <QueueJobView>[
      job('z', title: 'same', priority: 10, day: 1),
      job('a', title: 'same', priority: 10, day: 1),
    ];
    expect(sortQueueJobs(jobs, QueueSortOrder.priority).map((QueueJobView j) => j.id), <String>[
      'a',
      'z',
    ]);
    expect(
      sortQueueJobs(jobs.reversed.toList(), QueueSortOrder.priority).map((QueueJobView j) => j.id),
      <String>['a', 'z'],
    );
  });

  test('落盘：选过的排序熬过一次「重启」（同一个存储 → 新容器）', () async {
    final InMemoryKeyValueStore store = InMemoryKeyValueStore();
    final ProviderContainer before = ProviderContainer(
      overrides: [keyValueStoreProvider.overrideWithValue(store)],
    );
    expect(before.read(queueSortProvider), QueueSortOrder.priority, reason: '默认优先级');

    before.read(queueSortProvider.notifier).select(QueueSortOrder.name);
    expect(before.read(queueSortProvider), QueueSortOrder.name, reason: '立即生效');
    await Future<void>.delayed(Duration.zero); // 等落盘（put 是异步的）
    before.dispose();

    // 「重启」= 同一个存储、全新的容器（provider 状态全丢）。
    final ProviderContainer after = ProviderContainer(
      overrides: [keyValueStoreProvider.overrideWithValue(store)],
    );
    expect(after.read(queueSortProvider), QueueSortOrder.name, reason: '重启后还要记得上次选的排序维度');
    after.dispose();
  });

  test('落盘：存储里是脏值/老值时回退优先级，不崩也不乱排', () async {
    expect(queueSortOrderFromCode('name'), QueueSortOrder.name);
    expect(queueSortOrderFromCode(''), QueueSortOrder.priority);
    expect(queueSortOrderFromCode(null), QueueSortOrder.priority);
    expect(queueSortOrderFromCode('早就删掉的维度'), QueueSortOrder.priority);

    final InMemoryKeyValueStore store = InMemoryKeyValueStore();
    await store.put(QueueSortController.storageKey, 42); // 类型都不对
    final ProviderContainer c = ProviderContainer(
      overrides: [keyValueStoreProvider.overrideWithValue(store)],
    );
    expect(c.read(queueSortProvider), QueueSortOrder.priority);
    c.dispose();
  });

  group('拖拽落点 → 新优先级：算不出变化必须返回 null（不许静默假成功）', () {
    test('落在两个活动任务中间 → 取中间值', () {
      final List<QueueJobView> others = <QueueJobView>[
        job('a', title: 'A', priority: 10),
        job('b', title: 'B', priority: 30),
      ];
      expect(priorityForReorder(others: others, at: 1, current: 99), 20);
    });

    test('只有一个活动任务可参照 → 前面 +10 / 后面 -10', () {
      final List<QueueJobView> others = <QueueJobView>[
        job('a', title: 'A', priority: 10),
      ];
      expect(priorityForReorder(others: others, at: 1, current: 99), 20, reason: '落在它后面 → 比它大 10');
      expect(priorityForReorder(others: others, at: 0, current: 99), 0, reason: '落在它前面 → 比它小 10');
    });

    test('队列里只有它自己（前后都没有活动任务）→ null', () {
      expect(priorityForReorder(others: <QueueJobView>[], at: 0, current: 10), isNull);
      expect(
        priorityForReorder(
          others: <QueueJobView>[job('done', title: 'D', state: JobState.completed)],
          at: 0,
          current: 10,
        ),
        isNull,
        reason: '已完成的任务不算顺序参照',
      );
    });

    test('相邻优先级只差 1、中间值就是自己 → null（写下去也是原地不动）', () {
      final List<QueueJobView> others = <QueueJobView>[
        job('a', title: 'A', priority: 5),
        job('b', title: 'B', priority: 6),
      ];
      expect(priorityForReorder(others: others, at: 1, current: 5), isNull);
      expect(priorityForReorder(others: others, at: 1, current: 9), 5);
    });
  });
}
