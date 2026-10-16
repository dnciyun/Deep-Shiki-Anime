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
import '../ui/widgets/feedback.dart';
import 'desktop_integration.dart'
    show
        LocalNotifierPort,
        TrayToggleResult,
        pauseAllTorrents,
        queueSyncTargets,
        resumeAllTorrents;
import 'engine_bootstrap.dart' show EngineRuntimeHolder;
import 'hive_store.dart' show HiveKeyValueStore;
import 'host_data.dart' show HostDataHolder;
import 'playback.dart';
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
        case TrayCommand.showPlayer:
          unawaited(_showPlayerWindow());
        case TrayCommand.pauseAll:
          unawaited(_toggleAll(pause: true));
        case TrayCommand.resumeAll:
          unawaited(_toggleAll(pause: false));
        case TrayCommand.exitApp:
          unawaited(_exit());
      }
    });
  }

  /// 托盘的「显示播放器窗口」（第四十二轮 UX #48）。
  ///
  /// 走的就是主窗口侧栏那颗按钮的同一条路（`reopenPlayerWindow`：确保引擎在跑 →
  /// 重新取串流地址 → 让子窗口 show 出来）。**没有在播的内容时明说**，不静默 ——
  /// 托盘菜单是常驻的，用户点它的时候不一定正在看片。
  Future<void> _showPlayerWindow() async {
    final PlaybackUiState playback = container.read(playbackProvider);
    if (playback.nowPlaying == null) {
      await _report(
        '还没有在播的内容：先在「搜索」或「已完成」里点一集，之后这里可以直接唤回播放器',
        title: 'DSAnima · 没有在播的内容',
        warning: true,
      );
      return;
    }
    await container.read(playbackProvider.notifier).reopenPlayerWindow();
    final DsFailure? failure = container.read(playbackProvider).failure;
    if (failure != null) {
      await _report(
        '唤回播放窗口失败：${failure.message}',
        title: 'DSAnima · 唤回播放窗口失败',
        warning: true,
      );
    }
  }
  ///
  /// 引擎没起时给出明确提示，不假装成功。
  ///
  /// 第四十二轮 UX #8 两处修正：
  /// ① **部分失败不许说"已全部"** —— 回的是 `ok/total`，差几个就如实说几个；
  /// ② 反馈不再只走一扇可能被收起来的窗口：主窗口不可见时改发**系统通知**
  ///    （用户正在用托盘，正是主窗口被收起来的场景 —— 旧实现把提示画在一扇
  ///    看不见的窗口里，等于没说）。
  Future<void> _toggleAll({required bool pause}) async {
    final EnginePort engine = container.read(enginePortProvider);
    final String verb = pause ? '暂停' : '继续';
    try {
      final TrayToggleResult r =
          pause ? await pauseAllTorrents(engine) : await resumeAllTorrents(engine);
      // 引擎动完，**队列侧的状态也要跟上**（第四十二轮 UX #30）：旧实现只动引擎，
      // 于是用户进「队列」页看到每行还写着「下载中」，与引擎里的真实状态相反 ——
      // 两处说法不一致，用户不知道该信哪边。
      final int synced = await _syncQueueState(pause: pause, engineIds: r.okIds);
      if (r.ok == r.total) {
        await _report(
          '已$verb全部任务（引擎 ${r.ok} 个${synced > 0 ? '，队列同步 $synced 条' : ''}）',
        );
      } else {
        await _report(
          '已$verb ${r.ok}/${r.total} 个任务：${r.total - r.ok} 个没成功（它们可能已经不在引擎里）',
          title: 'DSAnima · 没全部$verb成功',
          warning: true,
        );
      }
    } catch (error) {
      await _report(
        '$verb全部失败：${describeFailure(error).message}',
        title: 'DSAnima · $verb全部失败',
        warning: true,
      );
    }
  }

  /// 把队列里**对应那几个引擎 torrent 的任务**状态同步过去。
  ///
  /// 只同步 `engineIds` 里真的动成功的那些（不然会出现"引擎没暂停成功、队列却说已暂停"）。
  /// 队列快照读不到（流还没发第一条）时什么都不做 —— 那时界面本来也还没显示任何行。
  /// 返回同步了几条。
  Future<int> _syncQueueState({
    required bool pause,
    required List<int> engineIds,
  }) async {
    if (engineIds.isEmpty) return 0;
    final List<QueueJobView>? jobs = container.read(queueJobsProvider).value;
    if (jobs == null) return 0;
    final QueuePort queue = container.read(queuePortProvider);
    // 该改哪几条由纯函数决定（可单测）；这里只负责逐条真的调用。
    final List<String> targets =
        queueSyncTargets(jobs: jobs, engineIds: engineIds, pause: pause);
    int synced = 0;
    for (final String jobId in targets) {
      try {
        if (pause) {
          await queue.pauseJob(jobId);
        } else {
          await queue.resumeJob(jobId);
        }
        synced++;
      } catch (_) {
        // 单条同步失败不影响其它条：这一条的状态与引擎不一致，但界面照旧可用
        // （用户点那一行的「继续」会自己纠正）。
      }
    }
    return synced;
  }

  /// 把一条托盘动作的结果送到用户眼前。
  ///
  /// 主窗口可见 → 页内提示（就近、不打扰）；被托盘收起来 → 系统通知
  /// （否则提示落在一扇看不见的窗口里）。通知发不出去（未 setup / 系统关了）
  /// 时仍然退回页内提示 —— 总比什么都不做强。
  Future<void> _report(String text, {String? title, bool warning = false}) async {
    if (await _mainWindowVisible()) {
      _toast(text, warning: warning);
      return;
    }
    final bool sent = await container
        .read(notificationPortProvider)
        .notify(title: title ?? 'DSAnima', body: text);
    if (!sent) _toast(text, warning: warning);
  }

  /// 主窗口现在看得见吗。问不出来时按"看得见"处理（用页内提示，不打扰）。
  Future<bool> _mainWindowVisible() async {
    try {
      return await windowManager.isVisible();
    } catch (_) {
      return true;
    }
  }

  /// 主窗口可见时的页内提示。
  ///
  /// 第四十二轮 UX #14：走全仓统一那套（凸起面 + 左侧语义色细条 + 图标），
  /// 不再自己拼裸 SnackBar —— 否则同样是"一句提示"，外观在不同入口长得不一样，
  /// 用户没法靠样式判断"这是成功还是警告"。
  void _toast(String text, {bool warning = false}) {
    final BuildContext? context = dsNavigatorKey.currentContext;
    if (context == null || !context.mounted) return;
    if (warning) {
      showWarning(context, text);
    } else {
      showSuccess(context, text, seconds: 4);
    }
  }
}
