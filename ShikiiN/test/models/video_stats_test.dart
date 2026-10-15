import 'package:flutter_test/flutter_test.dart';
import 'package:shikiin/models/video_stats.dart';

void main() {
  test('fromProps 正常映射并格式化常见字段', () {
    final s = VideoStats.fromProps({
      'estimated-vf-fps': '23.976023',
      'container-fps': '23.976000',
      'display-fps': '60.000000',
      'width': '1920',
      'height': '1080',
      'video-bitrate': '8000000',
      'frame-drop-count': '3',
      'video-codec': 'h264',
      'video-params/pixelformat': 'yuv420p',
      'hwdec-current': 'd3d11va',
      'avsync': '0.001234',
      'speed': '1.000000',
      'audio-codec-name': 'aac',
      'audio-bitrate': '256000',
      'audio-params/samplerate': '48000',
      'audio-params/channels': 'stereo',
    });
    expect(s.fps, '23.98'); // 输出帧率，圆整到 2 位
    expect(s.sourceFps, '23.98');
    expect(s.renderedFps, '—'); // 未传入则占位
    expect(s.displayFps, '60.00');
    expect(s.resolution, '1920×1080');
    expect(s.droppedFrames, '3');
    expect(s.videoCodec, 'h264');
    expect(s.pixelFormat, 'yuv420p');
    expect(s.hwdec, 'd3d11va');
    expect(s.avSync, '1 ms');
    expect(s.speed, '1.00x');
    expect(s.audioCodec, 'aac');
    expect(s.audioChannels, 'stereo');
    expect(s.videoBitrate, contains('Mbps')); // 8000000 → ~8.0 Mbps
    expect(s.audioBitrate, '256 kbps');
    expect(s.sampleRate, '48.0 kHz');
  });

  test('renderedFps 由调用方传入(实际帧率=输出-丢帧率)', () {
    final s = VideoStats.fromProps({'estimated-vf-fps': '24'}, renderedFps: '18.0');
    expect(s.renderedFps, '18.0');
  });

  test('缺项/空值回退占位 —', () {
    final s = VideoStats.fromProps({});
    expect(s.fps, '—');
    expect(s.renderedFps, '—');
    expect(s.sourceFps, '—');
    expect(s.displayFps, '—');
    expect(s.resolution, '—');
    expect(s.videoBitrate, '—');
    expect(s.droppedFrames, '—');
    expect(s.videoCodec, '—');
    expect(s.pixelFormat, '—');
    expect(s.hwdec, '—');
    expect(s.avSync, '—');
    expect(s.speed, '—');
    expect(s.audioCodec, '—');
    expect(s.audioBitrate, '—');
    expect(s.sampleRate, '—');
    expect(s.audioChannels, '—');
  });

  test('宽或高缺失则分辨率占位', () {
    expect(VideoStats.fromProps({'width': '1920'}).resolution, '—');
  });

  test('rows 覆盖所有展示项', () {
    final s = VideoStats.fromProps({});
    final labels = s.rows.map((e) => e.$1).toList();
    expect(labels, containsAll(['源帧率', '输出帧率', '实际帧率', '显示刷新', '音画同步', '播放速度']));
  });
}
