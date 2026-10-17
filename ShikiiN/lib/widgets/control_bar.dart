import 'package:flutter/material.dart';
import '../models/theme_tokens.dart';
import 'app_icon_button.dart';
import 'seek_bar.dart';
import 'styled_track.dart';

/// 控制栏（契约 §8）：播放/暂停 · 进度条+时间 · 上一集 · 下一集 · 音量 · 超分胶囊 · 全屏。
/// 无主题 resolver、无附加按钮、无画中画精简模式、无音量增强。
///
/// ⚠️ **第二十六轮**（用户：「播放器的下一集应该在上一集的右边」）：上一集/下一集**并排**
/// 放在进度条的**右侧**（`上一集` 在左、`下一集` 在右），中间不再隔着进度条。
/// 旧摆法是 `播放/暂停 · 上一集 · 进度条 · 下一集`——两颗切集键被进度条劈成左右两半，
/// 「上一集」孤零零挂在左端，看起来不像一对相邻的键。现在两颗贴在一起，
/// 「右边那颗 = 下一集」这个方向就成立了。
class ControlBar extends StatelessWidget {
  final ThemeTokens tokens;
  final bool playing;
  final Duration position;
  final Duration duration;
  final double volume;
  final VoidCallback onPlayPause;
  final VoidCallback onFullscreen;
  final ValueChanged<Duration> onSeek;
  final ValueChanged<double> onVolume;

  /// 进度/音量条拖动开始(true)/结束(false)——外层据此挂起自动隐藏。
  final ValueChanged<bool>? onBarDragging;

  /// null = 没有剧集组，按钮隐藏。
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;

  /// 「播放列表」按钮：宿主按「同名同压制组」组出来的那一组（用户 2026-10-11
  /// 「我要的播放列表为什么没有」）。null = 没有组信息（单集播放）→ 按钮隐藏。
  final VoidCallback? onPlaylist;

  /// 超分胶囊文案（如 `超分 标` / `超分 EWA锐`）。null = 宿主未注入超分 provider → 胶囊隐藏。
  final String? upscaleLabel;

  /// 胶囊是否处于开启态（只影响着色）。
  final bool? upscaleOn;

  /// 点一下循环切「关 → Anime4K 三档 → 其他实时方案 → 关」。
  final VoidCallback onCycleUpscale;

  const ControlBar({
    super.key,
    required this.tokens,
    required this.playing,
    required this.position,
    required this.duration,
    required this.volume,
    required this.onPlayPause,
    required this.onFullscreen,
    required this.onSeek,
    required this.onVolume,
    this.onBarDragging,
    this.onPrevious,
    this.onNext,
    this.onPlaylist,
    this.upscaleLabel,
    this.upscaleOn,
    required this.onCycleUpscale,
  });

  @override
  Widget build(BuildContext context) {
    final t = tokens;
    // 控制栏高度（用户 2026-10-11 第六轮：「控制栏全都调大些」）：
    // 宿主 `DsTokens.controlHeight` 36 → 44，图标按比例缩放（0.5/0.56 → 0.58/0.64），
    // 于是按钮的**命中区**从 36×36 涨到 44×44，肉眼看着也宽了一圈。
    final h = t.controlHeight;
    final face = t.raised;

    return ColoredBox(
      // 贴边停靠的整条控制栏：**直角**，跟顶部标题栏同一种"方条"语言。
      // 原来这里是 `ClipRRect(borderRadius: vertical(top: radiusCard))`，用户
      // 2026-10-10 要求「进度条那一栏的内圆角去掉」—— 顶角圆了会让它看起来像
      // 一张浮在画面上的卡片，而不是贴在窗口底边的一条栏。
      color: face,
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: t.spacing, vertical: t.spacing / 2),
        child: SizedBox(
          height: h,
          child: Row(
            children: [
              AppIconButton(
                key: const Key('btn_playPause'),
                id: playing ? AppIconId.pause : AppIconId.playPause,
                tooltip: playing ? '暂停' : '播放',
                size: h,
                iconSize: h * 0.64,
                radius: t.radiusControl,
                color: t.iconColor,
                onPressed: onPlayPause,
              ),
              SizedBox(width: t.spacing),
              // 进度条 + 时间（位置 / 总时长）
              Expanded(
                child: SeekBar(
                  tokens: t,
                  position: position,
                  duration: duration,
                  onSeek: onSeek,
                  onDragging: onBarDragging,
                ),
              ),
              SizedBox(width: t.spacing),
              // 「上一集 · 下一集」挨在一起放在进度条右边（第二十六轮，见类文档）：
              // 两颗都判 null 隐藏而不是禁用（契约 §9），到边界时对应的那颗消失。
              if (onPrevious != null)
                AppIconButton(
                  key: const Key('btn_prev'),
                  id: AppIconId.prev,
                  tooltip: '上一集',
                  size: h,
                  iconSize: h * 0.58,
                  radius: t.radiusControl,
                  color: t.iconColor,
                  onPressed: onPrevious!,
                ),
              if (onNext != null)
                AppIconButton(
                  key: const Key('btn_next'),
                  id: AppIconId.next,
                  tooltip: '下一集',
                  size: h,
                  iconSize: h * 0.58,
                  radius: t.radiusControl,
                  color: t.iconColor,
                  onPressed: onNext!,
                ),
              SizedBox(width: t.spacing),
              // 音量条（上限固定 100%，音量增强已删）
              SizedBox(
                // 78 → 100：控制栏整体变大后，音量条太短会显得"没长齐"，
                // 而且滑块本来就该有更长的拖动行程。
                width: 100,
                child: _VolumeBar(
                  value: volume,
                  accent: t.accent,
                  track: t.sunken,
                  thumb: t.raised,
                  onChanged: onVolume,
                  onDragging: onBarDragging,
                ),
              ),
              SizedBox(width: t.spacing),
              if (upscaleLabel != null)
                _UpscalePill(
                  tokens: t,
                  label: upscaleLabel!,
                  on: upscaleOn ?? false,
                  onTap: onCycleUpscale,
                ),
              if (onPlaylist != null)
                AppIconButton(
                  key: const Key('btn_playlist'),
                  id: AppIconId.playlist,
                  tooltip: '播放列表',
                  size: h,
                  iconSize: h * 0.64,
                  radius: t.radiusControl,
                  color: t.iconColor,
                  onPressed: onPlaylist!,
                ),
              AppIconButton(
                key: const Key('btn_fullscreen'),
                id: AppIconId.fullscreen,
                tooltip: '全屏',
                size: h,
                iconSize: h * 0.64,
                radius: t.radiusControl,
                color: t.iconColor,
                onPressed: onFullscreen,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 超分胶囊：点一下循环切「关 → Anime4K 三档 → 其他实时方案 → 关」。
///
/// 2026-10-17 方案制：文案由调用方给（`超分 关` / `超分 标` / `超分 EWA锐`），
/// 这里只管显示与点击，不再自己映射 Anime4K 档位。
class _UpscalePill extends StatefulWidget {
  final ThemeTokens tokens;
  final String label;
  final bool on;
  final VoidCallback onTap;
  const _UpscalePill({
    required this.tokens,
    required this.label,
    required this.on,
    required this.onTap,
  });

  @override
  State<_UpscalePill> createState() => _UpscalePillState();
}

class _UpscalePillState extends State<_UpscalePill> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final t = widget.tokens;
    final on = widget.on;
    final bg = on ? t.accent : t.sunken;
    final fg = on ? t.raised : t.text2;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          key: const Key('upscalePill'),
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeOut,
          height: t.controlHeight * 0.72,
          padding: EdgeInsets.symmetric(horizontal: t.spacing * 1.5),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: on
                ? (_hover ? Color.lerp(bg, t.text, 0.12) ?? bg : bg)
                : (_hover ? Color.lerp(bg, t.text, 0.06) ?? bg : bg),
            borderRadius: BorderRadius.circular(t.radiusPill),
          ),
          child: Text(
            widget.label,
            maxLines: 1,
            softWrap: false,
            // 字号走 token（用户 2026-10-11 第六轮：「包括控件文字」）。
            style: TextStyle(color: fg, fontSize: t.fontSize, height: 1.0),
          ),
        ),
      ),
    );
  }
}

/// 音量条：与进度条同一视觉（凹槽轨道 + 强调色填充），0..100。
class _VolumeBar extends StatefulWidget {
  final double value;
  final Color accent;
  final Color track;
  final Color thumb;
  final ValueChanged<double> onChanged;
  final ValueChanged<bool>? onDragging;
  const _VolumeBar({
    required this.value,
    required this.accent,
    required this.track,
    required this.thumb,
    required this.onChanged,
    this.onDragging,
  });

  @override
  State<_VolumeBar> createState() => _VolumeBarState();
}

class _VolumeBarState extends State<_VolumeBar> {
  bool _hover = false;
  final _k = GlobalKey();

  double _fracAt(Offset g) {
    final rb = _k.currentContext?.findRenderObject() as RenderBox?;
    if (rb == null || rb.size.width <= 0) return 0;
    return (rb.globalToLocal(g).dx / rb.size.width).clamp(0.0, 1.0);
  }

  void _apply(Offset g) => widget.onChanged(_fracAt(g) * 100);

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: _hover ? 1 : 0),
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
        builder: (context, ht, _) => GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (d) => _apply(d.globalPosition),
          onHorizontalDragStart: (d) {
            widget.onDragging?.call(true);
            _apply(d.globalPosition);
          },
          onHorizontalDragUpdate: (d) => _apply(d.globalPosition),
          onHorizontalDragEnd: (_) => widget.onDragging?.call(false),
          onHorizontalDragCancel: () => widget.onDragging?.call(false),
          child: SizedBox(
            key: _k,
            // 20 → 24：随控制栏一起放大（音量条命中区）。
            height: 24,
            child: StyledTrack(
              fraction: (widget.value / 100).clamp(0.0, 1.0),
              accent: widget.accent,
              track: widget.track,
              thumbColor: widget.thumb,
              hoverT: ht,
            ),
          ),
        ),
      ),
    );
  }
}
