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
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
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
          messenger.showSnackBar(SnackBar(content: Text('观看记录已导出：$path')));
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
          '「已看过」的勾在「正在追」里，不受影响 —— 那份数据是另一份。',
        ),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('清空')),
        ],
      ),
    );
    if (ok != true) return;
    await ref.read(watchHistoryProvider.notifier).clear();
  }

  /// 「继续播放」：拿记录里的 `infoHash`（引擎重启后 `engineId` 会变）回引擎找那一条。
  Future<void> _play(WatchRecord record) async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
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
      messenger.showSnackBar(
        const SnackBar(
          content: Text('引擎里已经没有这一条了（被移除或换过种子）——到「已完成」或「正在追」重新点一集'),
        ),
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
        );
    final DsFailure? failure = ref.read(playbackProvider).failure;
    if (failure != null && mounted) showFailure(context, failure);
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
              ? const DsEmpty(
                  icon: Icons.history,
                  title: '还没有观看记录',
                  message:
                      '用播放器看过一集就会记在这里（番名 / 集数 / 字幕组 / 看到哪儿）；'
                      '过期的按设置里的天数自动移除，也可以随时导出成 JSON。',
                )
              : ListView.builder(
                  padding: EdgeInsets.fromLTRB(t.spacing, 12, t.spacing, t.spacing),
                  itemCount: records.length,
                  itemBuilder: (BuildContext context, int index) {
                    final WatchRecord record = records[index];
                    return DsStaggerFade(index: index, child: _HistoryRow(
                      key: ValueKey<String>(record.id),
                      record: record,
                      onPlay: () => _play(record),
                      onDelete: () =>
                          ref.read(watchHistoryProvider.notifier).remove(record.id),
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
  const _HistoryRow({super.key, required this.record, required this.onPlay, required this.onDelete});

  final WatchRecord record;
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
                  progressText,
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
          NeoButton(
            label: '继续播放',
            icon: Icons.play_arrow,
            kind: NeoButtonKind.primary,
            compact: true,
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
