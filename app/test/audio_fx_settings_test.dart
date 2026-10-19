/// 音效设置的落盘：扩展页是唯一配置入口，这份状态要能跨重启活下来。
library;

import 'dart:io';

import 'package:dsanima/state/audio_fx_settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shikiin/shikiin.dart' as shikiin;

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('audio-fx-'));
  tearDown(() => dir.deleteSync(recursive: true));

  test('没文件 → 默认（关、无档、两档强度 0）', () async {
    final shikiin.AudioFxState s = await loadAudioFxState(dir);
    expect(s.enabled, isFalse);
    expect(s.presetId, isNull);
    expect(s.compression, 0);
    expect(s.loudness, 0);
  });

  test('写→读 一致（文件落在 dsanima/audio-fx.json）', () async {
    const shikiin.AudioFxState state = shikiin.AudioFxState(
      enabled: true,
      presetId: 'dsanima-audio/vocal',
      compression: 2,
      loudness: 1,
    );
    await saveAudioFxState(dir, state);
    expect(audioFxSettingsFileOf(dir).existsSync(), isTrue);
    expect(p.basename(audioFxSettingsFileOf(dir).path), 'audio-fx.json');

    final shikiin.AudioFxState loaded = await loadAudioFxState(dir);
    expect(loaded, state);
  });

  test('坏文件 → 退化默认，不抛', () async {
    final File f = audioFxSettingsFileOf(dir);
    f.parent.createSync(recursive: true);
    f.writeAsStringSync('{ 这不是 json');
    expect(await loadAudioFxState(dir), const shikiin.AudioFxState());
  });

  test('AudioFxState.fromJson 夹住越界强度与空档位', () {
    final shikiin.AudioFxState s = shikiin.AudioFxState.fromJson(<String, Object?>{
      'enabled': true,
      'presetId': '',
      'compression': 9,
      'loudness': -3,
    });
    expect(s.enabled, isTrue);
    expect(s.presetId, isNull);
    expect(s.compression, 3);
    expect(s.loudness, 0);
  });
}
