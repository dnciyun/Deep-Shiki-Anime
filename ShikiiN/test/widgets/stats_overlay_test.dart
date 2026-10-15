import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shikiin/models/video_stats.dart';
import 'package:shikiin/models/theme_tokens.dart';
import 'package:shikiin/widgets/stats_overlay.dart';

void main() {
  testWidgets('渲染各项标签与值', (tester) async {
    const stats = VideoStats(
      fps: '23.98', renderedFps: '20.0', sourceFps: '23.98', displayFps: '60.00',
      resolution: '1920×1080', videoBitrate: '8.0 Mbps', droppedFrames: '0',
      videoCodec: 'h264', pixelFormat: 'yuv420p', hwdec: 'd3d11va',
      avSync: '1 ms', speed: '1.00x', audioCodec: 'aac',
      audioBitrate: '256 kbps', sampleRate: '48.0 kHz', audioChannels: 'stereo',
    );
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: StatsOverlay(tokens: ThemeTokens.fallback, stats: stats))));
    expect(find.text('输出帧率'), findsOneWidget);
    expect(find.text('实际帧率'), findsOneWidget);
    expect(find.text('23.98'), findsWidgets); // fps 与源帧率同值
    expect(find.text('1920×1080'), findsOneWidget);
    expect(find.text('硬解'), findsOneWidget);
    expect(find.text('声道'), findsOneWidget);
  });
}
