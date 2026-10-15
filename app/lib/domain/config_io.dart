/// 配置导出/导入 + 诊断包内容（spec §7.3 Q20③④）。
///
/// 纯函数，可单测；文件 I/O 在 `state/export_service.dart`。
///
/// **隐私**：导出的配置与诊断包都会把 `proxyPassword` 抹成 `***`，
/// 且不含观看历史、磁力链、Cookie 等隐私内容。
library;

import 'dart:convert';

import 'models.dart';

/// 配置 JSON 的 schema 版本（导入时校验，避免把未来格式塞进旧版本）。
const int dsConfigSchema = 1;

/// 导出配置（可迁移：配置 / 缓存策略 / 下载目录）。
String encodeConfig(AppSettings settings, {DateTime? now}) {
  final Map<String, Object?> payload = settings.toJson();
  if ((payload['proxyPassword'] as String?)?.isNotEmpty ?? false) {
    payload['proxyPassword'] = '***';
  }
  return const JsonEncoder.withIndent('  ').convert(<String, Object?>{
    'schema': dsConfigSchema,
    'app': 'DSAnima',
    'exportedAt': (now ?? DateTime.now()).toIso8601String(),
    'settings': payload,
  });
}

/// 解析导入的配置；格式不对时抛 [FormatException]（带可行动说明）。
AppSettings decodeConfig(String raw) {
  final Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } on FormatException catch (error) {
    throw FormatException('不是合法 JSON：${error.message}');
  }
  if (decoded is! Map) {
    throw const FormatException('顶层必须是 JSON 对象（DSAnima 导出的配置文件）');
  }
  final Object? schema = decoded['schema'];
  if (schema is! num) {
    throw const FormatException('缺少 schema 字段：这不像是 DSAnima 导出的配置');
  }
  if (schema.toInt() > dsConfigSchema) {
    throw FormatException(
        '配置来自更新的版本（schema ${schema.toInt()} > $dsConfigSchema），请升级 DSAnima 后再导入');
  }
  final Object? settings = decoded['settings'];
  if (settings is! Map) {
    throw const FormatException('缺少 settings 段：文件可能被截断');
  }
  final AppSettings parsed =
      AppSettings.fromJson(settings.cast<Object?, Object?>());
  // 抹掉的密码不覆盖回来（导入配置不该带来别人的密码）。
  return parsed.proxyPassword == '***'
      ? parsed.copyWith(proxyPassword: '')
      : parsed;
}

/// 诊断包文本（日志 + 配置，**不含隐私**）。
String buildDiagnosticsReport({
  required AppSettings settings,
  required String engineStatus,
  required List<String> engineLogTail,
  required List<String> notes,
  DateTime? now,
}) {
  final StringBuffer sb = StringBuffer();
  final DateTime stamp = now ?? DateTime.now();
  sb.writeln('DSAnima 诊断包');
  sb.writeln('生成时间：${stamp.toIso8601String()}');
  sb.writeln('=' * 60);
  sb.writeln();
  sb.writeln('【环境】');
  sb.writeln('downloadDir: ${settings.downloadDir ?? '(未设置)'}');
  sb.writeln('enginePath: ${settings.enginePath ?? '(自动查找)'}');
  sb.writeln('引擎状态: $engineStatus');
  sb.writeln(
      // 提示：这里只打码 + 家族，不打中文名 —— domain 层**不 import Flutter**，
      // 中文名的唯一事实来源是 `theme/tokens.dart` 的 `DsAppearance.label`。
      '外观: ${settings.themeId}'
      '${settings.isDarkTheme ? '（黑色系）' : '（白色系）'}');
  sb.writeln('上传限速: ${settings.uploadLimitKbps} KB/s · 下载限速: ${settings.downloadLimitKbps} KB/s');
  sb.writeln('做种: ${settings.seedEnabled ? '开启' : '关闭'} · 后台常驻: ${settings.backgroundResident ? '开启' : '关闭'}');
  sb.writeln('省流量列表: ${settings.bandwidth.excludePatterns.join(' | ')}');
  sb.writeln();
  sb.writeln('【配置（代理密码已抹为 ***，不含观看历史/磁力链）】');
  sb.writeln(encodeConfig(settings, now: stamp));
  sb.writeln();
  if (notes.isNotEmpty) {
    sb.writeln('【备注】');
    for (final String note in notes) {
      sb.writeln('- $note');
    }
    sb.writeln();
  }
  sb.writeln('【引擎日志尾部 ${engineLogTail.length} 行】');
  if (engineLogTail.isEmpty) {
    sb.writeln('(无日志：引擎尚未启动或日志文件不存在)');
  } else {
    for (final String line in engineLogTail) {
      sb.writeln(line);
    }
  }
  return sb.toString();
}
