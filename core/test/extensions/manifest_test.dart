/// 扩展清单（`manifest.json`）与在线目录（`catalog.json`）解析的离线判据（1.1.0 M3 / T13）。
///
/// 每条测试对应 `core/lib/extensions/manifest.dart` 里的一条**判据**：缺字段、
/// 格式不认识、路径不安全、哈希不合法、版本不兼容、shader 描述不全……断言精确到
/// [ManifestIssue.field]（必要时连 message 一起钉），而不是只看 `ok`。
///
/// 文件末尾那组原本钉的是"当前实现的实际行为"（三个缺口已回报 Lead）；
/// **第六十三轮 Lead 已修**（schema 1.5 / id 保留设备名 / id 尾点），所以那组现在钉的是
/// "必须拒"，并且每条都绑一个理由。
library;

import 'package:dsanima_core/dsanima_core.dart';
import 'package:flutter_test/flutter_test.dart';

// ── 夹具 ────────────────────────────────────────────────────────────────────

/// 64 位十六进制 sha256（默认全 a；[fill] 用来造大小写不同的样例）。
String _sha([String fill = 'a']) => fill * 64;

/// 一个 files 条目（默认合法：路径 + 字节数 + 64 位 sha256）。
Map<String, Object?> _file(String path, {int size = 12, String? sha256}) =>
    _fileRaw(path, size: size, sha256: sha256 ?? _sha());

/// 允许把 size/sha256 传成非法值（`null` = 干脆不写这个键）。
Map<String, Object?> _fileRaw(String path, {Object? size = 12, Object? sha256}) =>
    <String, Object?>{
      'path': path,
      'size': ?size,
      'sha256': ?sha256,
    };

/// 合法最小清单：data-pack + 一个文件（schema/id/name/version/kind 都齐）。
Map<String, Object?> _validManifest() => <String, Object?>{
      'schema': 1,
      'id': 'demo-pack',
      'name': '演示扩展',
      'version': '1.0.0',
      'kind': 'data-pack',
      'files': <Object?>[_file('data/a.bin')],
    };

/// 合法 shader-pack 清单（两个 glsl，按顺序挂载）。
///
/// 参数都是"把某个判据掰弯"的入口：`shaderFiles: null` = 不写 files 键、
/// `pipeline: null` = 不写 pipeline（走默认）、`includePayload: false` = 没有 payload、
/// `shader` 非 null 时直接替换 `payload.shader` 的整个值（用来喂非对象）。
Map<String, Object?> _shaderManifest({
  String kind = 'shader-pack',
  List<Object?>? files,
  Object? dir = 'shaders',
  Object? shaderFiles = const <Object?>['a.glsl', 'b.glsl'],
  Object? pipeline = 'glsl-shaders',
  Object? shader,
  bool includePayload = true,
}) {
  final List<Object?> declared = files ??
      <Object?>[
        _file('shaders/a.glsl', size: 10),
        _file('shaders/b.glsl', size: 20),
      ];
  return <String, Object?>{
    'schema': 1,
    'id': 'demo-shader',
    'name': '演示着色器包',
    'version': '1.0.0',
    'kind': kind,
    'files': declared,
    if (includePayload)
      'payload': <String, Object?>{
        'shader': shader ??
            <String, Object?>{
              'dir': dir,
              'files': shaderFiles,
              'pipeline': ?pipeline,
            },
      },
  };
}

/// 解析并要求"能装"：issues 为空、ok 为 true、manifest 非 null。
ManifestParseResult _accepted(Object? raw, {String? currentAppVersion}) {
  final ManifestParseResult result = parseExtensionManifest(raw, currentAppVersion: currentAppVersion);
  expect(result.issues, isEmpty, reason: '不应有致命问题');
  expect(result.ok, isTrue);
  expect(result.manifest, isNotNull);
  return result;
}

/// 解析并要求"不能装"：ok 为 false、manifest 为 null、issues 里有 [field]。
ManifestParseResult _rejected(Object? raw, String field, {String? currentAppVersion}) {
  final ManifestParseResult result = parseExtensionManifest(raw, currentAppVersion: currentAppVersion);
  expect(result.ok, isFalse, reason: '应当拒绝（$field）');
  expect(result.manifest, isNull);
  expect(
    result.issues.where((ManifestIssue issue) => issue.field == field),
    isNotEmpty,
    reason: 'issues 里应有 $field，实际为 ${result.issues}',
  );
  return result;
}

/// issues 里 [field] 那条的 message（用来钉"为什么拒绝"）。
String _issueMessage(ManifestParseResult result, String field) =>
    result.issues.firstWhere((ManifestIssue issue) => issue.field == field).message;

/// 构造 `files` 列表（[count] 个互不相同的合法文件）。
List<Object?> _files(int count) => <Object?>[
      for (int i = 0; i < count; i++) _file('f$i.bin'),
    ];

// ── catalog 夹具 ────────────────────────────────────────────────────────────

final Uri _catalogBase = Uri.parse('https://example.com/ext/catalog.json');

Map<String, Object?> _catalog(List<Object?> entries, {Object? schema = 1}) =>
    <String, Object?>{
      'schema': ?schema,
      'extensions': entries,
    };

/// 一条目录条目；`url: null` = 不写 url，`size`/`sha256` 缺失时不写键。
Map<String, Object?> _catalogEntry({
  Map<String, Object?>? manifest,
  String? url = 'pkg-1.0.0.zip',
  Object? size,
  Object? sha256,
}) =>
    <String, Object?>{
      'manifest': ?manifest,
      'url': ?url,
      'size': ?size,
      'sha256': ?sha256,
    };

CatalogParseResult _parseCatalog(Object? raw, {String? currentAppVersion}) =>
    parseExtensionCatalog(raw, baseUrl: _catalogBase, currentAppVersion: currentAppVersion);

CatalogParseResult _catalogRejected(Object? raw, String field, {String? currentAppVersion}) {
  final CatalogParseResult result = _parseCatalog(raw, currentAppVersion: currentAppVersion);
  expect(result.ok, isFalse, reason: '应当有致命问题（$field）');
  expect(
    result.issues.where((ManifestIssue issue) => issue.field == field),
    isNotEmpty,
    reason: 'issues 里应有 $field，实际为 ${result.issues}',
  );
  return result;
}

String _catalogIssueMessage(CatalogParseResult result, String field) =>
    result.issues.firstWhere((ManifestIssue issue) => issue.field == field).message;

/// 一个合法的目录条目（data-pack 清单 + 相对 url）。
Map<String, Object?> _goodCatalogEntry({String id = 'demo-pack', Object? size, Object? sha256}) =>
    _catalogEntry(
      manifest: _validManifest()..['id'] = id,
      size: size,
      sha256: sha256,
    );

// ── 测试 ────────────────────────────────────────────────────────────────────

void main() {
  group('parseExtensionManifest：顶层与 schema', () {
    test('合法最小清单：字段逐项读出、issues/warnings 为空、raw 原样保留', () {
      final Map<String, Object?> raw = _validManifest();
      final ManifestParseResult result = _accepted(raw);
      expect(result.warnings, isEmpty);
      final ExtensionManifest manifest = result.manifest!;

      expect(manifest.schema, 1);
      expect(manifest.id, 'demo-pack');
      expect(manifest.name, '演示扩展');
      expect(manifest.version, '1.0.0');
      expect(manifest.kind, ExtensionKind.dataPack);
      expect(manifest.description, '');
      expect(manifest.author, isNull);
      expect(manifest.license, isNull);
      expect(manifest.homepage, isNull);
      expect(manifest.minAppVersion, isNull);
      expect(manifest.files, hasLength(1));
      expect(manifest.files.single.path, 'data/a.bin');
      expect(manifest.files.single.size, 12);
      expect(manifest.files.single.sha256, _sha());
      expect(manifest.shader, isNull);
      expect(manifest.isKnownKind, isTrue);
      expect(manifest.isUsable, isFalse);
      expect(manifest.raw, equals(raw));
      expect(manifest.toJson(), same(manifest.raw));
    });

    test('顶层不是 JSON 对象（null/列表/字符串/数字/布尔）→ 唯一一条 field=manifest', () {
      for (final Object? value in <Object?>[null, <Object?>[], 'manifest', 42, true]) {
        final ManifestParseResult result = parseExtensionManifest(value);
        expect(result.ok, isFalse);
        expect(result.manifest, isNull);
        expect(result.issues, hasLength(1));
        expect(result.issues.single.field, 'manifest');
        expect(result.warnings, isEmpty);
      }
    });

    test('schema 缺省 / 1（int）/ 1.0（num）都通过，解析结果 schema=1', () {
      final ManifestParseResult missing = _accepted(_validManifest()..remove('schema'));
      expect(missing.manifest!.schema, 1);
      final ManifestParseResult one = _accepted(_validManifest()..['schema'] = 1);
      expect(one.manifest!.schema, 1);
      final ManifestParseResult oneDouble = _accepted(_validManifest()..['schema'] = 1.0);
      expect(oneDouble.manifest!.schema, 1);
    });

    test('schema 不是 1（2 / 字符串 "1" / 布尔）→ field=schema 的致命问题', () {
      final ManifestParseResult two = _rejected(_validManifest()..['schema'] = 2, 'schema');
      expect(_issueMessage(two, 'schema'), contains('只认 1'));
      final ManifestParseResult text = _rejected(_validManifest()..['schema'] = '1', 'schema');
      expect(_issueMessage(text, 'schema'), contains('不认识'));
      _rejected(_validManifest()..['schema'] = true, 'schema');
    });
  });

  group('parseExtensionManifest：id', () {
    test('id 缺失、空串或纯空白 → field=id', () {
      _rejected(_validManifest()..remove('id'), 'id');
      _rejected(_validManifest()..['id'] = '', 'id');
      final ManifestParseResult blank = _rejected(_validManifest()..['id'] = '   ', 'id');
      expect(_issueMessage(blank, 'id'), contains('缺少扩展 id'));
    });

    test('id 大写 / 含空格 / 点开头 / 斜杠 / 单字符 / "."/".." → field=id 且提示不合规', () {
      for (final String bad in <String>[
        'Anime4K',
        'bad id',
        '.hidden',
        'a/b',
        '-lead',
        'a:b',
        r'a\b',
        'a',
        '.',
        '..',
      ]) {
        final ManifestParseResult result = _rejected(_validManifest()..['id'] = bad, 'id');
        expect(_issueMessage(result, 'id'), contains('不合规'), reason: 'id=$bad');
      }
    });

    test('id 长度 2 与 64 通过，1 与 65 拒绝', () {
      final String id64 = 'a${'b' * 63}';
      expect(id64.length, 64);
      expect(_accepted(_validManifest()..['id'] = 'ab').manifest!.id, 'ab');
      expect(_accepted(_validManifest()..['id'] = id64).manifest!.id, id64);
      _rejected(_validManifest()..['id'] = 'a', 'id');
      _rejected(_validManifest()..['id'] = 'a${'b' * 64}', 'id');
    });

    test('保留 id（anime4k / anime4k-ultra）→ field=id 且提示重名', () {
      for (final String reserved in <String>['anime4k', 'anime4k-ultra']) {
        final ManifestParseResult result = _rejected(_validManifest()..['id'] = reserved, 'id');
        expect(_issueMessage(result, 'id'), contains('重名'), reason: 'id=$reserved');
      }
    });

    test('id 里的 . _ - 被接受', () {
      const String id = 'a.b_c-d';
      expect(_accepted(_validManifest()..['id'] = id).manifest!.id, id);
    });
  });

  group('parseExtensionManifest：name', () {
    test('name 缺失或空串 → field=name', () {
      final ManifestParseResult missing = _rejected(_validManifest()..remove('name'), 'name');
      expect(_issueMessage(missing, 'name'), contains('缺少 name'));
      _rejected(_validManifest()..['name'] = '   ', 'name');
    });

    test('name 恰好 80 字符通过，81 字符拒绝（界面放不下）', () {
      final String name80 = 'a' * 80;
      expect(_accepted(_validManifest()..['name'] = name80).manifest!.name, name80);
      final ManifestParseResult tooLong = _rejected(_validManifest()..['name'] = 'a' * 81, 'name');
      expect(_issueMessage(tooLong, 'name'), contains('80'));
    });

    test('name 两头空白被 trim', () {
      final ExtensionManifest manifest =
          _accepted(_validManifest()..['name'] = '  我的扩展  ').manifest!;
      expect(manifest.name, '我的扩展');
    });
  });

  group('parseExtensionManifest：version', () {
    test('version 缺失或空串 → field=version', () {
      final ManifestParseResult missing = _rejected(_validManifest()..remove('version'), 'version');
      expect(_issueMessage(missing, 'version'), contains('缺少 version'));
      _rejected(_validManifest()..['version'] = '  ', 'version');
    });

    test('version 不是版本号（latest / 四段 / 空段）→ field=version', () {
      for (final String bad in <String>['latest', '1.2.3.4', '1..2', 'v', 'abc']) {
        final ManifestParseResult result = _rejected(_validManifest()..['version'] = bad, 'version');
        expect(_issueMessage(result, 'version'), contains('不是版本号'), reason: 'version=$bad');
      }
    });

    test('version 容忍 v 前缀 / 少写段 / +build，原串保留', () {
      for (final String version in <String>['v1.2.3', '1.2', '1.0.0+4']) {
        final ExtensionManifest manifest =
            _accepted(_validManifest()..['version'] = version).manifest!;
        expect(manifest.version, version);
      }
    });
  });

  group('parseExtensionManifest：kind', () {
    test('kind 缺失或空串 → field=kind', () {
      final ManifestParseResult missing = _rejected(_validManifest()..remove('kind'), 'kind');
      expect(_issueMessage(missing, 'kind'), contains('缺少 kind'));
      _rejected(_validManifest()..['kind'] = '', 'kind');
    });

    test('kind 不是合法类型名（大写 / 下划线 / 点 / 空格 / 单字符 / 超长）→ field=kind', () {
      for (final String bad in <String>[
        'Shader-Pack',
        'shader_pack',
        'shader.pack',
        'shader pack',
        '-shader',
        'x',
        'a' * 33,
      ]) {
        final ManifestParseResult result = _rejected(_validManifest()..['kind'] = bad, 'kind');
        expect(_issueMessage(result, 'kind'), contains('不是合法类型名'), reason: 'kind=$bad');
      }
    });

    test('已知类型 data-pack 没有 warning，isKnownKind=true', () {
      final ManifestParseResult result = _accepted(_validManifest()..['kind'] = 'data-pack');
      expect(result.warnings, isEmpty);
      expect(result.manifest!.isKnownKind, isTrue);
    });

    test('未来类型（不认识 ≠ 非法）：能装但只给 warning，宿主当"不支持"', () {
      final ManifestParseResult result = _accepted(_validManifest()..['kind'] = 'future-pack');
      expect(result.warnings, hasLength(1));
      expect(result.warnings.single.field, 'kind');
      expect(result.warnings.single.message, contains('不认识'));
      expect(result.manifest!.isKnownKind, isFalse);
      expect(result.manifest!.isUsable, isFalse);
      expect(ExtensionKind.labelOf('future-pack'), contains('未知类型'));
    });
  });

  group('parseExtensionManifest：minAppVersion', () {
    test('minAppVersion 高于当前版本 → field=minAppVersion，拒绝安装', () {
      final ManifestParseResult result = _rejected(
        _validManifest()..['minAppVersion'] = '1.2.0',
        'minAppVersion',
        currentAppVersion: '1.1.0',
      );
      final String message = _issueMessage(result, 'minAppVersion');
      expect(message, contains('1.2.0'));
      expect(message, contains('当前 1.1.0'));
      _rejected(
        _validManifest()..['minAppVersion'] = '1.1.1',
        'minAppVersion',
        currentAppVersion: '1.1.0',
      );
    });

    test('minAppVersion 等于或低于当前版本 → 通过，字段保留', () {
      final ManifestParseResult equal = _accepted(
        _validManifest()..['minAppVersion'] = '1.1.0',
        currentAppVersion: '1.1.0',
      );
      expect(equal.manifest!.minAppVersion, '1.1.0');
      _accepted(
        _validManifest()..['minAppVersion'] = '1.0.0',
        currentAppVersion: '1.1.0',
      );
    });

    test('build 号参与比较：1.1.0 < 1.1.0+1', () {
      _accepted(
        _validManifest()..['minAppVersion'] = '1.1.0',
        currentAppVersion: '1.1.0+1',
      );
      _rejected(
        _validManifest()..['minAppVersion'] = '1.1.0+1',
        'minAppVersion',
        currentAppVersion: '1.1.0',
      );
    });

    test('minAppVersion 不是版本号 → field=minAppVersion（即使没有当前版本）', () {
      final ManifestParseResult result =
          _rejected(_validManifest()..['minAppVersion'] = 'latest', 'minAppVersion');
      expect(_issueMessage(result, 'minAppVersion'), contains('不是版本号'));
    });

    test('minAppVersion 缺失或空串 = 不限制；currentAppVersion 为 null 时跳过兼容检查', () {
      final ManifestParseResult missing = _accepted(_validManifest()..['minAppVersion'] = '');
      expect(missing.manifest!.minAppVersion, isNull);
      final ManifestParseResult skipped =
          _accepted(_validManifest()..['minAppVersion'] = '9.9.9');
      expect(skipped.manifest!.minAppVersion, '9.9.9');
    });
  });

  group('parseExtensionManifest：files', () {
    test('files 缺失 / 不是列表 / 空列表 → field=files', () {
      final ManifestParseResult missing = _rejected(_validManifest()..remove('files'), 'files');
      expect(_issueMessage(missing, 'files'), contains('缺少 files'));
      _rejected(_validManifest()..['files'] = 'a.glsl', 'files');
      final ManifestParseResult empty =
          _rejected(_validManifest()..['files'] = <Object?>[], 'files');
      expect(_issueMessage(empty, 'files'), contains('空的'));
    });

    test('files 元素不是对象 → field=files[下标]', () {
      _rejected(_validManifest()..['files'] = <Object?>['junk'], 'files[0]');
      _rejected(
        _validManifest()
          ..['files'] = <Object?>[
            _file('data/a.bin'),
            'junk',
          ],
        'files[1]',
      );
    });

    test('path 缺失或空串 → field=files[i].path', () {
      _rejected(
        _validManifest()
          ..['files'] = <Object?>[
            <String, Object?>{'size': 1, 'sha256': _sha()},
          ],
        'files[0].path',
      );
      _rejected(
        _validManifest()
          ..['files'] = <Object?>[
            <String, Object?>{'path': '   ', 'size': 1, 'sha256': _sha()},
          ],
        'files[0].path',
      );
    });

    test('path 穿越 / 绝对 / 盘符 / 反斜杠 / 空段 / 保留名 → field=files[i].path', () {
      for (final String bad in <String>[
        '../../evil',
        'a/../b',
        '/etc/passwd',
        'C:/Windows/x',
        r'a\b',
        'a//b',
        'CON',
      ]) {
        final ManifestParseResult result =
            _rejected(_validManifest()..['files'] = <Object?>[_file(bad)], 'files[0].path');
        expect(_issueMessage(result, 'files[0].path'), contains('不可用'), reason: 'path=$bad');
      }
    });

    test('files 列了 manifest.json（大小写不敏感）→ field=files[i].path', () {
      for (final String path in <String>['manifest.json', 'Manifest.json', 'MANIFEST.JSON']) {
        final ManifestParseResult result =
            _rejected(_validManifest()..['files'] = <Object?>[_file(path)], 'files[0].path');
        expect(_issueMessage(result, 'files[0].path'), contains('不要再列'), reason: 'path=$path');
      }
    });

    test('files 路径重复（仅大小写不同）→ field=files[1].path', () {
      final ManifestParseResult result = _rejected(
        _validManifest()
          ..['files'] = <Object?>[
            _file('Shaders/A.glsl'),
            _file('shaders/a.glsl'),
          ],
        'files[1].path',
      );
      expect(_issueMessage(result, 'files[1].path'), contains('重复'));
    });

    test('size 负数 / 小数 / 字符串 / 布尔 / 缺失 → field=files[i].size', () {
      for (final Object? bad in <Object?>[-1, 1.5, '12', true]) {
        final ManifestParseResult result = _rejected(
          _validManifest()
            ..['files'] = <Object?>[
              _fileRaw('data/a.bin', size: bad),
            ],
          'files[0].size',
        );
        expect(_issueMessage(result, 'files[0].size'), contains('非负整数'), reason: 'size=$bad');
      }
      _rejected(
        _validManifest()
          ..['files'] = <Object?>[
            _fileRaw('data/a.bin', size: null),
          ],
        'files[0].size',
      );
    });

    test('size 恰好等于单文件上限通过，多 1 字节拒绝', () {
      final ExtensionManifest manifest = _accepted(
        _validManifest()
          ..['files'] = <Object?>[
            _file('data/a.bin', size: kPackageMaxEntryBytes),
          ],
      ).manifest!;
      expect(manifest.files.single.size, kPackageMaxEntryBytes);
      final ManifestParseResult result = _rejected(
        _validManifest()
          ..['files'] = <Object?>[
            _file('data/a.bin', size: kPackageMaxEntryBytes + 1),
          ],
        'files[0].size',
      );
      expect(_issueMessage(result, 'files[0].size'), contains('上限'));
    });

    test('sha256 非 64 位十六进制（短 / 长 / 非 hex / 数字 / 缺失）→ field=files[i].sha256', () {
      for (final Object? bad in <Object?>[
        'abc',
        'a' * 63,
        'a' * 65,
        'z' * 64,
        123,
        null,
      ]) {
        final ManifestParseResult result = _rejected(
          _validManifest()
            ..['files'] = <Object?>[
              _fileRaw('data/a.bin', sha256: bad),
            ],
          'files[0].sha256',
        );
        expect(_issueMessage(result, 'files[0].sha256'), contains('64 位十六进制'), reason: 'sha=$bad');
      }
    });

    test('sha256 大写 hex 接受并规范成小写', () {
      final ExtensionManifest manifest = _accepted(
        _validManifest()
          ..['files'] = <Object?>[
            _fileRaw('data/a.bin', sha256: _sha('A')),
          ],
      ).manifest!;
      expect(manifest.files.single.sha256, _sha('a'));
    });

    test('多文件顺序原样保留，size=0 是合法文件', () {
      final ExtensionManifest manifest = _accepted(
        _validManifest()
          ..['files'] = <Object?>[
            _file('z.glsl'),
            _file('a/b.glsl', size: 0),
          ],
      ).manifest!;
      expect(manifest.files.map((ExtensionFile file) => file.path), <String>['z.glsl', 'a/b.glsl']);
      expect(manifest.files.last.size, 0);
    });

    test('条目数恰好等于上限通过，超过上限拒绝（field=files）', () {
      final ExtensionManifest manifest =
          _accepted(_validManifest()..['files'] = _files(kPackageMaxEntries)).manifest!;
      expect(manifest.files, hasLength(kPackageMaxEntries));
      final ManifestParseResult result =
          _rejected(_validManifest()..['files'] = _files(kPackageMaxEntries + 1), 'files');
      expect(_issueMessage(result, 'files'), contains(kPackageMaxEntries.toString()));
    });
  });

  group('parseExtensionManifest：payload.shader（shader-pack）', () {
    test('合法 shader-pack：dir/files/pipeline 读出，rootRelativePaths 与 files 同口径', () {
      final ExtensionManifest manifest = _accepted(_shaderManifest()).manifest!;
      expect(manifest.isKnownKind, isTrue);
      expect(manifest.isUsable, isTrue);
      final ExtensionShaderSpec shader = manifest.shader!;
      expect(shader.dir, 'shaders');
      expect(shader.files, <String>['a.glsl', 'b.glsl']);
      expect(shader.pipeline, kGlslShadersPipeline);
      expect(shader.rootRelativePaths, <String>['shaders/a.glsl', 'shaders/b.glsl']);
      expect(shader.toJson(), <String, Object?>{
        'dir': 'shaders',
        'files': <String>['a.glsl', 'b.glsl'],
        'pipeline': 'glsl-shaders',
      });
    });

    test('dir 为空 = shader 放在扩展根，rootRelativePaths 不带目录', () {
      final ExtensionManifest manifest = _accepted(
        _shaderManifest(
          dir: '',
          files: <Object?>[_file('a.glsl'), _file('b.glsl')],
        ),
      ).manifest!;
      expect(manifest.shader!.dir, '');
      expect(manifest.shader!.rootRelativePaths, <String>['a.glsl', 'b.glsl']);
    });

    test('pipeline 缺失或空串 → 默认 glsl-shaders', () {
      expect(_accepted(_shaderManifest(pipeline: null)).manifest!.shader!.pipeline,
          kGlslShadersPipeline);
      expect(_accepted(_shaderManifest(pipeline: '')).manifest!.shader!.pipeline,
          kGlslShadersPipeline);
    });

    test('pipeline 不是 glsl-shaders（compute）→ field=payload.shader.pipeline', () {
      final ManifestParseResult result = _rejected(
        _shaderManifest(pipeline: 'compute'),
        'payload.shader.pipeline',
      );
      expect(_issueMessage(result, 'payload.shader.pipeline'), contains('glsl-shaders'));
    });

    test('shader-pack 没有 payload.shader → field=payload.shader', () {
      final ManifestParseResult result =
          _rejected(_shaderManifest(includePayload: false), 'payload.shader');
      expect(_issueMessage(result, 'payload.shader'), contains('必须带 payload.shader'));
    });

    test('payload.shader 不是对象 → field=payload.shader', () {
      for (final Object? bad in <Object?>['junk', <Object?>[]]) {
        final ManifestParseResult result = _rejected(_shaderManifest(shader: bad), 'payload.shader');
        expect(_issueMessage(result, 'payload.shader'), contains('必须是对象'));
      }
    });

    test('payload 不是对象 → field=payload，并且 shader-pack 仍缺 shader 描述', () {
      final ManifestParseResult result =
          _rejected(_shaderManifest()..['payload'] = <Object?>['x'], 'payload');
      expect(result.issues.map((ManifestIssue issue) => issue.field),
          containsAll(<String>['payload', 'payload.shader']));
    });

    test('dir 穿越 / 绝对 / 尾斜杠 / 回退段 → field=payload.shader.dir', () {
      for (final Object? badDir in <Object?>['../shaders', '/shaders', 'shaders/', 'shaders/../x']) {
        final ManifestParseResult result =
            _rejected(_shaderManifest(dir: badDir), 'payload.shader.dir');
        expect(_issueMessage(result, 'payload.shader.dir'), contains('不可用'),
            reason: 'dir=$badDir');
      }
    });

    test('shader.files 缺失 / 不是列表 / 空列表 → field=payload.shader.files', () {
      for (final Object? badFiles in <Object?>[null, 'a.glsl', <Object?>[]]) {
        final ManifestParseResult result =
            _rejected(_shaderManifest(shaderFiles: badFiles), 'payload.shader.files');
        expect(_issueMessage(result, 'payload.shader.files'), contains('为空'));
      }
    });

    test('shader 文件名空串或纯空白 → field=payload.shader.files[i]', () {
      for (final Object? badName in <Object?>['', '   ']) {
        final ManifestParseResult result = _rejected(
          _shaderManifest(shaderFiles: <Object?>[badName]),
          'payload.shader.files[0]',
        );
        expect(_issueMessage(result, 'payload.shader.files[0]'), contains('空的'));
      }
    });

    test('shader 文件名带 / 或 \\ → field=payload.shader.files[i]', () {
      for (final Object? badName in <Object?>['a/b.glsl', r'a\b.glsl']) {
        final ManifestParseResult result = _rejected(
          _shaderManifest(shaderFiles: <Object?>[badName]),
          'payload.shader.files[0]',
        );
        expect(_issueMessage(result, 'payload.shader.files[0]'), contains('不要带目录'));
      }
    });

    test('shader 文件名重复（仅大小写不同）→ field=payload.shader.files[1]', () {
      final ManifestParseResult result = _rejected(
        _shaderManifest(shaderFiles: <Object?>['A.glsl', 'a.glsl']),
        'payload.shader.files[1]',
      );
      expect(_issueMessage(result, 'payload.shader.files[1]'), contains('重复'));
    });

    test('shader 文件名是 Windows 保留设备名 → field=payload.shader.files[i]', () {
      final ManifestParseResult result = _rejected(
        _shaderManifest(shaderFiles: <Object?>['CON.glsl']),
        'payload.shader.files[0]',
      );
      expect(_issueMessage(result, 'payload.shader.files[0]'), contains('文件名不可用'));
    });

    test('shader 文件没在 files 里声明 → 挂载会指向不存在的文件，拒绝', () {
      final ManifestParseResult result = _rejected(
        _shaderManifest(shaderFiles: <Object?>['a.glsl', 'missing.glsl']),
        'payload.shader.files',
      );
      final String message = _issueMessage(result, 'payload.shader.files');
      expect(message, contains('没有列在 files 里'));
      expect(message, contains('shaders/missing.glsl'));
    });

    test('shader 文件已声明但不是 .glsl 后缀 → 只 warning，仍可装', () {
      final ManifestParseResult result = _accepted(
        _shaderManifest(
          files: <Object?>[
            _file('shaders/a.glsl', size: 10),
            _file('shaders/readme.txt', size: 5),
          ],
          shaderFiles: <Object?>['a.glsl', 'readme.txt'],
        ),
      );
      expect(result.warnings, hasLength(1));
      expect(result.warnings.single.field, 'payload.shader.files');
      expect(result.warnings.single.message, contains('.glsl'));
      expect(result.manifest!.isUsable, isTrue);
    });

    test('data-pack 带 payload.shader → 只 warning 并忽略，shader 为 null', () {
      final ManifestParseResult result = _accepted(_shaderManifest(kind: 'data-pack', shader: 'junk'));
      expect(result.warnings, hasLength(1));
      expect(result.warnings.single.field, 'payload.shader');
      expect(result.warnings.single.message, contains('不使用 payload.shader'));
      expect(result.manifest!.shader, isNull);
      expect(result.manifest!.isUsable, isFalse);
    });

    test('未来类型带 payload.shader → kind 与 payload.shader 两条 warning，shader 为 null', () {
      final ManifestParseResult result = _accepted(_shaderManifest(kind: 'future-pack'));
      expect(result.warnings.map((ManifestIssue warning) => warning.field),
          containsAll(<String>['kind', 'payload.shader']));
      expect(result.manifest!.shader, isNull);
      expect(result.manifest!.isKnownKind, isFalse);
      expect(result.manifest!.isUsable, isFalse);
    });
  });

  group('parseExtensionManifest：可选元信息与模型辅助', () {
    test('description/author/license 两头空白被 trim', () {
      final ExtensionManifest manifest = _accepted(
        _validManifest()
          ..['description'] = '  一句话说明  '
          ..['author'] = '  作者  '
          ..['license'] = '  MIT  ',
      ).manifest!;
      expect(manifest.description, '一句话说明');
      expect(manifest.author, '作者');
      expect(manifest.license, 'MIT');
    });

    test('homepage 不是网址 → 只 warning；合法 https 地址没有 warning', () {
      final ManifestParseResult bad = _accepted(_validManifest()..['homepage'] = 'example.com');
      expect(bad.warnings, hasLength(1));
      expect(bad.warnings.single.field, 'homepage');
      expect(bad.warnings.single.message, contains('不是网址'));
      expect(bad.manifest!.homepage, 'example.com');

      final ManifestParseResult good =
          _accepted(_validManifest()..['homepage'] = 'https://example.com/x');
      expect(good.warnings, isEmpty);
      expect(good.manifest!.homepage, 'https://example.com/x');
    });

    test('raw 原样保留（含未知字段），toJson 返回同一个 map', () {
      final Map<String, Object?> raw = _validManifest()
        ..['futureField'] = <String, Object?>{'nested': <Object?>[1, 2]};
      final ExtensionManifest manifest = _accepted(raw).manifest!;
      expect(manifest.raw, equals(raw));
      expect(manifest.raw['futureField'], equals(<String, Object?>{'nested': <Object?>[1, 2]}));
      expect(manifest.toJson(), same(manifest.raw));
    });

    test('files 列表不可变；filesByPath 键为小写（Windows 不区分大小写）', () {
      final ExtensionManifest manifest = _accepted(
        _validManifest()
          ..['files'] = <Object?>[
            _file('Data/File.BIN'),
            _file('x.bin'),
          ],
      ).manifest!;
      expect(manifest.filesByPath.keys, containsAll(<String>['data/file.bin', 'x.bin']));
      expect(manifest.filesByPath['data/file.bin']!.size, 12);
      expect(
        () => manifest.files.add(const ExtensionFile(path: 'y', size: 1, sha256: 'a')),
        throwsUnsupportedError,
      );
    });

    test('ExtensionFile.toJson / ManifestIssue.toString / ExtensionKind 辅助', () {
      final ExtensionManifest manifest = _accepted(_validManifest()).manifest!;
      expect(manifest.files.single.toJson(), <String, Object?>{
        'path': 'data/a.bin',
        'size': 12,
        'sha256': _sha(),
      });
      expect(
        const ManifestIssue('files[0].path', '路径不可用').toString(),
        'files[0].path: 路径不可用',
      );
      expect(ExtensionKind.labels, hasLength(2));
      expect(ExtensionKind.labels[ExtensionKind.shaderPack], '着色器包');
      expect(ExtensionKind.labelOf(ExtensionKind.dataPack), '数据包');
      expect(ExtensionKind.isKnown(ExtensionKind.shaderPack), isTrue);
      expect(ExtensionKind.isKnown('future-pack'), isFalse);
    });

    test('expectedPackageFiles = manifest.json + 清单里声明的全部文件', () {
      final ExtensionManifest manifest = _accepted(_shaderManifest()).manifest!;
      expect(expectedPackageFiles(manifest), <String>{
        'manifest.json',
        'shaders/a.glsl',
        'shaders/b.glsl',
      });
    });

    test('导出常量就是契约：保留 id 集合与唯一 shader 管线', () {
      expect(kReservedExtensionIds, containsAll(<String>['anime4k', 'anime4k-ultra']));
      expect(kGlslShadersPipeline, 'glsl-shaders');
    });
  });

  group('parseExtensionCatalog：顶层与 schema', () {
    test('合法目录：manifest 解析、相对 url 按 base 补全、size/sha256 读出', () {
      final CatalogParseResult result = _parseCatalog(_catalog(<Object?>[
        _goodCatalogEntry(size: 123, sha256: _sha('B')),
      ]));
      expect(result.ok, isTrue);
      expect(result.issues, isEmpty);
      expect(result.warnings, isEmpty);
      expect(result.entries, hasLength(1));
      final CatalogEntry entry = result.entries.single;
      expect(entry.manifest.id, 'demo-pack');
      expect(entry.url, Uri.parse('https://example.com/ext/pkg-1.0.0.zip'));
      expect(entry.size, 123);
      expect(entry.sha256, _sha('b'));
    });

    test('顶层不是 JSON 对象 → 唯一一条 field=catalog，entries 为空', () {
      for (final Object? value in <Object?>[null, <Object?>[], 'x', 1]) {
        final CatalogParseResult result = _parseCatalog(value);
        expect(result.ok, isFalse);
        expect(result.entries, isEmpty);
        expect(result.issues.single.field, 'catalog');
      }
    });

    test('schema 缺省或 1.0 通过；schema 2 报 schema（ok=false 拦住调用方）', () {
      final CatalogParseResult missing =
          _parseCatalog(_catalog(<Object?>[_goodCatalogEntry()], schema: null));
      expect(missing.ok, isTrue);

      final CatalogParseResult oneDouble =
          _parseCatalog(_catalog(<Object?>[_goodCatalogEntry()], schema: 1.0));
      expect(oneDouble.ok, isTrue);

      final CatalogParseResult two = _catalogRejected(
        _catalog(<Object?>[_goodCatalogEntry()], schema: 2),
        'schema',
      );
      expect(_catalogIssueMessage(two, 'schema'), contains('只认 1'));
      expect(two.entries, hasLength(1));
    });

    test('schema 不是数字（字符串 "1"）→ field=schema', () {
      final CatalogParseResult result = _catalogRejected(
        _catalog(<Object?>[_goodCatalogEntry()], schema: '1'),
        'schema',
      );
      expect(_catalogIssueMessage(result, 'schema'), contains('数字'));
    });

    test('extensions 缺失或不是列表 → field=extensions，entries 为空', () {
      for (final Object? raw in <Object?>[
        <String, Object?>{'schema': 1},
        <String, Object?>{'schema': 1, 'extensions': 'x'},
      ]) {
        final CatalogParseResult result = _catalogRejected(raw, 'extensions');
        expect(result.entries, isEmpty);
      }
    });

    test('extensions 为空列表 → 合法空目录', () {
      final CatalogParseResult result = _parseCatalog(_catalog(<Object?>[]));
      expect(result.ok, isTrue);
      expect(result.entries, isEmpty);
      expect(result.issues, isEmpty);
      expect(result.warnings, isEmpty);
    });

    test('条目不是对象 → field=extensions[0]，后面的好条目照常解析', () {
      final CatalogParseResult result = _catalogRejected(
        _catalog(<Object?>['junk', _goodCatalogEntry()]),
        'extensions[0]',
      );
      expect(result.entries, hasLength(1));
    });
  });

  group('parseExtensionCatalog：url 补全与安全', () {
    test('相对 url 按 catalog.json 的地址补全，绝对 url 原样保留', () {
      final CatalogParseResult result = _parseCatalog(_catalog(<Object?>[
        _goodCatalogEntry(id: 'pack-a'),
        _catalogEntry(manifest: _validManifest()..['id'] = 'pack-b', url: '../pkg.zip'),
        _catalogEntry(
          manifest: _validManifest()..['id'] = 'pack-c',
          url: 'https://cdn.example.com/pkg.zip',
        ),
      ]));
      expect(result.ok, isTrue);
      expect(
        result.entries.map((CatalogEntry entry) => entry.url.toString()),
        <String>[
          'https://example.com/ext/pkg-1.0.0.zip',
          'https://example.com/pkg.zip',
          'https://cdn.example.com/pkg.zip',
        ],
      );
    });

    test('公网 http 地址拒绝（中间人可以换包）', () {
      final CatalogParseResult result = _catalogRejected(
        _catalog(<Object?>[
          _catalogEntry(manifest: _validManifest(), url: 'http://example.com/pkg.zip'),
        ]),
        'extensions[0].url',
      );
      expect(_catalogIssueMessage(result, 'extensions[0].url'), contains('HTTPS'));
      expect(result.entries, isEmpty);
    });

    test('回环 http（localhost / 127.0.0.1 / [::1]）放行：本机测试目录是正当需求', () {
      for (final String url in <String>[
        'http://localhost:8080/pkg.zip',
        'http://127.0.0.1:8080/pkg.zip',
        'http://[::1]:8080/pkg.zip',
      ]) {
        final CatalogParseResult result = _parseCatalog(_catalog(<Object?>[
          _catalogEntry(manifest: _validManifest(), url: url),
        ]));
        expect(result.ok, isTrue, reason: url);
        expect(result.entries, hasLength(1), reason: url);
        expect(result.entries.single.url, Uri.parse(url));
      }
    });

    test('非 http(s) 协议（ftp / javascript）→ field=extensions[i].url', () {
      for (final String url in <String>['ftp://example.com/pkg.zip', 'javascript:alert(1)']) {
        final CatalogParseResult result = _catalogRejected(
          _catalog(<Object?>[_catalogEntry(manifest: _validManifest(), url: url)]),
          'extensions[0].url',
        );
        expect(_catalogIssueMessage(result, 'extensions[0].url'), contains('不支持的协议'),
            reason: url);
      }
    });

    test('缺 url → field=extensions[i].url，条目被丢弃', () {
      final CatalogParseResult result = _catalogRejected(
        _catalog(<Object?>[_catalogEntry(manifest: _validManifest(), url: null)]),
        'extensions[0].url',
      );
      expect(_catalogIssueMessage(result, 'extensions[0].url'), contains('缺少下载地址'));
      expect(result.entries, isEmpty);
    });
  });

  group('parseExtensionCatalog：坏条目不影响好条目', () {
    test('第一条清单非法 → 只丢这一条，第二条照常可用，问题字段带 extensions[i] 前缀', () {
      final CatalogParseResult result = _parseCatalog(_catalog(<Object?>[
        _catalogEntry(manifest: _validManifest()..['id'] = 'Bad'),
        _goodCatalogEntry(),
      ]));
      expect(result.ok, isFalse);
      expect(result.entries, hasLength(1));
      expect(result.entries.single.manifest.id, 'demo-pack');
      expect(result.issues.map((ManifestIssue issue) => issue.field),
          contains('extensions[0].id'));
    });

    test('缺 manifest → field=extensions[i].manifest', () {
      final CatalogParseResult result = _catalogRejected(
        _catalog(<Object?>[_catalogEntry()]),
        'extensions[0].manifest',
      );
      expect(result.entries, isEmpty);
    });

    test('currentAppVersion 透传给清单解析：minAppVersion 太高 → 条目被拒', () {
      final CatalogParseResult result = _catalogRejected(
        _catalog(<Object?>[
          _catalogEntry(manifest: _validManifest()..['minAppVersion'] = '9.0.0'),
        ]),
        'extensions[0].minAppVersion',
        currentAppVersion: '1.1.0',
      );
      expect(result.entries, isEmpty);
    });

    test('清单里的 warning 也带 extensions[i] 前缀，条目仍可用', () {
      final CatalogParseResult result = _parseCatalog(_catalog(<Object?>[
        _catalogEntry(manifest: _validManifest()..['kind'] = 'future-pack'),
      ]));
      expect(result.ok, isTrue);
      expect(result.entries, hasLength(1));
      expect(result.entries.single.manifest.isKnownKind, isFalse);
      expect(result.warnings, hasLength(1));
      expect(result.warnings.single.field, 'extensions[0].kind');
    });

    test('条目顺序原样保留', () {
      final CatalogParseResult result = _parseCatalog(_catalog(<Object?>[
        _goodCatalogEntry(id: 'pack-a'),
        _goodCatalogEntry(id: 'pack-b'),
        _goodCatalogEntry(id: 'pack-c'),
      ]));
      expect(
        result.entries.map((CatalogEntry entry) => entry.manifest.id),
        <String>['pack-a', 'pack-b', 'pack-c'],
      );
    });
  });

  group('parseExtensionCatalog：size / sha256', () {
    test('size 合法（含 0）读出，缺省为 null 且不警告', () {
      final CatalogEntry zero = _parseCatalog(_catalog(<Object?>[
        _goodCatalogEntry(size: 0),
      ])).entries.single;
      expect(zero.size, 0);
      final CatalogParseResult absent = _parseCatalog(_catalog(<Object?>[
        _goodCatalogEntry(),
      ]));
      expect(absent.entries.single.size, isNull);
      expect(absent.warnings, isEmpty);
    });

    test('size 非法（负数 / 小数 / 字符串）→ 只 warning，size=null，仍可装', () {
      for (final Object? bad in <Object?>[-1, 1.5, '12']) {
        final CatalogParseResult result = _parseCatalog(_catalog(<Object?>[
          _goodCatalogEntry(size: bad),
        ]));
        expect(result.ok, isTrue, reason: 'size=$bad');
        expect(result.entries.single.size, isNull);
        expect(result.warnings.single.field, 'extensions[0].size');
        expect(result.warnings.single.message, contains('非负整数'));
      }
    });

    test('sha256 合法（大写也认）保存为小写；非法只 warning；缺省/空串不警告', () {
      final CatalogEntry upper = _parseCatalog(_catalog(<Object?>[
        _goodCatalogEntry(sha256: _sha('C')),
      ])).entries.single;
      expect(upper.sha256, _sha('c'));

      final CatalogParseResult bad = _parseCatalog(_catalog(<Object?>[
        _goodCatalogEntry(sha256: 'abc'),
      ]));
      expect(bad.ok, isTrue);
      expect(bad.entries.single.sha256, isNull);
      expect(bad.warnings.single.field, 'extensions[0].sha256');
      expect(bad.warnings.single.message, contains('64 位十六进制'));

      final CatalogParseResult absent = _parseCatalog(_catalog(<Object?>[_goodCatalogEntry()]));
      expect(absent.entries.single.sha256, isNull);
      expect(absent.warnings, isEmpty);

      final CatalogParseResult empty = _parseCatalog(_catalog(<Object?>[
        _goodCatalogEntry(sha256: ''),
      ]));
      expect(empty.entries.single.sha256, isNull);
      expect(empty.warnings, isEmpty);
    });
  });

  group('第六十三轮修掉的三个缺口（原来钉的是"当前行为"，现在钉"必须拒"）', () {
    test('schema 1.5 必须拒（不许被 toInt() 当成 1）', () {
      final ManifestParseResult result =
          parseExtensionManifest(_validManifest()..['schema'] = 1.5);
      expect(result.ok, isFalse);
      expect(result.issues.single.field, 'schema');
    });

    test('schema 1.0（JSON 小数写法）仍然算 1', () {
      final ManifestParseResult result =
          parseExtensionManifest(_validManifest()..['schema'] = 1.0);
      expect(result.ok, isTrue);
      expect(result.manifest!.schema, 1);
    });

    test('id 是 Windows 保留设备名（nul / con）必须拒（会成为 extensions/<id>/ 目录）', () {
      for (final String id in <String>['nul', 'con', 'NUL', 'COM1']) {
        final ManifestParseResult result = parseExtensionManifest(_validManifest()..['id'] = id);
        expect(result.ok, isFalse, reason: 'id=$id');
        expect(result.issues.single.field, 'id', reason: 'id=$id');
      }
    });

    test('id 以点结尾（demo-pack.）必须拒（Windows 存盘会悄悄去掉尾点）', () {
      final ManifestParseResult result =
          parseExtensionManifest(_validManifest()..['id'] = 'demo-pack.');
      expect(result.ok, isFalse);
      expect(result.issues.single.field, 'id');
    });

    test('id 内部含 .. 仍然放行（Windows 目录名里合法，且它不是路径分隔）', () {
      final ManifestParseResult result =
          parseExtensionManifest(_validManifest()..['id'] = 'a..b');
      expect(result.ok, isTrue);
      expect(result.manifest!.id, 'a..b');
    });
  });
}
