/// 字幕面 consumer：把通用扩展包（`preset-pack` / `player.subtitle`）翻译成
/// 播放器认识的 `SubtitlePreset`，并处理字体资产与热刷新。
///
/// 守的是「装完包设置里没有 / 点不动 / 字体坏了拖垮整包 / 卸包后还挂着旧预设」这一类问题。
library;

import 'dart:convert';
import 'dart:io';

import 'package:dsanima/domain/app_version.dart';
import 'package:dsanima/state/extension_schemes.dart'
    show kExtensionsDirName, kExtensionsStateFileName;
import 'package:dsanima/state/generic_packs.dart';
import 'package:dsanima/state/subtitle_presets.dart';
import 'package:dsanima_core/dsanima_core.dart' as core;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shikiin/shikiin.dart';

final String _sha = 'a' * 64;

Map<String, Object?> _manifest({
  required String id,
  String name = '演示字幕包',
  String surface = 'player.subtitle',
  List<Object?> files = const <Object?>[],
  Map<String, Object?>? payload,
}) =>
    <String, Object?>{
      'schema': 1,
      'id': id,
      'name': name,
      'version': '1.0.0',
      'kind': 'preset-pack',
      'minAppVersion': kAppVersion.toString(),
      'files': files,
      'payload': payload ??
          <String, Object?>{
            'surface': surface,
            'surfaceSchema': 1,
            'presets': <Object?>[
              <String, Object?>{
                'id': 'cinema',
                'name': '影院大字',
                'values': <String, Object?>{'scale': 1.6, 'color': '#FFFFFF'},
              },
            ],
          },
    };

Directory _newSupportDir() =>
    Directory.systemTemp.createTempSync('dsanima-subtitle-presets-');

/// 写 `state.json` 的启用标记（禁用某个包）。
void _writeEnabledState(Directory support, Map<String, bool> enabled) {
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

void _writeManifest(Directory extDir, Map<String, Object?> manifest) {
  File(p.join(extDir.path, 'manifest.json'))
    ..createSync(recursive: true)
    ..writeAsStringSync(jsonEncode(manifest));
}

void _installPack(Directory support, String id,
    {Map<String, Object?>? manifest}) {
  final Directory ext = Directory(p.join(support.path, kExtensionsDirName, id))
    ..createSync(recursive: true);
  _writeManifest(ext, manifest ?? _manifest(id: id));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('合法预设包 → 1 个字幕预设，值与颜色都归一化好', () async {
    final Directory support = _newSupportDir();
    addTearDown(() => support.deleteSync(recursive: true));
    _installPack(support, 'subtitle-cinema');

    List<SubtitlePreset> captured = const <SubtitlePreset>[];
    final SubtitlePresetConsumer consumer =
        SubtitlePresetConsumer(onChanged: (List<SubtitlePreset> p) => captured = p);
    await consumer.setPacks(await scanGenericPacks(support));

    expect(captured, hasLength(1));
    expect(captured.single.name, '影院大字');
    expect(captured.single.packId, 'subtitle-cinema');
    expect(captured.single.packName, '演示字幕包');
    expect(captured.single.style.scale, 1.6);
    expect(captured.single.style.color, '#FFFFFFFF');
    expect(consumer.summary, contains('1 个字幕预设'));
  });

  test('禁用 / 未知 surface → 不喂给播放器；revert 清空', () async {
    final Directory support = _newSupportDir();
    addTearDown(() => support.deleteSync(recursive: true));
    _installPack(support, 'disabled', manifest: _manifest(id: 'disabled'));
    _writeEnabledState(support, <String, bool>{'disabled': false});
    _installPack(support, 'future-pack',
        manifest: _manifest(id: 'future-pack', surface: 'future.thing'));

    List<SubtitlePreset> captured = const <SubtitlePreset>[];
    final SubtitlePresetConsumer consumer =
        SubtitlePresetConsumer(onChanged: (List<SubtitlePreset> p) => captured = p);
    await consumer.setPacks(await scanGenericPacks(support));
    // 默认全部 enabled：未知 surface 的包会被扫出来，但 consumer 只挑自己的面 → 0 个。
    expect(captured, isEmpty);

    await consumer.revert();
    expect(captured, isEmpty);
  });

  test('同面两个包 → 预设合并，id 用包 id 隔离（不互相覆盖）', () async {
    final Directory support = _newSupportDir();
    addTearDown(() => support.deleteSync(recursive: true));
    _installPack(support, 'b-pack', manifest: _manifest(id: 'b-pack'));
    _installPack(support, 'a-pack', manifest: _manifest(id: 'a-pack'));

    List<SubtitlePreset> captured = const <SubtitlePreset>[];
    final SubtitlePresetConsumer consumer =
        SubtitlePresetConsumer(onChanged: (List<SubtitlePreset> p) => captured = p);
    await consumer.setPacks(await scanGenericPacks(support));

    expect(captured, hasLength(2));
    expect(captured.map((SubtitlePreset p) => p.id).toSet(), hasLength(2));
    expect(captured.first.id, startsWith('a-pack/'));
    expect(consumer.describe((await scanGenericPacks(support)).first), contains('1 个字幕预设'));
  });

  test('字体资产读不出来 → 预设仍在，notes 说明字体没加载上', () async {
    final Directory support = _newSupportDir();
    addTearDown(() => support.deleteSync(recursive: true));
    final Directory ext = Directory(p.join(support.path, kExtensionsDirName, 'font-broken'))
      ..createSync(recursive: true);
    final Map<String, Object?> manifest = _manifest(
      id: 'font-broken',
      files: <Object?>[
        <String, Object?>{'path': 'fonts/x.ttf', 'size': 10, 'sha256': _sha},
      ],
      payload: <String, Object?>{
        'surface': 'player.subtitle',
        'surfaceSchema': 1,
        'assets': <Object?>[
          <String, Object?>{'path': 'fonts/x.ttf', 'role': 'font', 'family': '坏字体'},
        ],
        'presets': <Object?>[
          <String, Object?>{
            'id': 'cinema',
            'name': '影院',
            'values': <String, Object?>{'scale': 1.6},
          },
        ],
      },
    );
    _writeManifest(ext, manifest);
    // 故意不写 fonts/x.ttf（字体加载失败不能挡住预设本身）。
    final core.ManifestParseResult parsed = core.parseExtensionManifest(
      jsonDecode(File(p.join(ext.path, 'manifest.json')).readAsStringSync()),
      currentAppVersion: kAppVersion.toString(),
    );
    final GenericPack pack = GenericPack(
      manifest: parsed.manifest!,
      payload: parsed.manifest!.generic!,
      dir: ext,
      surface: core.extensionSurfaceOf('player.subtitle'),
    );

    List<SubtitlePreset> captured = const <SubtitlePreset>[];
    final SubtitlePresetConsumer consumer =
        SubtitlePresetConsumer(onChanged: (List<SubtitlePreset> p) => captured = p);
    await consumer.setPacks(<GenericPack>[pack]);

    expect(captured, hasLength(1));
    expect(consumer.notes, isNotEmpty);
  });

  test('包里没有预设（kind/面写反的防御）→ consumer 直接跳过', () async {
    final Directory support = _newSupportDir();
    addTearDown(() => support.deleteSync(recursive: true));
    final Directory ext = Directory(p.join(support.path, kExtensionsDirName, 'empty-presets'))
      ..createSync(recursive: true);
    _writeManifest(ext, _manifest(id: 'empty-presets'));
    final core.ManifestParseResult parsed = core.parseExtensionManifest(
      jsonDecode(File(p.join(ext.path, 'manifest.json')).readAsStringSync()),
      currentAppVersion: kAppVersion.toString(),
    );
    final GenericPack pack = GenericPack(
      manifest: parsed.manifest!,
      // 面上写着字幕、但载荷里没有任何预设（core 会在解析阶段拒掉写反的 kind，
      // 这里模拟"旧版本写的包/未来字段"之类的漏网输入）。
      payload: const core.GenericPayload(surface: 'player.subtitle', surfaceSchema: 1),
      dir: ext,
      surface: core.extensionSurfaceOf('player.subtitle'),
    );

    List<SubtitlePreset> captured = const <SubtitlePreset>[];
    final SubtitlePresetConsumer consumer =
        SubtitlePresetConsumer(onChanged: (List<SubtitlePreset> p) => captured = p);
    await consumer.setPacks(<GenericPack>[pack]);

    expect(captured, isEmpty);
  });

  test('接线守卫：播放窗口挂了 notifier + provider override，主窗口开窗预扫', () {
    final String window = File('lib/ui/player_window_app.dart').readAsStringSync();
    expect(window, contains('windowSubtitlePresetsNotifier'));
    expect(window, contains('windowSubtitlePresetNotesNotifier'));
    expect(window, contains('shikiin.subtitlePresetsProvider'));
    expect(window, contains('.overrideWith('));
    expect(window, contains('scanGenericPacks'));

    final String mainFile = File('lib/main.dart').readAsStringSync();
    expect(mainFile, contains('SubtitlePresetConsumer'));
    expect(mainFile, contains('windowSubtitlePresetsNotifier'));
    expect(mainFile, contains('windowSubtitlePresetNotesNotifier'));
  });
}
