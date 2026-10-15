/// 退出收尾的两条硬规矩（用户 2026-10-12 第 10 轮：
/// 「修复关闭程序时会卡一会儿才关掉」）：
///
/// 1. **顺序**：保存续播 → 摘宿主数据层 → 关 Hive（flush + 放锁）→ 停边车 →
///    托盘/容器。其中「先放锁、后停边车」是配套修复：窗口秒关之后进程还会活
///    一两秒（等边车优雅退出），锁不提前放，用户这两秒里双击重开会撞
///    `PathAccessException: lock failed`；
/// 2. **有界**：某一步卡住就放弃它继续下一步，外面还有总闸 ——
///    `exitProcess` 一定被调用、且只调用一次（绝不允许关不掉的进程）。
library;

import 'dart:async';

import 'package:dsanima/domain/exit_runner.dart';
import 'package:flutter_test/flutter_test.dart';

/// 一个永远不会自己完成的 future（配 tearDown 收尾，避免留下悬挂定时器）。
Completer<void> _pending(List<Completer<void>> pool) {
  final Completer<void> completer = Completer<void>();
  pool.add(completer);
  return completer;
}

List<ExitStep> _fiveSteps({
  required Future<void> Function() saveResumePosition,
  required Future<void> Function() detachHostData,
  required Future<void> Function() closeStores,
  required Future<void> Function() stopEngine,
  required Future<void> Function() disposeDesktop,
}) =>
    buildExitSteps(
      saveResumePosition: saveResumePosition,
      detachHostData: detachHostData,
      closeStores: closeStores,
      stopEngine: stopEngine,
      disposeDesktop: disposeDesktop,
    );

void main() {
  group('顺序', () {
    test('保存续播 → 摘宿主数据层 → 关 Hive → 停边车 → 托盘/容器', () async {
      final List<String> order = <String>[];
      final List<int> exits = <int>[];
      final List<String> logs = <String>[];
      Future<void> step(String name) async => order.add(name);

      final ExitReport report = await ExitRunner(
        exitProcess: exits.add,
        log: logs.add,
      ).run(
        _fiveSteps(
          saveResumePosition: () => step('续播'),
          detachHostData: () => step('宿主'),
          closeStores: () => step('Hive'),
          stopEngine: () => step('边车'),
          disposeDesktop: () => step('托盘'),
        ),
      );

      expect(order, <String>['续播', '宿主', 'Hive', '边车', '托盘']);
      expect(exits, <int>[0], reason: '无论中途怎样都要退出，且只退一次');
      expect(
        report.steps.map((ExitStepReport s) => s.outcome),
        everyElement(ExitStepOutcome.done),
      );
      expect(report.hitDeadline, isFalse);
      // 每一步都留痕（用户报"关不掉/关得慢"时，diag 日志里要有证据链）。
      expect(logs.where((String l) => l.contains('关闭 Hive')), isNotEmpty);
      expect(logs.last, contains('退出｜共'));
    });

    test('「关 Hive（放锁）」必须排在「停边车」之前', () {
      final List<ExitStep> steps = _fiveSteps(
        saveResumePosition: () async {},
        detachHostData: () async {},
        closeStores: () async {},
        stopEngine: () async {},
        disposeDesktop: () async {},
      );
      final List<String> names =
          steps.map((ExitStep s) => s.name).toList(growable: false);
      final int stores = names.indexWhere((String n) => n.contains('关闭 Hive'));
      final int engine = names.indexWhere((String n) => n.contains('停边车'));
      expect(stores, greaterThanOrEqualTo(0));
      expect(engine, greaterThan(stores),
          reason: '秒关之后进程还要活一两秒等边车退出，锁不提前放，'
              '用户这时双击重开就会撞 <box>.lock');
      // 顺序里也得先摘宿主数据层：队列/源客户端还在写的时候关 box 会写出假错误。
      final int host =
          names.indexWhere((String n) => n.contains('宿主数据层'));
      expect(host, greaterThanOrEqualTo(0));
      expect(host, lessThan(stores));
    });

    test('停边车那一步的预算够它走完优雅退出（不然会落下没人管的边车进程）', () {
      final List<ExitStep> steps = _fiveSteps(
        saveResumePosition: () async {},
        detachHostData: () async {},
        closeStores: () async {},
        stopEngine: () async {},
        disposeDesktop: () async {},
      );
      final ExitStep engine = steps.firstWhere(
        (ExitStep s) => s.name.contains('停边车'),
      );
      // 真机日志里 `/shutdown` → `bye` 是 1.8s；内部最坏路径是
      // 2s(shutdown) + 3s(优雅等待) + 1s(sigterm) + 1s(sigkill) = 7s。
      expect(engine.budget, greaterThanOrEqualTo(const Duration(seconds: 7)));
    });
  });

  group('有界：绝不允许关不掉', () {
    test('某一步卡住：超预算被放弃，后面的步骤照做，进程照样退出', () async {
      final List<Completer<void>> pool = <Completer<void>>[];
      addTearDown(() {
        for (final Completer<void> c in pool) {
          if (!c.isCompleted) c.complete();
        }
      });
      final List<String> order = <String>[];
      final List<int> exits = <int>[];

      final ExitReport report = await ExitRunner(
        exitProcess: exits.add,
        log: (String _) {},
      ).run(<ExitStep>[
        ExitStep(
          '卡住的一步',
          () => _pending(pool).future,
          budget: const Duration(milliseconds: 40),
        ),
        ExitStep('后面的一步', () async => order.add('后面')),
      ]);

      expect(report.steps.first.outcome, ExitStepOutcome.timeout);
      expect(order, <String>['后面'], reason: '一步卡住不许拖死整条退出路径');
      expect(exits, <int>[0]);
    });

    test('某一步抛异常：记 failed，不阻塞后面的步骤', () async {
      final List<int> exits = <int>[];
      final List<String> order = <String>[];

      final ExitReport report = await ExitRunner(
        exitProcess: exits.add,
        log: (String _) {},
      ).run(<ExitStep>[
        ExitStep('炸的一步', () async => throw StateError('boom')),
        ExitStep('后面的一步', () async => order.add('后面')),
      ]);

      expect(report.steps.first.outcome, ExitStepOutcome.failed);
      expect(report.steps.first.error, isA<StateError>());
      expect(order, <String>['后面']);
      expect(exits, <int>[0]);
    });

    test('总闸：步骤表再长也会强退（这是"关不掉的进程"最坏情况的兜底）', () async {
      final List<Completer<void>> pool = <Completer<void>>[];
      addTearDown(() {
        for (final Completer<void> c in pool) {
          if (!c.isCompleted) c.complete();
        }
      });
      final List<int> exits = <int>[];

      final ExitReport report = await ExitRunner(
        exitProcess: exits.add,
        log: (String _) {},
        hardDeadline: const Duration(milliseconds: 60),
      ).run(<ExitStep>[
        ExitStep('很慢 1', () => _pending(pool).future,
            budget: const Duration(seconds: 5)),
        ExitStep('很慢 2', () => _pending(pool).future,
            budget: const Duration(seconds: 5)),
      ]);

      expect(report.hitDeadline, isTrue);
      expect(exits, <int>[0]);
    });

    test('报告里带上每一步的名字与结局（诊断包/日志里能看出卡在哪一步）', () async {
      final List<String> logs = <String>[];
      final ExitReport report = await ExitRunner(
        exitProcess: (int _) {},
        log: logs.add,
      ).run(
        _fiveSteps(
          saveResumePosition: () async {},
          detachHostData: () async => throw StateError('队列收尾炸了'),
          closeStores: () async {},
          stopEngine: () async {},
          disposeDesktop: () async {},
        ),
      );

      expect(report.steps, hasLength(5));
      expect(report.steps[1].outcome, ExitStepOutcome.failed);
      expect(report.steps[1].name, contains('宿主数据层'));
      expect(
        report.steps.every((ExitStepReport s) => s.took >= Duration.zero),
        isTrue,
      );
      expect(logs.where((String l) => l.contains('失败')), isNotEmpty);
    });
  });
}
