/// 扩展状态机（`state/extensions.dart`）的离线测试：**不联网、不碰磁盘**。
///
/// 这里钉的是"界面到底会看到哪句话"：
/// * 取消 ≠ 失败（提示「已取消」而不是红字）；
/// * 装上 ≠ 能用（类型不接运行时必须在成功提示里当场说清）；
/// * 进度不是猜的（对端不给总量时不给分数）；
/// * 装/卸/启用禁用之后要 bump 版本号（1.1.0 T17 的超分方案区靠它重读）。
library;

import 'dart:async';

import 'package:dsanima_core/dsanima_core.dart' as core;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dsanima/domain/extensions.dart';
import 'package:dsanima/domain/extensions_port.dart';
import 'package:dsanima/domain/ports.dart';
import 'package:dsanima/state/extensions.dart';
import 'package:dsanima/state/providers.dart';

/// 最小可用清单（shader-pack，一个文件）。
core.ExtensionManifest _manifest({
  String id = 'demo-pack',
  String name = '演示包',
  String kind = 'shader-pack',
  String version = '1.0.0',
}) {
  final core.ManifestParseResult parsed = core.parseExtensionManifest(<String, Object?>{
    'schema': 1,
    'id': id,
    'name': name,
    'version': version,
    'kind': kind,
    'description': '测试用',
    'files': <Object?>[
      <String, Object?>{'path': 'shaders/a.glsl', 'size': 12, 'sha256': 'a' * 64},
    ],
    if (kind == 'shader-pack')
      'payload': <String, Object?>{
        'shader': <String, Object?>{'dir': 'shaders', 'files': <String>['a.glsl']},
      },
  }, currentAppVersion: '1.0.3');
  expect(parsed.ok, isTrue, reason: '测试夹具本身必须合法：${parsed.issues}');
  return parsed.manifest!;
}

InstalledExtension _installed({
  String id = 'demo-pack',
  bool enabled = true,
  String kind = 'shader-pack',
}) =>
    InstalledExtension(
      manifest: _manifest(id: id, kind: kind),
      enabled: enabled,
      installedAt: DateTime(2026, 10, 17),
      origin: ExtensionOrigin.localZip,
      bytes: 12,
    );

class _FakeExtensionsPort implements ExtensionsPort {
  _FakeExtensionsPort();

  List<InstalledExtension> installed = <InstalledExtension>[];
  int scanCalls = 0;
  Object? scanError;
  Object? installError;
  Object? catalogError;
  List<core.CatalogEntry> catalog = <core.CatalogEntry>[];
  final List<ExtensionInstallRequest> installRequests = <ExtensionInstallRequest>[];
  final List<String> removedIds = <String>[];
  final List<(String, bool)> enabledCalls = <(String, bool)>[];
  int openDirCalls = 0;
  Object? openDirError;

  /// 安装卡在这里，测试先 `cancelInstall()` 再 `gate.complete()`（确定性取消）。
  Completer<void>? gate;

  /// 在 gate 之前推一次进度（模拟"下载到一半"）。
  bool pushProgress = true;

  /// 装好之后返回的那一条（默认 shader-pack；测试可换成 data-pack 等）。
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
    if (pushProgress) {
      onProgress?.call(const ExtensionProgress(received: 3, total: 10));
    }
    final Completer<void>? waiting = gate;
    if (waiting != null) await waiting.future;
    if (isCancelled?.call() ?? false) {
      throw const ExtensionInstallCancelled();
    }
    final Object? error = installError;
    if (error != null) throw error;
    final InstalledExtension item = installResult ??
        InstalledExtension(
          manifest: _manifest(),
          enabled: true,
          installedAt: DateTime(2026, 10, 17),
          origin: request.origin,
          sourceUrl: request.sourceUrl,
          bytes: 12,
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
    final Object? error = catalogError;
    if (error != null) throw error;
    return catalog;
  }

  @override
  Future<void> openDirectory() async {
    openDirCalls++;
    final Object? error = openDirError;
    if (error != null) throw error;
  }
}

class _FakePickerPort implements PickerPort {
  String? file;
  bool throwError = false;
  int pickFileCalls = 0;

  @override
  Future<String?> pickDirectory({String? title}) async => null;

  @override
  Future<String?> pickFile({String? title, List<String> extensions = const <String>[]}) async {
    pickFileCalls++;
    if (throwError) throw const PortUnavailableException('文件选择器不可用', hint: '装配问题');
    return file;
  }
}

class _Harness {
  _Harness() {
    container = ProviderContainer(overrides: [
      extensionsPortProvider.overrideWithValue(port),
      pickerPortProvider.overrideWithValue(picker),
    ]);
    container.listen<ExtensionsState>(extensionsProvider, (_, _) {}, fireImmediately: true);
    container.listen<int>(extensionsRevisionProvider, (_, _) {}, fireImmediately: true);
  }

  final _FakeExtensionsPort port = _FakeExtensionsPort();
  final _FakePickerPort picker = _FakePickerPort();
  late final ProviderContainer container;

  ExtensionsState get state => container.read(extensionsProvider);

  ExtensionsController get controller => container.read(extensionsProvider.notifier);

  int get revision => container.read(extensionsRevisionProvider);

  void dispose() => container.dispose();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('扫描/初始化', () {
    test('ensureLoaded 只扫一次；refresh 可强制重扫', () async {
      final _Harness h = _Harness();
      addTearDown(h.dispose);
      expect(h.state.phase, ExtensionsPhase.idle);
      expect(h.state.installed, isEmpty);

      await h.controller.ensureLoaded();
      expect(h.port.scanCalls, 1);
      expect(h.state.phase, ExtensionsPhase.ready);

      await h.controller.ensureLoaded();
      expect(h.port.scanCalls, 1, reason: '已扫过就不该再扫（懒挂载页面反复进出不重复读盘）');

      await h.controller.refresh();
      expect(h.port.scanCalls, 2);
    });

    test('扫描失败 → problem 带"为什么+怎么办"，不假装空列表', () async {
      final _Harness h = _Harness();
      addTearDown(h.dispose);
      h.port.scanError = const ExtensionFailure('扩展目录读不了', hint: '检查磁盘权限');
      await h.controller.ensureLoaded();
      expect(h.state.phase, ExtensionsPhase.problem);
      expect(h.state.problem, '扩展目录读不了');
      expect(h.state.problemHint, '检查磁盘权限');
    });
  });

  group('本地 zip 安装', () {
    test('选文件 → 安装 → 列表刷新 + notice + 版本号 bump', () async {
      final _Harness h = _Harness();
      addTearDown(h.dispose);
      h.picker.file = r'C:\tmp\demo.zip';
      await h.controller.ensureLoaded();
      final int before = h.revision;

      await h.controller.installFromZip();

      expect(h.port.installRequests, hasLength(1));
      expect(h.port.installRequests.single.localPath, r'C:\tmp\demo.zip');
      expect(h.state.phase, ExtensionsPhase.ready);
      expect(h.state.installed, hasLength(1));
      expect(h.state.notice, contains('已安装'));
      expect(h.state.installingName, isNull);
      expect(h.state.progress, isNull);
      expect(h.revision, before + 1, reason: 'T17 的方案区靠这个版本号重读');
    });

    test('用户取消选文件 → 什么都不做（不是错误）', () async {
      final _Harness h = _Harness();
      addTearDown(h.dispose);
      h.picker.file = null;
      await h.controller.ensureLoaded();
      await h.controller.installFromZip();
      expect(h.port.installRequests, isEmpty);
      expect(h.state.problem, isNull);
      expect(h.state.phase, ExtensionsPhase.ready);
    });

    test('文件选择器坏了 → problem 说明装配问题', () async {
      final _Harness h = _Harness();
      addTearDown(h.dispose);
      h.picker.throwError = true;
      await h.controller.ensureLoaded();
      await h.controller.installFromZip();
      expect(h.state.phase, ExtensionsPhase.problem);
      expect(h.state.problem, contains('文件选择器'));
    });

    test('安装中取消 → 「已取消」不是失败，且列表回到 ready', () async {
      final _Harness h = _Harness();
      addTearDown(h.dispose);
      h.picker.file = r'C:\tmp\demo.zip';
      h.port.gate = Completer<void>();
      await h.controller.ensureLoaded();

      final Future<void> installing = h.controller.installFromZip();
      // 选文件那一步是异步的：先让微任务跑完，才进入 installing。
      await pumpEventQueue();
      expect(h.state.phase, ExtensionsPhase.installing);
      expect(h.state.installingName, '扩展', reason: '本地 zip 还没有清单名，先用兜底名字');
      expect(h.state.progress?.received, 3);

      h.controller.cancelInstall();
      expect(h.state.cancelling, isTrue);

      h.port.gate!.complete();
      await installing;

      expect(h.state.phase, ExtensionsPhase.ready);
      expect(h.state.notice, contains('已取消'));
      expect(h.state.problem, isNull, reason: '取消不许画成红色失败');
      expect(h.state.cancelling, isFalse);
      expect(h.state.installed, isEmpty, reason: '取消 = 正式目录里没有东西');
    });

    test('安装失败 → problem 带原因与怎么办', () async {
      final _Harness h = _Harness();
      addTearDown(h.dispose);
      h.picker.file = r'C:\tmp\demo.zip';
      h.port.installError = const ExtensionFailure('包里的清单不合法', hint: '重新打包一份');
      await h.controller.ensureLoaded();
      await h.controller.installFromZip();
      expect(h.state.phase, ExtensionsPhase.problem);
      expect(h.state.problem, '包里的清单不合法');
      expect(h.state.problemHint, '重新打包一份');
      expect(h.state.installingName, isNull, reason: '失败也要退出安装态');
    });
  });

  group('在线安装', () {
    test('地址非法（公网 http）→ 不调用端口，直接说清原因', () async {
      final _Harness h = _Harness();
      addTearDown(h.dispose);
      await h.controller.ensureLoaded();
      await h.controller.installFromUrl('http://example.com/a.zip');
      expect(h.port.installRequests, isEmpty);
      expect(h.state.problem, contains('HTTPS'));
    });

    test('本机回环 http 允许；装上后 notice 提示去设置页选用', () async {
      final _Harness h = _Harness();
      addTearDown(h.dispose);
      await h.controller.ensureLoaded();
      await h.controller.installFromUrl('http://127.0.0.1:8080/demo.zip');
      expect(h.port.installRequests, hasLength(1));
      expect(h.port.installRequests.single.url.toString(), 'http://127.0.0.1:8080/demo.zip');
      expect(h.state.notice, contains('超分'));
    });

    test('目录安装带上 sha256/size（更严的校验）', () async {
      final _Harness h = _Harness();
      addTearDown(h.dispose);
      await h.controller.ensureLoaded();
      final core.ExtensionManifest manifest = _manifest();
      await h.controller.installFromCatalog(core.CatalogEntry(
        manifest: manifest,
        url: Uri.parse('https://example.com/demo.zip'),
        size: 100,
        sha256: 'b' * 64,
      ));
      final ExtensionInstallRequest request = h.port.installRequests.single;
      expect(request.sha256, 'b' * 64);
      expect(request.size, 100);
      expect(request.manifest?.id, manifest.id);
    });
  });

  group('在线目录', () {
    test('拉取成功 → 目录进状态并提示数量', () async {
      final _Harness h = _Harness();
      addTearDown(h.dispose);
      await h.controller.ensureLoaded();
      h.port.catalog = <core.CatalogEntry>[
        core.CatalogEntry(manifest: _manifest(), url: Uri.parse('https://example.com/a.zip')),
      ];
      await h.controller.addCatalog('https://example.com/catalog.json');
      expect(h.state.catalog, hasLength(1));
      expect(h.state.catalogUri.toString(), 'https://example.com/catalog.json');
      expect(h.state.notice, contains('1 个扩展'));
    });

    test('目录地址非法 → problem，且不覆盖已有目录', () async {
      final _Harness h = _Harness();
      addTearDown(h.dispose);
      await h.controller.ensureLoaded();
      await h.controller.addCatalog('ftp://example.com/catalog.json');
      expect(h.state.problem, contains('地址不可用'));
      expect(h.state.catalog, isEmpty);
    });

    test('目录拉取失败 → problem（网络失败也要说清）', () async {
      final _Harness h = _Harness();
      addTearDown(h.dispose);
      await h.controller.ensureLoaded();
      h.port.catalogError = const ExtensionFailure('目录下载失败', hint: '检查网络或代理');
      await h.controller.addCatalog('https://example.com/catalog.json');
      expect(h.state.phase, ExtensionsPhase.problem);
      expect(h.state.problem, '目录下载失败');
      expect(h.state.problemHint, '检查网络或代理');
    });
  });

  group('启用/卸载/打开目录', () {
    test('禁用保留文件、提示写清；版本号 bump', () async {
      final _Harness h = _Harness();
      addTearDown(h.dispose);
      h.port.installed = <InstalledExtension>[_installed()];
      await h.controller.ensureLoaded();
      final int before = h.revision;

      await h.controller.setEnabled('demo-pack', false);

      expect(h.port.enabledCalls.single, ('demo-pack', false));
      expect(h.state.installed.single.enabled, isFalse);
      expect(h.state.notice, contains('已禁用'));
      expect(h.state.notice, contains('文件还在'));
      expect(h.revision, before + 1);
    });

    test('卸载 → 列表消失 + 提示进回收站', () async {
      final _Harness h = _Harness();
      addTearDown(h.dispose);
      h.port.installed = <InstalledExtension>[_installed()];
      await h.controller.ensureLoaded();
      await h.controller.remove('demo-pack');
      expect(h.port.removedIds.single, 'demo-pack');
      expect(h.state.installed, isEmpty);
      expect(h.state.notice, contains('回收站'));
    });

    test('打开扩展目录失败 → problem', () async {
      final _Harness h = _Harness();
      addTearDown(h.dispose);
      await h.controller.ensureLoaded();
      h.port.openDirError = const ExtensionFailure('目录建不出来', hint: '检查磁盘权限');
      await h.controller.openDirectory();
      expect(h.port.openDirCalls, 1);
      expect(h.state.problem, '目录建不出来');
    });
  });

  group('状态摘要与"能用"的如实表述', () {
    test('装一个本版本不接运行时的类型 → 成功提示里必须当场说清楚', () async {
      final _Harness h = _Harness();
      addTearDown(h.dispose);
      h.picker.file = r'C:\tmp\data.zip';
      h.port.installResult = _installed(id: 'demo-data', kind: 'data-pack');
      await h.controller.ensureLoaded();
      await h.controller.installFromZip();
      expect(h.state.phase, ExtensionsPhase.ready);
      expect(h.state.notice, contains('已安装'));
      expect(h.state.notice, contains('本版本'),
          reason: '装上≠能用：类型不接运行时必须写在成功提示里，不能让用户以为有了新功能');
    });

    test('shader-pack 装好 → 提示指向设置页的超分方案', () async {
      final _Harness h = _Harness();
      addTearDown(h.dispose);
      h.picker.file = r'C:\tmp\demo.zip';
      await h.controller.ensureLoaded();
      await h.controller.installFromZip();
      expect(h.state.notice, contains('超分'));
    });

    test('summary 口径：总数/启用/可用/字节', () async {
      final _Harness h = _Harness();
      addTearDown(h.dispose);
      h.port.installed = <InstalledExtension>[
        _installed(id: 'aa', enabled: true),
        _installed(id: 'bb', enabled: false),
        _installed(id: 'cc', enabled: true, kind: 'data-pack'),
      ];
      await h.controller.ensureLoaded();
      final ExtensionsSummary summary = h.state.summary;
      expect(summary.installedCount, 3);
      expect(summary.enabledCount, 2);
      expect(summary.usableCount, 2, reason: 'data-pack 装得上但本版本不能用');
      expect(summary.bytes, 36);
      expect(h.state.enabledUsable.map((InstalledExtension e) => e.id), <String>['aa']);
    });
  });
}
