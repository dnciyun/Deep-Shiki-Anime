/// 主窗口的画面编辑器（`state/picture_editor.dart`）：只维护取值 + 写盘 + 通知播放窗口。
///
/// 守的是 spec 的 Review Focus 里跟"主窗口"有关的那几条：
/// * **2** 包卸载后重装，旧取值必须回来（不许重置成默认）；
/// * **3** 播放窗口没开 ⇒ 改动只写盘，不报错、不卡住；
/// * **4** 按住滑杆不放 ⇒ 不每帧写盘/发消息，且不丢最后一次；
/// 外加"坏文件只退化"（1 的那一半）与 `adopt` 不写盘不再 push（防止两个窗口互相覆盖）。
///
/// 全程临时目录真造文件 + 假推送记录器，不开 app、不联网。
library;

import 'dart:convert';
import 'dart:io';

import 'package:dsanima/state/extension_schemes.dart'
    show kExtensionsDirName, kExtensionsStateFileName;
import 'package:dsanima/state/infra.dart';
import 'package:dsanima/state/packs_available.dart';
import 'package:dsanima/state/picture_combos.dart';
import 'package:dsanima/state/picture_editor.dart';
import 'package:dsanima/state/picture_pack.dart';
import 'package:dsanima/state/picture_settings_io.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

final String _sha = 'c' * 64;

Map<String, Object?> _manifest(String id, {String name = '演示画面包'}) => <String, Object?>{
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
              'values': <String, Object?>{'sharpen': 1.5, 'line': 0.45},
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

const String _template = '#define SHARPEN @sharpen@\n#define LINE @line@\n';

Directory _newSupportDir() =>
    Directory.systemTemp.createTempSync('dsanima-picture-editor-');

/// 装一个完整的包（清单 + 模板 + 启用标记）。
void _installPack(Directory support, String id, {Map<String, Object?>? manifest}) {
  final Directory ext = Directory(p.join(support.path, kExtensionsDirName, id))
    ..createSync(recursive: true);
  File(p.join(ext.path, 'manifest.json'))
    ..createSync(recursive: true)
    ..writeAsStringSync(jsonEncode(manifest ?? _manifest(id)));
  File(p.join(ext.path, 'shaders', 'picture.glsl'))
    ..createSync(recursive: true)
    ..writeAsStringSync(_template);
  File(p.join(support.path, kExtensionsDirName, kExtensionsStateFileName))
    ..createSync(recursive: true)
    ..writeAsStringSync(jsonEncode(<String, Object?>{
      'schema': 1,
      'extensions': <String, Object?>{
        id: <String, Object?>{'enabled': true},
      },
    }));
}

/// 假的可用性 provider：测试里直接换清单（模拟装/卸）。
class _FakeAvailability extends PackAvailabilityController {
  List<PicturePack> _packs = const <PicturePack>[];
  bool _built = false;

  @override
  PackAvailability build() {
    _built = true;
    return PackAvailability(picturePacks: _packs);
  }

  /// 换清单（模拟装/卸）。容器建好之前只是记下来，`build` 时用。
  void set(List<PicturePack> packs) {
    _packs = packs;
    if (_built) state = PackAvailability(picturePacks: packs);
  }
}

/// 一套测试环境：临时数据根 + 一个包 + 记录推送次数的假通道。
class _Harness {
  _Harness(this.support, this.packs);

  final Directory support;
  final List<PicturePack> packs;
  final List<void> pushes = <void>[];
  late final _FakeAvailability availability = _FakeAvailability()..set(packs);
  late final ProviderContainer container = ProviderContainer(
    overrides: [
      supportDirProvider.overrideWithValue(support),
      packAvailabilityProvider.overrideWith(() => availability),
      // 记录器：跨窗口发消息在这里不可用，而"推了几次"正是防抖用例要断言的。
      picturePushProvider.overrideWithValue(() async => pushes.add(null)),
    ],
  );

  PictureEditorController get controller =>
      container.read(pictureEditorProvider.notifier);
  PictureEditorState get state => container.read(pictureEditorProvider);

  File get settingsFile => pictureSettingsFileOf(support);

  Map<String, Object?> readSettingsJson() =>
      jsonDecode(settingsFile.readAsStringSync()) as Map<String, Object?>;

  void dispose() => container.dispose();
}

/// 同步装包（`loadPicturePacks` 是异步的，但测试里需要先拿到包再起容器）。
Future<List<PicturePack>> _load(Directory support) => loadPicturePacks(support);

void main() {
  group('读盘：取值来自文件或包默认值', () {
    test('ensureLoaded 之后 values = 包默认值（没存过设置）', () async {
      final Directory support = _newSupportDir();
      addTearDown(() => support.deleteSync(recursive: true));
      _installPack(support, 'picture-demo');
      final List<PicturePack> packs = await _load(support);
      final _Harness harness = _Harness(support, packs);
      addTearDown(harness.dispose);

      await harness.controller.ensureLoaded();

      expect(harness.state.loaded, isTrue);
      expect(harness.state.problem, isNull);
      expect(harness.state.editingPack?.id, 'picture-demo', reason: '关着也要有可调的包');
      expect(harness.state.currentPack, isNull, reason: '关 = 没有生效中的包');
      expect(harness.state.values, <String, double>{'sharpen': 1.0, 'line': 0.45});
      expect(harness.state.settings.isOff, isTrue, reason: '没存过设置 = 关');
      expect(harness.state.isOff, isTrue);
    });

    test('文件里存过取值 → 直接显示那一份（用户不用重调）', () async {
      final Directory support = _newSupportDir();
      addTearDown(() => support.deleteSync(recursive: true));
      _installPack(support, 'picture-demo');
      final File file = pictureSettingsFileOf(support);
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(jsonEncode(<String, Object?>{
        'pack': 'picture-demo',
        'preset': 'crisp',
        'values': <String, Object?>{'sharpen': 1.25, 'line': 0.3},
      }));
      final _Harness harness = _Harness(support, await _load(support));
      addTearDown(harness.dispose);

      await harness.controller.ensureLoaded();

      expect(harness.state.settings.presetId, 'crisp');
      expect(harness.state.values['sharpen'], 1.25);
      expect(harness.state.isOff, isFalse);
    });

    test('坏文件 → 只退化（加载成功、按默认值显示、不抛）', () async {
      final Directory support = _newSupportDir();
      addTearDown(() => support.deleteSync(recursive: true));
      _installPack(support, 'picture-demo');
      final File file = pictureSettingsFileOf(support);
      file.parent.createSync(recursive: true);
      file.writeAsStringSync('{"pack": "picture-demo", "values": {"sharp');
      final _Harness harness = _Harness(support, await _load(support));
      addTearDown(harness.dispose);

      await harness.controller.ensureLoaded();

      expect(harness.state.loaded, isTrue);
      expect(harness.state.values['sharpen'], 1.0);
    });

    test('一个包都没有（清单坏/模板缺）→ 空态 + 一句说明，不抛', () async {
      final Directory support = _newSupportDir();
      addTearDown(() => support.deleteSync(recursive: true));
      final _Harness harness = _Harness(support, const <PicturePack>[]);
      addTearDown(harness.dispose);

      await harness.controller.ensureLoaded();

      expect(harness.state.loaded, isTrue);
      expect(harness.state.isOff, isTrue);
      expect(harness.state.values, isEmpty);
      expect(harness.state.problem, isNotNull, reason: '页面要能说清"为什么是空的"');
    });

    test('没注入数据根 → 退化成一句说明，不抛', () async {
      final ProviderContainer container = ProviderContainer(
        overrides: [
          packAvailabilityProvider.overrideWith(() => _FakeAvailability()),
          picturePushProvider.overrideWithValue(() async {}),
        ],
      );
      addTearDown(container.dispose);

      await container.read(pictureEditorProvider.notifier).ensureLoaded();

      expect(container.read(pictureEditorProvider).loaded, isTrue);
      expect(container.read(pictureEditorProvider).problem, isNotNull);
    });
  });

  group('滑杆：只改内存，夹值走同一套 PictureParam.clampValue', () {
    test('越界取值被夹回上限，返回值就是真正生效的值', () async {
      final Directory support = _newSupportDir();
      addTearDown(() => support.deleteSync(recursive: true));
      _installPack(support, 'picture-demo');
      final _Harness harness = _Harness(support, await _load(support));
      addTearDown(harness.dispose);
      await harness.controller.ensureLoaded();

      // 关着的时候第一次拖就把包选起来（与播放窗口面板同一条规矩）。
      final double effective = harness.controller.setValue('sharpen', 999);

      expect(effective, 2);
      expect(harness.state.values['sharpen'], 2);
      expect(harness.state.isOff, isFalse);
      expect(harness.state.settings.presetId, isNull, reason: '手调之后不再算某个预设');
    });
  });

  group('写盘 + 推送：一次操作一条', () {
    test('commit 写出的 json 与内存 settings 一致，并且恰好推一次', () async {
      final Directory support = _newSupportDir();
      addTearDown(() => support.deleteSync(recursive: true));
      _installPack(support, 'picture-demo');
      final _Harness harness = _Harness(support, await _load(support));
      addTearDown(harness.dispose);
      await harness.controller.ensureLoaded();

      harness.controller.setValue('sharpen', 1.35);
      await harness.controller.commit();

      expect(harness.readSettingsJson(), harness.state.settings.toJson());
      expect(harness.pushes, hasLength(1));
    });

    test('连续 5 次 setValue + 一次 commit → 只写一条通道消息（拖滑杆不该每帧发）', () async {
      final Directory support = _newSupportDir();
      addTearDown(() => support.deleteSync(recursive: true));
      _installPack(support, 'picture-demo');
      final _Harness harness = _Harness(support, await _load(support));
      addTearDown(harness.dispose);
      await harness.controller.ensureLoaded();

      for (int i = 0; i < 5; i++) {
        harness.controller.setValue('sharpen', 0.1 * i);
      }
      expect(harness.pushes, isEmpty, reason: '拖动中不该发消息');
      await harness.controller.commit();

      expect(harness.pushes, hasLength(1));
      expect(harness.readSettingsJson()['values'], <String, Object?>{'sharpen': 0.4, 'line': 0.45});
    });

    test('防抖：setValue 之后不 commit，220ms 后自己落盘 + 推送，且是最新那一次', () async {
      final Directory support = _newSupportDir();
      addTearDown(() => support.deleteSync(recursive: true));
      _installPack(support, 'picture-demo');
      final _Harness harness = _Harness(support, await _load(support));
      addTearDown(harness.dispose);
      await harness.controller.ensureLoaded();

      harness.controller.setValue('sharpen', 0.5);
      harness.controller.setValue('sharpen', 1.1);
      expect(harness.pushes, isEmpty);

      // 等过防抖窗口（220ms）：定时器自己 commit 一次。
      await Future<void>.delayed(const Duration(milliseconds: 450));

      expect(harness.pushes, hasLength(1), reason: '两次改动合成一次写 + 一次推');
      expect(harness.readSettingsJson()['values'], <String, Object?>{'sharpen': 1.1, 'line': 0.45});
    });

    test('拖完立刻松手（commit）→ 待落盘的那一次被并掉，不会写出两条', () async {
      final Directory support = _newSupportDir();
      addTearDown(() => support.deleteSync(recursive: true));
      _installPack(support, 'picture-demo');
      final _Harness harness = _Harness(support, await _load(support));
      addTearDown(harness.dispose);
      await harness.controller.ensureLoaded();

      harness.controller.setValue('sharpen', 1.1);
      await harness.controller.commit();
      await Future<void>.delayed(const Duration(milliseconds: 450));

      expect(harness.pushes, hasLength(1), reason: '松手那一次是唯一的一次');
    });

    test('turnOff → 文件写成"空的那一份"并推一次', () async {
      final Directory support = _newSupportDir();
      addTearDown(() => support.deleteSync(recursive: true));
      _installPack(support, 'picture-demo');
      final _Harness harness = _Harness(support, await _load(support));
      addTearDown(harness.dispose);
      await harness.controller.ensureLoaded();

      harness.controller.setValue('sharpen', 1.5);
      await harness.controller.commit();
      harness.pushes.clear();

      await harness.controller.turnOff();

      expect(harness.state.isOff, isTrue);
      // 关掉之后滑杆仍显示包的默认值（与播放窗口面板的回退一致）。
      expect(harness.state.values, <String, double>{'sharpen': 1.0, 'line': 0.45});
      expect(harness.readSettingsJson(), <String, Object?>{});
      expect(harness.pushes, hasLength(1));
    });

    test('resetPack → 回到包默认值，但仍然是"开"', () async {
      final Directory support = _newSupportDir();
      addTearDown(() => support.deleteSync(recursive: true));
      _installPack(support, 'picture-demo');
      final _Harness harness = _Harness(support, await _load(support));
      addTearDown(harness.dispose);
      await harness.controller.ensureLoaded();

      await harness.controller.applyPreset('crisp');
      expect(harness.state.values['sharpen'], 1.5);

      await harness.controller.resetPack();

      expect(harness.state.values, <String, double>{'sharpen': 1.0, 'line': 0.45});
      expect(harness.state.isOff, isFalse, reason: '「重置」不是「关」');
      expect(harness.state.currentPack?.id, 'picture-demo');
    });
  });

  group('「我的组合」', () {
    test('存两次同名 → 两套都在（不覆盖）', () async {
      final Directory support = _newSupportDir();
      addTearDown(() => support.deleteSync(recursive: true));
      _installPack(support, 'picture-demo');
      final _Harness harness = _Harness(support, await _load(support));
      addTearDown(harness.dispose);
      await harness.controller.ensureLoaded();

      harness.controller.setValue('sharpen', 1.2);
      await harness.controller.commit();
      final String? first = await harness.controller.saveCombo('夜间');
      final String? second = await harness.controller.saveCombo('夜间');

      expect(first, isNotNull);
      expect(second, isNotNull);
      expect(first, isNot(second));
      expect(harness.state.combos['picture-demo'], hasLength(2));
      expect(
        harness.state.combos['picture-demo']!.map((dynamic c) => c.name),
        <String>['夜间', '夜间'],
      );
      // 存下来的取值是**完整取值**（不是差异），否则包换默认值后这套组合会变形。
      expect(harness.state.combos['picture-demo']!.first.values['line'], 0.45);
      // 也进文件了（播放窗口的右键菜单从这份文件读）。
      final Map<String, Object?> json = jsonDecode(
        pictureCombosFileOf(support).readAsStringSync(),
      ) as Map<String, Object?>;
      expect((json['picture-demo']! as List<Object?>), hasLength(2));
    });

    test('空名字 → null，不存', () async {
      final Directory support = _newSupportDir();
      addTearDown(() => support.deleteSync(recursive: true));
      _installPack(support, 'picture-demo');
      final _Harness harness = _Harness(support, await _load(support));
      addTearDown(harness.dispose);
      await harness.controller.ensureLoaded();

      expect(await harness.controller.saveCombo('   '), isNull);
      expect(harness.state.combos, isEmpty);
    });

    test('applyCombo → 取值落成那套组合，presetId 记成 custom:<id>（菜单据此勾选）', () async {
      final Directory support = _newSupportDir();
      addTearDown(() => support.deleteSync(recursive: true));
      _installPack(support, 'picture-demo');
      final _Harness harness = _Harness(support, await _load(support));
      addTearDown(harness.dispose);
      await harness.controller.ensureLoaded();

      harness.controller.setValue('sharpen', 0.35);
      await harness.controller.commit();
      final String? id = await harness.controller.saveCombo('夜间');
      final String comboId = id!.split('custom:').last;

      // 先切到别处，再套回来。
      await harness.controller.applyPreset('crisp');
      expect(harness.state.values['sharpen'], 1.5);

      await harness.controller.applyCombo(comboId);
      expect(harness.state.values['sharpen'], 0.35);
      expect(harness.state.settings.presetId, 'custom:$comboId');
    });

    test('关着的时候点组合也要生效（2026-10-20 用户报的 bug）', () async {
      // 复现：先关（`currentPack == null`）→ 点「我的 · x」没反应，必须先点别的预设
      // 或拖一下滑杆把它打开才点得动。根因是 `applyCombo` 用了 `state.currentPack`
      // 而 `applyPreset` 用的是"正在调的那个包"（关着时回退到第一个包）—— 两条路
      // 对"关"的语义不一致。用户原话：「选择在关的时候，无法选择保存的预设，
      // 只有点其他的才能再点到」。
      final Directory support = _newSupportDir();
      addTearDown(() => support.deleteSync(recursive: true));
      _installPack(support, 'picture-demo');
      final _Harness harness = _Harness(support, await _load(support));
      addTearDown(harness.dispose);
      await harness.controller.ensureLoaded();

      harness.controller.setValue('sharpen', 0.35);
      await harness.controller.commit();
      final String comboId = (await harness.controller.saveCombo('夜间'))!.split('custom:').last;

      await harness.controller.turnOff();
      expect(harness.state.isOff, isTrue, reason: '前置条件：现在是关着的');

      await harness.controller.applyCombo(comboId);

      expect(harness.state.settings.packId, 'picture-demo',
          reason: '点组合就该把它打开（点一项 = 就这样看，与 `applyPreset` 同一条规矩）');
      expect(harness.state.isOff, isFalse);
      expect(harness.state.values['sharpen'], 0.35);
      expect(harness.state.settings.presetId, 'custom:$comboId');
    });

    test('deleteCombo → 组合没了、文件里也没了，且不抛', () async {
      final Directory support = _newSupportDir();
      addTearDown(() => support.deleteSync(recursive: true));
      _installPack(support, 'picture-demo');
      final _Harness harness = _Harness(support, await _load(support));
      addTearDown(harness.dispose);
      await harness.controller.ensureLoaded();

      harness.controller.setValue('sharpen', 1.1);
      await harness.controller.commit();
      final String id = (await harness.controller.saveCombo('夜间'))!;
      final String comboId = id.split('custom:').last;

      await harness.controller.deleteCombo(comboId);

      expect(harness.state.currentCombos, isEmpty);
      final Map<String, Object?> json = jsonDecode(
        pictureCombosFileOf(support).readAsStringSync(),
      ) as Map<String, Object?>;
      expect(json.containsKey('picture-demo'), isFalse, reason: '空数组不该写进文件');
    });
  });

  group('Review Focus 2：包卸载后重装，旧取值要回来', () {
    test('卸载 → 页面只剩空态（不写"关"）→ 重装 → 旧取值原样回来', () async {
      final Directory support = _newSupportDir();
      addTearDown(() => support.deleteSync(recursive: true));
      _installPack(support, 'picture-demo');
      final List<PicturePack> packs = await _load(support);
      final _Harness harness = _Harness(support, packs);
      addTearDown(harness.dispose);

      await harness.controller.ensureLoaded();
      harness.controller.setValue('sharpen', 1.6);
      await harness.controller.commit();
      expect(harness.state.values['sharpen'], 1.6);

      // 用户卸载了包（扩展页 → 卸载 → revision 变 → 可用性重扫）。
      harness.availability.set(const <PicturePack>[]);
      await harness.controller.ensureLoaded();
      expect(harness.state.isOff, isTrue, reason: '没有包 = 什么都没生效');
      expect(harness.state.values, isEmpty);
      expect(
        harness.state.settings.packId,
        'picture-demo',
        reason: '文件里那个 packId 必须留着 —— 卸载不是"关"',
      );

      // 重新装回来。
      harness.availability.set(packs);
      await harness.controller.ensureLoaded();

      expect(harness.state.values['sharpen'], 1.6, reason: '旧取值要回来，不许重置成默认');
      expect(harness.state.isOff, isFalse);
      expect(harness.state.currentPack?.id, 'picture-demo');
    });
  });

  group('Review Focus 3 + adopt：没开播放窗口 / 播放器回推', () {
    test('没开播放窗口（默认 push = 真通道，没有窗口）→ commit 不抛、照样写盘', () async {
      final Directory support = _newSupportDir();
      addTearDown(() => support.deleteSync(recursive: true));
      _installPack(support, 'picture-demo');
      // 故意**不** override `picturePushProvider`：走真实默认实现
      //（`playerWindowServiceProvider` 是占位实例 ⇒ 没有窗口 ⇒ send 是空操作）。
      final _FakeAvailability availability = _FakeAvailability()
        ..set(await _load(support));
      final ProviderContainer container = ProviderContainer(
        overrides: [
          supportDirProvider.overrideWithValue(support),
          packAvailabilityProvider.overrideWith(() => availability),
        ],
      );
      addTearDown(container.dispose);

      final PictureEditorController controller =
          container.read(pictureEditorProvider.notifier);
      await controller.ensureLoaded();
      controller.setValue('sharpen', 1.2);
      await controller.commit(); // 不许抛

      expect(pictureSettingsFileOf(support).existsSync(), isTrue);
      expect(container.read(pictureEditorProvider).values['sharpen'], 1.2);
    });

    test('adopt：同步显示回推的取值，但**不写盘、不再 push**', () async {
      final Directory support = _newSupportDir();
      addTearDown(() => support.deleteSync(recursive: true));
      _installPack(support, 'picture-demo');
      final _Harness harness = _Harness(support, await _load(support));
      addTearDown(harness.dispose);
      await harness.controller.ensureLoaded();
      harness.pushes.clear();

      harness.controller.adopt(<String, Object?>{
        'pack': 'picture-demo',
        'values': <String, Object?>{'sharpen': 0.65, 'line': 0.7},
      });

      expect(harness.state.values['sharpen'], 0.65);
      expect(harness.state.settings.packId, 'picture-demo');
      expect(harness.pushes, isEmpty, reason: '文件是对面写的，主窗口不再 push');
      expect(harness.settingsFile.existsSync(), isFalse, reason: '也不写盘');
    });

    test('adopt 会取消待落盘的那一次（否则把播放器刚调的覆盖掉）', () async {
      final Directory support = _newSupportDir();
      addTearDown(() => support.deleteSync(recursive: true));
      _installPack(support, 'picture-demo');
      final _Harness harness = _Harness(support, await _load(support));
      addTearDown(harness.dispose);
      await harness.controller.ensureLoaded();

      // 页面上刚拖了一下（还没过防抖），此时播放窗口回推了它自己调好的那一份。
      harness.controller.setValue('sharpen', 2.0);
      harness.controller.adopt(<String, Object?>{
        'pack': 'picture-demo',
        'values': <String, Object?>{'sharpen': 0.3},
      });
      await Future<void>.delayed(const Duration(milliseconds: 450));

      expect(harness.state.values['sharpen'], 0.3, reason: '播放器那份是最后说话的人');
      expect(harness.pushes, isEmpty);
      expect(harness.settingsFile.existsSync(), isFalse, reason: '待落盘的那次被取消了');
    });
  });
}
