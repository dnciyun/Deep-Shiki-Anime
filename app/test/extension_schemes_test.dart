/// `state/extension_schemes.dart`：扩展目录 → shikiin 超分方案的翻译（1.1.0 M3/T17）。
///
/// 全部用临时目录真造文件（不联网）：这些判据都是"用户手删了文件 / 装了数据包 /
/// 改了清单"之后的真实形态，用 mock 反而测不出来。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shikiin/shikiin.dart';
import 'package:dsanima/state/extension_schemes.dart';

final String _sha = 'a' * 64;

Map<String, Object?> _manifest({
  required String id,
  required String name,
  String kind = 'shader-pack',
  String version = '1.0.0',
  String? license,
  List<String> shaderFiles = const <String>['a.glsl'],
  String shaderDir = 'shaders',
}) =>
    <String, Object?>{
      'schema': 1,
      'id': id,
      'name': name,
      'version': version,
      'kind': kind,
      'description': '测试',
      'license': ?license,
      'files': <Object?>[
        for (final String file in shaderFiles)
          <String, Object?>{
            'path': shaderDir.isEmpty ? file : '$shaderDir/$file',
            'size': 4,
            'sha256': _sha,
          },
      ],
      if (kind == 'shader-pack')
        'payload': <String, Object?>{
          'shader': <String, Object?>{
            'dir': shaderDir,
            'files': shaderFiles,
            'pipeline': 'glsl-shaders',
          },
        },
    };

void _writeManifest(Directory extDir, Map<String, Object?> manifest) {
  File(p.join(extDir.path, 'manifest.json'))
    ..createSync(recursive: true)
    ..writeAsStringSync(jsonEncode(manifest));
}

void _writeShaderFiles(Directory extDir, String dir, List<String> names) {
  for (final String name in names) {
    File(p.join(extDir.path, dir, name))
      ..createSync(recursive: true)
      ..writeAsStringSync('//!DESC test\n');
  }
}

Directory _newSupportDir() => Directory.systemTemp.createTempSync('dsanima-ext-schemes-');

void _writeState(Directory supportDir, Map<String, Object?> extensions) {
  File(p.join(supportDir.path, kExtensionsDirName, kExtensionsStateFileName))
    ..createSync(recursive: true)
    ..writeAsStringSync(jsonEncode(<String, Object?>{
      'schema': 1,
      'extensions': extensions,
    }));
}

void main() {
  test('正常扩展 → 方案字段都对（id/name/files/绝对 dir/note 带版本许可）', () async {
    final Directory support = _newSupportDir();
    addTearDown(() => support.deleteSync(recursive: true));
    final Directory ext = Directory(p.join(support.path, kExtensionsDirName, 'anime4k-modeb'))
      ..createSync(recursive: true);
    _writeManifest(ext, _manifest(
      id: 'anime4k-modeb',
      name: 'Anime4K Mode B 保守',
      license: 'MIT',
      shaderFiles: <String>['a.glsl', 'b.glsl'],
    ));
    _writeShaderFiles(ext, 'shaders', <String>['a.glsl', 'b.glsl']);
    _writeState(support, <String, Object?>{
      'anime4k-modeb': <String, Object?>{'enabled': true},
    });

    final List<UpscaleScheme> schemes = await loadExtensionUpscaleSchemes(support);

    expect(schemes, hasLength(1));
    final UpscaleScheme scheme = schemes.single;
    expect(scheme.id, 'anime4k-modeb');
    expect(scheme.name, 'Anime4K Mode B 保守');
    expect(scheme.kind, UpscaleSchemeKind.glslPack);
    expect(scheme.files, <String>['a.glsl', 'b.glsl']);
    expect(scheme.dir, p.join(ext.path, 'shaders'));
    expect(p.isAbsolute(scheme.dir!), isTrue, reason: '播放器要能直接拼路径挂链');
    expect(File(p.join(scheme.dir!, 'a.glsl')).existsSync(), isTrue);
    expect(scheme.note, contains('扩展'));
    expect(scheme.note, contains('v1.0.0'));
    expect(scheme.note, contains('MIT'), reason: 'LGPL/MIT 许可要能一眼看到');
    expect(scheme.shortName.length, lessThanOrEqualTo(8));
  });

  test('被禁用 → 不出现（文件还在）', () async {
    final Directory support = _newSupportDir();
    addTearDown(() => support.deleteSync(recursive: true));
    final Directory ext = Directory(p.join(support.path, kExtensionsDirName, 'off-pack'))
      ..createSync(recursive: true);
    _writeManifest(ext, _manifest(id: 'off-pack', name: '关掉的包'));
    _writeShaderFiles(ext, 'shaders', <String>['a.glsl']);
    _writeState(support, <String, Object?>{
      'off-pack': <String, Object?>{'enabled': false},
    });

    expect(await loadExtensionUpscaleSchemes(support), isEmpty);
  });

  test('数据包（data-pack）→ 不出现（本版本不接运行时）', () async {
    final Directory support = _newSupportDir();
    addTearDown(() => support.deleteSync(recursive: true));
    final Directory ext = Directory(p.join(support.path, kExtensionsDirName, 'data-pack'))
      ..createSync(recursive: true);
    _writeManifest(ext, _manifest(id: 'data-pack', name: '数据包', kind: 'data-pack'));
    _writeShaderFiles(ext, 'shaders', <String>['a.glsl']);

    expect(await loadExtensionUpscaleSchemes(support), isEmpty);
  });

  test('清单不合法 / 目录名与清单 id 不一致 → 跳过（不崩）', () async {
    final Directory support = _newSupportDir();
    addTearDown(() => support.deleteSync(recursive: true));

    final Directory broken = Directory(p.join(support.path, kExtensionsDirName, 'broken'))
      ..createSync(recursive: true);
    File(p.join(broken.path, 'manifest.json')).writeAsStringSync('{ 这不是 json');

    final Directory renamed = Directory(p.join(support.path, kExtensionsDirName, 'dir-name'))
      ..createSync(recursive: true);
    _writeManifest(renamed, _manifest(id: 'other-id', name: '名字不一致'));
    _writeShaderFiles(renamed, 'shaders', <String>['a.glsl']);

    expect(await loadExtensionUpscaleSchemes(support), isEmpty);
  });

  test('shader 文件被手删了 → 跳过（不许给出挂不上的方案）', () async {
    final Directory support = _newSupportDir();
    addTearDown(() => support.deleteSync(recursive: true));
    final Directory ext = Directory(p.join(support.path, kExtensionsDirName, 'half-pack'))
      ..createSync(recursive: true);
    _writeManifest(ext, _manifest(
      id: 'half-pack',
      name: '半截包',
      shaderFiles: <String>['a.glsl', 'b.glsl'],
    ));
    _writeShaderFiles(ext, 'shaders', <String>['a.glsl']); // b.glsl 不写 = 缺失

    expect(await loadExtensionUpscaleSchemes(support), isEmpty);
  });

  test('state.json 坏了 → 按"全部启用"照常扫（目录存在即安装）', () async {
    final Directory support = _newSupportDir();
    addTearDown(() => support.deleteSync(recursive: true));
    final Directory ext = Directory(p.join(support.path, kExtensionsDirName, 'good-pack'))
      ..createSync(recursive: true);
    _writeManifest(ext, _manifest(id: 'good-pack', name: '好包'));
    _writeShaderFiles(ext, 'shaders', <String>['a.glsl']);
    File(p.join(support.path, kExtensionsDirName, kExtensionsStateFileName))
      ..createSync(recursive: true)
      ..writeAsStringSync('{ 坏掉的 json');

    final List<UpscaleScheme> schemes = await loadExtensionUpscaleSchemes(support);
    expect(schemes.map((UpscaleScheme s) => s.id), <String>['good-pack']);
  });

  test('shader.dir 为空 → 方案目录就是扩展根目录', () async {
    final Directory support = _newSupportDir();
    addTearDown(() => support.deleteSync(recursive: true));
    final Directory ext = Directory(p.join(support.path, kExtensionsDirName, 'flat-pack'))
      ..createSync(recursive: true);
    _writeManifest(ext, _manifest(
      id: 'flat-pack',
      name: '扁平包',
      shaderDir: '',
      shaderFiles: <String>['a.glsl'],
    ));
    _writeShaderFiles(ext, '', <String>['a.glsl']);

    final List<UpscaleScheme> schemes = await loadExtensionUpscaleSchemes(support);
    expect(schemes.single.dir, ext.path);
  });

  test('没有扩展目录 / 只有内部目录 → 空表，不抛', () async {
    final Directory support = _newSupportDir();
    addTearDown(() => support.deleteSync(recursive: true));
    expect(await loadExtensionUpscaleSchemes(support), isEmpty);

    Directory(p.join(support.path, kExtensionsDirName, '.staging')).createSync(recursive: true);
    Directory(p.join(support.path, kExtensionsDirName, '.trash')).createSync(recursive: true);
    expect(await loadExtensionUpscaleSchemes(support), isEmpty);
  });

  test('多个扩展按名字排序（菜单顺序稳定）', () async {
    final Directory support = _newSupportDir();
    addTearDown(() => support.deleteSync(recursive: true));
    for (final (String id, String name) in <(String, String)>[
      ('zzz-pack', 'Zeta 包'),
      ('aaa-pack', 'Alpha 包'),
      ('mmm-pack', 'Mu 包'),
    ]) {
      final Directory ext = Directory(p.join(support.path, kExtensionsDirName, id))
        ..createSync(recursive: true);
      _writeManifest(ext, _manifest(id: id, name: name));
      _writeShaderFiles(ext, 'shaders', <String>['a.glsl']);
    }
    final List<UpscaleScheme> schemes = await loadExtensionUpscaleSchemes(support);
    expect(schemes.map((UpscaleScheme s) => s.id), <String>['aaa-pack', 'mmm-pack', 'zzz-pack']);
  });
}
