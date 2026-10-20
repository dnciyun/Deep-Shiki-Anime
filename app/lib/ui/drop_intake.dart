/// 把窗口变成拖放目标：拖视频直接播、拖 `.torrent` 先确认再入队。
///
/// 用户 2026-10-20：「加入两个拖入逻辑，拖入视频则播放，拖入种子，则跳转到队列，
/// 并显示要下载的东西与内容参数，然后选择是否下载」。
///
/// 三条实现上的取舍：
/// 1. **用 `desktop_drop`（OLE `IDropTarget`，注册在 Flutter view 上）**，不是
///    `DragAcceptFiles` + `WM_DROPFILES`：后者要登记在能收到消息的那扇窗上，
///    而 Flutter 的 view 盖满客户区、消息进的是 view 的 WndProc，挂在 frame 上
///    基本收不到（拖进窗口没反应比崩溃还难查）。
/// 2. **种子不在本地解析完就下**：解析（`domain/torrent_file.dart`）→ 确认框
///    （可勾选文件）→ 这时才 `enqueueDownload(onlyFiles: …)`，勾掉的文件不会进队列。
/// 3. **确认之后跳到队列页**：用户要看得到"它真的开始下了"（进度/引擎 id 都在那儿）。
library;

import 'dart:async';
import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../app.dart' show dsNavigatorKey;
import '../domain/drop_paths.dart';
import '../domain/error_text.dart' show DsFailure;
import '../domain/format.dart' show formatBytes;
import '../domain/local_media.dart';
import '../domain/models.dart';
import '../domain/torrent_file.dart';
import '../state/local_library.dart' show localLibraryProvider;
import '../state/playback.dart' show playbackProvider;
import '../state/providers.dart';
import '../theme/tokens.dart';
import 'torrent_confirm_dialog.dart';
import 'widgets/feedback.dart';

/// 拖放宿主（包在**整个 App** 外面：弹窗开着时也能接住下一次拖放）。
class DsDropIntake extends ConsumerStatefulWidget {
  const DsDropIntake({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<DsDropIntake> createState() => _DsDropIntakeState();
}

class _DsDropIntakeState extends ConsumerState<DsDropIntake> {
  bool _hovering = false;
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final DsTokens t = context.ds;
    return DropTarget(
      onDragEntered: (_) {
        if (!mounted) return;
        setState(() => _hovering = true);
      },
      onDragExited: (_) {
        if (!mounted) return;
        setState(() => _hovering = false);
      },
      onDragDone: (DropDoneDetails detail) {
        if (!mounted) return;
        setState(() => _hovering = false);
        unawaited(_onDrop(<String>[for (final DropItem item in detail.files) item.path]));
      },
      child: Stack(
        children: <Widget>[
          widget.child,
          if (_hovering)
            Positioned.fill(
              child: IgnorePointer(
                child: Container(
                  decoration: BoxDecoration(
                    color: t.accent.withValues(alpha: 0.10),
                    border: Border.all(color: t.accent, width: 2),
                  ),
                  alignment: Alignment.center,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
                    decoration: BoxDecoration(
                      color: t.surface,
                      borderRadius: BorderRadius.circular(t.radiusCard),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Icon(Icons.file_download_outlined, color: t.accent, size: 28),
                        const SizedBox(height: 8),
                        Text(
                          '松手：视频直接播 / 种子先看内容再决定',
                          style: TextStyle(
                            color: t.text,
                            fontSize: DsTypeScale.body,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _onDrop(List<String> rawPaths) async {
    if (_busy) return;
    final BuildContext? ctx = dsNavigatorKey.currentContext;
    if (ctx == null) return;
    final DroppedPaths paths = partitionDroppedPaths(rawPaths);
    if (paths.isEmpty) return;
    setState(() => _busy = true);
    try {
      if (paths.torrents.isNotEmpty) {
        await _handleTorrent(ctx, paths.torrents.first);
        if (paths.torrents.length > 1 && ctx.mounted) {
          showWarning(
            ctx,
            '一次只处理一个种子',
            hint: '另外 ${paths.torrents.length - 1} 个没有处理（可以先处理完这个再拖）',
          );
        }
      } else if (paths.videos.isNotEmpty) {
        await _playVideo(ctx, paths.videos.first);
        if (paths.videos.length > 1 && ctx.mounted) {
          showWarning(ctx, '一次只播一个视频', hint: '另外 ${paths.videos.length - 1} 个没有播');
        }
      } else if (ctx.mounted) {
        showWarning(
          ctx,
          '拖进来的东西不认识',
          hint: '支持视频文件（${kLocalVideoExtensions.take(6).join(' / ')} …）与 .torrent 种子；'
              '字幕请和视频放同一个文件夹（会自动挂上）',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 种子：读字节 → 解析 → 确认框（可勾选）→ 入队 → 跳到队列。
  Future<void> _handleTorrent(BuildContext ctx, String path) async {
    final String name = p.basename(path);
    TorrentPreview? preview;
    try {
      final File file = File(path);
      final int size = await file.length();
      if (size > kMaxTorrentFileBytes) {
        if (ctx.mounted) showWarning(ctx, '种子文件太大（${formatBytes(size)}），不读了', hint: name);
        return;
      }
      preview = readTorrentPreview(await file.readAsBytes());
    } catch (error) {
      if (ctx.mounted) showWarning(ctx, '读不了这个种子文件', hint: '$name：$error');
      return;
    }
    if (preview == null) {
      if (ctx.mounted) {
        showWarning(ctx, '这个种子解析不了', hint: '可能已损坏，或不是真正的 .torrent（$name）');
      }
      return;
    }
    if (!ctx.mounted) return;
    final TorrentConfirmChoice? choice = await showTorrentConfirmDialog(
      ctx,
      preview: preview,
      sourceName: name,
    );
    if (choice == null || !ctx.mounted) return;
    await _enqueue(ctx, preview, choice);
  }

  Future<void> _enqueue(BuildContext ctx, TorrentPreview preview, TorrentConfirmChoice choice) async {
    final SourceItemView item = torrentPreviewSourceItem(preview);
    try {
      await ref.read(queuePortProvider).enqueueDownload(item, onlyFiles: choice.onlyFiles);
      if (!ctx.mounted) return;
      // 用户要在队列里看到它真的开始下了（用户原话：「跳转到队列」）。
      ref.read(navProvider.notifier).select(ShellTab.queue);
      showSuccess(
        ctx,
        choice.onlyFiles == null
            ? '已加入队列：${preview.name}（全部 ${preview.files.length} 个文件）'
            : '已加入队列：${preview.name}（${choice.onlyFiles!.length}/${preview.files.length} 个文件）',
        seconds: 5,
      );
    } catch (error) {
      if (ctx.mounted) showWarning(ctx, '加入队列失败', hint: '$error');
    }
  }

  /// 视频：直接开播放窗口（与「本地」页点一条同一条链路：续播 + 同名字幕）。
  Future<void> _playVideo(BuildContext ctx, String path) async {
    final String dir = p.dirname(path);
    final List<LocalFileStat> stats = <LocalFileStat>[LocalFileStat(path: path)];
    // 同目录的字幕（只读一层；限量防止把几万文件的目录整个列一遍）。
    try {
      await for (final FileSystemEntity entity in Directory(dir).list(followLinks: false)) {
        if (stats.length > 500) break;
        if (entity is File && isLocalSubtitlePath(entity.path)) {
          stats.add(LocalFileStat(path: entity.path));
        }
      }
    } catch (_) {
      // 目录读不了就只播视频（不能因为配不到字幕就不播）。
    }
    final List<LocalVideo> videos = localVideosFrom(folder: dir, files: stats);
    if (videos.isEmpty) return;
    final LocalVideo current = videos.first;
    final int? resume = ref.read(localLibraryProvider).resumeMsOf(current.path);
    await ref.read(playbackProvider.notifier).playLocal(
      showTitle: p.basename(dir),
      videos: <LocalVideo>[current],
      current: current,
      startPositionMs: resume,
    );
    if (!ctx.mounted) return;
    final DsFailure? failure = ref.read(playbackProvider).failure;
    if (failure != null) showFailure(ctx, failure);
  }
}
