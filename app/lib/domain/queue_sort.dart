/// 队列排序（用户 2026-10-10 第 1 轮问答：「要做排序顺序的名称排序 / 下载中排序等等」）。
///
/// 原来队列只有一种顺序：`priority` 小的先、同优先级按加入时间 —— 用户想按**名称**
/// 找一条任务、或想先看**正在下载**的那几条时没有别的选择。
///
/// 这里是纯函数/枚举：排序规则可单测，UI 只负责选一个 [QueueSortOrder]。
/// **「选了哪个」的持久化在 `state/providers.dart` 的 `queueSortProvider`**（它要读
/// 键值存储，属于 state 层；本文件保持零依赖，别把 provider 塞回来）。
library;

import 'models.dart';

/// 排序维度。[priority] 是历史默认（也是唯一支持拖拽改优先级的模式）。
enum QueueSortOrder {
  priority('priority', '优先级', '数字小 = 先下（可拖拽调整）'),
  state('state', '状态', '下载中 → 排队 → 已暂停 → 已完成 → 失败'),
  name('name', '名称', '按番名/集数文本'),
  size('size', '大小', '大的在前'),
  added('added', '加入时间', '新的在前');

  const QueueSortOrder(this.code, this.label, this.hint);

  final String code;
  final String label;
  final String hint;
}

/// 落盘的排序码 → 枚举。认不出来（老值/脏值/空）一律回退 [QueueSortOrder.priority]。
QueueSortOrder queueSortOrderFromCode(String? code) {
  for (final QueueSortOrder order in QueueSortOrder.values) {
    if (order.code == code) return order;
  }
  return QueueSortOrder.priority;
}

/// 状态排序权重：越靠前越"还在动"。
int _stateRank(JobState state) => switch (state) {
  JobState.downloading => 0,
  JobState.queued => 1,
  JobState.paused => 2,
  JobState.completed => 3,
  JobState.failed => 4,
  JobState.cancelled => 5,
};

/// 按 [order] 排序（不改原列表；同键时用 id 兜底，保证顺序稳定可测）。
///
/// [priority] 完全保持历史行为：优先级升序、同优先级按加入时间升序。
List<QueueJobView> sortQueueJobs(List<QueueJobView> jobs, QueueSortOrder order) {
  final List<QueueJobView> out = <QueueJobView>[...jobs];
  int byId(QueueJobView a, QueueJobView b) => a.id.compareTo(b.id);
  out.sort((QueueJobView a, QueueJobView b) {
    switch (order) {
      case QueueSortOrder.priority:
        final int byPriority = a.priority.compareTo(b.priority);
        if (byPriority != 0) return byPriority;
        final int byTime = a.createdAt.compareTo(b.createdAt);
        return byTime != 0 ? byTime : byId(a, b);
      case QueueSortOrder.state:
        final int byState = _stateRank(a.state).compareTo(_stateRank(b.state));
        if (byState != 0) return byState;
        // 同状态内仍然让优先级高的（数字小的）靠前。
        final int byPriority = a.priority.compareTo(b.priority);
        return byPriority != 0 ? byPriority : byId(a, b);
      case QueueSortOrder.name:
        final int byName = _compareText(
          a.item.displayTitle.toLowerCase(),
          b.item.displayTitle.toLowerCase(),
        );
        return byName != 0 ? byName : byId(a, b);
      case QueueSortOrder.size:
        final int sizeA = a.item.sizeBytes ?? -1;
        final int sizeB = b.item.sizeBytes ?? -1;
        final int bySize = sizeB.compareTo(sizeA); // 大的在前
        return bySize != 0 ? bySize : byId(a, b);
      case QueueSortOrder.added:
        final int byTime = b.createdAt.compareTo(a.createdAt); // 新的在前
        return byTime != 0 ? byTime : byId(a, b);
    }
  });
  return out;
}

/// 文本比较：数字段按数值大小比（"第 9 集" 要排在 "第 10 集" 前面）。
int _compareText(String a, String b) {
  final RegExp digits = RegExp(r'\d+');
  final List<String> ap = a.split(digits).toList();
  final List<String> bp = b.split(digits).toList();
  final Iterable<RegExpMatch> an = digits.allMatches(a);
  final Iterable<RegExpMatch> bn = digits.allMatches(b);
  final int parts = ap.length < bp.length ? ap.length : bp.length;
  for (int i = 0; i < parts; i++) {
    final int byText = ap[i].compareTo(bp[i]);
    if (byText != 0) return byText;
    final int? na = i < an.length ? int.tryParse(an.elementAt(i).group(0)!) : null;
    final int? nb = i < bn.length ? int.tryParse(bn.elementAt(i).group(0)!) : null;
    if (na != null && nb != null && na != nb) return na.compareTo(nb);
  }
  return a.compareTo(b);
}

/// 4 档优先级（用户 2026-10-10 第 3 轮问答：每行点开直接选一档，不用连点 ↑↓）。
///
/// 档位→数值的映射沿用历史语义（数字小 = 先下；点播 10、自动预取 100）：
/// 最高 0 / 高 5 / 普通 10 / 低 20。
///
/// ⚠️ **预取任务（`priority >= 100`）单独一档**：队列的"绝不自动下载"规则靠
/// `isPrefetch` 把预取条目压住（`core/lib/subs/queue.dart`），把预取条目的
/// 优先级改成 0/5/10/20 会让它变成"可启动"，等于替用户点了一次下载。
/// 所以对预取条目，档位落回 `100 + 档位序号`，只调整预取内部的先后。
enum QueuePriorityLevel {
  highest('最高'),
  high('高'),
  normal('普通'),
  low('低');

  const QueuePriorityLevel(this.label);

  final String label;
}

/// 档位对应的优先级数值（给非预取任务用）。
const List<int> kQueuePriorityValues = <int>[0, 5, 10, 20];

/// 预取任务（priority ≥ 100）保持"预取"身份，只在预取带内排序。
const int kPrefetchPriorityBase = 100;

/// 优先级数值 → 档位序号（0..3，用于下拉当前值）。
int priorityLevelOf(int priority) {
  final int value = priority >= kPrefetchPriorityBase ? priority - kPrefetchPriorityBase : priority;
  if (value <= kQueuePriorityValues[0]) return 0;
  if (value <= kQueuePriorityValues[1]) return 1;
  if (value <= kQueuePriorityValues[2]) return 2;
  return 3;
}

/// 档位序号 + 原优先级 → 新优先级数值（保留"是不是预取"这个身份）。
int priorityForLevel(int level, int currentPriority) {
  final int idx = level.clamp(0, kQueuePriorityValues.length - 1);
  final int base = currentPriority >= kPrefetchPriorityBase ? kPrefetchPriorityBase : 0;
  return base + kQueuePriorityValues[idx];
}

/// 拖拽落点 → 新的优先级数值；返回 **null = 这次拖拽不会改变任何东西**。
///
/// [others] 是"移除被拖项之后"的列表，[at] 是落点下标（0..others.length），
/// [current] 是被拖项现在的优先级。
///
/// 两种情况算不出变化，都必须返回 null：
/// * 落点前后**都没有别的活动任务**（队列里只有它一个）→ 没有参照；
/// * 相邻优先级**只差 1** → 中间值就等于自己。
///
/// 为什么要有这个返回值：旧实现把这两种情况都写成"优先级 = 自己原来的值"，
/// 却照样报「优先级 → N（数字小 = 先下）」—— 用户以为顺序变了（静默假成功）。
int? priorityForReorder({
  required List<QueueJobView> others,
  required int at,
  required int current,
}) {
  final int clamped = at.clamp(0, others.length);
  int? before;
  for (int i = clamped - 1; i >= 0; i--) {
    if (others[i].state.isActive) {
      before = others[i].priority;
      break;
    }
  }
  int? after;
  for (int i = clamped; i < others.length; i++) {
    if (others[i].state.isActive) {
      after = others[i].priority;
      break;
    }
  }
  if (before == null && after == null) return null;
  final int next = before != null && after != null
      ? (before + after) ~/ 2
      : before != null
      ? before + 10
      : after! - 10;
  return next == current ? null : next;
}
