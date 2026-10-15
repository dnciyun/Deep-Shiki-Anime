/// 可注入的键值持久化端口。
///
/// **签名正本**（Lead 2026-10-08 通知，按 host-dev 的 Hive 实现对齐）：
/// ```dart
/// abstract class KeyValueStore {
///   Object? get(String key);
///   Future<void> put(String key, Object? value);
///   Future<void> delete(String key);
///   Iterable<String> get keys;
///   Future<void> clear();
/// }
/// ```
/// [KeyValueStore.get] 是**同步**的 —— 这正是 Hive `Box.get` 的形态，宿主可以直接
/// 用 `Box<dynamic>` 实现；`put` 只接受可 JSON 序列化的 `Object?`
/// （Map / List / String / num / bool / null）。
///
/// `core` 是纯逻辑包，**不依赖 Hive**：
/// * 生产：宿主 `app/` 注入 Hive 实现（box：`subscriptions` / `queue` / `settings`），
///   或使用本文件的 [FileKeyValueStore]（`<appSupport>/dsanima/cache/sources` 等）；
/// * 单测：[InMemoryKeyValueStore]，**不落盘、不联网**。
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// 字符串键值存储端口（值 = 可 JSON 序列化的对象）。
abstract class KeyValueStore {
  /// 同步读取；不存在返回 null。实现必须能在不 await 的情况下给出结果。
  Object? get(String key);

  /// 写入（覆盖）。
  Future<void> put(String key, Object? value);

  /// 删除；不存在时静默返回。
  Future<void> delete(String key);

  /// 所有键。
  Iterable<String> get keys;

  /// 清空。
  Future<void> clear();
}

/// 内存实现：单测默认，也适合作为「宿主未注入存储」时的降级。
class InMemoryKeyValueStore implements KeyValueStore {
  InMemoryKeyValueStore([Map<String, Object?>? seed])
      : _data = <String, Object?>{...?seed};

  final Map<String, Object?> _data;

  /// 写入次数（测试断言「是否真的落盘」用）。
  int putCount = 0;

  @override
  Object? get(String key) => _data[key];

  @override
  Future<void> put(String key, Object? value) async {
    putCount++;
    _data[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    _data.remove(key);
  }

  @override
  Iterable<String> get keys => _data.keys.toList(growable: false);

  @override
  Future<void> clear() async {
    _data.clear();
  }

  /// 仅供测试：直接看当前快照。
  Map<String, Object?> snapshot() => Map<String, Object?>.unmodifiable(_data);
}

/// 文件实现：一个 key 一个 `.json` 文件，写入走「临时文件 + rename」原子替换。
///
/// key 经 [sanitizeKeyFileName] 归一化（缓存键是 sha1，天然安全）。
class FileKeyValueStore implements KeyValueStore {
  FileKeyValueStore(this.directory);

  /// 目录（不存在时首次写入自动创建）。
  final Directory directory;

  final Map<String, Object?> _memo = <String, Object?>{};

  File _fileFor(String key) =>
      File(p.join(directory.path, '${sanitizeKeyFileName(key)}.json'));

  @override
  Object? get(String key) {
    if (_memo.containsKey(key)) return _memo[key];
    final f = _fileFor(key);
    if (!f.existsSync()) return null;
    Object? decoded;
    try {
      decoded = jsonDecode(f.readAsStringSync());
    } catch (_) {
      // 损坏文件当作 miss（不让半截 JSON 炸掉 UI）。
      return null;
    }
    _memo[key] = decoded;
    return decoded;
  }

  @override
  Future<void> put(String key, Object? value) async {
    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }
    final f = _fileFor(key);
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(jsonEncode(value), flush: true);
    await tmp.rename(f.path);
    _memo[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    _memo.remove(key);
    final f = _fileFor(key);
    if (await f.exists()) await f.delete();
  }

  @override
  Iterable<String> get keys {
    if (!directory.existsSync()) return const <String>[];
    final out = <String>[];
    for (final entity in directory.listSync()) {
      if (entity is! File) continue;
      final name = p.basename(entity.path);
      if (name.endsWith('.json')) {
        out.add(name.substring(0, name.length - '.json'.length));
      }
    }
    return out;
  }

  @override
  Future<void> clear() async {
    _memo.clear();
    if (!await directory.exists()) return;
    await for (final entity in directory.list()) {
      if (entity is File && entity.path.endsWith('.json')) {
        await entity.delete();
      }
    }
  }
}

/// 把任意 key 变成安全的文件名（保留 `[A-Za-z0-9._-]`，其余替换为 `_`）。
String sanitizeKeyFileName(String key) {
  final sb = StringBuffer();
  for (final rune in key.runes) {
    final c = String.fromCharCode(rune);
    sb.write(RegExp(r'[A-Za-z0-9._-]').hasMatch(c) ? c : '_');
  }
  final s = sb.toString();
  if (s.isEmpty) return '_';
  return s.length > 120 ? s.substring(0, 120) : s;
}
