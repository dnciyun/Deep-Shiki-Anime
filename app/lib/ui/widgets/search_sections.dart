/// 搜索结果表格（搜索页唯一的内容块）。
///
/// 用户 2026-10-10 第 3 轮问答：原来的另外两块 —— 顶部「继续观看」横排与底部
/// 「订阅更新」面板 —— 都已删除（前者属于主页，后者「订阅」页已经有一份），
/// 连带它们的 widget 一起删掉，不留死代码。
///
/// 视觉（新拟态规范 `docs/specs/2026-10-10-dsanima-neo-theme.md`）：
/// 表格按决策 A43：**无斑马纹、无竖线**，表头 11px + 字距，行分隔用 `t.divider` 极淡线，
/// 行悬停铺 `t.sunken` 半透明底。
///
/// 列序：番名 / 大小 / 状态 / 操作 —— 用户 2026-10-11「把做种数去掉」，
/// 规范 §21 的 5 列再砍一列（做种数属于**源的元数据**，对"能不能播"没有决定性，
/// 却占了一个会随刷新乱跳的列宽）。
library;

import 'package:flutter/material.dart';

import '../../domain/aggregate.dart';
import '../../domain/batch_download.dart';
import '../../domain/format.dart';
import '../../domain/models.dart';
import '../../theme/motion.dart';
import '../../theme/tokens.dart';
import 'ds_spinner.dart';
import 'ds_stagger.dart';
import 'neo.dart';

// ─────────────────────────────────────────────────────────────────────────────
// 搜索结果表格
// ─────────────────────────────────────────────────────────────────────────────

class SearchResultsTable extends StatelessWidget {
  const SearchResultsTable({
    super.key,
    required this.items,
    required this.engineConnected,
    this.busyItemId,
    this.onPlay,
    this.onDownload,
    this.onSubscribe,
    this.selectedIds = const <String>{},
    this.onToggleSelect,
    this.onToggleSelectAll,
    this.sources = const <SourceOption>[],
    this.marksOf,
    this.groupActionLabel,
    this.onGroupAction,
    this.embedded = false,
    this.showHeader = true,
    this.selectAllScope,
  });

  final List<SourceItemView> items;
  final bool engineConnected;
  final String? busyItemId;
  final void Function(SourceItemView item)? onPlay;
  final void Function(SourceItemView item)? onDownload;
  final void Function(SourceItemView item)? onSubscribe;

  /// 已知的源表：用来把结果行里那个 `sourceId` 翻成**人看的名字**
  /// （第四十二轮 UX #16：以前直接打印 `mikan` / `rss:8f3a…` 这种内部 id）。
  final List<SourceOption> sources;

  /// 批量下载勾选（用户 2026-10-12 第二十三轮：「搜索页批量选择下载」）。
  ///
  /// 传了 [onToggleSelect] 才会画出勾选列 —— 别的调用方（旧测试/别的页面）
  /// 不传就还是原来那张表。
  final Set<String> selectedIds;
  final void Function(SourceItemView item)? onToggleSelect;

  /// 表头那颗勾：true = 勾上本页**可下载的**全部，false = 取消本页勾选。
  final void Function(bool select)? onToggleSelectAll;

  /// 每一行**额外**的小标记（第四十五轮：动漫库的种子块要在这里显示
  /// 「已看过 / 已在队列 / 已完成」）。不传 = 一个都不画，搜索页行为一字不变。
  final List<Widget> Function(SourceItemView item)? marksOf;

  /// 右键菜单里那一条**额外**动作的文字（app 自己算，因为"这一组有几集"只有它有上下文）。
  final String Function(SourceItemView item)? groupActionLabel;

  /// 那一条动作要干什么（第四十五轮：动漫库种子块的「这一组都入队（N 集）」）。
  final void Function(SourceItemView item)? onGroupAction;

  /// **嵌进别人的滚动页**（第四十五轮：动漫库详细页是 `ListView(children:)`，
  /// 高度无界）时为 true —— 行不再塞进 `Expanded(ListView)`，而是直接排成一列。
  /// 默认 false = 搜索页那种"自己占满剩余高度、自己滚"的形态，行为一字不变。
  final bool embedded;

  /// 画不画那一行表头（默认画）。
  ///
  /// 第四十八轮：动漫库种子块按字幕组分成了**好几张小表**，列宽都一样，
  /// 所以只在第一张上面画一次表头 —— 每段都来一行「番名 / 大小 / 状态 / 操作」
  /// 只会把版面切碎。
  final bool showHeader;

  /// 表头那颗勾说的"本页"是哪些条目（默认 = [items]）。
  ///
  /// 为什么要单独一个参数：分了段之后每一张表只装一段，而"全选本页"说的是
  /// **整块露出来的那些**（调用方也是按整块去勾的）—— 不传它，勾选状态就会
  /// 只看第一段，全勾满了还显示没勾。动作本身仍由 [onToggleSelectAll] 决定。
  final List<SourceItemView>? selectAllScope;

  // 列宽（表头用 `dsTableHeaderStyle`；数字列 tabular）。
  //
  // 用户 2026-10-10 第 1 轮问答：9 列砍到 **5 列**——
  // 「集数 / 画质 / 字幕 / 字幕组」并进番名那一列的副行（它们都是**这一条的属性**，
  // 各占一列只会把番名挤到没地方显示）。
  //
  // 2026-10-11 第六轮两处变化叠加：
  // * 「把做种数去掉」→ 做种列（原 48）删掉，现在 **4 列**；
  // * 字号阶梯整体上调（表头 11→12、正文 12→14）→ 数字/状态列都要跟着放宽。
  // 让出来的宽度给状态列：「引擎未连接」比原来的「可播 / 无种子」长，不给够会截成省略号。
  static const double _wSize = 84;
  static const double _wStatus = 88;
  static const double _wActions = 118;

  /// 勾选列宽（只在 [onToggleSelect] 非空时占位）。
  static const double _wSelect = 30;

  @override
  Widget build(BuildContext context) {
    final DsTokens t = context.ds;
    final TextStyle hs = dsTableHeaderStyle(t);
    final List<SourceItemView> scope = selectAllScope ?? items;
    final List<SourceItemView> selectable = <SourceItemView>[
      for (final SourceItemView item in scope)
        if (canBatchDownload(item)) item,
    ];
    final bool allSelected =
        selectable.isNotEmpty && selectable.every((SourceItemView i) => selectedIds.contains(i.id));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        // 表头：无斑马纹、无竖线，只用一条极淡分隔（决策 A43）。
        if (showHeader)
          Container(
          padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
          decoration: BoxDecoration(
            color: t.raised,
            border: Border(bottom: BorderSide(color: t.divider)),
          ),
          child: Row(
            children: <Widget>[
              if (onToggleSelect != null)
                SizedBox(
                  width: _wSelect,
                  child: _SelectBox(
                    selected: allSelected,
                    enabled: selectable.isNotEmpty && onToggleSelectAll != null,
                    tooltip: allSelected
                        ? '取消本页勾选'
                        : '全选本页（${selectable.length} 条可下载）',
                    onPressed: () => onToggleSelectAll?.call(!allSelected),
                  ),
                ),
              Expanded(child: Text('番名', style: hs)),
              SizedBox(
                width: _wSize,
                child: Text('大小', style: hs),
              ),
              SizedBox(
                width: _wStatus,
                child: Text('状态', style: hs),
              ),
              SizedBox(
                width: _wActions,
                child: Text('操作', style: hs),
              ),
            ],
          ),
        ),
        if (embedded)
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              for (int i = 0; i < items.length; i++)
                DsStaggerFade(index: i, child: _row(context, i, items[i])),
            ],
          )
        else
          Expanded(
            child: ListView.builder(
              padding: EdgeInsets.zero,
              itemCount: items.length,
              itemBuilder: (BuildContext context, int index) => DsStaggerFade(index: index, child: _row(context, index, items[index])),
            ),
          ),
      ],
    );
  }

  Widget _row(BuildContext context, int index, SourceItemView item) {
    final DsTokens t = context.ds;
    // 状态列只看"这条能不能播"：有没有磁力/直链 + 引擎在不在。
    // 做种数不再参与判断（用户 2026-10-11 把做种数从界面上去掉）：nyaa 之外的源
    // （mikan 的 RSS 等）本来就不给做种数，拿它当"无种子"的依据，会把 `seeders == null`
    // 的可播条目误判成不能播 —— 状态列说的事必须只由"这条有没有源 + 引擎通不通"决定。
    final (String statusText, Color statusColor) = !item.canDownload
        ? ('无磁力链', t.warning)
        : !item.hasTorrentSource
            ? ('需补链', t.text2)
            : !engineConnected
                ? ('引擎未连接', t.danger)
                : ('可播', t.success);
    // 番名的副行：集数 / 画质 / 字幕 / 字幕组 / 合集 —— 只显示真有的字段。
    final List<String> facts = <String>[
      ...item.episodeHints,
      if ((item.resolution ?? '').trim().isNotEmpty) item.resolution!.trim(),
      if ((item.subtitleLang ?? '').trim().isNotEmpty) item.subtitleLang!.trim(),
      if ((item.group ?? '').trim().isNotEmpty) item.group!.trim(),
      if (item.isBatch) '合集',
    ];
    return _HoverFill(
      builder: (bool hover) => GestureDetector(
        // 用户 2026-10-10 第 3 轮问答：「加入订阅过滤」从操作列收进**右键菜单**
        //（它与"播放/下载"不同，是低频动作；三颗图标并排太密）。
        onSecondaryTapDown:
            onSubscribe == null && (onGroupAction == null || groupActionLabel == null)
            ? null
            : (TapDownDetails d) => _showRowMenu(context, d.globalPosition, item),
        // 行悬停 = 沉一档的凹槽面（规范 §2：状态用**面色**表达，不用几何）。
        // 第三十轮：原来在 `sunken` 上手混 60% 透明度（调色板里没有这个色），
        // 而且 setState 直换 —— 现在交给 `DsMotion.hover`（90ms）插值。
        child: AnimatedContainer(
          duration: DsMotion.of(context).hover,
          curve: DsMotion.hoverCurve,
          padding: const EdgeInsets.fromLTRB(10, 7, 10, 7),
          decoration: BoxDecoration(
            color: hover ? t.sunken : null,
            border: Border(bottom: BorderSide(color: t.divider)),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              if (onToggleSelect != null)
                SizedBox(
                  width: _wSelect,
                  child: Padding(
                    padding: const EdgeInsets.only(top: 1),
                    child: _SelectBox(
                      selected: selectedIds.contains(item.id),
                      enabled: canBatchDownload(item),
                      tooltip: canBatchDownload(item)
                          ? (selectedIds.contains(item.id)
                                ? '取消勾选（批量下载只处理勾上的）'
                                : '勾上：可以和其他条一起批量下载')
                          : '这条既没有磁力/直链，也没有详情页可补链，不能下载',
                      onPressed: canBatchDownload(item) ? () => onToggleSelect!(item) : null,
                    ),
                  ),
                ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      item.displayTitle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: t.text, fontSize: DsTypeScale.secondary, height: 1.3),
                    ),
                    const SizedBox(height: 3),
                    Row(
                      children: <Widget>[
                        Flexible(
                          child: Text(
                            <String>[
                              // 第四十二轮 UX #16：显示源名，不是 `mikan` / `rss:8f3a…`。
                              sourceLabelFor(item.sourceId, sources),
                              formatRelative(item.publishedAt),
                              ...facts,
                            ].join(' · '),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(color: t.text3, fontSize: DsTypeScale.caption),
                          ),
                        ),
                        // 第四十五轮：额外的状态标记（已看过 / 在队列 / 已完成）。
                        // 放在这一行的尾部而不是另起一行：行高不变，表格不会变"毛"。
                        if (marksOf?.call(item) case final List<Widget> marks
                            when marks.isNotEmpty) ...<Widget>[
                          const SizedBox(width: 6),
                          ...marks,
                        ],
                      ],
                    ),
                  ],
                ),
              ),
              SizedBox(
                width: _wSize,
                child: Text(
                  formatBytes(item.sizeBytes),
                  style: TextStyle(
                    color: t.text2,
                    fontSize: DsTypeScale.caption,
                    fontFeatures: DsTokens.tabular,
                  ),
                ),
              ),
              // 做种列（NeoDot + 数字）已按用户 2026-10-11「把做种数去掉」删除；
              // 源的 `seeders` 字段仍在数据层保留（订阅过滤/排序还要用），只是不再上屏。
              SizedBox(
                width: _wStatus,
                child: Text(
                  statusText,
                  style: TextStyle(color: statusColor, fontSize: DsTypeScale.caption),
                ),
              ),
              SizedBox(
                width: _wActions,
                child: busyItemId == item.id
                    // 点了「立即播放」到窗口出来之间的行内加载：iOS 风格小圆环
                    // （14px / 无底轨，用户 2026-10-12 第八轮要求三处统一）。
                    ? const Padding(
                        padding: EdgeInsets.only(left: 8),
                        child: DsSpinner.inline(),
                      )
                    : Row(
                        children: <Widget>[
                          NeoIconButton(
                            icon: Icons.play_arrow,
                            tooltip: '立即播放（边下边播）',
                            size: 26,
                            color: item.canDownload ? t.accent : t.text3,
                            onPressed: onPlay == null ? null : () => onPlay!(item),
                          ),
                          const SizedBox(width: 2),
                          NeoIconButton(
                            icon: Icons.download,
                            tooltip: '下载（不进播放器）',
                            size: 26,
                            onPressed: onDownload == null ? null : () => onDownload!(item),
                          ),
                        ],
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 行右键菜单：「加入订阅过滤」+ 调用方额外给的那一条（低频动作，从操作列挪到这里）。
  Future<void> _showRowMenu(BuildContext context, Offset at, SourceItemView item) async {
    final void Function(SourceItemView)? subscribe = onSubscribe;
    final void Function(SourceItemView)? groupAction = onGroupAction;
    final String? groupLabel = groupActionLabel?.call(item);
    final bool hasGroup = groupAction != null && groupLabel != null;
    if (subscribe == null && !hasGroup) return;
    final DsTokens t = context.ds;
    final String? choice = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(at.dx, at.dy, at.dx, at.dy),
      color: t.raised,
      items: <PopupMenuEntry<String>>[
        if (subscribe != null)
          PopupMenuItem<String>(
            value: 'subscribe',
            child: Row(
              children: <Widget>[
                Icon(Icons.playlist_add, size: 15, color: t.text2),
                const SizedBox(width: 8),
                const Text('加入订阅过滤'),
              ],
            ),
          ),
        if (hasGroup)
          PopupMenuItem<String>(
            value: 'group',
            child: Row(
              children: <Widget>[
                Icon(Icons.playlist_play, size: 15, color: t.text2),
                const SizedBox(width: 8),
                Text(groupLabel),
              ],
            ),
          ),
      ],
    );
    if (choice == 'subscribe') subscribe?.call(item);
    if (choice == 'group') groupAction?.call(item);
  }
}

/// 勾选框（批量下载用）：新拟态图标按钮，勾上 = `check_box` + accent 色。
///
/// 不用 Material `Checkbox`：那个控件自带一圈边距与默认主题色，
/// 与表格行里「图标按钮」的既有形态（`NeoIconButton`）不是一套。
class _SelectBox extends StatelessWidget {
  const _SelectBox({
    required this.selected,
    required this.enabled,
    required this.tooltip,
    required this.onPressed,
  });

  final bool selected;
  final bool enabled;
  final String tooltip;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return NeoIconButton(
      icon: selected ? Icons.check_box : Icons.check_box_outline_blank,
      size: 22,
      selected: selected,
      color: !enabled ? context.ds.text3 : null,
      tooltip: tooltip,
      onPressed: enabled ? onPressed : null,
    );
  }
}

/// 行悬停探测（决策 A43 的「悬停行」）：只负责把 hover 状态交给 [builder]，
/// 行本身仍然是无状态的一段 Row。
class _HoverFill extends StatefulWidget {
  const _HoverFill({required this.builder});

  final Widget Function(bool hovered) builder;

  @override
  State<_HoverFill> createState() => _HoverFillState();
}

class _HoverFillState extends State<_HoverFill> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) => MouseRegion(
    onEnter: (_) => setState(() => _hover = true),
    onExit: (_) => setState(() => _hover = false),
    child: widget.builder(_hover),
  );
}
