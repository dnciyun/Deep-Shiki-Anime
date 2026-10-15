import 'package:flutter/material.dart';
import '../models/theme_tokens.dart';
import 'styled_track.dart';

String _fmt(Duration d) {
  String two(int n) => n.toString().padLeft(2, '0');
  final h = d.inHours, m = d.inMinutes % 60, s = d.inSeconds % 60;
  return h > 0 ? '${two(h)}:${two(m)}:${two(s)}' : '${two(m)}:${two(s)}';
}

/// 进度条 + 时间文字（`位置 / 总时长`，tabular figures）。
/// 悬停不做缩略图（契约 §8，B12：网流下会退化成顺序下载）。
class SeekBar extends StatefulWidget {
  final ThemeTokens tokens;
  final Duration position;
  final Duration duration;
  final ValueChanged<Duration> onSeek;

  /// 拖动开始(true)/结束(false)——外层据此在拖动期间挂起控制栏自动隐藏。
  final ValueChanged<bool>? onDragging;

  const SeekBar({
    super.key,
    required this.tokens,
    required this.position,
    required this.duration,
    required this.onSeek,
    this.onDragging,
  });

  @override
  State<SeekBar> createState() => _SeekBarState();
}

class _SeekBarState extends State<SeekBar> {
  bool _hover = false;
  double? _dragFraction; // 拖动中的进度分数 0..1
  final _barKey = GlobalKey();

  double _fractionAt(Offset globalPos) {
    final rb = _barKey.currentContext?.findRenderObject() as RenderBox?;
    if (rb == null || rb.size.width <= 0) return 0;
    final localX = rb.globalToLocal(globalPos).dx;
    return (localX / rb.size.width).clamp(0.0, 1.0);
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.tokens;
    final total = widget.duration.inMilliseconds <= 0 ? 1 : widget.duration.inMilliseconds;
    final posFraction = (widget.position.inMilliseconds / total).clamp(0.0, 1.0);
    final fraction = _dragFraction ?? posFraction;
    final shown = Duration(milliseconds: (fraction * total).round());
    final active = _hover || _dragFraction != null;

    return Row(
      children: [
        Expanded(
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            onEnter: (_) => setState(() => _hover = true),
            onExit: (_) => setState(() => _hover = false),
            child: TweenAnimationBuilder<double>(
              tween: Tween(begin: 0, end: active ? 1 : 0),
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOut,
              builder: (context, ht, _) => GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapDown: (d) {
                  final f = _fractionAt(d.globalPosition);
                  widget.onSeek(Duration(milliseconds: (f * total).round()));
                },
                onHorizontalDragStart: (d) {
                  widget.onDragging?.call(true);
                  setState(() => _dragFraction = _fractionAt(d.globalPosition));
                },
                onHorizontalDragUpdate: (d) {
                  setState(() => _dragFraction = _fractionAt(d.globalPosition));
                },
                onHorizontalDragEnd: (_) {
                  final f = _dragFraction;
                  setState(() => _dragFraction = null);
                  widget.onDragging?.call(false);
                  if (f != null) widget.onSeek(Duration(milliseconds: (f * total).round()));
                },
                onHorizontalDragCancel: () {
                  // 取消不落 seek，但必须清拖动态，否则进度显示会卡在拖动位置。
                  setState(() => _dragFraction = null);
                  widget.onDragging?.call(false);
                },
                child: SizedBox(
                  key: _barKey,
                  // 22 → 26：随控制栏一起调大（用户 2026-10-11 第六轮要求），
                  // 轨道更粗、拖动命中区更大，但仍是"贴边的一条细条"。
                  height: 26,
                  child: StyledTrack(
                    fraction: fraction,
                    accent: t.accent,
                    track: t.sunken,
                    thumbColor: t.raised,
                    hoverT: ht,
                  ),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(width: 10),
        Text(
          '${_fmt(shown)} / ${_fmt(widget.duration)}',
          maxLines: 1,
          softWrap: false,
          style: TextStyle(
            color: t.text,
            // 字号走 token：宿主调一处，播放窗口的文字整体跟着变（不再写死 12）。
            fontSize: t.fontSize,
            height: 1.0,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }
}
