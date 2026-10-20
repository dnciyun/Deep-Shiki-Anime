/// 「画面调节」页（`ui/picture_page.dart`）的组件测试。
///
/// 守的是"用户真的点得动"这一层：拖滑杆之后模型变了、点「关」真关了、存组合之后
/// 那一项出现在自己的 chips 里、去扩展页管理真跳过去、预设可见性真写到设置文件。
/// 还钉住 Review Focus 1：**装着包但扫描失败**时这一页只退化（一句说明），绝不崩。
///
/// 页面按 1400×1000 跑（默认 800×600 会 `RenderFlex overflowed` —— 拖放确认框那一轮
/// 踩过的坑，见计划里的全局约束）。不启动 app、不联网，包与数据根都是临时目录。
library;

import 'dart:convert';
import 'dart:io';

import 'package:dsanima/state/extension_settings.dart';
import 'package:dsanima/state/extension_schemes.dart'
    show kExtensionsDirName, kExtensionsStateFileName;
import 'package:dsanima/state/extensions.dart' show extensionsRevisionProvider;
import 'package:dsanima/state/infra.dart';
import 'package:dsanima/state/packs_available.dart';
import 'package:dsanima/state/picture_editor.dart';
import 'package:dsanima/state/picture_pack.dart';
import 'package:dsanima/state/providers.dart' show ShellTab, navProvider;
import 'package:dsanima/theme/app_theme.dart';
import 'package:dsanima/ui/picture_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

final String _sha = 'e' * 64;

const String _template = '#define SHARPEN @sharpen@\n#define LINE @line@\n';

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
              'unit': '%',
            },
            <String, Object?>{
              'key': 'line',
              'label': '线条强化',
              'min': 0,
              'max': 1,
              'step': 0.05,
              'default': 0.45,
              'group': '锐度与线条',
            },
          ],
          'presets': <Object?>[
            <String, Object?>{
              'id': 'crisp',
              'name': '清晰',
              'values': <String, Object?>{'sharpen': 1.5},
            },
            <String, Object?>{
              'id': 'soft',
              'name': '柔和',
              'values': <String, Object?>{'sharpen': 0.2},
            },
          ],
        },
      },
    };

Directory _newSupportDir() =>
    Directory.systemTemp.createTempSync('dsanima-picture-page-');

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

/// 固定值的可用性（**扫描类方法必须一起置空**）。
///
/// 页面 `initState` 的 postFrame 一定会调一次 `ensureLoaded()`；真实现会按数据根重扫，
/// 把这里钉死的清单**覆盖**成"没有包"，让所有用例静默退化成空态。
class _FixedAvailability extends PackAvailabilityController {
  _FixedAvailability(this.fixed);

  final PackAvailability fixed;

  @override
  PackAvailability build() => fixed;

  @override
  Future<void> ensureLoaded() async {}

  @override
  Future<void> refresh() async {}
}

/// 一套页面测试环境：临时数据根 + 容器 + 已装好的包。
class _PageHost {
  _PageHost(this.support, this.packs);

  final Directory support;
  final List<PicturePack> packs;
  final List<void> pushes = <void>[];
  late final ProviderContainer container = ProviderContainer(
    overrides: [
      supportDirProvider.overrideWithValue(support),
      packAvailabilityProvider.overrideWith(
        () => _FixedAvailability(PackAvailability(picturePacks: packs)),
      ),
      // 记录器：组件测试里没有窗口通道，"推了几次/推没推"要能断言。
      picturePushProvider.overrideWithValue(() async => pushes.add(null)),
    ],
  );

  PictureEditorState get editor => container.read(pictureEditorProvider);

  Future<void> load() async {
    await container.read(extensionUserSettingsProvider.notifier).ensureLoaded(support);
    await container.read(pictureEditorProvider.notifier).ensureLoaded();
  }

  void dispose() => container.dispose();
}

/// 把页面挂起来（用显式容器，好在 pump 之前先把盘上的东西读完）。
Future<void> _pumpPage(WidgetTester tester, _PageHost host) async {
  tester.view.physicalSize = const Size(1400, 1000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  // 真磁盘 IO 必须在 `runAsync` 里等：`testWidgets` 跑在 FakeAsync 区里，
  // 直接 await 真 IO 会永远等不到（超时挂死，实测踩过）。
  await tester.runAsync(host.load);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: host.container,
      child: MaterialApp(
        theme: buildDsanimaTheme(),
        home: const Scaffold(body: PicturePage()),
      ),
    ),
  );
  // postFrame 里的 ensureLoaded + 首帧之后的 rebuild。
  await tester.pump();
  await tester.pump();
}

/// 等到某个条件成立（默认最多 40 轮 ≈ 1 秒真实时间）。
///
/// `testWidgets` 跑在 FakeAsync 区里，而页面里的落盘是**真实 IO**：
/// * 真 IO 的完成要靠真事件循环（`tester.runAsync`）；
/// * 它的续体又排在 FakeAsync 的微任务队列里（要 `pump` 才抽干）。
/// 只做其中一半就会停在"设置改了但还没写盘"的中间态 —— 那正是这条用例最初
/// 报"文件没写、版本号没 bump"的原因，不是产品 bug。
Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() ready, {
  int rounds = 40,
}) async {
  for (int i = 0; i < rounds && !ready(); i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 25)),
    );
    await tester.pump();
  }
}

void main() {
  testWidgets('拖滑杆 → 模型里的取值变了（页面只改内存，落盘交给防抖）', (WidgetTester tester) async {
    final Directory support = _newSupportDir();
    addTearDown(() => support.deleteSync(recursive: true));
    _install(support, 'picture-demo');
    final _PageHost host = _PageHost(support, await loadPicturePacks(support));
    addTearDown(host.dispose);
    await _pumpPage(tester, host);

    expect(find.byKey(dsPictureSliderKey('sharpen')), findsOneWidget);
    expect(host.editor.values['sharpen'], 1.0, reason: '默认值先摆好');

    final Rect rect = tester.getRect(find.byKey(dsPictureSliderKey('sharpen')));
    // 点在轨道偏左：取值一定小于默认的 1.0（min=0, max=2）。
    await tester.tapAt(Offset(rect.left + rect.width * 0.2, rect.center.dy));
    await tester.pump();

    expect(host.editor.values['sharpen'], lessThan(1.0));
    expect(host.editor.isOff, isFalse, reason: '拖一下就等于选了包（否则"能拖但没反应"）');
    expect(host.editor.settings.packId, 'picture-demo');
  });

  testWidgets('点预设 → 取值换成那一档，chips 上能看出来', (WidgetTester tester) async {
    final Directory support = _newSupportDir();
    addTearDown(() => support.deleteSync(recursive: true));
    _install(support, 'picture-demo');
    final _PageHost host = _PageHost(support, await loadPicturePacks(support));
    addTearDown(host.dispose);
    await _pumpPage(tester, host);

    await tester.tap(find.byKey(dsPicturePresetKey('crisp')));
    await tester.pump();

    expect(host.editor.values['sharpen'], 1.5);
    expect(host.editor.settings.presetId, 'crisp');
  });

  testWidgets('点「关」→ isOff（页面不再显示"开着"）', (WidgetTester tester) async {
    final Directory support = _newSupportDir();
    addTearDown(() => support.deleteSync(recursive: true));
    _install(support, 'picture-demo');
    final _PageHost host = _PageHost(support, await loadPicturePacks(support));
    addTearDown(host.dispose);
    await _pumpPage(tester, host);

    await tester.tap(find.byKey(dsPicturePresetKey('crisp')));
    await tester.pump();
    expect(host.editor.isOff, isFalse);

    await tester.tap(find.byKey(dsPictureOffKey));
    await tester.pump();

    expect(host.editor.isOff, isTrue);
    expect(host.editor.settings.isOff, isTrue);
  });

  testWidgets('存为「我的组合」→ 组合多一项，页面上出现「我的 · 夜间」', (WidgetTester tester) async {
    final Directory support = _newSupportDir();
    addTearDown(() => support.deleteSync(recursive: true));
    _install(support, 'picture-demo');
    final _PageHost host = _PageHost(support, await loadPicturePacks(support));
    addTearDown(host.dispose);
    await _pumpPage(tester, host);
    expect(find.text('我的 · 夜间'), findsNothing);

    await tester.tap(find.byKey(dsPictureSaveComboKey));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.byKey(dsPictureComboNameKey), findsOneWidget, reason: '要先问名字');

    await tester.enterText(find.byKey(dsPictureComboNameKey), '夜间');
    await tester.tap(find.byKey(dsPictureComboSaveKey));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump();

    expect(host.editor.currentCombos, hasLength(1));
    expect(host.editor.currentCombos.single.name, '夜间');
    expect(find.text('我的 · 夜间'), findsOneWidget);
    // 顺带把"这一套就是现在生效的"标出来（否则用户会觉得存了个没用的东西）。
    expect(host.editor.settings.presetId, startsWith('custom:'));
  });

  testWidgets('关掉之后点「我的 · 夜间」→ 直接生效（2026-10-20 用户报的 bug）', (
    WidgetTester tester,
  ) async {
    // 用户原话：「选择在关的时候，无法选择保存的预设，只有点其他的才能再点到」。
    // 页面这一层要钉的是"从关 → 点组合"这条真实点击路径，而不只是控制器单测。
    final Directory support = _newSupportDir();
    addTearDown(() => support.deleteSync(recursive: true));
    _install(support, 'picture-demo');
    final _PageHost host = _PageHost(support, await loadPicturePacks(support));
    addTearDown(host.dispose);
    await _pumpPage(tester, host);

    // 先存一套「夜间」。
    await tester.tap(find.byKey(dsPictureSaveComboKey));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.enterText(find.byKey(dsPictureComboNameKey), '夜间');
    await tester.tap(find.byKey(dsPictureComboSaveKey));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump();

    final String comboId = host.editor.currentCombos.single.id;
    final Map<String, double> comboValues = host.editor.currentCombos.single.values;

    // 关 → 现在 currentPack 是 null（旧实现在这里点组合没反应）。
    await tester.tap(find.byKey(dsPictureOffKey));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(host.editor.isOff, isTrue, reason: '前置条件：现在是关着的');

    await tester.tap(find.byKey(dsPictureComboKey(comboId)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(host.editor.isOff, isFalse, reason: '点组合就该把它打开');
    expect(host.editor.settings.presetId, 'custom:$comboId');
    expect(host.editor.values['sharpen'], comboValues['sharpen']);
  });

  testWidgets('删掉当前组合 → chips 消失、文件里的那一项没了', (WidgetTester tester) async {
    final Directory support = _newSupportDir();
    addTearDown(() => support.deleteSync(recursive: true));
    _install(support, 'picture-demo');
    final _PageHost host = _PageHost(support, await loadPicturePacks(support));
    addTearDown(host.dispose);
    await _pumpPage(tester, host);

    // 先存一套（存完就是当前那一套，删除按钮才可用）。
    await tester.tap(find.byKey(dsPictureSaveComboKey));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.enterText(find.byKey(dsPictureComboNameKey), '夜间');
    await tester.tap(find.byKey(dsPictureComboSaveKey));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump();
    expect(find.text('我的 · 夜间'), findsOneWidget);

    await tester.tap(find.byKey(dsPictureDeleteComboKey));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump();

    expect(host.editor.currentCombos, isEmpty);
    expect(find.text('我的 · 夜间'), findsNothing);
  });

  testWidgets('点「去扩展页管理」→ 导航到扩展页', (WidgetTester tester) async {
    final Directory support = _newSupportDir();
    addTearDown(() => support.deleteSync(recursive: true));
    _install(support, 'picture-demo');
    final _PageHost host = _PageHost(support, await loadPicturePacks(support));
    addTearDown(host.dispose);
    await _pumpPage(tester, host);

    await tester.tap(find.byKey(dsPictureManageKey));
    await tester.pump();

    expect(host.container.read(navProvider), ShellTab.extensions);
  });

  testWidgets('预设可见性对话框保存 → hiddenPresets 变了，版本号也 +1', (WidgetTester tester) async {
    final Directory support = _newSupportDir();
    addTearDown(() => support.deleteSync(recursive: true));
    _install(support, 'picture-demo');
    final _PageHost host = _PageHost(support, await loadPicturePacks(support));
    addTearDown(host.dispose);
    await _pumpPage(tester, host);
    final int revisionBefore = host.container.read(extensionsRevisionProvider);

    await tester.tap(find.byKey(dsPictureVisibilityKey));
    // 对话框里的"全量预设"要重读一次盘（未被过滤的那份），所以多给几帧。
    for (int i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(find.byKey(dsPictureVisibilityToggleKey('crisp')), findsOneWidget);

    // 关掉「柔和」。
    await tester.tap(find.byKey(dsPictureVisibilityToggleKey('soft')));
    await tester.pump();
    await tester.tap(find.byKey(dsPictureVisibilitySaveKey));
    await tester.pump();
    // 保存动作里有一次**真实**文件写（`extension-settings.json`），写完才 bump 版本号。
    await _pumpUntil(
      tester,
      () => host.container.read(extensionsRevisionProvider) > revisionBefore,
    );

    expect(
      host.container.read(extensionUserSettingsProvider).hiddenPresetsOf('picture-demo'),
      <String>{'soft'},
    );
    // 真写进了 `extension-settings.json`（播放窗口开窗时读的就是这一份）。
    final File file = extensionUserSettingsFileOf(support);
    expect(file.existsSync(), isTrue);
    expect(file.readAsStringSync(), contains('soft'));
    expect(
      host.container.read(extensionsRevisionProvider),
      greaterThan(revisionBefore),
      reason: 'bump 之后侧栏/播放窗口才会重扫',
    );
  });

  testWidgets('Review Focus 1：装着包但扫描失败 → 只退化成一句说明，不崩', (WidgetTester tester) async {
    final Directory support = _newSupportDir();
    addTearDown(() => support.deleteSync(recursive: true));
    // 清单是坏 json（扫描会跳过它）：页面上不该出现"可调的东西"，但也不许抛。
    final Directory ext = Directory(p.join(support.path, kExtensionsDirName, 'broken'))
      ..createSync(recursive: true);
    File(p.join(ext.path, 'manifest.json')).writeAsStringSync('{ 这不是 json');

    final _PageHost host = _PageHost(support, const <PicturePack>[]);
    addTearDown(host.dispose);
    await _pumpPage(tester, host);

    expect(tester.takeException(), isNull);
    expect(find.textContaining('没找到画面调节包'), findsOneWidget);
    expect(find.byKey(dsPictureSaveComboKey), findsNothing, reason: '没有包就没有可存的东西');
    expect(host.editor.loaded, isTrue);
  });

  testWidgets('多个包才出包选择器（单包时不出）', (WidgetTester tester) async {
    final Directory support = _newSupportDir();
    addTearDown(() => support.deleteSync(recursive: true));
    _install(support, 'picture-a', manifest: _manifest('picture-a', name: '包A'));
    _install(support, 'picture-b', manifest: _manifest('picture-b', name: '包B'));
    final _PageHost host = _PageHost(support, await loadPicturePacks(support));
    addTearDown(host.dispose);
    await _pumpPage(tester, host);

    expect(find.byKey(dsPicturePackKey('picture-a')), findsOneWidget);
    expect(find.byKey(dsPicturePackKey('picture-b')), findsOneWidget);

    await tester.tap(find.byKey(dsPicturePackKey('picture-b')));
    await tester.pump();

    expect(host.editor.editingPack?.id, 'picture-b');
  });
}
