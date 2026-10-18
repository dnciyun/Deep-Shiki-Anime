/// `state/picture_pack.dart`：画面调节扩展包的扫描 / 渲染 / 落缓存 / 挂载。
///
/// 全是临时目录真造文件 + 假 runner（不联网、不碰播放器）：这些判据守的是
/// "装了但画面不对"这一类问题 —— 清单合法但模板拼错、缓存文件名不稳定导致拖滑杆
/// 堆满文件、关超分时把画面调节一起 clr 掉、包被卸载后还挂着一条指向不存在文件的链。
library;

import 'dart:convert';
import 'dart:io';

import 'package:dsanima/state/extension_schemes.dart'
    show kExtensionsDirName, kExtensionsStateFileName;
import 'package:dsanima/state/picture_pack.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shikiin/shikiin.dart';

final String _sha = 'a' * 64;

/// 一份画面调节包清单：两个参数 + 两个预设（第二个绑了超分方案）。
Map<String, Object?> _manifest({
  required String id,
  String name = '演示画面调节',
  String kind = 'picture-pack',
  String template = 'shaders/picture.glsl',
  List<Object?>? params,
  List<Object?>? presets,
}) =>
    <String, Object?>{
      'schema': 1,
      'id': id,
      'name': name,
      'version': '1.0.0',
      'kind': kind,
      'files': <Object?>[
        <String, Object?>{'path': template, 'size': 64, 'sha256': _sha},
      ],
      'payload': <String, Object?>{
        'picture': <String, Object?>{
          'template': template,
          'params': params ??
              <Object?>[
                <String, Object?>{
                  'key': 'sharpen',
                  'label': '锐度',
                  'min': 0,
                  'max': 2,
                  'step': 0.05,
                  'default': 0.5,
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
          'presets': presets ??
              <Object?>[
                <String, Object?>{
                  'id': 'soft',
                  'name': '柔和',
                  'values': <String, Object?>{'sharpen': 0.2, 'line': 0.2},
                },
                <String, Object?>{
                  'id': 'crisp',
                  'name': '清晰',
                  'values': <String, Object?>{'sharpen': 1.2, 'line': 0.45},
                  'upscale': 'anime4k',
                },
              ],
        },
      },
    };

const String _template = '#define SHARPEN @sharpen@\n'
    '#define LINE @line@\n';

void _writeManifest(Directory extDir, Map<String, Object?> manifest) {
  File(p.join(extDir.path, 'manifest.json'))
    ..createSync(recursive: true)
    ..writeAsStringSync(jsonEncode(manifest));
}

void _writeTemplate(Directory extDir, String path, [String text = _template]) {
  File(p.join(extDir.path, path))
    ..createSync(recursive: true)
    ..writeAsStringSync(text);
}

Directory _newSupportDir() =>
    Directory.systemTemp.createTempSync('dsanima-picture-pack-');

Directory _extDir(Directory support, String id) =>
    Directory(p.join(support.path, kExtensionsDirName, id))..createSync(recursive: true);

/// 装一个完整的包（清单 + 模板 + 可选 state.json 启用标记）。
Directory _installPack(
  Directory support,
  String id, {
  Map<String, Object?>? manifest,
  String templateText = _template,
  bool? enabled,
}) {
  final Directory ext = _extDir(support, id);
  _writeManifest(ext, manifest ?? _manifest(id: id));
  _writeTemplate(ext, 'shaders/picture.glsl', templateText);
  if (enabled != null) _writeState(support, <String, bool>{id: enabled});
  return ext;
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

/// 假播放器：只记录下发的 mpv 命令（与 `anime4k_controller_test.dart` 同一手法）。
Anime4kController _fakePlayer(List<List<String>> sent) =>
    Anime4kController(runner: (List<String> args) async => sent.add(args));

void main() {
  group('扫描：只收"现在真能用"的画面调节包', () {
    test('合法包 → 字段齐（id/name/spec/模板正文/dir）', () async {
      final Directory support = _newSupportDir();
      addTearDown(() => support.deleteSync(recursive: true));
      _installPack(support, 'picture-demo');

      final List<PicturePack> packs = await loadPicturePacks(support);
      expect(packs, hasLength(1));
      final PicturePack pack = packs.single;
      expect(pack.id, 'picture-demo');
      expect(pack.name, '演示画面调节');
      expect(pack.template, _template);
      expect(pack.spec.params.map((dynamic p) => p.key), <String>['sharpen', 'line']);
      expect(pack.spec.presets, hasLength(2));
      expect(pack.dir.path, p.join(support.path, kExtensionsDirName, 'picture-demo'));
      expect(pack.hasParams, isTrue);
      expect(pack.hasPresets, isTrue);
    });

    test('shader-pack / data-pack / 禁用 / 目录名与 id 不一致 → 都不收', () async {
      final Directory support = _newSupportDir();
      addTearDown(() => support.deleteSync(recursive: true));
      _installPack(support, 'shader-one',
          manifest: _manifest(id: 'shader-one', kind: 'shader-pack'));
      _installPack(support, 'data-one',
          manifest: _manifest(id: 'data-one', kind: 'data-pack'));
      _installPack(support, 'disabled', enabled: false);
      _installPack(support, 'wrong-dir', manifest: _manifest(id: 'other-id'));

      expect(await loadPicturePacks(support), isEmpty);
    });

    test('模板文件缺失 → 不收（挂上去只会静默不生效）', () async {
      final Directory support = _newSupportDir();
      addTearDown(() => support.deleteSync(recursive: true));
      final Directory ext = _extDir(support, 'no-template');
      _writeManifest(ext, _manifest(id: 'no-template'));
      // 故意不写模板文件

      expect(await loadPicturePacks(support), isEmpty);
    });

    test('模板里有未声明的占位符 → 不收（拼错的参数名不许安静生效）', () async {
      final Directory support = _newSupportDir();
      addTearDown(() => support.deleteSync(recursive: true));
      _installPack(support, 'typo',
          templateText: '#define X @sharpen@\n#define Y @sharpen_nope@\n');

      expect(await loadPicturePacks(support), isEmpty);
    });

    test('多个包按目录名排序（界面顺序稳定，可测）', () async {
      final Directory support = _newSupportDir();
      addTearDown(() => support.deleteSync(recursive: true));
      _installPack(support, 'zeta');
      _installPack(support, 'alpha');

      final List<PicturePack> packs = await loadPicturePacks(support);
      expect(packs.map((PicturePack x) => x.id), <String>['alpha', 'zeta']);
    });

    test('扩展目录不存在 → 空列表（不是异常）', () async {
      final Directory support = _newSupportDir();
      addTearDown(() => support.deleteSync(recursive: true));
      expect(await loadPicturePacks(support), isEmpty);
    });
  });

  group('渲染 + 缓存', () {
    late Directory support;
    late PicturePack pack;
    setUp(() async {
      support = _newSupportDir();
      addTearDown(() => support.deleteSync(recursive: true));
      _installPack(support, 'picture-demo');
      pack = (await loadPicturePacks(support)).single;
    });

    test('按取值替换占位符（固定 4 位小数）', () {
      final String? text = renderPackShader(
        pack,
        <String, double>{'sharpen': 0.8},
      );
      expect(text, isNotNull);
      expect(text, contains('#define SHARPEN 0.8000'));
      expect(text, contains('#define LINE 0.4500'));
    });

    test('落缓存：文件名确定性、内容就是渲染结果、没有 .tmp 残留', () async {
      final Directory cache = pictureCacheDirOf(support);
      final String? path = await ensureRenderedShader(
        pack: pack,
        values: <String, double>{'sharpen': 0.8},
        cacheDir: cache,
      );
      expect(path, isNotNull);
      final File file = File(path!);
      expect(file.existsSync(), isTrue);
      expect(p.basename(file.path), startsWith('picture-demo_'));
      expect(p.basename(file.path), endsWith('.glsl'));
      expect(file.readAsStringSync(), contains('#define SHARPEN 0.8000'));
      expect(File('${file.path}.tmp').existsSync(), isFalse);
    });

    test('同取值再来一次 → 复用同一个文件（不重写）', () async {
      final Directory cache = pictureCacheDirOf(support);
      final String? first = await ensureRenderedShader(
        pack: pack,
        values: <String, double>{'sharpen': 0.8},
        cacheDir: cache,
      );
      final DateTime stamp = File(first!).lastModifiedSync();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final String? second = await ensureRenderedShader(
        pack: pack,
        values: <String, double>{'sharpen': 0.8},
        cacheDir: cache,
      );
      expect(second, first);
      expect(File(first).lastModifiedSync(), stamp);
      expect(cache.listSync().whereType<File>(), hasLength(1));
    });

    test('换取值 → 换文件；越界取值被夹回（缓存键也按夹过的算）', () async {
      final Directory cache = pictureCacheDirOf(support);
      final String? a = await ensureRenderedShader(
        pack: pack,
        values: <String, double>{'sharpen': 0.8},
        cacheDir: cache,
      );
      final String? b = await ensureRenderedShader(
        pack: pack,
        values: <String, double>{'sharpen': 0.85},
        cacheDir: cache,
      );
      final String? clamped = await ensureRenderedShader(
        pack: pack,
        values: <String, double>{'sharpen': 99},
        cacheDir: cache,
      );
      expect(b, isNot(a));
      expect(File(clamped!).readAsStringSync(), contains('#define SHARPEN 2.0000'));
    });
  });

  group('控制器：挂载 / 重渲染 / 关掉', () {
    late Directory support;
    late List<List<String>> sent;
    late Anime4kController player;
    late PictureController controller;

    setUp(() async {
      support = _newSupportDir();
      addTearDown(() => support.deleteSync(recursive: true));
      _installPack(support, 'picture-demo');
      sent = <List<String>>[];
      player = _fakePlayer(sent);
      controller = PictureController(
        player: player,
        shaderCacheDir: pictureCacheDirOf(support),
        packs: await loadPicturePacks(support),
      );
    });

    test('选包 → 生成文件并作为叠加链下发（set 而不是 clr）', () async {
      await controller.selectPack('picture-demo');
      expect(controller.isOff, isFalse);
      expect(player.extraChain, hasLength(1));
      expect(p.basename(player.extraChain.single), startsWith('picture-demo_'));
      final List<String> args = sent.last;
      expect(args.sublist(0, 3), <String>['change-list', 'glsl-shaders', 'set']);
      expect(args[3], player.extraChain.single);
    });

    test('选包默认套第一个预设的取值', () async {
      await controller.selectPack('picture-demo');
      expect(controller.settings.presetId, 'soft');
      expect(controller.values['sharpen'], 0.2);
      expect(controller.values['line'], 0.2);
    });

    test('套预设 → 重新渲染并重下发（文件名跟着取值变）', () async {
      await controller.selectPack('picture-demo');
      final String first = player.extraChain.single;
      await controller.applyPreset('crisp');
      expect(controller.settings.presetId, 'crisp');
      expect(controller.values['sharpen'], 1.2);
      expect(player.extraChain.single, isNot(first));
      expect(File(player.extraChain.single).readAsStringSync(),
          contains('#define SHARPEN 1.2000'));
    });

    test('改滑杆：夹值、丢掉 presetId（不再算某个预设），apply 后才下发', () async {
      await controller.selectPack('picture-demo');
      final int before = sent.length;
      final double effective = controller.setValue('sharpen', 9);
      expect(effective, 2);
      expect(controller.settings.presetId, isNull);
      expect(sent, hasLength(before), reason: '只改状态不下发（拖滑杆不该每帧重挂）');

      await controller.apply();
      expect(sent.length, before + 1);
      expect(File(player.extraChain.single).readAsStringSync(),
          contains('#define SHARPEN 2.0000'));
    });

    test('关掉：清叠加链并 clr（超分方案不动）', () async {
      await controller.selectPack('picture-demo');
      sent.clear();
      await controller.turnOff();
      expect(controller.isOff, isTrue);
      expect(player.extraChain, isEmpty);
      expect(sent.last[2], 'clr');
    });

    test('包被卸载后 setPacks：回退成关 + 清链，并返回"发生了回退"', () async {
      await controller.selectPack('picture-demo');
      sent.clear();
      final bool reset = await controller.setPacks(const <PicturePack>[]);
      expect(reset, isTrue);
      expect(controller.isOff, isTrue);
      expect(player.extraChain, isEmpty);
      expect(sent.last[2], 'clr');
    });

    test('预设绑的超分方案 id 只作为建议，控制器不擅自改用户选中的方案', () async {
      await controller.applyPreset('crisp');
      expect(controller.currentPack, isNull, reason: '还没选包，套预设无效');
      await controller.selectPack('picture-demo', presetId: 'crisp');
      expect(controller.currentPack!.spec.presets[1].upscaleSchemeId, 'anime4k');
      // 下发里不应该出现 Ultra/标准链：控制器只管叠加链，方案由用户/界面决定。
      expect(sent.every((List<String> a) => !a.join(' ').contains('Anime4K_Restore')), isTrue);
    });
  });

  group('设置持久化（json 一片）', () {
    test('round-trip：包/预设/取值', () {
      const PictureSettings settings = PictureSettings(
        packId: 'picture-demo',
        presetId: 'crisp',
        values: <String, double>{'sharpen': 1.2},
      );
      final PictureSettings back = PictureSettings.fromJson(settings.toJson());
      expect(back, settings);
    });

    test('垃圾输入 → 退化成关，不抛（旧版本/手改文件不该让播放器起不来）', () {
      expect(PictureSettings.fromJson(null), PictureSettings.off);
      expect(PictureSettings.fromJson(<String, Object?>{'pack': 42}), PictureSettings.off);
      final PictureSettings partial = PictureSettings.fromJson(<String, Object?>{
        'pack': 'x',
        'values': <String, Object?>{'a': 'not-a-number', 'b': 1},
      });
      expect(partial.packId, 'x');
      expect(partial.values, <String, double>{'b': 1});
    });
  });

  group('用户关掉的预设（扩展页「设置」→ 取消勾选）', () {
    test('扫描时就把关掉的预设摘掉（菜单里看不到、也不会被当"第一个预设"套）', () async {
      final Directory support = _newSupportDir();
      addTearDown(() => support.deleteSync(recursive: true));
      _installPack(support, 'picture-demo');

      final List<PicturePack> packs = await loadPicturePacks(
        support,
        hiddenPresets: <String, Set<String>>{
          'picture-demo': <String>{'crisp'},
        },
      );
      expect(packs, hasLength(1));
      expect(packs.single.spec.presets.map((dynamic p) => p.id), <String>['soft']);
    });

    test('全关也照样列出包（滑杆面板还要能用）', () async {
      final Directory support = _newSupportDir();
      addTearDown(() => support.deleteSync(recursive: true));
      _installPack(support, 'picture-demo');

      final List<PicturePack> packs = await loadPicturePacks(
        support,
        hiddenPresets: <String, Set<String>>{
          'picture-demo': <String>{'soft', 'crisp'},
        },
      );
      expect(packs.single.spec.presets, isEmpty);
      expect(packs.single.hasPresets, isFalse);
      expect(packs.single.spec.params, isNotEmpty);
      // 参数还在 ⇒ 面板能拖；只是菜单里不会再列那两档。
      expect(packs.single.defaults.keys, contains('sharpen'));
    });

    test('别的包的开关不影响这个包', () async {
      final Directory support = _newSupportDir();
      addTearDown(() => support.deleteSync(recursive: true));
      _installPack(support, 'picture-demo');

      final List<PicturePack> packs = await loadPicturePacks(
        support,
        hiddenPresets: <String, Set<String>>{
          'another-pack': <String>{'crisp'},
        },
      );
      expect(packs.single.spec.presets, hasLength(2));
    });
  });

  // ── 取值持久化（关窗/重启后画面上还是上次调好的样子）────────────────────────
  //
  // 背景：第四轮交付时把"参数不持久化"列在「已知没做」里。控制器**不碰磁盘**：
  // 它只在每次"真正下发之后"通过 `onChanged` 告诉宿主存一次；写盘是装配点的事
  // （`main.dart` → `PictureSettingsStore`）。
  group('取值持久化：每次都通知宿主存，开窗时按存的恢复', () {
    late Directory support;
    late List<List<String>> sent;
    late Anime4kController player;
    late List<PictureSettings> persisted;

    setUp(() async {
      support = _newSupportDir();
      addTearDown(() => support.deleteSync(recursive: true));
      _installPack(support, 'picture-demo');
      sent = <List<String>>[];
      player = _fakePlayer(sent);
      persisted = <PictureSettings>[];
    });

    test('选包 / 拖滑杆 / 关掉：每次真正下发之后各存一次', () async {
      final List<PicturePack> packs = await loadPicturePacks(support);
      final PictureController controller = PictureController(
        player: player,
        shaderCacheDir: pictureCacheDirOf(support),
        packs: packs,
        onChanged: (PictureSettings value) async => persisted.add(value),
      );

      await controller.selectPack('picture-demo');
      expect(persisted.single.packId, 'picture-demo');
      expect(persisted.single.presetId, 'soft', reason: '选包默认套第一个预设');
      expect(persisted.single.values, <String, double>{'sharpen': 0.2, 'line': 0.2});

      controller.setValue('line', 0.9);
      await controller.apply(); // 面板松手后防抖调的就是它
      expect(persisted, hasLength(2));
      expect(persisted.last.presetId, isNull, reason: '手调之后不再算某个预设');
      expect(persisted.last.values['line'], 0.9);

      await controller.turnOff();
      expect(persisted.last, PictureSettings.off, reason: '「关」也要存，否则下次开窗又挂回去');
    });

    test('开窗：按上次的设置恢复取值（用户不用再拖一遍）', () async {
      final List<PicturePack> packs = await loadPicturePacks(support);
      final PictureController controller = PictureController(
        player: player,
        shaderCacheDir: pictureCacheDirOf(support),
        packs: packs,
        settings: const PictureSettings(
          packId: 'picture-demo',
          presetId: 'crisp',
          values: <String, double>{'sharpen': 1.2, 'line': 0.45},
        ),
        onChanged: (PictureSettings value) async => persisted.add(value),
      );

      expect(controller.isOff, isFalse);
      expect(controller.currentPack?.id, 'picture-demo');
      expect(controller.values, <String, double>{'sharpen': 1.2, 'line': 0.45});
      expect(sent, isEmpty, reason: '构造只恢复状态，下发由装配点显式调 apply()');

      await controller.apply();
      expect(player.extraChain, hasLength(1));
      expect(File(player.extraChain.single).readAsStringSync(),
          contains('#define SHARPEN 1.2000'));
      expect(persisted.single.presetId, 'crisp', reason: '恢复后 apply 也算一次落定');
    });

    test('上次的包已被卸载 → 退化成关（不会挂着指向不存在包的链）', () async {
      final List<PicturePack> packs = await loadPicturePacks(support);
      final PictureController controller = PictureController(
        player: player,
        shaderCacheDir: pictureCacheDirOf(support),
        packs: packs,
        settings: const PictureSettings(
          packId: 'uninstalled',
          values: <String, double>{'sharpen': 1},
        ),
        onChanged: (PictureSettings value) async => persisted.add(value),
      );

      expect(controller.isOff, isTrue);
      expect(controller.values, isEmpty);

      // 装配点开窗时照例调一次 apply()：什么都不挂，并把"已经没了"写回去。
      await controller.apply();
      expect(player.extraChain, isEmpty);
      expect(persisted.single, PictureSettings.off);
    });
  });
}
