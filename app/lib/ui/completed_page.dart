/// 已完成页（2026-10-12 第十四轮）。
///
/// 用户原话：
/// > 「添加已完成页面，下载好的会在里面，按照名字分类，封面调用bangumi」
/// > （追问后补充）「已完成的可跳转文件夹位置，和直接播放还有删除等」
///
/// 三件事定死了这个页面：
/// 1. **数据源与「已缓存」同一份**（问答选定：引擎里 `finished` 的 torrent，不扫盘不猜）；
///    区别只在摆法 —— 这里按番名归成一张张封面卡（`domain/completed.dart`）；
/// 2. **封面走 bangumi**：番名先清洗（`title_clean.dart` 的 `animeSearchName`：
///    去掉方括号里的东西 + 集号），再搜，**默认用第一个结果**；点封面可以换
///    （候选自选 / 自己输关键字重搜）。手选**不落盘**（问答选定：每次启动重新匹配）；
/// 3. **每一条都能直接播放 / 打开所在文件夹 / 移除任务 / 删文件**，而「删文件」是
///    **进 Windows 回收站**（可恢复），不是引擎那条永久删除（见 `domain/recycle_bin.dart`）。
///
/// ⚠️ 引擎给的 `EngineFileView.path` 是**相对 outputFolder 的文件名**，不是绝对路径
/// （真机 dump 见第十二轮），所以路径一律经 `engineFileAbsolutePath()` 拼，
/// 「打开文件夹」与「删文件」都用它 —— 直接拿 `path` 会指到工作目录下的同名文件。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/bangumi.dart';
import '../domain/completed.dart';
import '../domain/download_dir.dart' show effectiveDownloadDir;
import '../domain/error_text.dart';
import '../domain/format.dart';
import '../domain/models.dart';
import '../domain/ports.dart' show QueuePort;
import '../domain/recycle_bin.dart' show RecycleToTrash;
import '../domain/reveal_in_explorer.dart' show revealTargetFor;
import '../state/playback.dart';
import '../state/providers.dart';
import '../theme/tokens.dart';
import 'widgets/cover.dart';
import 'widgets/ds_cards.dart';
import 'widgets/ds_stagger.dart';
import 'widgets/feedback.dart';
import 'widgets/neo.dart';
import 'widgets/state_views.dart';

/// 卡片封面的尺寸（2:3 竖版；与「正在追」卡的 112×157 同一语言，这里小一号）。
const double kCompletedCoverWidth = 96;
const double kCompletedCoverHeight = kCompletedCoverWidth / kPosterAspect;

/// 点封面换封面那个热区的 key（测试锚点：按文字找会撞上卡片里别的「封面」字样）。
///
/// 多张卡共用同一个 key 是**故意**的：它们不是兄弟节点（各在自己那张卡里），
/// 测试要的只是"点某一张卡的封面"（用 `.first`）。
const ValueKey<String> dsCompletedCoverKey = ValueKey<String>('ds-completed-cover');

class CompletedPage extends ConsumerStatefulWidget {
  const CompletedPage({super.key});

  @override
  ConsumerState<CompletedPage> createState() => _CompletedPageState();
}

class _CompletedPageState extends ConsumerState<CompletedPage> {
  /// 展开着的卡（归组键）—— **列表**摆法用。
  final Set<String> _expanded = <String>{};

  /// 当前摆法（第二十四轮）：默认封面卡网格，可切回列表。
  CompletedView _view = CompletedView.grid;

  /// 网格里**点开**的那一部番的归组键（null = 还在网格上）。
  ///
  /// 点开之后就是"跟文件夹一样一集一集排着"：一集一行 + 四个动作，顶上一条返回。
  String? _opened;

  /// 已经安排过封面查询的归组键（避免在 build 里对同一张卡重复安排）。
  final Set<String> _coverAsked = <String>{};

  /// 一屏最多同时问几张卡的封面。
  ///
  /// 为什么要有上限：bangumi 客户端自带 1.1 秒最小请求间隔（见 `BangumiClient`），
  /// 一屏 50 张卡一起问会让最后一张等 55 秒才出封面。先问前面这些，往下滚会自然续上。
  static const int maxCoverLookupsPerPass = 12;

  @override
  Widget build(BuildContext context) {
    final DsTokens t = context.ds;
    final AsyncValue<List<EngineTorrentView>> torrentsValue = ref.watch(engineTorrentsProvider);
    final List<CompletedGroup> groups = ref.watch(completedGroupsProvider);
    final CompletedCoverState covers = ref.watch(completedCoverProvider);
    final AppSettings settings = ref.watch(settingsProvider);

    _scheduleCoverLookups(groups);

    final int files = groups.fold<int>(0, (int sum, CompletedGroup g) => sum + g.count);
    final int bytes = groups.fold<int>(0, (int sum, CompletedGroup g) => sum + g.bytes);

    // 点开的那部番可能已经被删掉/移除了 → 自己退回网格（否则会停在一个空视图上）。
    CompletedGroup? opened;
    for (final CompletedGroup g in groups) {
      if (g.key == _opened) {
        opened = g;
        break;
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: EdgeInsets.fromLTRB(t.spacing, t.spacing, t.spacing, 0),
          child: Row(
            children: <Widget>[
              DsChip(label: '已完成 ${groups.length} 部', tone: t.success),
              const SizedBox(width: 6),
              DsChip(label: '$files 个文件'),
              const SizedBox(width: 6),
              DsChip(label: '占用 ${formatBytes(bytes)}'),
              const Spacer(),
              // 摆法开关（第二十四轮）：默认「封面卡」，可切回以前那种一行一张的列表。
              // 点开的集列表只在网格摆法里有意义 → 切回列表时顺手把 _opened 清掉。
              NeoSegmented<CompletedView>(
                options: CompletedView.values,
                value: _view,
                labelOf: (CompletedView v) => v.label,
                onChanged: (CompletedView v) => setState(() {
                  _view = v;
                  if (v == CompletedView.list) _opened = null;
                }),
              ),
              const SizedBox(width: 10),
              // ⚠️ 第二十五轮（用户：「去除文字一部一番一张卡这一行」）：原来这里跟着摆法
              // 写了一句长提示（「一部番一张卡 · 点卡片打开…」/「按番名分类 · 点「展开」…」），
              // 整行删掉 —— 摆法开关本身已经说明有两种摆法，这一行只是噪音。
            ],
          ),
        ),
        const SizedBox(height: 10),
        Expanded(
          child: DsAsync<List<EngineTorrentView>>(
            value: torrentsValue,
            loadingLabel: '正在从引擎读取已完成列表…',
            onRetry: () => ref.invalidate(engineTorrentsProvider),
            builder: (BuildContext context, List<EngineTorrentView> all) {
              if (groups.isEmpty) {
                return DsEmpty(
                  icon: Icons.task_alt,
                  title: all.isEmpty ? '引擎里还没有任务' : '还没有下完的剧集',
                  message: '下完的剧集按番名归成一张卡：点卡片打开（一集一行），'
                      '在里面可以播放、打开所在文件夹；在卡片上**右键**可以换封面、'
                      '把任务从列表里移除，或把文件删进回收站。',
                  action: NeoButton(
                    label: '去搜索',
                    icon: Icons.search,
                    kind: NeoButtonKind.primary,
                    onPressed: () => ref.read(navProvider.notifier).select(ShellTab.search),
                  ),
                );
              }
              if (opened != null) {
                return _openedView(opened, covers, settings);
              }
              return _view == CompletedView.grid
                  ? _grid(groups, covers, settings)
                  : _list(groups, covers, settings);
            },
          ),
        ),
      ],
    );
  }

  /// 封面卡网格（默认摆法）：一部番一张卡，点卡片 = 打开它的集列表。
  Widget _grid(
    List<CompletedGroup> groups,
    CompletedCoverState covers,
    AppSettings settings,
  ) {
    final DsTokens t = context.ds;
    return GridView.builder(
      padding: EdgeInsets.fromLTRB(t.spacing, 0, t.spacing, t.spacing),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 200,
        // 2:3 封面 + 两行标题 + 一行集数/体积（见 `_CompletedGridCard` 的排布）。
        mainAxisExtent: 360,
        mainAxisSpacing: 12,
        crossAxisSpacing: 12,
      ),
      itemCount: groups.length,
      itemBuilder: (BuildContext context, int index) {
        final CompletedGroup group = groups[index];
        return DsStaggerFade(index: index, child: _CompletedGridCard(
          key: ValueKey<String>('grid-${group.key}'),
          group: group,
          cover: covers.subjectOf(group.key),
          coverLoading: covers.isLoading(group.key),
          coverError: covers.errorOf(group.key),
          coverPicked: covers.isPicked(group.key),
          onOpen: () => setState(() => _opened = group.key),
          // 右键（第二十五轮）：换封面 / 从列表移除 / 删文件（回收站）。
          onContextMenu: (Offset global) => unawaited(_openCardMenu(group, global)),
        ));
      },
    );
  }

  /// 点开之后：这一部番的集列表，一集一行（像资源管理器的文件夹）。
  Widget _openedView(
    CompletedGroup group,
    CompletedCoverState covers,
    AppSettings settings,
  ) {
    final DsTokens t = context.ds;
    final _CompletedActions actions = _CompletedActions(ref);
    final String? downloadRoot = _downloadRoot(settings);
    final CompletedEpisode first = group.episodes.first;
    final String folder = first.torrent.outputFolder.trim();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: EdgeInsets.fromLTRB(t.spacing, 0, t.spacing, 8),
          child: Row(
            children: <Widget>[
              NeoButton(
                label: '返回',
                icon: Icons.arrow_back,
                compact: true,
                tooltip: '回到封面卡那一屏',
                onPressed: () => setState(() => _opened = null),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  group.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: t.text,
                    fontSize: DsTypeScale.body,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              DsChip(
                label: group.episodeRangeLabel,
                icon: Icons.video_library_outlined,
                tone: t.success,
              ),
              const SizedBox(width: 6),
              DsChip(label: formatBytes(group.bytes), icon: Icons.save_outlined),
              const SizedBox(width: 8),
              NeoButton(
                label: '播放首集',
                icon: Icons.play_arrow,
                kind: NeoButtonKind.primary,
                compact: true,
                onPressed: first.torrent.playableFile == null
                    ? null
                    : () => actions.play(context, first.torrent),
              ),
              const SizedBox(width: 6),
              NeoButton(
                label: '打开文件夹',
                icon: Icons.folder_open,
                compact: true,
                onPressed: () => actions.reveal(context, first.torrent),
              ),
            ],
          ),
        ),
        // 这一屏就是"这一部番的文件夹"：凹槽面板 + 一集一行。
        Expanded(
          child: Padding(
            padding: EdgeInsets.fromLTRB(t.spacing, 0, t.spacing, t.spacing),
            child: DsInset(
              radius: t.radiusCard,
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  // 文件夹标题：路径 + 集数（跟资源管理器一样先告诉你这是哪个文件夹）。
                  Row(
                    children: <Widget>[
                      Icon(Icons.folder_outlined, size: 14, color: t.text3),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          folder.isEmpty ? '（引擎没记下下载目录）' : folder,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: t.text3, fontSize: DsTypeScale.caption),
                        ),
                      ),
                      Text(
                        '${group.count} 集',
                        style: TextStyle(color: t.text3, fontSize: DsTypeScale.caption),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Divider(height: 1, color: t.divider),
                  Expanded(
                    child: ListView.builder(
                      padding: const EdgeInsets.only(top: 2),
                      itemCount: group.episodes.length,
                      itemBuilder: (BuildContext context, int index) {
                        final CompletedEpisode episode = group.episodes[index];
                        return _EpisodeRow(
                          episode: episode,
                          downloadRoot: downloadRoot,
                          onPlay: episode.torrent.playableFile == null
                              ? null
                              : () => actions.play(context, episode.torrent),
                          onReveal: () => actions.reveal(context, episode.torrent),
                          onRemove: () => actions.remove(context, episode.torrent),
                          onDelete: () =>
                              actions.delete(context, episode.torrent, downloadRoot),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// 列表摆法（第二十四轮之前的样子）：一行一张宽卡，点「展开 N 集」看每一集。
  Widget _list(
    List<CompletedGroup> groups,
    CompletedCoverState covers,
    AppSettings settings,
  ) {
    final DsTokens t = context.ds;
    return ListView.builder(
      padding: EdgeInsets.fromLTRB(t.spacing, 0, t.spacing, t.spacing),
      itemCount: groups.length,
      itemBuilder: (BuildContext context, int index) {
        final CompletedGroup group = groups[index];
        return DsStaggerFade(index: index, child: _CompletedCard(
          key: ValueKey<String>(group.key),
          group: group,
          cover: covers.subjectOf(group.key),
          coverLoading: covers.isLoading(group.key),
          coverError: covers.errorOf(group.key),
          coverPicked: covers.isPicked(group.key),
          expanded: _expanded.contains(group.key),
          downloadRoot: _downloadRoot(settings),
          onToggleExpand: () => setState(() {
            if (!_expanded.remove(group.key)) _expanded.add(group.key);
          }),
          // 右键菜单与网格摆法**同一套**（第二十五轮）：换封面 / 移除任务 / 删文件。
          onContextMenu: (Offset global) => unawaited(_openCardMenu(group, global)),
        ));
      },
    );
  }

  /// 生效的下载根（护栏用：**绝不允许**删到它或它的祖先）。
  String? _downloadRoot(AppSettings settings) {
    final String root = effectiveDownloadDir(settings.downloadDir);
    return root.trim().isEmpty ? null : root;
  }

  /// 给还没问过的卡安排封面查询（一屏最多 [maxCoverLookupsPerPass] 张）。
  void _scheduleCoverLookups(List<CompletedGroup> groups) {
    int asked = 0;
    for (final CompletedGroup group in groups) {
      if (asked >= maxCoverLookupsPerPass) break;
      if (_coverAsked.contains(group.key)) continue;
      _coverAsked.add(group.key);
      asked++;
      // 不能在 build 里直接改 provider 状态 → 挪到微任务里。
      unawaited(Future<void>.microtask(
        () => ref.read(completedCoverProvider.notifier).ensure(group.key, group.name),
      ));
    }
  }

  Future<void> _openCoverPicker(CompletedGroup group, CompletedCoverState covers) async {
    await showDialog<void>(
      context: context,
      builder: (BuildContext context) => _CoverPickerDialog(
        groupKey: group.key,
        groupName: group.name,
        initialKeyword: group.name,
        picked: covers.isPicked(group.key),
      ),
    );
  }

  /// 卡片右键菜单（第二十五轮，用户：「点封面不要是换封面，加入右键，可选择删除或更换封面」）。
  ///
  /// 三项（问答选定）：
  /// * **更换封面** —— 打开原来的换封面对话框（点封面不再直接换）；
  /// * **从列表移除** —— 只把任务从引擎/队列拿掉，**文件留着**；
  /// * **删除文件（移进回收站）** —— 沿 `_CompletedActions.delete` 那条护栏（可还原）。
  ///
  /// 菜单锚在**指针位置**（`showMenu` 和全项目其它浮层同一套语言）。
  Future<void> _openCardMenu(CompletedGroup group, Offset globalPosition) async {
    final OverlayState? overlay = Overlay.maybeOf(context);
    final RenderBox? overlayBox = overlay?.context.findRenderObject() as RenderBox?;
    if (overlayBox == null) return;
    final DsTokens t = context.ds;
    final Offset at = overlayBox.globalToLocal(globalPosition);
    final _CardMenuAction? action = await showMenu<_CardMenuAction>(
      context: context,
      position: RelativeRect.fromLTRB(
        at.dx,
        at.dy,
        overlayBox.size.width - at.dx,
        overlayBox.size.height - at.dy,
      ),
      color: t.raised,
      elevation: t.overlayElevation,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(t.radiusControl),
      ),
      items: const <PopupMenuEntry<_CardMenuAction>>[
        PopupMenuItem<_CardMenuAction>(
          value: _CardMenuAction.changeCover,
          child: Text('更换封面'),
        ),
        PopupMenuItem<_CardMenuAction>(
          value: _CardMenuAction.remove,
          child: Text('从列表移除（文件留着）'),
        ),
        PopupMenuItem<_CardMenuAction>(
          value: _CardMenuAction.delete,
          child: Text('删除文件（移进回收站）'),
        ),
      ],
    );
    if (!mounted || action == null) return;
    final _CompletedActions actions = _CompletedActions(ref);
    final CompletedEpisode first = group.episodes.first;
    switch (action) {
      case _CardMenuAction.changeCover:
        await _openCoverPicker(group, ref.read(completedCoverProvider));
      case _CardMenuAction.remove:
        await actions.remove(context, first.torrent);
      case _CardMenuAction.delete:
        await actions.delete(
          context,
          first.torrent,
          _downloadRoot(ref.read(settingsProvider)),
        );
    }
  }
}

/// 卡片右键菜单的三项（顺序 = 菜单顺序）。
enum _CardMenuAction { changeCover, remove, delete }

/// 网格摆法下的一张卡：2:3 封面 + 番名 + 集数/体积（点整张卡 = 打开这一部番）。
///
/// 与 [_CompletedCard]（列表摆法）的区别只在**摆法**：封面尺寸跟着格子走、
/// 每张卡只占一格；四个动作不摆在这里 —— 它们属于"打开之后的每一集"
///（用户 2026-10-12 第二十四轮：「一部番一张卡，点开跟文件夹一样一集一集排着」）。
///
/// ⚠️ 第二十五轮（用户）：
/// * 「点封面不要是换封面」→ 封面不再是热点，点它和点卡片一样 = 打开这一部番；
/// * 「加入右键」→ 整张卡右键弹 [_CardMenuAction] 三项菜单；
/// * 「鼠标放上去不要显示文字」→ 封面那层 Tooltip 删掉了（悬停不再冒字）。
class _CompletedGridCard extends StatelessWidget {
  const _CompletedGridCard({
    super.key,
    required this.group,
    required this.cover,
    required this.coverLoading,
    required this.coverError,
    required this.coverPicked,
    required this.onOpen,
    required this.onContextMenu,
  });

  final CompletedGroup group;
  final BangumiSubject? cover;
  final bool coverLoading;
  final String? coverError;
  final bool coverPicked;
  final VoidCallback onOpen;

  /// 右键（参数是指针的全局位置，菜单锚在它上面）。
  final void Function(Offset global) onContextMenu;

  @override
  Widget build(BuildContext context) {
    final DsTokens t = context.ds;
    return NeoSurface(
      radius: t.radiusCard,
      padding: const EdgeInsets.all(8),
      onTap: onOpen,
      onSecondaryTapDown: (TapDownDetails d) => onContextMenu(d.globalPosition),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          // 封面铺满剩下的空间（DcCover 按 cover 裁切）。它**不再**是独立热点：
          // 点封面 = 卡片自己的 onTap = 打开这一部番。
          Expanded(
            child: _CoverBox(
              cover: cover,
              loading: coverLoading,
              error: coverError,
              picked: coverPicked,
              width: null,
              height: null,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            group.name,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: t.text,
              fontSize: DsTypeScale.secondary,
              fontWeight: FontWeight.w600,
              height: 1.25,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            '${group.count} 集 · ${formatBytes(group.bytes)}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: t.text3,
              fontSize: DsTypeScale.caption,
              fontFeatures: DsTokens.tabular,
            ),
          ),
        ],
      ),
    );
  }
}

/// 一部番一张卡：封面 + 番名 + 集数/体积 + 「播放首集 / 打开文件夹 / 展开」；
/// 展开后每一集有「播放 / 打开文件夹 / 移除任务 / 删除文件（回收站）」。
///
/// ⚠️ 第二十五轮：整张卡右键 = [_CardMenuAction] 菜单（换封面 / 移除任务 / 删文件）；
/// 封面与文件夹 chip 上那两层悬停 Tooltip 删掉了（用户：「鼠标放上去不要显示文字」）。
class _CompletedCard extends ConsumerWidget {
  const _CompletedCard({
    super.key,
    required this.group,
    required this.cover,
    required this.coverLoading,
    required this.coverError,
    required this.coverPicked,
    required this.expanded,
    required this.downloadRoot,
    required this.onToggleExpand,
    required this.onContextMenu,
  });

  final CompletedGroup group;
  final BangumiSubject? cover;
  final bool coverLoading;
  final String? coverError;
  final bool coverPicked;
  final bool expanded;
  final String? downloadRoot;
  final VoidCallback onToggleExpand;

  /// 右键（参数是指针的全局位置，菜单锚在它上面）。
  final void Function(Offset global) onContextMenu;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final DsTokens t = context.ds;
    final _CompletedActions actions = _CompletedActions(ref);
    final CompletedEpisode first = group.episodes.first;

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: NeoSurface(
          radius: t.radiusCard,
        padding: const EdgeInsets.fromLTRB(11, 10, 11, 10),
          onSecondaryTapDown: (TapDownDetails d) => onContextMenu(d.globalPosition),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                _CoverBox(
                  cover: cover,
                  loading: coverLoading,
                  error: coverError,
                  picked: coverPicked,
                ),
                const SizedBox(width: 11),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        group.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: t.text,
                          fontSize: DsTypeScale.body,
                          fontWeight: FontWeight.w600,
                          height: 1.3,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        children: <Widget>[
                          DsChip(
                            label: group.episodeRangeLabel,
                            icon: Icons.video_library_outlined,
                            tone: t.success,
                          ),
                          DsChip(label: formatBytes(group.bytes), icon: Icons.save_outlined),
                          if (first.torrent.outputFolder.isNotEmpty)
                            // 悬停不再冒 Tooltip（第二十五轮）；路径仍然写在 chip 里看得见。
                            DsChip(
                              label: first.torrent.outputFolder,
                              icon: Icons.folder_open,
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: <Widget>[
                    NeoButton(
                      label: '播放首集',
                      icon: Icons.play_arrow,
                      compact: true,
                      onPressed: first.torrent.playableFile == null
                          ? null
                          : () => actions.play(context, first.torrent),
                    ),
                    const SizedBox(height: 6),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        NeoButton(
                          label: expanded ? '收起' : '展开 ${group.count} 集',
                          icon: expanded ? Icons.expand_less : Icons.expand_more,
                          compact: true,
                          onPressed: onToggleExpand,
                        ),
                        const SizedBox(width: 6),
                        NeoButton(
                          label: '打开文件夹',
                          icon: Icons.folder_open,
                          compact: true,
                          onPressed: () => actions.reveal(context, first.torrent),
                        ),
                      ],
                    ),
                  ],
                ),
              ],
            ),
            if (expanded) ...<Widget>[
              const SizedBox(height: 9),
              Divider(height: 1, color: t.divider),
              const SizedBox(height: 4),
              for (final CompletedEpisode episode in group.episodes)
                _EpisodeRow(
                  episode: episode,
                  downloadRoot: downloadRoot,
                  onPlay: episode.torrent.playableFile == null
                      ? null
                      : () => actions.play(context, episode.torrent),
                  onReveal: () => actions.reveal(context, episode.torrent),
                  onRemove: () => actions.remove(context, episode.torrent),
                  onDelete: () => actions.delete(context, episode.torrent, downloadRoot),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 封面方块：加载中转一下，失败/无结果给可读的占位。
///
/// ⚠️ 第二十五轮（用户）：
/// * 「鼠标放上去不要显示文字」→ 外层 Tooltip **删掉**（悬停不再冒出封面名/提示）；
/// * 「点封面不要是换封面」→ 它不再是 `GestureDetector`，点它由卡片自己的 onTap 接走
///   （网格摆法 = 打开这一部番）。`dsCompletedCoverKey` 仍留在封面上当**测试锚点**。
/// 占位文案也跟着改成陈述句（不再写「点一下可换」——换封面现在是右键菜单里的事）。
class _CoverBox extends StatelessWidget {
  const _CoverBox({
    required this.cover,
    required this.loading,
    required this.error,
    required this.picked,
    this.width = kCompletedCoverWidth,
    this.height = kCompletedCoverHeight,
  });

  final BangumiSubject? cover;
  final bool loading;
  final String? error;
  final bool picked;

  /// 固定尺寸（列表摆法用 96×136）；**null = 跟着父约束铺满**（网格摆法用）。
  final double? width;
  final double? height;

  @override
  Widget build(BuildContext context) {
    final DsTokens t = context.ds;
    // 占位文案分四种，别把"图还没下来"说成"没匹配到"（那是两件事）。
    final String label = cover != null
        ? '封面没下来'
        : error != null
        ? '封面搜索失败'
        : loading
        ? '正在问 bangumi…'
        : '未匹配到封面';
    return SizedBox(
      key: dsCompletedCoverKey,
      width: width,
      height: height,
      child: Stack(
        children: <Widget>[
          Positioned.fill(
            child: DsCover(
              url: cover?.coverUrl ?? cover?.largeCoverUrl,
              referer: bangumiCoverReferer,
              placeholderLabel: label,
              // 96 × (96 ÷ 0.705) 的固定海报槽 → 不裁（见 kPosterFit）。
              fit: kPosterFit,
            ),
          ),
          // 手选过的角标：让人一眼看出"这张是我自己挑的"。
          if (picked)
            Positioned(
              right: 4,
              top: 4,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                decoration: BoxDecoration(
                  color: t.accentSoft,
                  borderRadius: BorderRadius.circular(t.radiusPill),
                ),
                child: Text('已选',
                    style: TextStyle(color: t.accent, fontSize: DsTypeScale.caption)),
              ),
            ),
        ],
      ),
    );
  }
}

/// 展开后的一集：集号 + 文件名 + 四个动作。
class _EpisodeRow extends StatelessWidget {
  const _EpisodeRow({
    required this.episode,
    required this.downloadRoot,
    required this.onPlay,
    required this.onReveal,
    required this.onRemove,
    required this.onDelete,
  });

  final CompletedEpisode episode;

  /// 只是为了让"这一行的删除会走哪套护栏"在卡片层就可见（供 tooltip 用）。
  final String? downloadRoot;
  final VoidCallback? onPlay;
  final VoidCallback onReveal;
  final VoidCallback onRemove;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final DsTokens t = context.ds;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: <Widget>[
          Container(
            width: 34,
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(vertical: 2),
            decoration: BoxDecoration(
              color: t.sunken,
              borderRadius: BorderRadius.circular(t.radiusBadge),
            ),
            child: Text(
              episode.episodeLabel,
              style: TextStyle(
                color: t.text2,
                fontSize: DsTypeScale.caption,
                fontFeatures: DsTokens.tabular,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              episode.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: t.text, fontSize: DsTypeScale.secondary),
            ),
          ),
          const SizedBox(width: 6),
          DsChip(label: formatBytes(episode.torrent.totalBytes)),
          const SizedBox(width: 6),
          NeoButton(
            label: '播放',
            icon: Icons.play_arrow,
            compact: true,
            onPressed: onPlay,
          ),
          const SizedBox(width: 5),
          NeoButton(
            label: '打开文件夹',
            icon: Icons.folder_open,
            compact: true,
            onPressed: onReveal,
          ),
          const SizedBox(width: 5),
          NeoButton(
            label: '移除',
            icon: Icons.playlist_remove,
            compact: true,
            tooltip: downloadRoot == null
                ? '只从列表移除任务，文件留着'
                : '只从列表移除任务，文件留在 $downloadRoot 下',
            onPressed: onRemove,
          ),
          const SizedBox(width: 5),
          NeoButton(
            label: '删文件',
            icon: Icons.delete_outline,
            kind: NeoButtonKind.danger,
            compact: true,
            tooltip: '把文件移进回收站（可还原）并移除任务',
            onPressed: onDelete,
          ),
        ],
      ),
    );
  }
}

/// 换封面对话框：候选自选 + 自己输关键字重搜（用户原话：
/// 「可点开错误封面，然后展示搜索内容自选，如果还是没有可自己搜索」）。
class _CoverPickerDialog extends ConsumerStatefulWidget {
  const _CoverPickerDialog({
    required this.groupKey,
    required this.groupName,
    required this.initialKeyword,
    required this.picked,
  });

  final String groupKey;
  final String groupName;
  final String initialKeyword;
  final bool picked;

  @override
  ConsumerState<_CoverPickerDialog> createState() => _CoverPickerDialogState();
}

class _CoverPickerDialogState extends ConsumerState<_CoverPickerDialog> {
  late final TextEditingController _keyword = TextEditingController(text: widget.initialKeyword);

  @override
  void initState() {
    super.initState();
    // 进对话框时确保问过一次（卡片那边只问了一屏的前 12 张，这里补上）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaitedAsk();
    });
  }

  void unawaitedAsk() {
    unawaited(ref
        .read(completedCoverProvider.notifier)
        .ensure(widget.groupKey, widget.groupName));
  }

  @override
  void dispose() {
    _keyword.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final DsTokens t = context.ds;
    final CompletedCoverState state = ref.watch(completedCoverProvider);
    final List<BangumiSubject> candidates = state.candidatesOf(widget.groupKey);
    final BangumiSubject? current = state.subjectOf(widget.groupKey);
    return AlertDialog(
      title: Text('换封面：${widget.groupName}'),
      content: SizedBox(
        width: 520,
        height: 420,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(
              '搜索关键字（已去掉方括号里的组名/集号/画质）：',
              style: TextStyle(color: t.text3, fontSize: DsTypeScale.caption),
            ),
            const SizedBox(height: 6),
            Row(
              children: <Widget>[
                Expanded(
                  child: TextField(
                    controller: _keyword,
                    decoration: const InputDecoration(hintText: '番名，例如：Re Zero kara Hajimeru Isekai Seikatsu 3rd Season'),
                    onSubmitted: (String value) => runGuarded(
                      context,
                      action: () => ref
                          .read(completedCoverProvider.notifier)
                          .search(widget.groupKey, value),
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                NeoButton(
                  label: '搜索',
                  icon: Icons.search,
                  kind: NeoButtonKind.primary,
                  onPressed: () => runGuarded(
                    context,
                    action: () => ref
                        .read(completedCoverProvider.notifier)
                        .search(widget.groupKey, _keyword.text),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            if (state.isLoading(widget.groupKey))
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 6),
                child: DsLoading(label: '正在问 bangumi…', compact: true),
              ),
            if (state.errorOf(widget.groupKey) case final String error)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: DsBanner(kind: DsBannerKind.warning, text: '搜索失败：$error'),
              ),
            Expanded(
              child: candidates.isEmpty
                  ? DsEmpty(
                      icon: Icons.image_search,
                      title: '没有候选',
                      message: '换一个关键字再搜（bangumi 用中文名/日文原名/罗马音都能搜）。'
                          '也可以不改关键字，直接关掉 —— 卡片上会显示「未匹配到封面」。',
                    )
                  : ListView.builder(
                      itemCount: candidates.length,
                      itemBuilder: (BuildContext context, int index) {
                        final BangumiSubject s = candidates[index];
                        final bool isCurrent = current?.id == s.id;
                        final String name = (s.nameCn?.trim().isNotEmpty ?? false)
                            ? s.nameCn!.trim()
                            : (s.name ?? '(无标题 · ${s.id})');
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 6),
                          child: InkWell(
                            onTap: () {
                              ref.read(completedCoverProvider.notifier).pick(widget.groupKey, s);
                              Navigator.of(context).pop();
                            },
                            child: NeoSurface(
                              radius: t.radiusControl,
                              padding: const EdgeInsets.all(6),
                              color: isCurrent ? t.accentSoft : null,
                              child: Row(
                                children: <Widget>[
                                  SizedBox(
                                    width: 40,
                                    height: 56,
                                    child: DsCover(
                                      url: s.coverUrl ?? s.largeCoverUrl,
                                      referer: bangumiCoverReferer,
                                      radius: t.radiusBadge,
                                      // 40×56（= 0.714）固定海报槽 → 不裁（见 kPosterFit）。
                                      fit: kPosterFit,
                                    ),
                                  ),
                                  const SizedBox(width: 9),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: <Widget>[
                                        Text(name,
                                            maxLines: 2,
                                            overflow: TextOverflow.ellipsis,
                                            style: TextStyle(
                                                color: t.text, fontSize: DsTypeScale.secondary)),
                                        const SizedBox(height: 3),
                                        Text(
                                          <String>[
                                            if ((s.name ?? '').trim().isNotEmpty) s.name!.trim(),
                                            if (s.date != null) s.date!,
                                            if (s.eps != null) '${s.eps} 话',
                                            if (s.score != null) '评分 ${s.score}',
                                            if (index == 0) '默认（第一个结果）',
                                            if (isCurrent) '当前使用',
                                          ].join(' · '),
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                              color: t.text3, fontSize: DsTypeScale.caption),
                                        ),
                                      ],
                                    ),
                                  ),
                                  if (isCurrent)
                                    Icon(Icons.check_circle, size: 16, color: t.accent),
                                ],
                              ),
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      actions: <Widget>[
        if (state.isPicked(widget.groupKey))
          TextButton(
            onPressed: () {
              ref.read(completedCoverProvider.notifier).clearPick(widget.groupKey);
              Navigator.of(context).pop();
            },
            child: const Text('用回默认（第一个结果）'),
          ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
      ],
    );
  }
}

/// 一个 torrent 里几个文件（确认框里用；空表就说"文件清单还没就绪"）。
String torrentFilesLabel(EngineTorrentView torrent) => torrent.files.isEmpty
    ? '文件清单还没就绪'
    : '${torrent.files.length} 个文件';

/// 「已完成」页的四个动作：**播放 / 打开文件夹 / 移除任务 / 删文件**。
///
/// 为什么抽成一个对象（第二十四轮）：这一页现在有两种摆法（封面卡网格、列表），
/// 而"点开网格卡之后的集列表"与"列表摆法展开后的集列表"**必须是同一套动作** ——
/// 各写一遍迟早走偏，最要命的是「删文件」那条回收站护栏（绝不允许永久删除）。
class _CompletedActions {
  const _CompletedActions(this.ref);

  final WidgetRef ref;

  Future<void> play(BuildContext context, EngineTorrentView torrent) async {
    final EngineFileView? file = torrent.playableFile;
    if (file == null) {
      showFailure(
        context,
        const DsFailure('这个 torrent 里没有识别出视频文件',
            hint: '到「队列」页看它的文件列表；可能只下了字幕或元数据还没就绪'),
      );
      return;
    }
    await ref.read(playbackProvider.notifier).playTorrentFile(torrent: torrent, file: file);
    if (!context.mounted) return;
    final DsFailure? failure = ref.read(playbackProvider).failure;
    if (failure != null) showFailure(context, failure);
  }

  Future<void> reveal(BuildContext context, EngineTorrentView torrent) async {
    final String? path = playableAbsolutePath(torrent);
    if (path == null) {
      showFailure(context, const DsFailure('这个 torrent 没有可定位的文件'));
      return;
    }
    // 定位不了就说清楚"为什么"（第十七轮）：引擎给的路径不是绝对路径 /
    // 文件已经不在了时，直接把不存在的路径丢给资源管理器只会让它开自己的默认目录，
    // 用户看到的是"跳到了别的地方"却没有任何解释。
    if (revealTargetFor(path) == null) {
      showFailure(
        context,
        DsFailure(
          '没能定位到这个文件',
          hint: '引擎给的路径是「$path」；文件可能被移动/删除了，'
              '或者这条任务没有记下下载目录',
        ),
      );
      return;
    }
    try {
      await ref.read(revealInExplorerProvider)(path);
    } catch (error, stackTrace) {
      if (!context.mounted) return;
      showFailure(context, describeFailure(error, stackTrace: stackTrace));
    }
  }

  /// 「移除任务」= 只把它从引擎/队列里拿掉，**文件留在原处**（用户问答选定）。
  Future<void> remove(BuildContext context, EngineTorrentView torrent) async {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('从列表移除这个任务？'),
        content: Text(
          '只把任务从引擎和队列里拿掉，磁盘上的文件不动。\n\n${torrent.name}\n'
          '（${formatBytes(torrent.totalBytes)}，${torrentFilesLabel(torrent)}）',
          style: TextStyle(color: context.ds.text2, fontSize: DsTypeScale.body, height: 1.5),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('移除任务'),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    final QueuePort port = ref.read(queuePortProvider);
    try {
      final String? warning = await port.removeByEngine(torrent.id, deleteFiles: false);
      ref.invalidate(engineTorrentsProvider);
      if (!context.mounted) return;
      if (warning == null) {
        showSuccess(context, '已移除任务（文件留着）');
      } else {
        showFailure(context, DsFailure(warning, hint: '文件还在磁盘上，任务可能还在队列里'));
      }
    } catch (error, stackTrace) {
      if (!context.mounted) return;
      showFailure(context, describeFailure(error, stackTrace: stackTrace));
    }
  }

  /// 「删除文件」= 移除任务 + **把文件移进回收站**（可恢复）。
  Future<void> delete(
    BuildContext context,
    EngineTorrentView torrent,
    String? downloadRoot,
  ) async {
    final List<String> paths = engineFilesAbsolutePaths(torrent);
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('删除文件到回收站？'),
        content: Text(
          '文件会移进 Windows 回收站（可以还原），任务同时从引擎/队列移除。\n'
          '共 ${paths.length} 个文件 · ${formatBytes(torrent.totalBytes)}\n\n'
          '${paths.take(4).map((String p) => '· ${p.split(RegExp(r'[\\/]')).last}').join('\n')}'
          '${paths.length > 4 ? '\n… 还有 ${paths.length - 4} 个' : ''}',
          style: TextStyle(color: context.ds.text2, fontSize: DsTypeScale.body, height: 1.5),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('删到回收站'),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;

    final QueuePort queue = ref.read(queuePortProvider);
    final RecycleToTrash recycle = ref.read(recycleBinProvider);
    final CompletedDeleteOutcome outcome = await deleteCompletedFiles(
      torrent: torrent,
      downloadRoot: downloadRoot,
      removeFromEngine: (int id) => queue.removeByEngine(id, deleteFiles: false),
      recycle: recycle,
    );
    ref.invalidate(engineTorrentsProvider);
    if (!context.mounted) return;

    if (outcome.failure != null) {
      // 标题要**中性**：`outcome.failure` 既可能是"回收站那一步失败"，也可能是
      // "引擎移除失败所以文件一个都没动"（第四十二轮 UX #13 把后者从"异常冒出去"
      // 改成了明确结果）。写死"文件没能进回收站"会在后一种情形下指错方向。
      showFailure(context, DsFailure('这次删除没做成', hint: outcome.failure));
      return;
    }
    final String detail = <String>[
      if (outcome.recycled > 0) '${outcome.recycled} 个文件已进回收站',
      if (outcome.missing.isNotEmpty) '${outcome.missing.length} 个文件本来就不在磁盘上',
      if (outcome.blocked.isNotEmpty) '${outcome.blocked.length} 个路径被安全护栏挡下（没删）',
      if (outcome.engineWarning != null) '引擎那边：${outcome.engineWarning}',
    ].join('；');
    if (outcome.recycled > 0) {
      showSuccess(context, detail.isEmpty ? '已删到回收站' : detail);
    } else {
      showFailure(context, DsFailure('没有文件被删（可能都已经不在磁盘上）', hint: detail));
    }
  }
}
