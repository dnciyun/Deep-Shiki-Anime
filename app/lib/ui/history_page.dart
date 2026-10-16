/// 「观看记录」页（用户第二十七轮：「新增观看记录在设置的上面，记录看过的记录，
/// 超 30 天自动移除，可在设置内更改删除时间或不删除，可导出观看记录」）。
///
/// 三件事在这里落地：
/// * **看过的流水**：每看一集一条（番名 / 集数 / 字幕组 / 看过时间 / 看到哪儿）；
/// * **清理**：加载时按 `AppSettings.historyRetentionDays` 丢掉过期的（设置页可改档位，
///   0 = 永不删除）；
/// * **导出 / 手动清理**：导出成 JSON 写进用户选的目录；也能逐条删、整页清空。
///
/// 视觉沿用列表行那一套（凸起面 + listSafe 阴影，无硬边框）；行内的进度条是自绘的
/// 两段色块，不用 Material 的 `LinearProgressIndicator`（规范 §7：不用默认控件）。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/error_text.dart';
import '../domain/format.dart';
import '../domain/models.dart';
import '../domain/watch_history.dart';
import '../state/export_service.dart';
import '../state/playback.dart';
import '../state/providers.dart';
import '../theme/tokens.dart';
import 'widgets/cover.dart';
import 'widgets/ds_cards.dart';
import 'widgets/ds_stagger.dart';
import 'widgets/feedback.dart';
import 'widgets/neo.dart';
import 'widgets/state_views.dart';

class HistoryPage extends ConsumerStatefulWidget {
  const HistoryPage({super.key});

  @override
  ConsumerState<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends ConsumerState<HistoryPage> {
  bool _busy = false;

  /// 定期按保留档位清一次（30 分钟）。
  ///
  /// 为什么页面要自己起这个计时器：`WatchHistoryController.build()` 只在 provider
  /// 重建时清（= 启动、或改保留档位）。这台机器上程序**常驻**（托盘常驻 / 一直开着），
  /// 不清的话"超 30 天自动移除"实际变成"启动时移除"，与设置页/本页的文案不符
  ///（第二十七轮复核抓到）。
  Timer? _pruneTimer;

  @override
  void initState() {
    super.initState();
    // 首帧之后再动 provider（build 期改 provider 状态会撞 Riverpod 断言）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(ref.read(watchHistoryProvider.notifier).pruneNow());
    });
    _pruneTimer = Timer.periodic(
      const Duration(minutes: 30),
      (_) => unawaited(ref.read(watchHistoryProvider.notifier).pruneNow()),
    );
  }

  @override
  void dispose() {
    _pruneTimer?.cancel();
    super.dispose();
  }

  String _retentionLabel(int days) => days <= 0 ? '不自动删除' : '保留 $days 天';

  Future<void> _export() async {
    final List<WatchRecord> records = ref.read(watchHistoryProvider);
    final int days = ref.read(settingsProvider).historyRetentionDays;
    setState(() => _busy = true);
    try {
      await runGuarded(
        context,
        action: () async {
          final String path = await exportWatchHistoryTo(
            ref.read(pickerPortProvider),
            records,
            retentionDays: days,
          );
          if (!mounted) return;
          // 第四十二轮 UX #14：统一走反馈通道（原来是裸 SnackBar）。
          showSuccess(context, '观看记录已导出：$path', seconds: 5);
        },
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _clearAll() async {
    final int count = ref.read(watchHistoryProvider).length;
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('清空观看记录？'),
        content: Text(
          '会删掉全部 $count 条记录（含进度）。'
          '**磁盘上的视频文件一个都不动**。'
          '「已看过」的勾在「正在追」里，不受影响 —— 那份数据是另一份。',
        ),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('清空')),
        ],
      ),
    );
    if (!mounted || ok != true) return;
    // 走统一反馈通道：落盘失败必须说出来（第四十二轮 UX #5/#19）。
    await runGuarded(
      context,
      action: () => ref.read(watchHistoryProvider.notifier).clear(),
      success: '已清空观看记录（$count 条）',
    );
  }

  /// 删掉一条观看记录。
  ///
  /// 单条删除**不给二次确认**（同「删一条搜索历史」的既定口径：低摩擦优先），
  /// 但必须**可撤销 + 有反馈**：旧实现是 `onDelete: () => ...remove(id)` ——
  /// 不 await 不 catch，删失败时连"没删掉"都不说（第四十二轮 UX #5 / #20）。
  Future<void> _deleteOne(WatchRecord record) async {
    try {
      await ref.read(watchHistoryProvider.notifier).remove(record.id);
      if (!mounted) return;
      showUndo(
        context,
        '已删掉「${record.title}」这条记录',
        onUndo: () => ref.read(watchHistoryProvider.notifier).restore(record),
      );
    } catch (error, stackTrace) {
      if (!mounted) return;
      showFailure(context, describeFailure(error, stackTrace: stackTrace));
    }
  }

  /// 「继续播放」：拿记录里的 `infoHash`（引擎重启后 `engineId` 会变）回引擎找那一条。
  Future<void> _play(WatchRecord record) async {
    final List<EngineTorrentView> torrents =
        ref.read(engineTorrentsProvider).value ?? const <EngineTorrentView>[];
    EngineTorrentView? torrent;
    for (final EngineTorrentView t in torrents) {
      if ((record.infoHash ?? '').isNotEmpty && t.infoHash == record.infoHash) {
        torrent = t;
        break;
      }
    }
    if (torrent == null && record.engineId != null) {
      for (final EngineTorrentView t in torrents) {
        if (t.id == record.engineId) {
          torrent = t;
          break;
        }
      }
    }
    final EngineFileView? file = (torrent == null || record.fileIndex == null)
        ? null
        : (record.fileIndex! >= 0 && record.fileIndex! < torrent.files.length
              ? torrent.files[record.fileIndex!]
              : null);
    if (torrent == null || file == null) {
      // 第四十二轮 UX #14：统一走反馈通道（原来是裸 SnackBar，与全仓那套不是一套）。
      // 这不是"操作失败"，是"这条记录指向的东西已经不在了" —— 警告形态最贴切。
      showWarning(
        context,
        '这条记录对应的种子已经不在引擎里了',
        hint: '被移除或换过种子？到「已完成」或「正在追」重新点一集',
      );
      return;
    }
    await ref.read(playbackProvider.notifier).playTorrentFile(
          torrent: torrent,
          file: file,
          showTitle: record.title,
          showTitleEn: record.titleEn,
          coverUrl: record.coverUrl,
          coverReferer: record.coverReferer,
          mikanBangumiId: record.mikanBangumiId,
          // 从上次看到的地方接着播（第四十二轮 UX #2）。null = 这一条没进度、
          // 或已经看完（行里那个按钮对看完的集写的是「重看」）。
          startPositionMs: record.resumePositionMs,
        );
    final DsFailure? failure = ref.read(playbackProvider).failure;
    if (failure != null && mounted) showFailure(context, failure);
    // 真的从上次那儿接上了吗 —— 说一句，别让用户自己盯着进度条猜。
    final int? from = record.resumePositionMs;
    if (from != null && mounted && failure == null) {
      showSuccess(
        context,
        '从 ${formatDuration(Duration(milliseconds: from))} 接着播：${record.title}',
        seconds: 4,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final DsTokens t = context.ds;
    final List<WatchRecord> records = ref.watch(watchHistoryProvider);
    final int days = ref.watch(settingsProvider).historyRetentionDays;
    final bool recordingProgress = ref.watch(settingsProvider).recordWatchProgress;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: EdgeInsets.fromLTRB(t.spacing, t.spacing, t.spacing, 10),
          child: Row(
            children: <Widget>[
              Text(
                '${records.length} 条记录 · ${_retentionLabel(days)}',
                style: TextStyle(color: t.text2, fontSize: DsTypeScale.secondary),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  recordingProgress
                      ? '记进度：打开「设置 → 观看记录 · 播放器」可以关掉'
                      : '只记时间不记进度（设置里关掉了「记录观看进度」）',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: t.text3, fontSize: DsTypeScale.caption),
                ),
              ),
              NeoButton(
                label: '导出观看记录',
                icon: Icons.ios_share,
                compact: true,
                onPressed: (records.isEmpty || _busy) ? null : _export,
              ),
              const SizedBox(width: 8),
              NeoButton(
                label: '清空',
                icon: Icons.delete_sweep_outlined,
                compact: true,
                onPressed: records.isEmpty ? null : _clearAll,
              ),
            ],
          ),
        ),
        Expanded(
          child: records.isEmpty
              // 空态必须带一个"下一步动作"（同仓库其它页都有；第四十二轮 UX #17）。
              ? DsEmpty(
                  icon: Icons.history,
                  title: '还没有观看记录',
                  message:
                      '用播放器看过一集就会记在这里（番名 / 集数 / 字幕组 / 看到哪儿）；'
                      '过期的按设置里的天数自动移除，也可以随时导出成 JSON。',
                  action: NeoButton(
                    label: '去搜索',
                    icon: Icons.search,
                    kind: NeoButtonKind.primary,
                    onPressed: () =>
                        ref.read(navProvider.notifier).select(ShellTab.search),
                  ),
                )
              : ListView.builder(
                  padding: EdgeInsets.fromLTRB(t.spacing, 12, t.spacing, t.spacing),
                  itemCount: records.length,
                  itemBuilder: (BuildContext context, int index) {
                    final WatchRecord record = records[index];
                    return DsStaggerFade(index: index, child: _HistoryRow(
                      key: ValueKey<String>(record.id),
                      record: record,
                      // 关掉「记录观看进度」之后，行里那份进度是**以前**记下的：
                      // 页头写着"只记时间不记进度"，行里却还在报百分比，两边自相矛盾
                      //（第四十二轮 UX #18）。所以把开关传下去，由行内说明它的来历。
                      recordingProgress: recordingProgress,
                      onPlay: () => _play(record),
                      onDelete: () => _deleteOne(record),
                    ));
                  },
                ),
        ),
      ],
    );
  }
}

/// 一条观看记录。
class _HistoryRow extends StatelessWidget {
  const _HistoryRow({
    super.key,
    required this.record,
    required this.recordingProgress,
    required this.onPlay,
    required this.onDelete,
  });

  final WatchRecord record;

  /// 设置里「记录观看进度」现在是开还是关。关掉之后行里那条进度是**历史遗留**，
  /// 要说明来历，不能和页头的「只记时间不记进度」打架（UX #18）。
  final bool recordingProgress;
  final Future<void> Function() onPlay;
  final Future<void> Function() onDelete;

  String _clock(int ms) {
    final int total = ms ~/ 1000;
    String two(int v) => v.toString().padLeft(2, '0');
    final int h = total ~/ 3600;
    final int m = (total % 3600) ~/ 60;
    final int s = total % 60;
    return h > 0 ? '$h:${two(m)}:${two(s)}' : '${two(m)}:${two(s)}';
  }

  @override
  Widget build(BuildContext context) {
    final DsTokens t = context.ds;
    final WatchRecord r = record;
    final String episode = (r.episodeLabel ?? '').trim().isEmpty
        ? (r.episode == null ? '全集' : '第 ${r.episode!.toString().padLeft(2, '0')} 集')
        : r.episodeLabel!;
    final String progressText = r.durationMs > 0
        ? '看到 ${_clock(r.positionMs)} / ${_clock(r.durationMs)}（${(r.progress * 100).round()}%）'
        : (r.positionMs > 0 ? '看到 ${_clock(r.positionMs)}（时长未知）' : '没有进度记录');
    // 关掉「记录观看进度」时，这条进度不会再更新了 —— 明说"这是以前记下的"，
    // 否则页头说"只记时间"、行里却报百分比，用户会以为设置没生效（UX #18）。
    final String progressLine =
        (!recordingProgress && r.positionMs > 0) ? '$progressText（已关掉进度记录，这是以前记下的）' : progressText;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(10),
      decoration: t.cardDecoration(
        radius: t.radiusCard,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 54,
            height: 76,
            child: DsCover(
              url: r.coverUrl,
              referer: r.coverReferer,
              radius: t.radiusBadge,
              // 54×76（= 0.711）固定海报槽 → 不裁（见 kPosterFit）。
              fit: kPosterFit,
            ),
          ),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  r.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: t.text,
                    fontSize: DsTypeScale.body,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Row(
                  children: <Widget>[
                    DsChip(label: episode, icon: Icons.play_circle_outline),
                    if ((r.group ?? '').trim().isNotEmpty) ...<Widget>[
                      const SizedBox(width: 6),
                      Flexible(child: DsChip(label: r.group!, icon: Icons.groups_outlined)),
                    ],
                    const SizedBox(width: 6),
                    Text(
                      formatRelative(r.watchedAt),
                      style: TextStyle(
                        color: t.text3,
                        fontSize: DsTypeScale.caption,
                        fontFeatures: DsTokens.tabular,
                      ),
                    ),
                    if (r.finished) ...<Widget>[
                      const SizedBox(width: 6),
                      Text(
                        '已看完',
                        style: TextStyle(color: t.success, fontSize: DsTypeScale.caption),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 7),
                _ProgressBar(progress: r.progress, active: r.durationMs > 0),
                const SizedBox(height: 5),
                Text(
                  progressLine,
                  style: TextStyle(
                    color: t.text3,
                    fontSize: DsTypeScale.caption,
                    fontFeatures: DsTokens.tabular,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          // 文案必须与**真的会做什么**一致（第四十二轮 UX #2）：有进度 = 「继续播放」
          // （会从上次那儿接上），已看完 = 「重看」（从 0 开始，行里也写着「已看完」）。
          NeoButton(
            label: r.resumePositionMs == null ? (r.finished ? '重看' : '播放') : '继续播放',
            icon: Icons.play_arrow,
            kind: NeoButtonKind.primary,
            compact: true,
            tooltip: r.resumePositionMs == null
                ? null
                : '从 ${formatDuration(Duration(milliseconds: r.resumePositionMs!))} 接着播',
            onPressed: () => onPlay(),
          ),
          const SizedBox(width: 6),
          NeoIconButton(
            icon: Icons.delete_outline,
            tooltip: '从观看记录里删掉这一条',
            onPressed: () => onDelete(),
          ),
        ],
      ),
    );
  }
}

/// 自绘进度条：凹槽底 + 强调色填充（不用 Material 的 `LinearProgressIndicator`）。
class _ProgressBar extends StatelessWidget {
  const _ProgressBar({required this.progress, required this.active});

  final double progress;

  /// false = 时长未知（画一条纯凹槽，不假装进度是 0%）。
  final bool active;

  @override
  Widget build(BuildContext context) {
    final DsTokens t = context.ds;
    return ClipRRect(
      borderRadius: BorderRadius.circular(t.radiusPill),
      child: Container(
        height: 4,
        color: t.sunken,
        child: active
            ? FractionallySizedBox(
                alignment: Alignment.centerLeft,
                widthFactor: progress.clamp(0.0, 1.0),
                child: ColoredBox(color: t.accent),
              )
            : null,
      ),
    );
  }
}
