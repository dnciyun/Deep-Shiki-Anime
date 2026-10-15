/// 订阅/队列测试的支撑：可推进的假时钟（不真实等待）。
library;

/// 假时钟：`sleep` 只推进时钟，供队列的确定性时序断言使用。
class FakeClock {
  FakeClock(this.now);

  DateTime now;

  final List<Duration> sleeps = <Duration>[];

  DateTime call() => now;

  Future<void> sleep(Duration duration) async {
    sleeps.add(duration);
    now = now.add(duration);
  }

  void advance(Duration duration) => now = now.add(duration);
}
