/// 未接通端口的**显式**实现。
///
/// 设计原则（task-4 要求「禁止假数据充当成功」）：
/// 这些实现绝不返回编造的数据；它们抛 [PortUnavailableException]，并把
/// 「缺什么 + 去哪里补」写成用户能看懂的中文提示，由 UI 原样展示。
///
/// 真实实现见 `state/engine_bootstrap.dart` / `state/player_adapter.dart`，
/// 二者都由 `main.dart` 在装配时注入替换。
library;

import 'dart:io';

import 'package:dsanima_core/update/update.dart' as core_update;

import 'bangumi.dart';
import 'bangumi_library.dart';
import 'episode_group.dart';
import 'models.dart';
import 'ports.dart';

const String _coreHint =
    '上游 dsanima_core 的能力尚未注入：请确认 core/ 已实现并在 app 启动时装配适配器';

/// 源未接通：搜索页/订阅页显示「源未接通」+ 这条提示。
class UnavailableSourcePort implements SourcePort {
  const UnavailableSourcePort();

  static const PortUnavailableException failure = PortUnavailableException(
    '源未接通：无法访问 nyaa.si / mikanani.me / 自定义 RSS',
    hint: '$_coreHint；也可先在「设置 → 网络」检查代理',  );

  @override
  List<SourceOption> get sources => const <SourceOption>[];

  @override
  Future<SourcePageView> latest(String sourceId, {int page = 1}) async =>
      throw failure;

  @override
  Future<SourcePageView> search(String sourceId, String keyword, {int page = 1}) async =>
      throw failure;
}

/// 追番表（主页）未接通：主页显示可行动错误，**绝不显示空表装成「今天没更新」**。
class UnavailableSchedulePort implements SchedulePort {
  const UnavailableSchedulePort();

  static const PortUnavailableException failure = PortUnavailableException(
    '追番表未接通：mikan 首页解析尚未装配',
    hint: '$_coreHint；主页需要 core 的 sources/mikan_schedule.dart',
  );

  @override
  bool get isAvailable => false;

  @override
  Future<ScheduleView> schedule() async => throw failure;

  @override
  Future<BangumiDetailView> bangumi(String bangumiId) async => throw failure;
}

/// 封面缓存未接通：封面一律降级成灰框「无封面」（不假装有图，也不联网）。
class UnavailableCoverCachePort implements CoverCachePort {
  const UnavailableCoverCachePort();

  @override
  Future<File?> fileFor(String url, {String? referer}) async => null;

  /// 未接通 ⇒ 永远"本地没有"（封面走灰框），与 [fileFor] 一致。
  @override
  File? cachedNow(String url) => null;
}

/// 今日推荐未接通：推荐 rail 显示可行动说明，**不塞假番**。
class UnavailableRecommendPort implements RecommendPort {
  const UnavailableRecommendPort();

  @override
  bool get isAvailable => false;

  @override
  Future<List<BangumiSubject>> recommend({required int seed, int? count}) async =>
      throw const PortUnavailableException(
        '今日推荐未接通：Bangumi API 客户端没装配',
        hint: '这是装配问题（main.dart 未注入 BangumiRecommendPort），请回报开发者',
      );
}

/// 动漫库未接通：页面显示可行动说明，**不塞假条目**。
class UnavailableBangumiLibraryPort implements BangumiLibraryPort {
  const UnavailableBangumiLibraryPort();

  @override
  bool get isAvailable => false;

  @override
  Future<BangumiLibraryPage> search(
    BangumiLibraryQuery query, {
    int offset = 0,
    int limit = kLibraryDefaultPageSize,
  }) async =>
      throw const PortUnavailableException(
        '动漫库未接通：Bangumi API 客户端没装配',
        hint: '这是装配问题（main.dart 未注入 BangumiLibraryService），请回报开发者',
      );

  @override
  Future<BangumiSubject> detail(int id) async => throw const PortUnavailableException(
        '动漫库未接通：Bangumi API 客户端没装配',
        hint: '这是装配问题（main.dart 未注入 BangumiLibraryService），请回报开发者',
      );

  /// 补充内容（角色 / 关联条目）**不抛**：它们是可选装饰，未接通时当"没有这两块"，
  /// 详情页主内容照常显示（不过 [isAvailable] 为 false，页面本来就显示未接通说明）。
  @override
  Future<BangumiSubjectExtra> extras(int id) async => BangumiSubjectExtra.empty;
}

/// 引擎未接通：所有需要边车的操作都明确失败（不伪造进度）。
class UnavailableEnginePort implements EnginePort {
  const UnavailableEnginePort();

  static const PortUnavailableException failure = PortUnavailableException(
    '引擎未连接：rqbit-engine 边车未启动或未装配',
    hint: '请到「设置 → 引擎」填写 rqbit-engine.exe 路径（或放到应用同目录），设置好下载目录后点「测试引擎连通」',
  );

  @override
  Future<EngineHealthView> health() async => throw failure;

  @override
  Future<EngineTorrentView> addMagnet(
    String magnet, {
    String? name,
    List<int>? onlyFiles,
    bool startPaused = false,
    String? subFolder,
  }) async =>
      throw failure;

  @override
  Future<List<EngineTorrentView>> list() async => throw failure;

  @override
  Future<void> pause(int id) async => throw failure;

  @override
  Future<void> resume(int id) async => throw failure;

  @override
  Future<void> remove(int id, {bool deleteFiles = false}) async => throw failure;

  @override
  Stream<List<EngineTorrentView>> watch() =>
      Stream<List<EngineTorrentView>>.error(failure);

  @override
  Uri? streamUrl(int id, int fileIndex) => null;
}

/// 队列未接通。
class UnavailableQueuePort implements QueuePort {
  const UnavailableQueuePort();

  static const PortUnavailableException failure = PortUnavailableException(
    '下载队列未接通：QueueManager 尚未装配',
    hint: _coreHint,
  );

  @override
  Stream<List<QueueJobView>> watchJobs() =>
      Stream<List<QueueJobView>>.error(failure);

  @override
  Future<QueueJobView> enqueuePlayNow(SourceItemView item,
          {List<SourceItemView> upNext = const <SourceItemView>[],
          List<SourceItemView> preheat = const <SourceItemView>[]}) async =>
      throw failure;

  @override
  Future<QueueJobView> enqueueDownload(SourceItemView item) async => throw failure;

  @override
  Future<void> attachToSubsRule(SourceItemView item) async => throw failure;

  @override
  Future<void> pauseJob(String jobId) async => throw failure;

  @override
  Future<void> resumeJob(String jobId) async => throw failure;

  @override
  Future<String?> removeJob(String jobId, {bool deleteFiles = false}) async =>
      throw failure;

  @override
  Future<String?> removeByEngine(int engineId, {bool deleteFiles = true}) async =>
      throw failure;

  @override
  Future<void> setPriority(String jobId, int priority) async => throw failure;

  @override
  Future<void> clearCompleted() async => throw failure;

  @override
  Future<String?> clearAll({bool deleteFiles = false}) async => throw failure;

  @override
  Future<void> settleAfterPlayback(int engineId) async => throw failure;

  @override
  Future<List<SourceItemView>> previewMatches(SubscriptionView subscription) async =>
      throw failure;

  @override
  Future<int> enqueueSeason(SubscriptionView subscription) async => throw failure;
}

/// 订阅未接通。
class UnavailableSubsPort implements SubsPort {
  const UnavailableSubsPort();

  static const PortUnavailableException failure = PortUnavailableException(
    '订阅功能未接通：规则引擎与 RSS 解析尚未装配',
    hint: _coreHint,
  );

  @override
  Stream<List<SubscriptionView>> watch() =>
      Stream<List<SubscriptionView>>.error(failure);

  @override
  Future<void> upsert(SubscriptionView subscription) async => throw failure;

  @override
  Future<void> remove(String id) async => throw failure;

  @override
  Future<SubsRefreshResult> refresh(String id) async => throw failure;

  @override
  Future<List<SourceItemView>> items(SubscriptionView subscription) async => throw failure;
}

/// 播放器未接通（装配根没注入 `playerPortProvider`：widget 测试，或播放窗口
/// 链路没接上）。
class UnavailablePlayerPort implements PlayerPort {
  const UnavailablePlayerPort();

  static const PortUnavailableException failure = PortUnavailableException(
    '播放器未接通：弹出播放窗口那条链路没接上',
    hint: '装配根要用 PlayerWindowPort 覆盖 playerPortProvider；'
        '组件测试里请注入一个假播放器端口',
  );

  @override
  bool get isAvailable => false;

  @override
  Future<void> open(PlayerRequest request, {EpisodeGrouping? episodeGroup}) async =>
      throw failure;

  @override
  Future<void> playOrPause() async => throw failure;

  @override
  Future<void> seek(Duration position) async => throw failure;

  @override
  Future<void> stop() async => throw failure;

  @override
  Stream<PlaybackSignal> get signals => const Stream<PlaybackSignal>.empty();

  @override
  Future<void> dispose() async {}
}

/// 运行时未接通：设置能保存，但无法下发到边车/源客户端。
class UnavailableLifecyclePort implements LifecyclePort {
  const UnavailableLifecyclePort();

  static const PortUnavailableException failure = PortUnavailableException(
    '设置已保存到本地，但未能生效：宿主运行时（引擎/源客户端）未接通',
    hint: '装配 dsanima_core 适配器后，保存设置会自动重启边车并重建源客户端',
  );

  @override
  Future<void> applySettings(AppSettings settings) async => throw failure;
}

/// 系统选择器未接通（`file_picker` 实现由 main.dart 注入；测试里注入假实现）。
class UnavailablePickerPort implements PickerPort {
  const UnavailablePickerPort();

  static const PortUnavailableException failure = PortUnavailableException(
    '系统目录选择器未接通',
    hint: '请直接在下拉/输入框里手填路径（例如 F:\\Anime）',
  );

  @override
  Future<String?> pickDirectory({String? title}) async => throw failure;

  @override
  Future<String?> pickFile({
    String? title,
    List<String> extensions = const <String>[],
  }) async =>
      throw failure;
}

/// 边车启动器未接通（真实实现由 main.dart 注入 core 的 `EngineRuntime`）。
class UnavailableEngineBootstrapPort implements EngineBootstrapPort {
  const UnavailableEngineBootstrapPort();

  @override
  bool get isRunning => false;

  @override
  Future<EngineStartOutcome> start({
    required AppSettings settings,
    required Directory supportDir,
  }) async =>
      EngineStartOutcome.failure(
        '边车启动器未接通：宿主没有注入 rqbit-engine 的启动实现',
        hint: '这是装配问题（main.dart 未注入 engineBootstrapPortProvider），请回报开发者',
      );

  @override
  Future<void> stop() async {}
}

/// 托盘未接通（需要 `tray_manager` 这类原生组件；由 Lead 决定是否引入）。
class UnavailableTrayPort implements TrayPort {
  const UnavailableTrayPort();

  @override
  bool get isAvailable => false;

  @override
  Future<void> show({required String tooltip}) async {}

  @override
  Future<void> hide() async {}

  @override
  Future<void> dispose() async {}

  @override
  Stream<TrayCommand> get commands => const Stream<TrayCommand>.empty();
}

/// 系统通知未接通（需要 `local_notifier` 这类原生组件）。
class UnavailableNotificationPort implements NotificationPort {
  const UnavailableNotificationPort();

  @override
  bool get isAvailable => false;

  @override
  Future<bool> notify({
    required String title,
    required String body,
    String? payload,
  }) async =>
      false;

  @override
  Stream<String> get clicks => const Stream<String>.empty();
}

/// 宿主数据层未接通：设置仍会保存，只是源/订阅/队列用不了。
class UnavailableHostDataPort implements HostDataPort {
  const UnavailableHostDataPort();

  static const PortUnavailableException failure = PortUnavailableException(
    '宿主数据层未接通：源/订阅/队列适配器还没装配',
    hint: '这是装配问题（main.dart 未注入 CoreHostDataPort），请回报开发者',
  );

  @override
  Future<void> applySettings(AppSettings settings) async => throw failure;

  @override
  Future<void> reconcile() async => throw failure;

  /// 没有宿主数据层 = 没有源客户端 = 补不了详情页。原样返回，让下游给出它自己的
  /// 真实错误（例如「这条结果既没有磁力链也没有 .torrent 直链」），
  /// 而不是在这里伪造一个"补全成功"。
  @override
  Future<SourceItemView> ensurePlayable(SourceItemView item) async => item;

  /// 没有宿主数据层 = 没有源客户端 = 取不到单集页。原样返回（调用方按"这一条认不出
  /// 属于哪部番"处理，别在这里假装认出来了）。
  @override
  Future<SourceItemView> episodeInfo(SourceItemView item) async => item;

  /// 没有宿主数据层 = 没有源客户端 = 取不到整部番的剧集清单。空表 = 播放列表只用
  /// 手头这一批（与旧行为一致），绝不假装"这就是全部"。
  @override
  Future<List<SourceItemView>> seriesEpisodes(SourceItemView item) async =>
      const <SourceItemView>[];
}

/// 更新端口未接通（测试 / 未装配）：**抛异常**，绝不假装"已是最新"。
///
/// 为什么这条必须诚实到底：「我明明发了新版，它却说已是最新」是最难自查的一类故障 ——
/// 用户会一直以为是自己发布方式错了。
class UnavailableUpdatePort implements UpdatePort {
  const UnavailableUpdatePort();

  static const PortUnavailableException failure = PortUnavailableException(
    '检查更新未接通：没有注入 GitHub 更新适配器',
    hint: '这是装配问题（main.dart 未注入 GitHubUpdatePort），请回报开发者',
  );

  @override
  Future<core_update.ReleaseInfo> latestRelease(String repoSlug, {String token = ''}) async =>
      throw failure;

  @override
  Future<File> downloadAsset(
    core_update.ReleaseAsset asset, {
    String token = '',
    void Function(int received, int? total)? onProgress,
    bool Function()? isCancelled,
  }) async => throw failure;

  @override
  Future<void> prepareUpdate(File package) async => throw failure;

  @override
  Future<core_update.PendingUpdate?> pendingUpdate() async => null;

  @override
  Future<void> declarePending(core_update.PendingUpdate? pending) async {}
}
