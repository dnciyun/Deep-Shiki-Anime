/// `state/generic_packs.dart`：通用扩展包（preset-pack / list-pack）的共享扫描器。
///
/// 全是临时目录真造文件（不联网）：守的是「装上了但扫不到/扫错了」这一类问题 ——
/// 禁用、清单坏、声明文件缺失、未知 surface、目录不存在都不能把扩展页带崩。
library;

import 'dart:convert';
import 'dart:io';

import 'package:dsanima/domain/app_version.dart';
import 'package:dsanima/state/extension_schemes.dart'
    show kExtensionsDirName, kExtensionsStateFileName;
import 'package:dsanima/state/generic_packs.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

final String _sha = 'a' * 64;

Map<String, Object?> _manifest({
  required String id,
  String name = '演示通用包',
  String kind = 'preset-pack',
  String surface = 'player.subtitle',
  List<Object?> files = const <Object?>[],
  Map<String, Object?>? payload,
  String? minAppVersion,
}) =>
    <String, Object?>{
      'schema': 1,
      'id': id,
      'name': name,
      'version': '1.0.0',
      'kind': kind,
      // 宿主自己当前的版本：清单的 minAppVersion 高于它会被直接拒装（判据在 core）。
      'minAppVersion': minAppVersion ?? kAppVersion.toString(),
      'files': files,
      'payload': payload ??
          <String, Object?>{
            'surface': surface,
            'surfaceSchema': 1,
            'presets': <Object?>[
              <String, Object?>{
                'id': 'cinema',
                'name': '影院',
                'values': <String, Object?>{'scale': 1.6},
              },
            ],
          },
    };

Directory _newSupportDir() =>
    Directory.systemTemp.createTempSync('dsanima-generic-packs-');

Directory _extDir(Directory support, String id) =>
    Directory(p.join(support.path, kExtensionsDirName, id))..createSync(recursive: true);

void _writeManifest(Directory extDir, Object manifest) {
  File(p.join(extDir.path, 'manifest.json'))
    ..createSync(recursive: true)
    ..writeAsStringSync(manifest is String ? manifest : jsonEncode(manifest));
}

void _writeState(Directory support, Map<String, bool> enabled) {
  File(p.join(support.path, kExtensionsDirName, kExtensionsStateFileName))
    ..createSync(recursive: true)
    ..writeAsStringSync(jsonEncode(<String, Object?>{
      'schema': 1,
      'extensions': <String, Object?>{
        for (final MapEntry<String, bool> e in enabled.entries)
          e.key: <String, Object?>{'enabled': e.value},
      },
    }));
}

Directory _installPack(
  Directory support,
  String id, {
  Map<String, Object?>? manifest,
  bool? enabled,
}) {
  final Directory ext = _extDir(support, id);
  _writeManifest(ext, manifest ?? _manifest(id: id));
  if (enabled != null) _writeState(support, <String, bool>{id: enabled});
  return ext;
}

void main() {
  test('合法预设包 → 扫出 1 个，surface 指到播放器字幕样式', () async {
    final Directory support = _newSupportDir();
    addTearDown(() => support.deleteSync(recursive: true));
    _installPack(support, 'subtitle-cinema');

    final List<GenericPack> packs = await scanGenericPacks(support);
    expect(packs, hasLength(1));
    final GenericPack pack = packs.single;
    expect(pack.id, 'subtitle-cinema');
    expect(pack.payload.surface, 'player.subtitle');
    expect(pack.surface!.id, 'player.subtitle');
    expect(pack.payload.presets.single.values['scale'], 1.6);
    expect(pack.dir.path, p.join(support.path, kExtensionsDirName, 'subtitle-cinema'));
  });

  test('state.json 里 enabled:false → 扫不到', () async {
    final Directory support = _newSupportDir();
    addTearDown(() => support.deleteSync(recursive: true));
    _installPack(support, 'subtitle-cinema', enabled: false);

    expect(await scanGenericPacks(support), isEmpty);
  });

  test('清单声明了文件但盘上没有 → 扫不到', () async {
    final Directory support = _newSupportDir();
    addTearDown(() => support.deleteSync(recursive: true));
    _installPack(
      support,
      'missing-file',
      manifest: _manifest(
        id: 'missing-file',
        files: <Object?>[
          <String, Object?>{'path': 'shaders/x.glsl', 'size': 10, 'sha256': _sha},
        ],
      ),
    );

    expect(await scanGenericPacks(support), isEmpty);
  });

  test('未知 surface 照样扫出（surface == null），交给扩展页说明', () async {
    final Directory support = _newSupportDir();
    addTearDown(() => support.deleteSync(recursive: true));
    _installPack(support, 'future-pack',
        manifest: _manifest(id: 'future-pack', surface: 'future.thing'));

    final List<GenericPack> packs = await scanGenericPacks(support);
    expect(packs, hasLength(1));
    expect(packs.single.surface, isNull);
    expect(packs.single.payload.surface, 'future.thing');
  });

  test('非通用 kind（data-pack）不返回', () async {
    final Directory support = _newSupportDir();
    addTearDown(() => support.deleteSync(recursive: true));
    final Directory ext = _installPack(
      support,
      'plain-data',
      manifest: _manifest(
        id: 'plain-data',
        kind: 'data-pack',
        files: <Object?>[
          <String, Object?>{'path': 'data/a.bin', 'size': 1, 'sha256': _sha},
        ],
      ),
    );
    File(p.join(ext.path, 'data/a.bin'))
      ..createSync(recursive: true)
      ..writeAsStringSync('x');

    expect(await scanGenericPacks(support), isEmpty);
  });

  test('坏 JSON / 目录名与 id 不一致 / 目录不存在 → 空列表、不抛', () async {
    final Directory support = _newSupportDir();
    addTearDown(() => support.deleteSync(recursive: true));
    _writeManifest(_extDir(support, 'bad-json'), 'not-json');
    _installPack(support, 'wrong-dir', manifest: _manifest(id: 'other-id'));

    expect(await scanGenericPacks(support), isEmpty);
    expect(await scanGenericPacks(Directory(p.join(support.path, 'no-such-dir'))), isEmpty);
  });

  test('groupGenericPacksBySurface 按面分组、组内按名字排序', () async {
    final Directory support = _newSupportDir();
    addTearDown(() => support.deleteSync(recursive: true));
    _installPack(support, 'z-pack', manifest: _manifest(id: 'z-pack', name: 'Z 包'));
    _installPack(support, 'a-pack', manifest: _manifest(id: 'a-pack', name: 'A 包'));
    _installPack(support, 'future-pack',
        manifest: _manifest(id: 'future-pack', name: 'Future', surface: 'future.thing'));

    final Map<String, List<GenericPack>> groups =
        groupGenericPacksBySurface(await scanGenericPacks(support));
    expect(groups.keys, containsAll(<String>['player.subtitle', 'future.thing']));
    expect(groups['player.subtitle']!.map((GenericPack p) => p.id), <String>['a-pack', 'z-pack']);
  });
}
