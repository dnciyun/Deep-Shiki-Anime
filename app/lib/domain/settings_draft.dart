/// 设置草稿 → 落盘那一份的合成（2026-10-12 第十六轮：**去掉自动保存，改成手动保存**）。
///
/// 用户原话：
/// > 「去除设置自动保存的逻辑，仅手动保存」
///
/// 两个纯函数：判断"脏没脏"（[settingsEqual]）与合成"真正要写下去的那份"
/// （[mergeDraftForSave]）。都刻意不碰 Flutter，好在单测里直接喂数字/结构断言。
library;

import 'dart:convert';

import 'models.dart';

/// 两份设置是不是"同一份"（逐字段比 `toJson()`）。
///
/// 为什么按字段比而不是整份字符串比：`toJson().toString()` 对**列表**是 `toString()`，
/// 而 `['a, b']` 与 `['a', 'b']` 的 `toString()` 是同一个字符串 `[a, b]`
/// —— 用户真的这么改时会被判成"没改"：脏标记不翻、保存按钮一直灰着。
bool settingsEqual(AppSettings a, AppSettings b) {
  final Map<String, Object?> from = a.toJson();
  final Map<String, Object?> to = b.toJson();
  if (from.length != to.length) return false;
  for (final MapEntry<String, Object?> entry in from.entries) {
    if (!to.containsKey(entry.key)) return false;
    if (_canonical(entry.value) != _canonical(to[entry.key])) return false;
  }
  return true;
}

/// 把一个字段值转成**能安全比较**的字符串。
///
/// * 不能直接插值：见 [settingsEqual] 里列表的例子；
/// * 不能无脑 `jsonEncode`：`trackerListUpdatedAt` 是 `DateTime`，jsonEncode 会抛。
String _canonical(Object? value) {
  if (value is DateTime) return 'dt:${value.toIso8601String()}';
  return 'json:${jsonEncode(value)}';
}

/// 手动保存时**真正要写下去的那份**：用户改过的字段用草稿，没碰过的字段用现在已保存的。
///
/// 为什么不是把草稿整份写下去：草稿 = "打开设置页那一刻的快照 + 用户改动"。这中间
/// **别的地方也会写设置**，而且都不是设置页 —— 第 15 轮的搜索页勾选走
/// `settingsProvider.patch`、每日 tracker 刷新走 `tracker_refresh.dart`、
/// 首启向导走 `first_run.dart`。整份覆盖会把它们悄悄吞掉：用户只是在设置页改了个限速，
/// 一天前刚刷新过的 tracker 列表却被退回打开设置页时那份。
///
/// 所以按 [baseline]（草稿的起点）与 [draft] 的**逐字段差异**取"用户改了什么"，
/// 只把那些字段盖到 [current]（现在的已保存值）上。
AppSettings mergeDraftForSave({
  required AppSettings baseline,
  required AppSettings draft,
  required AppSettings current,
}) {
  final Map<String, Object?> from = baseline.toJson();
  final Map<String, Object?> to = draft.toJson();
  final Map<String, Object?> merged = Map<String, Object?>.of(current.toJson());
  for (final MapEntry<String, Object?> entry in to.entries) {
    if (_canonical(from[entry.key]) != _canonical(entry.value)) {
      merged[entry.key] = entry.value;
    }
  }
  return AppSettings.fromJson(merged);
}
