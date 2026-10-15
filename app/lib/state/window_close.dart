/// 关窗流程（spec §7.3 Q14）：后台常驻开启时弹「是否后台继续下载？」；
/// 托盘可用时隐藏窗口 + 托盘唤回；托盘不可用时只最小化（**绝不**把窗口藏到
/// 用户找不回来的地方）。
///
/// 退出（[_exit]）的顺序与预算见 `domain/exit_runner.dart`：**窗口先消失**，
/// 有界收尾在后台跑完再 `exit(0)`（用户 2026-10-12 第 10 轮：
/// 「修复关闭程序时会卡一会儿才关掉」）。
///
/// 只有 `main.dart`（装配根）import 本文件：它需要 shikiin 的 `AppRuntime`
/// 保存续播位置。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shikiin/shikiin.dart' as shikiin;
import 'package:window_manager/window_manager.dart';

import '../app.dart' show dsNavigatorKey;
import '../domain/error_text.dart';
import '../domain/exit_runner.dart';
import '../domain/models.dart';
import '../domain/ports.dart';
import '../theme/tokens.dart';
import 'desktop_integration.dart'
    show LocalNotifierPort, pauseAllTorrents, resumeAllTorrents;
import 'engine_bootstrap.dart' show EngineRuntimeHolder;
import 'hive_store.dart' show HiveKeyValueStore;
import 'host_data.dart' show HostDataHolder;
import 'providers.dart';

enum CloseChoice { background, exitApp, cancel }

/// 关窗协调器：阻止默认关闭，改走「询问 → 后台 / 退出」。
class CloseCoordinator with WindowListener {
  CloseCoordinator({
    required this.runtime,
    required this.container,
    required this.engineHolder,
    required this.hostData,
    required this.appStore,
  });

  final shikiin.AppRuntime runtime;
  final ProviderContainer container;
  final EngineRuntimeHolder engineHolder;

  /// 宿主数据层（退出时一起收尾：队列落盘 + 源客户端关闭）。
  final HostDataHolder hostData;

  /// 宿主的 Hive box（`<数据根>/store/dsanima.lock`）：退出时关掉它 = flush + 放锁。
  final HiveKeyValueStore appStore;

  bool _closing = false;

  @override
  void onWindowClose() {
    unawaited(_handle());
  }

  /// 「立刻退出并收尾」——给检查更新那条路用（第三十九轮）。
  ///
  /// 覆盖更新是**另一个进程**干的活，它正等着本进程消失；而退出必须按
  /// [buildExitSteps] 那套顺序走（先放 Hive 锁 → 再停边车 → `exit(0)`），
  /// 否则新版本启动时会撞上没放掉的 `<box>.lock`。
  ///
  /// 与关窗那条路的唯一区别：**不弹「后台常驻」那个询问** —— 更新时窗口必须真的消失。
  Future<void> quit() => _exit();

  Future<void> _handle() async {
    if (_closing) return;
    _closing = true;
    try {
      final BuildContext? context = dsNavigatorKey.currentContext;
      // 第十六轮（设置页改成手动保存）：有未保存的改动时先问一句。
      // 用户选「留在这」就**什么都不做** —— 窗口不关、也不进后台。
      final bool mayClose = await resolveUnsavedSettings(
        container.read(settingsDraftGuardProvider),
        context,
      );
      if (!mayClose) return;
      final AppSettings settings = container.read(settingsProvider);
      final TrayPort tray = container.read(trayPortProvider);
      if (!settings.backgroundResident) {
        await _exit();
        return;
      }
      CloseChoice choice = CloseChoice.cancel;
      if (context != null && context.mounted) {
        choice = await showDialog<CloseChoice>(
              context: context,
              barrierDismissible: false,
              builder: (BuildContext context) => AlertDialog(
                title: const Text('关闭 DSAnima？'),
                content: Text(
                  tray.isAvailable
                      ? '「后台常驻」已开启：可以继续下载/做种，并从托盘图标唤回窗口。'
                      : '「后台常驻」已开启，但**托盘组件未接通**：\n'
                          '选择「后台继续」只会把窗口最小化（可从任务栏唤回），'
                          '不会隐藏到托盘。',
                  style: const TextStyle(
                      fontSize: DsTypeScale.body, height: 1.5),
                ),
                actions: <Widget>[
                  TextButton(
                    onPressed: () =>
                        Navigator.of(context).pop(CloseChoice.cancel),
                    child: const Text('取消'),
                  ),
                  OutlinedButton(
                    onPressed: () =>
                        Navigator.of(context).pop(CloseChoice.exitApp),
                    child: const Text('退出程序（停止下载）'),
                  ),
                  FilledButton(
                    onPressed: () =>
                        Navigator.of(context).pop(CloseChoice.background),
                    child: const Text('后台继续下载'),
                  ),
                ],
              ),
            ) ??
            CloseChoice.cancel;
      }
      switch (choice) {
        case CloseChoice.cancel:
          break;
        case CloseChoice.exitApp:
          await _exit();
        case CloseChoice.background:
          await runtime.saveResumePosition();
          // 托盘可用 → 隐藏到托盘；不可用 → **只最小化**（绝不把窗口藏丢）。
          // 真实现的 isAvailable 是「创建成功后才为 true」，所以要先把 show() 跑一遍。
          await tray.show(tooltip: 'DSAnima · 后台下载中');
          if (tray.isAvailable) {
            await windowManager.hide();
          } else {
            await windowManager.minimize();
          }
      }
    } finally {
      _closing = false;
    }
  }

  /// 退出程序：**先让窗口消失**，再有界收尾，最后 `exit(0)`。
  ///
  /// 为什么是这个顺序（用户 2026-10-12 第 10 轮：「关闭程序时会卡一会儿才关掉」）：
  /// 引擎的优雅退出（`POST /shutdown` → drain → 会话落盘 → `bye`）实测稳定要 ~1.8s
  ///（见 `DSAnima-data/engine/engine.log`），旧实现是**开着窗口**把这 1.8s 一路
  /// `await` 完才 `exit(0)` —— 用户看到的就是点 X 之后卡一下才关。
  /// 现在窗口在第一步就隐藏（任务栏按钮一起消失，对用户就是"关了"），
  /// 剩下的落盘/停边车在窗口已经没了之后继续走；每一步都有预算，外面还有总闸，
  /// 所以既不会卡、也不会出现关不掉的进程。
  Future<void> _exit() async {
    try {
      // 给窗口隐藏一个小上限：原生插件不应答也不能拖住整条退出路径。
      await windowManager.hide().timeout(const Duration(milliseconds: 500));
    } catch (_) {
      // 隐藏失败（无窗口/插件异常）不阻塞退出：下面照样收尾 + 强退。
    }
    await ExitRunner(
      exitProcess: exit,
      log: (String message) {
        try {
          shikiin.diag.info('exit', message);
        } catch (_) {
          // 诊断写不进去不该影响退出。
        }
      },
    ).run(
      buildExitSteps(
        saveResumePosition: () => runtime.saveResumePosition(),
        detachHostData: () => hostData.detach(),
        closeStores: _closeStores,
        stopEngine: () => engineHolder.detach(),
        disposeDesktop: _disposeDesktop,
      ),
    );
  }

  /// 放掉两个 Hive 占用锁（`shikiin.lock` / `dsanima.lock`）并把待写内容刷出去。
  ///
  /// 顺序上排在"宿主数据层收尾"之后、停边车之前：这时候已经没有写者（队列订阅已取消、
  /// 源客户端已关），关 box 不会写出 `Box has already been closed` 这种假错误；
  /// 而它又远早于边车那 ~1.8s，所以"关掉马上重开"撞不上锁。
  Future<void> _closeStores() async {
    await runtime.closeStore();
    await appStore.close();
  }

  /// 托盘 / 通知 / ProviderContainer（最后一步，纯宿主侧资源）。
  Future<void> _disposeDesktop() async {
    try {
      await container.read(trayPortProvider).dispose();
      final NotificationPort notifier = container.read(notificationPortProvider);
      if (notifier is LocalNotifierPort) await notifier.dispose();
    } catch (_) {
      // 托盘/通知收尾失败不阻塞退出。
    }
    container.dispose();
  }

  /// 托盘命令（唤回窗口 / 暂停全部 / 继续全部 / 从托盘退出）。
  ///
  /// 先尝试创建托盘（真实现的 [TrayPort.isAvailable] 只有创建成功后才为 true，
  /// 所以不能在 show() 之前就用它做判断——那样真托盘永远建不起来）；
  /// 创建失败（无托盘环境）就什么都不订阅，关窗流程会退回「只最小化」。
  Future<void> bindTray() async {
    final TrayPort tray = container.read(trayPortProvider);
    try {
      await tray.show(tooltip: 'DSAnima');
    } catch (_) {
      // 创建失败不阻塞启动。
    }
    if (!tray.isAvailable) return;
    tray.commands.listen((TrayCommand command) {
      switch (command) {
        case TrayCommand.restore:
          unawaited(windowManager.show());
          unawaited(windowManager.focus());
        case TrayCommand.pauseAll:
          unawaited(_toggleAll(pause: true));
        case TrayCommand.resumeAll:
          unawaited(_toggleAll(pause: false));
        case TrayCommand.exitApp:
          unawaited(_exit());
      }
    });
  }

  /// 托盘的「暂停全部 / 继续全部」：逐个动引擎里的 torrent（单个失败不中断）。
  ///
  /// 引擎没起时给出明确提示，不假装成功。
  Future<void> _toggleAll({required bool pause}) async {
    final EnginePort engine = container.read(enginePortProvider);
    try {
      final int ok = pause
          ? await pauseAllTorrents(engine)
          : await resumeAllTorrents(engine);
      _toast(pause ? '已暂停全部任务（$ok 个）' : '已继续全部任务（$ok 个）');
    } catch (error) {
      _toast('${pause ? '暂停' : '继续'}全部失败：'
          '${describeFailure(error).message}');
    }
  }

  void _toast(String text) {
    final BuildContext? context = dsNavigatorKey.currentContext;
    if (context == null || !context.mounted) return;
    ScaffoldMessenger.maybeOf(context)
        ?.showSnackBar(SnackBar(content: Text(text)));
  }
}
