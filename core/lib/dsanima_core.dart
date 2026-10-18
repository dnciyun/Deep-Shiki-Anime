/// DSAnima 核心包公共出口（spec §4）。
///
/// * `engine/` —— 边车进程托管与 HTTP/SSE 客户端（③ engine-client 负责汇总）。
/// * `sources/` —— 内置 10 个源实例（nyaa / mikan / dmhy / acgrip / acgnx /
///   bangumi.moe 各自的分区）+ 自定义 RSS（② sources-subs 的子出口）。
/// * `subs/` —— 标题解析、订阅规则、下载队列（同上）。
/// * `update/` —— 版本号比较 + GitHub Release 解析与判定（第三十九轮，纯逻辑）。
/// * `extensions/` —— 扩展清单（manifest.json）解析 + 压缩包条目守卫（1.1.0 M3，纯逻辑）。
///
/// 内部工具（如 `engine/json_tools.dart`）刻意不导出，避免污染公共命名空间。
library;

// ── engine/（③ engine-client）──────────────────────────────────────────────
export 'engine/client.dart';
export 'engine/locator.dart';
export 'engine/models.dart';
export 'engine/process.dart';
export 'engine/runtime.dart';
export 'engine/sse.dart';

// ── sources/ + subs/（② sources-subs 各自维护子出口）────────────────────────
export 'sources/sources.dart';
export 'subs/subs.dart';

// ── update/（第三十九轮：GitHub Release 检查更新，纯逻辑）────────────────────
export 'update/update.dart';

// ── extensions/（1.1.0 M3：扩展清单解析 + 包体守卫，纯逻辑）──────────────────
export 'extensions/manifest.dart';
export 'extensions/package_guard.dart';
export 'extensions/picture.dart';
export 'extensions/urls.dart';
export 'extensions/user_settings.dart';
