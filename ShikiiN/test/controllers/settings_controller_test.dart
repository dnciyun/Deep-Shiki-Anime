import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shikiin/infra/persistence.dart';
import 'package:shikiin/controllers/settings_controller.dart';

class MemStore implements KeyValueStore {
  final Map<String, Object?> _m = {};
  bool closed = false;
  @override
  Object? get(String key) => _m[key];
  @override
  Future<void> put(String key, Object? value) async => _m[key] = value;
  @override
  Future<void> close() async => closed = true;
}

void main() {
  test('resumeKey is stable for same path+size', () {
    final f = File('${Directory.systemTemp.path}/shikiin_test.bin')..writeAsBytesSync([1, 2, 3]);
    final k1 = SettingsController.resumeKey(f.path);
    final k2 = SettingsController.resumeKey(f.path);
    expect(k1, k2);
    expect(k1, isNotEmpty);
    f.deleteSync();
  });

  test('saveResume then loadResume round-trips', () async {
    final c = SettingsController(MemStore());
    await c.saveResume('/v/ep1.mkv', const Duration(seconds: 90), force: true);
    expect(c.loadResume('/v/ep1.mkv'), const Duration(seconds: 90));
  });

  test('throttle suppresses writes within interval unless forced', () async {
    final store = MemStore();
    final c = SettingsController(store, throttle: const Duration(seconds: 5));
    await c.saveResume('/v/a.mkv', const Duration(seconds: 10));
    await c.saveResume('/v/a.mkv', const Duration(seconds: 11)); // 被节流忽略
    expect(c.loadResume('/v/a.mkv'), const Duration(seconds: 10));
    await c.saveResume('/v/a.mkv', const Duration(seconds: 12), force: true);
    expect(c.loadResume('/v/a.mkv'), const Duration(seconds: 12));
  });

  test('loadResume missing returns null', () {
    final c = SettingsController(MemStore());
    expect(c.loadResume('/nope'), isNull);
  });
}
