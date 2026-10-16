/// 引擎进度流「自愈」单测（用户 2026-10-12 第 9 轮：「下载100%了还是不完成」）。
///
/// 覆盖的是 `state/engine_bootstrap.dart` 里的 [resilientEngineStream] 与
/// [EngineRuntimeHolder.onAttach] 这对组合：
/// * 队列订阅进度流时**边车还没起**（`main.dart` 先 `await hostData.init()`，
///   之后才 `engineBootstrapProvider.start()`），旧实现拿到一个 `Stream.error`
///   就永远不再重建 —— 引擎之后发多少「已完成」事件都收不到；
/// * 所以这里逐条钉住"等待 / 接上 / 换运行期 / 内层崩了还能再接上"。
///
/// **不联网、不起边车**：泛型参数只为可测，`open` 用假的 `StreamController`。
library;

import 'dart:async';

import 'package:dsanima/state/engine_bootstrap.dart';
import 'package:flutter_test/flutter_test.dart';

/// 假运行期（真实代码里这里是 `core.EngineClient`）。
class _FakeClient {
  _FakeClient(this.name);

  final String name;
}

void main() {
  group('resilientEngineStream', () {
    test('订阅时引擎还没就绪 → 不报错也不结束，就绪后自动接上', () async {
      _FakeClient? client;
      final signals = StreamController<void>.broadcast();
      final inner = <StreamController<String>>[];

      final out = resilientEngineStream<String, _FakeClient>(
        clientOf: () => client,
        reattachSignals: signals.stream,
        open: (c) {
          final controller = StreamController<String>();
          inner.add(controller);
          return controller.stream;
        },
      );

      final seen = <String>[];
      Object? error;
      bool done = false;
      final sub = out.listen(seen.add, onError: (Object e) => error = e,
          onDone: () => done = true);

      await pumpEventQueue();
      expect(inner, isEmpty, reason: '还没就绪时不该去开会话');
      expect(error, isNull, reason: '关键：不能像旧实现那样直接给 Stream.error');
      expect(done, isFalse, reason: '关键：流必须活着等边车起来');

      // 边车起来了：真实代码里 attach() 会发这条信号。
      client = _FakeClient('engine-1');
      signals.add(null);
      await pumpEventQueue();
      expect(inner, hasLength(1));

      inner.single.add('tick-1');
      await pumpEventQueue();
      expect(seen, <String>['tick-1']);

      // 还没就绪时来的信号不该白接一次：同一次订阅只开一条。
      signals.add(null);
      await pumpEventQueue();
      expect(inner, hasLength(1), reason: '同一个运行期不该重复接');

      await sub.cancel();
      await signals.close();
    });

    test('订阅时已经就绪 → 立刻接上，不用等信号', () async {
      final client = _FakeClient('engine-1');
      final signals = StreamController<void>.broadcast();
      final inner = <StreamController<String>>[];

      final out = resilientEngineStream<String, _FakeClient>(
        clientOf: () => client,
        reattachSignals: signals.stream,
        open: (c) {
          final controller = StreamController<String>();
          inner.add(controller);
          return controller.stream;
        },
      );
      final seen = <String>[];
      final sub = out.listen(seen.add);
      await pumpEventQueue();

      expect(inner, hasLength(1));
      inner.single.add('tick-now');
      await pumpEventQueue();
      expect(seen, <String>['tick-now']);

      await sub.cancel();
      await signals.close();
    });

    test('换运行期（设置页重启边车）→ 取消旧订阅、接新的', () async {
      _FakeClient? client = _FakeClient('engine-1');
      final signals = StreamController<void>.broadcast();
      final inner = <StreamController<String>>[];
      var cancelled = 0;

      final out = resilientEngineStream<String, _FakeClient>(
        clientOf: () => client,
        reattachSignals: signals.stream,
        open: (c) {
          final controller = StreamController<String>(onCancel: () => cancelled++);
          inner.add(controller);
          return controller.stream;
        },
      );
      final seen = <String>[];
      final sub = out.listen(seen.add);
      await pumpEventQueue();
      expect(inner, hasLength(1));

      // 换了运行期（旧边车被杀、新边车接管）
      client = _FakeClient('engine-2');
      signals.add(null);
      await pumpEventQueue();
      expect(inner, hasLength(2));
      expect(cancelled, 1, reason: '旧订阅要被取消，不能两条同时灌事件');

      inner[1].add('tick-new');
      await pumpEventQueue();
      expect(seen, <String>['tick-new']);

      await sub.cancel();
      await signals.close();
    });

    test('内层流报错（边车被杀）→ 外层继续活着，下次接上还能收', () async {
      _FakeClient? client = _FakeClient('engine-1');
      final signals = StreamController<void>.broadcast();
      final inner = <StreamController<String>>[];

      final out = resilientEngineStream<String, _FakeClient>(
        clientOf: () => client,
        reattachSignals: signals.stream,
        open: (c) {
          final controller = StreamController<String>();
          inner.add(controller);
          return controller.stream;
        },
      );
      final seen = <String>[];
      Object? error;
      bool done = false;
      final sub = out.listen(seen.add, onError: (Object e) => error = e,
          onDone: () => done = true);
      await pumpEventQueue();

      inner.single.addError(StateError('SSE 断了'));
      await pumpEventQueue();
      expect(error, isNull, reason: '内层的错不该把外层打死');
      expect(done, isFalse);

      // 新运行期接上后照常收事件
      client = _FakeClient('engine-2');
      signals.add(null);
      await pumpEventQueue();
      expect(inner, hasLength(2));
      inner[1].add('tick-after-restart');
      await pumpEventQueue();
      expect(seen, <String>['tick-after-restart']);

      await sub.cancel();
      await signals.close();
    });

    test('取消订阅会连带取消内层与信号订阅（不泄漏）', () async {
      _FakeClient? client = _FakeClient('engine-1');
      final signals = StreamController<void>.broadcast();
      var cancelled = 0;
      var signalSubs = 0;

      final out = resilientEngineStream<String, _FakeClient>(
        clientOf: () => client,
        reattachSignals: signals.stream,
        open: (c) => StreamController<String>(onCancel: () => cancelled++).stream,
      );
      signals.onListen = () => signalSubs++;
      final sub = out.listen((_) {});
      await pumpEventQueue();
      expect(signalSubs, 1);

      await sub.cancel();
      await pumpEventQueue();
      expect(cancelled, 1);
      await signals.close();
    });
  });

  group('EngineRuntimeHolder.onAttach', () {
    test('建好就有这条流；dispose 前一直可监听（不抛）', () async {
      final holder = EngineRuntimeHolder();
      expect(holder.isAttached, isFalse);
      final sub = holder.onAttach.listen((_) {});
      expect(holder.client, isNull);
      await sub.cancel();
    });

    test('真身：边车未就绪时订阅队列进度流 → 不报错、不结束（旧实现直接给错误流）', () async {
      // 这条是**回归钉**：把 `QueueEngineBridge.progress()` 改回
      // `CoreEnginePort(_holder).watch()` 的旧写法，这里就会收到
      // PortUnavailableException 且订阅结束 —— 那正是「下载100%了还是不完成」的根因
      //（引擎之后发多少「已完成」事件队列都收不到）。实测过：旧写法下 errors 非空。
      final holder = EngineRuntimeHolder();
      final bridge = QueueEngineBridge(holder);
      final errors = <Object>[];
      bool done = false;
      final sub = bridge.progress().listen(
        (_) {},
        onError: errors.add,
        onDone: () => done = true,
      );
      await pumpEventQueue();
      expect(errors, isEmpty);
      expect(done, isFalse, reason: '必须活着等边车起来，而不是当场结束');
      await sub.cancel();
    });
  });
}
