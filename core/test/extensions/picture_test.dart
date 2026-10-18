/// 「画面调节」扩展包（`picture-pack`）的离线判据：清单解析 + 模板渲染 + 缓存键。
///
/// 这些判据守的是**最贵的那类 bug**：装上了、界面上看着对、播放时画面不对。
/// 因为这份 libmpv 不认 `//!PARAM`，参数只能烧进 .glsl 文本 —— 一旦
/// 参数名拼错 / 预设越界 / 占位符没声明，宿主会安静地渲染出一份"语法正确、
/// 语义错"的 shader，mpv 日志里一个字都不会有。所以：
///
/// * 清单期的错 → 断言精确到 [ManifestIssue.field]（装不上，能看见）；
/// * 渲染期的错 → 断言 [renderPictureShader] 返回 null 并给出 [ParsedTemplateIssue]
///   （在写文件之前就能拦住）。
library;

import 'package:dsanima_core/dsanima_core.dart';
import 'package:flutter_test/flutter_test.dart';

String _sha([String fill = 'a']) => fill * 64;

Map<String, Object?> _file(String path, {int size = 128, String? sha256}) =>
    <String, Object?>{
      'path': path,
      'size': size,
      'sha256': sha256 ?? _sha(),
    };

/// 合法画面调节包：一份模板 + 两个参数 + 一个预设。
Map<String, Object?> _pictureManifest() => <String, Object?>{
      'schema': 1,
      'id': 'demo-picture',
      'name': '演示画面调节',
      'version': '1.0.0',
      'kind': 'picture-pack',
      'files': <Object?>[
        _file('shaders/picture.glsl'),
      ],
      'payload': <String, Object?>{
        'picture': <String, Object?>{
          'template': 'shaders/picture.glsl',
          'params': <Object?>[
            <String, Object?>{
              'key': 'sharpen',
              'label': '锐度',
              'min': 0,
              'max': 2,
              'step': 0.05,
              'default': 0.5,
              'group': '锐度与线条',
            },
            <String, Object?>{
              'key': 'line',
              'label': '线条强化',
              'min': 0,
              'max': 1,
              'step': 0.05,
              'default': 0.45,
            },
          ],
          'presets': <Object?>[
            <String, Object?>{
              'id': 'crisp',
              'name': '清晰',
              'values': <String, Object?>{'sharpen': 0.8, 'line': 0.45},
              'upscale': 'anime4k',
            },
          ],
        },
      },
    };

/// 从合法清单里改一处，返回新清单（不污染夹具）。
Map<String, Object?> _withPicture(
  void Function(Map<String, Object?> picture) edit,
) {
  final Map<String, Object?> manifest = _pictureManifest();
  final Map<String, Object?> payload = manifest['payload']! as Map<String, Object?>;
  final Map<String, Object?> picture = payload['picture']! as Map<String, Object?>;
  edit(picture);
  return manifest;
}

PictureSpec _parsedSpec(Map<String, Object?> manifest) {
  final ManifestParseResult result = parseExtensionManifest(manifest, currentAppVersion: '1.1.0');
  expect(result.ok, isTrue, reason: result.issues.join('\n'));
  return result.manifest!.picture!;
}

void main() {
  group('画面调节包 · 清单解析', () {
    test('合法清单：kind / template / params 顺序 / defaults / presets / isUsable', () {
      final ManifestParseResult result =
          parseExtensionManifest(_pictureManifest(), currentAppVersion: '1.1.0');
      expect(result.ok, isTrue, reason: result.issues.join('\n'));
      expect(result.issues, isEmpty);
      final ExtensionManifest manifest = result.manifest!;
      expect(manifest.kind, ExtensionKind.picturePack);
      expect(ExtensionKind.labelOf(manifest.kind), '画面调节包');
      expect(manifest.isKnownKind, isTrue);
      expect(manifest.isUsable, isTrue);
      expect(manifest.shader, isNull);

      final PictureSpec spec = manifest.picture!;
      expect(spec.template, 'shaders/picture.glsl');
      expect(spec.params.map((PictureParam p) => p.key), <String>['sharpen', 'line']);
      expect(spec.params.first.group, '锐度与线条');
      expect(spec.params.last.group, isEmpty);
      expect(spec.defaults, <String, double>{'sharpen': 0.5, 'line': 0.45});
      expect(spec.presets.single.id, 'crisp');
      expect(spec.presets.single.upscaleSchemeId, 'anime4k');
    });

    test('缺少 payload.picture → 拒，字段指到 payload.picture', () {
      final Map<String, Object?> manifest = _pictureManifest();
      (manifest['payload']! as Map<String, Object?>).remove('picture');
      final ManifestParseResult result =
          parseExtensionManifest(manifest, currentAppVersion: '1.1.0');
      expect(result.ok, isFalse);
      expect(result.issues.map((ManifestIssue i) => i.field), contains('payload.picture'));
    });

    test('模板没列在 files 里 → 拒（装上后读不到模板）', () {
      final Map<String, Object?> manifest = _withPicture((Map<String, Object?> p) {
        p['template'] = 'shaders/other.glsl';
      });
      final ManifestParseResult result =
          parseExtensionManifest(manifest, currentAppVersion: '1.1.0');
      expect(result.ok, isFalse);
      expect(
        result.issues.map((ManifestIssue i) => i.field),
        contains('payload.picture.template'),
      );
    });

    test('模板路径带 .. → 拒（路径判据与 files 同一套）', () {
      final Map<String, Object?> manifest = _withPicture((Map<String, Object?> p) {
        p['template'] = '../evil.glsl';
      });
      final ManifestParseResult result =
          parseExtensionManifest(manifest, currentAppVersion: '1.1.0');
      expect(result.ok, isFalse);
      expect(
        result.issues.map((ManifestIssue i) => i.field),
        contains('payload.picture.template'),
      );
    });

    test('参数名大写/短横线 → 拒；key 重复 → 拒', () {
      final Map<String, Object?> upper = _withPicture((Map<String, Object?> p) {
        final List<Object?> params = p['params']! as List<Object?>;
        (params.first! as Map<String, Object?>)['key'] = 'Sharpen';
      });
      final ManifestParseResult r1 =
          parseExtensionManifest(upper, currentAppVersion: '1.1.0');
      expect(r1.ok, isFalse);
      expect(
        r1.issues.map((ManifestIssue i) => i.field),
        contains('payload.picture.params[0].key'),
      );

      final Map<String, Object?> dup = _withPicture((Map<String, Object?> p) {
        final List<Object?> params = p['params']! as List<Object?>;
        (params.last! as Map<String, Object?>)['key'] = 'sharpen';
      });
      final ManifestParseResult r2 =
          parseExtensionManifest(dup, currentAppVersion: '1.1.0');
      expect(r2.ok, isFalse);
      expect(
        r2.issues.map((ManifestIssue i) => i.field),
        contains('payload.picture.params[1].key'),
      );
    });

    test('max <= min / default 越界 / step <= 0 → 各自一条，字段精确', () {
      final ManifestParseResult r1 = parseExtensionManifest(
        _withPicture((Map<String, Object?> p) {
          final Map<String, Object?> param =
              (p['params']! as List<Object?>).first! as Map<String, Object?>;
          param['max'] = 0;
        }),
        currentAppVersion: '1.1.0',
      );
      expect(r1.ok, isFalse);
      expect(
        r1.issues.map((ManifestIssue i) => i.field),
        contains('payload.picture.params[0].max'),
      );

      final ManifestParseResult r2 = parseExtensionManifest(
        _withPicture((Map<String, Object?> p) {
          final Map<String, Object?> param =
              (p['params']! as List<Object?>).first! as Map<String, Object?>;
          param['default'] = 9;
        }),
        currentAppVersion: '1.1.0',
      );
      expect(r2.ok, isFalse);
      expect(
        r2.issues.map((ManifestIssue i) => i.field),
        contains('payload.picture.params[0].default'),
      );

      final ManifestParseResult r3 = parseExtensionManifest(
        _withPicture((Map<String, Object?> p) {
          final Map<String, Object?> param =
              (p['params']! as List<Object?>).first! as Map<String, Object?>;
          param['step'] = 0;
        }),
        currentAppVersion: '1.1.0',
      );
      expect(r3.ok, isFalse);
      expect(
        r3.issues.map((ManifestIssue i) => i.field),
        contains('payload.picture.params[0].step'),
      );
    });

    test('预设引用未声明的参数 → 拒（拼错的参数名不许静默生效）', () {
      final ManifestParseResult result = parseExtensionManifest(
        _withPicture((Map<String, Object?> p) {
          final Map<String, Object?> preset =
              (p['presets']! as List<Object?>).first! as Map<String, Object?>;
          preset['values'] = <String, Object?>{'sharppn': 0.8};
        }),
        currentAppVersion: '1.1.0',
      );
      expect(result.ok, isFalse);
      expect(
        result.issues.map((ManifestIssue i) => i.field),
        contains('payload.picture.presets[0].values.sharppn'),
      );
    });

    test('预设 id 重复 → 拒；presets 可以缺省（只给滑杆）', () {
      final ManifestParseResult dup = parseExtensionManifest(
        _withPicture((Map<String, Object?> p) {
          p['presets'] = <Object?>[
            <String, Object?>{'id': 'a', 'name': 'A'},
            <String, Object?>{'id': 'a', 'name': 'B'},
          ];
        }),
        currentAppVersion: '1.1.0',
      );
      expect(dup.ok, isFalse);
      expect(
        dup.issues.map((ManifestIssue i) => i.field),
        contains('payload.picture.presets[1].id'),
      );

      final ManifestParseResult bare = parseExtensionManifest(
        _withPicture((Map<String, Object?> p) {
          p.remove('presets');
        }),
        currentAppVersion: '1.1.0',
      );
      expect(bare.ok, isTrue);
      expect(bare.manifest!.picture!.presets, isEmpty);
      expect(bare.manifest!.isUsable, isTrue);
    });

    test('params 与 presets 都空 → 拒（没有任何可调项）', () {
      final ManifestParseResult result = parseExtensionManifest(
        _withPicture((Map<String, Object?> p) {
          p.remove('params');
          p.remove('presets');
        }),
        currentAppVersion: '1.1.0',
      );
      expect(result.ok, isFalse);
      expect(
        result.issues.map((ManifestIssue i) => i.field),
        contains('payload.picture'),
      );
    });

    test('类型不对时 payload.picture 被忽略并提醒（不静默）', () {
      final Map<String, Object?> manifest = _pictureManifest();
      manifest['kind'] = 'shader-pack';
      (manifest['payload']! as Map<String, Object?>)['shader'] = <String, Object?>{
        'dir': 'shaders',
        'files': <Object?>['picture.glsl'],
      };
      final ManifestParseResult result =
          parseExtensionManifest(manifest, currentAppVersion: '1.1.0');
      expect(result.ok, isTrue);
      expect(result.manifest!.picture, isNull);
      expect(
        result.warnings.map((ManifestIssue i) => i.field),
        contains('payload.picture'),
      );
    });
  });

  group('画面调节包 · 取值与预设', () {
    test('clampValue：夹区间 + 按 step 量化到可读小数', () {
      final PictureSpec spec = _parsedSpec(_pictureManifest());
      final PictureParam sharpen = spec.paramByKey('sharpen')!;
      expect(sharpen.clampValue(9), 2);
      expect(sharpen.clampValue(-1), 0);
      expect(sharpen.clampValue(0.73), 0.75);
      expect(sharpen.clampValue(0.7), 0.7);
      // 抖动不该漏到渲染文本里：0.7000000000000001 → 0.7
      expect(sharpen.clampValue(0.1 + 0.6), 0.7);
      expect(sharpen.clampValue(double.nan), 0.5);
    });

    test('valuesOf：预设覆盖默认值、越界被夹回，未写的参数保持默认', () {
      final PictureSpec spec = _parsedSpec(_pictureManifest());
      final PicturePreset preset = spec.presets.single;
      expect(spec.valuesOf(preset), <String, double>{'sharpen': 0.8, 'line': 0.45});

      final PictureSpec clamped = _parsedSpec(
        _withPicture((Map<String, Object?> p) {
          (p['presets']! as List<Object?>).first = <String, Object?>{
            'id': 'over',
            'name': '越界',
            'values': <String, Object?>{'sharpen': 99},
          };
        }),
      );
      expect(clamped.valuesOf(clamped.presets.single)['sharpen'], 2);
    });

    test('normalizeValues：丢未知键、未知值用默认', () {
      final PictureSpec spec = _parsedSpec(_pictureManifest());
      expect(
        spec.normalizeValues(<String, double>{'sharpen': 1, 'nope': 3}),
        <String, double>{'sharpen': 1, 'line': 0.45},
      );
    });
  });

  group('画面调节包 · 模板渲染', () {
    const String template = '#define SHARPEN @sharpen@\n'
        '#define LINE @line@\n';

    test('占位符替换成固定 4 位小数（不是 toString 的指数形式）', () {
      final PictureSpec spec = _parsedSpec(_pictureManifest());
      final String? out = renderPictureShader(
        template: template,
        spec: spec,
        values: <String, double>{'sharpen': 0.8},
      );
      expect(out, isNotNull);
      expect(out, contains('#define SHARPEN 0.8000'));
      expect(out, contains('#define LINE 0.4500'));
      expect(out, isNot(contains('@')));
    });

    test('很小的数也不出 1e-7（GLSL 不吃指数写法）', () {
      final PictureSpec spec = _parsedSpec(
        _withPicture((Map<String, Object?> p) {
          final Map<String, Object?> param =
              (p['params']! as List<Object?>).first! as Map<String, Object?>;
          param['min'] = 0;
          param['max'] = 0.001;
          param['step'] = 0.0001;
          param['default'] = 0.0001;
        }),
      );
      final String? out = renderPictureShader(
        template: '#define TINY @sharpen@\n',
        spec: spec,
        values: <String, double>{'sharpen': 0.0001},
      );
      expect(out, contains('#define TINY 0.0001'));
      expect(out, isNot(contains('e-')));
    });

    test('模板里有未声明的占位符 → null + 一条 issue（不许安静出个空 define）', () {
      final PictureSpec spec = _parsedSpec(_pictureManifest());
      final List<ParsedTemplateIssue> issues = <ParsedTemplateIssue>[];
      final String? out = renderPictureShader(
        template: '#define X @typo@\n',
        spec: spec,
        values: <String, double>{},
        issues: issues,
      );
      expect(out, isNull);
      expect(issues.map((ParsedTemplateIssue i) => i.key), contains('typo'));
    });

    test('声明了却没在模板里出现 → 仍然渲染，但给一条提醒', () {
      final PictureSpec spec = _parsedSpec(_pictureManifest());
      final List<ParsedTemplateIssue> issues = <ParsedTemplateIssue>[];
      final String? out = renderPictureShader(
        template: '#define SHARPEN @sharpen@\n',
        spec: spec,
        values: <String, double>{},
        issues: issues,
      );
      expect(out, isNotNull);
      expect(issues.map((ParsedTemplateIssue i) => i.key), contains('line'));
    });
  });

  group('画面调节包 · 缓存键', () {
    test('同版本同取值 → 同键；键与键序无关', () {
      final String a = pictureCacheKey(
        extensionId: 'demo-picture',
        extensionVersion: '1.0.0',
        values: <String, double>{'sharpen': 0.8, 'line': 0.45},
      );
      final String b = pictureCacheKey(
        extensionId: 'demo-picture',
        extensionVersion: '1.0.0',
        values: <String, double>{'line': 0.45, 'sharpen': 0.8},
      );
      expect(a, b);
      expect(a.length, 16);
      expect(RegExp(r'^[0-9a-f]{16}$').hasMatch(a), isTrue);
    });

    test('改值 / 改版本 / 改扩展 → 换键；文件名带扩展 id', () {
      final String base = pictureCacheKey(
        extensionId: 'demo-picture',
        extensionVersion: '1.0.0',
        values: <String, double>{'sharpen': 0.8},
      );
      expect(
        pictureCacheKey(
          extensionId: 'demo-picture',
          extensionVersion: '1.0.0',
          values: <String, double>{'sharpen': 0.81},
        ),
        isNot(base),
      );
      expect(
        pictureCacheKey(
          extensionId: 'demo-picture',
          extensionVersion: '1.0.1',
          values: <String, double>{'sharpen': 0.8},
        ),
        isNot(base),
      );
      expect(
        pictureCacheFileName(extensionId: 'demo-picture', cacheKey: base),
        'demo-picture_$base.glsl',
      );
    });
  });

  group('withoutPresets（扩展页「关掉不需要的预设」）', () {
    PictureSpec spec() => PictureSpec(
          template: 'shaders/picture.glsl',
          params: const <PictureParam>[
            PictureParam(
              key: 'sharpen',
              label: '锐度',
              min: 0,
              max: 2,
              step: 0.05,
              defaultValue: 0,
            ),
          ],
          presets: const <PicturePreset>[
            PicturePreset(id: 'crisp', name: '清晰', values: <String, double>{'sharpen': 1}),
            PicturePreset(id: 'soft', name: '柔和', values: <String, double>{'sharpen': 0.5}),
            PicturePreset(id: 'warm', name: '暖色', values: <String, double>{'sharpen': 0.9}),
          ],
          chainHint: 'hint',
        );

    test('摘掉指定预设，其余顺序不变', () {
      final PictureSpec before = spec();
      final PictureSpec after = before.withoutPresets(<String>{'soft'});
      expect(after.presets.map((PicturePreset p) => p.id), <String>['crisp', 'warm']);
      // 参数/模板/提示不动：关预设不该顺带改"能调什么"。
      expect(after.params.length, before.params.length);
      expect(after.template, before.template);
      expect(after.chainHint, before.chainHint);
    });

    test('全关 = 预设为空（菜单里只剩「关」和「调节…」）', () {
      final PictureSpec after = spec().withoutPresets(<String>{'crisp', 'soft', 'warm'});
      expect(after.presets, isEmpty);
      expect(after.params, isNotEmpty);
    });

    test('没有命中任何预设 → 原对象返回（不白造一份）', () {
      final PictureSpec before = spec();
      expect(identical(before.withoutPresets(<String>{'nope'}), before), isTrue);
      expect(identical(before.withoutPresets(const <String>{}), before), isTrue);
    });
  });
}
