import 'package:flutter_test/flutter_test.dart';
import 'package:shikiin/models/mpv_stream_tuning.dart';

void main() {
  test('开播前下发的调优命令：把网络超时从 media_kit 的 5s 放宽，且关掉磁盘缓存', () {
    final List<List<String>> commands = mpvStreamTuningCommands();
    expect(commands, hasLength(2));
    expect(commands[0], <String>['set', 'network-timeout', '60']);
    expect(commands[1], <String>['set', 'cache-on-disk', 'no']);
    // 每条都是 `set <option> <value>`：调用方逐条当 mpv 命令下发。
    for (final List<String> cmd in commands) {
      expect(cmd.length, 3);
      expect(cmd.first, 'set');
    }
  });

  test('超时值必须明显大于 media_kit 的 5 秒（否则等于没改）', () {
    expect(kMpvNetworkTimeoutSeconds, greaterThan(10));
  });
}
