import 'dart:async';
import 'package:media_kit/media_kit.dart';
import 'diag.dart';

/// Route a single libmpv log line to [d]: fatal/error → error, warn → warn,
/// everything else (info/v/debug/trace) → breadcrumb (anti-flood; with the
/// player configured at logLevel warn these lower levels rarely arrive).
void routeMpvLog(PlayerLog log, Diag d) {
  final where = '[${log.prefix}] ${log.text}';
  switch (log.level) {
    case 'fatal':
    case 'error':
      d.error('mpv', where);
    case 'warn':
      d.warn('mpv', where);
    default:
      d.breadcrumb('mpv/${log.prefix}: ${log.text}');
  }
}

/// Subscribe a libmpv log stream (production: `player.stream.log`) to [d].
/// Returns the subscription so the caller can cancel it on teardown.
StreamSubscription<PlayerLog> installMpvLogBridge(
        Stream<PlayerLog> logStream, Diag d) =>
    logStream.listen((log) => routeMpvLog(log, d));
