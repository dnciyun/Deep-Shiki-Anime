/// tracker 的**每日自动刷新**（用户 2026-10-11：「tracker加入每日刷新一次逻辑」）。
///
/// 背景：公共 tracker 列表（ngosang 的 `trackers_best.txt`）是**社区每天更新**的，
/// 而引擎的 tracker 是**进程启动参数**（`--trackers`）—— 用户不手动点一次、
/// 不重启边车，列表就永远停在装机那天。
///
/// 这一层要解决三件事，每一件都踩过坑：
/// 1. **何时该拉**：`trackerRefreshDue` 是纯函数（到期/未到期/时钟回拨），
///    时钟注入 ⇒ 单测不用等一天；
/// 2. **怎么拉**：多来源并发 + 合并去重 + 全部失败回落离线快照 —— 这套逻辑
///    原来只长在设置页的 `_updateTrackersFromSources()` 里。现在抽成
///    [TrackerRefreshService]：**设置页的「一键更新」与启动时的自动刷新共用同一份实现**，
///    绝不复制第二份（两份逻辑迟早跑偏：一边修了超时、另一边没有）。
/// 3. **回落时不许动时间戳**：快照不是"更新成功"。写成现在就等于宣布"今天更新过了"，
///    明天不会再试 —— 而联网失败恰恰是最需要明天再试的情况。
/// 4. **时机**：tracker 是边车的**进程启动参数**（`--trackers`），所以"首次启动"这一次
///    必须在 `engineBootstrapProvider.start()` **之前**就把列表拿到手、写进设置
///    （[ensureTrackersAtStartup]）；等边车起来了再写，这一轮的 `start()` 已经过去了。
///
/// 网络失败**绝不能让启动流程崩或卡住**：单来源 8s、整轮 20s 双保险，
/// 抓不到就用离线快照，调用方只拿到一个「有没有真的更新」的布尔语义。
library;

import 'dart:async';

import 'package:flutter/foundation.dart' show immutable;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../domain/error_text.dart';
import '../domain/models.dart';
import '../domain/trackers.dart';
import 'providers.dart';

/// 自动刷新周期：一天一次（用户要的就是"每日"）。
const Duration kTrackerRefreshInterval = Duration(hours: 24);

/// 单个来源的超时（原设置页就是 8s，保持不变）。
const Duration kTrackerSourceTimeout = Duration(seconds: 8);

/// **整轮**抓取的总上限（双保险）。
///
/// 为什么要它：`Future.wait` 只有全部 futures 都完成才回来；单来源超时虽然已经保证
/// 每个 future 都会结束，但只要有一条路径绕过了那个超时（例如将来换成别的取数方式），
/// 启动流程就会**挂在网络栈上**。20s 内必须出结果，超时就当"这一轮没拿到"。
const Duration kTrackerFetchTotalTimeout = Duration(seconds: 20);

/// 取一个来源的实现（可注入：单测不联网、不真等 8s）。
typedef TrackerFetch = Future<String> Function(Uri url);

/// 现在到点了吗？
///
/// * [lastUpdated] 为 null（从没更新过）→ 到期；
/// * 距上次 **满** [interval] → 到期；
/// * [now] **早于** [lastUpdated]（用户改系统时间 / 休眠唤醒后的时钟抖动）→ 也算到期。
///   理由：宁可不必要地拉一次，也不要因为"时间倒流"让列表永远不再更新。
bool trackerRefreshDue(
  DateTime? lastUpdated,
  DateTime now, {
  Duration interval = kTrackerRefreshInterval,
}) {
  if (lastUpdated == null) return true;
  if (now.isBefore(lastUpdated)) return true;
  return now.difference(lastUpdated) >= interval;
}

/// 来源的短名（提示里不糊一整条 URL）。
///
/// 从设置页搬过来的：那里原来有一份 `_sourceLabel`，现在两边共用这一个。
String trackerSourceLabel(String url) {
  for (final TrackerSourcePreset preset in trackerSourcePresets) {
    if (preset.url == url) return preset.label;
  }
  final Uri? uri = Uri.tryParse(url);
  if (uri == null || uri.host.isEmpty) return url;
  final List<String> segments = uri.path
      .split('/')
      .where((String s) => s.isNotEmpty)
      .toList(growable: false);
  if (segments.isEmpty) return uri.host;
  return '${uri.host}/${segments.last}';
}

/// 一个来源这次的结果（逐条说明，不糊成一句"失败了"）。
@immutable
class TrackerSourceResult {
  const TrackerSourceResult({required this.url, required this.label, this.count = 0, this.error});

  final String url;
  final String label;

  /// 解析出的 tracker 条数（0 = 没拿到）。
  final int count;

  /// 为什么没拿到（HTTP 码 / 网络异常文案 / 总超时）；null = 拿到了。
  final String? error;

  bool get ok => error == null && count > 0;

  String get note => ok ? '$label：$count 个' : '$label：${error ?? '空响应'}';
}

/// 一次多来源抓取的完整结果。
@immutable
class TrackerListResult {
  const TrackerListResult({
    required this.trackers,
    required this.fetchedFromSources,
    required this.sources,
  });

  /// 合并去重后的列表；一个来源都没拿到时 = [builtinTrackers]（离线快照）。
  final List<String> trackers;

  /// true = 至少有一个来源**真的**拿到了（false = 回落快照）。
  final bool fetchedFromSources;

  /// 逐来源结果（顺序与来源清单一致）。
  final List<TrackerSourceResult> sources;

  /// 写进设置 `extraTrackers` 的形态（引擎 `--trackers` 参数，逗号分隔）。
  String get text => trackerListText(trackers);

  /// 逐来源说明 + 结论（UI 直接显示这一句）。
  String get note {
    final String head;
    if (sources.isEmpty) {
      head = '没有配置来源：用了内置离线列表（${builtinTrackers.length} 个）';
    } else if (fetchedFromSources) {
      head =
          '已合并 ${sources.where((TrackerSourceResult s) => s.ok).length}/${sources.length} 个来源 '
          '→ ${trackers.length} 个 tracker';
    } else {
      head = '全部来源都没拿到：用了内置离线列表（${builtinTrackers.length} 个）';
    }
    if (sources.isEmpty) return head;
    return '$head｜${sources.map((TrackerSourceResult s) => s.note).join('｜')}';
  }
}

/// 多来源 tracker 抓取（设置页「一键更新」与启动时的每日刷新共用）。
class TrackerRefreshService {
  TrackerRefreshService({
    this.fetch,
    this.sourceTimeout = kTrackerSourceTimeout,
    this.totalTimeout = kTrackerFetchTotalTimeout,
    this.clock,
  });

  /// 注入的取数实现；null = 用 package:http 真联网。
  ///
  /// 用 `Future<String> Function(Uri)` 而不是 `http.Client`：单测要能按来源
  /// 分别伪造「拿到 / 空响应 / 抛异常 / 永不完成」四种行为，拿 client 去 mock
  /// 要多写一层假 Response，收益为零。
  final TrackerFetch? fetch;

  final Duration sourceTimeout;
  final Duration totalTimeout;

  /// 时钟（"这次算什么时候更新的"用；单测注入固定时间）。
  final DateTime Function()? clock;

  /// 当前时间：注入的时钟优先，否则走系统时钟。
  DateTime now() => (clock ?? DateTime.now)();

  /// 拉取一份可用的 tracker 列表。
  ///
  /// 并发（来源之间互不依赖，串行只是白等网络）+ 合并去重；
  /// **全部失败**才回落 [builtinTrackers]，`fetchedFromSources` 说明是哪一种。
  Future<TrackerListResult> fetchTrackerList(Iterable<String> sourceUrls) async {
    final List<String> urls = normalizeTrackerSourceUrls(sourceUrls);
    if (urls.isEmpty) {
      return const TrackerListResult(
        trackers: builtinTrackers,
        fetchedFromSources: false,
        sources: <TrackerSourceResult>[],
      );
    }

    final List<TrackerSourceResult> finished = <TrackerSourceResult>[];
    final List<List<String>> fetched = <List<String>>[];
    // 默认实现共用**一个** client（一轮最多几条来源；每个来源各起一个纯属浪费）。
    final http.Client? client = fetch == null ? http.Client() : null;
    final TrackerFetch fetchOne = fetch ?? (Uri url) => _get(client!, url);
    try {
      await Future.wait<void>(<Future<void>>[
        for (final String url in urls)
          _fetchSource(url, fetchOne, finished: finished, fetched: fetched),
      ]).timeout(totalTimeout);
    } on TimeoutException {
      // 总超时：**已经拿到的照用**（部分成功就是成功），没回来的记成"总超时"。
      for (final String url in urls) {
        if (finished.any((TrackerSourceResult r) => r.url == url)) continue;
        finished.add(
          TrackerSourceResult(
            url: url,
            label: trackerSourceLabel(url),
            error: '总超时（${totalTimeout.inSeconds}s）',
          ),
        );
      }
    } finally {
      client?.close();
    }

    final List<String> merged = mergeTrackerLists(fetched);
    return TrackerListResult(
      trackers: merged.isEmpty ? builtinTrackers : merged,
      fetchedFromSources: merged.isNotEmpty,
      sources: List<TrackerSourceResult>.unmodifiable(finished),
    );
  }

  Future<void> _fetchSource(
    String url,
    TrackerFetch fetch, {
    required List<TrackerSourceResult> finished,
    required List<List<String>> fetched,
  }) async {
    final String label = trackerSourceLabel(url);
    try {
      final String body = await fetch(Uri.parse(url)).timeout(sourceTimeout);
      final List<String> parsed = parseTrackerList(body);
      if (parsed.isEmpty) {
        finished.add(TrackerSourceResult(url: url, label: label, error: '空响应'));
        return;
      }
      fetched.add(parsed);
      finished.add(TrackerSourceResult(url: url, label: label, count: parsed.length));
    } catch (error) {
      finished.add(
        TrackerSourceResult(
          url: url,
          label: label,
          // describeFailure 把 SocketException/超时/TLS 翻成中文口径；
          // HTTP 码是我们自己造的异常，照原样说明（见 [_TrackerFetchException]）。
          error: error is _TrackerFetchException
              ? error.message
              : describeFailure(error).message,
        ),
      );
    }
  }

  Future<String> _get(http.Client client, Uri url) async {
    final http.Response response = await client.get(url);
    if (response.statusCode != 200) {
      throw _TrackerFetchException('HTTP ${response.statusCode}');
    }
    return response.body;
  }
}

/// 取数失败，且原因本身就该照原样告诉用户（HTTP 码）。
///
/// 为什么不用 `http.ClientException`：`describeFailure` 把所有 ClientException
/// 一律翻成「网络请求失败 → 去配代理」，而 404/403 是**来源那条 URL 自己**的问题 ——
/// 让用户去改代理配置是错的引导（原来设置页会显示「空响应/HTTP 404」，别把它弄丢）。
class _TrackerFetchException implements Exception {
  _TrackerFetchException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 一次自动刷新的结论。
@immutable
class TrackerRefreshOutcome {
  const TrackerRefreshOutcome({
    required this.due,
    required this.updated,
    required this.fellBack,
    required this.trackers,
    required this.updatedAt,
    required this.note,
  });

  /// 没到期时的空结果（什么都没做）。
  const TrackerRefreshOutcome.skipped()
    : due = false,
      updated = false,
      fellBack = false,
      trackers = '',
      updatedAt = null,
      note = '未到期：跳过（每日一次）';

  /// 这次是否到期（false = 直接跳过）。
  final bool due;

  /// **是否真的更新了列表** —— 调用方据此决定要不要重启边车。
  final bool updated;

  /// 是否回落了离线快照（true 时 [updated] 必为 false）。
  final bool fellBack;

  /// 新的 `extraTrackers`（未更新时为空串，调用方不该写）。
  final String trackers;

  /// 新的 `trackerListUpdatedAt`（未更新时为 null，调用方不该写）。
  final DateTime? updatedAt;

  /// 逐来源说明（写日志/提示用）。
  final String note;

  @override
  String toString() =>
      'TrackerRefreshOutcome(due=$due, updated=$updated, fellBack=$fellBack, note=$note)';
}

/// 把 tracker 那两个字段写回去的方式：**对"写入那一刻的最新设置"做合并**。
///
/// 为什么不是 `writeSettings(AppSettings next)`：整轮抓取最长
/// [kTrackerFetchTotalTimeout]（20s），而 [refreshTrackersIfDue] 手上的 `settings`
/// 是**拉取之前**的快照。用那份快照 `copyWith` 后整份 replace，会把这 20s 里用户
/// 写进去的其它设置（首启向导的 `downloadDir`、设置页保存、搜索页的源开关…）
/// **悄悄退回旧值**。回调收的是"合并函数"，由持有最新状态的控制器在 live state 上应用
/// （见 `SettingsController.patch`）。
typedef TrackerFieldsPatch = Future<void> Function(
  AppSettings Function(AppSettings current) mutate,
);

/// 到期才拉；**真的拿到**才写 `extraTrackers` + `trackerListUpdatedAt`。
///
/// [patchSettings] 由调用方给（riverpod 合并落盘 / 单测收集），这样纯逻辑可以脱离容器测。
/// 返回值里 `updated == true` 就是"要不要重启边车"的判据。
Future<TrackerRefreshOutcome> refreshTrackersIfDue({
  required AppSettings settings,
  required TrackerFieldsPatch patchSettings,
  TrackerRefreshService? service,
  DateTime? now,
}) async {
  final TrackerRefreshService svc = service ?? TrackerRefreshService();
  final DateTime clock = now ?? svc.now();
  if (!trackerRefreshDue(settings.trackerListUpdatedAt, clock)) {
    return const TrackerRefreshOutcome.skipped();
  }

  final TrackerListResult result = await svc.fetchTrackerList(settings.trackerSourceUrls);
  if (!result.fetchedFromSources) {
    // ⚠️ 回落快照：时间戳与 extraTrackers **都不动**。
    // * 时间戳一动，明天就不再试（"昨天更新过了"是假的）；
    // * extraTrackers 不动，是为了不让一次网络抖动把用户手里那份好列表
    //   换成内置快照 —— 引擎在没有 `--trackers` 时本来就有自己的内置列表。
    return TrackerRefreshOutcome(
      due: true,
      updated: false,
      fellBack: true,
      trackers: '',
      updatedAt: null,
      note: result.note,
    );
  }

  // ⚠️ 只合并这两个字段，**不许整份覆盖**：抓取期间用户可能改了别的设置
  // （首启向导、设置页保存、搜索页开关…），陈旧快照整份写回会把它们退回旧值。
  await patchSettings(
    (AppSettings current) => current.copyWith(
      extraTrackers: result.text,
      trackerListUpdatedAt: clock,
    ),
  );
  return TrackerRefreshOutcome(
    due: true,
    updated: true,
    fellBack: false,
    trackers: result.text,
    updatedAt: clock,
    note: result.note,
  );
}

/// 启动接线（装配根唯一需要调的一行）：到期才拉 → 真的更新了就重启边车。
///
/// 为什么要用 [ProviderContainer] 而不是 `Ref`：调用方是 `main.dart`（装配根），
/// 它手上就是容器。
///
/// 边界（都刻意"吞掉"，因为自动刷新不是功能主路径）：
/// * 边车**没在跑** → 不动它（新参数下一次启动自然带上，没必要为一个 tracker
///   列表把引擎拉起来）；
/// * 重启失败 → 设置已经落盘，不抛：用户到设置页点一次「保存并生效」即可，
///   而启动流程绝不能因为一次网络/进程问题崩掉。
Future<TrackerRefreshOutcome> refreshTrackersAtStartup(
  ProviderContainer container, {
  TrackerRefreshService? service,
  DateTime? now,
}) async {
  final AppSettings settings = container.read(settingsProvider);
  final TrackerRefreshOutcome outcome = await refreshTrackersIfDue(
    settings: settings,
    patchSettings: (AppSettings Function(AppSettings) mutate) =>
        container.read(settingsProvider.notifier).patch(mutate),
    service: service,
    now: now,
  );
  if (!outcome.updated) return outcome;

  // tracker 是**进程启动参数**（`--trackers`）：真的换了列表就得重启边车才生效。
  if (!container.read(engineBootstrapProvider).running) return outcome;
  try {
    await container.read(lifecyclePortProvider).applySettings(container.read(settingsProvider));
  } catch (_) {
    // 见上面的边界说明：不抛。
  }
  return outcome;
}

/// **首次启动**（从没更新过 tracker 列表）时先把列表拉回来，好让紧接着那次边车
/// `start()` 就带上 `--trackers`（用户 2026-10-11：「trackers 首次启动自动加载一次」）。
///
/// 为什么单开这一支：[refreshTrackersAtStartup] 要等边车**已经在跑**才谈得上"用上"
/// （它靠 `applySettings` 重启边车）；而第一次启动时边车还没起（下载目录为空的首次
/// 运行甚至不起），抓回来的列表虽然写进了设置，却**赶不上**那条 `start()` ——
/// 用户看到的"自动加载一次"就等于什么都没发生。
///
/// 边界（时机上的，抓取逻辑一行都不重复：全部复用 [refreshTrackersIfDue]）：
/// * **只等"从没更新过"这一种情况**。已经更新过的每日刷新仍走
///   [refreshTrackersAtStartup] 的非阻塞路径 —— 不该为一次例行刷新把引擎启动推迟
///   最多 [kTrackerFetchTotalTimeout]（20s）；
/// * 关键不变式（与 [refreshTrackersIfDue] 同一条）：**回落快照不许写
///   `trackerListUpdatedAt`** —— 写了明天就不再试，而联网失败恰恰最需要明天再试；
///   extraTrackers 同样不写，免得一次网络抖动把用户手里那份好列表换成内置快照；
/// * 返回值 `due == false`（skipped）表示"这一轮压根没试"，调用方据此决定要不要再补
///   一次非阻塞的每日刷新 —— 避免同一个启动里对着网络打两轮。
Future<TrackerRefreshOutcome> ensureTrackersAtStartup(
  ProviderContainer container, {
  TrackerRefreshService? service,
  DateTime? now,
}) async {
  final AppSettings settings = container.read(settingsProvider);
  if (settings.trackerListUpdatedAt != null) {
    return const TrackerRefreshOutcome.skipped();
  }
  return refreshTrackersIfDue(
    settings: settings,
    patchSettings: (AppSettings Function(AppSettings) mutate) =>
        container.read(settingsProvider.notifier).patch(mutate),
    service: service,
    now: now,
  );
}
