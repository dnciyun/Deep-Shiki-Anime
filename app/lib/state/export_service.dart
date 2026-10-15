/// 配置迁移与诊断包的文件 I/O（spec §7.3 Q20③④）。
///
/// 位置由用户通过系统选择器决定（不猜路径）；失败给可行动异常。
library;

import 'dart:io';

import 'package:path/path.dart' as p;

import '../domain/config_io.dart';
import '../domain/models.dart';
import '../domain/ports.dart';
import '../domain/watch_history.dart';

/// 导出配置到用户选的目录；返回写出的文件路径。
Future<String> exportConfigTo(
  PickerPort picker,
  AppSettings settings, {
  DateTime? now,
}) async {
  final String? dir = await picker.pickDirectory(title: '选择配置导出目录');
  if (dir == null) {
    throw const PortUnavailableException('已取消导出', hint: '重新点击「导出配置」并选一个目录');
  }
  final String stamp = _stamp(now ?? DateTime.now());
  final File file = File(p.join(dir, 'dsanima-config-$stamp.json'));
  await file.writeAsString(encodeConfig(settings, now: now), flush: true);
  return file.path;
}

/// 从用户选的文件导入配置。
Future<AppSettings> importConfigFrom(PickerPort picker) async {
  final String? path = await picker.pickFile(
    title: '选择 DSAnima 配置文件',
    extensions: <String>['json'],
  );
  if (path == null) {
    throw const PortUnavailableException('已取消导入', hint: '重新点击「导入配置」并选一个 .json 文件');
  }
  final File file = File(path);
  if (!await file.exists()) {
    throw PortUnavailableException('文件不存在：$path', hint: '确认路径后重试');
  }
  final String raw = await file.readAsString();
  try {
    return decodeConfig(raw);
  } on FormatException catch (error) {
    throw PortUnavailableException('配置文件无法解析：${error.message}',
        hint: '请选 DSAnima 导出的 .json 配置文件');
  }
}

/// 导出**观看记录**到用户选的目录；返回写出的文件路径（第二十七轮）。
///
/// 与「导出配置」分开是因为它**含隐私**（看过哪些番、看到哪儿）：配置/诊断包刻意不带
/// 观看历史（`config_io.dart` 的注释写着这条），而这个文件是用户在「观看记录」页
/// 显式点出来的那一份 —— 写进用户自己选的目录，文件名也写清楚是什么。
Future<String> exportWatchHistoryTo(
  PickerPort picker,
  List<WatchRecord> records, {
  int? retentionDays,
  DateTime? now,
}) async {
  final String? dir = await picker.pickDirectory(title: '选择观看记录导出目录');
  if (dir == null) {
    throw const PortUnavailableException(
      '已取消导出',
      hint: '重新点击「导出观看记录」并选一个目录',
    );
  }
  final String stamp = _stamp(now ?? DateTime.now());
  final File file = File(p.join(dir, 'dsanima-watch-history-$stamp.json'));
  await file.writeAsString(
    watchHistoryJson(records, exportedAt: now, retentionDays: retentionDays),
    flush: true,
  );
  return file.path;
}

/// 导出诊断包（日志 + 配置，不含隐私）；返回写出的文件路径。
Future<String> exportDiagnosticsTo(
  PickerPort picker, {
  required AppSettings settings,
  required String engineStatus,
  required Directory? supportDir,
  required List<String> notes,
  DateTime? now,
}) async {
  final String? dir = await picker.pickDirectory(title: '选择诊断包导出目录');
  if (dir == null) {
    throw const PortUnavailableException('已取消导出', hint: '重新点击「导出诊断包」并选一个目录');
  }
  final List<String> logTail = await readEngineLogTail(supportDir, maxLines: 200);
  final String report = buildDiagnosticsReport(
    settings: settings,
    engineStatus: engineStatus,
    engineLogTail: logTail,
    notes: notes,
    now: now,
  );
  final String stamp = _stamp(now ?? DateTime.now());
  final File file = File(p.join(dir, 'dsanima-diagnostics-$stamp.txt'));
  await file.writeAsString(report, flush: true);
  return file.path;
}

/// 读边车日志尾部（读不到返回空列表，不抛）。
Future<List<String>> readEngineLogTail(Directory? supportDir, {int maxLines = 200}) async {
  if (supportDir == null) return const <String>[];
  final File log = File(p.join(supportDir.path, 'engine', 'engine.log'));
  try {
    if (!await log.exists()) return const <String>[];
    final List<String> lines = await log.readAsLines();
    if (lines.length <= maxLines) return lines;
    return lines.sublist(lines.length - maxLines);
  } catch (_) {
    return const <String>[];
  }
}

String _stamp(DateTime t) =>
    '${t.year}${_two(t.month)}${_two(t.day)}-${_two(t.hour)}${_two(t.minute)}${_two(t.second)}';

String _two(int v) => v.toString().padLeft(2, '0');
