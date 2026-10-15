/// 磁盘剩余空间探测（底部状态条「磁盘」用）。
///
/// 纯 Dart：`Process.run` 一次 PowerShell `(Get-PSDrive -Name X).Free`（返回字节数），
/// 失败就返回 null（UI 显示「—」并给 tooltip，**不猜数字**）。
/// 不引入 FFI / 原生依赖，所以没有「无法验证的原生调用」风险。
library;

import 'dart:async';
import 'dart:io';

/// 从路径取盘符（`F:\Anime\a` → `F`）。UNC 路径返回 null（本版本不查）。
String? driveLetterOf(String path) {
  final String trimmed = path.trim();
  if (trimmed.isEmpty) return null;
  if (trimmed.startsWith(r'\\')) return null;
  final RegExpMatch? m = RegExp(r'^([A-Za-z]):').firstMatch(trimmed);
  return m?.group(1)?.toUpperCase();
}

/// 从 PowerShell 输出里取剩余字节数（`(Get-PSDrive).Free` 就是纯数字）。
int? parseFreeBytes(String output) {
  final RegExpMatch? m = RegExp(r'\d+').firstMatch(output.trim());
  if (m == null) return null;
  return int.tryParse(m.group(0)!);
}

/// 带缓存的空间探测（同一盘 30 秒内不重复起进程；始终不抛异常）。
class DiskSpaceProbe {
  DiskSpaceProbe({this.cacheFor = const Duration(seconds: 30)});

  final Duration cacheFor;
  final Map<String, (DateTime, int?)> _cache = <String, (DateTime, int?)>{};

  /// 返回剩余字节数；取不到返回 null（调用方显示「—」）。
  Future<int?> freeBytes(String path) async {
    final String? drive = driveLetterOf(path);
    if (drive == null) return null;
    final (DateTime, int?)? hit = _cache[drive];
    if (hit != null && DateTime.now().difference(hit.$1) < cacheFor) {
      return hit.$2;
    }
    final int? value = await _query(drive);
    _cache[drive] = (DateTime.now(), value);
    return value;
  }

  Future<int?> _query(String drive) async {
    try {
      final ProcessResult result = await Process.run(
        'powershell',
        <String>[
          '-NoProfile',
          '-NonInteractive',
          '-Command',
          '(Get-PSDrive -Name $drive).Free',
        ],
        stdoutEncoding: SystemEncoding(),
        stderrEncoding: SystemEncoding(),
      ).timeout(const Duration(seconds: 8));
      if (result.exitCode != 0) return null;
      return parseFreeBytes(result.stdout.toString());
    } catch (_) {
      return null;
    }
  }
}
