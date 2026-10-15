import 'dart:ui';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shikiin/infra/diagnostics/diag.dart';
import 'package:shikiin/infra/diagnostics/error_hooks.dart';

class _RecDiag extends Diag {
  final List<String> sources = [];
  @override
  void error(String source, String msg, [Object? e, StackTrace? st]) =>
      sources.add(source);
}

void main() {
  late FlutterExceptionHandler? savedFlutter;
  late ErrorCallback? savedPlatform;

  setUp(() {
    savedFlutter = FlutterError.onError;
    savedPlatform = PlatformDispatcher.instance.onError;
  });
  tearDown(() {
    FlutterError.onError = savedFlutter;
    PlatformDispatcher.instance.onError = savedPlatform;
  });

  test('installErrorHooks routes FlutterError.onError to Diag.error', () {
    final rec = _RecDiag();
    installErrorHooks(rec);
    FlutterError.onError!(FlutterErrorDetails(exception: Exception('x')));
    expect(rec.sources, contains('flutter'));
  });

  test('installErrorHooks routes PlatformDispatcher.onError and returns true', () {
    final rec = _RecDiag();
    installErrorHooks(rec);
    final handled =
        PlatformDispatcher.instance.onError!(Exception('y'), StackTrace.current);
    expect(handled, isTrue);
    expect(rec.sources, contains('platform'));
  });

  test('runGuarded routes a synchronous throw in body to Diag.error(zone)', () async {
    final rec = _RecDiag();
    runGuarded(rec, () => throw Exception('z'));
    await Future<void>(() {}); // let the zone handler run
    expect(rec.sources, contains('zone'));
  });
}
