/// 「本地」页（2026-10-20，用户：「加入本地文件功能，可选择文件夹并加载内的视频」）。
///
/// 这一页只管三件事：
/// 1. **文件夹清单**：添加（系统目录选择器）/ 移除（只从列表移除，磁盘一个文件都不动）
///    / 每个文件夹各扫各的（某一行的盘掉线不影响别的行）；
/// 2. **视频清单**：按目录分段（番名 / 第 N 季 各成一段），段内按集号排；
/// 3. **播放**：点一行就交给播放窗口（同目录的其它集一起带过去 ⇒ 有上一集/下一集），
///    进度记在 `local.progress`（行上显示"看到 12:34"）。
///
/// 与「已完成」的区别：那一页的数据源是**引擎下完的种子**，这一页是自己盘上的文件
///（不在引擎里，没有 infoHash / 串流 URL）。两页相邻，但**不共用一份数据**。
///
/// 视觉：页头用本页身份色（`hueOfTab(ShellTab.local)`，青绿），行内只有"进度"染色，
/// 大小 / 时间这些事实数据保持中性（同「观看记录」页的口径）。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/format.dart' show formatBytes, formatDuration;
import '../domain/local_media.dart';
import '../domain/error_text.dart' show DsFailure;
import '../domain/reveal_in_explorer.dart' show revealTargetFor;
import '../state/local_library.dart';
import '../state/playback.dart' show playbackProvider;
import '../state/providers.dart';
import '../theme/tokens.dart';
import 'widgets/ds_cards.dart';
import 'widgets/ds_stagger.dart';
import 'widgets/feedback.dart';
import 'widgets/hues.dart';
import 'widgets/neo.dart';
import 'widgets/state_views.dart';

/// 「添加文件夹」按钮（测试锚点）。
const ValueKey<String> dsLocalAddFolderKey = ValueKey<String>('ds-local-add-folder');

/// 「刷新」按钮（测试锚点）。
const ValueKey<String> dsLocalRefreshKey = ValueKey<String>('ds-local-refresh');

/// 文件夹那一行的 key（测试按路径定位，别按文字 —— 目录名可能重复）。
ValueKey<String> dsLocalFolderRowKey(String folder) => ValueKey<String>('ds-local-folder-$folder');

/// 视频那一行的 key（同上）。
ValueKey<String> dsLocalVideoRowKey(String path) => ValueKey<String>('ds-local-video-$path');

/// 「手动输入路径」对话框里那个输入框的 key（选择器不可用时的兜底路）。
const ValueKey<String> dsLocalPathFieldKey = ValueKey<String>('ds-local-path-field');

class LocalPage extends ConsumerStatefulWidget {
  const LocalPage({super.key});

  @override
  ConsumerState<LocalPage> createState() => _LocalPageState();
}

class _LocalPageState extends ConsumerState<LocalPage> {
  bool _adding = false;

  @override
  void initState() {
    super.initState();
    // 首帧之后再动 provider（build 期改状态会撞 Riverpod 断言）。
    //
    // 第一次进这一页自动扫一遍（问答第 5 题定稿），之后靠刷新按钮 ——
    // 不自动反复扫：用户的媒体盘可能是机械盘/网盘，每切一次页面扫一遍就是一次卡顿。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(ref.read(localLibraryProvider.notifier).ensureLoaded());
    });
  }

  Future<void> _addFolder() async {
    if (_adding) return;
    setState(() => _adding = true);
    try {
      final String? added = await ref.read(localLibraryProvider.notifier).addFolder();
      if (!mounted) return;
      if (added != null) _reportAdded(added);
    } catch (error) {
      if (!mounted) return;
      // 系统目录选择器没打开（插件没装好 / RDP 会话）：**不要**把用户堵在一条
      // 死路上 —— 退回"手动输入路径"。用户 2026-10-20 报的「系统目录选择器未接通」
      // 就是这条路（根因是 provider 声明重复，见 `provider_identity_test.dart`），
      // 但即便选择器真坏了，也不该让「本地」页完全用不了。
      final String? typed = await _askPathByTyping(reason: '$error');
      if (typed == null || !mounted) return;
      final String? done = await ref.read(localLibraryProvider.notifier).addFolderPath(typed);
      if (!mounted) return;
      if (done == null) {
        showWarning(context, ref.read(localLibraryProvider).error ?? '没加上：$typed');
      } else {
        _reportAdded(done);
      }
    } finally {
      if (mounted) setState(() => _adding = false);
    }
  }

  /// 加成功之后的反馈（重复添加那一路 `addFolder` 会返回 null + 写 error，走不到这里）。
  void _reportAdded(String added) {
    final LocalLibraryState after = ref.read(localLibraryProvider);
    final String? error = after.error;
    if (error != null) {
      showWarning(context, error);
      return;
    }
    showSuccess(context, '已添加文件夹：$added（扫到 ${after.videoCount} 个视频）', seconds: 4);
  }

  /// 手动输入一个文件夹路径（选择器不可用时的兜底）。
  ///
  /// ⚠️ 输入框的 `TextEditingController` 由对话框**自己**持有（见 [_PathInputDialog]）：
  /// 在这里 try/finally 里 dispose 会撞上"对话框退场动画还在重建 TextField"，
  /// 抛 `A TextEditingController was used after being disposed`（实测踩过）。
  Future<String?> _askPathByTyping({required String reason}) async {
    final String? typed = await showDialog<String>(
      context: context,
      builder: (BuildContext context) => _PathInputDialog(reason: reason),
    );
    final String clean = (typed ?? '').trim();
    return clean.isEmpty ? null : clean;
  }

  Future<void> _refresh() async {
    final LocalLibraryController controller = ref.read(localLibraryProvider.notifier);
    try {
      await controller.refresh();
      if (!mounted) return;
      final LocalLibraryState after = ref.read(localLibraryProvider);
      final int failed = after.failedFolders;
      if (failed > 0) {
        showWarning(context, '有 $failed 个文件夹没扫成功', hint: '看每行末尾的说明（盘掉线 / 没权限）');
      }
    } catch (error) {
      if (mounted) showWarning(context, '刷新失败', hint: '$error');
    }
  }

  /// 移除一个文件夹（**只从列表移除**，不删任何文件 —— 所以文案必须说清楚）。
  Future<void> _removeFolder(String folder) async {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('不再显示这个文件夹？'),
        content: Text('会把它从「本地」页移除，并忘掉这个文件夹里的播放进度。\n磁盘上的文件一个都不动。\n\n$folder'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('移除'),
          ),
        ],
      ),
    );
    if (!mounted || ok != true) return;
    await ref.read(localLibraryProvider.notifier).removeFolder(folder);
    if (mounted) showSuccess(context, '已从列表移除：$folder');
  }

  Future<void> _play(LocalVideo video) async {
    await ref.read(localLibraryProvider.notifier).play(video);
    if (!mounted) return;
    final DsFailure? failure = ref.read(playbackProvider).failure;
    if (failure != null) showFailure(context, failure);
  }

  Future<void> _reveal(String path) async {
    if (revealTargetFor(path) == null) {
      showWarning(context, '这个路径打不开（不是绝对路径或已经不存在）', hint: path);
      return;
    }
    try {
      await ref.read(revealInExplorerProvider)(path);
    } catch (error) {
      if (mounted) showWarning(context, '打开所在文件夹失败', hint: '$error');
    }
  }

  @override
  Widget build(BuildContext context) {
    final DsTokens t = context.ds;
    final DsHue pageHue = hueOfTab(ShellTab.local);
    final LocalLibraryState state = ref.watch(localLibraryProvider);

    final List<LocalFolderGroup> groups = state.groups;
    final String summary = <String>[
      '${state.folders.length} 个文件夹',
      '${state.videoCount} 个视频',
      if (state.videoCount > 0) formatBytes(state.totalBytes),
    ].join(' · ');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: EdgeInsets.fromLTRB(t.spacing, t.spacing, t.spacing, 10),
          child: Row(
            children: <Widget>[
              // 页头 = 本页身份色（同仓库其它页的 3px 竖条 + hueInk 统计文字）。
              Container(
                width: 3,
                height: 14,
                decoration: BoxDecoration(
                  color: t.hueFill(pageHue),
                  borderRadius: BorderRadius.circular(t.radiusPill),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                summary,
                style: TextStyle(color: t.hueInk(pageHue), fontSize: DsTypeScale.secondary),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  state.scanning
                      ? '正在扫描…'
                      : <String>[
                          if (state.failedFolders > 0) '${state.failedFolders} 个文件夹读不了',
                          if (state.truncated) '文件太多，只扫了前 $kLocalScanMaxFiles 个',
                          if (state.failedFolders == 0 && !state.truncated)
                            '递归扫描子文件夹 · 只读不写',
                        ].join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: t.text3, fontSize: DsTypeScale.caption),
                ),
              ),
              NeoIconButton(
                key: dsLocalRefreshKey,
                icon: Icons.refresh,
                tooltip: state.scanning ? '正在扫描…' : '重新扫描所有文件夹',
                onPressed: state.scanning ? null : _refresh,
              ),
              const SizedBox(width: 8),
              NeoButton(
                key: dsLocalAddFolderKey,
                label: '添加文件夹',
                icon: Icons.create_new_folder_outlined,
                kind: NeoButtonKind.primary,
                compact: true,
                hue: pageHue,
                busy: _adding,
                onPressed: _adding ? null : _addFolder,
              ),
            ],
          ),
        ),
        if (state.error != null)
          Padding(
            padding: EdgeInsets.fromLTRB(t.spacing, 0, t.spacing, 8),
            child: NeoBanner(
              text: state.error!,
              kind: NeoBannerKind.warning,
            ),
          ),
        Expanded(
          child: state.folders.isEmpty
              ? _emptyNoFolder(pageHue)
              : state.videoCount == 0 && !state.scanning
              ? _emptyNoVideo(pageHue)
              : CustomScrollView(
                  slivers: <Widget>[
                    ..._folderSlivers(t, state),
                    for (int i = 0; i < groups.length; i++)
                      ..._groupSlivers(t, pageHue, state, groups[i], i),
                    const SliverToBoxAdapter(child: SizedBox(height: 16)),
                  ],
                ),
        ),
      ],
    );
  }

  Widget _emptyNoFolder(DsHue hue) => DsEmpty(
    icon: Icons.folder_open,
    hue: hue,
    title: '还没有添加文件夹',
    message: '选一个放番剧的文件夹（比如 F:\\Anime），它会递归扫出里面所有的视频文件：'
        '按目录分段、按集号排序、点一条就能播。\n'
        '只读不写 —— 不会改名、不会移动、不会删任何文件。',
    action: NeoButton(
      label: '选择文件夹',
      icon: Icons.create_new_folder_outlined,
      kind: NeoButtonKind.primary,
      hue: hue,
      busy: _adding,
      onPressed: _adding ? null : _addFolder,
    ),
  );

  Widget _emptyNoVideo(DsHue hue) => DsEmpty(
    icon: Icons.videocam_off_outlined,
    hue: hue,
    title: '这些文件夹里没找到视频',
    message: '认得的格式：${kLocalVideoExtensions.join(' / ')}。\n'
        '扫的是子文件夹里的全部文件，所以也可能是这一层还没有片子；'
        '换一个更具体的目录（比如某一部番的那一层）再试。',
    action: NeoButton(
      label: '换一个文件夹',
      icon: Icons.create_new_folder_outlined,
      kind: NeoButtonKind.primary,
      hue: hue,
      onPressed: _adding ? null : _addFolder,
    ),
  );

  /// 文件夹那一块：每个文件夹一行（路径 / 视频数 / 失败原因 / 移除）。
  List<Widget> _folderSlivers(DsTokens t, LocalLibraryState state) => <Widget>[
    SliverToBoxAdapter(
      child: Padding(
        padding: EdgeInsets.fromLTRB(t.spacing, 4, t.spacing, 8),
        child: NeoSectionHeader(
          title: '文件夹',
          subtitle: '${state.folders.length} 个',
          hue: hueOfTab(ShellTab.local),
          padding: EdgeInsets.zero,
        ),
      ),
    ),
    SliverList(
      delegate: SliverChildBuilderDelegate(
        (BuildContext context, int index) {
          final String folder = state.folders[index];
          final LocalScanResult result = state.results[folder] ?? LocalScanResult(folder: folder);
          return Padding(
            key: dsLocalFolderRowKey(folder),
            padding: EdgeInsets.fromLTRB(t.spacing, 0, t.spacing, 6),
            child: Container(
              padding: const EdgeInsets.fromLTRB(10, 8, 6, 8),
              decoration: t.cardDecoration(radius: t.radiusCard),
              child: Row(
                children: <Widget>[
                  Icon(
                    result.ok ? Icons.folder_outlined : Icons.folder_off_outlined,
                    size: 16,
                    color: result.ok ? t.text2 : t.danger,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          folder,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: t.text,
                            fontSize: DsTypeScale.secondary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          result.ok
                              ? '${result.videos.length} 个视频 · ${formatBytes(result.totalBytes)}'
                              : (result.error ?? '扫描失败'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: result.ok ? t.text3 : t.danger,
                            fontSize: DsTypeScale.caption,
                          ),
                        ),
                      ],
                    ),
                  ),
                  NeoIconButton(
                    icon: Icons.open_in_new,
                    tooltip: '在资源管理器里打开',
                    onPressed: () => _reveal(folder),
                  ),
                  NeoIconButton(
                    icon: Icons.remove_circle_outline,
                    tooltip: '从列表移除（不删文件）',
                    onPressed: () => _removeFolder(folder),
                  ),
                ],
              ),
            ),
          );
        },
        childCount: state.folders.length,
      ),
    ),
  ];

  /// 一段视频（一个目录）：段头 + 逐条。
  List<Widget> _groupSlivers(
    DsTokens t,
    DsHue hue,
    LocalLibraryState state,
    LocalFolderGroup group,
    int groupIndex,
  ) => <Widget>[
    SliverToBoxAdapter(
      child: Padding(
        padding: EdgeInsets.fromLTRB(t.spacing, groupIndex == 0 ? 10 : 18, t.spacing, 6),
        child: NeoSectionHeader(
          title: group.label,
          subtitle: '${group.videos.length} 个视频 · ${formatBytes(group.totalBytes)}',
          hue: hue,
          padding: EdgeInsets.zero,
        ),
      ),
    ),
    SliverList(
      delegate: SliverChildBuilderDelegate(
        (BuildContext context, int index) {
          final LocalVideo video = group.videos[index];
          return DsStaggerFade(
            key: dsLocalVideoRowKey(video.path),
            index: index,
            child: _LocalVideoRow(
              video: video,
              progress: state.progressOf(video.path),
              hue: hue,
              onPlay: () => _play(video),
              onForgetProgress: () =>
                  ref.read(localLibraryProvider.notifier).forgetProgress(video.path),
              onReveal: () => _reveal(video.path),
            ),
          );
        },
        childCount: group.videos.length,
      ),
    ),
  ];
}

/// 一条视频。
class _LocalVideoRow extends StatelessWidget {
  const _LocalVideoRow({
    required this.video,
    required this.progress,
    required this.hue,
    required this.onPlay,
    required this.onForgetProgress,
    required this.onReveal,
  });

  final LocalVideo video;
  final LocalProgress? progress;
  final DsHue hue;
  final VoidCallback onPlay;
  final VoidCallback onForgetProgress;
  final VoidCallback onReveal;

  static String _clock(int ms) {
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
    final LocalProgress? p = progress;
    final int? resumeMs = p?.resumeMs;
    final double ratio = (p != null && p.durationMs > 0)
        ? (p.positionMs / p.durationMs).clamp(0.0, 1.0)
        : 0.0;
    final String progressLine = p == null
        ? '没看过'
        : (resumeMs == null
              ? '没记进度'
              : p.durationMs > 0
              ? '看到 ${_clock(p.positionMs)} / ${_clock(p.durationMs)}'
              : '看到 ${_clock(p.positionMs)}（时长未知）');
    return Container(
      margin: EdgeInsets.fromLTRB(t.spacing, 0, t.spacing, 6),
      padding: const EdgeInsets.fromLTRB(10, 9, 8, 9),
      decoration: t.cardDecoration(radius: t.radiusCard),
      child: Row(
        children: <Widget>[
          // 集号胶囊：认不出集号就退成一个播放图标（不编一个"第 X 集"）。
          video.episode == null
              ? SizedBox(
                  width: 34,
                  child: Icon(Icons.movie_outlined, size: 16, color: t.text3),
                )
              : Padding(
                  padding: const EdgeInsets.only(right: 10),
                  child: DsChip(
                    label: video.episode!.toString().padLeft(2, '0'),
                    hue: hue,
                  ),
                ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  video.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: t.text,
                    fontSize: DsTypeScale.secondary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 3),
                Row(
                  children: <Widget>[
                    Text(
                      formatBytes(video.sizeBytes),
                      style: TextStyle(
                        color: t.text3,
                        fontSize: DsTypeScale.caption,
                        fontFeatures: DsTokens.tabular,
                      ),
                    ),
                    if (video.subtitlePath != null) ...<Widget>[
                      const SizedBox(width: 6),
                      DsChip(label: '字幕', icon: Icons.subtitles_outlined),
                    ],
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        progressLine,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: resumeMs == null ? t.text3 : t.hueInk(hue),
                          fontSize: DsTypeScale.caption,
                          fontFeatures: DsTokens.tabular,
                        ),
                      ),
                    ),
                  ],
                ),
                if (ratio > 0) ...<Widget>[
                  const SizedBox(height: 6),
                  DsProgressLine(value: ratio, hue: hue),
                ],
              ],
            ),
          ),
          if (resumeMs != null)
            NeoIconButton(
              icon: Icons.restart_alt,
              tooltip: '忘掉进度，下次从头播',
              onPressed: onForgetProgress,
            ),
          NeoIconButton(
            icon: Icons.open_in_new,
            tooltip: '在资源管理器里定位这个文件',
            onPressed: onReveal,
          ),
          NeoButton(
            label: resumeMs == null ? '播放' : '继续播放',
            icon: Icons.play_arrow,
            kind: NeoButtonKind.primary,
            compact: true,
            hue: hue,
            tooltip: resumeMs == null
                ? null
                : '从 ${formatDuration(Duration(milliseconds: resumeMs))} 接着播',
            onPressed: onPlay,
          ),
        ],
      ),
    );
  }
}

/// 「手动输入文件夹路径」对话框。
///
/// 为什么单独一个 StatefulWidget：输入框的 controller 必须活得比 `showDialog`
/// 的 Future 长一点点（退场动画还在重建 TextField），放在调用方 try/finally 里
/// dispose 会抛 `A TextEditingController was used after being disposed`（实测踩过）。
class _PathInputDialog extends StatefulWidget {
  const _PathInputDialog({required this.reason});

  /// 为什么退回到手动输入（把选择器的报错原样带上，用户/排障看得懂）。
  final String reason;

  @override
  State<_PathInputDialog> createState() => _PathInputDialogState();
}

class _PathInputDialogState extends State<_PathInputDialog> {
  final TextEditingController _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() => Navigator.of(context).pop(_controller.text.trim());

  @override
  Widget build(BuildContext context) {
    final DsTokens t = context.ds;
    return AlertDialog(
      title: const Text('手动输入文件夹路径'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            '这次没能打开系统目录选择器，可以直接把文件夹路径粘进来。',
            style: TextStyle(fontSize: DsTypeScale.secondary, color: t.text2),
          ),
          const SizedBox(height: 6),
          Text(
            widget.reason,
            style: TextStyle(fontSize: DsTypeScale.caption, color: t.text3),
          ),
          const SizedBox(height: 12),
          TextField(
            key: dsLocalPathFieldKey,
            controller: _controller,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: '文件夹路径',
              hintText: r'例如 F:\Anime',
            ),
            onSubmitted: (_) => _submit(),
          ),
        ],
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _submit, child: const Text('添加')),
      ],
    );
  }
}
