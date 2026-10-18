/// 扩展页（1.1.0 M3/T15）的 widget 测试：**不联网、不碰磁盘**。
///
/// 注入假 `ExtensionsPort` + 假 `PickerPort`（与 `extensions_state_test.dart` 同一套做法），
/// 这里钉的是**用户看到的界面**：
/// * 空态把"扩展是资源包 / 本版本支持 shader-pack"说清楚；
/// * 已安装行：名称/版本/类型中文/大小/来源/启用状态 + 启用·禁用·卸载；
/// * `usable == false` 的行必须写「本版本不接运行时」，`usable == true` 写
///   「可在播放器的「超分」菜单里选用」——
///   ⚠️ **不许写「设置 → 超分方案」**（Lead 2026-10-17 更正：设置页这一轮没有方案区）；
/// * 安装中：名字 + 进度条（总量未知 = 不确定进度）+ 取消（cancelling 时禁用）；
/// * notice 与 problem 是**两个落点**（problem 红字 + 怎么办）；
/// * 卸载先弹确认框，并说明文件进回收站；
/// * 在线目录：同 id 已装显示「重新安装」。
library;

import 'dart:async';

import 'package:dsanima/domain/extensions.dart';
import 'package:dsanima/domain/extensions_port.dart';
import 'package:dsanima/domain/ports.dart';
import 'package:dsanima/state/extensions.dart';
import 'package:dsanima/state/providers.dart' show pickerPortProvider;
import 'package:dsanima/theme/app_theme.dart';
import 'package:dsanima/theme/tokens.dart';
import 'package:dsanima/ui/extensions_page.dart';
import 'package:dsanima/ui/widgets/neo.dart';
import 'package:dsanima_core/dsanima_core.dart' as core;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

// ─────────────────────────────────────────────────────────────────────────────
// 夹具
// ─────────────────────────────────────────────────────────────────────────────

core.ExtensionManifest _manifest({
  String id = 'demo-pack',
  String name = '演示包',
  String kind = 'shader-pack',
  String version = '1.2.0',
  String description = '一个演示用的扩展',
}) {
  final core.ManifestParseResult parsed = core.parseExtensionManifest(<String, Object?>{
    'schema': 1,
    'id': id,
    'name': name,
    'version': version,
    'kind': kind,
    'description': description,
    'files': <Object?>[
      <String, Object?>{'path': 'shaders/a.glsl', 'size': 12, 'sha256': 'a' * 64},
    ],
    if (kind == 'shader-pack')
      'payload': <String, Object?>{
        'shader': <String, Object?>{'dir': 'shaders', 'files': <String>['a.glsl']},
      },
  }, currentAppVersion: '1.1.0');
  expect(parsed.ok, isTrue, reason: '测试夹具本身必须合法：${parsed.issues}');
  return parsed.manifest!;
}

/// 画面调节包夹具：三个预设（`设置` 按钮只给"有预设的包"）。
core.ExtensionManifest _pictureManifest({
  String id = 'picture-demo',
  String name = '画面调节演示',
  List<String> presetIds = const <String>['crisp', 'soft', 'warm'],
}) {
  final core.ManifestParseResult parsed = core.parseExtensionManifest(<String, Object?>{
    'schema': 1,
    'id': id,
    'name': name,
    'version': '1.1.0',
    'kind': 'picture-pack',
    'files': <Object?>[
      <String, Object?>{'path': 'shaders/picture.glsl', 'size': 12, 'sha256': 'b' * 64},
    ],
    'payload': <String, Object?>{
      'picture': <String, Object?>{
        'template': 'shaders/picture.glsl',
        // 包的一句说明：只在扩展页「设置」里显示（用户 2026-10-18：
        // 「右键菜单内不要有太多介绍，全在扩展内就好了」）。
        'hint': '演示包的说明：默认不改画面。',
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
          for (final String pid in presetIds)
            <String, Object?>{
              'id': pid,
              'name': pid == 'crisp'
                  ? '清晰'
                  : pid == 'soft'
                      ? '柔和'
                      : '暖色',
              'description': pid == 'crisp' ? '推荐：线条细而实，不糊。' : '',
              'values': <String, Object?>{'sharpen': 1.0},
            },
        ],
      },
    },
  }, currentAppVersion: '1.1.0');
  expect(parsed.ok, isTrue, reason: '画面调节夹具本身必须合法：${parsed.issues}');
  return parsed.manifest!;
}

InstalledExtension _installedPicture({
  String id = 'picture-demo',
  String name = '画面调节演示',
  bool enabled = true,
  List<String> presetIds = const <String>['crisp', 'soft', 'warm'],
}) =>
    InstalledExtension(
      manifest: _pictureManifest(id: id, name: name, presetIds: presetIds),
      enabled: enabled,
      installedAt: DateTime(2026, 10, 18),
      origin: ExtensionOrigin.localZip,
      bytes: 4096,
    );

InstalledExtension _installed({
  String id = 'demo-pack',
  String name = '演示包',
  String kind = 'shader-pack',
  String version = '1.2.0',
  String description = '一个演示用的扩展',
  bool enabled = true,
  int bytes = 1536 * 1024,
  ExtensionOrigin origin = ExtensionOrigin.localZip,
}) =>
    InstalledExtension(
      manifest: _manifest(
        id: id,
        name: name,
        kind: kind,
        version: version,
        description: description,
      ),
      enabled: enabled,
      installedAt: DateTime(2026, 10, 17, 12),
      origin: origin,
      bytes: bytes,
    );

core.CatalogEntry _catalogEntry({
  String id = 'new-pack',
  String name = '新扩展',
  String description = '目录里的演示扩展',
  int? size = 4096,
  String? sha256 = 'b',
  String url = 'https://example.com/new.zip',
}) =>
    core.CatalogEntry(
      manifest: _manifest(id: id, name: name, description: description),
      url: Uri.parse(url),
      size: size,
      sha256: sha256 == null ? null : sha256 * 64,
    );

/// 假的扩展端口：记录调用、可闸门化安装（确定性测"安装中/取消"）。
class _FakeExtensionsPort implements ExtensionsPort {
  List<InstalledExtension> installed = <InstalledExtension>[];

  int scanCalls = 0;
  Object? scanError;
  Object? installError;
  List<core.CatalogEntry> catalog = <core.CatalogEntry>[];

  /// 拉过哪些目录地址（「官方插件库」按钮钉的是"用的是哪个地址"）。
  final List<Uri> catalogUrls = <Uri>[];

  final List<ExtensionInstallRequest> installRequests = <ExtensionInstallRequest>[];
  final List<String> removedIds = <String>[];
  final List<(String, bool)> enabledCalls = <(String, bool)>[];
  int openDirCalls = 0;

  /// 安装卡在这里（测试先点取消/断言，再 `gate.complete()`）。
  Completer<void>? gate;

  /// 在 gate 之前推一次进度（模拟"下载到一半"）。
  bool pushProgress = true;
  ExtensionProgress progress = const ExtensionProgress(received: 3, total: 10);

  /// 装好之后返回的那一条。
  InstalledExtension? installResult;

  @override
  String get extensionsDir => r'C:\fake\extensions';

  @override
  Future<List<InstalledExtension>> scan() async {
    scanCalls++;
    final Object? error = scanError;
    if (error != null) throw error;
    return installed;
  }

  @override
  Future<InstalledExtension> install(
    ExtensionInstallRequest request, {
    void Function(ExtensionProgress progress)? onProgress,
    bool Function()? isCancelled,
  }) async {
    installRequests.add(request);
    if (pushProgress) onProgress?.call(progress);
    final Completer<void>? waiting = gate;
    if (waiting != null) await waiting.future;
    if (isCancelled?.call() ?? false) {
      throw const ExtensionInstallCancelled();
    }
    final Object? error = installError;
    if (error != null) throw error;
    final InstalledExtension item = installResult ??
        _installed(
          name: request.manifest?.name ?? '演示包',
          origin: request.origin,
        );
    installed = <InstalledExtension>[...installed, item];
    return item;
  }

  @override
  Future<void> setEnabled(String id, bool enabled) async {
    enabledCalls.add((id, enabled));
    installed = <InstalledExtension>[
      for (final InstalledExtension item in installed)
        if (item.id == id) item.copyWith(enabled: enabled) else item,
    ];
  }

  @override
  Future<void> remove(String id) async {
    removedIds.add(id);
    installed = <InstalledExtension>[
      for (final InstalledExtension item in installed)
        if (item.id != id) item,
    ];
  }

  @override
  Future<List<core.CatalogEntry>> fetchCatalog(Uri url) async {
    catalogUrls.add(url);
    return catalog;
  }

  @override
  Future<void> openDirectory() async {
    openDirCalls++;
  }
}

class _FakePickerPort implements PickerPort {
  String? file;
  int pickFileCalls = 0;

  @override
  Future<String?> pickDirectory({String? title}) async => null;

  @override
  Future<String?> pickFile({String? title, List<String> extensions = const <String>[]}) async {
    pickFileCalls++;
    return file;
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 脚手架
// ─────────────────────────────────────────────────────────────────────────────

Widget _harness(_FakeExtensionsPort port, {_FakePickerPort? picker}) => ProviderScope(
      overrides: [
        extensionsPortProvider.overrideWithValue(port),
        pickerPortProvider.overrideWithValue(picker ?? _FakePickerPort()),
      ],
      child: MaterialApp(
        theme: buildDsanimaTheme(),
        home: const Scaffold(body: ExtensionsPage()),
      ),
    );

Future<void> _pump(
  WidgetTester tester,
  _FakeExtensionsPort port, {
  _FakePickerPort? picker,
  Size size = const Size(1400, 1200),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(_harness(port, picker: picker));
  await tester.pumpAndSettle();
}

DsTokens _tokens(WidgetTester tester) =>
    tester.element(find.byType(ExtensionsPage)).ds;

String _textOf(WidgetTester tester, Key key) =>
    tester.widget<Text>(find.byKey(key)).data ?? '';

/// notice 落在 NeoBanner 上（不是 Text），单读一下它的文案。
String _noticeText(WidgetTester tester) =>
    tester.widget<NeoBanner>(find.byKey(dsExtensionsNoticeKey)).text;

void main() {
  group('空态与统计', () {
    testWidgets('没装扩展：统计行 + 说清「扩展是资源包 / 本版本支持 shader-pack」', (WidgetTester tester) async {
      final _FakeExtensionsPort port = _FakeExtensionsPort();
      await _pump(tester, port);

      expect(find.byKey(dsExtensionsStatsKey), findsOneWidget);
      expect(_textOf(tester, dsExtensionsStatsKey), contains('已安装 0 个'));
      expect(_textOf(tester, dsExtensionsStatsKey), contains('占用 —'),
          reason: '0 字节显示「—」（formatBytes 的全站口径），不编一个 0 MB');
      expect(find.byKey(dsExtensionsEmptyKey), findsOneWidget);
      expect(find.textContaining('资源包'), findsWidgets, reason: '空态要说清扩展是什么');
      expect(find.textContaining('shader-pack'), findsWidgets);
      expect(find.textContaining('「超分」菜单'), findsWidgets);
      // ⚠️ Lead 2026-10-17 更正的文案口径：设置页这一轮没有超分方案区。
      expect(find.textContaining('设置 → 超分方案'), findsNothing);
      expect(port.scanCalls, 1, reason: '页面挂载时扫描一次（懒挂载：不重复扫）');
    });

    testWidgets('扫描失败：红字（为什么）+ 红字（怎么办），空态指向那条红字', (WidgetTester tester) async {
      final _FakeExtensionsPort port = _FakeExtensionsPort()
        ..scanError = const ExtensionFailure('扩展目录读不了', hint: '检查磁盘权限');
      await _pump(tester, port);
      final DsTokens t = _tokens(tester);

      expect(find.byKey(dsExtensionsProblemKey), findsOneWidget);
      expect(_textOf(tester, dsExtensionsProblemKey), '扩展目录读不了');
      expect(_textOf(tester, dsExtensionsProblemHintKey), contains('检查磁盘权限'));
      expect(tester.widget<Text>(find.byKey(dsExtensionsProblemKey)).style?.color, t.danger,
          reason: '问题必须是红字');
      expect(tester.widget<Text>(find.byKey(dsExtensionsProblemHintKey)).style?.color, t.danger);
      expect(find.textContaining('读不到已安装列表'), findsOneWidget,
          reason: '读盘失败时不许说「还没有安装任何扩展」');
    });
  });

  group('已安装列表', () {
    testWidgets('两行：名称/版本/类型中文/大小/来源/启用状态 + 可用性说明', (WidgetTester tester) async {
      final _FakeExtensionsPort port = _FakeExtensionsPort()
        ..installed = <InstalledExtension>[
          _installed(id: 'shader-pack-demo', name: '动画超分演示', bytes: 1536 * 1024),
          _installed(
            id: 'data-demo',
            name: '数据包演示',
            kind: 'data-pack',
            version: '0.9.0',
            enabled: false,
            bytes: 2048,
            origin: ExtensionOrigin.url,
          ),
        ];
      await _pump(tester, port);

      expect(find.byKey(dsExtensionRowKey('shader-pack-demo')), findsOneWidget);
      expect(find.byKey(dsExtensionRowKey('data-demo')), findsOneWidget);
      expect(find.text('动画超分演示'), findsOneWidget);
      expect(find.text('数据包演示'), findsOneWidget);
      expect(find.text('v1.2.0'), findsOneWidget);
      expect(find.text('v0.9.0'), findsOneWidget);
      // 类型中文走 core 的 ExtensionKind.labelOf。
      expect(find.text('着色器包'), findsOneWidget);
      expect(find.text('数据包'), findsOneWidget);
      expect(find.text('1.5 MiB'), findsOneWidget);
      expect(find.text('2.0 KiB'), findsOneWidget);
      expect(find.text('来源：本地文件'), findsOneWidget);
      expect(find.text('来源：在线下载'), findsOneWidget);
      expect(find.text('已启用'), findsOneWidget);
      expect(find.text('已禁用'), findsOneWidget);
      expect(_textOf(tester, dsExtensionUseHintKey('shader-pack-demo')),
          '可在播放器的「超分」菜单里选用');
      expect(_textOf(tester, dsExtensionUseHintKey('data-demo')), contains('本版本不接运行时'));
      // 统计行跟着列表走。
      expect(_textOf(tester, dsExtensionsStatsKey), contains('已安装 2 个 · 启用 1 · 可用 1'));
      expect(find.textContaining('设置 → 超分方案'), findsNothing);
    });

    testWidgets('禁用/启用：点一下就调端口，列表按新状态重画', (WidgetTester tester) async {
      final _FakeExtensionsPort port = _FakeExtensionsPort()
        ..installed = <InstalledExtension>[_installed()];
      await _pump(tester, port);

      await tester.tap(find.byKey(dsExtensionToggleKey('demo-pack')));
      await tester.pumpAndSettle();

      expect(port.enabledCalls, <(String, bool)>[('demo-pack', false)]);
      expect(find.text('已禁用'), findsOneWidget);
      final Finder row = find.byKey(dsExtensionRowKey('demo-pack'));
      expect(find.descendant(of: row, matching: find.text('启用')), findsOneWidget,
          reason: '禁用之后按钮变成「启用」');
    });

    testWidgets('卸载：先确认（说明进回收站）；取消则什么都不发生', (WidgetTester tester) async {
      final _FakeExtensionsPort port = _FakeExtensionsPort()
        ..installed = <InstalledExtension>[_installed()];
      await _pump(tester, port);

      await tester.tap(find.byKey(dsExtensionRemoveKey('demo-pack')));
      await tester.pumpAndSettle();

      expect(find.text('卸载「演示包」？'), findsOneWidget);
      expect(find.textContaining('回收站'), findsWidgets, reason: '必须说明文件可恢复');
      await tester.tap(find.byKey(dsExtensionsRemoveCancelKey));
      await tester.pumpAndSettle();

      expect(port.removedIds, isEmpty, reason: '取消 = 不卸载');
      expect(find.text('卸载「演示包」？'), findsNothing);
      expect(find.byKey(dsExtensionRowKey('demo-pack')), findsOneWidget);
    });

    testWidgets('卸载确认后：调 remove、列表少一条、notice 说明文件在回收站', (WidgetTester tester) async {
      final _FakeExtensionsPort port = _FakeExtensionsPort()
        ..installed = <InstalledExtension>[_installed()];
      await _pump(tester, port);

      await tester.tap(find.byKey(dsExtensionRemoveKey('demo-pack')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(dsExtensionsRemoveConfirmKey));
      await tester.pumpAndSettle();

      expect(port.removedIds, <String>['demo-pack']);
      expect(find.byKey(dsExtensionRowKey('demo-pack')), findsNothing);
      expect(find.byKey(dsExtensionsNoticeKey), findsOneWidget);
      expect(find.textContaining('已卸载「演示包」'), findsOneWidget);
      expect(find.textContaining('回收站'), findsWidgets);
    });
  });

  group('安装中：进度 / 取消 / 按钮禁用', () {
    testWidgets('有名有进度（3/10 = 30%）；取消后显示「正在取消…」并禁用，收尾是中性提示', (
      WidgetTester tester,
    ) async {
      final _FakeExtensionsPort port = _FakeExtensionsPort();
      port.gate = Completer<void>();
      await _pump(tester, port);

      await tester.enterText(find.byKey(dsExtensionsUrlFieldKey), 'https://example.com/pack.zip');
      await tester.tap(find.byKey(dsExtensionsUrlInstallKey));
      await tester.pump();

      expect(find.byKey(dsExtensionsInstallingKey), findsOneWidget);
      expect(find.text('正在安装'), findsOneWidget);
      expect(find.textContaining('「扩展」'), findsWidgets, reason: 'URL 直链没有清单名，用「扩展」');
      final LinearProgressIndicator bar =
          tester.widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator));
      expect(bar.value, closeTo(0.3, 1e-9), reason: '3 / 10 = 30%');
      expect(find.textContaining('已收到'), findsOneWidget);

      // 忙时所有动作按钮都禁用。
      expect(tester.widget<NeoButton>(find.byKey(dsExtensionsRefreshKey)).onPressed, isNull);
      expect(tester.widget<NeoButton>(find.byKey(dsExtensionsImportZipKey)).onPressed, isNull);
      expect(tester.widget<NeoButton>(find.byKey(dsExtensionsUrlInstallKey)).onPressed, isNull);

      await tester.tap(find.byKey(dsExtensionsCancelKey));
      await tester.pump();
      final Finder cancel = find.byKey(dsExtensionsCancelKey);
      expect(tester.widget<NeoButton>(cancel).label, '正在取消…');
      expect(tester.widget<NeoButton>(cancel).onPressed, isNull,
          reason: '正在取消时按钮要禁用（端口还在收尾）');

      port.gate!.complete();
      await tester.pumpAndSettle();

      expect(find.byKey(dsExtensionsInstallingKey), findsNothing);
      expect(find.byKey(dsExtensionsProblemKey), findsNothing, reason: '取消 ≠ 失败（不许红字）');
      expect(find.textContaining('已取消安装'), findsOneWidget);
      final NeoBanner banner = tester.widget<NeoBanner>(find.byKey(dsExtensionsNoticeKey));
      expect(banner.kind, NeoBannerKind.info, reason: '取消是中性提示，不是成功也不是失败');
    });

    testWidgets('对端没给总大小：进度条不确定（value == null），文案如实说"总量未知"', (
      WidgetTester tester,
    ) async {
      final _FakeExtensionsPort port = _FakeExtensionsPort()
        ..progress = const ExtensionProgress(received: 1024);
      port.gate = Completer<void>();
      await _pump(tester, port);

      await tester.enterText(find.byKey(dsExtensionsUrlFieldKey), 'https://example.com/pack.zip');
      await tester.tap(find.byKey(dsExtensionsUrlInstallKey));
      await tester.pump();

      final LinearProgressIndicator bar =
          tester.widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator));
      expect(bar.value, isNull, reason: '不拿"已下载多少"除以编造的总量');
      expect(find.textContaining('对端没给总大小'), findsOneWidget);
      expect(find.textContaining('1.0 KiB'), findsOneWidget, reason: '已收到 1024 B');

      await tester.tap(find.byKey(dsExtensionsCancelKey));
      await tester.pump();
      port.gate!.complete();
      await tester.pumpAndSettle();
      expect(find.textContaining('已取消安装'), findsOneWidget);
    });

    testWidgets('装好之后：notice 由状态机给（写播放器「超分」菜单，不写设置页）', (WidgetTester tester) async {
      final _FakeExtensionsPort port = _FakeExtensionsPort();
      await _pump(tester, port);

      await tester.enterText(find.byKey(dsExtensionsUrlFieldKey), 'https://example.com/pack.zip');
      await tester.tap(find.byKey(dsExtensionsUrlInstallKey));
      await tester.pumpAndSettle();

      expect(find.byKey(dsExtensionsNoticeKey), findsOneWidget);
      expect(find.textContaining('已安装'), findsWidgets);
      expect(find.textContaining('「超分」菜单'), findsWidgets,
          reason: '状态机口径：装好即可在播放器「超分」菜单选用（第六十四轮起热刷新，不用重开窗口）');
      expect(find.textContaining('设置 → 超分方案'), findsNothing);
      final NeoBanner banner = tester.widget<NeoBanner>(find.byKey(dsExtensionsNoticeKey));
      expect(banner.kind, NeoBannerKind.success, reason: '成功是绿条');
      expect(find.byKey(dsExtensionRowKey('demo-pack')), findsOneWidget,
          reason: '装好后列表里要有它');
    });

    testWidgets('本地导入 zip：选择器返回路径 → 安装请求带 localPath', (WidgetTester tester) async {
      final _FakeExtensionsPort port = _FakeExtensionsPort();
      final _FakePickerPort picker = _FakePickerPort()..file = r'C:\tmp\pack.zip';
      await _pump(tester, port, picker: picker);

      await tester.tap(find.byKey(dsExtensionsImportZipKey));
      await tester.pumpAndSettle();

      expect(picker.pickFileCalls, 1);
      expect(port.installRequests.single.localPath, r'C:\tmp\pack.zip');
      expect(port.installRequests.single.url, isNull);
    });
  });

  group('地址校验 / 操作按钮', () {
    testWidgets('公网 http 地址：红字「下载地址不可用」+ 怎么办，且不发安装请求', (WidgetTester tester) async {
      final _FakeExtensionsPort port = _FakeExtensionsPort();
      await _pump(tester, port);

      await tester.enterText(find.byKey(dsExtensionsUrlFieldKey), 'http://example.com/pack.zip');
      await tester.tap(find.byKey(dsExtensionsUrlInstallKey));
      await tester.pumpAndSettle();

      expect(port.installRequests, isEmpty);
      expect(_textOf(tester, dsExtensionsProblemKey), contains('下载地址不可用'));
      expect(_textOf(tester, dsExtensionsProblemHintKey), contains('https://'));
    });

    testWidgets('刷新 / 打开扩展目录都接到端口上', (WidgetTester tester) async {
      final _FakeExtensionsPort port = _FakeExtensionsPort();
      await _pump(tester, port);
      expect(port.scanCalls, 1);

      await tester.tap(find.byKey(dsExtensionsRefreshKey));
      await tester.pumpAndSettle();
      expect(port.scanCalls, 2, reason: '刷新 = 重新扫盘');

      await tester.tap(find.byKey(dsExtensionsOpenDirKey));
      await tester.pumpAndSettle();
      expect(port.openDirCalls, 1);
    });
  });

  group('在线目录', () {
    testWidgets('目录列表：名称/说明/版本/大小；同 id 已装显示「重新安装」', (WidgetTester tester) async {
      final _FakeExtensionsPort port = _FakeExtensionsPort()
        ..installed = <InstalledExtension>[_installed(id: 'installed-pack', name: '已装包')]
        ..catalog = <core.CatalogEntry>[
          _catalogEntry(),
          _catalogEntry(
            id: 'installed-pack',
            name: '已装包',
            description: '已经在本地装过的那一条',
            url: 'https://example.com/installed.zip',
          ),
        ];
      await _pump(tester, port);

      await tester.enterText(
          find.byKey(dsExtensionsCatalogFieldKey), 'https://example.com/catalog.json');
      await tester.tap(find.byKey(dsExtensionsCatalogFetchKey));
      await tester.pumpAndSettle();

      expect(find.byKey(dsExtensionsCatalogRowKey('new-pack')), findsOneWidget);
      expect(find.byKey(dsExtensionsCatalogRowKey('installed-pack')), findsOneWidget);
      expect(find.text('新扩展'), findsOneWidget);
      expect(find.text('目录里的演示扩展'), findsOneWidget);
      expect(find.textContaining('4.0 KiB'), findsWidgets, reason: '目录 size 如实显示');
      expect(find.text('安装'), findsOneWidget);
      expect(find.text('重新安装'), findsOneWidget,
          reason: '同 id 已装 → 装下去是覆盖/升级');
      expect(find.textContaining('目录已加载：2 个扩展'), findsOneWidget);

      await tester.tap(find.byKey(dsExtensionsCatalogInstallKey('new-pack')));
      await tester.pumpAndSettle();
      final ExtensionInstallRequest request = port.installRequests.single;
      expect(request.url, Uri.parse('https://example.com/new.zip'));
      expect(request.size, 4096);
      expect(request.sha256, 'b' * 64, reason: '目录给了 sha256 就必须带上（校验更严）');
    });

    testWidgets('空目录：中性提示「这个目录里没有可用扩展」', (WidgetTester tester) async {
      final _FakeExtensionsPort port = _FakeExtensionsPort()..catalog = <core.CatalogEntry>[];
      await _pump(tester, port);

      await tester.enterText(
          find.byKey(dsExtensionsCatalogFieldKey), 'https://example.com/catalog.json');
      await tester.tap(find.byKey(dsExtensionsCatalogFetchKey));
      await tester.pumpAndSettle();

      expect(find.textContaining('这个目录里没有可用扩展'), findsOneWidget);
      final NeoBanner banner = tester.widget<NeoBanner>(find.byKey(dsExtensionsNoticeKey));
      expect(banner.kind, NeoBannerKind.info);
    });

    testWidgets('目录没给 sha256：如实标「未提供哈希」（不假装校验过）', (WidgetTester tester) async {
      final _FakeExtensionsPort port = _FakeExtensionsPort()
        ..catalog = <core.CatalogEntry>[_catalogEntry(sha256: null, size: null)];
      await _pump(tester, port);

      await tester.enterText(
          find.byKey(dsExtensionsCatalogFieldKey), 'https://example.com/catalog.json');
      await tester.tap(find.byKey(dsExtensionsCatalogFetchKey));
      await tester.pumpAndSettle();

      expect(find.textContaining('未提供哈希'), findsOneWidget);
      expect(find.textContaining('size 未知'), findsNothing);
    });
  });

  group('扩展设置（画面调节包的预设开关）', () {
    testWidgets('只有"有设置项"的扩展才显示「设置」按钮', (WidgetTester tester) async {
      final _FakeExtensionsPort port = _FakeExtensionsPort()
        ..installed = <InstalledExtension>[_installed(), _installedPicture()];
      await _pump(tester, port);

      expect(find.byKey(dsExtensionSettingsKey('picture-demo')), findsOneWidget);
      expect(find.byKey(dsExtensionSettingsKey('demo-pack')), findsNothing,
          reason: 'shader-pack 没有可设置的项，不许放一个点进去空白的入口');
    });

    testWidgets('设置对话框：关掉一个预设 → 保存 → 提示说清关了几个；再打开勾选状态还在',
        (WidgetTester tester) async {
      final _FakeExtensionsPort port = _FakeExtensionsPort()
        ..installed = <InstalledExtension>[_installedPicture()];
      await _pump(tester, port);

      await tester.tap(find.byKey(dsExtensionSettingsKey('picture-demo')));
      await tester.pumpAndSettle();
      // 三个预设都在（默认全开）
      expect(find.text('清晰'), findsWidgets);
      expect(find.text('柔和'), findsWidgets);
      expect(find.text('暖色'), findsWidgets);

      // 关掉「柔揉」…（按 key 点，避免撞上页面别处的同名文字）
      await tester.tap(find.byKey(dsExtensionPresetToggleKey('picture-demo', 'soft')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(dsExtensionSettingsSaveKey));
      await tester.pumpAndSettle();

      expect(_noticeText(tester), contains('关掉了 1 个预设'));

      // 重新打开：勾选状态被记住（读的是 provider 里的设置）
      await tester.tap(find.byKey(dsExtensionSettingsKey('picture-demo')));
      await tester.pumpAndSettle();
      final CheckboxListTile soft = tester.widget<CheckboxListTile>(
        find.byKey(dsExtensionPresetToggleKey('picture-demo', 'soft')),
      );
      expect(soft.value, isFalse);
      final CheckboxListTile crisp = tester.widget<CheckboxListTile>(
        find.byKey(dsExtensionPresetToggleKey('picture-demo', 'crisp')),
      );
      expect(crisp.value, isTrue);
    });

    testWidgets('设置对话框：说明文字都在扩展页里（包一句 + 每档预设一行）',
        (WidgetTester tester) async {
      final _FakeExtensionsPort port = _FakeExtensionsPort()
        ..installed = <InstalledExtension>[_installedPicture()];
      await _pump(tester, port);

      await tester.tap(find.byKey(dsExtensionSettingsKey('picture-demo')));
      await tester.pumpAndSettle();

      // 用户 2026-10-18：「右键菜单内不要有太多介绍，全在扩展内就好了」——
      // 说明从播放器右键菜单搬到了这里，就必须真的在这里看得见。
      expect(
        find.text('演示包的说明：默认不改画面。'),
        findsOneWidget,
        reason: '包的一句说明（payload.picture.hint）要在设置对话框顶部',
      );
      expect(
        find.text('推荐：线条细而实，不糊。'),
        findsOneWidget,
        reason: '每档预设的说明要挂在它自己那一行下（subtitle）',
      );
    });

    testWidgets('官方插件库：出厂就指向 dnciyun/DSAnima-plungin（用户不用先粘地址）',
        (WidgetTester tester) async {
      final _FakeExtensionsPort port = _FakeExtensionsPort()
        ..catalog = <core.CatalogEntry>[_catalogEntry()];
      await _pump(tester, port);

      await tester.tap(find.byKey(dsExtensionsOfficialKey));
      await tester.pumpAndSettle();

      // 用户 2026-10-18 给了插件仓库地址：这一键从"提示先配地址"变成"直接拉"。
      expect(port.catalogUrls.single.toString(), kOfficialExtensionsCatalogUrl);
      expect(_noticeText(tester), contains('目录已加载'));
      // 输入框里也填着它：用户能看见官方库在哪儿，也能复制去浏览器核对。
      final TextField field = tester.widget<TextField>(
        find.byKey(dsExtensionsCatalogFieldKey),
      );
      expect(field.controller?.text, kOfficialExtensionsCatalogUrl);
      expect(find.byKey(dsExtensionsProblemKey), findsNothing);
    });
  });
}
