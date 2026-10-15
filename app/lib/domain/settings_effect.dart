/// 「改一条设置，要不要**重启边车进程**？」
///
/// 为什么需要这个判断（用户 2026-10-11 第二阶段清单第 6 项提出、最初是为**自动保存**
/// 服务的）：`EngineLifecyclePort.applySettings` 原来**无条件**重启边车（一次 ~3.5s，
/// 还会打断正在下载的连接）。开着自动保存时，那意味着"换个主题/改个 TTL"都会重启一次
/// 引擎 —— 自动保存根本不敢开。所以先把"哪些设置真的需要重启"抽成纯函数：
///
/// * **进程启动参数**（下载目录、引擎 exe、上下行限速、做种比、tracker）→ 改了必须重启；
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
/// 只列 `engine_bootstrap.dart` 真正塞进进程参数的那几项。
bool engineRestartRequired(AppSettings a, AppSettings b) =>
    a.downloadDir != b.downloadDir ||
    a.enginePath != b.enginePath ||
    a.uploadLimitKbps != b.uploadLimitKbps ||
    a.downloadLimitKbps != b.downloadLimitKbps ||
    a.seedRatio != b.seedRatio ||
    a.extraTrackers != b.extraTrackers;

/// 需要重启才能生效的字段名（写进 UI 文案/日志，便于说明"为什么这次重启了"）。
List<String> engineRestartReasons(AppSettings a, AppSettings b) => <String>[
  if (a.downloadDir != b.downloadDir) '下载目录',
  if (a.enginePath != b.enginePath) '引擎路径',
  if (a.uploadLimitKbps != b.uploadLimitKbps) '上传限速',
  if (a.downloadLimitKbps != b.downloadLimitKbps) '下载限速',
  if (a.seedRatio != b.seedRatio) '做种比',
  if (a.extraTrackers != b.extraTrackers) 'tracker 列表',
];
