/// 桌面集成测试（spec §7.3 Q14/Q16）：托盘菜单 → 命令映射、通知点击回传 payload、
/// 「暂停全部 / 继续全部」逐个动引擎。
///
/// **不真起托盘、不真弹通知**：`TrayBackend` / `NotifierBackend` 都用假实现，
/// 只验证端口层与映射逻辑（这才是会写错的地方）。
library;

import 'dart:async';
import 'dart:io';

import 'package:dsanima/domain/models.dart';
import 'package:dsanima/domain/ports.dart';
import 'package:dsanima/state/desktop_integration.dart';
import 'package:flutter_test/flutter_test.dart';

// ─────────────────────────────────────────────────────────────────────────────
// 假后端
// ─────────────────────────────────────────────────────────────────────────────

class FakeTrayBackend implements TrayBackend {
  final StreamController<String> _clicks = StreamController<String>.broadcast();
  final List<String> icons = <String>[];
  final List<String> tooltips = <String>[];
  List<TrayMenuItemSpec> menu = const <TrayMenuItemSpec>[];
  bool destroyed = false;
  Object? failOnIcon;

  @override
  Stream<String> get clicks => _clicks.stream;

  @override
  Future<void> setIcon(String iconPath) async {
    final Object? error = failOnIcon;
    if (error != null) throw error;
    icons.add(iconPath);
  }

  @override
  Future<void> setToolTip(String tooltip) async => tooltips.add(tooltip);

  @override
  Future<void> setMenu(List<TrayMenuItemSpec> items) async => menu = items;

  @override
  Future<void> destroy() async {
    destroyed = true;
    await _clicks.close();
  }

  void emit(String key) => _clicks.add(key);
}

class FakeNotifierBackend implements NotifierBackend {
  final StreamController<String> _clicks = StreamController<String>.broadcast();
  final List<String> setups = <String>[];
  final List<String> shown = <String>[];
  bool ready = false;

  @override
  Stream<String> get clicks => _clicks.stream;

  @override
  Future<void> setup({required String appName}) async {
    setups.add(appName);
    ready = true;
  }

  @override
  Future<void> show({
    required String title,
    required String body,
    String? payload,
  }) async {
    if (!ready) return; // 真实现同款语义：没 setup 就静默不弹
    shown.add('$title|$body|${payload ?? ''}');
  }

  void emitClick(String payload) => _clicks.add(payload);
}

/// 记录 pause/resume 的假引擎端口。
class FakeEnginePort implements EnginePort {
  FakeEnginePort(this.torrents);

  final List<EngineTorrentView> torrents;
  final List<String> calls = <String>[];
  int failOnId = -1;

  @override
  Future<EngineHealthView> health() async =>
      const EngineHealthView(ok: true, version: '0.1.0');

  @override
  Future<List<EngineTorrentView>> list() async => torrents;

  @override
  Future<void> pause(int id) async {
    if (id == failOnId) throw const PortUnavailableException('这个种子刚被删了');
    calls.add('pause:$id');
  }

  @override
  Future<void> resume(int id) async {
    if (id == failOnId) throw const PortUnavailableException('这个种子刚被删了');
    calls.add('resume:$id');
  }

  @override
  Future<EngineTorrentView> addMagnet(String magnet,
          {String? name,
          List<int>? onlyFiles,
          bool startPaused = false,
          String? subFolder}) async =>
      throw const PortUnavailableException('测试替身：不加种');

  @override
  Future<void> remove(int id, {bool deleteFiles = false}) async {}

  @override
  Stream<List<EngineTorrentView>> watch() =>
      Stream<List<EngineTorrentView>>.value(torrents);

  @override
  Uri? streamUrl(int id, int fileIndex) => null;
}

EngineTorrentView _torrent(int id, String name) => EngineTorrentView(
      id: id,
      name: name,
      state: TorrentState.live,
      files: const <EngineFileView>[],
    );

void main() {
  group('托盘端口（TrayManagerPort）', () {
    test('show() 设置图标/tooltip/右键菜单，并把菜单 key 映射成命令', () async {
      final FakeTrayBackend backend = FakeTrayBackend();
      final TrayManagerPort port =
          TrayManagerPort(backend: backend, iconPath: r'C:\tmp\tray.ico');

      expect(port.isAvailable, isFalse, reason: '创建成功前不可用（关窗要退回最小化）');
      await port.show(tooltip: 'DSAnima');
      expect(port.isAvailable, isTrue);
      expect(backend.icons.single, r'C:\tmp\tray.ico');
      expect(backend.tooltips.single, 'DSAnima');
      expect(backend.menu.map((TrayMenuItemSpec m) => m.key), <String>[
        trayKeyRestore,
        trayKeyPauseAll,
        trayKeyResumeAll,
        trayKeyExit,
      ]);
      expect(backend.menu.map((TrayMenuItemSpec m) => m.label), <String>[
        '显示主窗口',
        '暂停全部',
        '继续全部',
        '退出',
      ]);

      final List<TrayCommand> commands = <TrayCommand>[];
      port.commands.listen(commands.add);
      backend.emit(trayKeyRestore);
      backend.emit(trayKeyPauseAll);
      backend.emit(trayKeyResumeAll);
      backend.emit(trayKeyExit);
      backend.emit('unknown-key');
      await Future<void>.delayed(Duration.zero);
      expect(commands, <TrayCommand>[
        TrayCommand.restore,
        TrayCommand.pauseAll,
        TrayCommand.resumeAll,
        TrayCommand.exitApp,
      ]);
      await port.dispose();
      expect(backend.destroyed, isTrue);
    });

    test('托盘创建失败（无托盘环境）→ isAvailable 保持 false，不抛', () async {
      final FakeTrayBackend backend = FakeTrayBackend()
        ..failOnIcon = StateError('no tray here');
      final TrayManagerPort port =
          TrayManagerPort(backend: backend, iconPath: 'x.ico');
      await port.show(tooltip: 'DSAnima');
      expect(port.isAvailable, isFalse);
      expect(backend.menu, isEmpty);
    });
  });

  group('通知端口（LocalNotifierPort）', () {
    test('必须先 setup：没 setup 时 notify 返回 false（不假装弹过）', () async {
      final FakeNotifierBackend backend = FakeNotifierBackend();
      final LocalNotifierPort port = LocalNotifierPort(backend);
      expect(port.isAvailable, isFalse);
      expect(
          await port.notify(title: 't', body: 'b', payload: 'job:1'), isFalse);
      expect(backend.shown, isEmpty);

      await port.initialize(appName: 'DSAnima');
      expect(backend.setups, <String>['DSAnima']);
      expect(port.isAvailable, isTrue);
      expect(await port.notify(title: '葬送的芙莉莲 · 第 12 话', body: '订阅命中', payload: 'job:7'),
          isTrue);
      expect(backend.shown.single, '葬送的芙莉莲 · 第 12 话|订阅命中|job:7');
    });

    test('点击通知把 payload 原样回传（宿主用 `job:<id>` 定位任务）', () async {
      final FakeNotifierBackend backend = FakeNotifierBackend();
      final LocalNotifierPort port = LocalNotifierPort(backend);
      await port.initialize();
      final List<String> clicks = <String>[];
      port.clicks.listen(clicks.add);

      backend.emitClick('job:42');
      await Future<void>.delayed(Duration.zero);
      expect(clicks, <String>['job:42']);
      await port.dispose();
    });
  });

  group('托盘菜单动作：暂停全部 / 继续全部', () {
    test('逐个 pause/resume，单个失败不中断', () async {
      final FakeEnginePort engine = FakeEnginePort(<EngineTorrentView>[
        _torrent(1, 'A'),
        _torrent(2, 'B'),
        _torrent(3, 'C'),
      ]);
      expect(await pauseAllTorrents(engine), 3);
      expect(engine.calls, <String>['pause:1', 'pause:2', 'pause:3']);

      engine.calls.clear();
      engine.failOnId = 2;
      expect(await resumeAllTorrents(engine), 2,
          reason: '第 2 个失败（刚被删），剩下两个照常继续');
      expect(engine.calls, <String>['resume:1', 'resume:3']);
    });
  });

  group('托盘图标（Windows 必须真 .ico）', () {
    test('assets/tray.ico 是真 ICO（magic 00 00 01 00），不是改名的 PNG', () {
      final File icon = File('assets/tray.ico');
      expect(icon.existsSync(), isTrue);
      final List<int> head = icon.readAsBytesSync().sublist(0, 4);
      expect(head, <int>[0x00, 0x00, 0x01, 0x00],
          reason: 'tray_manager 在 Windows 上 LoadImage/LR_LOADFROMFILE，'
              'PNG 改名成 .ico 会加载失败（托盘空窗）');
    });
  });
}
