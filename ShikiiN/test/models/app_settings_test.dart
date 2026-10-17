import 'package:flutter_test/flutter_test.dart';
import 'package:shikiin/models/app_settings.dart';
import 'package:shikiin/models/anime4k_preset.dart';
import 'package:shikiin/models/subtitle_style.dart';
import 'package:shikiin/models/upscale_scheme.dart';

void main() {
  test('默认含中性字幕样式', () {
    final s = AppSettings();
    expect(s.subtitleStyle.scale, 1.0);
  });

  test('toMap/fromMap 往返保留字幕样式', () {
    final s = AppSettings(subtitleStyle: const SubtitleStyle(scale: 1.5, bold: true));
    final r = AppSettings.fromMap(s.toMap());
    expect(r.subtitleStyle.scale, 1.5);
    expect(r.subtitleStyle.bold, true);
    expect(r.volume, 100);
  });

  test('anime4kPreset 默认 off 且往返序列化', () {
    final s = AppSettings(anime4kPreset: Anime4kPreset.standard);
    final back = AppSettings.fromMap(s.toMap());
    expect(back.anime4kPreset, Anime4kPreset.standard);
    expect(AppSettings().anime4kPreset, Anime4kPreset.off);
  });

  test('rate 固定 1.0（倍速已删，只读保留）', () {
    expect(AppSettings().rate, 1.0);
  });

  test('旧档(只有 volume)回退默认值', () {
    final back = AppSettings.fromMap({'volume': 80});
    expect(back.volume, 80);
    expect(back.anime4kPreset, Anime4kPreset.off);
    expect(back.rememberPosition, isTrue);
  });

  test('旧数据里的已删字段被静默忽略，不抛异常', () {
    final back = AppSettings.fromMap({
      'volume': 70,
      'autoSkip': true,
      'endAction': 'loop',
      'controlBarExtras': ['screenshot'],
      'volumeBoostEnabled': true,
      'anime4kCustomChain': ['modeCHq'],
      'controlBarFloatingOverride': false,
    });
    expect(back.volume, 70);
    expect(back.anime4kPreset, Anime4kPreset.off);
  });

  test('无法识别的 anime4kPreset 名称回退 off', () {
    expect(AppSettings.fromMap({'anime4kPreset': 'modeCHq'}).anime4kPreset, Anime4kPreset.off);
  });

  test('upscaleSchemeId：默认 anime4k、往返保留、空值回默认', () {
    expect(AppSettings().upscaleSchemeId, kAnime4kSchemeId);

    final s = AppSettings(upscaleSchemeId: 'mpv-ewa-lanczossharp');
    expect(AppSettings.fromMap(s.toMap()).upscaleSchemeId, 'mpv-ewa-lanczossharp');

    expect(AppSettings.fromMap({'upscaleSchemeId': '  '}).upscaleSchemeId, kAnime4kSchemeId);
    expect(AppSettings.fromMap({'upscaleSchemeId': 42}).upscaleSchemeId, kAnime4kSchemeId);
  });

  test('旧数据（没有 upscaleSchemeId）→ 默认 anime4k，旧档位照读', () {
    final back = AppSettings.fromMap({'anime4kPreset': 'ultra'});
    expect(back.upscaleSchemeId, kAnime4kSchemeId);
    expect(back.anime4kPreset, Anime4kPreset.ultra);
  });
}
