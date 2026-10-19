/// `audio-pack` 的离线判据：面必须绑 `player.audio`、值必须有界、通用包规则照旧。
///
/// 每条对应 `manifest.dart` / `generic.dart` 里的一条判据，断言精确到 field。
library;

import 'package:dsanima_core/dsanima_core.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, Object?> _preset({
  Map<String, Object?>? values,
  String id = 'vocal',
  String name = '人声增强',
}) =>
    <String, Object?>{
      'id': id,
      'name': name,
      'description': '',
      'values': values ?? <String, Object?>{'b2k': 3, 'preamp': -3, 'crossfeed': 0},
    };

Map<String, Object?> _manifest({
  String kind = kAudioPackKind,
  String surface = kPlayerAudioSurfaceId,
  Object? surfaceSchema = 1,
  List<Object?>? presets,
  List<Object?>? files,
  Object? minAppVersion = '1.1.0',
}) =>
    <String, Object?>{
      'schema': 1,
      'id': 'dsanima-audio',
      'name': 'DSAnima 音效包',
      'version': '1.0.0',
      'kind': kind,
      'minAppVersion': ?minAppVersion,
      'files': files ?? <Object?>[],
      'payload': <String, Object?>{
        'surface': surface,
        'surfaceSchema': surfaceSchema,
        'presets': presets ?? <Object?>[_preset()],
      },
    };

void main() {
  test('合法的音效包能解析、能装、能判定可用', () {
    final ManifestParseResult parsed = parseExtensionManifest(_manifest());
    expect(parsed.ok, isTrue, reason: parsed.issues.join('；'));
    final ExtensionManifest m = parsed.manifest!;
    expect(m.kind, kAudioPackKind);
    expect(ExtensionKind.labelOf(m.kind), '音效包');
    expect(m.generic!.surface, kPlayerAudioSurfaceId);
    expect(m.generic!.presets.single.name, '人声增强');
    expect(m.isUsable, isTrue);
  });

  test('面必须是 player.audio：写成字幕面拒装', () {
    final ManifestParseResult parsed =
        parseExtensionManifest(_manifest(surface: kPlayerSubtitleSurfaceId));
    expect(parsed.ok, isFalse);
    expect(
      parsed.issues.map((ManifestIssue i) => i.field),
      contains('payload.surface'),
    );
  });

  test('段增益越界拒装（±12 之外）', () {
    final ManifestParseResult parsed = parseExtensionManifest(_manifest(
      presets: <Object?>[
        _preset(values: <String, Object?>{'b2k': 40}),
      ],
    ));
    expect(parsed.ok, isFalse);
    expect(
      parsed.issues.map((ManifestIssue i) => i.field),
      contains('payload.presets[0].values.b2k'),
    );
  });

  test('拼错的字段拒装（不静默忽略）', () {
    final ManifestParseResult parsed = parseExtensionManifest(_manifest(
      presets: <Object?>[
        _preset(values: <String, Object?>{'b1khz': 3}),
      ],
    ));
    expect(parsed.ok, isFalse);
    expect(
      parsed.issues.map((ManifestIssue i) => i.field),
      contains('payload.presets[0].values.b1khz'),
    );
  });

  test('crossfeed / preamp 也有界', () {
    expect(
      parseExtensionManifest(_manifest(
        presets: <Object?>[
          _preset(values: <String, Object?>{'crossfeed': 2}),
        ],
      )).ok,
      isFalse,
    );
    expect(
      parseExtensionManifest(_manifest(
        presets: <Object?>[
          _preset(values: <String, Object?>{'preamp': 12}),
        ],
      )).ok,
      isFalse,
    );
  });

  test('必须写 minAppVersion（老宿主不认识 audio-pack）', () {
    final ManifestParseResult parsed =
        parseExtensionManifest(_manifest(minAppVersion: null));
    expect(parsed.ok, isFalse);
    expect(
      parsed.issues.map((ManifestIssue i) => i.field),
      contains('minAppVersion'),
    );
  });

  test('老宿主（1.0.5）装 1.1.0 的音效包 → 拒装', () {
    final ManifestParseResult parsed =
        parseExtensionManifest(_manifest(), currentAppVersion: '1.0.5');
    expect(parsed.ok, isFalse);
    expect(
      parsed.issues.map((ManifestIssue i) => i.field),
      contains('minAppVersion'),
    );
  });

  test('files 允许为空（音效包只有数值，没有要落盘的文件）', () {
    final ManifestParseResult parsed =
        parseExtensionManifest(_manifest(files: <Object?>[]));
    expect(parsed.ok, isTrue, reason: parsed.issues.join('；'));
  });

  test('surfaceSchema 必须是 1', () {
    final ManifestParseResult parsed =
        parseExtensionManifest(_manifest(surfaceSchema: 2));
    expect(parsed.ok, isFalse);
    expect(
      parsed.issues.map((ManifestIssue i) => i.field),
      contains('payload.surfaceSchema'),
    );
  });

  test('面注册表：player.audio 存在、上限 12 档、不收资产', () {
    final ExtensionSurface? surface = extensionSurfaceOf(kPlayerAudioSurfaceId);
    expect(surface, isNotNull);
    expect(surface!.maxPresets, 12);
    expect(surface.maxAssets, 0);
    expect(surface.payloadKind, SurfacePayloadKind.preset);
    expect(
      surface.fields.map((SurfaceField f) => f.key),
      containsAll(<String>['b31', 'b16k', 'preamp', 'crossfeed']),
    );
  });
}
