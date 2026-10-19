/// 首发音效包（`tool/extension-packs/dsanima-audio/`）的落地判据。
///
/// 与其它 fixture 测试同一个理由：源目录里的清单被手改坏了，要在这里拦住，
/// 而不是等打完包、推到线上、用户装的时候才发现装不上。
library;

import 'dart:convert';
import 'dart:io';

import 'package:dsanima_core/dsanima_core.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final File file = File('../tool/extension-packs/dsanima-audio/manifest.json');

  test('首发音效包：能解析、六档、面是 player.audio、minAppVersion 1.1.0', () {
    expect(file.existsSync(), isTrue, reason: '源目录里应有 dsanima-audio/manifest.json');
    final ManifestParseResult parsed = parseExtensionManifest(
      jsonDecode(file.readAsStringSync()),
      currentAppVersion: '1.1.0',
    );
    expect(parsed.ok, isTrue, reason: parsed.issues.join('；'));
    final ExtensionManifest manifest = parsed.manifest!;
    expect(manifest.kind, kAudioPackKind);
    expect(manifest.generic!.surface, kPlayerAudioSurfaceId);
    expect(manifest.generic!.presets.length, 6);
    expect(manifest.minAppVersion, '1.1.0');
    expect(manifest.files, isEmpty, reason: '音效包只有数值，没有落盘文件');
    expect(manifest.isUsable, isTrue);
  });

  test('每一档的增益都在 ±12、preamp 与 crossfeed 都在范围内', () {
    final ManifestParseResult parsed = parseExtensionManifest(
      jsonDecode(file.readAsStringSync()),
      currentAppVersion: '1.1.0',
    );
    for (final GenericPreset preset in parsed.manifest!.generic!.presets) {
      for (final String band in <String>[
        'b31', 'b63', 'b125', 'b250', 'b500', 'b1k', 'b2k', 'b4k', 'b8k', 'b16k',
      ]) {
        final Object? gain = preset.values[band];
        if (gain == null) continue;
        expect(gain, isA<num>(), reason: '${preset.id}.$band 不是数字');
        expect((gain as num).abs() <= 12, isTrue, reason: '${preset.id}.$band 越界');
      }
      final Object? preamp = preset.values['preamp'];
      if (preamp is num) {
        expect(preamp >= -12 && preamp <= 6, isTrue, reason: '${preset.id}.preamp 越界');
      }
      final Object? crossfeed = preset.values['crossfeed'];
      if (crossfeed is num) {
        expect(crossfeed >= 0 && crossfeed <= 1, isTrue, reason: '${preset.id}.crossfeed 越界');
      }
    }
  });
}
