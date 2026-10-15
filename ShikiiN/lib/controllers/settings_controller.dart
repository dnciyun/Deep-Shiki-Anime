import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import '../infra/persistence.dart';
import '../models/app_settings.dart';

/// 设置与续播位置的读写（契约 §3）。
class SettingsController extends ChangeNotifier {
  final KeyValueStore _store;
  final Duration throttle;
  final Map<String, DateTime> _lastWrite = {};

  SettingsController(this._store, {this.throttle = const Duration(seconds: 5)});

  /// 续播键：基于路径 + 文件大小（存在时），稳定且避免重名冲突。
  /// **键格式 `resume:<md5(path|size)>` 不能改**，否则用户既有续播记录读不出来。
  static String resumeKey(String path) {
    int size = 0;
    try {
      size = File(path).lengthSync();
    } catch (_) {}
    final raw = '$path|$size';
    return 'resume:${md5.convert(raw.codeUnits)}';
  }

  Duration? loadResume(String path) {
    final ms = _store.get(resumeKey(path));
    if (ms is int) return Duration(milliseconds: ms);
    return null;
  }

  Future<void> saveResume(String path, Duration position, {bool force = false}) async {
    final key = resumeKey(path);
    final now = DateTime.now();
    final last = _lastWrite[key];
    if (!force && last != null && now.difference(last) < throttle) return;
    _lastWrite[key] = now;
    await _store.put(key, position.inMilliseconds);
  }

  /// 持久化数据损坏（字段类型对不上）时回退默认值：loadSettings 在 initState 与
  /// 大量 UI 回调里被调用，抛出去会让整个界面起不来。
  AppSettings loadSettings() {
    try {
      return AppSettings.fromMap(_store.get('app_settings') as Map?);
    } catch (_) {
      return AppSettings();
    }
  }

  Future<void> saveSettings(AppSettings s) async {
    await _store.put('app_settings', s.toMap());
    notifyListeners();
  }

  /// 改一个字段并落盘（读-改-写，走 [saveSettings]）。
  Future<void> patch(AppSettings Function(AppSettings s) change) =>
      saveSettings(change(loadSettings()));
}
