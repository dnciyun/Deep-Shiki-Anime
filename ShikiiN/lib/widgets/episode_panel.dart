/// 播放列表**右侧栏**（用户 2026-10-11：「播放列表太小了看不到集数了应该放在右边栏里」）。
///
/// 宿主按「同名同压制组」把同一部番、同一个字幕组的那几集组好推过来（契约 §9），
/// 播放器只负责**显示与选择**：列表里当前这一集高亮，点其它集交回宿主起播
/// （见 `episodeSelectProvider` 的说明 —— 跨种子时播放器自己没有 streamUrl）。
///
/// 为什么从"居中浮层"改成"右侧栏"：播放器是**弹窗**，真机上只有 462×260 逻辑像素，
/// 而旧浮层固定 380×460 —— 比窗口还大，被窗口边缘裁掉，用户看到的是"列表太小、
/// 看不到集数"。右侧栏**贴着窗口右边缘、撑满高度**，宽度按窗口宽度自适应
/// （`min(240, 60%)`），所以再小的窗口也看得见集号那一列。
///
/// 集号用**宿主算好的真实集号**（`MediaItem.episode`），拿不到才用下标兜底 ——
/// 列表里缺集时（只列出 8/9/10）用下标会显示成"第 2 集"，那是撒谎。
///
/// **行内排版（用户 2026-10-12 第十三轮）**：`[标题（左半，超 32 字截成 …）] [集号] [🔊]`。
/// 原来集号是**最左边**一个 36px 徽标、标题在它右边一路铺到行尾；用户播的 VCB 那种
/// 「一等集一个种子、标题就是文件名」的命名有一百多个字符，标题会把行占满，用户
/// 看到的就是「集数看不见」。现在标题先按字数截断、集号占**行中间**固定那一槽
/// （左右两个 Expanded 1:1），每一行的集号都在同一列，扫一眼就往下读完了。
library;

import 'package:flutter/material.dart';

import '../controllers/playlist_controller.dart' show EpisodeGroup;
import '../models/media_item.dart';
import '../models/theme_tokens.dart';

class EpisodePanel extends StatefulWidget {
  const EpisodePanel({
    super.key,
    required this.tokens,
    required this.group,
    required this.onSelect,
    required this.onClose,
    this.width,
    this.onWidthChanged,
  });

  final ThemeTokens tokens;

  /// 当前那组（宿主推过来的「同名同压制组」）。
  final EpisodeGroup group;

  final void Function(MediaItem item) onSelect;
  final VoidCallback onClose;

  /// 侧栏宽度；null = 自适应（`min(可用宽度, 默认宽度)`，默认宽度见 [_kDefaultPanelWidth]）。
  ///
  /// 用户 2026-10-11 第六轮：「播放列表改成可托大的，有些视频太长了，默认大小也稍微调大一些」——
  /// 所以侧栏现在**可以拖左边框改宽**（[_kResizeHandleWidth] 那条拖拽把柄），
  /// 拖出来的宽度由 [onWidthChanged] 报给宿主/播放面记住。
  final double? width;

  /// 用户拖大/拖小之后的宽度上报（null 宽度时不报）。
  final ValueChanged<double>? onWidthChanged;

  @override
  State<EpisodePanel> createState() => _EpisodePanelState();
}

/// 一行的高度（打开列表时用它把当前集滚到中间；第六轮 32 → 40）。
const double _kEpisodeRowHeight = 40;

/// 播放列表行里标题最多显示多少**字**（超出就截成 `…`，然后把集数露出来）。
///
/// 用户 2026-10-12 第十三轮原话：
/// > 「修改下播放列表逻辑，…放在中间，优先展示集数」
/// > 「全名 `[hyakuhuyu&VCB-Studio] Re Zero kara Hajimeru Isekai Seikatsu 3rd Season
/// > [51][Ma10p_1080p][x265_flac_aac].CHS.mp4`，会导致集数看不见，改成，
/// > 超出多少字数后变成...然后显示集数」
///
/// 为什么是 32：默认侧栏宽 300 逻辑像素，行里扣掉标题槽/集号槽/内边距之后标题大约
/// 只有半行宽；13px 字号下 32 个拉丁字符差不多就是上限，再长就一定把集数挤没
/// （那正是用户报的现象：VCB 这种「一等集一个种子、标题就是文件名」的命名，一个
/// 名字一百多个字符）。中文字符更宽，还会由 `TextOverflow.ellipsis` 再收一次 ——
/// 两道保险；集号那一槽是**固定宽度**，任何情况下都不会被标题挤掉。
const int kEpisodeTitleMaxChars = 32;

/// 按**字数**截断标题（超出部分换成 `…`）；不超过 [max] 时原样返回（去掉首尾空白）。
///
/// 用 runes（码点）而不是 `String.length`：后者按 UTF-16 码元数，会把一个增补平面汉字
/// 或 emoji 算成 2，截在中间就出半个字符。这里不做完整的 grapheme 分簇
/// （播放列表标题里不会出现 ZWJ 组合序列），够用且不引入新依赖。
String shortenEpisodeTitle(String label, {int max = kEpisodeTitleMaxChars}) {
  final String text = label.trim();
  if (max <= 0) return text;
  final List<int> runes = text.runes.toList(growable: false);
  if (runes.length <= max) return text;
  return '${String.fromCharCodes(runes.take(max))}…';
}

/// 侧栏默认宽度（逻辑像素）。
///
/// 用户 2026-10-11 第六轮要「默认大小也稍微调大一些」：原来上限 240 时，
/// `[Skymoon-Raws] 遭到流放的转生重骑士 / Tsuihou … - 08 [ViuTV][WEB-DL][CHT][1080p]`
/// 这种长标题在 240px 里只剩十来个字可见。默认 300 能把"番名 + 集号 + 一点区分度"看全，
/// 想更宽就拖左边框（最大 [_kMaxPanelWidth]）。
const double _kDefaultPanelWidth = 300;

/// 拖拽把柄宽度（侧栏左边缘那一条）。
const double _kResizeHandleWidth = 6;

/// 拖拽上下限：太窄看不见集号（210），太宽把画面挤没（520 或窗口的 70%）。
const double _kMinPanelWidth = 210;
const double _kMaxPanelWidth = 520;

class _EpisodePanelState extends State<EpisodePanel> {
  late final ScrollController _scroll = ScrollController(
    // 打开时直接停在**当前集**：用户是从这一集点进来的，列表跳回第 1 集反而要重找。
    initialScrollOffset: _initialOffset(),
  );

  /// 用户拖出来的宽度。null = 还没拖过，用默认宽度。
  double? _width;

  /// 拖拽把柄悬停（给个视觉反馈，否则用户不知道这条能拖）。
  bool _handleHover = false;

  double _initialOffset() {
    final int index = widget.group.currentIndex;
    // 视口高度这一层还不知道，按"让当前集上部留 3 行"估算；滚不过头由控制器兜底。
    return (index - 3).clamp(0, 1 << 20) * _kEpisodeRowHeight;
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  /// 当前该用的宽度：用户拖过就用拖出来的，否则按可用宽度取默认值（留出画面）。
  double _resolveWidth(double available) {
    final double max = (available * 0.7).clamp(_kMinPanelWidth, _kMaxPanelWidth);
    return (widget.width ?? _width ?? _kDefaultPanelWidth).clamp(_kMinPanelWidth, max);
  }

  @override
  Widget build(BuildContext context) {
    final ThemeTokens t = widget.tokens;
    final double sp = t.spacing;
    final EpisodeGroup group = widget.group;
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints c) {
        final double width = _resolveWidth(c.maxWidth);
        return Container(
          width: width,
          decoration: BoxDecoration(
            color: t.raised,
            // 只画左边一条极淡的分隔线（新拟态：靠面色分层，不用硬边框）。
            border: Border(left: BorderSide(color: t.line.withValues(alpha: 0.6))),
          ),
          child: Stack(
            children: <Widget>[
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  _Header(tokens: t, count: group.items.length, onClose: widget.onClose),
                  Expanded(
                    child: ListView.builder(
                      controller: _scroll,
                      // 底部留出控制栏的高度：控制栏画在侧栏上层（Stack 顺序），
                      // 不留白的话最后几行会被它压住、点不到。
                      padding: EdgeInsets.only(top: sp / 2, bottom: t.barHeight),
                      itemExtent: _kEpisodeRowHeight,
                      itemCount: group.items.length,
                      itemBuilder: (BuildContext context, int i) => _Row(
                        tokens: t,
                        item: group.items[i],
                        index: i,
                        current: i == group.currentIndex,
                        onTap: () => widget.onSelect(group.items[i]),
                      ),
                    ),
                  ),
                ],
              ),
              // 左边缘的拖拽把柄：往左拖 = 变宽（把柄贴着边框，鼠标形状是左右箭头）。
              Positioned(
                left: 0,
                top: 0,
                bottom: 0,
                width: _kResizeHandleWidth,
                child: MouseRegion(
                  cursor: SystemMouseCursors.resizeLeftRight,
                  onEnter: (_) => setState(() => _handleHover = true),
                  onExit: (_) => setState(() => _handleHover = false),
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onHorizontalDragUpdate: (DragUpdateDetails d) {
                      final double max = (c.maxWidth * 0.7).clamp(_kMinPanelWidth, _kMaxPanelWidth);
                      // 往左拖（dx < 0）= 拉宽，所以是**减** dx。
                      final double next =
                          ((_width ?? width) - d.delta.dx).clamp(_kMinPanelWidth, max);
                      setState(() => _width = next);
                      widget.onWidthChanged?.call(next);
                    },
                    child: ColoredBox(
                      // 悬停时给把柄一点强调色（不悬停就完全透明：
                      // 新拟态不画边框，常驻一条线会显得侧栏"多了个框"）。
                      color: _handleHover
                          ? t.accent.withValues(alpha: 0.35)
                          : Colors.transparent,
                      child: const SizedBox.expand(),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.tokens, required this.count, required this.onClose});

  final ThemeTokens tokens;
  final int count;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final double sp = tokens.spacing;
    return Container(
      padding: EdgeInsets.fromLTRB(sp * 1.25, sp * 0.75, sp * 0.5, sp * 0.75),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: tokens.line.withValues(alpha: 0.6))),
      ),
      child: Row(
        children: <Widget>[
          // 图标与两个字号都随 token 放大（用户 2026-10-11 第六轮：
          // 「标题栏控制栏全都调大些，包括控件文字」—— 播放列表表头也算这一条）。
          Icon(Icons.playlist_play_rounded, size: 19, color: tokens.text2),
          SizedBox(width: sp * 0.75),
          Expanded(
            child: Text(
              '播放列表',
              style: TextStyle(
                color: tokens.text,
                fontSize: tokens.fontSize + 1,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Text(
            '$count 集',
            style: TextStyle(color: tokens.text3, fontSize: tokens.fontSizeSmall),
          ),
          SizedBox(width: sp * 0.5),
          _IconTap(
            tokens: tokens,
            icon: Icons.close_rounded,
            tooltip: '收起列表',
            onTap: onClose,
          ),
        ],
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({
    required this.tokens,
    required this.item,
    required this.index,
    required this.current,
    required this.onTap,
  });

  final ThemeTokens tokens;
  final MediaItem item;
  final int index;
  final bool current;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    // 列表里显示**文件名/标题**（宿主填的是这一集的标题）：集号由宿主的解析器负责，
    // 播放器不重新解析标题（否则同一集在两处显示不一样）。
    //
    // 标题先按字数截断（见 [kEpisodeTitleMaxChars]）：用户的真实命名有一百多个字符，
    // 不截的话它会把右侧的集数整段吃掉 —— 「会导致集数看不见」就是这么来的。
    final String raw = item.title.trim().isEmpty ? item.path : item.title.trim();
    final String label = shortenEpisodeTitle(raw);
    final int? episode = item.episode;
    // 集数：宿主给了真实集号就用它；没有才用下标兜底（缺集时下标会撒谎，但总比空着强）。
    final String episodeText = episode == null ? '${index + 1}' : '$episode';
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: current ? null : onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          color: current ? tokens.sunken : Colors.transparent,
          child: Row(
            children: <Widget>[
              // 标题占左半边（超长再 ellipsis 兜底一次）。
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: current ? tokens.text : tokens.text2,
                    fontSize: tokens.fontSize,
                    fontWeight: current ? FontWeight.w600 : FontWeight.w400,
                  ),
                ),
              ),
              const SizedBox(width: 6),
              // 集号徽标：**行中间那一槽就是用户要看的"集数"**（用户第十三轮：
              // 「…放在中间，优先展示集数」）。宽度固定 + 等宽数字，所以
              // **每一行的集号都在同一个位置**，顺着往下一列就能读完；
              // 它左右两个 Expanded 是 1:1，于是这一槽正好落在行的中间。
              SizedBox(
                width: 46,
                child: Container(
                  height: 24,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: current ? tokens.accent.withValues(alpha: 0.18) : tokens.sunken,
                    borderRadius: BorderRadius.circular(tokens.radiusControl),
                  ),
                  child: Text(
                    episodeText,
                    style: TextStyle(
                      color: current ? tokens.accent : tokens.text2,
                      fontSize: tokens.fontSize,
                      fontWeight: current ? FontWeight.w700 : FontWeight.w500,
                      fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
                    ),
                  ),
                ),
              ),
              // 右半边：只在当前行放一个"正在播"的喇叭，其余留白
              //（留白是刻意的：集号要落在中间，就不能让标题一路铺到右边）。
              Expanded(
                child: current
                    ? Align(
                        alignment: Alignment.centerRight,
                        child: Icon(Icons.volume_up_rounded, size: 16, color: tokens.accent),
                      )
                    : const SizedBox.shrink(),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _IconTap extends StatelessWidget {
  const _IconTap({
    required this.tokens,
    required this.icon,
    required this.onTap,
    this.tooltip,
  });

  final ThemeTokens tokens;
  final IconData icon;
  final VoidCallback onTap;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final Widget button = MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            color: tokens.sunken,
            borderRadius: BorderRadius.circular(tokens.radiusControl),
          ),
          child: Icon(icon, size: 17, color: tokens.text2),
        ),
      ),
    );
    final String? tip = tooltip;
    if (tip == null || tip.isEmpty) return button;
    return Tooltip(message: tip, child: button);
  }
}
