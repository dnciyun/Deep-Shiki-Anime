/// 默认下载目录的解析（用户 2026-10-11：「下载目录默认在
/// `C:\Users\用户名\Downloads\Anime`」）。
///
/// 为什么要单独一个文件、而且要把环境变量**当参数传进来**：
/// * 这是纯字符串规则（`%USERPROFILE%\Downloads\Anime`），跟 Hive / 引擎 / UI 都无关；
///   放在 domain 层可以被**首启向导、设置页、引擎启动**三处共用同一份实现 ——
///   三处各写一遍必然有一天跑偏（"向导里显示 A、引擎用的是 B"）。
/// * `Platform.environment` 是全局状态，测试里改不动它。注入一份 `env` 映射，
///   单测才能覆盖「USERPROFILE 缺失 → HOMEDRIVE+HOMEPATH 回落 → 都缺 = 空串」
///   整条链，而不必去动真实系统环境变量。
///
/// ⚠️ **绝不猜盘符**：拿不到用户目录就返回**空串**，由调用方维持原来的
/// 「还没有设置下载目录」报错。猜一个 `C:\Downloads\Anime` 比报错更糟 ——
/// 那可能是台没有写权限的机器，用户会得到一句莫名其妙的引擎启动失败。
library;

import 'dart:io' show Platform;

/// 默认下载目录挂在用户目录下的那一段（分隔符统一用 Windows 的 `\`）。
const String kDownloadDirLeaf = r'Downloads\Anime';

/// 解析默认下载目录；拿不到用户目录时返回**空串**。
///
/// 规则（顺序固定，不并行不猜测）：
/// 1. `USERPROFILE` 非空 → `<USERPROFILE>\Downloads\Anime`；
/// 2. 否则 `HOMEDRIVE` + `HOMEPATH` 都非空 → `<HOMEDRIVE><HOMEPATH>\Downloads\Anime`；
/// 3. 都没有 → `''`。
///
/// [env] 只给单测注入；生产调用不传，走 `Platform.environment`。
String resolveDefaultDownloadDir({Map<String, String>? env}) {
  final Map<String, String> values = env ?? Platform.environment;

  final String profile = _clean(values['USERPROFILE']);
  if (profile.isNotEmpty) return _join(profile, kDownloadDirLeaf);

  // USERPROFILE 缺失（精简版系统 / 被清过的环境变量 / 某些 CI）时用老两件套拼。
  final String drive = _clean(values['HOMEDRIVE']);
  final String homePath = _clean(values['HOMEPATH']);
  if (drive.isEmpty || homePath.isEmpty) return '';
  return _join(_join(drive, homePath), kDownloadDirLeaf);
}

/// 「生效值」：设置里有值用设置值，否则用默认值；空串 = 仍然没得用。
///
/// 引擎启动、设置页显示、向导预填都读这一个函数，口径只有一处：
/// * 设置值两端空白被去掉、尾部多余分隔符被去掉（`F:\Anime\` → `F:\Anime`）；
/// * 设置值为 null / 空白 → 默认目录（可能是空串）。
String effectiveDownloadDir(String? settingValue, {Map<String, String>? env}) {
  final String configured = _stripTrailingSeparators(_clean(settingValue));
  if (configured.isNotEmpty) return configured;
  return resolveDefaultDownloadDir(env: env);
}

/// 去掉两端空白。
String _clean(String? raw) => (raw ?? '').trim();

/// 用 `\` 把两段路径拼起来。
///
/// 为什么要自己拼而不是 `path.join`：这里处理的是**用户配置字符串**，
/// 可能是 `H:` + `\Users\x`、也可能是 `\Users\x` 不带前导斜杠，
/// 而 `p.join` 在 Windows 上会把 `H:` 当成"当前目录"语义。规则简单点更可控。
String _join(String head, String tail) {
  final String a = _stripTrailingSeparators(head);
  final String b = _stripTrailingSeparators(tail).replaceFirst(RegExp(r'^\\+'), '');
  if (a.isEmpty) return b;
  if (b.isEmpty) return a;
  // 头已经以 `\` 结尾（`H:\` 这种盘符根会被刻意保留）时**不能**再补一个，
  // 否则拼出 `H:\\Users\...` —— 单测逮到过。
  if (a.endsWith(r'\')) return '$a$b';
  return '$a\\$b';
}

/// 归一化分隔符（`/` → `\`）并去掉**尾部**多余分隔符。
///
/// 唯一的例外是**盘符根**：`C:\` 不能变成 `C:`（那是"盘符下的当前目录"，语义不同）。
String _stripTrailingSeparators(String raw) {
  String value = raw.replaceAll('/', r'\');
  while (value.length > 1 && value.endsWith(r'\')) {
    if (RegExp(r'^[A-Za-z]:\\$').hasMatch(value)) break;
    value = value.substring(0, value.length - 1);
  }
  return value;
}
