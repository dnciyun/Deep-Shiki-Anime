/// 播放窗口侧的接收端：`PictureController.applySettings` + 回推给主窗口。
///
/// 守的是 spec §6 的两条硬要求：
/// * `selectPack` / `applyPreset` / `turnOff` 全部**收敛到 `applySettings`**（不留第二条
///   下发路径）—— 否则"页面调的"与"右键调的"迟早行为不一致；
/// * 一次下发 = 状态 + 取值 + 渲染 + 挂链，**永久不抛**，失败只回落成"什么都不挂"。
///
/// 还钉住回推那一半：真正下发之后主窗口页面必须收到那一份（否则页面显示旧值，
/// 用户一拖就把播放器刚调好的覆盖掉）。菜单里的「我的组合」归
/// `picture_menu_adapter_test.dart` 管（那是适配器的契约）。
///
/// 假播放器（`Anime4kController(runner:)`）与 `picture_pack_test.dart` 同一手法：
/// 只记录下发的 mpv 命令，不碰真播放器、不联网、不启动 app。
library;

import 'dart:convert';
import 'dart:io';

import 'package:dsanima/state/extension_schemes.dart'
    show kExtensionsDirName, kExtensionsStateFileName;
import 'package:dsanima/state/picture_menu_attach.dart';
import 'package:dsanima/state/picture_pack.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shikiin/shikiin.dart';

final String _sha = 'd' * 64;

const String _template = '#define SHARPEN @sharpen@\n#define LINE @line@\n';

Map<String, Object?> _manifest(String id, {String name = '演示包'}) => <String, Object?>{
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
          'presets': <Object?>[
            <String, Object?>{
              'id': 'crisp',
              'name': '清晰',
              'values': <String, Object?>{'sharpen': 1.2, 'line': 0.45},
            },
          ],
        },
      },
    };

Directory _newSupportDir() =>
    Directory.systemTemp.createTempSync('dsanima-picture-apply-');

void _install(Directory support, String id, {Map<String, Object?>? manifest}) {
  final Directory ext = Directory(p.join(support.path, kExtensionsDirName, id))
    ..createSync(recursive: true);
  File(p.join(ext.path, 'manifest.json'))
      .writeAsStringSync(jsonEncode(manifest ?? _manifest(id)));
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

Anime4kController _fakePlayer(List<List<String>> sent) =>
    Anime4kController(runner: (List<String> args) async => sent.add(args));

void main() {
  group('applySettings：一次下发 = 状态 + 取值 + 渲染 + 挂链', () {
    late Directory support;
    late List<List<String>> sent;
    late Anime4kController player;
    late PictureController controller;

    setUp(() async {
      support = _newSupportDir();
      addTearDown(() => support.deleteSync(recursive: true));
      _install(support, 'demo');
      sent = <List<String>>[];
      player = _fakePlayer(sent);
      controller = PictureController(
        player: player,
        shaderCacheDir: pictureCacheDirOf(support),
        packs: await loadPicturePacks(support),
      );
    });

    test('一份设置下去 → values 归一化、渲染文件对得上、叠加链就是那个文件', () async {
      await controller.applySettings(const PictureSettings(
        packId: 'demo',
        values: <String, double>{'sharpen': 1.5},
      ));

      expect(controller.isOff, isFalse);
      expect(controller.values, <String, double>{'sharpen': 1.5, 'line': 0.45});
      expect(player.extraChain, hasLength(1));
      expect(File(player.extraChain.single).readAsStringSync(),
          contains('#define SHARPEN 1.5000'));
    });

    test('取值越界 → 按 PictureParam.clampValue 夹到区间再渲染', () async {
      await controller.applySettings(const PictureSettings(
        packId: 'demo',
        values: <String, double>{'sharpen': 99},
      ));

      expect(controller.values['sharpen'], 2);
      expect(File(player.extraChain.single).readAsStringSync(),
          contains('#define SHARPEN 2.0000'));
    });

    test('applySettings(off) → 状态归零 + 叠加链清空（超分方案不动）', () async {
      await controller.applySettings(const PictureSettings(
        packId: 'demo',
        values: <String, double>{'sharpen': 1.0},
      ));
      expect(player.extraChain, isNotEmpty);

      await controller.applySettings(PictureSettings.off);

      expect(controller.isOff, isTrue);
      expect(controller.values, isEmpty);
      expect(player.extraChain, isEmpty);
      expect(sent.last[2], 'clr', reason: '清的是叠加链那一层（change-list glsl-shaders）');
    });

    test('选中已被卸载的包 → 退化成关，不抛', () async {
      await controller.applySettings(const PictureSettings(
        packId: 'ghost',
        values: <String, double>{'sharpen': 1},
      ));

      expect(controller.isOff, isTrue);
      expect(controller.values, isEmpty);
      expect(player.extraChain, isEmpty);
    });

    test('模板坏了（占位符拼错）→ 什么都不挂，但"想要的那份取值"不丢、也不抛', () async {
      // 真机上的坏模板是"扫包时通过、事后改坏/升级成错的"：这里直接把内存里的那份
      // 换成一个含未声明占位符的模板，模拟同一条路径（`renderPictureShader` 返回 null）。
      final PicturePack good = controller.packs.single;
      final PicturePack broken = PicturePack(
        id: good.id,
        name: good.name,
        version: good.version,
        spec: good.spec,
        template: '#define X @not_declared@' '\n',
        dir: good.dir,
      );
      final Anime4kController brokenPlayer = _fakePlayer(sent);
      final PictureController brokenController = PictureController(
        player: brokenPlayer,
        shaderCacheDir: pictureCacheDirOf(support),
        packs: <PicturePack>[broken],
      );

      await brokenController.applySettings(const PictureSettings(
        packId: 'demo',
        values: <String, double>{'sharpen': 1.1},
      ));

      expect(brokenController.isOff, isFalse, reason: '模板坏了是包的问题，不该把用户调好的丢掉');
      expect(brokenController.values['sharpen'], 1.1);
      expect(brokenPlayer.extraChain, isEmpty, reason: '渲染不出来就什么都不挂');
    });

    test('selectPack / applyPreset / turnOff 都收敛到它（同一条下发路径）', () async {
      // 选包 = 第一个预设的取值。
      await controller.selectPack('demo');
      expect(controller.settings.presetId, 'crisp');
      expect(controller.values['sharpen'], 1.2);

      // 套预设 = 同一条链（文件换新、链换新）。
      final String first = player.extraChain.single;
      await controller.applyPreset('crisp');
      expect(controller.settings.presetId, 'crisp');
      expect(player.extraChain.single, first, reason: '同取值复用同一个缓存文件');

      // 关 = 一份空设置。
      await controller.turnOff();
      expect(controller.isOff, isTrue);
      expect(player.extraChain, isEmpty);
    });
  });

  group('回推：真正下发之后把那一份交给主窗口', () {
    test('ensurePictureMenuAttached 的 onSettingsChanged 拿到的是下发的那一份设置', () async {
      final Directory support = _newSupportDir();
      addTearDown(() => support.deleteSync(recursive: true));
      _install(support, 'demo');
      final List<PictureSettings> pushed = <PictureSettings>[];
      final List<PictureMenu?> attached = <PictureMenu?>[];

      final PictureMenu? menu = await ensurePictureMenuAttached(
        player: _fakePlayer(<List<String>>[]),
        supportDir: support,
        current: null,
        attach: attached.add,
        onSettingsChanged: (PictureSettings settings) async => pushed.add(settings),
      );
      expect(menu, isNotNull);
      attached.clear();

      await menu!.selectPreset('demo/crisp');

      expect(pushed, hasLength(1));
      expect(pushed.single.packId, 'demo');
      expect(pushed.single.presetId, 'crisp');
      expect(pushed.single.values['sharpen'], 1.2);
      // 文件也写了（文件是唯一真相：主窗口页面重进时读到的是这一份）。
      final File file = File(p.join(support.path, 'dsanima', 'picture-settings.json'));
      expect(jsonDecode(file.readAsStringSync()), pushed.single.toJson());
    });

    test('开窗时读到的组合会进菜单（combos 参数不传就自己从盘上读）', () async {
      final Directory support = _newSupportDir();
      addTearDown(() => support.deleteSync(recursive: true));
      _install(support, 'demo');
      final File file = File(p.join(support.path, 'dsanima', 'picture-combos.json'));
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(jsonEncode(<String, Object?>{
        'demo': <Object?>[
          <String, Object?>{
            'id': 'c1',
            'name': '夜间',
            'values': <String, Object?>{'sharpen': 0.3},
          },
        ],
      }));

      final PictureMenu? menu = await ensurePictureMenuAttached(
        player: _fakePlayer(<List<String>>[]),
        supportDir: support,
        current: null,
        attach: (_) {},
      );

      expect(menu!.presets.map((PicturePresetInfo x) => x.name),
          contains('我的 · 夜间'));
    });

    test('已挂着的菜单重扫时会重新读组合（主窗口刚存的立刻出现）', () async {
      final Directory support = _newSupportDir();
      addTearDown(() => support.deleteSync(recursive: true));
      _install(support, 'demo');
      final PictureMenu? menu = await ensurePictureMenuAttached(
        player: _fakePlayer(<List<String>>[]),
        supportDir: support,
        current: null,
        attach: (_) {},
      );
      expect(menu!.presets.map((PicturePresetInfo x) => x.name), <String>['清晰']);

      final File file = File(p.join(support.path, 'dsanima', 'picture-combos.json'));
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(jsonEncode(<String, Object?>{
        'demo': <Object?>[
          <String, Object?>{
            'id': 'c1',
            'name': '夜间',
            'values': <String, Object?>{'sharpen': 0.3},
          },
        ],
      }));

      await ensurePictureMenuAttached(
        player: _fakePlayer(<List<String>>[]),
        supportDir: support,
        current: menu,
        attach: (_) {},
      );

      expect(menu.presets.map((PicturePresetInfo x) => x.name),
          <String>['清晰', '我的 · 夜间']);
    });
  });
}
