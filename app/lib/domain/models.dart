/// DSAnima 宿主侧领域模型（视图约定）。
///
/// 字段名与 `docs/specs/2026-10-09-dsanima-design.md` §3.6 / §4.2 / §4.3 逐字对齐，
/// 由 `state/ports.dart` 里的适配器从 `dsanima_core` 的真实类型转换而来。
///
/// 为什么要多这一层：UI 只依赖本文件 → widget 测试可以注入假数据，不用联网、
/// 不用起引擎；`dsanima_core` 与 `shikiin` 并行落地期间，UI 也能独立 analyze/测试。
library;

import 'package:flutter/foundation.dart';

import 'trackers.dart' show kDefaultTrackerSourceUrls;
// 观看记录的元数据（[NowPlaying.watch] 用它；那份文件只依赖 kv + foundation，不会成环）。
import 'watch_history.dart' show WatchMeta;

// ─────────────────────────────────────────────────────────────────────────────
// 设置
// ─────────────────────────────────────────────────────────────────────────────

/// 源抓取代理模式（spec §4.2：仅作用于源抓取，不影响边车串流回环直连）。
enum ProxyMode {
  none('none', '不使用代理'),
  http('http', 'HTTP 代理'),
  socks5('socks5', 'SOCKS5 代理');

  const ProxyMode(this.wireName, this.label);
  final String wireName;
  final String label;

  static ProxyMode fromName(String? name) =>
      ProxyMode.values.firstWhere((m) => m.wireName == name, orElse: () => ProxyMode.none);
}

/// 省流量策略（spec §4.3 `BandwidthPolicy`）。
@immutable
class BandwidthPolicy {
  /// 提前预热后几集（第三十八轮；用户原话「添加逻辑默认关闭，可提前预热后几集」）。
  ///
  /// 0 = **关闭（默认）**：只有正在播的那一集会被启动 —— 也就是"不自动往队列里加任务"。
  /// 1–3 = 起播时就把后面 N 集加进队列并启动，点「下一集」时种子已经在引擎里、
  /// 元数据早已就绪，不用再等「补磁力 → addMagnet 等元数据」那一段。
  /// 它是**真下载**：会提前吃带宽和磁盘（设置页文案照这个说）。
  final int preheatAhead;

  /// true ⇒ 播放结束/切集时对该 torrent `pause()`（不再上传）。
  final bool stopSeedingAfterPlayback;

  /// true ⇒ 播完删除已看文件。
  final bool deleteAfterPlayed;

  /// 并发下载数（1–3）。
  final int maxConcurrent;

  /// 省流量列表：命中的番剧/规则一律不预热。
  final List<String> excludePatterns;

  const BandwidthPolicy({
    this.preheatAhead = 0,
    this.stopSeedingAfterPlayback = true,
    this.deleteAfterPlayed = false,
    this.maxConcurrent = 1,
    this.excludePatterns = const <String>[],
  });

  /// 生效档位：夹到 0..3（core 那份策略同名 getter，两边口径必须一致）。
  int get effectivePreheatAhead =>
      preheatAhead < 0 ? 0 : (preheatAhead > 3 ? 3 : preheatAhead);

  BandwidthPolicy copyWith({
    int? preheatAhead,
    bool? stopSeedingAfterPlayback,
    bool? deleteAfterPlayed,
    int? maxConcurrent,
    List<String>? excludePatterns,
  }) => BandwidthPolicy(
    preheatAhead: preheatAhead ?? this.preheatAhead,
    stopSeedingAfterPlayback: stopSeedingAfterPlayback ?? this.stopSeedingAfterPlayback,
    deleteAfterPlayed: deleteAfterPlayed ?? this.deleteAfterPlayed,
    maxConcurrent: maxConcurrent ?? this.maxConcurrent,
    excludePatterns: excludePatterns ?? this.excludePatterns,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'preheatAhead': preheatAhead,
    'stopSeedingAfterPlayback': stopSeedingAfterPlayback,
    'deleteAfterPlayed': deleteAfterPlayed,
    'maxConcurrent': maxConcurrent,
    'excludePatterns': excludePatterns,
  };

  /// ⚠️ 旧键 `prefetchNext` **故意不读**（第三十八轮）：旧默认是 `true`
  /// （下完本集自动下下一集），读了它等于把用户刚要求的"默认关闭"又打开回去。
  factory BandwidthPolicy.fromJson(Map<Object?, Object?>? json) {
    if (json == null) return const BandwidthPolicy();
    const fallback = BandwidthPolicy();
    return BandwidthPolicy(
      preheatAhead: (json['preheatAhead'] as num?)?.toInt() ?? fallback.preheatAhead,
      stopSeedingAfterPlayback:
          json['stopSeedingAfterPlayback'] as bool? ?? fallback.stopSeedingAfterPlayback,
      deleteAfterPlayed: json['deleteAfterPlayed'] as bool? ?? fallback.deleteAfterPlayed,
      maxConcurrent: (json['maxConcurrent'] as num?)?.toInt() ?? fallback.maxConcurrent,
      excludePatterns:
          (json['excludePatterns'] as List<Object?>?)
              ?.map((Object? e) => e.toString())
              .toList(growable: false) ??
          const <String>[],
    );
  }
}

/// 搜索模式（用户 2026-10-12 第十四轮：「添加聚合搜索，聚合全部源，默认为聚合源……
/// 设置中切换回单独源模式」）。
///
/// * [aggregate] = **默认**：一次搜索把「聚合 / 动漫 / 全集」那一档里的源全部并发问一遍，
///   合并去重后给一页 20 条（见 `domain/aggregate.dart`）；
/// * [single] = 回到本轮之前的形态：搜索页顶部的源下拉选**一个**源，只问它。
enum SearchMode {
  aggregate('aggregate'),
  single('single');

  const SearchMode(this.wireName);
  final String wireName;

  /// 认不出的值（老配置/乱码）一律回退 [SearchMode.aggregate] —— 这是本轮定的默认。
  static SearchMode fromName(String? name) {
    for (final SearchMode m in SearchMode.values) {
      if (m.wireName == name) return m;
    }
    return SearchMode.aggregate;
  }
}

/// 宿主全局设置。持久化在 Hive `settings` box（JSON 编码）。
@immutable
class AppSettings {
  /// 下载目录；null = 未设置（首启向导要求设置后才能起引擎）。
  final String? downloadDir;

  /// 引擎可执行文件路径；null = 由 dsanima_core 的 locator 自动查找。
  final String? enginePath;

  final ProxyMode proxyMode;
  final String proxyHost;
  final int proxyPort;
  final String proxyUsername;
  final String proxyPassword;

  /// 0 = 不限。
  final int uploadLimitKbps;
  final int downloadLimitKbps;

  /// 播完不强制做种（引擎 `--seed-ratio`）。
  final double seedRatio;

  final BandwidthPolicy bandwidth;

  /// 源缓存 TTL（秒）：search/latest。
  final int sourceCacheTtlSeconds;

  /// `detail` 缓存 TTL（秒）。
  final int sourceDetailCacheTtlSeconds;

  /// 每 host 最小请求间隔（毫秒）。
  final int sourceRequestIntervalMs;

  /// 默认源 id（`mikan` / `nyaa` / `rss:<订阅id>` …）。
  ///
  /// 默认 mikan：番剧的中文标题与更新表都在那边，nyaa 更适合按关键字找生肉/合集。
  /// **只在 [SearchMode.single] 下有效**（聚合模式下用的是「动漫/全集」分区里的一组源）。
  final String defaultSourceId;

  /// 搜索模式（第 14 轮，默认聚合，见 [SearchMode]）。
  final SearchMode searchMode;

  /// 聚合搜索里**不勾**的源 id（第 15 轮：用户「默认全开，可选择几个源搜索」）。
  ///
  /// 存排除名单而不是勾选名单：空集合天然就是"全开"，而且**新出现的源自动算勾上**
  /// —— 刚打开的 sukebei、新加的自定义 RSS 订阅，不需要用户再进面板点一次。
  /// 名单里留着一个已经不存在的 id 是**故意的**（sukebei 关掉又打开，用户当初取消的
  /// 选择仍然算数），所以不要清理它。语义详见 `domain/aggregate.dart`。
  final List<String> aggregateExcludedSourceIds;

  /// 搜索页「字幕组」筛选勾选的组（**归一化 key**，见 `domain/subtitle_groups.dart`）。
  ///
  /// 第四十五轮（用户：「在搜索中加入字幕组筛选」，并选定「落盘记住」）。空 = 不限。
  /// 存归一化后的 key 而不是原始写法：同一个组在各站会写成 `桜都字幕组` / `桜都字幕組` /
  /// `桜都`，只有 key 能跨源对上（面板上的展示名另取）。
  final List<String> subtitleGroupFilter;

  /// 最近用过的字幕组 key（**新的在前**），只用于面板排序（第四十五轮）。
  ///
  /// 为什么单独存：勾选会被清掉，但"我常看这家的"这件事没变 —— 预置名单只有 33 家，
  /// 覆盖不到长尾里那些"一部番一个组"的情况（实测 336 个组名里 30% 只出现一次）。
  final List<String> recentSubtitleGroups;

  /// 播完自动下一集（可关）。
  final bool autoPlayNext;

  /// 首启向导是否已完成。
  final bool firstRunCompleted;

  /// 追加的公共 tracker（逗号分隔，引擎 `--trackers`）。
  final String extraTrackers;

  /// 一键更新 tracker 时抓取的**来源清单**（用户 2026-10-11：要能导入 URL、
  /// 也要能用多条）。空 = 没有来源，一键更新只能用离线快照。
  final List<String> trackerSourceUrls;

  /// 封面缓存自动清理周期（天，用户 2026-10-11 第二阶段清单第 7 项）。
  ///
  /// **0 = 不清除**（用户可选）；默认 30 天（"一个月自动清"）。
  /// `HttpCoverCache.maxAge` 只决定"过期就重新下载"，过期文件原来**从不删除** ⇒
  /// `<支持目录>/cache/covers` 只涨不减。
  final int coverCacheMaxAgeDays;

  /// 内置外观（新拟态）：`'light'`（默认）或 `'dark'`。
  ///
  /// 旧值兼容：曾为 `'A' / 'C' / 'B'`（三套暗色主题，已删除）。
  /// [themeBrightness] 会把无法识别的旧值一律回退为 `light`，不崩、不丢其它设置。
  final String themeId;

  /// 「封面大小」（决策 F23）：`'s' / 'm'（默认）/ 'l'` —— 三档只影响今日更新网格的
  /// 宽度封顶（172 / 208 / 250），解析走 `DsCoverSize.fromCode`（非法值 → 中）。
  final String homeCoverSize;

  /// 「轮播封面」（决策 F24）：`'landscape'（默认，3:2 横版）/ 'portrait'（竖版，看完整封面）`。
  final String carouselShape;

  /// 「轮播大小」（决策 F24）：`'s' / 'm'（默认）/ 'l'` —— 主卡 + 邻卡 + 整块高度等比。
  final String carouselSize;

  /// 「开启做种」开关（spec §7.1 Q2，**默认关**）。
  final bool seedEnabled;

  /// 「后台常驻」开关（spec §7.3 Q14，**默认关**）：关窗后继续下载 + 托盘常驻。
  final bool backgroundResident;

  /// nyaa 是否同时查 sukebei（spec §7.1 Q4，默认关）。
  final bool sukebeiEnabled;

  /// 「观看记录」保留天数：**0 = 永不自动删除**。
  ///
  /// ⚠️ **默认从 30 天改成 0（不删除）**：用户 2026-10-15 第三十三轮
  /// 「历史记录从默认30天改为不删」。老数据的一次性迁移见
  /// `state/history_retention_migration.dart`（**只有旧默认值 30 会被改**，
  /// 手选过 7/90 的人不动 —— 那是显式选择，不该被我们抹掉）。
  ///
  /// 清理发生在**读取记录时**（`WatchHistoryController.build`）与**每次写入之后**，
  /// 不做后台定时器：这个项目的其它清理（封面缓存、源缓存）也都是"用的时候顺手清"，
  /// 后台常驻的定时器反而是要额外维护的生命周期。
  final int historyRetentionDays;

  /// 录制观看进度（与观看记录一起写；用户第二十七轮「添加观看进度逻辑同观看记录
  /// 一起记录，可在设置关闭」）。
  ///
  /// 关闭后：**只记时间**（哪部番哪一集什么时候看的），不再更新已播时长/进度，
  /// 也不再由进度自动打「已看过」的勾（手动打勾照旧可用）。
  final bool recordWatchProgress;

  /// 鼠标移到**画面正中**也唤起播放器那两条栏（默认关 = 保留第十四/二十六轮的语义：
  /// 只有上下热区才唤起）。用户第二十七轮：「画面正中仍不唤起逻辑可在设置中关闭」。
  final bool wakeChromeAtCenter;

  /// 「更新源」：`owner/repo`（第三十九轮：检查更新走 GitHub Releases）。
  ///
  /// **默认空 = 用内置仓库**（第四十一轮）：`dsanima_core` 的 `effectiveUpdateRepo`
  /// 会把空值换成 `kBuiltinUpdateRepo` —— 从哪更新是产品的一部分，不该要求用户去仓库
  /// 页面抄 `<用户名>/<仓库名>`。所以这一格是**覆盖**入口：想换成自己的 fork 或别的
  /// 仓库才填，清空就回到内置（老设置里存的空串因此自动享受到内置值，不用迁移）。
  ///
  /// 用户粘整条地址也行（`https://github.com/owner/repo`、`.git`、发布页、
  /// 甚至 API 地址），由 `dsanima_core` 的 `normalizeRepoSlug` 收成 `owner/repo`。
  final String updateRepo;

  /// **可选**的 GitHub 访问令牌（第四十轮；默认空 = 匿名请求）。
  ///
  /// 为什么要有它 —— 检查更新走的是**匿名**接口，而这三种情况下匿名读不到：
  /// * 仓库是私有的（匿名 404）；
  /// * 账号被 GitHub 限制可见性（flagged）—— 连未登录访客看仓库主页都是 404，
  ///   2026-10-16 在本项目的仓库上真撞到过（带 token 一切正常）；
  /// * 匿名额度只有 60 次/小时。
  /// 填一个**只读**令牌（fine-grained，只需 `Contents: Read-only`）三种一起解决。
  ///
  /// ⚠️ 它**明文存在本机设置里**（`DSAnima-data/store`，与其它设置同一份），所以：
  /// 只填只读令牌、别填带写权限的；界面按密码框显示，日志与报错里都不会打印它。
  final String updateToken;

  /// 内置 tracker 列表最近一次一键更新的时间。
  final DateTime? trackerListUpdatedAt;

  /// 首启合规声明是否已被用户确认（spec §7.3 Q20①）。
  final bool complianceAccepted;

  const AppSettings({
    this.downloadDir,
    this.enginePath,
    this.proxyMode = ProxyMode.none,
    this.proxyHost = '127.0.0.1',
    this.proxyPort = 1080,
    this.proxyUsername = '',
    this.proxyPassword = '',
    this.uploadLimitKbps = 100,
    this.downloadLimitKbps = 0,
    this.seedRatio = 0,
    this.bandwidth = const BandwidthPolicy(),
    this.sourceCacheTtlSeconds = 300,
    this.sourceDetailCacheTtlSeconds = 86400,
    this.sourceRequestIntervalMs = 1200,
    this.defaultSourceId = 'mikan',
    this.searchMode = SearchMode.aggregate,
    this.aggregateExcludedSourceIds = const <String>[],
    this.subtitleGroupFilter = const <String>[],
    this.recentSubtitleGroups = const <String>[],
    this.autoPlayNext = true,
    this.firstRunCompleted = false,
    this.extraTrackers = '',
    this.trackerSourceUrls = kDefaultTrackerSourceUrls,
    this.coverCacheMaxAgeDays = 30,
    this.themeId = 'w_orange',
    this.homeCoverSize = 'm',
    this.carouselShape = 'landscape',
    this.carouselSize = 'm',
    this.seedEnabled = false,
    this.backgroundResident = false,
    this.sukebeiEnabled = false,
    this.historyRetentionDays = 0,
    this.recordWatchProgress = true,
    this.wakeChromeAtCenter = false,
    this.updateRepo = '',
    this.updateToken = '',
    this.trackerListUpdatedAt,
    this.complianceAccepted = false,
  });

  AppSettings copyWith({
    String? downloadDir,
    /// true = **真的把下载目录清成 null**（用户清空输入框 = "不要目录，用默认"）。
    ///
    /// 为什么需要这个开关：`copyWith` 的 `?? this.x` 语义下传 null 表示"不改"，
    /// 于是"清空输入框"永远清不掉已有的值 —— 输入框看着是空的、设置里还是旧路径，
    /// 正是用户最容易被骗的那种状态（设置页/首启向导两处都踩过）。
    bool clearDownloadDir = false,
    String? enginePath,
    /// true = **真的把引擎路径清成 null**（用户清空输入框 = "留空，自动查找"）。
    ///
    /// 与 [clearDownloadDir] 同一条理由：`copyWith(enginePath: null)` 的语义是"不改"，
    /// 而设置页与首启向导的标签都写着「留空 = 自动查找」—— 没有这个开关，"留空"
    /// 就是一句空话：框里空着、设置里还是旧路径，脏标记也没变化（保存按钮一直灰着）。
    bool clearEnginePath = false,
    ProxyMode? proxyMode,
    String? proxyHost,
    int? proxyPort,
    String? proxyUsername,
    String? proxyPassword,
    int? uploadLimitKbps,
    int? downloadLimitKbps,
    double? seedRatio,
    BandwidthPolicy? bandwidth,
    int? sourceCacheTtlSeconds,
    int? sourceDetailCacheTtlSeconds,
    int? sourceRequestIntervalMs,
    String? defaultSourceId,
    SearchMode? searchMode,
    List<String>? aggregateExcludedSourceIds,
    List<String>? subtitleGroupFilter,
    List<String>? recentSubtitleGroups,
    bool? autoPlayNext,
    bool? firstRunCompleted,
    String? extraTrackers,
    List<String>? trackerSourceUrls,
    int? coverCacheMaxAgeDays,
    String? themeId,
    String? homeCoverSize,
    String? carouselShape,
    String? carouselSize,
    bool? seedEnabled,
    bool? backgroundResident,
    bool? sukebeiEnabled,
    int? historyRetentionDays,
    bool? recordWatchProgress,
    bool? wakeChromeAtCenter,
    String? updateRepo,
    String? updateToken,
    DateTime? trackerListUpdatedAt,
    bool? complianceAccepted,
  }) => AppSettings(
    downloadDir: clearDownloadDir ? null : (downloadDir ?? this.downloadDir),
    enginePath: clearEnginePath ? null : (enginePath ?? this.enginePath),
    proxyMode: proxyMode ?? this.proxyMode,
    proxyHost: proxyHost ?? this.proxyHost,
    proxyPort: proxyPort ?? this.proxyPort,
    proxyUsername: proxyUsername ?? this.proxyUsername,
    proxyPassword: proxyPassword ?? this.proxyPassword,
    uploadLimitKbps: uploadLimitKbps ?? this.uploadLimitKbps,
    downloadLimitKbps: downloadLimitKbps ?? this.downloadLimitKbps,
    seedRatio: seedRatio ?? this.seedRatio,
    bandwidth: bandwidth ?? this.bandwidth,
    sourceCacheTtlSeconds: sourceCacheTtlSeconds ?? this.sourceCacheTtlSeconds,
    sourceDetailCacheTtlSeconds: sourceDetailCacheTtlSeconds ?? this.sourceDetailCacheTtlSeconds,
    sourceRequestIntervalMs: sourceRequestIntervalMs ?? this.sourceRequestIntervalMs,
    defaultSourceId: defaultSourceId ?? this.defaultSourceId,
    searchMode: searchMode ?? this.searchMode,
    aggregateExcludedSourceIds: aggregateExcludedSourceIds ?? this.aggregateExcludedSourceIds,
    subtitleGroupFilter: subtitleGroupFilter ?? this.subtitleGroupFilter,
    recentSubtitleGroups: recentSubtitleGroups ?? this.recentSubtitleGroups,
    autoPlayNext: autoPlayNext ?? this.autoPlayNext,
    firstRunCompleted: firstRunCompleted ?? this.firstRunCompleted,
    extraTrackers: extraTrackers ?? this.extraTrackers,
    trackerSourceUrls: trackerSourceUrls ?? this.trackerSourceUrls,
    coverCacheMaxAgeDays: coverCacheMaxAgeDays ?? this.coverCacheMaxAgeDays,
    themeId: themeId ?? this.themeId,
    homeCoverSize: homeCoverSize ?? this.homeCoverSize,
    carouselShape: carouselShape ?? this.carouselShape,
    carouselSize: carouselSize ?? this.carouselSize,
    seedEnabled: seedEnabled ?? this.seedEnabled,
    backgroundResident: backgroundResident ?? this.backgroundResident,
    sukebeiEnabled: sukebeiEnabled ?? this.sukebeiEnabled,
    historyRetentionDays: historyRetentionDays ?? this.historyRetentionDays,
    recordWatchProgress: recordWatchProgress ?? this.recordWatchProgress,
    wakeChromeAtCenter: wakeChromeAtCenter ?? this.wakeChromeAtCenter,
    updateRepo: updateRepo ?? this.updateRepo,
    updateToken: updateToken ?? this.updateToken,
    trackerListUpdatedAt: trackerListUpdatedAt ?? this.trackerListUpdatedAt,
    complianceAccepted: complianceAccepted ?? this.complianceAccepted,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'downloadDir': downloadDir,
    'enginePath': enginePath,
    'proxyMode': proxyMode.wireName,
    'proxyHost': proxyHost,
    'proxyPort': proxyPort,
    'proxyUsername': proxyUsername,
    'proxyPassword': proxyPassword,
    'uploadLimitKbps': uploadLimitKbps,
    'downloadLimitKbps': downloadLimitKbps,
    'seedRatio': seedRatio,
    'bandwidth': bandwidth.toJson(),
    'sourceCacheTtlSeconds': sourceCacheTtlSeconds,
    'sourceDetailCacheTtlSeconds': sourceDetailCacheTtlSeconds,
    'sourceRequestIntervalMs': sourceRequestIntervalMs,
    'defaultSourceId': defaultSourceId,
    'searchMode': searchMode.wireName,
    'aggregateExcludedSourceIds': aggregateExcludedSourceIds,
    'subtitleGroupFilter': subtitleGroupFilter,
    'recentSubtitleGroups': recentSubtitleGroups,
    'autoPlayNext': autoPlayNext,
    'firstRunCompleted': firstRunCompleted,
    'extraTrackers': extraTrackers,
    'trackerSourceUrls': trackerSourceUrls,
    'coverCacheMaxAgeDays': coverCacheMaxAgeDays,
    'themeId': themeId,
    'homeCoverSize': homeCoverSize,
    'carouselShape': carouselShape,
    'carouselSize': carouselSize,
    'seedEnabled': seedEnabled,
    'backgroundResident': backgroundResident,
    'sukebeiEnabled': sukebeiEnabled,
    'historyRetentionDays': historyRetentionDays,
    'recordWatchProgress': recordWatchProgress,
    'wakeChromeAtCenter': wakeChromeAtCenter,
    'updateRepo': updateRepo,
    'updateToken': updateToken,
    'trackerListUpdatedAt': trackerListUpdatedAt?.toIso8601String(),
    'complianceAccepted': complianceAccepted,
  };

  factory AppSettings.fromJson(Map<Object?, Object?>? json) {
    if (json == null) return const AppSettings();
    const d = AppSettings();
    int intOr(Object? v, int fallback) => (v as num?)?.toInt() ?? fallback;
    // ⚠️ 第二十九轮改成**类型安全**的读法：旧写法 `v as String?` 遇到脏数据（比如
    // `homeCoverSize: 42`）会抛 TypeError，直接让设置加载崩掉；现在类型不对就回落默认值，
    // 与「AppSettings 缺字段/脏数据容错（不崩、回落默认值）」的既有口径一致。
    String strOr(Object? v, String fallback) => v is String ? v : fallback;
    return AppSettings(
      downloadDir: json['downloadDir'] as String?,
      enginePath: json['enginePath'] as String?,
      proxyMode: ProxyMode.fromName(json['proxyMode'] as String?),
      proxyHost: strOr(json['proxyHost'], d.proxyHost),
      proxyPort: intOr(json['proxyPort'], d.proxyPort),
      proxyUsername: strOr(json['proxyUsername'], d.proxyUsername),
      proxyPassword: strOr(json['proxyPassword'], d.proxyPassword),
      uploadLimitKbps: intOr(json['uploadLimitKbps'], d.uploadLimitKbps),
      downloadLimitKbps: intOr(json['downloadLimitKbps'], d.downloadLimitKbps),
      seedRatio: (json['seedRatio'] as num?)?.toDouble() ?? d.seedRatio,
      bandwidth: BandwidthPolicy.fromJson(json['bandwidth'] as Map<Object?, Object?>?),
      sourceCacheTtlSeconds: intOr(json['sourceCacheTtlSeconds'], d.sourceCacheTtlSeconds),
      sourceDetailCacheTtlSeconds: intOr(
        json['sourceDetailCacheTtlSeconds'],
        d.sourceDetailCacheTtlSeconds,
      ),
      sourceRequestIntervalMs: intOr(json['sourceRequestIntervalMs'], d.sourceRequestIntervalMs),
      defaultSourceId: strOr(json['defaultSourceId'], d.defaultSourceId),
      searchMode: SearchMode.fromName(json['searchMode'] as String?),
      aggregateExcludedSourceIds: stringListFromJson(json['aggregateExcludedSourceIds']),
      subtitleGroupFilter: stringListFromJson(json['subtitleGroupFilter']),
      recentSubtitleGroups: stringListFromJson(json['recentSubtitleGroups']),
      autoPlayNext: json['autoPlayNext'] as bool? ?? d.autoPlayNext,
      firstRunCompleted: json['firstRunCompleted'] as bool? ?? d.firstRunCompleted,
      extraTrackers: strOr(json['extraTrackers'], d.extraTrackers),
      trackerSourceUrls: trackerSourceUrlsFromJson(json['trackerSourceUrls'], d.trackerSourceUrls),
      coverCacheMaxAgeDays: intOr(json['coverCacheMaxAgeDays'], d.coverCacheMaxAgeDays),
      themeId: strOr(json['themeId'], d.themeId),
      // 旧 JSON 里的 `simpleMode` 键**故意不读**（第二十九轮已删除该设置，不崩不丢其它项）。
      homeCoverSize: strOr(json['homeCoverSize'], d.homeCoverSize),
      carouselShape: strOr(json['carouselShape'], d.carouselShape),
      carouselSize: strOr(json['carouselSize'], d.carouselSize),
      seedEnabled: json['seedEnabled'] as bool? ?? d.seedEnabled,
      backgroundResident: json['backgroundResident'] as bool? ?? d.backgroundResident,
      sukebeiEnabled: json['sukebeiEnabled'] as bool? ?? d.sukebeiEnabled,
      historyRetentionDays: intOr(json['historyRetentionDays'], d.historyRetentionDays),
      recordWatchProgress: json['recordWatchProgress'] as bool? ?? d.recordWatchProgress,
      wakeChromeAtCenter: json['wakeChromeAtCenter'] as bool? ?? d.wakeChromeAtCenter,
      updateRepo: strOr(json['updateRepo'], d.updateRepo),
      updateToken: strOr(json['updateToken'], d.updateToken),
      trackerListUpdatedAt: DateTime.tryParse((json['trackerListUpdatedAt'] as String?) ?? ''),
      complianceAccepted: json['complianceAccepted'] as bool? ?? d.complianceAccepted,
    );
  }

  /// 黑色系外观的 code 集合（与 `DsAppearance.isDark` 保持同步：新增黑色系外观时两处都要改）。
  ///
  /// 刻意不 import Flutter：domain 层只做字符串判断，UI 层再翻成 `DsAppearance`。
  /// 旧值 `'light' / 'dark' / 'A' / 'C' / 'B' / 乱码` 都在这里落 false（迁移交 `DsAppearance.fromCode`）。
  static const Set<String> darkThemeCodes = <String>{
    'b_neon',
    'b_electric',
    'b_mono',
    'b_red',
  };
  bool get isDarkTheme => darkThemeCodes.contains(themeId);

  /// tracker 来源清单的解析（`AppSettings.fromJson` 用）。
  ///
  /// 语义刻意分两种：**字段缺失/类型不对 = 老配置**，给默认的 best 一条（升级后
  /// 一键更新照旧能用）；**显式写成 `[]` = 用户把来源全删了**，就保持空 —— 否则
  /// 用户删掉的来源下次启动又长回来。条目做 trim + 去重，坏项丢掉。
  static List<String> trackerSourceUrlsFromJson(Object? raw, List<String> fallback) {
    if (raw is! List) return fallback;
    final List<String> out = <String>[];
    for (final Object? item in raw) {
      if (item is! String) continue;
      final String value = item.trim();
      if (value.isEmpty || out.contains(value)) continue;
      out.add(value);
    }
    return out;
  }

  /// 字符串清单的解析（[aggregateExcludedSourceIds] 用）。
  ///
  /// 这里**没有**"字段缺失 vs 显式空表"的区别：排除名单的默认值本来就是空集 = 全开，
  /// 两种情况的语义完全一样。条目 trim + 去重 + 丢掉非字符串。
  static List<String> stringListFromJson(Object? raw) {
    if (raw is! List) return const <String>[];
    final List<String> out = <String>[];
    for (final Object? item in raw) {
      if (item is! String) continue;
      final String value = item.trim();
      if (value.isEmpty || out.contains(value)) continue;
      out.add(value);
    }
    return out;
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 源（spec §4.2）
// ─────────────────────────────────────────────────────────────────────────────

/// 源分区（与 core 的 `SourcePartition` 一一对应，装配层负责翻译）。
///
/// 用途只有一个：第 14 轮「聚合搜索」的「动漫 / 全集」两档按它筛源
/// （见 `domain/aggregate.dart`）。[other] 只出现在「聚合」档里。
enum SourcePartition { anime, collection, other }

/// 源下拉项（nyaa 动漫区 / mikan / 自定义 RSS 订阅）。
@immutable
class SourceOption {
  final String id;
  final String displayName;
  final bool supportsSearch;

  /// 这个源属于哪个分区（core 注册时声明，见 `SourceRegistry.partitionOf`）。
  ///
  /// 默认 [SourcePartition.anime]：绝大多数源是动漫分区，只有四个「全集/合集」
  /// 实例和 sukebei 需要显式声明。
  final SourcePartition partition;

  const SourceOption({
    required this.id,
    required this.displayName,
    this.supportsSearch = true,
    this.partition = SourcePartition.anime,
  });
}

/// 一条搜索结果 / 订阅项。字段名与 spec §4.2 `SourceItem` 一致。
@immutable
class SourceItemView {
  final String id;
  final String? title;
  final String sourceId;
  final Uri? detailUrl;
  final String? torrentUrl;
  final String? magnet;
  final String? infoHash;
  final int? sizeBytes;
  final int? seeders;
  final int? leechers;
  final int? downloads;
  final DateTime? publishedAt;
  final String? category;

  /// 字幕组 / 发布组。
  final String? group;

  /// 标题提取的集数提示：'01'、'S01E02'、'第3话'。
  final List<String> episodeHints;

  /// 源特有字段（分辨率、语言、字幕等，spec §4.4 由 TitleParser 写入）。
  final Map<String, Object?> extra;

  const SourceItemView({
    required this.id,
    required this.sourceId,
    this.title,
    this.detailUrl,
    this.torrentUrl,
    this.magnet,
    this.infoHash,
    this.sizeBytes,
    this.seeders,
    this.leechers,
    this.downloads,
    this.publishedAt,
    this.category,
    this.group,
    this.episodeHints = const <String>[],
    this.extra = const <String, Object?>{},
  });

  String get displayTitle =>
      (title == null || title!.trim().isEmpty) ? '(无标题 · $id)' : title!.trim();

  /// 多候选排序用：分辨率（`extra['resolution']`）。
  ///
  /// core 的 `TitleParser` 写的是 **int**（720/1080/2160），但自定义源/未来解析器
  /// 可能写字符串（'1080p'），两种都要认——否则「画质」列会一直是「—」。
  String? get resolution {
    final Object? raw = extra['resolution'];
    if (raw == null) return null;
    if (raw is num) {
      final int value = raw.toInt();
      return value <= 0 ? null : '${value}p';
    }
    final String text = raw.toString().trim();
    return text.isEmpty ? null : text;
  }

  String? get subtitleLang => extra['subtitleLang'] as String?;
  bool get isBatch => extra['isBatch'] as bool? ?? false;

  /// 可下判据：**磁力链、`.torrent` 直链、或 infoHash** 三者有其一。
  ///
  /// ⚠️ 2026-10-15 第三十轮修（用户报障：「集数里点第 4-6 集没反应，也没进队列下载，
  /// 点后面其他几集都正常」）。原来这里只看 `magnet`/`torrentUrl`，**漏了 `infoHash`**，
  /// 与 core 的判据不一致：`core/lib/sources/models.dart:84-93` 的 `isDownloadable`
  /// 认 infoHash，`bestMagnet` 还会拿它拼出 `magnet:?xt=urn:btih:<hash>`
  /// —— 也就是说**引擎完全能下，界面却当成"没有源"**。
  ///
  /// 哪几集会中招：mikan 番剧页/搜索页的行解析是
  /// `infoHash: infoHashFromMagnet(magnet) ?? hash`（`core/lib/sources/mikan.dart:818`），
  /// 磁力没抽到（行的 `input.js-episode-select[data-magnet]` / `a.js-magnet` 缺了）、
  /// 但单集链接 `/Home/Episode/<40hex>` 的 hash 在的行，就是这种"只有 infoHash"的条目。
  /// 于是：「下载」按钮禁用（点了毫无反应、也不入队）／整行只剩「无种子链接」／批量勾选禁用，
  /// 而邻居那几集抽到了磁力 ⇒ 看着像"只有第 4-6 集坏了"。
  bool get hasTorrentSource =>
      (magnet != null && magnet!.isNotEmpty) ||
      (torrentUrl != null && torrentUrl!.isNotEmpty) ||
      (infoHash != null && infoHash!.isNotEmpty);

  /// 点「下载」有没有希望：自己带源，**或者**能从详情页补到源（mikan 单集页 / nyaa view 页）。
  ///
  /// 为什么下载门比 [hasTorrentSource] 宽一档：`HostDataPort.enqueueDownload` 会先
  /// `ensurePlayable`（`state/host_data.dart:315-327`：没有磁力就去 `client.detail()`
  /// 取详情页 HTML 里的磁力），所以"只有详情页链接"的条目**点得动**；
  /// 而播放不做这层兜底前也走同一条路。用 [hasTorrentSource] 当门的后果就是
  /// 按钮直接禁用 —— 用户点了**毫无反馈**，连"补链失败"都不会说（第三十轮报障的第二种形态）。
  bool get canDownload => hasTorrentSource || detailUrl != null;

  /// 同 infoHash 视为同一任务（spec §4.3 重启对齐）。
  String get dedupeKey => (infoHash != null && infoHash!.isNotEmpty) ? infoHash! : id;
}

/// 一页源结果（spec §4.2 `SourcePage`）。
@immutable
class SourcePageView {
  final List<SourceItemView> items;
  final bool hasNext;
  final int page;
  final DateTime fetchedAt;

  /// true = 数据来自缓存。**两种情形共用这一个标志**：
  /// ① TTL 内的新鲜命中（根本没发网络请求）② 网络失败后回落过期缓存。
  final bool fromCache;

  /// 缓存是**过期回落**来的（= 网络那一步真的失败过）。
  ///
  /// 第四十二轮 UX #10：旧实现的注释把 [fromCache] 直接当成了 ②，
  /// 于是重搜同一个词（必然命中 ①）也会弹「网络抓取失败」。
  final bool staleFallback;

  const SourcePageView({
    required this.items,
    required this.page,
    required this.fetchedAt,
    this.hasNext = false,
    this.fromCache = false,
    this.staleFallback = false,
  });
}

// ─────────────────────────────────────────────────────────────────────────────
// 引擎（spec §3.6 / §4.1）
// ─────────────────────────────────────────────────────────────────────────────

enum TorrentState {
  initializing,
  live,
  paused,
  error;

  static TorrentState fromWire(String? s) => switch (s) {
    'initializing' => TorrentState.initializing,
    'live' => TorrentState.live,
    'paused' => TorrentState.paused,
    _ => TorrentState.error,
  };

  String get label => switch (this) {
    TorrentState.initializing => '获取元数据',
    TorrentState.live => '下载中',
    TorrentState.paused => '已暂停',
    TorrentState.error => '错误',
  };
}

@immutable
class EngineFileView {
  final int index;
  final String path;
  final int length;
  final int downloaded;
  final double progress;
  final bool included;
  final String? mime;
  final bool isVideo;
  final bool complete;

  const EngineFileView({
    required this.index,
    required this.path,
    this.length = 0,
    this.downloaded = 0,
    this.progress = 0,
    this.included = true,
    this.mime,
    this.isVideo = false,
    this.complete = false,
  });
}

@immutable
class EngineTorrentView {
  final int id;
  final String infoHash;
  final String name;
  final TorrentState state;
  final String? error;
  final int totalBytes;
  final int progressBytes;
  final int uploadedBytes;
  final double downloadBps;
  final double uploadBps;
  final int peers;
  final double progress;
  final bool finished;
  final String outputFolder;
  final List<EngineFileView> files;

  const EngineTorrentView({
    required this.id,
    required this.name,
    this.infoHash = '',
    this.state = TorrentState.initializing,
    this.error,
    this.totalBytes = 0,
    this.progressBytes = 0,
    this.uploadedBytes = 0,
    this.downloadBps = 0,
    this.uploadBps = 0,
    this.peers = 0,
    this.progress = 0,
    this.finished = false,
    this.outputFolder = '',
    this.files = const <EngineFileView>[],
  });

  /// spec §4.1：`files.where(isVideo)`，多版本同捆取体积最大者。
  EngineFileView? get playableFile {
    final videos = files.where((EngineFileView f) => f.isVideo).toList();
    if (videos.isEmpty) return null;
    videos.sort((EngineFileView a, EngineFileView b) => b.length.compareTo(a.length));
    return videos.first;
  }

  /// 同目录外挂字幕（供 mpv 外挂）。
  List<EngineFileView> get subtitleFiles => files
      .where(
        (EngineFileView f) =>
            f.path.toLowerCase().endsWith('.ass') ||
            f.path.toLowerCase().endsWith('.srt') ||
            f.path.toLowerCase().endsWith('.sub') ||
            f.path.toLowerCase().endsWith('.ssa'),
      )
      .toList(growable: false);
}

@immutable
class EngineHealthView {
  final bool ok;
  final String version;
  final int sessions;
  const EngineHealthView({required this.ok, this.version = '', this.sessions = 0});
}

// ─────────────────────────────────────────────────────────────────────────────
// 队列（spec §4.3）
// ─────────────────────────────────────────────────────────────────────────────

enum JobState {
  queued('queued', '排队中'),
  downloading('downloading', '下载中'),
  paused('paused', '已暂停'),
  completed('completed', '已完成'),
  failed('failed', '失败'),
  cancelled('cancelled', '已取消');

  const JobState(this.wireName, this.label);
  final String wireName;
  final String label;

  bool get isActive =>
      this == JobState.queued || this == JobState.downloading || this == JobState.paused;

  static JobState fromWire(String? s) =>
      JobState.values.firstWhere((JobState j) => j.wireName == s, orElse: () => JobState.queued);
}

@immutable
class QueueJobView {
  final String id;
  final String subscriptionId;

  /// 任务对应的源条目（标题/大小/集数提示都在这里）。
  final SourceItemView item;
  final JobState state;
  final int? engineId;
  final int? fileIndex;

  /// 数字小 = 优先；用户点播 10，自动预取 100。
  final int priority;
  final int attempts;
  final String? error;
  final DateTime createdAt;
  final DateTime updatedAt;

  const QueueJobView({
    required this.id,
    required this.item,
    this.subscriptionId = '',
    this.state = JobState.queued,
    this.engineId,
    this.fileIndex,
    this.priority = 10,
    this.attempts = 0,
    this.error,
    required this.createdAt,
    required this.updatedAt,
  });

  bool get isPrefetch => priority >= 100;

  String get displayTitle => item.displayTitle;

  QueueJobView copyWith({
    JobState? state,
    int? engineId,
    int? fileIndex,
    int? priority,
    int? attempts,
    String? error,
    DateTime? updatedAt,
  }) => QueueJobView(
    id: id,
    item: item,
    subscriptionId: subscriptionId,
    state: state ?? this.state,
    engineId: engineId ?? this.engineId,
    fileIndex: fileIndex ?? this.fileIndex,
    priority: priority ?? this.priority,
    attempts: attempts ?? this.attempts,
    error: error ?? this.error,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// 订阅与规则（spec §4.3）
// ─────────────────────────────────────────────────────────────────────────────

@immutable
class SubsRuleView {
  final String id;
  final String name;

  /// null = 全部源。
  final String? sourceId;
  final String includeRegex;
  final String excludeRegex;

  /// 字幕组白名单（逗号分隔，空 = 不限）。
  final String? groupAllow;
  final int? minSeeders;
  final int minSizeMB;
  final int maxSizeMB;

  /// null | 720 | 1080 | 2160。
  final int? preferResolution;
  final bool autoDownload;
  final String saveSubFolder;

  const SubsRuleView({
    required this.id,
    required this.name,
    this.sourceId,
    this.includeRegex = '',
    this.excludeRegex = '(合集|全集|BDRip|HEVC.*10bit|招募|招新)',
    this.groupAllow,
    this.minSeeders = 0,
    this.minSizeMB = 0,
    this.maxSizeMB = 0,
    this.preferResolution,
    this.autoDownload = false,
    this.saveSubFolder = '{title}',
  });

  SubsRuleView copyWith({
    String? name,
    String? sourceId,
    String? includeRegex,
    String? excludeRegex,
    String? groupAllow,
    int? minSeeders,
    int? minSizeMB,
    int? maxSizeMB,
    int? preferResolution,
    bool? autoDownload,
    String? saveSubFolder,
    bool clearPreferResolution = false,
  }) => SubsRuleView(
    id: id,
    name: name ?? this.name,
    sourceId: sourceId ?? this.sourceId,
    includeRegex: includeRegex ?? this.includeRegex,
    excludeRegex: excludeRegex ?? this.excludeRegex,
    groupAllow: groupAllow ?? this.groupAllow,
    minSeeders: minSeeders ?? this.minSeeders,
    minSizeMB: minSizeMB ?? this.minSizeMB,
    maxSizeMB: maxSizeMB ?? this.maxSizeMB,
    preferResolution: clearPreferResolution ? null : (preferResolution ?? this.preferResolution),
    autoDownload: autoDownload ?? this.autoDownload,
    saveSubFolder: saveSubFolder ?? this.saveSubFolder,
  );
}

@immutable
class SubscriptionView {
  final String id;
  final String name;
  final String feedUrl;

  /// 'rss' | 'nyaa' | 'mikan'。
  final String sourceKind;
  final Map<String, String> sourceParams;
  final List<SubsRuleView> rules;
  final Duration refreshInterval;
  final bool enabled;
  final DateTime? lastRefreshAt;
  final String? lastError;

  /// 首次抓取只做「已读」标记，不倒灌历史剧集（spec §4.3）。
  final int seededCount;

  const SubscriptionView({
    required this.id,
    required this.name,
    required this.feedUrl,
    this.sourceKind = 'rss',
    this.sourceParams = const <String, String>{},
    this.rules = const <SubsRuleView>[],
    this.refreshInterval = const Duration(minutes: 30),
    this.enabled = true,
    this.lastRefreshAt,
    this.lastError,
    this.seededCount = 0,
  });

  SubscriptionView copyWith({
    String? name,
    String? feedUrl,
    String? sourceKind,
    Map<String, String>? sourceParams,
    List<SubsRuleView>? rules,
    Duration? refreshInterval,
    bool? enabled,
    DateTime? lastRefreshAt,
    String? lastError,
    int? seededCount,
  }) => SubscriptionView(
    id: id,
    name: name ?? this.name,
    feedUrl: feedUrl ?? this.feedUrl,
    sourceKind: sourceKind ?? this.sourceKind,
    sourceParams: sourceParams ?? this.sourceParams,
    rules: rules ?? this.rules,
    refreshInterval: refreshInterval ?? this.refreshInterval,
    enabled: enabled ?? this.enabled,
    lastRefreshAt: lastRefreshAt ?? this.lastRefreshAt,
    lastError: lastError ?? this.lastError,
    seededCount: seededCount ?? this.seededCount,
  );

  String get sourceKindLabel => switch (sourceKind) {
    'nyaa' => 'nyaa.si',
    'mikan' => 'mikanani.me',
    _ => '自定义 RSS',
  };
}

/// 手动刷新结果（命中预览与入队数）。
@immutable
class SubsRefreshResult {
  final int fetched;
  final int matched;
  final int queued;
  final bool seeded;
  final String? error;

  const SubsRefreshResult({
    this.fetched = 0,
    this.matched = 0,
    this.queued = 0,
    this.seeded = false,
    this.error,
  });
}

// ─────────────────────────────────────────────────────────────────────────────
// 播放
// ─────────────────────────────────────────────────────────────────────────────

/// 交给播放器的一次播放请求：`streamUrl` 就是边车串流 URL（边下边播的全部秘密）。
@immutable
class PlayerRequest {
  final Uri streamUrl;
  final String title;
  final int? engineId;
  final int? fileIndex;

  /// 外挂字幕绝对路径（引擎已下载完成的同目录字幕）。
  final String? subtitlePath;
  final Duration? startAt;

  const PlayerRequest({
    required this.streamUrl,
    required this.title,
    this.engineId,
    this.fileIndex,
    this.subtitlePath,
    this.startAt,
  });

  PlayerRequest copyWith({String? title, String? subtitlePath}) => PlayerRequest(
    streamUrl: streamUrl,
    title: title ?? this.title,
    engineId: engineId,
    fileIndex: fileIndex,
    subtitlePath: subtitlePath ?? this.subtitlePath,
    startAt: startAt,
  );
}

/// 播放器回传的信号（播放页据此做「播完自动下一集」）。
sealed class PlaybackSignal {
  const PlaybackSignal();
}

class PlaybackPosition extends PlaybackSignal {
  final Duration position;
  final Duration duration;
  const PlaybackPosition(this.position, this.duration);
}

class PlaybackCompleted extends PlaybackSignal {
  const PlaybackCompleted();
}

class PlaybackFailure extends PlaybackSignal {
  final String message;
  const PlaybackFailure(this.message);
}

/// 播放/暂停状态变化（自绘控制条据此更新图标）。
class PlaybackPlayingChanged extends PlaybackSignal {
  final bool playing;
  const PlaybackPlayingChanged(this.playing);
}

// ─────────────────────────────────────────────────────────────────────────────
// 主页：mikan 追番更新表（spec §7.5）
// ─────────────────────────────────────────────────────────────────────────────

/// 星期短名（`周日`…`周六`）。
///
/// **键口径与 core 一致**：0 = 周日 … 6 = 周六（Dart 的 `DateTime.weekday` 是
/// 1=周一…7=周日，转换见 [dsTodayDow]）。
const List<String> dsWeekdayNames = <String>['周日', '周一', '周二', '周三', '周四', '周五', '周六'];

/// 星期键 → 展示名；**7 = 剧场版、8 = OVA**（mikan 首页那两个专档的站点原文名）。
///
/// 第二十五轮修：以前 7/8 都写成「未定档」。站点自己标的是
/// `date-li-7 → 剧场版`（`data-row-7` 正文也写着「剧场版」）、`date-li-8 → OVA`；
/// 真机样本见 core 的 `test/fixtures/mikan_home_schedule.html`。展示名照抄站点。
///
/// 其它越界值（例如从「正在追」卡构造详情页时传的占位 dow）回落成「未定档」，
/// 不让一个展示函数抛 RangeError。
String dsWeekdayLabel(int dayOfWeek) => switch (dayOfWeek) {
  7 => '剧场版',
  8 => 'OVA',
  < 0 || > 8 => '未定档',
  _ => dsWeekdayNames[dayOfWeek],
};

/// 本机「今天」对应的星期键（0 = 周日 … 6 = 周六），与 core 的 `byDay` 同口径。
int dsTodayDow([DateTime? now]) => (now ?? DateTime.now()).weekday % 7;

/// 两个时间是否是**同一个自然日**（按本机时区）。
///
/// 用于「今日更新」角标：mikan 的 `date-text` 给的是这部番最近一次更新的日期，
/// 拿它和今天比才是「今天真的更了这一集」；只按「当前看的是星期三」判断会让
/// 当天的每一张卡都挂同一个角标，等于没有信息。
bool isSameCalendarDay(DateTime? a, DateTime? b) {
  if (a == null || b == null) return false;
  final DateTime x = a.toLocal();
  final DateTime y = b.toLocal();
  return x.year == y.year && x.month == y.month && x.day == y.day;
}

/// 追番表里的一条：**某部番在某天更新**。
///
/// ⚠️ 这里**没有磁力/种子**（mikan 首页不给）：想播放必须先进番剧详情页
/// （[SchedulePort.bangumi]）拿剧集，绝不把这条硬凑成可播项。
@immutable
class ScheduleEntryView {
  /// 番剧 id（`/Home/Bangumi/<id>` 里的数字）。可能为空串（站点没给）。
  final String bangumiId;

  /// 0=周日 … 6=周六；**7 = 剧场版、8 = OVA**（mikan 的两个专档）。
  final int dayOfWeek;
  final String? title;

  /// 封面绝对 URL；null = 站点没给 → UI 降级成灰框「无封面」。
  ///
  /// 实测 mikan 图床即使带 `format=webp` 也可能真返回 WebP，
  /// 落盘缓存必须按**响应真实格式**定扩展名（见 `state/cover_cache.dart`）。
  final String? coverUrl;

  /// mikan 首页原文（如 `2026/10/07 更新`）。**只有日期，没有集数**。
  final String updateText;

  /// 从 [updateText] 解析出的更新日期；解析不出为 null（不猜）。
  final DateTime? updatedAt;

  /// 当天内的排位（1 起）；缺失为 0。
  final int index;

  /// 站点标记的「本机已订阅」（`data-showsubscribed`）。
  final bool subscribed;
  final Uri? detailUrl;

  const ScheduleEntryView({
    required this.bangumiId,
    required this.dayOfWeek,
    this.title,
    this.coverUrl,
    this.updateText = '',
    this.updatedAt,
    this.index = 0,
    this.subscribed = false,
    this.detailUrl,
  });

  bool get isUnslotted => dayOfWeek > 6;

  String get dayLabel => dsWeekdayLabel(dayOfWeek);

  String get displayTitle =>
      (title == null || title!.trim().isEmpty) ? '(未知名番剧 · $bangumiId)' : title!.trim();

  /// 封面右下角的更新文案：优先站点原文，没有就用解析出的日期补，**都没有就是空串**（不编）。
  String get updateLabel {
    final String raw = updateText.trim();
    if (raw.isNotEmpty) return raw;
    final DateTime? date = updatedAt;
    if (date == null) return '';
    String two(int v) => v.toString().padLeft(2, '0');
    return '${date.year}/${two(date.month)}/${two(date.day)} 更新';
  }
}

/// 一整张追番表（一次拿全周，切星期不再拉数据）。
@immutable
class ScheduleView {
  final List<ScheduleEntryView> entries;

  /// key = 档位键（0..6，以及 7=剧场版 / 8=OVA）→ 该档的条目。
  final Map<int, List<ScheduleEntryView>> byDay;

  /// 本轮取到数据的时间（用于「数据 X 前」）。
  ///
  /// core 的 `MikanSchedule` 不带缓存时间戳，所以这里是**宿主拿到数据的时刻**：
  /// 新鲜抓取时准确；命中 core 缓存时它表示「本轮读取时刻」而非站点更新时间，
  /// 界面文案写成「数据 X」而不是「站点更新于 X」，不冒充新鲜度。
  final DateTime fetchedAt;

  /// 解析时丢弃的条目数（可观测，不静默）。
  final int skipped;

  const ScheduleView({
    required this.entries,
    required this.byDay,
    required this.fetchedAt,
    this.skipped = 0,
  });

  List<ScheduleEntryView> day(int dayOfWeek) => byDay[dayOfWeek] ?? const <ScheduleEntryView>[];

  /// 展示顺序：周一 → 周日 → 剧场版 → OVA（7 → 8），只含非空的档。
  List<int> get displayDays => const <int>[
    1,
    2,
    3,
    4,
    5,
    6,
    0,
    7,
    8,
  ].where((int d) => day(d).isNotEmpty).toList(growable: false);

  /// 非空的两个专档（剧场版 7 / OVA 8）。
  List<int> get unslottedDays =>
      const <int>[7, 8].where((int d) => day(d).isNotEmpty).toList(growable: false);

  int get total => entries.length;
}

/// mikan 番剧页上的**一个字幕组**（第二十七轮：把每组的 RSS 地址也带出来）。
///
/// 为什么必须带 [rssUrl]：用户要求「在字幕组的旁边，可以直接订阅」——
/// 订阅就是订这一组的 RSS（`/RSS/Bangumi?bangumiId=…&subgroupid=…`），
/// 站点把这个地址写在番剧页每个字幕组那一行的 `a.mikan-rss` 上（core 已解析）。
/// 以前这一层只传组名，订阅就无从下手。
@immutable
class BangumiGroupView {
  const BangumiGroupView({required this.name, this.id = '', this.rssUrl});

  /// 站点给的组 id（`subgroup-text` 元素的 id；拿不到就是空串）。
  final String id;
  final String name;
  final String? rssUrl;

  /// 有 RSS 地址才订阅得动 —— 按钮据此置灰（而不是点了没反应）。
  bool get canSubscribe => (rssUrl ?? '').trim().isNotEmpty;

  @override
  bool operator ==(Object other) =>
      other is BangumiGroupView && other.id == id && other.name == name && other.rssUrl == rssUrl;

  @override
  int get hashCode => Object.hash(id, name, rssUrl);
}

/// mikan 番剧详情（`/Home/Bangumi/<id>`）：字幕组 + 剧集列表。
///
/// 主页条目靠它才能变成可播项：这里的 [episodes] 才是**带磁力/infoHash 的种子**。
@immutable
class BangumiDetailView {
  final String bangumiId;
  final String? title;

  /// 字幕组（站点按字幕组分区；名字用于展示与筛选，RSS 地址用于「直接订阅」）。
  final List<BangumiGroupView> groups;
  final List<SourceItemView> episodes;
  final int skipped;

  const BangumiDetailView({
    required this.bangumiId,
    this.title,
    this.groups = const <BangumiGroupView>[],
    this.episodes = const <SourceItemView>[],
    this.skipped = 0,
  });

  /// 组名列表（老代码/测试读的形态；顺序与 [groups] 一致）。
  List<String> get groupNames =>
      <String>[for (final BangumiGroupView g in groups) g.name];

  String get displayTitle =>
      (title == null || title!.trim().isEmpty) ? '番剧 $bangumiId' : title!.trim();
}

/// 正在播放的上下文（播放页浮层 + 自动下一集都需要它）。
@immutable
class NowPlaying {
  final String title;
  final int engineId;
  final int fileIndex;

  /// 同一次点播的后续集（自动下一集按顺序取）。
  final List<SourceItemView> upNext;

  /// 观看记录的元数据（第二十七轮；null = 这次播放不记账，例如调试用的 `--play`）。
  ///
  /// 进度是子窗口之后才报上来的，所以键必须在**开播那一刻**算好带上
  /// （见 `domain/watch_history.dart` 的 [WatchMeta]）。
  final WatchMeta? watch;

  /// **这一组里每一集**的观看记录元数据，键是串流 URL 文本（第二十七轮）。
  ///
  /// 为什么需要它：同一个 torrent 里的其它集（合并种子）在子窗口里是**直接本地开盘**的
  ///  —— `episodeGroupingFor` 给每一项都填了 `streamUri`，子窗口点「下一集」时
  /// 走 `playerRequestProvider` 自己 `open`，**不经过宿主**（见 ShikiiN 的
  /// `_playEpisode`：有 `streamUrl` 就直接放）。于是宿主的 `nowPlaying` 会停在
  /// 最开始那一集，而子窗口早就在放第 2、3 集了。
  /// 子窗口上报进度时会带上它当前真正在放的 `path`（= 串流 URL），
  /// 宿主用这张表把进度**归到正确的那一集**上 —— 否则第 2 集的进度会写进第 1 集的记录，
  /// 还会在第 1 集上打出「已看过」的勾。
  ///
  /// 「同名同压制组」那份播放列表里的其它集**没有** streamUrl（还没进引擎），
  /// 子窗口只能交回宿主 ⇒ 宿主自己会更新 `nowPlaying`，不需要这张表。
  ///
  /// 值里带 `fileIndex`：那一集在 torrent 里的文件序号。子窗口自己换集时宿主不知道，
  /// 要**补写**一条观看记录（`recordStart`）就得知道"这一集是哪个文件" ——
  /// 否则观看记录里那一行的「继续播放」没有可播的目标。
  final Map<String, ({WatchMeta watch, int? fileIndex})> watchByUrl;

  const NowPlaying({
    required this.title,
    required this.engineId,
    required this.fileIndex,
    this.upNext = const <SourceItemView>[],
    this.watch,
    this.watchByUrl = const <String, ({WatchMeta watch, int? fileIndex})>{},
  });

  NowPlaying copyWith({
    String? title,
    int? engineId,
    int? fileIndex,
    List<SourceItemView>? upNext,
    WatchMeta? watch,
    Map<String, ({WatchMeta watch, int? fileIndex})>? watchByUrl,
  }) => NowPlaying(
    title: title ?? this.title,
    engineId: engineId ?? this.engineId,
    fileIndex: fileIndex ?? this.fileIndex,
    upNext: upNext ?? this.upNext,
    watch: watch ?? this.watch,
    watchByUrl: watchByUrl ?? this.watchByUrl,
  );
}
