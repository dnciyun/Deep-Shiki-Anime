import 'package:flutter/material.dart';
import '../models/subtitle_style.dart';
import '../models/theme_tokens.dart';
import 'styled_track.dart';

/// 设置面板（极简）：只保留 **音量** 与 **字幕样式** 两组。
/// 主题/快捷键/文件关联/界面 Tab、播放结束行为、音量增强、附加按钮全部已删。
class SettingsPanel extends StatelessWidget {
  final ThemeTokens tokens;
  final double volume;
  final ValueChanged<double> onVolume;
  final SubtitleStyle subtitleStyle;
  final ValueChanged<SubtitleStyle> onSubtitleStyle;

  /// 可选关闭按钮（宿主也可用 Esc / 点外部关闭）。
  final VoidCallback? onClose;

  const SettingsPanel({
    super.key,
    required this.tokens,
    required this.volume,
    required this.onVolume,
    required this.subtitleStyle,
    required this.onSubtitleStyle,
    this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    final t = tokens;
    final s = subtitleStyle;
    return Container(
      width: 340,
      constraints: const BoxConstraints(maxHeight: 480),
      decoration: BoxDecoration(
        color: t.line.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(t.radiusCard),
      ),
      padding: const EdgeInsets.all(1),
      child: Container(
        decoration: BoxDecoration(
          color: t.raised,
          borderRadius: BorderRadius.circular(t.radiusCard - 1),
        ),
        child: SingleChildScrollView(
          padding: EdgeInsets.all(t.spacing * 2),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '设置',
                      style: TextStyle(color: t.text, fontSize: t.fontSize + 2, fontWeight: FontWeight.w600, height: 1.25),
                    ),
                  ),
                  if (onClose != null)
                    GestureDetector(
                      onTap: onClose,
                      child: MouseRegion(
                        cursor: SystemMouseCursors.click,
                        child: Icon(Icons.close_rounded, size: 18, color: t.iconColor),
                      ),
                    ),
                ],
              ),
              SizedBox(height: t.spacing * 2),

              // ── 音量 ─────────────────────────────────────────────────────
              _header(t, '音量', trailing: '${volume.round()}%'),
              SizedBox(height: t.spacing),
              _NeoSlider(
                tokens: t,
                value: (volume / 100).clamp(0.0, 1.0),
                onChanged: (v) => onVolume(v * 100),
              ),
              SizedBox(height: t.spacing * 3),

              // ── 字幕样式 ─────────────────────────────────────────────────
              _header(t, '字幕样式', trailing: '字号 ${s.scale.toStringAsFixed(1)}×'),
              SizedBox(height: t.spacing),
              _NeoSlider(
                tokens: t,
                value: ((s.scale - 0.5) / 1.5).clamp(0.0, 1.0),
                onChanged: (v) => onSubtitleStyle(s.copyWith(scale: 0.5 + v * 1.5)),
              ),
              SizedBox(height: t.spacing * 1.5),
              _row(
                t,
                label: '位置',
                value: '${s.pos}',
                child: _NeoSlider(
                  tokens: t,
                  value: (s.pos / 150).clamp(0.0, 1.0),
                  onChanged: (v) => onSubtitleStyle(s.copyWith(pos: (v * 150).round())),
                ),
              ),
              SizedBox(height: t.spacing * 1.5),
              _row(
                t,
                label: '描边',
                value: s.borderSize.toStringAsFixed(1),
                child: _NeoSlider(
                  tokens: t,
                  value: (s.borderSize / 6).clamp(0.0, 1.0),
                  onChanged: (v) => onSubtitleStyle(s.copyWith(borderSize: v * 6)),
                ),
              ),
              SizedBox(height: t.spacing * 1.5),
              Row(
                children: [
                  Expanded(child: _label(t, '粗体')),
                  _NeoSwitch(
                    tokens: t,
                    value: s.bold,
                    onChanged: (v) => onSubtitleStyle(s.copyWith(bold: v)),
                  ),
                ],
              ),
              SizedBox(height: t.spacing),
              Row(
                children: [
                  Expanded(child: _label(t, '斜体')),
                  _NeoSwitch(
                    tokens: t,
                    value: s.italic,
                    onChanged: (v) => onSubtitleStyle(s.copyWith(italic: v)),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _label(ThemeTokens t, String text) =>
      Text(text, style: TextStyle(color: t.text, fontSize: t.fontSize, height: 1.45));

  Widget _header(ThemeTokens t, String text, {String? trailing}) => Row(
        children: [
          Expanded(
            child: Text(text,
                style: TextStyle(color: t.text, fontSize: t.fontSize + 2, fontWeight: FontWeight.w600, height: 1.25)),
          ),
          if (trailing != null)
            Text(
              trailing,
              style: TextStyle(
                color: t.text2,
                fontSize: t.fontSizeSmall,
                height: 1.0,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
        ],
      );

  Widget _row(ThemeTokens t, {required String label, required String value, required Widget child}) => Row(
        children: [
          SizedBox(width: 44, child: _label(t, label)),
          Expanded(child: child),
          const SizedBox(width: 8),
          SizedBox(
            width: 32,
            child: Text(
              value,
              textAlign: TextAlign.right,
              style: TextStyle(
                color: t.text2,
                fontSize: t.fontSizeSmall,
                height: 1.0,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ],
      );
}

/// 极简滑杆：凹槽轨道 + 强调色填充（复用 StyledTrack，拖钮常驻）。
class _NeoSlider extends StatefulWidget {
  final ThemeTokens tokens;
  final double value;
  final ValueChanged<double> onChanged;
  const _NeoSlider({required this.tokens, required this.value, required this.onChanged});

  @override
  State<_NeoSlider> createState() => _NeoSliderState();
}

class _NeoSliderState extends State<_NeoSlider> {
  final _k = GlobalKey();

  double _fracAt(Offset g) {
    final rb = _k.currentContext?.findRenderObject() as RenderBox?;
    if (rb == null || rb.size.width <= 0) return 0;
    return (rb.globalToLocal(g).dx / rb.size.width).clamp(0.0, 1.0);
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.tokens;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (d) => widget.onChanged(_fracAt(d.globalPosition)),
        onHorizontalDragStart: (d) => widget.onChanged(_fracAt(d.globalPosition)),
        onHorizontalDragUpdate: (d) => widget.onChanged(_fracAt(d.globalPosition)),
        child: SizedBox(
          key: _k,
          height: 22,
          child: StyledTrack(
            fraction: widget.value.clamp(0.0, 1.0),
            accent: t.accent,
            track: t.sunken,
            thumbColor: t.raised,
            hoverT: 1,
          ),
        ),
      ),
    );
  }
}

/// 极简开关：凹槽轨道（开=强调色）+ 凸起圆钮。
class _NeoSwitch extends StatelessWidget {
  final ThemeTokens tokens;
  final bool value;
  final ValueChanged<bool> onChanged;
  const _NeoSwitch({required this.tokens, required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final t = tokens;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: () => onChanged(!value),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
          width: 40,
          height: 22,
          padding: const EdgeInsets.all(2),
          alignment: value ? Alignment.centerRight : Alignment.centerLeft,
          decoration: BoxDecoration(
            color: value ? t.accent : t.sunken,
            borderRadius: BorderRadius.circular(t.radiusPill),
          ),
          child: Container(
            width: 18,
            height: 18,
            decoration: BoxDecoration(
              color: t.raised,
              borderRadius: BorderRadius.circular(t.radiusPill),
            ),
          ),
        ),
      ),
    );
  }
}
