/// 「同时发生的同一件事只做一次」（1.1.0 M1/T3）。
///
/// 典型场景是 `latest()`：一次就是一次 RSS/HTML 抓取。同一个源上的这一页可能被
/// **好几个调用方同时**要 —— 「正在追」一屏 N 张卡一起挂载（每张卡读自己订阅的条目）、
/// 点开层的「命中预览」/「全季入队」、订阅的自动/手动刷新。
/// 并发 N 个请求 = N 次网络往返、N 份解析。
///
/// 这里只合并**同时在飞**的请求：第一个调用真的发出去，其余共享它的结果；
/// 一结束（成功**或失败**）立刻把它从表里摘掉。
///
/// ⚠️ 这**不是**缓存：不设 TTL、不保留结果。下一轮再要就是真的再去抓
/// （TTL 缓存是 core 源缓存 / `cache_sweep` 的事；在这里再造一层，用户点「刷新」会看起来没反应）。
/// 失败也必须摘掉：否则一次网络错误会把这个 key **永久**钉在失败的那个 Future 上，
/// 之后每次重试都秒失败。
library;

import 'dart:async';

class InFlightCoalescer<K, V> {
  final Map<K, Completer<V>> _inFlight = <K, Completer<V>>{};

  /// 当前在飞的请求数（测试用；也算一个可观测的健康指标）。
  int get inFlightCount => _inFlight.length;

  /// 用 [key] 合并并发调用：同一个 key 同时只跑一次 [start]。
  Future<V> run(K key, Future<V> Function() start) {
    final Completer<V>? running = _inFlight[key];
    if (running != null) return running.future;
    final Completer<V> completer = Completer<V>();
    _inFlight[key] = completer;
    unawaited(
      // `Future.sync`：`start()` 如果**同步**抛（比如参数校验失败），也要变成
      // 一个失败的 Future 走到这里，而不是把异常漏给第一个调用方、把表里的 completer 晾着。
      Future<V>.sync(start)
          .then(
            (V value) => completer.complete(value),
            onError: (Object error, StackTrace stack) => completer.completeError(error, stack),
          )
          .whenComplete(() {
            // 只摘自己那一份：并发合并的后来者不该把别人的在飞句柄清掉。
            if (identical(_inFlight[key], completer)) _inFlight.remove(key);
          }),
    );
    return completer.future;
  }
}
