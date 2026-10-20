/// `state/picture_menu_adapter.dart`：把 `PictureController` 翻成播放器菜单接口。
///
/// 守的是"菜单里点一下，播放器真的换了画面"这条端到端最小的缝：
/// 组合 id（`<包>/<预设>`）能不能拆回来、切包与同包换预设走的是不是不同的路、
/// 关掉之后叠加链是不是真的清空（而不是只把菜单勾选改了），以及「我的组合」
/// 有没有按 `<包>/custom:<组合>` 的约定追加在包自带预设之后、点了是不是真的落到
/// 那一套取值（而不是退回"第一个预设"）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:dsanima/domain/picture_combo.dart';
import 'package:dsanima/state/extension_schemes.dart'
    show kExtensionsDirName, kExtensionsStateFileName;
import 'package:dsanima/state/picture_menu_adapter.dart';
import 'package:dsanima/state/picture_pack.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shikiin/shikiin.dart';

final String _sha = 'a' * 64;

const String _template = '#define SHARPEN @sharpen@\n#define LINE @line@\n';

Map<String, Object?> _manifest(String id, String name) => <String, Object?>{
      'schema': 1,
      'id': id,
      'name': name,
      'version': '1.0.0',
      'kind': 'picture-pack',
      'files': <Object?>[
        <String, Object?>{'path': 'shaders/picture.glsl', 'size': 64, 'sha256': _sha},
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
              'default': 1.0,
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
              'description': '推荐',
              'values': <String, Object?>{'sharpen': 1.0, 'line': 0.45},
            },
            <String, Object?>{
              'id': 'soft',
              'name': '柔和',
              'values': <String, Object?>{'sharpen': 0.2, 'line': 0.2},
            },
          ],
        },
      },
    };

void _install(Directory support, String id, String name) {
  final Directory ext = Directory(p.join(support.path, kExtensionsDirName, id))
    ..createSync(recursive: true);
  File(p.join(ext.path, 'manifest.json'))
    .writeAsStringSync(jsonEncode(_manifest(id, name)));
  File(p.join(ext.path, 'shaders', 'picture.glsl'))
    ..createSync(recursive: true)
    ..writeAsStringSync(_template);
  File(p.join(support.path, kExtensionsDirName, kExtensionsStateFileName))
    .writeAsStringSync(jsonEncode(<String, Object?>{
      'schema': 1,
      'extensions': <String, Object?>{
        id: <String, Object?>{'enabled': true},
      },
    }));
}

void main() {
  test('组合 id 拆装往返；坏格式返回 null（菜单值一律当不可信）', () {
    expect(pictureCompositePresetId('demo', 'crisp'), 'demo/crisp');
    expect(parsePictureCompositeId('demo/crisp'), (packId: 'demo', presetId: 'crisp'));
    expect(parsePictureCompositeId('no-slash'), isNull);
    expect(parsePictureCompositeId('/crisp'), isNull);
    expect(parsePictureCompositeId('demo/'), isNull);
  });

  test('视图字段：包名/参数/预设/当前值都来自 controller', () async {
    final Directory support = Directory.systemTemp.createTempSync('dsanima-pic-menu-');
    addTearDown(() => support.deleteSync(recursive: true));
    _install(support, 'demo', '演示包');
    final List<List<String>> sent = <List<String>>[];
    final Anime4kController anime4k =
        Anime4kController(runner: (List<String> args) async => sent.add(args));
    final PictureController controller = PictureController(
      player: anime4k,
      shaderCacheDir: pictureCacheDirOf(support),
      packs: await loadPicturePacks(support),
    );
    final PictureMenuAdapter menu = PictureMenuAdapter(source: controller);

    expect(menu.packName, '演示包');
    expect(menu.isOff, isTrue, reason: '还没选任何东西');
    expect(menu.params.map((PictureParamInfo x) => x.key), <String>['sharpen', 'line']);
    expect(menu.params.first.group, '锐度与线条');
    expect(menu.presets.map((PicturePresetInfo x) => x.id), <String>['demo/crisp', 'demo/soft']);
    // 预设说明只在扩展页「设置」里显示（用户 2026-10-18：右键菜单内不要太多介绍），
    // 播放器侧拿到的就是名称本身 —— 单包时不带任何前缀/后缀。
    expect(menu.presets.map((PicturePresetInfo x) => x.name), <String>['清晰', '柔和']);
    expect(menu.valueOf('sharpen'), 1.0, reason: '关着时按默认值显示');
    expect(menu.activePresetId, isNull);
  });

  test('套预设 → 文件生成 + 叠加链下发；换预设有新文件；关 → 清链', () async {
    final Directory support = Directory.systemTemp.createTempSync('dsanima-pic-menu-');
    addTearDown(() => support.deleteSync(recursive: true));
    _install(support, 'demo', '演示包');
    final List<List<String>> sent = <List<String>>[];
    final Anime4kController anime4k =
        Anime4kController(runner: (List<String> args) async => sent.add(args));
    final PictureController controller = PictureController(
      player: anime4k,
      shaderCacheDir: pictureCacheDirOf(support),
      packs: await loadPicturePacks(support),
    );
    final PictureMenuAdapter menu = PictureMenuAdapter(source: controller);

    await menu.selectPreset('demo/crisp');
    expect(menu.isOff, isFalse);
    expect(menu.activePresetId, 'demo/crisp');
    final String firstPath = anime4k.extraChain.single;
    expect(File(firstPath).readAsStringSync(), contains('#define SHARPEN 1.0000'));
    expect(sent.last.sublist(0, 3), <String>['change-list', 'glsl-shaders', 'set']);

    await menu.selectPreset('demo/soft');
    expect(menu.activePresetId, 'demo/soft');
    expect(anime4k.extraChain.single, isNot(firstPath));

    sent.clear();
    await menu.selectPreset(null);
    expect(menu.isOff, isTrue);
    expect(anime4k.extraChain, isEmpty);
    expect(sent.last[2], 'clr');
  });

  test('滑杆：第一次拖就自动把包选起来（不会出现「能拖但没反应」）', () async {
    final Directory support = Directory.systemTemp.createTempSync('dsanima-pic-menu-');
    addTearDown(() => support.deleteSync(recursive: true));
    _install(support, 'demo', '演示包');
    final List<List<String>> sent = <List<String>>[];
    final Anime4kController anime4k =
        Anime4kController(runner: (List<String> args) async => sent.add(args));
    final PictureController controller = PictureController(
      player: anime4k,
      shaderCacheDir: pictureCacheDirOf(support),
      packs: await loadPicturePacks(support),
    );
    final PictureMenuAdapter menu = PictureMenuAdapter(source: controller);

    menu.setValue('sharpen', 1.6);
    expect(menu.isOff, isFalse, reason: '拖动即视为启用');
    expect(menu.activePresetId, isNull, reason: '手调不再算某个预设');
    expect(menu.valueOf('sharpen'), closeTo(1.6, 1e-9));

    await menu.applyValues();
    expect(File(anime4k.extraChain.single).readAsStringSync(),
        contains('#define SHARPEN 1.6000'));
  });

  test('多个包：预设 id 带包名，切到另一个包会重新选包', () async {
    final Directory support = Directory.systemTemp.createTempSync('dsanima-pic-menu-');
    addTearDown(() => support.deleteSync(recursive: true));
    _install(support, 'pack-a', '包A');
    _install(support, 'pack-b', '包B');
    final List<List<String>> sent = <List<String>>[];
    final Anime4kController anime4k =
        Anime4kController(runner: (List<String> args) async => sent.add(args));
    final PictureController controller = PictureController(
      player: anime4k,
      shaderCacheDir: pictureCacheDirOf(support),
      packs: await loadPicturePacks(support),
    );
    final PictureMenuAdapter menu = PictureMenuAdapter(source: controller);

    expect(menu.presets.map((PicturePresetInfo x) => x.id),
        containsAll(<String>['pack-a/crisp', 'pack-b/soft']));
    await menu.selectPreset('pack-a/crisp');
    expect(controller.currentPack?.id, 'pack-a');
    await menu.selectPreset('pack-b/soft');
    expect(controller.currentPack?.id, 'pack-b');
    expect(menu.activePresetId, 'pack-b/soft');
  });

  group('「我的组合」进菜单', () {
    late Directory support;
    late Anime4kController player;
    late PictureController controller;
    late PictureMenuAdapter menu;

    const PictureCombo night = PictureCombo(
      id: 'c1',
      name: '夜间',
      values: <String, double>{'sharpen': 0.3, 'line': 0.2},
    );
    const PictureCombo day = PictureCombo(
      id: 'c2',
      name: '白天',
      values: <String, double>{'sharpen': 1.8},
    );

    setUp(() async {
      support = Directory.systemTemp.createTempSync('dsanima-pic-menu-');
      addTearDown(() => support.deleteSync(recursive: true));
      _install(support, 'demo', '演示包');
      player = Anime4kController(runner: (List<String> args) async {});
      controller = PictureController(
        player: player,
        shaderCacheDir: pictureCacheDirOf(support),
        packs: await loadPicturePacks(support),
      );
      menu = PictureMenuAdapter(
        source: controller,
        combos: const <String, List<PictureCombo>>{
          'demo': <PictureCombo>[night, day],
        },
      );
    });

    test('追加在包自带预设之后，名字是「我的 · <名字>」，id 是 <包>/custom:<id>', () {
      expect(menu.presets.map((PicturePresetInfo x) => x.name),
          <String>['清晰', '柔和', '我的 · 夜间', '我的 · 白天']);
      expect(menu.presets.map((PicturePresetInfo x) => x.id),
          <String>['demo/crisp', 'demo/soft', 'demo/custom:c1', 'demo/custom:c2']);
    });

    test('selectPreset(custom id) → 落到那套组合的取值（不是"第一个预设"）', () async {
      await menu.selectPreset('demo/custom:c1');

      expect(menu.isOff, isFalse);
      expect(controller.values, <String, double>{'sharpen': 0.3, 'line': 0.2});
      expect(menu.activePresetId, 'demo/custom:c1', reason: '菜单据此把这一项勾上');
      expect(File(player.extraChain.single).readAsStringSync(),
          contains('#define SHARPEN 0.3000'));
    });

    test('组合已被删掉（菜单里还留着旧项）→ 什么都不做，不崩', () async {
      await menu.selectPreset('demo/custom:nope');

      expect(controller.isOff, isTrue);
      expect(controller.values, isEmpty);
      expect(player.extraChain, isEmpty);
    });

    test('setCombos 换一批 → 菜单立刻按新的那批重建', () {
      menu.setCombos(const <String, List<PictureCombo>>{
        'demo': <PictureCombo>[day],
      });
      expect(menu.presets.map((PicturePresetInfo x) => x.name),
          <String>['清晰', '柔和', '我的 · 白天']);
    });

    test('未知参数键在套用组合时被丢掉（包不认识的键不许进渲染/状态）', () async {
      menu.setCombos(const <String, List<PictureCombo>>{
        'demo': <PictureCombo>[
          PictureCombo(
            id: 'c3',
            name: '带垃圾键',
            values: <String, double>{'sharpen': 1.0, 'not_a_param': 9},
          ),
        ],
      });

      await menu.selectPreset('demo/custom:c3');

      expect(controller.values.keys.toSet(), <String>{'sharpen', 'line'});
      expect(controller.values['sharpen'], 1.0);
    });
  });
}
