import 'package:flutter_test/flutter_test.dart';
import 'package:shikiin/models/video_fit_mode.dart';

void main() {
  test('keepAspect maps to keepaspect=yes, panscan=0', () {
    expect(VideoFitMode.keepAspect.toMpvProperties(),
        {'keepaspect': 'yes', 'panscan': '0.0'});
  });

  test('cover (fill+crop) maps to panscan=1.0, keepaspect=yes', () {
    expect(VideoFitMode.cover.toMpvProperties(),
        {'keepaspect': 'yes', 'panscan': '1.0'});
  });

  test('stretch maps to keepaspect=no, panscan=0', () {
    expect(VideoFitMode.stretch.toMpvProperties(),
        {'keepaspect': 'no', 'panscan': '0.0'});
  });

  test('default mode is keepAspect', () {
    expect(VideoFitMode.values.first, VideoFitMode.keepAspect);
  });

  test('label is human-readable Chinese', () {
    expect(VideoFitMode.keepAspect.label, '保持比例');
    expect(VideoFitMode.cover.label, '填充裁切');
    expect(VideoFitMode.stretch.label, '拉伸');
  });
}
