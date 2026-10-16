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

QueueJobView _job(String id, JobState state, {int? engineId}) => QueueJobView(
  id: id,
  item: SourceItemView(id: 'item-$id', sourceId: 'nyaa', title: '某番 - $id'),
  state: state,
  engineId: engineId,
  createdAt: DateTime(2026, 10, 15),
  updatedAt: DateTime(2026, 10, 15),
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
        trayKeyShowPlayer,
        trayKeyPauseAll,
        trayKeyResumeAll,
        trayKeyExit,
      ]);
      expect(backend.menu.map((TrayMenuItemSpec m) => m.label), <String>[
        '显示主窗口',
        // 第四十二轮 UX #48：收起的播放窗口以前只能"先唤主窗口 → 再点侧栏"。
        '显示播放器窗口',
        '暂停全部',
        '继续全部',
        '退出',
      ]);

      final List<TrayCommand> commands = <TrayCommand>[];
      port.commands.listen(commands.add);
      backend.emit(trayKeyRestore);
      backend.emit(trayKeyShowPlayer);
      backend.emit(trayKeyPauseAll);
      backend.emit(trayKeyResumeAll);
      backend.emit(trayKeyExit);
      backend.emit('unknown-key');
      await Future<void>.delayed(Duration.zero);
      expect(commands, <TrayCommand>[
        TrayCommand.restore,
        TrayCommand.showPlayer,
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
    test('逐个 pause/resume，单个失败不中断，并如实回报 ok/total/okIds', () async {
      final FakeEnginePort engine = FakeEnginePort(<EngineTorrentView>[
        _torrent(1, 'A'),
        _torrent(2, 'B'),
        _torrent(3, 'C'),
      ]);
      // 第四十二轮 UX #8/#30：回的是 `(ok, total, okIds)` —— 只有成功条数时，部分失败
      // 会被说成"已**全部**暂停"；`okIds` 则用来把**队列侧**的状态也只同步那几个。
      // （逐字段断言：record 的 `==` 对 List 字段是**引用**比较。）
      final TrayToggleResult paused = await pauseAllTorrents(engine);
      expect(paused.ok, 3);
      expect(paused.total, 3);
      expect(paused.okIds, <int>[1, 2, 3]);
      expect(engine.calls, <String>['pause:1', 'pause:2', 'pause:3']);

      engine.calls.clear();
      engine.failOnId = 2;
      final TrayToggleResult resumed = await resumeAllTorrents(engine);
      expect(resumed.ok, 2, reason: '第 2 个失败（刚被删），剩下两个照常继续');
      expect(resumed.total, 3, reason: '总数要带出来，提示才能说"没全部成功"');
      expect(resumed.okIds, <int>[1, 3], reason: 'okIds 里不许有失败那个');
      expect(engine.calls, <String>['resume:1', 'resume:3']);
    });

    test('队列侧要同步哪些任务：只认"引擎真的动成功"且"确实需要改"的那些（UX #30）', () {
      final List<QueueJobView> jobs = <QueueJobView>[
        _job('a', JobState.downloading, engineId: 1),
        _job('b', JobState.paused, engineId: 2),
        _job('c', JobState.downloading, engineId: 3), // 引擎那一步失败（不在 okIds 里）
        _job('d', JobState.completed, engineId: 4), // 已完成：不该被"暂停全部"搅动
        _job('e', JobState.queued), // 还没交给引擎
      ];

      expect(
        queueSyncTargets(jobs: jobs, engineIds: <int>[1, 2, 3, 4], pause: true),
        <String>['a', 'c'],
        reason: '暂停：只找 downloading，而且 engineIds 里必须真的有它',
      );
      expect(
        queueSyncTargets(jobs: jobs, engineIds: <int>[1, 2], pause: true),
        <String>['a'],
        reason: 'c 那个引擎 id 没在里面（引擎那一步没成功）⇒ 队列不许说它已暂停',
      );
      expect(
        queueSyncTargets(jobs: jobs, engineIds: <int>[1, 2, 3, 4], pause: false),
        <String>['b'],
        reason: '继续：只找 paused（downloading 的不用管）',
      );
      expect(
        queueSyncTargets(jobs: jobs, engineIds: const <int>[], pause: true),
        isEmpty,
        reason: '一个都没成功就什么都不改',
      );
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
