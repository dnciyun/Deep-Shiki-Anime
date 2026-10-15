/// 展示层格式化工具（中文界面统一口径，避免各处自己算）。
library;

/// 二进制单位（与 Windows 资源管理器口径接近：KiB/MiB/GiB）。
String formatBytes(int? bytes) {
  if (bytes == null || bytes <= 0) return '—';
  const List<String> units = <String>['B', 'KiB', 'MiB', 'GiB', 'TiB'];
  double v = bytes.toDouble();
  int i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  return '${v.toStringAsFixed(i == 0 ? 0 : 1)} ${units[i]}';
}

String formatSpeed(double? bytesPerSecond) {
  if (bytesPerSecond == null || bytesPerSecond <= 0) return '—';
  return '${formatBytes(bytesPerSecond.round())}/s';
}

String formatPercent(double? ratio) {
  if (ratio == null) return '—';
  final clamped = ratio.clamp(0.0, 1.0);
  return '${(clamped * 100).toStringAsFixed(clamped >= 0.999 ? 0 : 1)}%';
}

String formatDateTime(DateTime? t) {
  if (t == null) return '—';
  final local = t.toLocal();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)} '
      '${two(local.hour)}:${two(local.minute)}';
}

/// 相对时间：刚刚 / N 分钟前 / N 小时前 / N 天前 / 日期。
String formatRelative(DateTime? t, {DateTime? now}) {
  if (t == null) return '—';
  final ref = now ?? DateTime.now();
  final diff = ref.difference(t);
  if (diff.isNegative) return formatDateTime(t);
  if (diff.inMinutes < 1) return '刚刚';
  if (diff.inHours < 1) return '${diff.inMinutes} 分钟前';
  if (diff.inDays < 1) return '${diff.inHours} 小时前';
  if (diff.inDays < 30) return '${diff.inDays} 天前';
  return formatDateTime(t);
}

/// 时长的中文短形态：`1 小时 03 分` / `12 分 30 秒`。
String formatDuration(Duration? d) {
  if (d == null || d <= Duration.zero) return '—';
  final h = d.inHours;
  final m = d.inMinutes.remainder(60);
  final s = d.inSeconds.remainder(60);
  if (h > 0) return '$h 小时 ${m.toString().padLeft(2, '0')} 分';
  if (m > 0) return '$m 分 ${s.toString().padLeft(2, '0')} 秒';
  return '$s 秒';
}

/// 设置项里的秒数展示：`5 分钟` / `24 小时`。
String formatTtl(int seconds) {
  if (seconds <= 0) return '不使用缓存';
  if (seconds % 3600 == 0) return '${seconds ~/ 3600} 小时';
  if (seconds % 60 == 0) return '${seconds ~/ 60} 分钟';
  return '$seconds 秒';
}

/// 集数提示拼接：`['01']` → `第 01 集`；空 → `—`。
String formatEpisodeHints(List<String> hints) {
  if (hints.isEmpty) return '—';
  return hints.map((String h) => h.toUpperCase().startsWith('S') ? h : '第 $h 集').join(' / ');
}
