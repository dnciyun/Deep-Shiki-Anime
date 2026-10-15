import 'package:flutter/material.dart';
import 'package:media_kit_video/media_kit_video.dart';
import '../controllers/player_controller.dart';
import '../models/subtitle_style.dart';
import '../models/theme_tokens.dart';
import '../models/video_fit_mode.dart';

class VideoStage extends StatelessWidget {
  final PlayerController controller;
  final VoidCallback onDoubleTap;
  final Color background;
  final SubtitleStyle subtitleStyle;

  /// 可选 token（字幕颜色串损坏时的兜底色来源；不传则回退到 [background]）。
  final ThemeTokens? tokens;

  const VideoStage({
    super.key,
    required this.controller,
    required this.onDoubleTap,
    required this.background,
    required this.subtitleStyle,
    this.tokens,
  });

  // 画面适配靠 Flutter 端 BoxFit 真正生效（mpv 输出的纹理仍是原始比例）。
  BoxFit _fitFor(VideoFitMode m) => switch (m) {
        VideoFitMode.keepAspect => BoxFit.contain,
        VideoFitMode.cover => BoxFit.cover,
        VideoFitMode.stretch => BoxFit.fill,
      };

  Color _color(String s) {
    var h = s.replaceFirst('#', '');
    if (h.length == 6) h = 'FF$h';
    // 颜色串来自持久化设置：损坏数据不能让 VideoStage 每帧 build 抛异常（整个画面挂掉）。
    final v = int.tryParse(h, radix: 16);
    if (v == null) return tokens?.text ?? background;
    return Color(v);
  }

  // media_kit 在 Flutter 层渲染字幕，样式由这里决定（mpv 的 sub-* 管不到它）。
  SubtitleViewConfiguration _subConfig() {
    final s = subtitleStyle;
    final b = s.borderSize;
    final shadows = <Shadow>[];
    if (b > 0) {
      final bc = _color(s.borderColor);
      for (final o in [
        Offset(-b, -b), Offset(b, -b), Offset(-b, b), Offset(b, b),
        Offset(0, -b), Offset(0, b), Offset(-b, 0), Offset(b, 0),
      ]) {
        shadows.add(Shadow(offset: o, color: bc, blurRadius: 0));
      }
    }
    if (s.shadowOffset > 0) {
      shadows.add(Shadow(
          offset: Offset(s.shadowOffset, s.shadowOffset), color: _color(s.shadowColor), blurRadius: s.shadowOffset));
    }
    // pos：100=底部(默认)，越小越靠上 → 增大底部留白。
    final bottom = (32 + (100 - s.pos) * 2.4).clamp(8.0, 400.0);
    return SubtitleViewConfiguration(
      style: TextStyle(
        color: _color(s.color),
        fontSize: 32.0 * s.scale,
        fontFamily: s.font.isEmpty ? null : s.font,
        fontWeight: s.bold ? FontWeight.bold : FontWeight.normal,
        fontStyle: s.italic ? FontStyle.italic : FontStyle.normal,
        backgroundColor: s.backColor != null ? _color(s.backColor!) : null,
        shadows: shadows.isEmpty ? null : shadows,
        height: 1.2,
      ),
      textAlign: TextAlign.center,
      padding: EdgeInsets.fromLTRB(24, 24, 24, bottom),
    );
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onDoubleTap: onDoubleTap,
      child: Video(
        controller: controller.video,
        controls: NoVideoControls,
        fill: background,
        fit: _fitFor(controller.fit),
        subtitleViewConfiguration: _subConfig(),
      ),
    );
  }
}
