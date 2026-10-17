/// 「改一条设置，要不要**重启边车进程**？」
///
/// 为什么需要这个判断（用户 2026-10-11 第二阶段清单第 6 项提出、最初是为**自动保存**
/// 服务的）：`EngineLifecyclePort.applySettings` 原来**无条件**重启边车（一次 ~3.5s，
/// 还会打断正在下载的连接）。开着自动保存时，那意味着"换个主题/改个 TTL"都会重启一次
/// 引擎 —— 自动保存根本不敢开。所以先把"哪些设置真的需要重启"抽成纯函数：
///
/// * **只能靠重启生效的进程启动参数**（下载目录、引擎 exe、做种比、tracker）→ 改了必须重启；
/// * **上下行限速** → **不再**算"必须重启"（1.1.0 M1/T4，用户 2026-10-17 在里程碑里
///   要求的）：边车有 `PATCH /limits` 可以热改，只改限速时走 [engineLimitsOnlyChanged] +
///   [engineLimitsPatch] 热更新，省掉一次 ~3.5s 重启、也不打断正在下载的连接。
///   只有边车**不支持**这个端点（404/405）或引擎没连上时，`applySettings` 才回退到
///   重启，并且**明确**告诉用户「这个引擎版本不支持热改限速，需要重启边车」（不许静默成功）。
/// * 其余（外观、缓存 TTL、省流量策略、源列表与 sukebei、队列策略、订阅、**代理**、
///   **做种开关**…）→ 宿主侧重建即可，`applySettings` 的第二半会处理，**不用**重启进程。
///
/// ⚠️ 代理与做种开关**不在**这一档（审查修正）：全仓没有任何 `--proxy-*` 进程参数
/// （代理只用于抓取，走宿主侧 `SourceRegistry` 的 proxy 配置）；做种开关真正生效的是
/// 宿主侧的 `queue.setPolicy(stopSeedingAfterDownload:)` —— 边车的 `--seed-ratio 0`
/// 语义是"不做任何做种干预"，表达不了这个开关。把它们当成进程参数只会白白重启边车
/// （~3.5s）并打断正在下载的连接，而进程参数一个都没变。
///
/// 边车参数清单的出处：`state/engine_bootstrap.dart` 的
/// `EngineRuntime.launch(... extraArgs:)` —— 那里传了什么，这里才该算什么。
library;

import 'models.dart';

/// [a] → [b] 是否需要重启边车进程才能生效。
///
/// 只列 `engine_bootstrap.dart` 真正塞进进程参数、**且没有运行时端点可以改**的那几项。
/// 限速虽然也是启动参数，但有 `PATCH /limits` 热更新通道，因此**不在**这里：
/// 见 [engineLimitsChanged] / [engineLimitsOnlyChanged] / [engineLimitsPatch]。
bool engineRestartRequired(AppSettings a, AppSettings b) =>
    a.downloadDir != b.downloadDir ||
    a.enginePath != b.enginePath ||
    a.seedRatio != b.seedRatio ||
    a.extraTrackers != b.extraTrackers;

/// [a] → [b] 上下行限速有没有变（单位 KiB/s，`0` = 不限；换算见 [limitKbpsToBps]）。
bool engineLimitsChanged(AppSettings a, AppSettings b) =>
    a.uploadLimitKbps != b.uploadLimitKbps ||
    a.downloadLimitKbps != b.downloadLimitKbps;

/// 只有限速变了、其它进程参数一个都没动 → 可以先试 `PATCH /limits` 热更新。
///
/// 一旦下载目录/引擎路径/做种比/tracker 也变了，就没得省：那几项只能重启进程
/// （`engineRestartRequired` 为 true），限速会跟着新进程参数一起生效。
bool engineLimitsOnlyChanged(AppSettings a, AppSettings b) =>
    !engineRestartRequired(a, b) && engineLimitsChanged(a, b);

/// 需要重启才能生效的字段名（写进 UI 文案/日志，便于说明"为什么这次重启了"）。
///
/// **不含限速**：限速优先热更新，只有边车不支持 `PATCH /limits` 时才回退重启；
/// 那条"回退"的文案含「为什么没热更好」+「这次是怎么生效的」，由
/// `EngineLifecyclePort.applySettings` 自己拼（见那里的 `_hotPatchLimits`）。
List<String> engineRestartReasons(AppSettings a, AppSettings b) => <String>[
  if (a.downloadDir != b.downloadDir) '下载目录',
  if (a.enginePath != b.enginePath) '引擎路径',
  if (a.seedRatio != b.seedRatio) '做种比',
  if (a.extraTrackers != b.extraTrackers) 'tracker 列表',
];

/// `PATCH /limits` 能表达的字节/秒上限：librqbit 把限速存成 `u32`。
const int kEngineMaxLimitBytesPerSecond = 0xFFFFFFFF;

/// 设置项的 `*LimitKbps`（**KiB/s**）→ 边车 `PATCH /limits` 的**字节/秒**。
///
/// 为什么是 ×1024（不是 ×1000÷8，也不是 ×1024÷8）——按仓库里的**现有语义**：
/// * 设置项名是 `uploadLimitKbps` / `downloadLimitKbps`，UI 标签写「KB/s」，但边车契约
///   `engine/README.md` 的「命令行」表里 `--*-limit-kbps` 的单位明确是 **KiB/s**；
/// * 边车实现 `engine/src/cfg.rs` 的 `kbps_to_bps()` 就是
///   `kbps.saturating_mul(1024)`；`PATCH /limits` 的 body 则是**字节/秒**
///   （`engine/README.md` §10 第 9 条）。
/// 所以「启动参数」与「热更新」必须用同一个换算：否则同一个限速，重启一次是 2×、
/// 不重启热改是 1×，用户看到的速度会莫名其妙差一倍。
///
/// 边界：
/// * `0` = 不限 —— 两边语义一致，原样传 `0`（边车 `to_limit(0)` 会映射成 `None`
///   = librqbit 不限速）；
/// * 超过 [kEngineMaxLimitBytesPerSecond] 的值**饱和到 u32::MAX**，与边车启动参数的
///   `saturating_mul(1024)` 完全一致：这样同一个 kbps 走"热改"和"重启"得到同一个字节数，
///   不会一条成功、另一条返回 400 `bad_limit`。设置页对这两个数字**没有**上限校验
///   （只校验非负整数），所以这个饱和不是理论值。
int limitKbpsToBps(int kbps) {
  if (kbps <= 0) return 0;
  // 先比上限再乘：避免超 64 位整数时溢出成负数。
  if (kbps > kEngineMaxLimitBytesPerSecond ~/ 1024) {
    return kEngineMaxLimitBytesPerSecond;
  }
  return kbps * 1024;
}

/// 只把**变了的那一路**翻成 `PATCH /limits` 的参数（没变的那一路 `null` = 不改）。
///
/// 边车的 `setLimits` 语义就是"缺省字段表示不改"（`core/lib/engine/client.dart`），
/// 所以这里不传没变的那一路，免得"顺手"把另一条限速也重设一遍。
({int? downloadBps, int? uploadBps}) engineLimitsPatch(
  AppSettings a,
  AppSettings b,
) => (
  downloadBps: a.downloadLimitKbps == b.downloadLimitKbps
      ? null
      : limitKbpsToBps(b.downloadLimitKbps),
  uploadBps: a.uploadLimitKbps == b.uploadLimitKbps
      ? null
      : limitKbpsToBps(b.uploadLimitKbps),
);
