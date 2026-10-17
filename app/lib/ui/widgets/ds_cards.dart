/// 复用卡片：结果卡片 / 队列行 / 订阅行 / 分组面板 / 小徽标。
///
/// 视觉：新拟态规范 `docs/specs/2026-10-10-dsanima-neo-theme.md` §7
/// * 无硬边框（原来的 `Border.all(color: border)` 全部去掉，改凸起面 + 柔光内边）；
/// * 列表内的卡片一律 `listSafe: true`（性能红线：模糊 ≤ 2px）；
/// * 字号只用 5 档阶梯。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/format.dart';
import '../../domain/models.dart';
import '../../domain/queue_display.dart';
import '../../domain/queue_sort.dart';
import '../../state/providers.dart';
import '../../theme/tokens.dart';
import '../settings_page.dart' show kSettingsCaptionSize, kSettingsTitleSize;
import 'feedback.dart';
import 'neo.dart';
import 'neo_dropdown.dart';

/// 带标题的面板（组内边距统一；凸起面，无边框）。
///
/// ⚠️ 第二十五轮（用户：「设置内的文字颇多且杂乱一体，多做点区分」）：
/// 标题前面加一条**强调色竖条**（一级标题的记号），小字说明缩进对齐标题文字。
///
/// ⚠️ **第二十六轮**（用户：「设置页去除上次改动的『展开』内容，缩小整体字大小，
/// 增加每个设置的间距」）：
/// * 说明**不再折叠** —— 上一轮那句「展开说明 ▾」整段删掉，长说明直接全文换行显示
///   （设置页要"一眼看完"，而不是每个区块都挂一颗要点的按钮）；
/// * 说明文字收小到 11（设置页的局部字号，见 `settings_page.dart` 顶部那组常量）；
/// * 标题/说明/内容之间的内边距整体加大，区块之间的外边距也加大。
/// 这个类目前只有设置页在用，所以在这里动版式不会影响别的页面。
class DsSection extends StatelessWidget {
  const DsSection({
    super.key,
    required this.title,
    this.subtitle,
    this.trailing,
    required this.child,
    this.dense = false,
    this.hue,
    this.icon,
  });

  final String title;
  final String? subtitle;
  final Widget? trailing;
  final Widget child;
  final bool dense;

  /// 标识色相（第五十二轮）：给了就把标题前的竖条换成色相色、标题用色相 ink。
  /// 设置页每个区块一个色相，整页就有了"分区色"。
  final DsHue? hue;

  /// 可选的区块图标（给 icon 时用「色相淡底小方块 + 图标」代替竖条）。
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final DsTokens t = context.ds;
    return Container(
      // 区块与区块之间的留白：`spacing * 1.5` → `spacing * 2.5`（"增加每个设置的间距"）。
      margin: EdgeInsets.fromLTRB(t.spacing * 2, t.spacing * 2.5, t.spacing * 2, 0),
      decoration: BoxDecoration(
        color: t.raised,
        borderRadius: BorderRadius.circular(t.radiusCard),
        border: Border.all(color: t.line, width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            // 标题区：行高 14 → 18，底部 8 → 12。
            padding: EdgeInsets.fromLTRB(18, dense ? 14 : 18, 16, 12),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: <Widget>[
                          // 区块标题记号（第五十二轮）：有 icon 用「色相淡底方块 + 图标」，
                          // 否则用 3px 竖条（默认强调色，给了 hue 就换成色相色）。
                          if (icon != null) ...<Widget>[
                            Container(
                              width: 24,
                              height: 24,
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                color: hue != null ? t.hueSoft(hue!) : t.accentSoft,
                                borderRadius: BorderRadius.circular(t.radiusBadge),
                              ),
                              child: Icon(
                                icon,
                                size: 14,
                                color: hue != null ? t.hueInk(hue!) : t.accent,
                              ),
                            ),
                            const SizedBox(width: 10),
                          ] else ...<Widget>[
                            Container(
                              width: 3,
                              height: 14,
                              decoration: BoxDecoration(
                                color: hue != null ? t.hueFill(hue!) : t.accent,
                                borderRadius: BorderRadius.circular(t.radiusPill),
                              ),
                            ),
                            const SizedBox(width: 8),
                          ],
                          Expanded(
                            child: Text(
                              title,
                              style: TextStyle(
                                // 区块标题 17 → 15（"缩小整体字大小"）。
                                color: hue != null ? t.hueInk(hue!) : t.text,
                                fontSize: kSettingsTitleSize,
                                fontWeight: FontWeight.w600,
                                height: 1.25,
                              ),
                            ),
                          ),
                        ],
                      ),
                      if (subtitle != null)
                        Padding(
                          // 左缩进 = 前导记号宽 + 间距，让说明与标题文字左对齐成一列。
                          // 第五十二轮：前导记号有两种（3px 竖条 = 11；24px 图标方块 = 34），
                          // 缩进必须跟着走，否则说明会比标题左移一大截。
                          padding: EdgeInsets.only(
                            top: 6,
                            left: icon != null ? 34 : 11,
                          ),
                          // ⚠️ 第二十六轮：**不再折叠**，全文换行显示（见类文档）。
                          // 行高 1.4 → 1.6：说明收小之后靠行距把可读性补回来。
                          child: Text(
                            subtitle!,
                            style: TextStyle(
                              color: t.text3,
                              fontSize: kSettingsCaptionSize,
                              height: 1.6,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                ?trailing,
              ],
            ),
          ),
          // 分隔用极淡的线（不是边框），比原来的硬边框轻一档。
          Divider(height: 1, color: t.divider),
          Padding(
            padding: EdgeInsets.fromLTRB(18, dense ? 16 : 18, 18, 18),
            child: child,
          ),
        ],
      ),
    );
  }
}

/// 小徽标（尺寸/字幕组/分辨率/速率…）。语义色只以小面积出现（决策 A18）。
///
/// ⚠️ **2026-10-15 第三十轮**：`tone` 必须走 `NeoPill.tone`（不是 `color`）——
/// 只有 `tone` 才会给 12% 底 + 该色文字。之前传 `color` 让 tone **完全失效**
/// （队列「失败/取消」不是 danger、已完成不是 success，五颗 chip 一个样）。
class DsChip extends StatelessWidget {
  const DsChip({super.key, required this.label, this.icon, this.tone, this.hue, this.tooltip});

  final String label;
  final IconData? icon;
  final Color? tone;

  /// 标识色相（第五十二轮）：分类色（源 / 标签 / 页面），与 [tone] 语义色二选一。
  final DsHue? hue;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    return NeoPill(label: label, icon: icon, tone: tone, hue: hue, tooltip: tooltip);
  }
}

/// 细进度条 + 右侧百分比（凹槽轨道 + 语义色填充）。
class DsProgressLine extends StatelessWidget {
  const DsProgressLine({super.key, required this.value, this.height = 4, this.tone, this.hue});

  final double value;
  final double height;
  final Color? tone;
  final DsHue? hue;

  @override
  Widget build(BuildContext context) {
    return NeoProgress(value: value, height: height, color: tone, hue: hue);
  }
}

/// 引擎连接状态徽标（外壳顶栏 & 设置页共用）。
class EngineStatusPill extends ConsumerWidget {
  const EngineStatusPill({super.key, this.onTap});

  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final DsTokens t = context.ds;
    final EngineStatus status = ref.watch(engineStatusProvider);
    final (Color color, IconData icon) = switch (status.kind) {
      EngineStatusKind.connected => (t.success, Icons.link),
      EngineStatusKind.connecting => (t.warning, Icons.sync),
      EngineStatusKind.error => (t.danger, Icons.link_off),
    };
    return Tooltip(
      message: status.hint ?? status.label,
      child: Container(
        decoration: t.cardDecoration(
          radius: t.radiusPill,
        ),
        padding: EdgeInsets.zero,
        child: NeoPill(label: status.label, icon: icon, color: color, selected: true, onTap: onTap),
      ),
    );
  }
}

/// 队列行：标题 + 状态 + 引擎实时进度 + 操作（暂停/继续/删除/优先级）。
class QueueJobRow extends StatelessWidget {
  const QueueJobRow({
    super.key,
    required this.job,
    this.torrent,
    this.onPause,
    this.onResume,
    this.resumeLabel = '继续',
    this.onRemove,
    this.onRemoveWithFiles,
    this.onPriorityPick,
    this.dragHandle,
  });

  final QueueJobView job;
  final EngineTorrentView? torrent;
  final VoidCallback? onPause;
  final VoidCallback? onResume;

  /// 「继续」那颗按钮写什么。
  ///
  /// 失败的任务走的是同一条 `resumeJob` 路（core 允许多这一个状态，见
  /// `resumeJob` 里的判据），但文案必须是**重试** —— 用户看到「继续」不会想到
  /// 那是"再试一次刚才失败的那一步"（第四十二轮 UX #7）。
  final String resumeLabel;
  final VoidCallback? onRemove;
  final VoidCallback? onRemoveWithFiles;
  final void Function(int level)? onPriorityPick;
  final Widget? dragHandle;

  @override
  Widget build(BuildContext context) {
    final DsTokens t = context.ds;
    final EngineFileView? file = torrent?.files.isEmpty ?? true
        ? null
        : (job.fileIndex == null
              ? torrent!.playableFile
              : torrent!.files.firstWhere(
                  (EngineFileView f) => f.index == job.fileIndex,
                  orElse: () => torrent!.files.first,
                ));
    final double overall = torrent?.progress ?? 0;
    // 第五十二轮「整个项目太素」：队列页的身份色 = 蓝（`hueOfTab(queue)`），所以
    // 「下载中」不再用调色板 accent（白橙外观下是橙、白黑外观下是黑），而是固定的蓝；
    // 暂停/完成/失败继续用语义色（它们是"状态"不是"页面"）。
    final Color stateTone = switch (job.state) {
      JobState.downloading => t.hueInk(DsHue.blue),
      JobState.queued => t.text3,
      JobState.paused => t.warning,
      JobState.completed => t.success,
      JobState.failed => t.danger,
      JobState.cancelled => t.text3,
    };
    final Widget card = Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(15, 12, 14, 10),
      decoration: BoxDecoration(
        color: t.raised,
        borderRadius: BorderRadius.circular(t.radiusCard),
        border: Border.all(color: t.line, width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              ?dragHandle,
              if (dragHandle != null) const SizedBox(width: 6),
              Expanded(
                child: Text(
                  job.displayTitle,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: t.text, fontSize: DsTypeScale.body, height: 1.4),
                ),
              ),
              const SizedBox(width: 8),
              DsChip(label: job.state.label, tone: stateTone),
              if (job.isPrefetch)
                Padding(
                  padding: const EdgeInsets.only(left: 6),
                  child: DsChip(label: '预取', tone: t.accent),
                ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: <Widget>[
              Expanded(
                child: DsProgressLine(value: overall, tone: stateTone),
              ),
              const SizedBox(width: 10),
              Text(
                torrent != null
                    ? formatPercent(overall)
                    // 没有引擎信息时别说"等待引擎…"：已经暂停/结束的任务永远等不到，
                    // 而"排队中/等元数据"又完全是另一回事（见 domain/queue_display.dart）。
                    : queueProgressText(job),
                style: TextStyle(
                  color: t.text2,
                  fontSize: DsTypeScale.caption,
                  fontFeatures: DsTokens.tabular,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: <Widget>[
              if (torrent != null) ...<Widget>[
                DsChip(
                  label: '↓ ${formatSpeed(torrent!.downloadBps)}',
                  icon: Icons.download,
                  hue: DsHue.blue,
                ),
                DsChip(
                  label: '↑ ${formatSpeed(torrent!.uploadBps)}',
                  icon: Icons.upload,
                  hue: DsHue.teal,
                ),
                // 原来这里还有一颗「做种 N」徽标（`torrent.peers`）。用户 2026-10-11
                //「把做种数去掉」后删掉：它显示的是**当前连到的 peer 数**，不是源的做种数，
                // 数字随连接状态乱跳，却和旁边的 ↓/↑/进度并列成"同等重要"的信息。
                DsChip(
                  label:
                      '${formatBytes(torrent!.progressBytes)} / ${formatBytes(torrent!.totalBytes)}',
                  icon: Icons.data_usage,
                ),
              ] else
                // 引擎里读不到这条任务时按**真实状态**说话（用户 2026-10-12 第二十三轮）：
                // 旧实现一律写「引擎里已经没有这个任务」，而排队中（还没轮到）和正在把
                // 磁力交给引擎（等元数据最长 130s）这两种情况下 `engineId` 本来就是空的
                // —— 用户连点下载时看到的就是一屏假报错。判据见 domain/queue_display.dart。
                DsChip(
                  label: queueEngineChip(job).label,
                  icon: Icons.link_off,
                  tone: queueEngineChip(job).warn ? t.warning : t.text3,
                ),
              if (file != null)
                DsChip(
                  label: '本集 ${formatPercent(file.progress)}${file.complete ? ' · 已完成' : ''}',
                  icon: Icons.movie_outlined,
                  tone: file.complete ? t.success : t.text3,
                ),
              DsChip(label: 'priority ${job.priority}'),
            ],
          ),
          if (job.error != null && job.error!.isNotEmpty) ...<Widget>[
            const SizedBox(height: 8),
            Text(
              '错误：${job.error}',
              style: TextStyle(color: t.danger, fontSize: DsTypeScale.secondary),
            ),
          ],
          const SizedBox(height: 8),
          Row(
            children: <Widget>[
              // 用户 2026-10-10 第 3 轮问答：把「↑ / ↓」两颗按钮换成一个
              // **4 档优先级**下拉（最高 / 高 / 普通 / 低）—— 一步选到位，
              // 不用连点；页头那个全局排序是"怎么看"，这里是"这条排第几"。
              if (onPriorityPick != null)
                NeoDropdown<int>(
                  width: 116,
                  height: 28,
                  fontSize: DsTypeScale.caption,
                  value: priorityLevelOf(job.priority),
                  tooltip: '这一条排第几（数字小 = 先下）',
                  label:
                      '优先级 · '
                      '${QueuePriorityLevel.values[priorityLevelOf(job.priority)].label}',
                  items: <NeoDropdownItem<int>>[
                    for (final QueuePriorityLevel level in QueuePriorityLevel.values)
                      NeoDropdownItem<int>(level.index, level.label),
                  ],
                  onSelected: (int level) => onPriorityPick!(level),
                ),
              const Spacer(),
              if (onPause != null)
                NeoButton(label: '暂停', icon: Icons.pause, onPressed: onPause, compact: true),
              if (onResume != null)
                NeoButton(
                  label: resumeLabel,
                  icon: Icons.play_arrow,
                  onPressed: onResume,
                  compact: true,
                ),
              if (onRemove != null)
                NeoButton(
                  label: '移除',
                  icon: Icons.close,
                  // 已经下完的不动引擎那份记录（第十九轮）：说清楚，不然用户会以为
                  // 「移除」把下好的东西也一起处理掉了。
                  tooltip: '只从队列里删掉这条任务（订阅不会再自动加回来）；'
                      '已经下完的会留在「已完成」，文件不动',
                  onPressed: onRemove,
                  compact: true,
                ),
              if (onRemoveWithFiles != null)
                NeoButton(
                  label: '删除含文件',
                  icon: Icons.delete_outline,
                  tooltip: '删掉任务、引擎里的 torrent 与磁盘上的文件',
                  kind: NeoButtonKind.danger,
                  onPressed: onRemoveWithFiles,
                  compact: true,
                ),
            ],
          ),
        ],
      ),
    );

    // 第五十二轮：卡片左缘 3px 状态色竖条 —— 队列一屏十几条时，颜色先于文字告诉你
    // 「哪条在跑、哪条挂了」。用 Stack + Positioned 而不是 Border/IntrinsicHeight：
    // 竖条随卡片高度自动拉满，不引入额外布局测量（长列表性能红线）。
    return ClipRRect(
      borderRadius: BorderRadius.circular(t.radiusCard),
      child: Stack(
        children: <Widget>[
          card,
          Positioned(
            left: 0,
            top: 0,
            bottom: 0,
            width: 3,
            child: ColoredBox(color: stateTone),
          ),
        ],
      ),
    );
  }
}

/// 订阅行：名称 / 类型 / 规则数 / 上次刷新 / 启用开关 + 操作。
class SubscriptionRow extends StatelessWidget {
  const SubscriptionRow({
    super.key,
    required this.subscription,
    this.onToggle,
    this.onEdit,
    this.onRefresh,
    this.onPreview,
    this.onSeason,
    this.onDelete,
  });

  final SubscriptionView subscription;
  final ValueChanged<bool>? onToggle;
  final VoidCallback? onEdit;
  final VoidCallback? onRefresh;
  final VoidCallback? onPreview;
  final VoidCallback? onSeason;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final DsTokens t = context.ds;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
      decoration: BoxDecoration(
        color: t.raised,
        borderRadius: BorderRadius.circular(t.radiusCard),
        border: Border.all(color: t.line, width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  subscription.name,
                  style: TextStyle(
                    color: t.text,
                    fontSize: DsTypeScale.body,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              NeoSwitch(
                value: subscription.enabled,
                onChanged: onToggle,
                tooltip: subscription.enabled ? '已启用' : '已停用',
              ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: <Widget>[
              DsChip(label: subscription.sourceKindLabel, tone: t.accent2),
              DsChip(label: '规则 ${subscription.rules.length}'),
              DsChip(label: '刷新 ${subscription.refreshInterval.inMinutes} 分钟'),
              DsChip(
                label: subscription.lastRefreshAt == null
                    ? '从未刷新'
                    : '上次 ${formatRelative(subscription.lastRefreshAt)}',
              ),
              if (subscription.seededCount > 0)
                DsChip(
                  label: '首次已读 ${subscription.seededCount}',
                  tone: t.text3,
                  tooltip: '首次抓取只做已读标记，不倒灌历史剧集',
                ),
            ],
          ),
          const SizedBox(height: 8),
          // 第四十二轮 UX #46：订阅地址原来写死 `maxLines: 1` 且不能横向滚 ——
          // 而这是**唯一一处**用户真的要"核对全文"的地方（复制去浏览器/发给别人）。
          // 现在给两行 + 一颗「复制」按钮（复制拿到的是**完整**地址，跟屏幕截断无关）。
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Expanded(
                child: SelectableText(
                  subscription.feedUrl,
                  maxLines: 2,
                  style: TextStyle(
                      color: t.text3, fontSize: DsTypeScale.caption, height: 1.4),
                ),
              ),
              const SizedBox(width: 6),
              NeoIconButton(
                icon: Icons.copy_all_outlined,
                tooltip: '复制订阅地址（拿到的是完整地址）',
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: subscription.feedUrl));
                  if (context.mounted) {
                    showSuccess(context, '订阅地址已复制');
                  }
                },
              ),
            ],
          ),
          if (subscription.lastError != null) ...<Widget>[
            const SizedBox(height: 6),
            Text(
              '上次刷新失败：${subscription.lastError}',
              style: TextStyle(color: t.danger, fontSize: DsTypeScale.secondary),
            ),
          ],
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: <Widget>[
              NeoButton(label: '刷新', icon: Icons.refresh, onPressed: onRefresh, compact: true),
              NeoButton(
                label: '命中预览',
                icon: Icons.preview_outlined,
                onPressed: onPreview,
                compact: true,
              ),
              NeoButton(
                label: '全季入队',
                icon: Icons.playlist_add_check,
                onPressed: onSeason,
                compact: true,
              ),
              NeoButton(label: '编辑', icon: Icons.edit_outlined, onPressed: onEdit, compact: true),
              NeoButton(
                label: '删除',
                icon: Icons.delete_outline,
                kind: NeoButtonKind.danger,
                onPressed: onDelete,
                compact: true,
              ),
            ],
          ),
        ],
      ),
    );
  }
}
