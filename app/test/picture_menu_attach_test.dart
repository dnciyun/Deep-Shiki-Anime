/// 「装完插件后播放器不会立马生效」的回归（用户 2026-10-18 原话）。
///
/// 判据不是"有没有函数"，而是**运行期补挂**这条真路径：播放窗口开着的时候才装上
/// 画面调节包，宿主重扫后必须能拿到一个"现在就能用"的菜单（参数/预设都在），
/// 已挂着的菜单要能重扫（关掉的预设消失、包换了版本后按新版本重新渲染）。
///
/// 全部用临时目录 + 假播放器（`Anime4kController(runner:)`，与
/// `anime4k_controller_test.dart` / `picture_pack_test.dart` 同一手法）——
/// 不联网、不启动 app（按项目规矩）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:dsanima/state/extension_schemes.dart'
    show kExtensionsDirName, kExtensionsStateFileName;
import 'package:dsanima/state/picture_menu_attach.dart';
import 'package:dsanima/state/picture_pack.dart' show pictureCacheDirOf;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shikiin/shikiin.dart';

final String _sha = 'b' * 64;

/// 一份画面调节包清单（两个参数 + 两个预设）。
Map<String, Object?> _manifest({
  required String id,
  String version = '1.0.0',
  String name = '演示画面调节',
}) =>
    <String, Object?>{
      'schema': 1,
      'id': id,
      'name': name,
      'version': version,
      'kind': 'picture-pack',
      'files': <Object?>[
        <String, Object?>{'path': 'shaders/picture.glsl', 'size': 40, 'sha256': _sha},
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
              'default': 0.0,
            },
          ],
          'presets': <Object?>[
            <String, Object?>{
              'id': 'soft',
              'name': '柔和',
              'values': <String, Object?>{'sharpen': 0.3},
            },
            <String, Object?>{
              'id': 'crisp',
              'name': '清晰',
              'values': <String, Object?>{'sharpen': 1.2},
            },
          ],
        },
      },
    };

const String _template = '#define SHARPEN @sharpen@\n';

Directory _newSupportDir() =>
    Directory.systemTemp.createTempSync('dsanima-picture-attach-');

/// 装一个完整的画面调节包（清单 + 模板 + 启用标记）。
void _installPack(Directory support, String id, {Map<String, Object?>? manifest}) {
  final Directory ext = Directory(p.join(support.path, kExtensionsDirName, id))
    ..createSync(recursive: true);
  File(p.join(ext.path, 'manifest.json'))
      .writeAsStringSync(jsonEncode(manifest ?? _manifest(id: id)));
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

/// 上次调好的画面（包 + 一个取值）：`<数据根>/dsanima/picture-settings.json`。
void _writePictureSettings(Directory support, Map<String, Object?> json) {
  File(p.join(support.path, 'dsanima', 'picture-settings.json'))
    ..createSync(recursive: true)
    ..writeAsStringSync(jsonEncode(json));
}

/// 假播放器：只记录下发的 mpv 命令。
Anime4kController _fakePlayer(List<List<String>> sent) =>
    Anime4kController(runner: (List<String> args) async => sent.add(args));

void main() {
  group('运行期补挂画面调节菜单', () {
    test('还没有包 → 不挂菜单（返回 null，不调 attach）', () async {
      final Directory support = _newSupportDir();
      addTearDown(() => support.deleteSync(recursive: true));
      final List<PictureMenu?> attached = <PictureMenu?>[];

      final PictureMenu? menu = await ensurePictureMenuAttached(
        player: _fakePlayer(<List<String>>[]),
        supportDir: support,
        current: null,
        attach: attached.add,
      );

      expect(menu, isNull);
      expect(attached, isEmpty);
    });

    test('窗口开着时装上包 → 现场挂出能用的菜单（参数/预设都在）', () async {
      final Directory support = _newSupportDir();
      addTearDown(() => support.deleteSync(recursive: true));
      // 关键场景：调用前**一点包都没有**（= 播放窗口开窗时那份空清单），之后才装。
      final List<PictureMenu?> attached = <PictureMenu?>[];
      _installPack(support, 'picture-demo');

      final PictureMenu? menu = await ensurePictureMenuAttached(
        player: _fakePlayer(<List<String>>[]),
        supportDir: support,
        current: null,
        attach: attached.add,
      );

      expect(menu, isNotNull, reason: '装上包之后必须能挂上菜单（不许等重启）');
      expect(attached.single, same(menu));
      expect(menu!.params.map((PictureParamInfo x) => x.key), <String>['sharpen']);
      expect(menu.presets.map((PicturePresetInfo x) => x.name), <String>['柔和', '清晰']);
      expect(menu.isOff, isTrue, reason: '刚装上、用户没选过 → 不能自己乱开画面调节');
    });

    test('已挂着的菜单 → reload 重扫（扩展页关掉的预设立刻消失）', () async {
      final Directory support = _newSupportDir();
      addTearDown(() => support.deleteSync(recursive: true));
      final List<PictureMenu?> attached = <PictureMenu?>[];
      _installPack(support, 'picture-demo');

      final PictureMenu? menu = await ensurePictureMenuAttached(
        player: _fakePlayer(<List<String>>[]),
        supportDir: support,
        current: null,
        attach: attached.add,
      );
      expect(menu, isNotNull);
      expect(menu!.presets, hasLength(2));

      // 用户在扩展页把「柔和」关掉（真机 00:19 那一步就是这个）：
      File(p.join(support.path, 'dsanima', 'extension-settings.json'))
        ..createSync(recursive: true)
        ..writeAsStringSync(jsonEncode(<String, Object?>{
          'schema': 1,
          'extensions': <String, Object?>{
            'picture-demo': <String, Object?>{
              'hiddenPresets': <String>['soft'],
            },
          },
        }));

      final PictureMenu? after = await ensurePictureMenuAttached(
        player: _fakePlayer(<List<String>>[]),
        supportDir: support,
        current: menu,
        attach: attached.add,
      );

      expect(after, same(menu), reason: '有菜单就重扫，不重复挂');
      expect(attached, hasLength(1));
      expect(after!.presets.map((PicturePresetInfo x) => x.name), <String>['清晰']);
    });

    test('包换了版本（同 id）→ 重扫后按新版本重新渲染（不沿用旧 shader）', () async {
      final Directory support = _newSupportDir();
      addTearDown(() => support.deleteSync(recursive: true));
      _installPack(support, 'picture-demo');
      // 上次选着这个包：ensure 时会 apply 一次（版本 1.0.0 的缓存文件）。
      _writePictureSettings(support, <String, Object?>{
        'pack': 'picture-demo',
        'values': <String, Object?>{'sharpen': 1.0},
      });
      final Directory cache = pictureCacheDirOf(support);

      final PictureMenu? menu = await ensurePictureMenuAttached(
        player: _fakePlayer(<List<String>>[]),
        supportDir: support,
        current: null,
        attach: (_) {},
      );
      expect(menu, isNotNull);
      expect(cache.listSync(), hasLength(1), reason: '1.0.0 渲染过一次');

      // 扩展升级：同 id、版本变了（播放窗口并没有重开）。
      _installPack(support, 'picture-demo',
          manifest: _manifest(id: 'picture-demo', version: '2.0.0'));

      final PictureMenu? after = await ensurePictureMenuAttached(
        player: _fakePlayer(<List<String>>[]),
        supportDir: support,
        current: menu,
        attach: (_) {},
      );

      expect(after, same(menu));
      final List<String> files = cache
          .listSync()
          .whereType<File>()
          .map((File f) => p.basename(f.path))
          .toList();
      expect(files, hasLength(2), reason: '新版本要重渲染（缓存键带版本号）');
      expect(files.any((String n) => n.contains('2.0.0') || n.contains('picture-demo')), isTrue);
    });
  });

  group('接线守卫（缺了这条，装完插件还是要重启才生效）', () {
    test('播放窗口收到「扩展变了」→ 让宿主重扫并丢掉菜单缓存', () {
      final String window = File('lib/ui/player_window_app.dart').readAsStringSync();
      expect(window.contains('onExtensionsChanged'), isTrue);
      expect(window.contains('ref.invalidate(shikiin.pictureMenuProvider)'), isTrue);

      final String main = File('lib/main.dart').readAsStringSync();
      expect(main.contains('onExtensionsChanged: () => _ensurePictureMenu('), isTrue,
          reason: '主窗口装配处必须把「扩展变了」接到补挂逻辑上');
    });
  });
}
