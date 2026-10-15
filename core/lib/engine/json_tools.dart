/// 引擎 JSON 响应的容错取值工具。
///
/// 契约要求（task-3 / spec §3.6）：字段缺失或类型不符时使用默认值，
/// 而不是抛异常——一个未知新增字段不应该让整个 UI 崩掉。
/// 本文件属于 `engine/` 内部实现，刻意**不从 barrel 导出**，
/// 以免与 `sources/`、`subs/` 的同名工具函数在公共命名空间撞名。
library;

/// 取整数。支持 `int` / `num` / 数字字符串 / `bool`，其余返回 [fallback]。
int jsonInt(Object? value, {int fallback = 0}) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is bool) return value ? 1 : 0;
  if (value is String) {
    final text = value.trim();
    return int.tryParse(text) ?? double.tryParse(text)?.toInt() ?? fallback;
  }
  return fallback;
}

/// 取浮点数。支持 `int` / `num` / 数字字符串，其余返回 [fallback]。
double jsonDouble(Object? value, {double fallback = 0}) {
  if (value is double) return value;
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value.trim()) ?? fallback;
  return fallback;
}

/// 取布尔值。支持 `bool` / 数字 / `'true'|'false'|'1'|'0'|'yes'|'no'`。
bool jsonBool(Object? value, {bool fallback = false}) {
  if (value is bool) return value;
  if (value is num) return value != 0;
  if (value is String) {
    switch (value.trim().toLowerCase()) {
      case 'true':
      case '1':
      case 'yes':
      case 'on':
        return true;
      case 'false':
      case '0':
      case 'no':
      case 'off':
      case '':
        return false;
    }
  }
  return fallback;
}

/// 取字符串。非字符串的标量转成字符串；对象/数组/null 返回 `null`。
String? jsonString(Object? value) {
  if (value is String) return value;
  if (value is num || value is bool) return value.toString();
  return null;
}

/// 取 JSON 对象；不是对象时返回 `null`（调用方决定是容错还是报错）。
Map<String, dynamic>? jsonMap(Object? value) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) {
    return <String, dynamic>{
      for (final entry in value.entries) entry.key.toString(): entry.value,
    };
  }
  return null;
}

/// 取 JSON 数组；不是数组时返回空列表。
List<Object?> jsonList(Object? value) {
  if (value is List) return List<Object?>.from(value);
  return const <Object?>[];
}
