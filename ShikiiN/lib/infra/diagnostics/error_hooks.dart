import 'dart:async';
import 'package:flutter/foundation.dart';
import 'diag.dart';

/// Install global Dart error hooks routing everything to [d]. Call as early as
/// possible in main() — before any initialization that can throw (spec §4.1).
void installErrorHooks(Diag d) {
  FlutterError.onError = (FlutterErrorDetails details) {
    d.error('flutter', details.exceptionAsString(), details.exception, details.stack);
    if (kDebugMode) {
      FlutterError.presentError(details); // keep the red screen in debug
    }
  };
  PlatformDispatcher.instance.onError = (Object e, StackTrace st) {
    d.error('platform', e.toString(), e, st);
    return true; // handled — don't tear down the isolate
  };
}

/// Outermost fallback: run [body] (typically `() => runApp(...)`) in a guarded
/// zone so anything that escapes the two hooks above still lands in [d].
void runGuarded(Diag d, void Function() body) {
  runZonedGuarded(body, (Object e, StackTrace st) => d.error('zone', e.toString(), e, st));
}
