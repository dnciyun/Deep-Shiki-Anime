/// 桌面集成：真托盘（`tray_manager`）+ 真系统通知（`local_notifier`）。
///
/// 规范：spec §7.3 Q14（托盘、唤回窗口、关闭询问）、Q16（新集命中 → 通知 → 点击跳转播放）。
///
/// **为什么多一层后端抽象**：`tray_manager` / `local_notifier` 都是原生插件，
/// widget/单测里真起托盘会污染开发机（而且平台通道在测试里根本不通）。
/// 端口实现只依赖 [TrayBackend] / [NotifierBackend]，测试注入假后端 ——
/// 既验证了「菜单项、命令映射、通知点击回传 payload」这些真逻辑，
/// 又不在测试里碰原生插件。
///
/// 两个实测坑：
/// * Windows 的 `tray_manager` 用 `LoadImage(..., IMAGE_ICON, LR_LOADFROMFILE)` 读图标，
///   **必须是真 .ico**：把 PNG 改名成 .ico 会加载失败（托盘空窗/无图标）；
/// * `local_notifier` **首个通知前必须 `setup(appName:)`**：不 setup 会静默不弹。
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:local_notifier/local_notifier.dart';
import 'package:path/path.dart' as p;
import 'package:tray_manager/tray_manager.dart' as tray;

import '../domain/models.dart';
import '../domain/ports.dart';

// ─────────────────────────────────────────────────────────────────────────────
// 后端抽象（可注入 → 可测）
// ─────────────────────────────────────────────────────────────────────────────

/// 托盘左键单击（唤回窗口）用的菜单项 key。
const String trayKeyRestore = 'restore';
const String trayKeyPauseAll = 'pauseAll';
const String trayKeyResumeAll = 'resumeAll';
const String trayKeyExit = 'exit';

/// 一个托盘菜单项（后端无关，避免把 `menu_base.MenuItem` 泄漏到端口层）。
class TrayMenuItemSpec {
  const TrayMenuItemSpec({
    required this.key,
    required this.label,
    this.separatorBefore = false,
  });

  final String key;
  final String label;
  final bool separatorBefore;
}

/// 托盘后端：`tray_manager` 的最小封装。
abstract interface class TrayBackend {
  Future<void> setIcon(String iconPath);

  Future<void> setToolTip(String tooltip);

  Future<void> setMenu(List<TrayMenuItemSpec> items);

  Future<void> destroy();

  /// 菜单项 key 流（左键单击回传 [trayKeyRestore]）。
  Stream<String> get clicks;
}

/// 系统通知后端：`local_notifier` 的最小封装。
abstract interface class NotifierBackend {
  /// **必须**在第一个通知前调用（否则静默不弹）。
  Future<void> setup({required String appName});

  Future<void> show({required String title, required String body, String? payload});

  /// 点击通知回传 payload。
  Stream<String> get clicks;
}

// ─────────────────────────────────────────────────────────────────────────────
// 真实现
// ─────────────────────────────────────────────────────────────────────────────

/// `tray_manager` 实现（Windows 上就是真托盘；**测试不要用这个**）。
class TrayManagerBackend with tray.TrayListener implements TrayBackend {
  TrayManagerBackend() {
    tray.TrayManager.instance.addListener(this);
  }

  final StreamController<String> _clicks = StreamController<String>.broadcast();

  @override
  Stream<String> get clicks => _clicks.stream;

  @override
  Future<void> setIcon(String iconPath) =>
      tray.TrayManager.instance.setIcon(iconPath);

  @override
  Future<void> setToolTip(String tooltip) =>
      tray.TrayManager.instance.setToolTip(tooltip);

  @override
  Future<void> setMenu(List<TrayMenuItemSpec> items) =>
      tray.TrayManager.instance.setContextMenu(tray.Menu(items: <tray.MenuItem>[
        for (final TrayMenuItemSpec item in items) ...<tray.MenuItem>[
          if (item.separatorBefore) tray.MenuItem.separator(),
          tray.MenuItem(key: item.key, label: item.label),
        ],
      ]));

  @override
  Future<void> destroy() async {
    tray.TrayManager.instance.removeListener(this);
    await tray.TrayManager.instance.destroy();
    await _clicks.close();
  }

  @override
  void onTrayIconMouseDown() {
    if (!_clicks.isClosed) _clicks.add(trayKeyRestore);
  }

  @override
  void onTrayIconRightMouseDown() {
    // 右键弹菜单（Windows 上必须显式弹）。
    unawaited(tray.TrayManager.instance.popUpContextMenu());
  }

  @override
  void onTrayMenuItemClick(tray.MenuItem menuItem) {
    final String? key = menuItem.key;
    if (key != null && key.isNotEmpty && !_clicks.isClosed) _clicks.add(key);
  }
}

/// `local_notifier` 实现。
class LocalNotifierBackend implements NotifierBackend, LocalNotificationListener {
  final StreamController<String> _clicks = StreamController<String>.broadcast();
  bool _ready = false;

  /// 是否已经成功 `setup`（**没 setup 就通知 = 静默丢失**）。
  bool get isReady => _ready;

  @override
  Stream<String> get clicks => _clicks.stream;

  @override
  Future<void> setup({required String appName}) async {
    if (_ready) return;
    await localNotifier.setup(appName: appName);
    localNotifier.addListener(this);
    _ready = true;
  }

  @override
  Future<void> show({
    required String title,
    required String body,
    String? payload,
  }) async {
    if (!_ready) return; // 没 setup 就发 = 静默不弹，直接不发（调用方会看到 false）
    final LocalNotification notification = LocalNotification(
      // identifier 用来把「点击」关联回队列任务（宿主用 `job:<id>`）。
      identifier: (payload ?? '').isEmpty ? null : payload,
      title: title,
      body: body,
    );
    await notification.show();
  }

  @override
  void onLocalNotificationClick(LocalNotification notification) {
    final String payload = notification.identifier;
    if (payload.isNotEmpty && !_clicks.isClosed) _clicks.add(payload);
  }

  // 其余三个回调宿主用不到，但监听器接口要求实现。
  @override
  void onLocalNotificationShow(LocalNotification notification) {}

  @override
  void onLocalNotificationClose(
      LocalNotification notification, LocalNotificationCloseReason reason) {}

  @override
  void onLocalNotificationClickAction(LocalNotification notification, int actionIndex) {}

  Future<void> dispose() async {
    localNotifier.removeListener(this);
    await _clicks.close();
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 端口实现
// ─────────────────────────────────────────────────────────────────────────────

/// 真托盘端口：图标 + tooltip + 右键菜单（显示主窗口 / 暂停全部 / 继续全部 / 退出）。
class TrayManagerPort implements TrayPort {
  TrayManagerPort({
    required this.backend,
    required this.iconPath,
  });

  final TrayBackend backend;

  /// **真 .ico** 的绝对路径（见库注释：Windows 必须 .ico）。
  final String iconPath;

  final StreamController<TrayCommand> _commands =
      StreamController<TrayCommand>.broadcast();
  StreamSubscription<String>? _sub;
  bool _available = false;

  @override
  bool get isAvailable => _available;

  @override
  Stream<TrayCommand> get commands => _commands.stream;

  @override
  Future<void> show({required String tooltip}) async {
    try {
      await backend.setIcon(iconPath);
      await backend.setToolTip(tooltip);
      await backend.setMenu(const <TrayMenuItemSpec>[
        TrayMenuItemSpec(key: trayKeyRestore, label: '显示主窗口'),
        TrayMenuItemSpec(
            key: trayKeyPauseAll, label: '暂停全部', separatorBefore: true),
        TrayMenuItemSpec(key: trayKeyResumeAll, label: '继续全部'),
        TrayMenuItemSpec(key: trayKeyExit, label: '退出', separatorBefore: true),
      ]);
      _sub ??= backend.clicks.listen(_onKey);
      _available = true;
    } catch (_) {
      // 没有托盘（Linux 无 StatusNotifier / 权限受限）：保持 isAvailable=false，
      // 关窗流程会退回「只最小化」，绝不把窗口藏丢。
      _available = false;
    }
  }

  @override
  Future<void> hide() async {
    // 托盘本体不需要 hide：窗口才是被隐藏的那个。
  }

  void _onKey(String key) {
    final TrayCommand? command = switch (key) {
      trayKeyRestore => TrayCommand.restore,
      trayKeyPauseAll => TrayCommand.pauseAll,
      trayKeyResumeAll => TrayCommand.resumeAll,
      trayKeyExit => TrayCommand.exitApp,
      _ => null,
    };
    if (command != null && !_commands.isClosed) _commands.add(command);
  }

  @override
  Future<void> dispose() async {
    await _sub?.cancel();
    _sub = null;
    try {
      await backend.destroy();
    } catch (_) {
      // 收尾失败不阻塞退出。
    }
    if (!_commands.isClosed) await _commands.close();
    _available = false;
  }
}

/// 真系统通知端口。
class LocalNotifierPort implements NotificationPort {
  LocalNotifierPort(this.backend);

  final NotifierBackend backend;
  StreamSubscription<String>? _sub;
  final StreamController<String> _clicks = StreamController<String>.broadcast();

  /// setup 是否成功（**没 setup 就 notify = 静默丢失**，所以直接拒发并返回 false）。
  bool _ready = false;

  /// 启动时调用一次：**第一个通知前必须 setup**（否则静默不弹）。
  Future<void> initialize({String appName = 'DSAnima'}) async {
    try {
      await backend.setup(appName: appName);
      _ready = true;
    } catch (_) {
      _ready = false;
      return;
    }
    _sub ??= backend.clicks.listen((String payload) {
      if (!_clicks.isClosed) _clicks.add(payload);
    });
  }

  @override
  bool get isAvailable => _ready;

  @override
  Stream<String> get clicks => _clicks.stream;

  @override
  Future<bool> notify({
    required String title,
    required String body,
    String? payload,
  }) async {
    if (!isAvailable) return false;
    try {
      await backend.show(title: title, body: body, payload: payload);
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> dispose() async {
    await _sub?.cancel();
    _sub = null;
    if (backend is LocalNotifierBackend) {
      await (backend as LocalNotifierBackend).dispose();
    }
    if (!_clicks.isClosed) await _clicks.close();
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 托盘图标：把打包进来的 .ico 落到磁盘（Windows 只认真 .ico 文件路径）
// ─────────────────────────────────────────────────────────────────────────────

/// 托盘图标资源（真 ICO；与 `windows/runner/resources/app_icon.ico` 同一份）。
const String trayIconAsset = 'assets/tray.ico';

/// 把 `.ico` 资源写到 [supportDir]，返回可交给 `tray_manager` 的绝对路径。
///
/// 为什么不用 asset 路径直接给插件：`tray_manager` 在 Windows 上是
/// `LoadImage(..., LR_LOADFROMFILE)`，要的是**文件系统路径**；
/// 打包后 asset 在 flutter_assets 里，直接给会加载不到。
Future<String?> materializeTrayIcon(String supportDir) async {
  try {
    final Directory dir = Directory(p.join(supportDir, 'dsanima'));
    await dir.create(recursive: true);
    final File out = File(p.join(dir.path, 'tray.ico'));
    final ByteData data = await rootBundle.load(trayIconAsset);
    await out.writeAsBytes(data.buffer.asUint8List(), flush: true);
    return out.path;
  } catch (_) {
    return null;
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 托盘菜单动作（可单测：只依赖 EnginePort 抽象）
// ─────────────────────────────────────────────────────────────────────────────

/// 「暂停全部」：把引擎里所有 torrent 逐个 pause；返回成功条数。
///
/// 单个失败不中断（某个 torrent 可能刚被删掉）——用户点「暂停全部」时
/// 剩下的一起生效才是他想要的。
Future<int> pauseAllTorrents(EnginePort engine) async {
  final List<EngineTorrentView> torrents = await engine.list();
  int ok = 0;
  for (final EngineTorrentView t in torrents) {
    try {
      await engine.pause(t.id);
      ok++;
    } catch (_) {
      // 忽略单个失败。
    }
  }
  return ok;
}

/// 「继续全部」。
Future<int> resumeAllTorrents(EnginePort engine) async {
  final List<EngineTorrentView> torrents = await engine.list();
  int ok = 0;
  for (final EngineTorrentView t in torrents) {
    try {
      await engine.resume(t.id);
      ok++;
    } catch (_) {
      // 忽略单个失败。
    }
  }
  return ok;
}
