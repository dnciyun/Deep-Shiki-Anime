/// 番剧详情页（主页卡片点进来的那一层）。
///
/// 为什么必须多这一层：mikan 首页的追番表**只有「番剧在某天更新」**，没有磁力、
/// 没有集数（spec §7.5 明确禁止伪造集数）。真正的可播项在
/// `/Home/Bangumi/<id>` 里（字幕组分区 + 每集 magnet/`.torrent`），
/// 也就是 core 的 `MikanSource.bangumi()`。这里把它渲染出来，
/// 点某一集才走队列入队播放（复用既有链路：`playbackProvider.playItem`）。
///
/// **整页只用 mikan 自己的数据**（用户 2026-10-12：「首页点开的不要加载 bangumi 了，
/// 只用 mikan 的就好」）：封面/标题/字幕组/剧集全部来自 mikan，
/// 原来中间那一块「Bangumi 元数据」（去 bgm.tv 按番名匹配封面+评分+标签）整个删掉 ——
/// 打开一集要等两次网络、还经常匹配不上一部中文名，却只为了一个第三方封面。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/episodes.dart';
import '../domain/error_text.dart';
import '../domain/format.dart';
import '../domain/models.dart';
import '../state/playback.dart';
import '../state/providers.dart';
import '../theme/tokens.dart';
import 'widgets/cover.dart';
import 'widgets/feedback.dart';
import 'widgets/follow_button.dart';
import 'widgets/group_subscribe.dart';
import 'widgets/hues.dart';
import 'widgets/neo.dart';
import 'widgets/state_views.dart';

/// 打开番剧详情（主页卡片点击）。
Future<void> openBangumiDetail(BuildContext context, ScheduleEntryView entry) {
  return Navigator.of(context, rootNavigator: true).push<void>(
    MaterialPageRoute<void>(
      builder: (BuildContext context) => BangumiDetailPage(entry: entry),
    ),
  );
}

class BangumiDetailPage extends ConsumerStatefulWidget {
  const BangumiDetailPage({super.key, required this.entry});

  final ScheduleEntryView entry;

  @override
  ConsumerState<BangumiDetailPage> createState() => _BangumiDetailPageState();
}

class _BangumiDetailPageState extends ConsumerState<BangumiDetailPage> {
  String? _busyItemId;

  Future<void> _play(SourceItemView item, List<SourceItemView> episodes) async {
    // 起播前先抓住 navigator（await 之后再摸 context 会触发
    // `use_build_context_synchronously`）；失败提示统一走 `showFailure`，所以
    // 这里不再需要 ScaffoldMessenger 与 tokens 的局部副本。
    final NavigatorState navigator = Navigator.of(context);
    setState(() => _busyItemId = item.id);
    try {
      await ref.read(playbackProvider.notifier).playItem(
            item,
            upNext: followingEpisodes(episodes, item),
            // 播放列表 = 这个字幕组这一整页的剧集（同名同压制组，见 domain/playlist.dart）。
            playlist: episodes,
            // 观看记录（第二十七轮）要的"这一部是谁"：条目里只有"第 03 集"这种标题，
            // 封面与番剧 id 只有这一页知道。
            showTitle: widget.entry.displayTitle,
            coverUrl: widget.entry.coverUrl,
            mikanBangumiId: widget.entry.bangumiId,
          );
      final DsFailure? failure = ref.read(playbackProvider).failure;
      if (!mounted) return;
      if (failure != null) {
        showFailure(context, failure);
        return;
      }
      // 起播成功：退回外壳。播放本身已经落在弹出窗口里（用户 2026-10-10），
      // 主窗口不再有「正在播放」页可切。
      if (navigator.canPop()) navigator.pop();
    } catch (error, stackTrace) {
      // 起播失败：走统一的 `showFailure`（NeoBanner：12% 底 + 左侧 2px 语义色条 + 怎么办）。
      // 第三十轮改：原来整条铺 `t.dangerSoft`，属于大面积语义色（规范 F16/§2 只允许小面积）。
      if (mounted) showFailure(context, describeFailure(error, stackTrace: stackTrace));
    } finally {
      if (mounted) setState(() => _busyItemId = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final DsTokens t = context.ds;
    final ScheduleEntryView entry = widget.entry;
    final AsyncValue<BangumiDetailView> async =
        ref.watch(bangumiDetailProvider(entry.bangumiId));

    return Scaffold(
      backgroundColor: t.base,
      appBar: AppBar(
        backgroundColor: t.surface,
        elevation: 0,
        toolbarHeight: t.barHeight,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, size: 16),
          tooltip: '返回主页',
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        titleSpacing: 0,
        // 第五十二轮（用户 2026-10-17「整个项目太素」）：番剧详情的**身份色 = 橙**，
        // 与主页「今日推荐 / 今日更新」同一个色相（`hueOfTab(ShellTab.home)`）——
        // 页头标题前一条 3px 橙竖条 + 标题用橙色 ink，从主页点进来颜色是连着的。
        title: Row(
          children: <Widget>[
            Container(
              width: 3,
              height: 14,
              decoration: BoxDecoration(
                color: t.hueFill(DsHue.orange),
                borderRadius: BorderRadius.circular(t.radiusPill),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                async.value?.displayTitle ?? entry.displayTitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    color: t.hueInk(DsHue.orange),
                    fontSize: DsTypeScale.body,
                    fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
        actions: <Widget>[
          // 追番按钮（spec §7.6）：详情页头部也能追，不必先建订阅。
          FollowButton(entry: followingEntryFromSchedule(widget.entry)),
          const SizedBox(width: 8),
          IconButton(
            icon: const Icon(Icons.refresh, size: 16),
            tooltip: '重新拉取番剧详情',
            onPressed: () => ref.invalidate(bangumiDetailProvider(entry.bangumiId)),
          ),
          const SizedBox(width: 6),
        ],
      ),
      body: _body(async, entry),
    );
  }

  Widget _body(AsyncValue<BangumiDetailView> async, ScheduleEntryView entry) {
    if (entry.bangumiId.trim().isEmpty) {
      // 第五十二轮：空态图标圆盘也用页面身份色（橙），不再是一个全灰圆盘。
      return const DsEmpty(
        hue: DsHue.orange,
        icon: Icons.link_off,
        title: '这条追番记录没有番剧 id',
        message: 'mikan 首页没给 id，打不开详情页。可以到「搜索」页按番名搜这一部。',
      );
    }
    final BangumiDetailView? detail = async.value;
    if (detail == null) {
      if (async.isLoading) {
        return const DsLoading(label: '正在拉取番剧详情（字幕组与剧集）…');
      }
      return SingleChildScrollView(
        child: DsErrorPanel(
          failure: describeFailure(async.error ?? '番剧详情拉取失败'),
          title: '番剧详情拉取失败',
          onRetry: () =>
              ref.invalidate(bangumiDetailProvider(entry.bangumiId)),
        ),
      );
    }
    if (detail.episodes.isEmpty) {
      return const DsEmpty(
        hue: DsHue.orange,
        icon: Icons.movie_filter_outlined,
        title: '这一部还没有可下载的剧集',
        message: 'mikan 番剧页没解析出剧集（可能是新番未开播）。稍后再试，或到「搜索」页按番名找种子。',
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _Header(entry: entry, detail: detail),
        Expanded(child: _EpisodeList(
          detail: detail,
          busyItemId: _busyItemId,
          onPlay: _play,
        )),
      ],
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.entry, required this.detail});

  final ScheduleEntryView entry;
  final BangumiDetailView detail;

  @override
  Widget build(BuildContext context) {
    final DsTokens t = context.ds;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 96,
            height: 96 / kPosterAspect,
            child: DsCover(
              url: entry.coverUrl,
              radius: t.radiusBadge,
              // 96 × (96 ÷ 0.705) 固定海报槽 → 不裁（见 kPosterFit）。
              fit: kPosterFit,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(detail.displayTitle,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        color: t.text,
                        fontSize: DsTypeScale.title,
                        fontWeight: FontWeight.w600)),
                const SizedBox(height: 6),
                Text(
                  <String>[
                    '${detail.episodes.length} 集',
                    if (entry.updateLabel.isNotEmpty) entry.updateLabel,
                    if (detail.groups.isNotEmpty)
                      '${detail.groups.length} 个字幕组',
                  ].join(' · '),
                  style: TextStyle(
                      color: t.text3, fontSize: DsTypeScale.caption),
                ),
                if (detail.groups.isNotEmpty) ...<Widget>[
                  const SizedBox(height: 8),
                  // 字幕组用胶囊（凹槽底、无边框），不再「灰底 + 1px 描边」。
                  // 第五十二轮：每颗字幕组胶囊按 `hueOfTag` 上色 —— 同一组名每次同色，
                  // 和下面剧集列表里该组的区块头是**同一个色相**（颜色成了"这是哪个组"的编码）。
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: <Widget>[
                      for (final BangumiGroupView group in detail.groups)
                        NeoPill(
                          label: group.name,
                          icon: Icons.groups_outlined,
                          hue: hueOfTag(group.name),
                        ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 剧集列表：按字幕组分区（mikan 的番剧页就是这个结构）。
///
/// ⚠️ 第二十七轮：每个字幕组标题右边多一颗「订阅」（用户：「在字幕组的旁边，可以直接订阅」），
/// 所以这里要读 provider（订阅列表）—— 从 `StatelessWidget` 变成 `ConsumerWidget`。
class _EpisodeList extends ConsumerWidget {
  const _EpisodeList({
    required this.detail,
    required this.busyItemId,
    required this.onPlay,
  });

  final BangumiDetailView detail;
  final String? busyItemId;
  final Future<void> Function(SourceItemView item, List<SourceItemView> all) onPlay;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 字幕组顺序照站点给的顺序；没有 group 的归到最后一组。
    final List<String> groups = <String>[
      ...detail.groupNames,
      for (final SourceItemView item in detail.episodes)
        if (!detail.groupNames.contains(item.group ?? '')) item.group ?? '未知字幕组',
    ];
    // 去重（保序），避免同一组重复出小标题。
    final List<String> ordered = <String>[];
    for (final String g in groups) {
      if (!ordered.contains(g)) ordered.add(g);
    }
    // 组名 → 组（拿 RSS 地址用；站点没给就退化成"没有地址、订阅按钮置灰"）。
    final Map<String, BangumiGroupView> byName = <String, BangumiGroupView>{
      for (final BangumiGroupView g in detail.groups) g.name: g,
    };

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 20),
      children: <Widget>[
        for (final String group in ordered) ...<Widget>[
          // 第五十二轮（用户 2026-10-17「整个项目太素」）：每个字幕组 = 一块"板块"，
          // 区块头带该组的色相竖条 + 色相标题（`NeoSectionHeader`，与设置页 `DsSection`
          // 同一套记号语言）。色相走 `hueOfTag` 的稳定哈希：同一组名每次渲染同色，
          // 并且与页头那颗同组的字幕组胶囊颜色一致。
          Padding(
            padding: const EdgeInsets.only(top: 6, bottom: 5),
            child: NeoSectionHeader(
              title: group,
              hue: hueOfTag(group),
              padding: EdgeInsets.zero,
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  GroupSubscribeButton(
                    bangumiId: detail.bangumiId,
                    showTitle: detail.displayTitle,
                    group: byName[group] ??
                        BangumiGroupView(name: group), // 站点没列出的组：只能逐集下载
                  ),
                  const SizedBox(width: 4),
                ],
              ),
            ),
          ),
          for (final SourceItemView item in detail.episodes)
            if ((item.group ?? '未知字幕组') == group)
              _EpisodeRow(
                item: item,
                busy: busyItemId == item.id,
                onPlay: () => onPlay(item, detail.episodes),
              ),
        ],
      ],
    );
  }
}

class _EpisodeRow extends ConsumerWidget {
  const _EpisodeRow({
    required this.item,
    required this.busy,
    required this.onPlay,
  });

  final SourceItemView item;
  final bool busy;
  final Future<void> Function() onPlay;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final DsTokens t = context.ds;
    // 播放/下载都走 `canDownload`：自己带源（磁力/直链/infoHash）**或**有详情页链接能补链。
    // `playable` 只管状态列第一档文案（"现在就能播" vs "得先去详情页补磁力"）。
    final bool playable = item.hasTorrentSource;
    final bool actionable = item.canDownload;
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      // 列表里的行：凸起面 + listSafe 阴影（模糊 ≤ 2px，规范 §3 性能红线），无硬边框。
      decoration: t.cardDecoration(
        radius: t.radiusControl,
      ),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(item.displayTitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        color: t.text, fontSize: DsTypeScale.body)),
                const SizedBox(height: 3),
                Row(
                  children: <Widget>[
                    if (item.episodeHints.isNotEmpty) ...<Widget>[
                      Text(formatEpisodeHints(item.episodeHints),
                          style: TextStyle(
                              color: t.accent,
                              fontSize: DsTypeScale.caption,
                              fontWeight: FontWeight.w600)),
                      const SizedBox(width: 10),
                    ],
                    Text(formatBytes(item.sizeBytes),
                        style: TextStyle(
                            color: t.text3,
                            fontSize: DsTypeScale.caption,
                            fontFeatures: DsTokens.tabular)),
                    if (item.resolution case final String res) ...<Widget>[
                      const SizedBox(width: 10),
                      Text(res,
                          style: TextStyle(
                              color: t.text3,
                              fontSize: DsTypeScale.caption)),
                    ],
                    if (item.subtitleLang case final String lang) ...<Widget>[
                      const SizedBox(width: 10),
                      Text(lang,
                          style: TextStyle(
                              color: t.text3,
                              fontSize: DsTypeScale.caption)),
                    ],
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          // 用户 2026-10-10 第 2 轮问答：剧集行与搜索结果表对齐 ——
          // 名（含集数/大小/画质/字幕副行）+ **状态** + 下载。
          // 用户 2026-10-11「把做种数去掉」：原来夹在名与状态之间的「做种」列（NeoDot + 数字）
          // 整个删掉；源的 `seeders` 字段仍在数据层保留（订阅过滤/排序还要用）。
          SizedBox(
            width: 74,
            child: Text(
              playable
                  ? '可播'
                  : actionable
                      ? '需补链'
                      : '无磁力链',
              // 状态只看"这条有没有源"：做种数不再参与判断。nyaa 之外的源（mikan RSS 等）
              // 本来就不给做种数，用 `seeders == 0` 判「无种子」会把 seeders 为 null 的
              // 可播条目误标成不能播。
              //
              // 第三档「需补链」是 2026-10-15 第三十轮补的：mikan 番剧页的行是
              // `infoHash: infoHashFromMagnet(magnet) ?? hash`，磁力没抽到但单集 hash 在
              // ⇒ 之前被当成"无源"，整行连按钮都不画，用户点行**毫无反应**（报障原话：
              // 「集数里点第 4-6 集没反应，也没进队列下载」）。这种条目点下去会先
              // `ensurePlayable` 去 `/Home/Episode/<hash>` 取磁力，所以它是**可操作**的。
              style: TextStyle(
                  color: playable
                      ? t.success
                      : actionable
                          ? t.text2
                          : t.warning,
                  fontSize: DsTypeScale.caption),
            ),
          ),
          if (!actionable)
            Tooltip(
              message: '这条既没有磁力/直链，也没有可补链的详情页，不能播放',
              child: Text('无种子链接',
                  style: TextStyle(
                      color: t.warning, fontSize: DsTypeScale.caption)),
            )
          else ...<Widget>[
            // 操作按钮换成新拟态组件（旧的 FilledButton/OutlinedButton 带 Material
            // 描边与 elevation，属于规范 §7 要覆盖掉的默认控件）。
            NeoButton(
              label: busy ? '起播中…' : '播放',
              icon: Icons.play_arrow,
              kind: NeoButtonKind.primary,
              busy: busy,
              compact: true,
              onPressed: busy ? null : () => onPlay(),
            ),
            const SizedBox(width: 6),
            NeoButton(
              label: '下载',
              icon: Icons.download,
              compact: true,
              onPressed: () => runGuarded(
                context,
                action: () => ref.read(queuePortProvider).enqueueDownload(item),
                success: '已加入下载队列',
              ),
            ),
          ],
        ],
      ),
    );
  }
}
