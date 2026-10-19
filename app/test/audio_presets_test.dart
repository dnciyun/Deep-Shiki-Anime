/// 音效面 consumer 的离线判据（不扫盘、不碰引擎包装配）。
library;

import 'dart:io';

import 'package:dsanima_core/dsanima_core.dart' as core;
import 'package:dsanima_core/dsanima_core.dart' show ExtensionManifest;
import 'package:flutter_test/flutter_test.dart';
import 'package:shikiin/shikiin.dart' as shikiin;

import 'package:dsanima/domain/app_version.dart';
import 'package:dsanima/state/audio_presets.dart';
import 'package:dsanima/state/generic_packs.dart';

Map<String, Object?> _preset(String id, String name, Map<String, Object?> values) =>
    <String, Object?>{
      'id': id,
      'name': name,
      'description': '',
      'values': values,
    };

Map<String, Object?> _manifest({
  required String id,
  required List<Object?> presets,
}) =>
    <String, Object?>{
      'schema': 1,
      'id': id,
      'name': '包 $id',
      'version': '1.0.0',
      'kind': core.kAudioPackKind,
      'minAppVersion': '1.1.0',
      'files': <Object?>[],
      'payload': <String, Object?>{
        'surface': core.kPlayerAudioSurfaceId,
        'surfaceSchema': 1,
        'presets': presets,
      },
    };

GenericPack _pack(Map<String, Object?> json) {
  final core.ManifestParseResult parsed = core.parseExtensionManifest(
    json,
    currentAppVersion: kAppVersion.toString(),
  );
  expect(parsed.ok, isTrue, reason: parsed.issues.join('；'));
  final ExtensionManifest manifest = parsed.manifest!;
  return GenericPack(
    manifest: manifest,
    payload: manifest.generic!,
    dir: Directory('C:/nonexistent/${manifest.id}'),
    surface: core.extensionSurfaceOf(manifest.generic!.surface),
  );
}

void main() {
  test('两个包三档 → 列表三条，id 带包前缀', () async {
    final GenericPack packA = _pack(_manifest(id: 'audio-a', presets: <Object?>[
      _preset('vocal', '人声增强', <String, Object?>{'b2k': 3, 'preamp': -3.5}),
      _preset('bass', '低音增强', <String, Object?>{'b63': 6}),
    ]));
    final GenericPack packB = _pack(_manifest(id: 'audio-b', presets: <Object?>[
      _preset('harman', '哈曼风格', <String, Object?>{'b31': 5}),
    ]));

    List<shikiin.AudioFxPreset> captured = const <shikiin.AudioFxPreset>[];
    final AudioPresetConsumer consumer =
        AudioPresetConsumer(onChanged: (List<shikiin.AudioFxPreset> p) => captured = p);
    await consumer.setPacks(<GenericPack>[packB, packA]);

    expect(captured, hasLength(3));
    expect(captured.map((shikiin.AudioFxPreset p) => p.id), <String>[
      'audio-a/vocal',
      'audio-a/bass',
      'audio-b/harman',
    ]);
    final shikiin.AudioFxPreset vocal = captured.first;
    expect(vocal.name, '人声增强');
    expect(vocal.bands['b2k'], 3);
    expect(vocal.bands['b31'], 0, reason: '缺项按 0');
    expect(vocal.preamp, -3.5);
    expect(vocal.crossfeed, 0);
    expect(consumer.presetCount, 3);
    expect(consumer.summary, '3 个音效档（来自 2 个包）');
    expect(consumer.describe(packA), '2 档音效');
  });

  test('空清单/卸包 → 回退空列表', () async {
    List<shikiin.AudioFxPreset> captured = <shikiin.AudioFxPreset>[
      const shikiin.AudioFxPreset(id: 'x', name: 'x'),
    ];
    final AudioPresetConsumer consumer =
        AudioPresetConsumer(onChanged: (List<shikiin.AudioFxPreset> p) => captured = p);
    await consumer.revert();
    expect(captured, isEmpty);
    expect(consumer.summary, '0 个音效档（来自 0 个包）');
  });

  test('只喂音效面：别的面的包一个都不收', () async {
    final GenericPack audio = _pack(_manifest(id: 'audio-a', presets: <Object?>[
      _preset('vocal', '人声增强', <String, Object?>{'b1k': 2}),
    ]));
    final GenericPack subtitle = GenericPack(
      manifest: audio.manifest,
      payload: const core.GenericPayload(
        surface: core.kPlayerSubtitleSurfaceId,
        surfaceSchema: 1,
        presets: <core.GenericPreset>[
          core.GenericPreset(id: 'cinema', name: '影院', values: <String, Object?>{'scale': 1.6}),
        ],
      ),
      dir: audio.dir,
      surface: core.extensionSurfaceOf(core.kPlayerSubtitleSurfaceId),
    );

    List<shikiin.AudioFxPreset> captured = const <shikiin.AudioFxPreset>[];
    final AudioPresetConsumer consumer =
        AudioPresetConsumer(onChanged: (List<shikiin.AudioFxPreset> p) => captured = p);
    await consumer.setPacks(<GenericPack>[subtitle, audio]);
    expect(captured, hasLength(1));
    expect(captured.single.id, 'audio-a/vocal');
  });

  test('全是别的面 → 空列表 + 一条说明', () async {
    final GenericPack audio = _pack(_manifest(id: 'audio-a', presets: <Object?>[
      _preset('vocal', '人声增强', <String, Object?>{}),
    ]));
    final GenericPack subtitle = GenericPack(
      manifest: audio.manifest,
      payload: const core.GenericPayload(
        surface: core.kPlayerSubtitleSurfaceId,
        surfaceSchema: 1,
      ),
      dir: audio.dir,
      surface: core.extensionSurfaceOf(core.kPlayerSubtitleSurfaceId),
    );
    final AudioPresetConsumer consumer =
        AudioPresetConsumer(onChanged: (_) {});
    await consumer.setPacks(<GenericPack>[subtitle]);
    expect(consumer.notes, isNotEmpty);
  });

  test('接线守卫：两个引擎都建 consumer，播放窗口有 notifier/provider', () {
    final String mainFile = File('lib/main.dart').readAsStringSync();
    expect(mainFile, contains('AudioPresetConsumer'));
    expect(mainFile, contains('windowAudioPresetsNotifier'));

    final String window = File('lib/ui/player_window_app.dart').readAsStringSync();
    expect(window, contains('windowAudioPresetsNotifier'));
    expect(window, contains('shikiin.audioPresetsProvider'));
    expect(window, contains('scanGenericPacks'));
  });
}
