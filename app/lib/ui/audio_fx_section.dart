/// 扩展页里的「音效」配置区（用户 2026-10-19：「放设置里没用，就放扩展里」）。
///
/// 位置为什么在扩展页而不是播放器设置面板：
/// * 音效是**扩展包带来的功能**，装没装、有几档，本来就该在扩展页看得到；
/// * 配置入口在主窗口，播放窗口（独立引擎）只负责执行与右键快捷切换——
///   两边各存一份必然漂移，所以主窗口是唯一写入口。
library;

import 'package:flutter/material.dart';
import 'package:shikiin/shikiin.dart' as shikiin;

import '../theme/tokens.dart';

/// 音效区：当前档 + 频响曲线 + 档位 + 总强度 + 两个全局强度。
///
/// 没有音效包时调用方**不渲染它**（整区不出现）。
class AudioFxSection extends StatelessWidget {
  const AudioFxSection({
    super.key,
    required this.tokens,
    required this.presets,
    required this.state,
    required this.onChange,
  });

  final DsTokens tokens;
  final List<shikiin.AudioFxPreset> presets;
  final shikiin.AudioFxState state;

  /// 页面上任何一处改动都走它：调用方负责落盘 + 推给播放窗口。
  final ValueChanged<shikiin.AudioFxState> onChange;

  shikiin.AudioFxPreset? get _current {
    if (!state.enabled) return null;
    for (final shikiin.AudioFxPreset preset in presets) {
      if (preset.id == state.presetId) return preset;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final DsTokens t = tokens;
    final shikiin.AudioFxPreset? current = _current;
    // 总强度的缩放只作用于 10 段 EQ（与 `audioFxFilterSpec` 同一条口径），所以曲线也
    // 用同一个缩放函数画：50% = 包里原值、100% = 两倍、0% = 平直。
    // 各算一份的话，用户会看到曲线和耳朵里的力度对不上，然后怀疑音效坏了。
    final double scale = shikiin.audioFxIntensityScale(state.intensity);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Icon(Icons.graphic_eq_rounded, size: 16, color: t.accent),
            const SizedBox(width: 8),
            Text(
              '音效',
              style: TextStyle(
                color: t.text,
                fontSize: DsTypeScale.secondary,
                fontWeight: FontWeight.w600,
              ),
            ),
            const Spacer(),
            Text(
              current == null ? '原声' : current.name,
              style: TextStyle(color: t.text2, fontSize: DsTypeScale.caption),
            ),
          ],
        ),
        const SizedBox(height: 10),
        SizedBox(
          height: 56,
          child: CustomPaint(
            painter: AudioFxCurvePainter(
              bands: <String, double>{
                for (final String band in shikiin.kAudioFxBands)
                  band: (current?.bands[band] ?? 0) * scale,
              },
              line: t.accent,
              grid: t.line,
            ),
            child: const SizedBox.expand(),
          ),
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: <Widget>[
            _chip(t, '原声',
                key: const ValueKey<String>('audio-fx-off'),
                selected: !state.enabled,
                onTap: () => onChange(state.copyWith(enabled: false, clearPreset: true))),
            for (final shikiin.AudioFxPreset preset in presets)
              _chip(
                t,
                preset.name,
                key: ValueKey<String>('audio-fx-preset-${preset.id}'),
                selected: state.enabled && state.presetId == preset.id,
                onTap: () => onChange(state.copyWith(enabled: true, presetId: preset.id)),
              ),
          ],
        ),
        const SizedBox(height: 12),
        _intensityRow(t),
        const SizedBox(height: 4),
        // 中性点必须在界面上说清楚：滑块两头都"能调大/调小"，而 50% 才是包里的原值。
        // 不写出来的话，用户会以为"拖到 100% 才是这档该有的样子"（那是原值两倍）。
        Text(
          '50% = 包里的原值；往右更明显（100% = 原值两倍），往左更淡（0% = 频响平直）。'
          '只缩 EQ 的 10 段增益，不缩预增益、也不缩下面两个强度。',
          style: TextStyle(color: t.text3, fontSize: DsTypeScale.caption, height: 1.4),
        ),
        const SizedBox(height: 8),
        _levelRow(t, '对白压缩', 'compression', state.compression,
            (int v) => onChange(state.copyWith(compression: v))),
        const SizedBox(height: 8),
        _levelRow(t, '音量均衡', 'loudness', state.loudness,
            (int v) => onChange(state.copyWith(loudness: v))),
        if (current != null && current.description.isNotEmpty) ...<Widget>[
          const SizedBox(height: 8),
          Text(
            current.description,
            style: TextStyle(
              color: t.text3,
              fontSize: DsTypeScale.caption,
              height: 1.4,
            ),
          ),
        ],
      ],
    );
  }

  /// 总强度滑块（0–100%，`divisions: 20` = 每 5% 一档）。
  ///
  /// 为什么是滑块而不是 4 档 chips：这是**连续**的力度（"再多一点/再少一点"），
  /// 而下面两个强度是**互斥的档位语义**（关/轻/中/强，右键菜单里也是这四档）。
  ///
  /// ⚠️ 中点（50%）是"不动"，不是"关"：滑块两头都有余量，往右是**加强**到原值两倍
  /// （2026-10-20 用户：「当前100的强度移动到50，默认强度在50，拉大效果更明显」）。
  Widget _intensityRow(DsTokens t) {
    final int value = state.intensity
        .clamp(shikiin.kAudioFxIntensityMin, shikiin.kAudioFxIntensityMax);
    return Row(
      children: <Widget>[
        SizedBox(
          width: 68,
          child: Text('总强度',
              style: TextStyle(color: t.text, fontSize: DsTypeScale.caption)),
        ),
        Expanded(
          child: Slider(
            key: const ValueKey<String>('audio-fx-intensity'),
            value: value.toDouble(),
            min: shikiin.kAudioFxIntensityMin.toDouble(),
            max: shikiin.kAudioFxIntensityMax.toDouble(),
            divisions: 20,
            label: '$value%',
            onChanged: (double v) =>
                onChange(state.copyWith(intensity: v.round())),
          ),
        ),
        SizedBox(
          width: 44,
          child: Text(
            '$value%',
            key: const ValueKey<String>('audio-fx-intensity-value'),
            textAlign: TextAlign.right,
            style: TextStyle(
              color: t.text2,
              fontSize: DsTypeScale.caption,
              fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
            ),
          ),
        ),
      ],
    );
  }

  Widget _chip(
    DsTokens t,
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
            padding: EdgeInsets.symmetric(horizontal: t.spacing, vertical: 6),
            decoration: BoxDecoration(
              color: selected ? t.accent : t.sunken,
              borderRadius: BorderRadius.circular(t.radiusPill),
            ),
            child: Text(
              label,
              style: TextStyle(
                color: selected ? t.onAccent : t.text,
                fontSize: DsTypeScale.caption,
              ),
            ),
          ),
        ),
      );

  Widget _levelRow(
    DsTokens t,
    String label,
    String id,
    int value,
    ValueChanged<int> onChange,
  ) =>
      Row(
        children: <Widget>[
          SizedBox(
            width: 68,
            child: Text(label,
                style: TextStyle(color: t.text, fontSize: DsTypeScale.caption)),
          ),
          Expanded(
            child: Wrap(
              spacing: 6,
              children: <Widget>[
                for (int level = 0; level <= 3; level++)
                  _chip(
                    t,
                    const <String>['关', '轻', '中', '强'][level],
                    key: ValueKey<String>('audio-fx-level-$id-$level'),
                    selected: value == level,
                    onTap: () => onChange(level),
                  ),
              ],
            ),
          ),
        ],
      );
}

/// 频响曲线：横轴 31Hz→16kHz 等间距（对数刻度），纵轴 ±12 dB。
class AudioFxCurvePainter extends CustomPainter {
  AudioFxCurvePainter({required this.bands, required this.line, required this.grid});

  final Map<String, double> bands;
  final Color line;
  final Color grid;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;
    final Paint gridPaint = Paint()
      ..color = grid.withValues(alpha: 0.6)
      ..strokeWidth = 1;
    for (final double db in <double>[-12, 0, 12]) {
      final double y = _yFor(db, size.height);
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
    }
    final Path path = Path();
    for (int i = 0; i < shikiin.kAudioFxBands.length; i++) {
      final double gain =
          (bands[shikiin.kAudioFxBands[i]] ?? 0).clamp(-12, 12).toDouble();
      final double x = size.width * (i / (shikiin.kAudioFxBands.length - 1));
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
