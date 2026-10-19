/// 设置面板里的「音效」区：当前档 + 频响曲线 + 档位列表 + 两个全局强度。
///
/// 为什么配置放这里而不是主窗口的扩展页：播放窗口是独立 Flutter 引擎，主窗口读不到
/// 这里的运行状态（用户 2026-10-19 定的入口是「右键 + 扩展的配置」，与字幕样式预设
/// 同一处落地；扩展页只显示「装了什么」）。
library;

import 'package:flutter/material.dart';

import '../models/audio_fx.dart';
import '../models/theme_tokens.dart';

/// 「音效」区：空包时调用方不该渲染它（这一项在没装包时整个不出现）。
class AudioFxSection extends StatelessWidget {
  const AudioFxSection({
    super.key,
    required this.tokens,
    required this.presets,
    required this.state,
    required this.onPreset,
    required this.onCompression,
    required this.onLoudness,
  });

  final ThemeTokens tokens;
  final List<AudioFxPreset> presets;
  final AudioFxState state;

  /// `null` = 原声（关总开关）。
  final ValueChanged<String?> onPreset;
  final ValueChanged<int> onCompression;
  final ValueChanged<int> onLoudness;

  AudioFxPreset? get _current {
    if (!state.enabled) return null;
    for (final AudioFxPreset preset in presets) {
      if (preset.id == state.presetId) return preset;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final ThemeTokens t = tokens;
    final AudioFxPreset? current = _current;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: Text(
                '音效',
                style: TextStyle(
                  color: t.text,
                  fontSize: t.fontSize + 2,
                  fontWeight: FontWeight.w600,
                  height: 1.25,
                ),
              ),
            ),
            Text(
              current == null ? '原声' : current.name,
              style: TextStyle(color: t.text2, fontSize: t.fontSizeSmall, height: 1.0),
            ),
          ],
        ),
        SizedBox(height: t.spacing),
        // 频响曲线：10 个点按对数频率等间距画（31Hz → 16kHz）。
        SizedBox(
          height: 64,
          child: CustomPaint(
            painter: AudioFxCurvePainter(
              bands: <String, double>{
                for (final String band in kAudioFxBands)
                  band: current?.bands[band] ?? 0,
              },
              line: t.accent,
              grid: t.line,
            ),
            child: const SizedBox.expand(),
          ),
        ),
        SizedBox(height: t.spacing),
        Wrap(
          spacing: t.spacing,
          runSpacing: t.spacing,
          children: <Widget>[
            _chip(t, '原声',
                key: const ValueKey<String>('audio-fx-off'),
                selected: state.enabled == false, onTap: () => onPreset(null)),
            for (final AudioFxPreset preset in presets)
              _chip(
                t,
                preset.name,
                key: ValueKey<String>('audio-fx-preset-${preset.id}'),
                selected: state.enabled && state.presetId == preset.id,
                onTap: () => onPreset(preset.id),
              ),
          ],
        ),
        SizedBox(height: t.spacing * 1.5),
        _levelRow(t, '对白压缩', 'compression', state.compression, onCompression),
        SizedBox(height: t.spacing),
        _levelRow(t, '音量均衡', 'loudness', state.loudness, onLoudness),
      ],
    );
  }

  Widget _chip(
    ThemeTokens t,
    String label, {
    required bool selected,
    required VoidCallback onTap,
    Key? key,
  }) =>
      MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: onTap,
          child: Container(
            key: key,
            padding: EdgeInsets.symmetric(horizontal: t.spacing * 1.5, vertical: t.spacing),
            decoration: BoxDecoration(
              color: selected ? t.accent : t.sunken,
              borderRadius: BorderRadius.circular(t.radiusPill),
            ),
            child: Text(
              label,
              style: TextStyle(
                color: selected ? t.raised : t.text,
                fontSize: t.fontSizeSmall,
                height: 1.2,
              ),
            ),
          ),
        ),
      );

  Widget _levelRow(
    ThemeTokens t,
    String label,
    String id,
    int value,
    ValueChanged<int> onChanged,
  ) =>
      Row(
        children: <Widget>[
          SizedBox(
            width: 64,
            child: Text(label,
                style: TextStyle(color: t.text, fontSize: t.fontSizeSmall, height: 1.4)),
          ),
          Expanded(
            child: Wrap(
              spacing: t.spacing / 1.5,
              children: <Widget>[
                for (int level = 0; level <= 3; level++)
                  _chip(
                    t,
                    const <String>['关', '轻', '中', '强'][level],
                    key: ValueKey<String>('audio-fx-level-$id-$level'),
                    selected: value == level,
                    onTap: () => onChanged(level),
                  ),
              ],
            ),
          ),
        ],
      );
}

/// 频响曲线：横轴 31Hz→16kHz（等间距 = 对数刻度），纵轴 ±12 dB。
class AudioFxCurvePainter extends CustomPainter {
  AudioFxCurvePainter({required this.bands, required this.line, required this.grid});

  /// 键 = `b31`..`b16k`；缺项按 0。
  final Map<String, double> bands;
  final Color line;
  final Color grid;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;
    final Paint gridPaint = Paint()
      ..color = grid.withValues(alpha: 0.6)
      ..strokeWidth = 1;
    // 三条参考线：-12 / 0 / +12 dB。
    for (final double db in <double>[-12, 0, 12]) {
      final double y = _yFor(db, size.height);
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
    }
    final Path path = Path();
    for (int i = 0; i < kAudioFxBands.length; i++) {
      final double gain = (bands[kAudioFxBands[i]] ?? 0).clamp(-12, 12).toDouble();
      final double x = size.width * (i / (kAudioFxBands.length - 1));
      final double y = _yFor(gain, size.height);
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = line
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeJoin = StrokeJoin.round,
    );
  }

  /// 0 dB 在中间；+12 贴顶、-12 贴底（留 2px 不压边）。
  double _yFor(double db, double height) {
    final double half = (height - 4) / 2;
    return height / 2 - (db.clamp(-12, 12) / 12) * half;
  }

  @override
  bool shouldRepaint(AudioFxCurvePainter oldDelegate) =>
      oldDelegate.bands != bands ||
      oldDelegate.line != line ||
      oldDelegate.grid != grid;
}
