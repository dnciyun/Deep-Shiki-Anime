import 'package:flutter/material.dart';
import '../models/subtitle_preset.dart';
import '../models/subtitle_style.dart';
import '../models/theme_tokens.dart';
import 'styled_track.dart';

/// 设置面板（极简）：**音量** 与 **字幕样式**（＋宿主给的样式预设）。
/// 主题/快捷键/文件关联/界面 Tab、播放结束行为、音量增强、附加按钮全部已删。
///
/// 音效（`audio-pack`）的配置**不在这里**：用户 2026-10-19 明确要求放到「扩展」页
/// （主窗口），见 `app/lib/ui/extensions_page.dart` 的音效区。
class SettingsPanel extends StatelessWidget {
  final ThemeTokens tokens;
  final double volume;
  final ValueChanged<double> onVolume;
  final SubtitleStyle subtitleStyle;
  final ValueChanged<SubtitleStyle> onSubtitleStyle;

  /// 宿主从扩展包扫出来的字幕样式预设；空 = 不显示「样式预设」这一区。
  final List<SubtitlePreset> presets;

  /// 预设的非致命提示（目前是「字体没加载上」）：显示在预设区下面，不挡预设。
  final List<String> presetNotes;

  /// 可选关闭按钮（宿主也可用 Esc / 点外部关闭）。
  final VoidCallback? onClose;

  const SettingsPanel({
    super.key,
    required this.tokens,
    required this.volume,
    required this.onVolume,
    required this.subtitleStyle,
    required this.onSubtitleStyle,
    this.presets = const <SubtitlePreset>[],
    this.presetNotes = const <String>[],
    this.onClose,
  });

  /// 按包名分组（保持 presets 原顺序；没有包名的归到空 key）。
  ///
  /// 为什么要在界面上分组：一个面可以装多个包，两个包都叫「影院大字」时，只看一排
  /// 同名按钮用户分不清来源 —— id 隔离是给代码的，分组是给人的。
  Map<String, List<SubtitlePreset>> _presetGroups() {
    final Map<String, List<SubtitlePreset>> groups = <String, List<SubtitlePreset>>{};
    for (final SubtitlePreset preset in presets) {
      (groups[preset.packName] ??= <SubtitlePreset>[]).add(preset);
    }
    return groups;
  }

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

              // ── 样式预设（宿主从扩展包扫出来的；没有就不显示这一区）──────
              if (presets.isNotEmpty) ...[
                _header(t, '样式预设', trailing: '${presets.length} 套'),
                SizedBox(height: t.spacing),
                for (final MapEntry<String, List<SubtitlePreset>> group
                    in _presetGroups().entries) ...[
                  if (group.key.isNotEmpty)
                    Padding(
                      padding: EdgeInsets.only(bottom: t.spacing / 2),
                      child: Text(
                        group.key,
                        style: TextStyle(
                          color: t.text3,
                          fontSize: t.fontSizeSmall,
                          height: 1.2,
                        ),
                      ),
                    ),
                  Wrap(
                    spacing: t.spacing,
                    runSpacing: t.spacing,
                    children: <Widget>[
                      for (final SubtitlePreset preset in group.value)
                        _PresetChip(
                          tokens: t,
                          preset: preset,
                          onTap: () => onSubtitleStyle(preset.style),
                        ),
                    ],
                  ),
                  SizedBox(height: t.spacing * 2),
                ],
                // 字体没加载上之类的非致命提示（预设照常可用，但要说清楚）。
                for (final String note in presetNotes)
                  Padding(
                    padding: EdgeInsets.only(bottom: t.spacing / 2),
                    child: Text(
                      note,
                      style: TextStyle(
                        color: t.text3,
                        fontSize: t.fontSizeSmall,
                        height: 1.35,
                      ),
                    ),
                  ),
                SizedBox(height: t.spacing * 3),
              ],

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

/// 一个字幕样式预设：凹槽底、点击即套用（扁平风格，颜色全取 token）。
class _PresetChip extends StatelessWidget {
  final ThemeTokens tokens;
  final SubtitlePreset preset;
  final VoidCallback onTap;

  const _PresetChip({required this.tokens, required this.preset, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final t = tokens;
    final Widget chip = MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          key: ValueKey<String>('subtitle-preset-${preset.id}'),
          padding: EdgeInsets.symmetric(horizontal: t.spacing * 1.5, vertical: t.spacing),
          decoration: BoxDecoration(
            color: t.sunken,
            borderRadius: BorderRadius.circular(t.radiusPill),
          ),
          child: Text(
            preset.name,
            style: TextStyle(color: t.text, fontSize: t.fontSizeSmall, height: 1.2),
          ),
        ),
      ),
    );
    if (preset.description.isEmpty) return chip;
    return Tooltip(message: preset.description, child: chip);
  }
}
