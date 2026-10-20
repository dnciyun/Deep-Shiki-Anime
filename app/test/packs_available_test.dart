/// `state/packs_available.dart`：侧栏那两个"包页面"什么时候存在。
///
/// 守的是一类静默失败：**装上包但入口不出现**（用户只能重启才能用上新装的功能），
/// 以及反过来的**包坏了入口还在**（点进去一片空，比没有入口更让人困惑）。
/// 全程临时目录真造文件、不联网。
library;

import 'dart:convert';
import 'dart:io';

import 'package:dsanima/domain/app_version.dart';
import 'package:dsanima/state/extension_schemes.dart'
    show kExtensionsDirName, kExtensionsStateFileName;
import 'package:dsanima/state/infra.dart';
import 'package:dsanima/state/packs_available.dart';
import 'package:dsanima_core/dsanima_core.dart' as core;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

Directory _newSupportDir() =>
    Directory.systemTemp.createTempSync('dsanima-packs-available-');

Directory _extDir(Directory support, String id) =>
    Directory(p.join(support.path, kExtensionsDirName, id))..createSync(recursive: true);

void _writeFile(Directory dir, String name, String text) {
  File(p.join(dir.path, name))
    ..createSync(recursive: true)
    ..writeAsStringSync(text);
}

void _writeManifest(Directory support, String id, Object? manifest) {
  _writeFile(
    _extDir(support, id),
    'manifest.json',
    manifest is String ? manifest : jsonEncode(manifest),
  );
}

void _writeEnabled(Directory support, Map<String, bool> enabled) {
  _writeFile(
    Directory(p.join(support.path, kExtensionsDirName)),
    kExtensionsStateFileName,
    jsonEncode(<String, Object?>{
      'schema': 1,
      'extensions': <String, Object?>{
        for (final MapEntry<String, bool> e in enabled.entries)
          e.key: <String, Object?>{'enabled': e.value},
      },
    }),
  );
}

/// 模板正文（`files` 里的 size 要跟它一致，否则清单判不合法）。
const String _kPictureTemplate = '#define SHARPEN @sharpen@\n';

/// 一个合法的画面调节包清单（参数 + 一档预设），模板另外写。
///
/// `files` 必须把模板列出来（要带 size/sha256）：清单校验会拒绝"模板没登记在 files 里"
/// 的包 —— 那不是刁难，是"装上之后挂不上"的唯一预防。
Map<String, Object?> _pictureManifest({String id = 'picture-demo'}) => <String, Object?>{
      'files': <Object?>[
        <String, Object?>{
          'path': 'shaders/picture.glsl',
          'size': _kPictureTemplate.length,
          'sha256': 'b' * 64,
        },
      ],
      'schema': 1,
      'id': id,
      'name': '演示画面包',
      'version': '1.0.0',
      'kind': 'picture-pack',
      'minAppVersion': kAppVersion.toString(),
      'payload': <String, Object?>{
        'picture': <String, Object?>{
          'template': 'shaders/picture.glsl',
          'hint': '演示包',
          'params': <Object?>[
            <String, Object?>{
              'key': 'sharpen',
              'label': '锐度',
              'min': 0,
              'max': 2,
              'step': 0.05,
              'default': 0.0,
            },
          ],
          'presets': <Object?>[
            <String, Object?>{
              'id': 'crisp',
              'name': '清晰',
              'values': <String, Object?>{'sharpen': 1.0},
            },
          ],
        },
      },
    };

/// 一个合法的音效包清单（面 `player.audio`，一档预设）。
Map<String, Object?> _audioManifest({String id = 'audio-demo'}) => <String, Object?>{
      'schema': 1,
      'id': id,
      'name': '演示音效包',
      'version': '1.0.0',
      'kind': core.kAudioPackKind,
      'minAppVersion': kAppVersion.toString(),
      'files': <Object?>[],
      'payload': <String, Object?>{
        'surface': core.kPlayerAudioSurfaceId,
        'surfaceSchema': 1,
        'presets': <Object?>[
          <String, Object?>{
            'id': 'vocal',
            'name': '人声增强',
            'description': '',
            'values': <String, Object?>{'b2k': 3, 'preamp': -3},
          },
        ],
      },
    };

/// 起一个容器并等一次扫描。
Future<PackAvailability> _scan({Directory? supportDir}) async {
  final ProviderContainer container = ProviderContainer(
    overrides: [
      if (supportDir != null) supportDirProvider.overrideWithValue(supportDir),
    ],
  );
  addTearDown(container.dispose);
  await container.read(packAvailabilityProvider.notifier).ensureLoaded();
  return container.read(packAvailabilityProvider);
}

void main() {
  test('没注入数据根 → 两个入口都不出现，且不抛', () async {
    final PackAvailability available = await _scan();
    expect(available.hasPicture, isFalse);
    expect(available.hasAudioFx, isFalse);
  });

  test('空目录 → 两个入口都不出现', () async {
    final Directory dir = _newSupportDir();
    addTearDown(() => dir.deleteSync(recursive: true));
    final PackAvailability available = await _scan(supportDir: dir);
    expect(available.picturePacks, isEmpty);
    expect(available.audioPresets, isEmpty);
  });

  test('坏清单（不是 JSON）→ 当作没有这个包，绝不抛', () async {
    final Directory dir = _newSupportDir();
    addTearDown(() => dir.deleteSync(recursive: true));
    _writeManifest(dir, 'picture-demo', '{ 这不是 json');
    final PackAvailability available = await _scan(supportDir: dir);
    expect(available.hasPicture, isFalse, reason: '解析不过的包不能算"有这个入口"');
  });

  test('清单过了但模板文件不在 → 也不算可用（点进去只会什么都挂不上）', () async {
    final Directory dir = _newSupportDir();
    addTearDown(() => dir.deleteSync(recursive: true));
    _writeManifest(dir, 'picture-demo', _pictureManifest());
    _writeEnabled(dir, <String, bool>{'picture-demo': true});
    final PackAvailability available = await _scan(supportDir: dir);
    expect(available.hasPicture, isFalse);
  });

  test('完整的画面调节包 → 入口出现', () async {
    final Directory dir = _newSupportDir();
    addTearDown(() => dir.deleteSync(recursive: true));
    _writeManifest(dir, 'picture-demo', _pictureManifest());
    _writeFile(_extDir(dir, 'picture-demo'), p.join('shaders', 'picture.glsl'),
        '#define SHARPEN @sharpen@\n');
    _writeEnabled(dir, <String, bool>{'picture-demo': true});
    final PackAvailability available = await _scan(supportDir: dir);
    expect(available.hasPicture, isTrue);
    expect(available.picturePacks.single.id, 'picture-demo');
    expect(available.picturePacks.single.spec.params.single.key, 'sharpen');
  });

  test('被禁用的画面调节包 → 入口不出现', () async {
    final Directory dir = _newSupportDir();
    addTearDown(() => dir.deleteSync(recursive: true));
    _writeManifest(dir, 'picture-demo', _pictureManifest());
    _writeFile(_extDir(dir, 'picture-demo'), p.join('shaders', 'picture.glsl'),
        '#define SHARPEN @sharpen@\n');
    _writeEnabled(dir, <String, bool>{'picture-demo': false});
    final PackAvailability available = await _scan(supportDir: dir);
    expect(available.hasPicture, isFalse, reason: '禁用的包不该给入口');
  });

  test('音效包 → 音效入口出现，且档位带包前缀', () async {
    final Directory dir = _newSupportDir();
    addTearDown(() => dir.deleteSync(recursive: true));
    _writeManifest(dir, 'audio-demo', _audioManifest());
    _writeEnabled(dir, <String, bool>{'audio-demo': true});
    final PackAvailability available = await _scan(supportDir: dir);
    expect(available.hasAudioFx, isTrue);
    expect(available.audioPresets.single.id, 'audio-demo/vocal');
    expect(available.audioPresets.single.name, '人声增强');
  });
}
