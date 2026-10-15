import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:shikiin/infra/diagnostics/diag.dart';
import 'package:shikiin/infra/diagnostics/mpv_log_bridge.dart';

class _RecDiag extends Diag {
  final List<String> calls = [];
  @override
  void error(String source, String msg, [Object? e, StackTrace? st]) =>
      calls.add('error:$msg');
  @override
  void warn(String source, String msg, [Object? e, StackTrace? st]) =>
      calls.add('warn:$msg');
  @override
  void breadcrumb(String event) => calls.add('crumb:$event');
}

void main() {
  test('routeMpvLog maps fatal/error→error, warn→warn, info→breadcrumb', () {
    final rec = _RecDiag();
    routeMpvLog(const PlayerLog(prefix: 'vo', level: 'error', text: 'swapchain'), rec);
    routeMpvLog(const PlayerLog(prefix: 'cplayer', level: 'fatal', text: 'abort'), rec);
    routeMpvLog(const PlayerLog(prefix: 'vd', level: 'warn', text: 'slow'), rec);
    routeMpvLog(const PlayerLog(prefix: 'cplayer', level: 'info', text: 'playing'), rec);
    expect(rec.calls, [
      'error:[vo] swapchain',
      'error:[cplayer] abort',
      'warn:[vd] slow',
      'crumb:mpv/cplayer: playing',
    ]);
  });

  test('installMpvLogBridge subscribes and routes stream events', () async {
    final rec = _RecDiag();
    final ctrl = StreamController<PlayerLog>();
    final sub = installMpvLogBridge(ctrl.stream, rec);
    ctrl.add(const PlayerLog(prefix: 'vo', level: 'error', text: 'boom'));
    await Future<void>(() {});
    expect(rec.calls, contains('error:[vo] boom'));
    await sub.cancel();
    await ctrl.close();
  });
}
