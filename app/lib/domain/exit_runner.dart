/// 退出收尾的**有界**执行器
/// （用户 2026-10-12 第 10 轮：「修复关闭程序时会卡一会儿才关掉」）。
///
/// ## 卡在哪儿（真机证据）
/// `DSAnima-data/engine/engine.log` 里每次退出都是同一套：
/// `POST /shutdown` → `stdin closed` → 800ms drain → `http server stopped` →
/// **会话落盘** → `bye`，从请求到 `bye` 稳定 **1.81~1.83s**（6 次退出，6 次都一样）。
/// 而 `CloseCoordinator._exit()` 是**在窗口还开着的时候**一路 `await` 这条收尾链，
/// 最后才 `exit(0)` —— 那 1.8s 就是用户看到的"卡一会儿才关掉"。
///
/// ## 两条规矩
/// 1. **窗口先消失**：`CloseCoordinator` 第一步就 `windowManager.hide()`，用户看到的是
///    秒关；落盘/停边车在窗口已经没了之后继续做（进程还活着，但用户看不见它）。
/// 2. **每一步都有预算**：某一步卡住（引擎不吐 `bye`、原生插件不应答、磁盘慢）就
///    放弃等它，继续下一步；最后还有 [ExitRunner.hardDeadline] 这个总闸 ——
///    **绝不允许出现"关不掉的进程"**。
///
/// 这个文件刻意不 import 任何 io/Flutter：整条退出路径用注入的回调跑，
/// 于是"顺序对不对""一步卡住会不会拖死全局"都能在单测里钉死
/// （见 `app/test/exit_runner_test.dart`）。
library;

import 'dart:async';

/// 一步收尾动作。
class ExitStep {
  const ExitStep(
    this.name,
    this.run, {
    this.budget = const Duration(seconds: 2),
  });

  /// 日志/报告里的名字（写清楚这一步在干什么）。
  final String name;

  /// 有预算上限的动作。
  final Future<void> Function() run;

  /// 允许这一步花多久；超了就放弃（记录 timeout）继续下一步。
  final Duration budget;
}

/// 一步的结局。
enum ExitStepOutcome {
  /// 在预算内正常做完。
  done,

  /// 超预算，被放弃（后面的事照做）。
  timeout,

  /// 抛异常（不阻塞退出，但要留痕）。
  failed,
}

/// 一步的执行报告。
class ExitStepReport {
  const ExitStepReport({
    required this.name,
    required this.took,
    required this.outcome,
    this.error,
  });

  final String name;
  final Duration took;
  final ExitStepOutcome outcome;
  final Object? error;

  @override
  String toString() {
    final String mark = switch (outcome) {
      ExitStepOutcome.done => 'ok',
      ExitStepOutcome.timeout => '超时放弃',
      ExitStepOutcome.failed => '失败',
    };
    return '$name: $mark (${took.inMilliseconds}ms)';
  }
}

/// 整轮退出的报告。
class ExitReport {
  const ExitReport({
    required this.steps,
    required this.total,
    required this.hitDeadline,
  });

  final List<ExitStepReport> steps;
  final Duration total;

  /// 总闸被触发（有步骤在预算内都没回来，或步骤表本身太长）。
  final bool hitDeadline;

  /// 一行式摘要（进 diag 日志）。
  String describe() =>
      '共 ${total.inMilliseconds}ms${hitDeadline ? '（触发总闸）' : ''}'
      '｜${steps.map((ExitStepReport s) => s.toString()).join(' · ')}';
}

/// 退出收尾执行器。
///
/// [exitProcess] 是**注入**的（生产传 `dart:io` 的 `exit`，测试传一个记录器）：
/// 否则这条路径根本没法测。
class ExitRunner {
  ExitRunner({
    required this.exitProcess,
    required this.log,
    this.hardDeadline = const Duration(seconds: 16),
  });

  /// 真正结束进程（生产 = `exit(0)`）。
  final void Function(int code) exitProcess;

  /// 日志（生产 = `shikiin.diag.info('exit', …)`；测试 = 收集器）。
  final void Function(String message) log;

  /// 总闸：整轮收尾最多花这么久，超过就强退（每一步自己的预算仍在起作用）。
  ///
  /// 默认值比"各步预算之和"再宽一点，这样正常路径永远走不到它 ——
  /// 它是"关不掉的进程"这个最坏情况的兜底，不是常规路径。
  final Duration hardDeadline;

  /// 依序跑 [steps]（顺序就是参数顺序），然后结束进程。返回报告。
  ///
  /// 无论中途发生什么（超时/异常/总闸），[exitProcess] **一定**会被调用，
  /// 且只调用一次 —— 这是"绝不允许关不掉"的落点。
  Future<ExitReport> run(List<ExitStep> steps) async {
    final Stopwatch total = Stopwatch()..start();
    final List<ExitStepReport> reports = <ExitStepReport>[];
    var hitDeadline = false;

    Future<void> each() async {
      for (final ExitStep step in steps) {
        final Stopwatch watch = Stopwatch()..start();
        ExitStepOutcome outcome = ExitStepOutcome.done;
        Object? error;
        try {
          await step.run().timeout(step.budget);
        } on TimeoutException {
          outcome = ExitStepOutcome.timeout;
        } catch (e) {
          outcome = ExitStepOutcome.failed;
          error = e;
        }
        final ExitStepReport report = ExitStepReport(
          name: step.name,
          took: watch.elapsed,
          outcome: outcome,
          error: error,
        );
        reports.add(report);
        log('退出｜$report');
      }
    }

    try {
      await each().timeout(hardDeadline);
    } on TimeoutException {
      hitDeadline = true;
      log('退出｜总闸 ${hardDeadline.inMilliseconds}ms 到点，强退（还有步骤没回来）');
    }

    final ExitReport report = ExitReport(
      steps: List<ExitStepReport>.unmodifiable(reports),
      total: total.elapsed,
      hitDeadline: hitDeadline,
    );
    log('退出｜${report.describe()}');
    exitProcess(0);
    return report;
  }
}

/// 退出收尾的**步骤表**（顺序 = 执行顺序）。
///
/// 为什么单独抽出来：这套顺序里有两条是"血的教训"，必须被测试钉住 ——
/// * **先放 Hive 锁再停边车**：窗口秒关之后进程还会活一两秒（等边车优雅退出），
///   锁不提前放，用户这两秒里双击重开会撞 `<box>.lock`；
/// * **先摘宿主数据层再关 box**：队列/源客户端还在写的时候关掉 box，会写出
///   `Box has already been closed` 这种假错误。
List<ExitStep> buildExitSteps({
  required Future<void> Function() saveResumePosition,
  required Future<void> Function() detachHostData,
  required Future<void> Function() closeStores,
  required Future<void> Function() stopEngine,
  required Future<void> Function() disposeDesktop,
}) =>
    <ExitStep>[
      ExitStep(
        '保存续播位置',
        saveResumePosition,
        budget: const Duration(seconds: 1),
      ),
      ExitStep(
        '宿主数据层收尾（队列订阅/源客户端/订阅流）',
        detachHostData,
        budget: const Duration(seconds: 2),
      ),
      ExitStep(
        '关闭 Hive（flush + 放掉 <box>.lock）',
        closeStores,
        budget: const Duration(seconds: 2),
      ),
      ExitStep(
        '停边车（优雅退出，实测 ~1.8s）',
        stopEngine,
        // 站内最坏路径：/shutdown 2s + 优雅等待 3s + sigterm 1s + sigkill 1s。
        // 给足它才不会留下没人管的 rqbit-engine.exe（下次启动虽然会接管，
        // 但"退出不落孤儿"是这个仓早就定下的规矩）。
        budget: const Duration(seconds: 8),
      ),
      ExitStep(
        '托盘 / 通知 / ProviderContainer',
        disposeDesktop,
        budget: const Duration(seconds: 1),
      ),
    ];
