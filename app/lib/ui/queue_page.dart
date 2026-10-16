/// 队列页：任务列表（引擎 SSE 实时进度）+ 暂停/继续/删除（含删文件）+ 拖拽优先级。
///
/// 视觉（新拟态规范 `docs/specs/2026-10-10-dsanima-neo-theme.md`）：概览用语义胶囊
/// （决策 A18：小面积着色），任务行是 `QueueJobRow` 的凸起卡片（listSafe），
/// 操作走 `NeoButton` / `NeoIconButton`（按下凹进去）。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/error_text.dart';
import '../domain/format.dart';
import '../domain/models.dart';
import '../domain/ports.dart';
import '../domain/queue_sort.dart';
import '../state/providers.dart';
import '../theme/tokens.dart';
import 'widgets/ds_cards.dart';
import 'widgets/ds_stagger.dart';
import 'widgets/feedback.dart';
import 'widgets/neo.dart';
import 'widgets/neo_dropdown.dart';
import 'widgets/state_views.dart';

/// 「一起下载 N 条」选择器（用户 2026-10-12 第二十三轮：「队列则是一起下载的数量」）。
///
/// 它写的是**同一份设置**（`settings.bandwidth.maxConcurrent`）——设置页的
/// 「并发下载数（1–3）」与这里显示的永远是同一个数，不存在两套并发上限。
/// 改完立刻走 `applySettings`（与设置页「保存并生效」同一条链路）：并发数不是进程
/// 参数，**不会重启边车**，但会走到 `queue.setPolicy` → `pump()`，
/// 于是新上限**当场生效**（排队中的任务马上按新数量开始，不用等下一次队列变化）。
class _ConcurrentPicker extends ConsumerWidget {
  const _ConcurrentPicker();

  /// 可选值 = 设置页那三个（`effectiveMaxConcurrent` 也是夹到 1–3，见 core 队列）。
  static const List<int> choices = <int>[1, 2, 3];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final int raw = ref.watch(settingsProvider).bandwidth.maxConcurrent;
    final int current = raw < 1 ? 1 : (raw > 3 ? 3 : raw);
    return NeoDropdown<int>(
      width: 176,
      height: 32,
      fontSize: DsTypeScale.caption,
      value: current,
      tooltip: '一起下载几条：队列每次按这个数把任务交给引擎（= 设置里的「并发下载数」）',
      label: '一起下载 · $current 条',
      items: <NeoDropdownItem<int>>[
        for (final int n in choices) NeoDropdownItem<int>(n, '一起下载 $n 条'),
      ],
      onSelected: (int n) => _select(context, ref, n),
    );
  }

  Future<void> _select(BuildContext context, WidgetRef ref, int value) async {
    final AppSettings current = ref.read(settingsProvider);
    if (current.bandwidth.maxConcurrent == value) return;
    final AppSettings next = current.copyWith(
      bandwidth: current.bandwidth.copyWith(maxConcurrent: value),
    );
    await runGuarded(
      context,
      action: () async {
        await ref.read(settingsProvider.notifier).replace(next);
        await ref.read(lifecyclePortProvider).applySettings(next);
      },
      success: '一起下载 $value 条',
    );
  }
}

/// 队列排序选择器：凹槽 + 下拉（与主页的星期下拉同一形态 → 同一个 `NeoDropdown`）。
class _SortPicker extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final QueueSortOrder order = ref.watch(queueSortProvider);
    return NeoDropdown<QueueSortOrder>(
      width: 132,
      height: 32,
      fontSize: DsTypeScale.caption,
      value: order,
      tooltip: '排序：${order.hint}',
      label: '排序 · ${order.label}',
      items: <NeoDropdownItem<QueueSortOrder>>[
        for (final QueueSortOrder o in QueueSortOrder.values)
          NeoDropdownItem<QueueSortOrder>(o, '排序 · ${o.label}', hint: o.hint),
      ],
      onSelected: (QueueSortOrder o) => ref.read(queueSortProvider.notifier).select(o),
    );
  }
}

class QueuePage extends ConsumerWidget {
  const QueuePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final DsTokens t = context.ds;
    final AsyncValue<List<QueueJobView>> jobsValue = ref.watch(queueJobsProvider);
    final QueueSummary summary = ref.watch(queueSummaryProvider);
    // 一次性订阅引擎进度，行内只做纯查表（避免在 itemBuilder 里 watch）。
    final AsyncValue<List<EngineTorrentView>> torrentsValue =
        ref.watch(engineTorrentsProvider);
    final List<EngineTorrentView> torrents =
        torrentsValue.value ?? const <EngineTorrentView>[];
    // 队列本身是 Dart 侧状态，**引擎挂了它照样读得出来** —— 所以"引擎没连上"这件事
    // 只能靠这一路 AsyncError 判断。旧实现直接 `?? const []` 吞掉它：边车启动失败或
    // 中途挂掉时，每行进度静静停在最后一次成功的位置，界面上一句解释都没有
    //（第四十二轮 UX #3，二级）。
    final Object? torrentsError = torrentsValue.error;
    final bool torrentsFailed = torrentsError != null && !torrentsValue.isLoading;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: EdgeInsets.fromLTRB(t.spacing, t.spacing, t.spacing, 0),
          child: Row(
            children: <Widget>[
              DsChip(label: '下载中 ${summary.active}', tone: t.accent),
              const SizedBox(width: 6),
              DsChip(label: '排队 ${summary.queued}'),
              if (summary.paused > 0) ...<Widget>[
                const SizedBox(width: 6),
                // 「暂停」不是「下载中」：用户 2026-10-11 的遗留任务就是 paused，
                // 旧统计把它算进 active，看着像"一直在下"。
                DsChip(label: '已暂停 ${summary.paused}', tone: t.text3),
              ],
              const SizedBox(width: 6),
              DsChip(label: '已完成 ${summary.completed}', tone: t.success),
              if (summary.failed > 0) ...<Widget>[
                const SizedBox(width: 6),
                DsChip(label: '失败/取消 ${summary.failed}', tone: t.danger),
              ],
              const Spacer(),
              // 「一起下载 N 条」（第二十三轮）：连点下载的人真正关心的是"同时在下几条"。
              const _ConcurrentPicker(),
              const SizedBox(width: 8),
              // 排序维度（用户 2026-10-10 第 1 轮问答：要能按名称 / 状态排序）。
              _SortPicker(),
              const SizedBox(width: 8),
              // 用户 2026-10-10 第 4–20 轮清单：两颗「清空」按钮收进「⋯」菜单
              //（危险动作不该与计数胶囊并列常驻）。
              PopupMenuButton<String>(
                tooltip: '队列操作',
                icon: Icon(Icons.more_horiz, size: 18, color: t.text2),
                itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
                  PopupMenuItem<String>(
                    value: 'clearDone',
                    enabled: summary.completed + summary.failed > 0,
                    child: const Text('清空已结束'),
                  ),
                  PopupMenuItem<String>(
                    value: 'clearAll',
                    enabled: !(jobsValue.value?.isEmpty ?? true),
                    child: const Text('清空队列（逐条记墓碑）'),
                  ),
                ],
                onSelected: (String value) {
                  if (value == 'clearDone') {
                    unawaited(runGuarded(
                      context,
                      action: () => ref.read(queuePortProvider).clearCompleted(),
                      success: '已清空已完成任务',
                    ));
                  } else {
                    unawaited(_confirmClearAll(context, ref));
                  }
                },
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        if (torrentsFailed) ...<Widget>[
          Padding(
            padding: EdgeInsets.fromLTRB(t.spacing, 0, t.spacing, 8),
            child: DsBanner(
              kind: DsBannerKind.error,
              text: '读不到引擎的实时进度：'
                  '${describeFailure(torrentsError).message}\n'
                  '下面每行的进度与速度会停在最后一次成功的时刻。',
              action: NeoButton(
                label: '重试',
                icon: Icons.refresh,
                kind: NeoButtonKind.primary,
                onPressed: () => ref.invalidate(engineTorrentsProvider),
              ),
            ),
          ),
        ],
        Expanded(
          child: DsAsync<List<QueueJobView>>(
            value: jobsValue,
            loadingLabel: '正在从队列管理器读取任务…',
            onRetry: () => ref.invalidate(queueJobsProvider),
            isEmpty: (List<QueueJobView> jobs) => jobs.isEmpty,
            empty: DsEmpty(
              icon: Icons.download_done,
              title: '队列是空的',
              message: '到「搜索」页点「下载」，或让订阅规则命中后自动入队。',
              action: NeoButton(
                label: '去搜索',
                icon: Icons.search,
                kind: NeoButtonKind.primary,
                onPressed: () => ref.read(navProvider.notifier).select(ShellTab.search),
              ),
            ),
            builder: (BuildContext context, List<QueueJobView> jobs) {
              final QueueSortOrder order = ref.watch(queueSortProvider);
              final List<QueueJobView> sorted = sortQueueJobs(jobs, order);
              return ReorderableListView.builder(
                padding: EdgeInsets.fromLTRB(t.spacing, 0, t.spacing, t.spacing),
                buildDefaultDragHandles: false,
                itemCount: sorted.length,
                // 只有「优先级」这一种排序允许拖拽：拖拽落点写的就是优先级，
                // 别的排序下拖了也会被立刻排回去（看着像"拖不动"）。
                onReorderItem: order == QueueSortOrder.priority
                    ? (int oldIndex, int newIndex) =>
                          _onReorder(context, ref, sorted, oldIndex, newIndex)
                    : (int oldIndex, int newIndex) {},
                itemBuilder: (BuildContext context, int index) {
                  final QueueJobView job = sorted[index];
                  // ⚠️ `ReorderableListView` 要求**直接子节点**带 key：逐次淡入那层包在外面，
                  // 所以 key 必须挂在 `DsStaggerFade` 上（挂在返回值里面的行上不算）。
                  return DsStaggerFade(
                    key: ValueKey<String>(job.id),
                    index: index,
                    child: _row(
                      context,
                      ref,
                      job,
                      _torrentOf(torrents, job.engineId),
                      index,
                      canDrag: order == QueueSortOrder.priority,
                    ),
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }

  EngineTorrentView? _torrentOf(List<EngineTorrentView> torrents, int? id) {
    if (id == null) return null;
    for (final EngineTorrentView torrent in torrents) {
      if (torrent.id == id) return torrent;
    }
    return null;
  }

  Widget _row(
    BuildContext context,
    WidgetRef ref,
    QueueJobView job,
    EngineTorrentView? torrent,
    int index, {
    bool canDrag = true,
  }) {
    final QueuePort port = ref.read(queuePortProvider);
    // 失败的任务也要有出路（第四十二轮 UX #7）：core 的 `resumeJob` **本来**就收
    // `JobState.failed`（它会把状态放回 queued，无 engineId 的那种就重新加种），
    // 但界面只在 `paused` 时才渲染那颗按钮 —— 于是失败行成了一个死路：
    // 既没有「继续」、也没有自动重试，用户只能移除再回搜索页重找。
    final bool isFailed = job.state == JobState.failed;
    final bool canResume = job.state == JobState.paused || isFailed;
    return QueueJobRow(
      key: ValueKey<String>(job.id),
      job: job,
      torrent: torrent,
      dragHandle: canDrag && job.state.isActive
          ? ReorderableDragStartListener(
              index: index,
              child: Icon(Icons.drag_indicator, size: 16, color: context.ds.text2),
            )
          : null,
      onPause: job.state == JobState.downloading || job.state == JobState.queued
          ? () => runGuarded(context, action: () => port.pauseJob(job.id), success: '已暂停')
          : null,
      onResume: canResume
          ? () => runGuarded(
                context,
                action: () => port.resumeJob(job.id),
                success: isFailed ? '已重新加入下载：${job.displayTitle}' : '已继续',
              )
          : null,
      resumeLabel: isFailed ? '重试' : '继续',
      onRemove: () => _runRemoval(
        context,
        () => port.removeJob(job.id),
        success: '已从队列移除（订阅不会再自动把它加回来；磁盘上的文件没动，'
            '已经下完的还会留在「已完成」）',
      ),
      onRemoveWithFiles: () => _confirmRemoveWithFiles(context, port, job),
      // 用户 2026-10-10 第 3 轮问答：优先级改成 4 档（最高/高/普通/低），
      // 保留"预取"身份（见 `priorityForLevel`）—— 绝不把预取条目变成可启动。
      onPriorityPick: (int level) => runGuarded(
        context,
        action: () => port.setPriority(job.id, priorityForLevel(level, job.priority)),
        success: '优先级 → ${QueuePriorityLevel.values[level].label}',
      ),
    );
  }

  Future<void> _confirmRemoveWithFiles(
    BuildContext context,
    QueuePort port,
    QueueJobView job,
  ) async {
    final DsTokens t = context.ds;
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('删除任务并删除已下载文件？'),
        content: Text(
          // 第四十二轮 UX #45：不再写 `DELETE /torrents/{id}?deleteFiles=true` 这种
          // 实现细节，改说人话 —— 删的是哪一部、多大、**能不能还原**。
          // 「能不能还原」这一条尤其要说：同项目「已完成」页的删除是**走回收站**的
          // （那里写着"可以还原"），而这条路是引擎直删、不进回收站，用户很容易按
          // 上一页的经验以为还能找回来。
          '${job.displayTitle}\n'
          '${job.item.sizeBytes == null ? '' : '大小约 ${formatBytes(job.item.sizeBytes)}。'}'
          '会把它从队列和引擎里一起删掉，**磁盘上已经下好的文件一并永久删除**'
          '（这条路不进回收站，删了找不回来）。\n'
          '只想删任务、把文件留着：选「移除」。',
          style: TextStyle(color: t.text2, fontSize: DsTypeScale.body, height: 1.5),
        ),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('删除')),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    await _runRemoval(
      context,
      () => port.removeJob(job.id, deleteFiles: true),
      success: '已删除任务与文件（订阅不会再自动把它加回来）',
    );
  }

  /// 跑一个「队列删除」动作。
  ///
  /// 与 [runGuarded] 的区别：这些动作会**回报一句引擎侧的提示**（记录已清掉、但引擎那一步
  /// 没成功）。队列记录已经删了，所以不能再报"已删除"，也不能把提示吞掉 —— 用户得知道
  /// 文件可能还在、或者引擎里本来就已经没有这个任务了（用户 2026-10-11「删不掉」）。
  ///
  /// 第四十二轮 UX #28：有提示时**走警告通道**，不再塞进绿色成功条 ——
  /// 旧实现是 `showSuccess(context, warning ?? success)`，显示的确实是警告原文，
  /// 但用的是成功语义/绿色，一眼扫过去就漏掉了"引擎没删掉"。
  Future<void> _runRemoval(
    BuildContext context,
    Future<String?> Function() action, {
    required String success,
  }) async {
    try {
      final String? warning = await action();
      if (!context.mounted) return;
      if (warning == null) {
        showSuccess(context, success);
        return;
      }
      showWarning(
        context,
        warning,
        hint: '队列记录已经删了；引擎里可能还留着这个任务（到「已完成」页可以再删一次）',
      );
    } catch (error, stackTrace) {
      if (!context.mounted) return;
      showFailure(context, describeFailure(error, stackTrace: stackTrace));
    }
  }

  /// 「清空队列」：删掉全部任务记录，可选连文件一起删。删过的条目会记墓碑，
  /// 订阅自动入队不会再把它们拉回来。
  Future<void> _confirmClearAll(BuildContext context, WidgetRef ref) async {
    final DsTokens t = context.ds;
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('清空整个下载队列？'),
        content: Text(
          // 文案必须和 `QueueManager.clearAll` 的真实行为对齐（第十九轮）：不含文件的清空
          // 只删队列记录，引擎里**已经下完**的那几条会留着 —— 它们就是「已完成」页的数据源。
          '会移除队列里的全部任务记录，并记住「别再自动加回来」。\n'
          '还没下完的会连引擎里的 torrent 一起删掉；已经下完的只从队列拿掉，'
          '引擎记录留着，「已完成」页照旧。\n'
          '磁盘上已经下好的文件不会被删除。',
          style: TextStyle(color: t.text2, fontSize: DsTypeScale.body, height: 1.5),
        ),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('清空')),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    await _runRemoval(
      context,
      () => ref.read(queuePortProvider).clearAll(),
      success: '队列已清空',
    );
  }

  /// 拖拽落点 → 新优先级。
  ///
  /// `onReorderItem` 给的 `newIndex` 已经是「移除被拖项之后」的最终位置，
  /// 所以这里不再做 `newIndex - 1` 修正；优先级取相邻活动任务的中间值。
  Future<void> _onReorder(
    BuildContext context,
    WidgetRef ref,
    List<QueueJobView> sorted,
    int oldIndex,
    int newIndex,
  ) async {
    if (oldIndex < 0 || oldIndex >= sorted.length) return;
    if (newIndex == oldIndex) return;
    final QueueJobView moved = sorted[oldIndex];
    final List<QueueJobView> others = <QueueJobView>[...sorted]..removeAt(oldIndex);
    // 拖拽落点 → 新优先级；**null = 这次拖拽不会改变顺序**（没有可比较的相邻活动任务，
    // 或相邻优先级只差 1、中间值就是自己）。旧实现会写回原值却照样报「优先级 → N」，
    // 用户以为顺序变了 —— 静默假成功。
    final int? next = priorityForReorder(
      others: others,
      at: newIndex,
      current: moved.priority,
    );
    if (next == null) {
      showSuccess(
        context,
        '这次拖拽不会改变顺序：队列里没有别的活动任务可作参照，或相邻优先级只差 1（没有空档可插）',
      );
      return;
    }
    await runGuarded(
      context,
      action: () => ref.read(queuePortProvider).setPriority(moved.id, next),
      success: '优先级 → $next（数字小 = 先下）',
    );
  }
}
