/// 宿主与外部能力之间的**端口**（抽象接口）。
///
/// 三个理由：
/// 1. 并行开发：`dsanima_core` / `shikiin` 落地期间 UI 能独立编译、独立测试；
/// 2. 可测：widget 测试直接 override 端口注入假数据，不联网、不起引擎；
/// 3. 诚实：未接通时注入 `domain/unavailable.dart` 里的实现——它们**抛异常**并给出
///    可行动提示，绝不用假数据装成成功。
///
/// 真实实现由 `state/adapters.dart` 提供，`main.dart` 在 `ProviderScope.overrides`
/// 里注入。
library;

import 'dart:io';

import 'package:dsanima_core/update/update.dart' as core_update;
import 'package:flutter/widgets.dart';

import 'bangumi.dart';
import 'bangumi_library.dart';
import 'episode_group.dart';
import 'local_media.dart';
import 'models.dart';

/// 端口未接通 / 上游依赖未就绪。UI 必须把 [message] + [hint] 直接展示给用户。
class PortUnavailableException implements Exception {
  const PortUnavailableException(this.message, {this.hint});

  /// 发生了什么（用户能看懂的）。
  final String message;

  /// 怎么办（具体到「去哪里改什么」）。
  final String? hint;

  @override
  String toString() => hint == null ? message : '$message（$hint）';
}

/// 源查询端口（nyaa.si 动漫区 / mikanani.me / 自定义 RSS）。
abstract interface class SourcePort {
  /// 当前可用源（下拉框）。未接通时返回空列表，页面需显示「源未接通」。
  List<SourceOption> get sources;

  Future<SourcePageView> latest(String sourceId, {int page = 1});

  Future<SourcePageView> search(String sourceId, String keyword, {int page = 1});
}

/// 引擎端口（边车 rqbit-engine 的 HTTP + SSE 能力）。
abstract interface class EnginePort {
  Future<EngineHealthView> health();

  Future<EngineTorrentView> addMagnet(
    String magnet, {
    String? name,
    List<int>? onlyFiles,
    bool startPaused,
    String? subFolder,
  });

  Future<List<EngineTorrentView>> list();

  Future<void> pause(int id);

  Future<void> resume(int id);

  Future<void> remove(int id, {bool deleteFiles = false});

  /// SSE 全量进度流（spec §3.9）。UI 侧订阅它做实时进度。
  Stream<List<EngineTorrentView>> watch();

  /// mpv 用的串流 URL：`<baseUrl>/torrents/{id}/files/{idx}/stream?token=…`。
  /// 返回 null = 引擎未连接 / 没有该文件（UI 显示「引擎未连接」，不要假装能播）。
  Uri? streamUrl(int id, int fileIndex);
}

/// 队列端口（spec §4.3 QueueManager）。
abstract interface class QueuePort {
  Stream<List<QueueJobView>> watchJobs();

  /// 用户点播：立即入队 + 立即把 streamUrl 交给播放器（priority 10）。
  ///
  /// [upNext] = 同批结果里的后续集（喂成 queue 的候选，供"本集下完后继续预热"）。
  /// [preheat] = **这一轮要按档位预热的整批**（第三十八轮）：core 自己从里面挑
  /// "当前集之后最近的 N 集"入队并启动，于是用户点「下一集」时种子已在引擎里。
  /// 传整批（番剧页全集清单）而不是只传下一条：挑哪几条归 core 的档位管，
  /// 换档位不用改调用方。
  Future<QueueJobView> enqueuePlayNow(
    SourceItemView item, {
    List<SourceItemView> upNext = const <SourceItemView>[],
    List<SourceItemView> preheat = const <SourceItemView>[],
  });

  /// 只下载不播放（priority 20）。
  ///
  /// [onlyFiles] = 只下这些文件序号（引擎的 `onlyFiles`；null/空 = 全下）。
  /// 拖入 `.torrent` 时用户在确认框里勾掉的文件不进下载队列 —— 这份选择会存进任务、
  /// 并在真正交给引擎时带上（见 core `QueueJob.onlyFiles`），所以重启后不会被整包覆盖。
  Future<QueueJobView> enqueueDownload(SourceItemView item, {List<int>? onlyFiles});

  /// 只订阅过滤（交给订阅规则，不入队）。
  Future<void> attachToSubsRule(SourceItemView item);

  Future<void> pauseJob(String jobId);

  Future<void> resumeJob(String jobId);

  /// 移除任务：删掉队列记录（可选连文件一起删），并记一条「别再自动入队」的墓碑。
  ///
  /// ⚠️ **不含文件的移除不动引擎里那份种子**，尤其是已经下完的（用户 2026-10-12
  /// 第十九轮：「队列中移除了不应该把已完成里也移除」）——「已完成」页的数据源就是引擎里
  /// `finished` 的种子，删了它等于把用户已经拿到手的本地文件从「已完成」里抹掉。
  ///
  /// 返回值 `null` = 队列与引擎都处理干净（含"引擎那条按规矩留着"）；非空字符串 = 记录
  /// 已删掉、但引擎那一步没成功（例如任务早已不在引擎里），调用方应当把它显示给用户。
  Future<String?> removeJob(String jobId, {bool deleteFiles = false});

  /// **从引擎侧**删掉一个 torrent，并顺带清掉队列里绑着它的任务（含墓碑）。
  ///
  /// 「已完成」页（原「已缓存」页，第二十一轮合并）的数据源是引擎 torrent 列表，
  /// 那里的删除必须走这条路 —— 只删引擎不删
  /// 队列会留下一条永远「下载中」的幽灵任务（用户 2026-10-11 报的问题）。返回值同
  /// [removeJob]。
  Future<String?> removeByEngine(int engineId, {bool deleteFiles = true});

  Future<void> setPriority(String jobId, int priority);

  Future<void> clearCompleted();

  /// 清空整个队列（可选连文件一起删）。返回值同 [removeJob]；规则也一样 ——
  /// 不含文件的清空**不碰引擎里已经下完的那几条**（否则「已完成」页会被一起清掉）。
  Future<String?> clearAll({bool deleteFiles = false});

  /// 播放结束（播放窗口收起/彻底关闭）：把正在播的那条任务收尾。
  ///
  /// 下完 → `completed`，没下完 → `paused`，引擎侧不再后台跑（用户 2026-10-11 选定）。
  Future<void> settleAfterPlayback(int engineId);

  /// 命中预览：「这条规则会下哪些」（不落库、不入队）。
  Future<List<SourceItemView>> previewMatches(SubscriptionView subscription);

  /// 一键全季入队；返回入队条数。
  Future<int> enqueueSeason(SubscriptionView subscription);
}

/// 订阅端口（增删改查 + 手动刷新）。
abstract interface class SubsPort {
  Stream<List<SubscriptionView>> watch();

  Future<void> upsert(SubscriptionView subscription);

  Future<void> remove(String id);

  /// 手动刷新：抓取 → 命中预览 → 按规则入队。首次抓取只做已读标记。
  Future<SubsRefreshResult> refresh(String id);

  /// 订阅的**全部条目**（第二十七轮）：不套规则 —— 「正在追」点开层要列的是
  /// 「这个字幕组都出过哪些集」，不是"按规则会下哪些"
  /// （实现见 `HostDataRuntime.subscriptionItems`）。
  Future<List<SourceItemView>> items(SubscriptionView subscription);
}

/// 主页数据端口：mikan 追番更新表 + 番剧详情（spec §7.5）。
///
/// 主页条目**没有磁力**，只有「番剧在某天更新」这一条事实；要播放必须走
/// [bangumi] 拿剧集（那里才有 `.torrent` / magnet / infoHash）。
abstract interface class SchedulePort {
  /// 是否真接通（false = 只有占位实现，UI 显示可行动错误而不是空表）。
  bool get isAvailable;

  /// 整张追番表（一次拿全周：切星期**不重新拉数据**）。
  Future<ScheduleView> schedule();

  /// 番剧详情：字幕组 + 剧集列表（含磁力，可直接入队播放）。
  Future<BangumiDetailView> bangumi(String bangumiId);
}

/// 封面图本地缓存端口（spec §7.5 / §7.6）。
///
/// 真实实现下载到 `<支持目录>/cache/covers/`，**按响应真实格式定扩展名**；
/// 任何失败（无网络 / 超时 / 403 / 不是图片）都必须返回 null 让 UI 降级成灰框：
/// 封面加载失败绝不能拖慢列表、更不能中断首启向导。
abstract interface class CoverCachePort {
  /// 返回本地缓存文件；不可用/失败返回 null。
  ///
  /// [referer] 仅 Bangumi 图床需要（`http://lain.bgm.tv` 要带 `Referer: https://bgm.tv/`）。
  Future<File?> fileFor(String url, {String? referer});

  /// **同步**问一句"这张图现在就在本地吗"—— 第三十七轮加的（用户 2026-10-16：
  /// 「动漫库的封面图保存缓存，不然每次都要加载」）。
  ///
  /// 差别只在于**要不要等**：`fileFor` 即使缓存命中也得过 `await`（磁盘探测 → 下一帧
  /// 才拿到 File），于是每张封面、每次进页面/滚动回来都会先空一帧灰底；`cachedNow`
  /// 只查内存索引，命中就**当帧**能画（`Image.file` 那时也还能命中解码缓存）。
  ///
  /// 契约（宽进严出，别在这里做 IO）：
  /// * **只查内存索引**，绝不碰磁盘、绝不发请求、绝不抛异常；
  /// * 不知道 / 过期 / 没预热 ⇒ `null`（调用方退回 [fileFor] 那条异步路，行为与以前一致）；
  /// * 拿到的文件可能**下一秒就不在了**（设置页清了缓存）—— 调用方的降级路径要能接住
  ///   （`Image.file` 的 `errorBuilder`）。
  File? cachedNow(String url);
}

/// 主页「今日推荐」端口（spec §7.7：Bangumi **全年代随机** 5 部）。
///
/// [seed] 相同 → 结果必须相同（当天稳定）；`换一批` 用递增 seed。
/// 实现要防「年代聚簇」（多窗口均衡抽取）并过滤残缺项；
/// 候选不足时返回能拿到的全部，**不报错、不编数据**。
abstract interface class RecommendPort {
  bool get isAvailable;

  Future<List<BangumiSubject>> recommend({required int seed, int? count});
}

/// 「动漫库」端口（第三十三轮）：按 [BangumiLibraryQuery] 翻页浏览 Bangumi 全库 + 取条目详情。
///
/// 契约（都是实测出来的，见 `domain/bangumi_library.dart` 的表格）：
/// * 返回的 [BangumiLibraryPage.items] **已经按放送形态在本地精确过滤过**
///   （服务端的 `platform` 参数会被忽略，只能拿 `tag` 近似）；
/// * [BangumiLibraryPage.nextOffset] 是**下一页的游标**，不一定等于 `startOffset + 条数`
///   （本地过滤会吃掉一些）—— 调用方只用它，不要自己算；
/// * `total` 已按服务端上限（1000）封顶，不许拿它承诺"还有几千部"；
/// * [limit] 是**要多少条**：调用方按"列数 × [kLibraryRows]"给（保证整行），
///   服务层自己去凑页（服务端单次最多 20 条，见 [kLibraryServerPageCap]）；
/// * 失败照旧**抛异常**（不返回空列表假装没有数据），由 UI 显示"为什么 + 重试"。
abstract interface class BangumiLibraryPort {
  bool get isAvailable;

  Future<BangumiLibraryPage> search(
    BangumiLibraryQuery query, {
    int offset = 0,
    int limit = kLibraryDefaultPageSize,
  });

  /// 条目详情（`GET /v0/subjects/{id}`，含评分/简介/标签/放送日/话数）。
  Future<BangumiSubject> detail(int id);

  /// 详情页顶部信息带下面的两块补充内容（第三十七轮「参考 bangumi 那样的布局」）：
  /// **角色**（`GET /v0/subjects/{id}/characters`）与**关联条目**
  /// （`GET /v0/subjects/{id}/subjects`）。
  ///
  /// 契约（都比 [detail] 松，理由是它们是**可空的装饰**而不是主内容）：
  /// * 两条端点**各自**失败时，那一半当空表返回，另一半照常给 —— 不因为
  ///   「角色没拉到」就让整页变成一句错误提示；**但失败的那一路要记在
  ///   [BangumiSubjectExtra.charactersError] / `relatedError` 上**（第四十四轮加，
  ///   否则调用方分不出"真的没有"与"没拉到"，那一块只会静静地不出现）；
  /// * 但有失败**不落盘缓存**（否则一次网络抖动会把"没有角色"永久钉在盘上），
  ///   也**不进程内缓存**（第四十四轮加：否则用户点「重试」拿到的还是内存里那份缺的）；
  /// * 两条都成功时（哪怕真的都是空数组，实测孤独摇滚就是）结果落盘，第二次点开是本地读；
  /// * 两条都失败时抛其中一条异常，交给调用方决定要不要提示。
  Future<BangumiSubjectExtra> extras(int id);
}

/// 播放器端口（shikiin 的 PlayerController 由适配器包住）。
abstract interface class PlayerPort {
  /// 播放器是否真的接通（false = 只有 `UnavailablePlayerPort` 这类占位实现）。
  bool get isAvailable;

  /// 播放 [request]。
  ///
  /// [episodeGroup] 是「当前集所在的那一组」（决策 B31）。弹出播放窗口那条链路上，
  /// 子窗口拿不到宿主的引擎，每集的串流地址只能由宿主填好一起交过去；
  /// 内嵌实现可以直接忽略它（宿主自己 override `episodeGroupProvider`）。
  Future<void> open(PlayerRequest request, {EpisodeGrouping? episodeGroup});

  Future<void> playOrPause();

  Future<void> seek(Duration position);

  Future<void> stop();

  /// 播放器回传的信号（位置/时长/播放状态/播放完成/失败）。
  Stream<PlaybackSignal> get signals;

  Future<void> dispose();
}

/// 运行时生命周期端口：让新设置真正生效。
///
/// 设置页保存后调用 [applySettings]：
/// * **只改了上下行限速** → 走边车的 `PATCH /limits` **热更新**，不重启进程
///   （1.1.0 M1/T4：省一次 ~3.5s、不打断正在下载的连接）；
/// * 下载目录/引擎路径/做种比/tracker 变了 → 重启边车；
/// * 两种情况都会重建源客户端（代理/缓存 TTL）。
///
/// 「这次到底重启没重启、为什么」由 `state/providers.dart` 的 `engineApplyNoteProvider`
/// 带给设置页的成功文案（**不**用抛异常来表示"回退重启了"——那会把一次成功的保存
/// 画成红色失败横幅）。未接通时抛 [PortUnavailableException]，
/// 设置页会显示「已保存但未生效」而不是假装成功。
abstract interface class LifecyclePort {
  Future<void> applySettings(AppSettings settings);
}

/// 播放画面构建器：宿主注入「内嵌 shikiin 播放器」的控件。
///
/// 真正的播放投递走 [PlayerPort]（`PlayerRequestNotifier` → ShikiiN 外壳），
/// 所以这里只需要「把播放器的画面/控件挂进树」，不需要再传一次请求。
/// 未注入时默认返回空盒子，播放页会叠一张明确提示，而不是一块黑屏。
typedef PlayerSurfaceBuilder = Widget Function(BuildContext context);

/// 目录/文件选择端口（`file_picker` 的真实实现 + 测试用假实现）。
abstract interface class PickerPort {
  Future<String?> pickDirectory({String? title});

  Future<String?> pickFile({String? title, List<String> extensions = const <String>[]});
}

/// 本地文件夹扫描端口（`dart:io` 的真实实现 + 测试用假实现）。
///
/// 为什么单独一个端口而不是在 `local_library.dart` 里直接 `Directory.list`：
/// 扫描是**唯一**的磁盘 IO，把它关在端口后面，控制器那套（文件夹增删 / 进度 /
/// 错误提示）就能在测试里用一份内存目录跑满。返回的是**文件清单**（视频 + 字幕
/// 两类扩展名都收），"哪些是视频、字幕怎么配"是 `domain/local_media.dart` 的纯逻辑。
abstract interface class LocalMediaScannerPort {
  /// 递归扫描 [folder]。目录不存在 / 没权限时抛异常（调用方把它显示在该行上）。
  ///
  /// 实现必须**容错**：某个子目录读不了就跳过它，不要让整次扫描失败。
  Future<List<LocalFileStat>> scan(String folder);

  /// 平台支持（桌面才有意义；false 时页面直接说明"这个平台不支持"）。
  bool get isSupported;
}

/// 一次「拉起边车」的结果。失败必须带可行动提示。
@immutable
class EngineStartOutcome {
  final bool ok;
  final String? message;
  final String? hint;
  final String? exePath;
  final Duration? startup;

  /// 边车的根地址（`http://127.0.0.1:<port>`，来自 runtime.json）。
  ///
  /// 用途：状态栏那颗引擎点的小面板要显示**端口**（用户 2026-10-11 第二阶段清单
  /// 第 8 项）。端口只有起引擎/接管的那一刻知道，所以随结果一起带出来。
  final String? baseUrl;

  const EngineStartOutcome({
    required this.ok,
    this.message,
    this.hint,
    this.exePath,
    this.startup,
    this.baseUrl,
  });

  static EngineStartOutcome failure(String message, {String? hint}) =>
      EngineStartOutcome(ok: false, message: message, hint: hint);
}

/// 拉起 / 停止 rqbit 边车进程。
///
/// 真实实现（core 的 `EngineRuntime`）由 `main.dart` 注入，UI 层只认这个端口：
/// 上游 core 正在重构时，宿主的 `flutter analyze` / widget 测试仍然可跑。
abstract interface class EngineBootstrapPort {
  /// 当前是否有一个在跑的边车。
  bool get isRunning;

  Future<EngineStartOutcome> start({required AppSettings settings, required Directory supportDir});

  Future<void> stop();
}

/// 托盘命令（宿主 → 窗口）。
enum TrayCommand {
  /// 显示主窗口（左键单击 / 菜单「显示主窗口」）。
  restore,

  /// 唤回**播放器窗口**（菜单「显示播放器窗口」，第四十二轮 UX #48）。
  ///
  /// 与 [restore] 分开：用托盘的人往往是不想把主窗口调出来的那种，而收起的播放窗口
  /// 以前只能"先唤主窗口 → 再点侧栏那颗按钮"。
  showPlayer,

  /// 暂停引擎里全部任务。
  pauseAll,

  /// 继续引擎里全部任务。
  resumeAll,

  /// 从托盘退出（先停边车再退进程）。
  exitApp,
}

/// 系统托盘（spec §7.3 Q14）。
///
/// 未接通时 [isAvailable] 为 false：设置页会明确写「后台常驻需要托盘组件」，
/// **不会**默默把窗口藏起来让用户找不回来。
abstract interface class TrayPort {
  bool get isAvailable;

  Future<void> show({required String tooltip});

  Future<void> hide();

  Future<void> dispose();

  /// 用户在托盘里点「显示主界面 / 退出」。
  Stream<TrayCommand> get commands;
}

/// 系统通知（spec §7.3 Q16：新集数命中订阅 → 通知，点击跳转播放）。
abstract interface class NotificationPort {
  bool get isAvailable;

  /// 弹一条通知；[payload] 原样回传在 [clicks] 里（宿主用 `job:<id>` 定位任务）。
  Future<bool> notify({required String title, required String body, String? payload});

  Stream<String> get clicks;
}

/// 宿主数据层（源注册表 / 订阅存储 / 队列管理器）的生命周期。
///
/// UI 层只认这个端口：真实实现由 `main.dart` 注入（core 的
/// `SourceRegistry` + `SubscriptionStore` + `QueueManager`）。
abstract interface class HostDataPort {
  /// 设置变更后重建（代理 / 限速 / 缓存 TTL / 并发 / 省流量策略）。
  Future<void> applySettings(AppSettings settings);

  /// 引擎就绪后与引擎对齐（同 infoHash 视为同一任务）。
  Future<void> reconcile();

  /// 把一条**搜索结果**补全成「能加磁力」的形态。
  ///
  /// 为什么必须有这一步（用户 2026-10-11：「搜索内的全部无法播放 mikan 的」）：
  /// mikan 的 RSS（`/RSS/Classic`、`/RSS/Search`）**没有 magnet、也没有 infoHash**
  /// （spec §4.2 原文），磁力只存在于单集详情页 `/Home/Episode/<hash>` 的 HTML 里。
  /// 搜索页点「播放」时直接把 RSS 条目交给队列，`bestMagnet` 是 null ⇒
  /// `QueueManager.playNow` 抛「既没有磁力链接也没有 infoHash」⇒ 搜索结果**全军覆没**。
  ///
  /// 契约：**永不为了"看起来成功"编一个磁力**。拿不到就原样返回，让下游给出真实错误；
  /// 网络/解析失败也原样返回（不抛出），因为这一步只是"顺手补全"。
  Future<SourceItemView> ensurePlayable(SourceItemView item);

  /// 这一条所在的**整部番的剧集清单**（来源支持才有；拿不到就返回空表）。
  ///
  /// 为什么必须有这一步（用户 2026-10-11 第五次报障）：
  /// > 而且不会有前几集，我点第8集就没有765等。
  /// 播放列表原来只按"**这一批**搜索结果"归组（见 `domain/playlist.dart`），
  /// 于是从「今日更新」点第 8 集，列表里就只有今天发过的 8/9/10 —— 5/6/7 根本没进过这一批。
  /// mikan 的番剧页 `/Home/Bangumi/<id>` 有整部番每集的 magnet，把它并进来才凑得齐。
  ///
  /// 契约：网络/解析失败一律返回空表（**不抛**）—— 播放列表少几集不该让播放失败。
  Future<List<SourceItemView>> seriesEpisodes(SourceItemView item);
}

// ─────────────────────────────────────────────────────────────────────────────
// 检查更新（第三十九轮：走 GitHub Release，能直接覆盖更新并重启）
// ─────────────────────────────────────────────────────────────────────────────

/// 「检查更新 / 直接更新」端口。
///
/// ## 为什么只抽象这 5 件事
/// 判定"要不要更新、挑哪个包"这类**规则**不是这里的：它们是 `dsanima_core` 的纯函数
/// （`decideUpdate` / `ReleaseInfo.tryParse` / `normalizeRepoSlug`），一份代码、
/// `core/test` 里离线钉死。这个端口只搬字节与启动进程：
/// * [latestRelease] —— 打 GitHub 的 API（网络）；
/// * [downloadAsset] —— 把发布包下到本地（网络 + 磁盘，带进度、可取消）；
/// * [prepareUpdate] —— 解压 + 写覆盖脚本 + 脱离父进程启动它（进程 + 文件系统）；
/// * [pendingUpdate] / [declarePending] —— 「我要升到哪一版」这条待办（重启后对账用）。
///
/// 检查与下载都可以带一个**可选**的只读令牌（第四十轮，见 [latestRelease] 的 `token`）：
/// 私有仓库、账号被 GitHub 限制可见性（匿名读什么都是 404）、以及匿名 60 次/小时的额度，
/// 三种情况都靠它。**空字符串 = 匿名请求**，是默认行为。
///
/// ## 契约
/// 失败**必须抛** [PortUnavailableException]（消息 + 怎么办都写全），绝不允许
/// "假装已是最新"或"假装下载成功"：用户看到的每一句话都要是真的。
/// 未接通时注入 `domain/unavailable.dart` 的 [UnavailableUpdatePort]。
abstract interface class UpdatePort {
  /// 取仓库最新一次发布（`GET /repos/<slug>/releases/latest`）。
  ///
  /// [token] 非空就带上 `Authorization: Bearer <token>`；空 = 匿名（默认）。
  /// 令牌**只从设置里来**，实现不许把它写进 URL、日志或报错文案里。
  Future<core_update.ReleaseInfo> latestRelease(String repoSlug, {String token = ''});

  /// 下载 [asset] 到本地的更新目录，返回落地的文件。
  ///
  /// * [onProgress] 收到「已下载字节 / 总字节」；总字节可能为 null（GitHub 没给）；
  /// * [isCancelled] 每收到一块问一次：返回 true 就**删掉半截文件**并抛
  ///   [PortUnavailableException]（`已取消下载`）—— 半截 zip 留在盘上会在下次
  ///   解压时报一个跟"取消"毫无关系的错，所以由实现负责清干净。
  /// * [token] 与 [latestRelease] 同源：**附件下载也要带它**
  ///   （私有/受限仓库的下载地址匿名同样是 404）；空 = 匿名。
  Future<File> downloadAsset(
    core_update.ReleaseAsset asset, {
    String token = '',
    void Function(int received, int? total)? onProgress,
    bool Function()? isCancelled,
  });

  /// 解压 [package]、写好覆盖脚本并**脱离父进程启动它**，然后返回。
  ///
  /// 脚本会等本进程退出后覆盖安装目录、再以新版本重启 —— 所以调用方拿到返回后
  /// 应该立刻走**宿主统一的退出流程**（`CloseCoordinator.quit()`：先放 Hive 锁、
  /// 再停边车），而不是在这里 `exit()`。
  Future<void> prepareUpdate(File package);

  /// 上一次"要升到哪一版"的待办记录；没有就 null（见 `core` 的 [core_update.PendingUpdate]）。
  Future<core_update.PendingUpdate?> pendingUpdate();

  /// 写下/清除那条待办（传 null = 清除）。
  Future<void> declarePending(core_update.PendingUpdate? pending);
}
