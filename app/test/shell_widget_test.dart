/// 宿主外壳 widget 测试（用假端口注入：不联网、不起引擎、不碰 libmpv）。
///
/// 覆盖 task-4 要求的三项：shell 导航、搜索结果渲染、队列列表渲染；
/// 另加 spec §7.4 定稿后的表格/语义色断言。
library;

import 'dart:async';

import 'package:dsanima/domain/episode_group.dart';
import 'package:dsanima/domain/models.dart';
import 'package:dsanima/domain/ports.dart';
import 'package:dsanima/domain/unavailable.dart';
import 'package:dsanima/app.dart';
import 'package:dsanima/state/playback.dart';
import 'package:dsanima/state/providers.dart';
import 'package:dsanima/theme/app_theme.dart';
import 'package:dsanima/theme/tokens.dart';
import 'package:dsanima/ui/queue_page.dart';
import 'package:dsanima/ui/first_run.dart';
import 'package:dsanima/ui/search_page.dart';
import 'package:dsanima/ui/settings_page.dart';
import 'package:dsanima/ui/shell.dart';
import 'package:dsanima/ui/widgets/ds_theme_reveal.dart';
import 'package:dsanima/ui/widgets/neo.dart';
import 'package:dsanima/ui/widgets/neo_dropdown.dart';
import 'package:dsanima/ui/widgets/search_sections.dart';
import 'package:dsanima_core/sources/kv.dart' show InMemoryKeyValueStore;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shikiin/shikiin.dart' as shikiin;

// ─────────────────────────────────────────────────────────────────────────────
// 测试替身（只存在于 test/ 下；生产代码里的「假实现」一律是显式报错）
// ─────────────────────────────────────────────────────────────────────────────

SourceItemView _item(
  String hash,
  String title, {
  int? seeders,
  int? sizeBytes,
  bool downloadable = true,
}) => SourceItemView(
  id: hash,
  sourceId: 'nyaa',
  title: title,
  magnet: downloadable ? 'magnet:?xt=urn:btih:$hash' : null,
  sizeBytes: sizeBytes,
  seeders: seeders,
  publishedAt: DateTime(2026, 10, 8, 12),
  group: 'TestGroup',
  episodeHints: const <String>['01'],
  extra: const <String, Object?>{'resolution': '1080p'},
);

class FakeSourcePort implements SourcePort {
  FakeSourcePort(this.items, {this.failure});

  final List<SourceItemView> items;
  final Object? failure;
  int calls = 0;

  @override
  List<SourceOption> get sources => const <SourceOption>[
    SourceOption(id: 'nyaa', displayName: 'nyaa.si 动漫区'),
    SourceOption(id: 'mikan', displayName: 'mikanani.me'),
  ];

  @override
  Future<SourcePageView> latest(String sourceId, {int page = 1}) async {
    calls++;
    final Object? error = failure;
    if (error != null) throw error;
    return SourcePageView(items: items, page: page, fetchedAt: DateTime(2026, 10, 8, 12));
  }

  @override
  Future<SourcePageView> search(String sourceId, String keyword, {int page = 1}) async =>
      latest(sourceId, page: page);
}

class FakeQueuePort implements QueuePort {
  FakeQueuePort(this.jobs, {this.downloadFails = true});

  final List<QueueJobView> jobs;

  /// 单条「下载」是否报错。默认 true 保留旧的"下载不可用"行为；
  /// 批量下载那条用例要的是**成功**（第二十三轮）。
  final bool downloadFails;

  final List<String> calls = <String>[];

  @override
  Stream<List<QueueJobView>> watchJobs() => Stream<List<QueueJobView>>.value(jobs);

  @override
  Future<QueueJobView> enqueuePlayNow(
    SourceItemView item, {
    List<SourceItemView> upNext = const <SourceItemView>[],
    List<SourceItemView> preheat = const <SourceItemView>[],
  }) async => throw const PortUnavailableException('测试替身：不真正点播');

  @override
  Future<QueueJobView> enqueueDownload(SourceItemView item) async {
    calls.add('download:${item.id}');
    if (downloadFails) throw const PortUnavailableException('测试替身：未实现下载');
    return QueueJobView(
      id: 'job-${item.id}',
      item: item,
      state: JobState.queued,
      createdAt: DateTime(2026, 10, 12, 12),
      updatedAt: DateTime(2026, 10, 12, 12),
    );
  }

  @override
  Future<void> attachToSubsRule(SourceItemView item) async => calls.add('subscribe:${item.id}');

  @override
  Future<void> pauseJob(String jobId) async => calls.add('pause:$jobId');

  @override
  Future<void> resumeJob(String jobId) async => calls.add('resume:$jobId');

  @override
  Future<String?> removeJob(String jobId, {bool deleteFiles = false}) async {
    calls.add('remove:$jobId:deleteFiles=$deleteFiles');
    return null;
  }

  @override
  Future<String?> removeByEngine(int engineId, {bool deleteFiles = true}) async {
    calls.add('removeByEngine:$engineId:deleteFiles=$deleteFiles');
    return null;
  }

  @override
  Future<void> setPriority(String jobId, int priority) async =>
      calls.add('priority:$jobId:$priority');

  @override
  Future<void> clearCompleted() async => calls.add('clearCompleted');

  @override
  Future<String?> clearAll({bool deleteFiles = false}) async {
    calls.add('clearAll:deleteFiles=$deleteFiles');
    return null;
  }

  @override
  Future<void> settleAfterPlayback(int engineId) async =>
      calls.add('settleAfterPlayback:$engineId');

  @override
  Future<List<SourceItemView>> previewMatches(SubscriptionView subscription) async =>
      const <SourceItemView>[];

  @override
  Future<int> enqueueSeason(SubscriptionView subscription) async => 0;
}

class FakeEnginePort implements EnginePort {
  FakeEnginePort({this.healthResponse = const EngineHealthView(ok: true, version: '0.1.0')});

  final EngineHealthView healthResponse;

  @override
  Future<EngineHealthView> health() async => healthResponse;

  @override
  Future<EngineTorrentView> addMagnet(
    String magnet, {
    String? name,
    List<int>? onlyFiles,
    bool startPaused = false,
    String? subFolder,
  }) async => throw const PortUnavailableException('测试替身：不加种');

  @override
  Future<List<EngineTorrentView>> list() async => const <EngineTorrentView>[];

  @override
  Future<void> pause(int id) async {}

  @override
  Future<void> resume(int id) async {}

  @override
  Future<void> remove(int id, {bool deleteFiles = false}) async {}

  @override
  Stream<List<EngineTorrentView>> watch() =>
      Stream<List<EngineTorrentView>>.value(const <EngineTorrentView>[]);

  @override
  Uri? streamUrl(int id, int fileIndex) =>
      Uri.parse('http://127.0.0.1:1/torrents/$id/files/$fileIndex/stream?token=t');
}

/// 假通知端口：测试里**不弹真通知**，只手动喂一条「点击」。
class FakeNotifierPort implements NotificationPort {
  final StreamController<String> _clicks = StreamController<String>.broadcast();
  final List<String> sent = <String>[];

  @override
  bool get isAvailable => true;

  @override
  Stream<String> get clicks => _clicks.stream;

  @override
  Future<bool> notify({required String title, required String body, String? payload}) async {
    sent.add('$title|$body|${payload ?? ''}');
    return true;
  }

  void click(String payload) => _clicks.add(payload);
}

/// 能真正点播的队列替身（返回 engineId/fileIndex，走完整点播链路）。
class PlayingQueuePort implements QueuePort {
  PlayingQueuePort(this.job);

  final QueueJobView job;

  @override
  Stream<List<QueueJobView>> watchJobs() => Stream<List<QueueJobView>>.value(<QueueJobView>[job]);
  @override
  Future<QueueJobView> enqueuePlayNow(
    SourceItemView item, {
    List<SourceItemView> upNext = const <SourceItemView>[],
    List<SourceItemView> preheat = const <SourceItemView>[],
  }) async => job;

  @override
  Future<QueueJobView> enqueueDownload(SourceItemView item) async => job;

  @override
  Future<void> attachToSubsRule(SourceItemView item) async {}

  @override
  Future<void> pauseJob(String jobId) async {}

  @override
  Future<void> resumeJob(String jobId) async {}

  @override
  Future<String?> removeJob(String jobId, {bool deleteFiles = false}) async => null;

  @override
  Future<String?> removeByEngine(int engineId, {bool deleteFiles = true}) async => null;

  @override
  Future<void> setPriority(String jobId, int priority) async {}

  @override
  Future<void> clearCompleted() async {}

  @override
  Future<String?> clearAll({bool deleteFiles = false}) async => null;

  @override
  Future<void> settleAfterPlayback(int engineId) async {}

  @override
  Future<List<SourceItemView>> previewMatches(SubscriptionView subscription) async =>
      const <SourceItemView>[];

  @override
  Future<int> enqueueSeason(SubscriptionView subscription) async => 0;
}

/// 记录 open() 的播放器替身（**不碰 libmpv、不真开窗口**）。
///
/// 用户 2026-10-10 的硬要求是「只有弹出窗口播放」，所以宿主侧的断言落在这一层：
/// 宿主只会**投递一条播放请求**给播放器端口（真实实现是跨窗口投递），
/// 主窗口自己不会出现任何播放面。
class RecordingPlayerPort implements PlayerPort {
  final List<PlayerRequest> opened = <PlayerRequest>[];
  final List<EpisodeGrouping?> groups = <EpisodeGrouping?>[];
  final StreamController<PlaybackSignal> _signals = StreamController<PlaybackSignal>.broadcast();

  @override
  bool get isAvailable => true;

  @override
  Future<void> open(PlayerRequest request, {EpisodeGrouping? episodeGroup}) async {
    opened.add(request);
    groups.add(episodeGroup);
  }

  @override
  Future<void> playOrPause() async {}

  @override
  Future<void> seek(Duration position) async {}

  @override
  Future<void> stop() async {}

  @override
  Stream<PlaybackSignal> get signals => _signals.stream;

  @override
  Future<void> dispose() async {
    await _signals.close();
  }
}

QueueJobView _job(String id, JobState state, {int priority = 10, int? engineId}) => QueueJobView(
  id: id,
  item: _item('hash$id', '葬送的芙莉莲 - 第 01 话 [1080p]'),
  state: state,
  priority: priority,
  engineId: engineId,
  createdAt: DateTime(2026, 10, 8, 12),
  updatedAt: DateTime(2026, 10, 8, 12),
);

/// 测试脚手架：假端口 + 内存存储 + 宿主主题。
Widget harness(
  Widget child, {
  SourcePort? source,
  QueuePort? queue,
  EnginePort? engine,
  LifecyclePort? lifecycle,
  AppSettings settings = const AppSettings(firstRunCompleted: true),
}) {
  return ProviderScope(
    overrides: [
      keyValueStoreProvider.overrideWithValue(
        InMemoryKeyValueStore(<String, Object?>{SettingsController.storageKey: settings.toJson()}),
      ),
      sourcePortProvider.overrideWithValue(source ?? FakeSourcePort(const <SourceItemView>[])),
      queuePortProvider.overrideWithValue(queue ?? FakeQueuePort(const <QueueJobView>[])),
      enginePortProvider.overrideWithValue(engine ?? FakeEnginePort()),
      subsPortProvider.overrideWithValue(const UnavailableSubsPort()),
      playerPortProvider.overrideWithValue(const UnavailablePlayerPort()),
      lifecyclePortProvider.overrideWithValue(lifecycle ?? const UnavailableLifecyclePort()),
      pickerPortProvider.overrideWithValue(const UnavailablePickerPort()),
    ],
    child: MaterialApp(
      theme: buildDsanimaTheme(),
      home: Scaffold(body: child),
    ),
  );
}

void _sizeTo(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

/// 「单独源模式」的设置。
///
/// 第 14 轮起默认是**聚合模式**（顶部三颗 chip、没有源下拉），而下面这些用例盯的是
/// 单源那条老路（源下拉 / 源报错 / 空结果 / 页码条）—— 显式切回单独源模式再验，
/// 聚合那套另有专门的用例。
const AppSettings kSingleMode = AppSettings(
  firstRunCompleted: true,
  searchMode: SearchMode.single,
);

/// 状态栏那颗引擎点。用它自己的 key 当锚点（tooltip 文本随连接状态与目录提示变；
/// 侧栏底部还挂着一个同样写着状态文本的引擎块，按 tooltip 匹配会一次命中两个）。
Finder _engineDot() => find.byKey(dsEngineDotKey);

/// 假的播放状态：外壳读的只有 `nowPlaying`（有/没有）与 `playing`，
/// 所以给一个固定状态就够了 —— 不碰引擎、不碰 mpv、不打网络。
class _FakePlayback extends PlaybackController {
  _FakePlayback(this._initial);

  final PlaybackUiState _initial;

  @override
  PlaybackUiState build() => _initial;
}

void main() {
  // ── 第二十七轮补记②：左下角多了一行（观看记录），矮窗口下也不能被它撑破 ────────

  group('侧栏左下角多了一行之后：矮窗口不溢出（第二十七轮补记②）', () {
    // 侧栏那一列是**不可滚动**的 `Column`：顶部 5 项 + `Spacer()` + 左下角
    // （观看记录 / 在播时的继续播放 / 设置齿轮）+ 那条铺满整窗的底部状态条。
    // 把「观看记录」从顶部列表搬下来之后，左下角从 2 行变成 3 行（在播时）——
    // 矮到某个高度就会 `RenderFlex overflowed by N pixels`（黄条），所以钉住门槛：
    // 到 **400px** 高为止都不许溢出（实测余量很大），且那一行还得在（不是被压没了）。
    for (final double height in <double>[700, 520, 400]) {
      testWidgets('窗口高 ${height.toInt()}px：侧栏不溢出', (WidgetTester tester) async {
        _sizeTo(tester, Size(1200, height));
        await tester.pumpWidget(harness(const DsShell()));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull,
            reason: '侧栏在 ${height.toInt()}px 高时溢出了（左下角那一块被顶出窗口）');
        expect(find.byKey(dsSidebarFooterRowKey(ShellTab.history)), findsOneWidget,
            reason: '矮窗口下左下角那一行也得在');
      });
    }
  });

  testWidgets('外壳：左侧栏每个目的地都在，点击切换内容区索引（设置在最左下角那颗齿轮上）', (
    WidgetTester tester,
  ) async {
    _sizeTo(tester, const Size(1600, 1000));

    await tester.pumpWidget(
      harness(
        const DsShell(),
        source: FakeSourcePort(<SourceItemView>[_item('abc', '芙莉莲 第 01 话')]),
      ),
    );
    await tester.pumpAndSettle();

    // 顶部导航区每个目的地都在（`shellNavTabs` = ShellTab 去掉 settings 与 history，
    // 第三十三轮之后是 主页/动漫库/搜索/正在追/队列/已完成 6 项）。
    for (final ShellTab tab in shellNavTabs) {
      expect(find.text(tab.label), findsWidgets, reason: '缺少导航项：${tab.label}');
    }
    // 用户 2026-10-12 第十四轮：「主窗口的设置改为……左下角」（原话先说右下角、随后更正）
    // —— 设置**不再**是列表里的一项，而是左下角那颗齿轮。
    expect(find.byKey(dsSettingsGearKey), findsOneWidget, reason: '左下角必须有设置齿轮');
    // 第二十五轮（用户：「设置按钮旁边加上设置文字」）：齿轮右边写着「设置」，
    // 但它仍然**不在**导航列表里（列表只有 shellNavTabs 那几项）。
    expect(find.text(ShellTab.settings.label), findsOneWidget, reason: '齿轮旁边那颗「设置」字');
    final Rect gearRect = tester.getRect(find.byKey(dsSettingsGearKey));
    final Rect settingsTextRect = tester.getRect(find.text(ShellTab.settings.label));
    expect(settingsTextRect.left, greaterThanOrEqualTo(gearRect.right - 2),
        reason: '「设置」两个字在齿轮**右边**（旁边）');
    expect((settingsTextRect.center.dy - gearRect.center.dy).abs(), lessThan(5),
        reason: '跟齿轮同一行（第二十六轮齿轮缩到 16：中心允许差几像素）');

    // 第二十一轮：「已缓存」页按用户要求整页删掉（侧栏随之少一项）。
    // `ShellTab.values` 是侧栏与 IndexedStack 的**唯一出处**（`tab.index` 就是下标），
    // 所以这里钉住它的形状 —— 以后谁要加回来，必须同时补 IndexedStack 里的那一页。
    expect(ShellTab.values.length, 8,
        reason: '主页/动漫库/搜索/正在追/队列/已完成/观看记录/设置 = 8'
            '（第三十三轮新增「动漫库」，排在主页下面；第二十七轮：订阅页删掉、新增观看记录）');
    expect(ShellTab.values.map((ShellTab t) => t.label), isNot(contains('已缓存')),
        reason: '侧栏不该再有「已缓存」这一项');
    expect(ShellTab.values.map((ShellTab t) => t.label), isNot(contains('订阅')),
        reason: '第二十七轮：「订阅」页整页删掉，订阅功能搬进「正在追」');
    // ⚠️ **第二十七轮补记**（用户：「观看记录改到左下角设置的上面」）：
    // 第一版把「观看记录」当成第 6 个导航项排在顶部列表最后 —— 顶部列表底下隔着一个
    // `Spacer()` 才是设置入口，它离设置有一大段空白，不是"设置的上面"。
    // 现在：① 它**不在**顶部导航列表里；② 它在左下角那一块（设置上面）。
    for (final ShellTab tab in shellFooterTabs) {
      expect(shellNavTabs, isNot(contains(tab)),
          reason: '${tab.label} 已经从顶部导航列表搬到左下角，不该还留在 shellNavTabs 里');
      final Finder row = find.byKey(dsSidebarFooterRowKey(tab));
      expect(row, findsOneWidget, reason: '左下角缺「${tab.label}」那一行');
      final Rect rowRect = tester.getRect(row);
      // 在侧栏里（侧栏固定 184px），不是在底部状态条那条通栏里。
      expect(rowRect.left, lessThan(184));
      expect(rowRect.right, lessThanOrEqualTo(184));
      // 在**导航列表下面**（= 真的落在左下角那一块，而不是混在顶部的 5 项里）。
      expect(rowRect.top, greaterThan(tester.getRect(find.text(ShellTab.completed.label).first).bottom),
          reason: '「${tab.label}」要落在左下角那一块，不是顶部导航列表里');
      // 在设置那一行**上面**（用户原话：「改到左下角设置的上面」）。
      expect(rowRect.bottom, lessThanOrEqualTo(gearRect.top),
          reason: '「${tab.label}」要在设置那一行上面');
    }
    // 每个目的地恰好出现在一处：顶部导航 / 左下角那一块 / 设置入口（齿轮那一行）。
    expect(
      <ShellTab>[...shellNavTabs, ...shellFooterTabs, ShellTab.settings],
      containsAll(ShellTab.values),
      reason: '有目的地没被任何一处列出来',
    );
    expect(shellNavTabs.length + shellFooterTabs.length + 1, ShellTab.values.length,
        reason: '同一个目的地被列了两处');

    int contentIndex() => tester.widget<IndexedStack>(find.byKey(dsShellContentKey)).index!;

    // spec §7.5：主页是侧栏第一项，也是默认 tab
    expect(contentIndex(), ShellTab.home.index);

    // 用户 2026-10-12 第二十一轮：「去掉已缓存页面，有已完成了」——
    // 侧栏不再有「已缓存」这一项（测试不再遍历它）。
    for (final ShellTab tab in <ShellTab>[
      ShellTab.history,
      ShellTab.queue,
      ShellTab.completed,
      ShellTab.search,
      ShellTab.home,
    ]) {
      // 侧栏在树里排在内容区之前，`.first` 命中的就是导航项。
      await tester.tap(find.text(tab.label).first);
      await tester.pumpAndSettle();
      expect(contentIndex(), tab.index, reason: '点击「${tab.label}」后内容区没切过去');
    }

    // 齿轮 = 设置页（唯一的设置入口）。
    await tester.tap(find.byKey(dsSettingsGearKey));
    await tester.pumpAndSettle();
    expect(contentIndex(), ShellTab.settings.index, reason: '点左下角齿轮该切到设置页');

    // 「设置」两个字也**可点**（不是纯装饰）。
    await tester.tap(find.text(ShellTab.home.label).first);
    await tester.pumpAndSettle();
    expect(contentIndex(), ShellTab.home.index);
    await tester.tap(find.text(ShellTab.settings.label));
    await tester.pumpAndSettle();
    expect(contentIndex(), ShellTab.settings.index, reason: '点「设置」两个字也该切到设置页');
  });

  // ── 第二十五轮：导航项悬停不再「黑一下」，而是在上面就一直黑着 ────────────────

  testWidgets('导航项：悬停 = 实色凹槽底并**一直保持**（移开才恢复，没有忽明忽暗）', (WidgetTester tester) async {
    _sizeTo(tester, const Size(1600, 1000));

    await tester.pumpWidget(harness(const DsShell(), source: FakeSourcePort(<SourceItemView>[])));
    await tester.pumpAndSettle();

    /// 某一项最靠近文字的那层 Container 底色（就是那个胶囊）。
    ///
    /// ⚠️ 用**没有选中**的那一项（队列）：选中的那一项本来就是凹槽底 + 强调色文字，
    /// 拿它测悬停分不出"选中"还是"悬停"。
    Color? faceOf(String label) {
      for (final Element e
          in find.ancestor(of: find.text(label).first, matching: find.byType(Container)).evaluate()) {
        final Decoration? d = (e.widget as Container).decoration;
        if (d is BoxDecoration) return d.color;
      }
      return null;
    }

    const String probe = '队列';
    // 静止时：透明（不占视觉）+ 次级文字色。
    expect(faceOf(probe), Colors.transparent);
    expect(tester.widget<Text>(find.text(probe).first).style?.color, DsTokens.whiteInk.text2);

    final TestGesture gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(gesture.removePointer);
    await gesture.moveTo(tester.getCenter(find.text(probe).first));
    await tester.pumpAndSettle();

    // 悬停：**实色**凹槽底（旧实现是 `raised @55%`：在侧栏底色上等于看不见，
    // 而透明→它的过渡中间帧会先暗一下，就是用户看到的那一下"黑"）。
    expect(
      faceOf(probe),
      DsTokens.whiteInk.sunken,
      reason: '悬停底色必须是实色凹槽色（不是半透明）',
    );
    // 文字也跟着变深（t.text 而不是 t.text2）。
    expect(tester.widget<Text>(find.text(probe).first).style?.color, DsTokens.whiteInk.text);

    // 指针不动、时间过去 → 仍然是黑的（"鼠标在上面就黑着"）。
    await tester.pump(const Duration(milliseconds: 400));
    expect(faceOf(probe), DsTokens.whiteInk.sunken);

    // 移开 → 恢复透明 + 文字回到次级色。
    await gesture.moveTo(const Offset(4, 4));
    await tester.pumpAndSettle();
    expect(faceOf(probe), Colors.transparent);
    expect(tester.widget<Text>(find.text(probe).first).style?.color, DsTokens.whiteInk.text2);
  });

  // ── 第二十六轮：设置入口改成「跟其他按钮一样的形态」──────────────────────────

  testWidgets('设置入口：与导航项同一形态 —— 整行命中区、悬停实色凹槽、选中强调色', (WidgetTester tester) async {
    _sizeTo(tester, const Size(1600, 1000));

    await tester.pumpWidget(harness(const DsShell(), source: FakeSourcePort(<SourceItemView>[])));
    await tester.pumpAndSettle();

    // ⚠️ 光按文字找会命中**两处**：「设置」既是左下角这一行的文字，也是切到设置页之后
    // 顶部工具条上的页名（`_Toolbar` 画的是 `tab.label`）。用字号把侧栏那一处挑出来
    //（侧栏行是 `DsTypeScale.secondary`，工具条页名是 `DsTypeScale.title`）。
    final Finder settingsLabel = find.byWidgetPredicate(
      (Widget w) =>
          w is Text &&
          w.data == ShellTab.settings.label &&
          w.style?.fontSize == DsTypeScale.secondary,
    );

    /// 设置那一行最贴近文字的 Container 底色（与导航项的 `faceOf` 同一口径）。
    Color? settingsFace() {
      for (final Element e
          in find.ancestor(of: settingsLabel, matching: find.byType(Container)).evaluate()) {
        final Decoration? d = (e.widget as Container).decoration;
        if (d is BoxDecoration) return d.color;
      }
      return null;
    }

    // 静止（当前不在设置页）：透明，跟导航项静止时一样。
    expect(settingsFace(), Colors.transparent);
    expect(
      tester.widget<Text>(settingsLabel).style?.color,
      DsTokens.whiteInk.text2,
      reason: '静止时用次级文字色（与导航项一致）',
    );

    final TestGesture gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(gesture.removePointer);
    await gesture.moveTo(tester.getCenter(settingsLabel));
    await tester.pumpAndSettle();

    // 悬停：**实色**凹槽底 + 文字提到 `t.text`（第二十五轮定的规则，现在设置项也走它）。
    expect(settingsFace(), DsTokens.whiteInk.sunken, reason: '悬停 = 实色凹槽底（与导航项同一种形态）');
    expect(tester.widget<Text>(settingsLabel).style?.color, DsTokens.whiteInk.text);

    // 指针不动也不变（"鼠标在上面就黑着"）。
    await tester.pump(const Duration(milliseconds: 400));
    expect(settingsFace(), DsTokens.whiteInk.sunken);

    // 命中区是**整行**：点齿轮图标右边的内边距（原先那颗 30×30 按钮之外）也能切到设置页。
    final Rect gearRect = tester.getRect(find.byKey(dsSettingsGearKey));
    final Rect labelRect = tester.getRect(settingsLabel);

    // 「跟其他的按钮一样的形态」的**硬指标**：悬停/选中那层高亮与 7 个导航项**同宽**
    //（独立审查抓到过一版：设置项只有内容宽 ~64px、图标还多缩进 8px，看着就是另一种控件）。
    final Rect settingsFaceRect = tester.getRect(
      find.ancestor(of: settingsLabel, matching: find.byType(Container)).first,
    );
    final Rect navFaceRect = tester.getRect(
      find.ancestor(of: find.text('队列').first, matching: find.byType(Container)).first,
    );
    expect(settingsFaceRect.width, closeTo(navFaceRect.width, 0.5),
        reason: '设置项那层高亮要与导航项**同宽**（不是收缩到内容宽度）');
    expect(settingsFaceRect.left, closeTo(navFaceRect.left, 0.5),
        reason: '左边界也要对齐：两者的图标与文字必须落在同一列');

    await gesture.moveTo(Offset(labelRect.right + 2, gearRect.center.dy));
    await tester.pumpAndSettle();
    expect(settingsFace(), DsTokens.whiteInk.sunken, reason: '文字右侧那条内边距也在命中区里（与导航项同宽）');

    int contentIndex() => tester.widget<IndexedStack>(find.byKey(dsShellContentKey)).index!;
    expect(contentIndex(), ShellTab.home.index);
    await tester.tapAt(Offset(labelRect.right + 2, gearRect.center.dy));
    await tester.pumpAndSettle();
    expect(contentIndex(), ShellTab.settings.index, reason: '整行任意一点都该切到设置页');

    // 选中态：图标与文字都走强调色（与导航项的选中态一致）。
    // ⚠️ 先切回主页再断言：设置页自己的正文里也会出现「设置」两个字，
    // 用全局 `find.text` 会在那个时刻一次命中多个（`DsShell` 里侧栏那一个才算）。
    // 选中态：图标与文字都走强调色（与导航项的选中态一致）——就在**已经切到设置页**
    // 的这个时刻断言，别先切回去（切回去就不是选中态了）。
    // 选中态：图标与文字都走**该目的地的标识色相**（第五十二轮：设置 = slate）——
    // 不再是统一的 accent，颜色用于"按颜色认页"（用户 2026-10-17「整个项目太素」）。
    expect(
      tester.widget<Text>(settingsLabel).style?.color,
      DsTokens.whiteInk.hueInk(DsHue.slate),
      reason: '选中时文字用该页的色相 ink',
    );
    expect(
      tester.widget<Icon>(find.byKey(dsSettingsGearKey)).color,
      DsTokens.whiteInk.hueOnFill(DsHue.slate),
      reason: '选中时齿轮在色相实底上，前景自动取反差色',
    );
  });

  testWidgets('搜索页：默认不加载 → 点「搜索」才 loading → 结果表格（4 列表头 + 属性并进番名副行）', (
    WidgetTester tester,
  ) async {
    _sizeTo(tester, const Size(1500, 1500));

    final FakeSourcePort source = FakeSourcePort(<SourceItemView>[
      _item('hash1', '葬送的芙莉莲 - 第 01 话 [1080p][简繁]', seeders: 42, sizeBytes: 734003200),
      _item('hash2', '葬送的芙莉莲 - 第 02 话 [1080p][简繁]', seeders: 0, sizeBytes: 524288000),
    ]);
    await tester.pumpWidget(harness(const SearchPage(), source: source, settings: kSingleMode));
    // 用户 2026-10-12：「搜索页改成默认不加载，只有个搜索，搜索后才有」。
    await tester.pumpAndSettle();
    expect(find.textContaining('在搜索框里输入番名'), findsOneWidget);
    expect(source.calls, 0, reason: '默认不加载 = 进页面一条网络都不打');

    await tester.tap(find.widgetWithText(NeoButton, '搜索'));
    await tester.pumpAndSettle();
    expect(source.calls, greaterThan(0));
    // 表头：用户 2026-10-10 第 1 轮问答把 9 列砍成 5 列
    //（集数/画质/字幕/字幕组并进番名那一列的副行）；
    // 用户 2026-10-11「把做种数去掉」再砍一列（做种），所以现在是 4 列。
    for (final String column in <String>['番名', '大小', '状态', '操作']) {
      expect(find.text(column), findsWidgets, reason: '缺表头列：$column');
    }
    for (final String gone in <String>['#', '集数', '画质', '字幕', '字幕组', '做种']) {
      // 第四十五轮起把这条守卫**收窄到表格内部**：查询条上多了一颗「字幕组」筛选 chip，
      // 它本来就写着「字幕组」三个字。这里要防的是"列回潮"，不是"这个词出现在别处"。
      expect(
        find.descendant(of: find.byType(SearchResultsTable), matching: find.text(gone)),
        findsNothing,
        reason: '$gone 这一列应该已经合并/删掉了',
      );
    }
    // 行内容
    expect(find.textContaining('葬送的芙莉莲 - 第 01 话'), findsWidgets);
    expect(find.textContaining('葬送的芙莉莲 - 第 02 话'), findsWidgets);
    // 做种数字本身也不许上屏（这是"做种列回潮"的守卫：删了表头却漏了行内数字）。
    expect(find.text('42'), findsNothing, reason: '用户 2026-10-11：做种数不再显示');
    // 属性现在都在番名下的副行里：一行文本里同时出现字幕组 / 画质 / 集数
    expect(find.textContaining('TestGroup'), findsWidgets);
    expect(find.textContaining('1080p'), findsWidgets);
    expect(find.textContaining('MiB'), findsWidgets);
    // 结果表格结构本身
    expect(find.byType(SearchResultsTable), findsOneWidget);
  });

  testWidgets('搜索页：批量选择下载（用户 2026-10-12 第二十三轮）', (WidgetTester tester) async {
    _sizeTo(tester, const Size(1500, 1200));

    final FakeSourcePort source = FakeSourcePort(<SourceItemView>[
      _item('hash1', '葬送的芙莉莲 - 第 01 话 [1080p]'),
      _item('hash2', '葬送的芙莉莲 - 第 02 话 [1080p]'),
      // 没有磁力链：勾不上，也不能混进批量里
      _item('hash3', '葬送的芙莉莲 - 第 03 话 [1080p]', downloadable: false),
    ]);
    final FakeQueuePort queue = FakeQueuePort(const <QueueJobView>[], downloadFails: false);
    await tester.pumpWidget(
      harness(const SearchPage(), source: source, queue: queue, settings: kSingleMode),
    );
    await tester.tap(find.widgetWithText(NeoButton, '搜索'));
    await tester.pumpAndSettle();

    // 批量条在结果表格**上面**：一条没勾时按钮不可点，也不该有"下载选中"的错觉。
    expect(find.text('已选 0 条'), findsOneWidget);
    // 没有磁力链的那条不给勾（它的 tooltip 说清为什么）。
    expect(find.byTooltip('这条既没有磁力/直链，也没有详情页可补链，不能下载'), findsOneWidget);

    // 勾一条 → 计数与按钮文案跟着走。
    await tester.tap(find.byTooltip('勾上：可以和其他条一起批量下载').first);
    await tester.pumpAndSettle();
    expect(find.text('已选 1 条'), findsOneWidget);
    expect(find.widgetWithText(NeoButton, '下载选中 1 条'), findsOneWidget);

    // 表头那颗勾 = 全选本页（本页只有 2 条可下载）。
    await tester.tap(find.byTooltip('全选本页（2 条可下载）'));
    await tester.pumpAndSettle();
    expect(find.text('已选 2 条'), findsOneWidget);

    await tester.tap(find.widgetWithText(NeoButton, '下载选中 2 条'));
    await tester.pumpAndSettle();

    // 一次点下去：队列收到两条（第三条没有磁力链，连试都不试）。
    expect(queue.calls, <String>['download:hash1', 'download:hash2']);
    expect(find.textContaining('已加入下载队列 2 条'), findsOneWidget);
    // 加完清空勾选：留着的话下一次点会重复入队。
    expect(find.text('已选 0 条'), findsOneWidget);

    // 排掉 SnackBar 的自动关闭定时器（否则用例结束时会报"Timer still pending"）。
    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();
  });

  testWidgets('搜索页：底部只有页码条，没有「加载更多」（用户 2026-10-12）', (WidgetTester tester) async {
    _sizeTo(tester, const Size(1400, 900));

    final FakeSourcePort source = FakeSourcePort(<SourceItemView>[
      for (int i = 1; i <= 45; i++) _item('hash$i', '葬送的芙莉莲 - 第 $i 话 [1080p]', seeders: 1),
    ]);
    await tester.pumpWidget(harness(const SearchPage(), source: source, settings: kSingleMode));
    await tester.tap(find.widgetWithText(NeoButton, '搜索'));
    await tester.pumpAndSettle();

    // 用户原话：「搜索页的加载更多去掉，不应该有」。
    expect(find.text('加载更多'), findsNothing);
    // 页码条还在（一页 20 条，45 条 = 3 页）：点页码仍然能翻到别的页。
    // 页脚只报"我在第几页"，不再报总数（用户 2026-10-12 第八轮）。
    expect(find.text('第 1 页'), findsOneWidget);
    expect(find.byTooltip('跳到第 2 页'), findsOneWidget);
    expect(find.byTooltip('跳到第 3 页'), findsOneWidget);
    // 当前页不给点（工具提示换成"当前第几页"，点了也不动）。
    expect(find.byTooltip('当前第 1 页'), findsOneWidget);
    // 窗口永远 20 条（表格是懒构建的，所以直接问 provider 要真实窗口）。
    final ProviderContainer container =
        ProviderScope.containerOf(tester.element(find.byType(SearchPage)));
    expect(container.read(searchProvider).items.length, 20);
    expect(container.read(searchProvider).fetched.length, 45, reason: '池子留住源给的全部条目');
    expect(container.read(searchProvider).items.first.id, 'hash1');
    expect(container.read(searchProvider).items.last.id, 'hash20');
  });

  testWidgets('搜索页：不显示总页数，末页数字要真翻到才出现（用户 2026-10-12 第八轮）', (
    WidgetTester tester,
  ) async {
    _sizeTo(tester, const Size(1400, 900));

    // mikan 的真实形态：搜索页一次给 1000 条 = 正好 50 页（所以"只有 50 页"）。
    final FakeSourcePort source = FakeSourcePort(<SourceItemView>[
      for (int i = 1; i <= 1000; i++) _item('hash$i', '芙莉莲 - 第 $i 话 [1080p]', seeders: 1),
    ]);
    await tester.pumpWidget(harness(const SearchPage(), source: source, settings: kSingleMode));
    await tester.tap(find.widgetWithText(NeoButton, '搜索'));
    await tester.pumpAndSettle();

    // 用户原话：「为什么只有 50 页，不要固定页数，加载出数据就加一页」。
    expect(find.text('第 1 页'), findsOneWidget);
    expect(find.textContaining('/ 50'), findsNothing, reason: '不许再显示「第 1 / 50 页」');
    expect(find.textContaining('共 50 页'), findsNothing, reason: '不许再显示「共 N 页」');
    expect(find.byTooltip('跳到第 50 页'), findsNothing, reason: '末页数字不能一上来就挂在页码条上');
    // 右边只留一个省略号表示"后面还有"，数字随翻页长出来。
    expect(find.byTooltip('跳到第 2 页'), findsOneWidget, reason: '当前页右边那一页要能直接点');
    expect(find.text('…'), findsOneWidget);

    // 翻到第 3 页：窗口跟着右移，末页数字依然不出现。
    final ProviderContainer container =
        ProviderScope.containerOf(tester.element(find.byType(SearchPage)));
    await container.read(searchProvider.notifier).goToPage(3);
    await tester.pumpAndSettle();
    expect(find.text('第 3 页'), findsOneWidget);
    expect(find.byTooltip('跳到第 4 页'), findsOneWidget);
    expect(find.byTooltip('跳到第 1 页'), findsOneWidget, reason: '首页永远留一个入口');
    expect(find.byTooltip('跳到第 50 页'), findsNothing);
  });

  testWidgets('搜索结果表格：状态列只看磁力链与引擎连接，做种数不上屏（用户 2026-10-11）', (
    WidgetTester tester,
  ) async {
    _sizeTo(tester, const Size(1400, 900));

    final DsTokens t = DsTokens.whiteInk;

    // ① 引擎未连接：两条都**有磁力链**，所以状态都该是「引擎未连接」。
    // 关键是 h2 的 `seeders: 0` —— 旧实现按做种数把它写成「无种子」，新实现必须不再被
    // 源的做种数左右（nyaa 之外的源根本不给做种数，`null` 会被旧逻辑当成"无种子"）。
    await tester.pumpWidget(
      ProviderScope(
        overrides: [keyValueStoreProvider.overrideWithValue(InMemoryKeyValueStore())],
        child: MaterialApp(
          theme: buildDsanimaTheme(),
          home: Scaffold(
            body: SearchResultsTable(
              items: <SourceItemView>[
                _item('h1', 'A 第 01 话', seeders: 3, sizeBytes: 1024),
                _item('h2', 'B 第 02 话', seeders: 0, sizeBytes: 1024),
              ],
              engineConnected: false,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('引擎未连接'), findsNWidgets(2));
    expect(find.text('可播'), findsNothing);
    expect(find.text('无种子'), findsNothing, reason: '做种数不再参与状态判断，这句文案已经不存在');
    expect(find.text('3'), findsNothing, reason: '做种数不再上屏');
    expect(find.text('0'), findsNothing, reason: '做种数不再上屏');
    // 语义色仍然按状态给（等价于旧用例「0 做种用失败色」那层断言：颜色没丢，判据换了）。
    expect(tester.widget<Text>(find.text('引擎未连接').first).style!.color, t.danger);

    // ② 无磁力链 + 引擎已连接：状态是警告色的「无磁力链」，而且操作列的播放键禁用
    //（`hasTorrentSource == false` → 图标退到 t.text3），有磁力链的那条仍是强调色。
    await tester.pumpWidget(
      ProviderScope(
        overrides: [keyValueStoreProvider.overrideWithValue(InMemoryKeyValueStore())],
        child: MaterialApp(
          theme: buildDsanimaTheme(),
          home: Scaffold(
            body: SearchResultsTable(
              items: <SourceItemView>[
                const SourceItemView(id: 'h3', sourceId: 'nyaa', title: 'C 第 03 话'),
                _item('h4', 'D 第 04 话', seeders: 0, sizeBytes: 1024),
              ],
              engineConnected: true,
              onPlay: (SourceItemView _) {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('无磁力链'), findsOneWidget);
    expect(find.text('可播'), findsOneWidget);
    expect(tester.widget<Text>(find.text('无磁力链')).style!.color, t.warning);
    final List<Icon> plays = tester.widgetList<Icon>(find.byIcon(Icons.play_arrow)).toList();
    expect(plays.length, 2);
    expect(plays[0].color, t.text3, reason: '没有磁力链的条目：播放键禁用（图标退到 t.text3）');
    expect(plays[1].color, t.accent, reason: '有磁力链的条目：播放键可用（强调色）');
  });

  testWidgets('搜索页：源报错 → 可行动错误（不是空列表）', (WidgetTester tester) async {
    _sizeTo(tester, const Size(1400, 1200));

    await tester.pumpWidget(
      harness(
        const SearchPage(),
        source: FakeSourcePort(
          const <SourceItemView>[],
          failure: const PortUnavailableException('源未接通：无法访问 nyaa.si', hint: '检查网络或到「设置 → 网络」配置代理'),
        ),
        settings: kSingleMode,
      ),
    );
    // 默认不加载：先点「搜索」，错误才可能出现（不点就永远只有那句提示）。
    await tester.tap(find.widgetWithText(NeoButton, '搜索'));
    await tester.pumpAndSettle();

    expect(find.textContaining('源未接通'), findsWidgets);
    expect(find.textContaining('怎么办：检查网络或到'), findsOneWidget);
    expect(find.text('重试'), findsWidgets);
    // 没有伪造结果：表格里一行都没有
    expect(find.text('番名'), findsNothing);
  });

  testWidgets('搜索页：空结果 → 空状态（给出下一步）', (WidgetTester tester) async {
    _sizeTo(tester, const Size(1400, 900));

    await tester.pumpWidget(
      harness(const SearchPage(), source: FakeSourcePort(const <SourceItemView>[]), settings: kSingleMode),
    );
    await tester.tap(find.widgetWithText(NeoButton, '搜索'));
    await tester.pumpAndSettle();

    expect(find.text('这个源现在没有内容'), findsOneWidget);
  });

  testWidgets('队列页：渲染任务行（状态/优先级/进度不可用提示）并可暂停', (WidgetTester tester) async {
    _sizeTo(tester, const Size(1400, 1400));

    final FakeQueuePort queue = FakeQueuePort(<QueueJobView>[
      _job('1', JobState.downloading, priority: 10, engineId: 3),
      _job('2', JobState.queued, priority: 100),
      _job('3', JobState.completed, priority: 10),
    ]);
    await tester.pumpWidget(harness(const QueuePage(), queue: queue));
    await tester.pumpAndSettle();

    expect(find.textContaining('葬送的芙莉莲 - 第 01 话'), findsNWidgets(3));
    expect(find.text('下载中'), findsWidgets);
    expect(find.text('排队中'), findsWidgets);
    expect(find.text('已完成'), findsWidgets);
    expect(find.text('预取'), findsOneWidget);
    expect(find.textContaining('priority 10'), findsWidgets);
    // 假引擎没返回任何 torrent → 必须明说进度不可用，而不是显示 0%
    expect(find.text('引擎未连接：进度不可用'), findsWidgets);
    // 第二十三轮：**排队中**的那条不许被写成「引擎里已经没有这个任务」——
    // 连点下载时用户看到的就是这句假报错（判据见 domain/queue_display.dart）。
    expect(find.text('排队等待中：还没轮到它'), findsOneWidget);
    expect(find.text('引擎里已经没有这个任务'), findsOneWidget); // 只剩那条已完成

    await tester.tap(find.text('暂停').first);
    await tester.pumpAndSettle();
    expect(queue.calls, contains('pause:1'));
  });

  testWidgets('队列页：失败的任务有「重试」这条出路（第四十二轮 UX #7）', (WidgetTester tester) async {
    // 旧实现只在 `paused` 时才渲染那颗按钮 ⇒ 失败行是个**死路**：既没有「继续」、
    // 也没有自动重试，唯一的出路是"移除 → 回搜索页重找"。core 的 `resumeJob`
    // 本来就把 `failed` 当合法输入（放回 queued / 重新加种），只是界面没给入口。
    _sizeTo(tester, const Size(1400, 1400));

    final FakeQueuePort queue = FakeQueuePort(<QueueJobView>[
      _job('9', JobState.paused, priority: 10),
      _job('10', JobState.failed, priority: 10),
    ]);
    await tester.pumpWidget(harness(const QueuePage(), queue: queue));
    await tester.pumpAndSettle();

    expect(find.text('继续'), findsOneWidget, reason: '暂停的那条照旧是「继续」');
    expect(find.text('重试'), findsOneWidget, reason: '失败的那条要有「重试」');

    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(queue.calls, contains('resume:10'));
  });

  testWidgets('队列页：「一起下载 N 条」写的是同一份设置，改完当场生效（第二十三轮）', (
    WidgetTester tester,
  ) async {
    _sizeTo(tester, const Size(1400, 1000));

    final _RecordingLifecycle lifecycle = _RecordingLifecycle();
    await tester.pumpWidget(
      harness(
        const QueuePage(),
        queue: FakeQueuePort(const <QueueJobView>[]),
        lifecycle: lifecycle,
      ),
    );
    await tester.pumpAndSettle();

    // 默认 1 条（`BandwidthPolicy.maxConcurrent` 的默认值 = 同时只下一条）。
    expect(find.text('一起下载 · 1 条'), findsOneWidget);

    // 下拉里选 3：触发器和菜单项文案相同，所以选菜单项要取 `.last`。
    await tester.tap(find.byType(NeoDropdown<int>));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('一起下载 3 条').last);
    await tester.pumpAndSettle();

    expect(find.text('一起下载 · 3 条'), findsOneWidget);
    // 写进的是**同一份设置**（设置页「并发下载数」读的就是它）……
    final ProviderContainer container =
        ProviderScope.containerOf(tester.element(find.byType(QueuePage)));
    expect(container.read(settingsProvider).bandwidth.maxConcurrent, 3);
    // ……并且走了一次「保存并生效」（并发数不是进程参数 → 不重启边车，
    // 但会到 `queue.setPolicy` → `pump()`，新上限当场生效）。
    expect(lifecycle.applied, 1);
    expect(lifecycle.payloads.single.bandwidth.maxConcurrent, 3);

    // 排掉 SnackBar 的自动关闭定时器。
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
  });

  testWidgets('队列页：暂停/引擎里已不存在的任务必须说人话（用户 2026-10-11）', (WidgetTester tester) async {
    _sizeTo(tester, const Size(1400, 1400));

    // 用户那条"删不掉"的遗留任务就是这个形态：paused + engineId 已被对齐清空。
    final FakeQueuePort queue = FakeQueuePort(<QueueJobView>[
      _job('1', JobState.paused),
    ]);
    await tester.pumpWidget(harness(const QueuePage(), queue: queue));
    await tester.pumpAndSettle();

    // ① 摘要里"暂停"必须**单开一档**：旧统计把 paused 算进 active，显示成「下载中 1」，
    //    一条没在下也没在排队的任务被说成在下载 —— 用户就是被这行字误导的。
    expect(find.text('下载中 0'), findsOneWidget);
    expect(find.text('已暂停 1'), findsOneWidget);
    // ② 引擎里没有它时别说"引擎连不上"：该做的是「继续」或「移除」。
    expect(find.text('引擎里已经没有这个任务'), findsOneWidget);
    expect(find.text('引擎未连接：进度不可用'), findsNothing);
    // ③ 进度条旁也别再写"等待引擎…"（已经暂停的任务永远等不到）。
    expect(find.text('等待引擎…'), findsNothing);
    expect(find.text('已暂停'), findsWidgets);
  });

  testWidgets('队列页：队列未接通 → 可行动错误（不伪造空队列）', (WidgetTester tester) async {
    _sizeTo(tester, const Size(1400, 900));

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          keyValueStoreProvider.overrideWithValue(InMemoryKeyValueStore()),
          queuePortProvider.overrideWithValue(const UnavailableQueuePort()),
        ],
        child: MaterialApp(
          theme: buildDsanimaTheme(),
          home: const Scaffold(body: QueuePage()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('QueueManager 尚未装配'), findsWidgets);
    expect(find.text('队列是空的'), findsNothing);
  });

  testWidgets('队列页：空队列 → 空状态（与「未接通」区分开）', (WidgetTester tester) async {
    _sizeTo(tester, const Size(1400, 900));

    await tester.pumpWidget(harness(const QueuePage()));
    await tester.pumpAndSettle();
    expect(find.text('队列是空的'), findsOneWidget);
  });

  // 用户 2026-10-10 第 2 轮问答：搜索页的源下拉从主窗口工具条搬进来了
  //（「工具条只留页名 + 窗口按钮，源下拉只在搜索页」）。
  testWidgets('搜索页：源下拉在搜索页里（不是主窗口工具条）', (WidgetTester tester) async {
    _sizeTo(tester, const Size(1500, 1000));

    final FakeSourcePort source = FakeSourcePort(<SourceItemView>[
      _item('hash1', '葬送的芙莉莲 - 第 01 话 [1080p]', seeders: 42),
    ]);
    await tester.pumpWidget(harness(const SearchPage(), source: source, settings: kSingleMode));
    await tester.pumpAndSettle();

    expect(find.byType(SearchSourcePicker), findsOneWidget);
  });

  // ── spec §7.3 Q16：新集命中 → 通知 → 点击起播（落在弹出播放窗口里） ──
  testWidgets('点系统通知（job:<id>）→ 投递那条任务到播放窗口（主窗口不切页、无播放面）', (WidgetTester tester) async {
    _sizeTo(tester, const Size(1600, 1000));

    final FakeNotifierPort notifier = FakeNotifierPort();
    // 这条任务**上次会话**就躺在队列里（`createdAt` 在启动之前）：
    // ① 不该再弹「订阅命中」（用户 2026-10-11 ⑥）；② 但点它的通知**仍然**要能起播。
    final QueueJobView job = QueueJobView(
      id: 'job-7',
      item: _item('hash7', '葬送的芙莉莲 - 第 07 话 [1080p]'),
      subscriptionId: 'sub-1',
      state: JobState.downloading,
      engineId: 3,
      fileIndex: 0,
      createdAt: DateTime(2026, 10, 8, 12),
      updatedAt: DateTime(2026, 10, 8, 12),
    );
    final PlayingQueuePort queue = PlayingQueuePort(job);
    final RecordingPlayerPort player = RecordingPlayerPort();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          keyValueStoreProvider.overrideWithValue(
            InMemoryKeyValueStore(<String, Object?>{
              SettingsController.storageKey: const AppSettings(firstRunCompleted: true).toJson(),
            }),
          ),
          sourcePortProvider.overrideWithValue(FakeSourcePort(const <SourceItemView>[])),
          queuePortProvider.overrideWithValue(queue),
          enginePortProvider.overrideWithValue(FakeEnginePort()),
          notificationPortProvider.overrideWithValue(notifier),
          playerPortProvider.overrideWithValue(player),
          subsPortProvider.overrideWithValue(const UnavailableSubsPort()),
          pickerPortProvider.overrideWithValue(const UnavailablePickerPort()),
        ],
        child: MaterialApp(
          theme: buildDsanimaTheme(),
          home: const Scaffold(body: DsShell()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    // 外壳挂载时队列里就有它 —— 但它是**上次会话**建的，所以一条通知都不该发。
    expect(notifier.sent, isEmpty, reason: '恢复出来的旧任务不该报"刚刚命中"（用户 2026-10-11 ⑥）');

    // 通知点击那条路本身照旧：payload 是 `job:<id>`，直接起播那一集。
    notifier.click('job:job-7');
    await tester.pumpAndSettle();

    expect(player.opened, hasLength(1), reason: '通知点击必须直接起播那一集');
    expect(player.opened.single.streamUrl.toString(), contains('/torrents/3/files/0/stream'));
    expect(player.opened.single.title, contains('葬送的芙莉莲'));
    // 用户 2026-10-10：只有弹出窗口播放 —— 主窗口既不切「正在播放」页（已删除），
    // 也不该出现任何播放面。
    final ProviderContainer container = ProviderScope.containerOf(
      tester.element(find.byType(DsShell)),
    );
    expect(container.read(navProvider), ShellTab.home, reason: '主窗口不该因为起播而跳页');
    expect(find.byType(shikiin.PlayerSurface), findsNothing, reason: '主窗口任何地方都不挂播放面（只有弹出窗口挂）');
  });

  testWidgets('上次会话留在队列里的订阅任务：重启后**不再**弹「订阅命中」（用户 2026-10-11 ⑥）', (WidgetTester tester) async {
    _sizeTo(tester, const Size(1600, 1000));
    final FakeNotifierPort notifier = FakeNotifierPort();
    // 真机上那条就是这样：上次会话建的、订阅来的、paused。
    final QueueJobView old = QueueJobView(
      id: 'job-old',
      item: _item('hashOld', '葬送的芙莉莲 - 第 07 话 [1080p]'),
      subscriptionId: 'sub-1',
      state: JobState.paused,
      createdAt: DateTime(2026, 10, 8, 17, 59),
      updatedAt: DateTime(2026, 10, 8, 18, 57),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          keyValueStoreProvider.overrideWithValue(
            InMemoryKeyValueStore(<String, Object?>{
              SettingsController.storageKey: const AppSettings(firstRunCompleted: true).toJson(),
            }),
          ),
          sourcePortProvider.overrideWithValue(FakeSourcePort(const <SourceItemView>[])),
          queuePortProvider.overrideWithValue(PlayingQueuePort(old)),
          enginePortProvider.overrideWithValue(FakeEnginePort()),
          notificationPortProvider.overrideWithValue(notifier),
          playerPortProvider.overrideWithValue(RecordingPlayerPort()),
          subsPortProvider.overrideWithValue(const UnavailableSubsPort()),
          pickerPortProvider.overrideWithValue(const UnavailablePickerPort()),
        ],
        child: MaterialApp(
          theme: buildDsanimaTheme(),
          home: const Scaffold(body: DsShell()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      notifier.sent,
      isEmpty,
      reason: '用户原话：「订阅是订阅下载是下载，每次启动队列有东西就会弹订阅已命中」',
    );
  });

  group('主窗口里**不存在**播放面（用户 2026-10-10 的硬要求）', () {    // 这一组守的是**否定式契约**：只有弹出窗口播放，主窗口任何地方都不播。
    // 历史教训（真机缺陷）：原来宿主播放页要"常驻挂载"播放面，于是主窗口里
    // 始终躺着一个 mpv 实例；用户明确否掉了这个形态，改成弹窗独占播放。
    //
    // 所以这里断言三件事：
    //   ① 主窗口整棵树里没有 `shikiin.PlayerSurface`；
    //   ② 侧栏再也没有「正在播放」这一项（8 项 → 7 项）；
    //   ③ 状态栏在**没有在播内容**时不显示任何播放相关 UI（不留白条、不占位）。
    testWidgets('主窗口外壳里没有 PlayerSurface，也没有「正在播放」导航项', (WidgetTester tester) async {
      _sizeTo(tester, const Size(1200, 800));

      await tester.pumpWidget(harness(const DsShell()));
      await tester.pumpAndSettle();

      expect(find.byType(shikiin.PlayerSurface), findsNothing, reason: '主窗口任何地方都不挂播放面 ⇒ 只有弹出窗口播');

      for (final ShellTab tab in ShellTab.values) {
        expect(tab.name, isNot('player'), reason: '「正在播放」已经从侧栏删掉（播放只发生在弹出窗口里）');
      }
      expect(find.text('正在播放'), findsNothing);

      // 没有在播内容 → 状态栏不出现播放指示（不显示空态、不占位）。
      final double statusBarHeight = tester.getSize(find.byType(DsShell).first).height;
      expect(statusBarHeight, greaterThan(0));

      // 第十七轮：播放入口从状态条搬到了**侧栏左下角**（设置齿轮正上方）。
      // 没有在播内容时那一行整块不渲染。
      expect(find.text('继续播放'), findsNothing);
      expect(find.byKey(dsResumePlayingKey), findsNothing);
    });
  });

  group('侧栏左下角「继续播放」（用户 2026-10-12 第十七轮）', () {
    // 用户原话：「继续播放位置太隐蔽，改到设置的上面也就是左下角」。
    // 原来它只是**底部状态条最左边**一颗 22px 的图标（挨着引擎点），现在必须是
    // 侧栏左下角、齿轮**正上方**的一整行（带文字）。
    NowPlaying playing() => const NowPlaying(
          title: '女友的朋友 - 02 [WebRip][1080P].mkv',
          engineId: 7,
          fileIndex: 0,
        );

    Widget harnessWith({
      required bool hasNowPlaying,
      bool windowOpen = false,
    }) {
      final PlayerWindowService service = PlayerWindowService.unconfigured();
      service.isOpen.value = windowOpen;
      return ProviderScope(
        overrides: [
          keyValueStoreProvider.overrideWithValue(
            InMemoryKeyValueStore(<String, Object?>{
              SettingsController.storageKey:
                  const AppSettings(firstRunCompleted: true).toJson(),
            }),
          ),
          sourcePortProvider.overrideWithValue(FakeSourcePort(const <SourceItemView>[])),
          queuePortProvider.overrideWithValue(FakeQueuePort(const <QueueJobView>[])),
          enginePortProvider.overrideWithValue(FakeEnginePort()),
          subsPortProvider.overrideWithValue(const UnavailableSubsPort()),
          playerPortProvider.overrideWithValue(const UnavailablePlayerPort()),
          lifecyclePortProvider.overrideWithValue(const UnavailableLifecyclePort()),
          pickerPortProvider.overrideWithValue(const UnavailablePickerPort()),
          playerWindowServiceProvider.overrideWithValue(service),
          playbackProvider.overrideWith(
            () => _FakePlayback(
              hasNowPlaying
                  ? PlaybackUiState(nowPlaying: playing(), playing: windowOpen)
                  : const PlaybackUiState(),
            ),
          ),
        ],
        child: MaterialApp(
          theme: buildDsanimaTheme(),
          home: const Scaffold(body: DsShell()),
        ),
      );
    }

    testWidgets('在播时：那一行在侧栏左下角、齿轮正上方（状态条里不再有它）', (WidgetTester tester) async {
      _sizeTo(tester, const Size(1400, 900));
      await tester.pumpWidget(harnessWith(hasNowPlaying: true, windowOpen: true));
      await tester.pumpAndSettle();

      final Finder row = find.byKey(dsResumePlayingKey);
      expect(row, findsOneWidget);

      // ① 在侧栏里（侧栏固定 184px）——而不是在底部状态条那条通栏里。
      final Rect rowRect = tester.getRect(row);
      expect(rowRect.left, lessThan(184));
      expect(rowRect.right, lessThanOrEqualTo(184));

      // ② 在设置齿轮**正上方**（用户原话：「改到设置的上面」）。
      final Rect gearRect = tester.getRect(find.byKey(dsSettingsGearKey));
      expect(rowRect.bottom, lessThanOrEqualTo(gearRect.top));

      // ③ 有文字，不是一个只有图标的按钮（用户抱怨的正是"太隐蔽"）。
      expect(find.text('正在播放'), findsOneWidget);
    });

    testWidgets('播放器收起/关掉之后：同一个按钮变成「继续播放」（点它唤回）', (WidgetTester tester) async {
      _sizeTo(tester, const Size(1400, 900));
      await tester.pumpWidget(harnessWith(hasNowPlaying: true));
      await tester.pumpAndSettle();

      expect(find.byKey(dsResumePlayingKey), findsOneWidget);
      expect(find.text('继续播放'), findsOneWidget);
      expect(find.text('正在播放'), findsNothing);
    });

    testWidgets('没有在播内容：整行不渲染（不留空位）', (WidgetTester tester) async {
      _sizeTo(tester, const Size(1400, 900));
      await tester.pumpWidget(harnessWith(hasNowPlaying: false));
      await tester.pumpAndSettle();

      expect(find.byKey(dsResumePlayingKey), findsNothing);
      expect(find.text('继续播放'), findsNothing);
    });
  });

  group('状态栏（底部）只剩「引擎连接」一个点 —— 用户 2026-10-10 第 1 轮问答', () {
    // 用户嫌底部一屏到处是数字，要求「只留引擎连接一个点 + tooltip，其余全删」。
    // 这条仍然守住同一类缺陷：状态栏**任何情况下**都不能把窗口顶出去。
    const String longDir =
        r'F:\Anime\2026\秋番\葬送的芙莉莲 第二季\[SubsPlease] Frieren S2 (1080p) [Batch]\downloads\completed';

    Future<void> pumpAt(WidgetTester tester, double width) async {
      _sizeTo(tester, Size(width, 900));
      await tester.pumpWidget(
        harness(
          const DsShell(),
          settings: const AppSettings(firstRunCompleted: true, downloadDir: longDir),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('窄窗口（900px）下状态栏无布局异常', (WidgetTester tester) async {
      await pumpAt(tester, 900);

      expect(tester.takeException(), isNull, reason: '状态栏溢出会走 FlutterError.reportError，测试里表现为异常');
    });

    testWidgets('原来的数字格（下载目录 / 速率 / 对等 / 剩余 / 缓存）都不再常驻', (WidgetTester tester) async {
      await pumpAt(tester, 900);

      expect(find.byKey(const Key('dsStatusBarDir')), findsNothing, reason: '下载目录不再占状态栏（要看时去设置页）');
      expect(find.textContaining('秋番'), findsNothing);
      expect(find.textContaining('缓存 '), findsNothing);
      expect(find.textContaining('对等 '), findsNothing);
      expect(find.textContaining('剩余 '), findsNothing);
      // 引擎点还在（通/不通的唯一常驻信息）：状态栏那一行里应该只有一个可点的点。
      expect(_engineDot(), findsOneWidget, reason: '引擎点的 tooltip 是这一条状态栏唯一常驻信息');
    });

    testWidgets('全窗口只有一颗引擎点，且它在**侧栏最下面（设置下面）**（第二十九轮删状态栏 / 第三十一轮下移）',
        (WidgetTester tester) async {
      await pumpAt(tester, 1400);

      // 决策 F3/F16/F20：底部状态条整条删除，引擎状态变成侧栏里的一个 6px 点。
      expect(_engineDot(), findsOneWidget, reason: '全窗口就一颗引擎点');
      expect(find.text('引擎已连接'), findsNothing, reason: '文字只在 tooltip 里，不常驻');

      final Rect dot = tester.getRect(_engineDot());
      expect(dot.left, lessThan(184), reason: '在侧栏里（侧栏固定 184px）');
      // ⚠️ 旧的「不贴窗口底」反向断言在第三十一轮**作废**：底部那条状态栏确实已经删了
      // （上面几条断言守着），而用户现在明确要求这颗点挪到「设置下面」，也就是侧栏最下面。
      expect(dot.bottom, lessThanOrEqualTo(900), reason: '仍然在窗口里（900 高的窗口）');
      // ⚠️ **第三十一轮**（用户 2026-10-15：「侧边栏的小绿点放到设置下面」）：
      // 顺序改成 导航项 → 继续播放 → 设置 → 引擎点。原来是"引擎点在设置齿轮上方"。
      final Rect gear = tester.getRect(find.byKey(dsSettingsGearKey));
      expect(dot.top, greaterThanOrEqualTo(gear.bottom),
          reason: '引擎点必须在设置齿轮**下面**（用户要求下移）');
    });
  });

  group('首启向导：每一步都要给出可行动的提示', () {
    testWidgets('把预填的目录清空（= 明确不要默认）→ 第 ① 步就拦住并说明怎么办', (WidgetTester tester) async {
      _sizeTo(tester, const Size(1600, 1000));
      await tester.pumpWidget(
        harness(const FirstRunPage(), settings: const AppSettings(firstRunCompleted: false)),
      );
      await tester.pumpAndSettle();

      // 用户 2026-10-11：「下载目录默认在 C:\Users\用户名\Downloads\Anime」——
      // 向导现在进第 ① 步就把默认值**预填**好，所以"没选目录"这条拦截要先把预填值
      // 清掉才走得到（清空 = 用户明确不要默认值）。
      await tester.enterText(find.byType(TextFormField).first, '');
      await tester.pumpAndSettle();

      await tester.tap(find.text('下一步'));
      await tester.pumpAndSettle();

      expect(find.text('还没有选下载目录'), findsOneWidget);
      expect(find.text('① 下载目录'), findsOneWidget, reason: '校验失败要留在原步');
    });

    testWidgets('没勾合规声明就点「完成」→ 跳到第 ③ 步并显示错误', (WidgetTester tester) async {
      _sizeTo(tester, const Size(1600, 1000));
      await tester.pumpWidget(
        harness(
          const FirstRunPage(),
          settings: const AppSettings(firstRunCompleted: false, downloadDir: r'F:\Anime'),
        ),
      );
      await tester.pumpAndSettle();

      // ① → ② → ③
      await tester.tap(find.text('下一步'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('下一步'));
      await tester.pumpAndSettle();
      expect(find.text('合规声明（必须确认）'), findsOneWidget);

      // 旧实现：这一步点「完成」什么都不显示（错误面板只在 ①/② 渲染）。
      await tester.tap(find.text('完成'));
      await tester.pumpAndSettle();

      expect(find.text('请先阅读并勾选合规声明'), findsOneWidget);
      expect(find.text('合规声明（必须确认）'), findsOneWidget, reason: '错误必须出现在合规声明所在的这一步');
    });
  });

  group('浅/深切换的过渡', () {
    testWidgets('不再做颜色插值：立刻换成新配色 + 圆形揭开那层在（第三十三轮）', (WidgetTester tester) async {
      _sizeTo(tester, const Size(1600, 1000));
      await tester.pumpWidget(
        ProviderScope(
          // 不写显式类型：`Override` 在 Riverpod 3 里不在主 barrel 上。
          overrides: [
            keyValueStoreProvider.overrideWithValue(
              InMemoryKeyValueStore(<String, Object?>{
                SettingsController.storageKey: const AppSettings(firstRunCompleted: true).toJson(),
              }),
            ),
            sourcePortProvider.overrideWithValue(FakeSourcePort(const <SourceItemView>[])),
            queuePortProvider.overrideWithValue(FakeQueuePort(const <QueueJobView>[])),
            enginePortProvider.overrideWithValue(FakeEnginePort()),
            subsPortProvider.overrideWithValue(const UnavailableSubsPort()),
            playerPortProvider.overrideWithValue(const UnavailablePlayerPort()),
            lifecyclePortProvider.overrideWithValue(const UnavailableLifecyclePort()),
            pickerPortProvider.overrideWithValue(const UnavailablePickerPort()),
          ],
          child: const DsanimaApp(),
        ),
      );
      await tester.pumpAndSettle();

      // 外壳树里的 `Theme.of` 走的是 MaterialApp 的**动画**主题（`AnimatedTheme`），
      // 所以这里读到的就是"当前这一帧实际渲染用的" token。
      DsTokens shown() => Theme.of(tester.element(find.byType(DsShell))).extension<DsTokens>()!;

      expect(shown().isDark, isFalse);
      final ProviderContainer container = ProviderScope.containerOf(
        tester.element(find.byType(DsanimaApp)),
      );
      await container
          .read(settingsProvider.notifier)
          .replace(const AppSettings(firstRunCompleted: true, themeId: 'dark'));
      // ⚠️ 第三十三轮：**不做颜色插值**（`kDsThemeAnimationDuration` = 0）。
      // 用户报的「处于白色系时点击黑白，黑白字消失，可能是颜色混一起了」真身就是插值：
      // 白底黑字 ⇄ 黑底白字，`Color.lerp(白, 黑, 0.5)` 两边都是中灰 ⇒ 文字与背景同色。
      // 现在换外观**一步到位**，"旧界面"改成由圆形揭开的那层快照来演。
      expect(kDsThemeAnimationDuration, Duration.zero,
          reason: '插值一开，中灰那一段就会回来');
      await tester.pump(); // 让 theme 变化生效
      await tester.pump(const Duration(milliseconds: 90)); // 以前这里是"插值走到一半"

      final DsTokens mid = shown();
      expect(mid.isDark, isTrue, reason: '第 90ms 就该是**已经换好**的新配色，不是中间色');
      expect(mid.base, DsTokens.blackMono.base);
      expect(mid.text, DsTokens.blackMono.text,
          reason: '中灰那一段没了 ⇒ "黑白字消失"这条路径被结构性删掉');

      // 揭开那一层挂在 MaterialApp 的 builder 上（整窗，含弹出的页面/对话框）。
      expect(find.byType(DsThemeRevealHost), findsOneWidget);

      await tester.pumpAndSettle();
      expect(shown().isDark, isTrue);
      expect(shown().base, DsTokens.blackMono.base);
    });
  });

  group('状态栏引擎点的小面板（用户 2026-10-11 第二阶段清单第 8 项）', () {
    testWidgets('点引擎点 → 弹出「连通 / 端口 / 重启边车」，不再是直接跳设置页', (WidgetTester tester) async {
      _sizeTo(tester, const Size(1600, 1000));
      final _RecordingLifecycle lifecycle = _RecordingLifecycle();
      await tester.pumpWidget(harness(const DsShell(), lifecycle: lifecycle));
      await tester.pumpAndSettle();

      // 状态栏那颗点是唯一挂着状态 tooltip 的地方（文本随连接状态变）。
      await tester.tap(_engineDot());
      await tester.pumpAndSettle();

      expect(find.text('端口'), findsOneWidget, reason: '面板要能看端口');
      expect(find.text('重启边车'), findsOneWidget);
      expect(find.text('设置页'), findsOneWidget);
      expect(find.text('重新测连通'), findsOneWidget);

      // 引擎没起来时端口显示占位，而不是空白或假端口。
      expect(find.text('—'), findsWidgets);

      // 面板里的「重启边车」走的是真实链路（applySettings），并给出反馈。
      await tester.tap(find.text('重启边车'));
      await tester.pumpAndSettle();
      expect(lifecycle.applied, 1, reason: '重启必须走设置页那条真实链路');
      expect(find.text('边车已重启'), findsOneWidget);
    });

    testWidgets('面板里的「设置页」会把导航切到设置', (WidgetTester tester) async {
      _sizeTo(tester, const Size(1600, 1000));
      await tester.pumpWidget(harness(const DsShell()));
      await tester.pumpAndSettle();

      await tester.tap(_engineDot());
      await tester.pumpAndSettle();
      await tester.tap(find.text('设置页'));
      await tester.pumpAndSettle();

      final ProviderContainer container = ProviderScope.containerOf(
        tester.element(find.byType(DsShell)),
      );
      expect(container.read(navProvider), ShellTab.settings);
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // 第十六轮：设置页改成**手动保存** → 带着未保存的改动切页要被拦一下
  // ───────────────────────────────────────────────────────────────────────────
  group('设置页手动保存：未保存就切页会被拦（第十六轮）', () {
    /// 打开设置页并把「开启做种」打开（草稿变脏）。视口给高，免得为了点开关先滚半天。
    Future<void> openSettingsAndToggle(WidgetTester tester) async {
      await tester.tap(find.byKey(dsSettingsGearKey));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(SwitchListTile, '开启做种'));
      await tester.pumpAndSettle();
      expect(find.byKey(dsSettingsSaveBarTextKey), findsOneWidget);
      expect(
        tester.widget<Text>(find.byKey(dsSettingsSaveBarTextKey)).data,
        contains('有未保存的改动'),
      );
    }

    testWidgets('点别的页 → 弹三选；「留在这」就留在设置页、草稿还在、也没落盘', (WidgetTester tester) async {
      _sizeTo(tester, const Size(1600, 3000));
      final _RecordingLifecycle lifecycle = _RecordingLifecycle();
      await tester.pumpWidget(harness(const DsShell(), lifecycle: lifecycle));
      await tester.pumpAndSettle();
      await openSettingsAndToggle(tester);

      await tester.tap(find.text('主页'));
      await tester.pumpAndSettle();

      expect(find.text('设置有未保存的改动'), findsOneWidget, reason: '切页要被拦一下');
      expect(find.text('留在这'), findsOneWidget);
      expect(find.text('放弃改动'), findsOneWidget);
      expect(find.text('保存并生效'), findsWidgets, reason: '对话框里那颗（底部保存条里那颗被它挡着）');

      await tester.tap(find.text('留在这'));
      await tester.pumpAndSettle();

      final ProviderContainer container = ProviderScope.containerOf(
        tester.element(find.byType(DsShell)),
      );
      expect(container.read(navProvider), ShellTab.settings, reason: '「留在这」= 不切页');
      expect(
        tester.widget<SwitchListTile>(find.widgetWithText(SwitchListTile, '开启做种')).value,
        isTrue,
        reason: '草稿要留着',
      );
      expect(container.read(settingsProvider).seedEnabled, isFalse, reason: '没保存就不许落盘');
      expect(lifecycle.applied, 0, reason: '没保存就不许生效');
    });

    testWidgets('「放弃改动」→ 切页成功、改动丢掉、不落盘不生效', (WidgetTester tester) async {
      _sizeTo(tester, const Size(1600, 3000));
      final _RecordingLifecycle lifecycle = _RecordingLifecycle();
      await tester.pumpWidget(harness(const DsShell(), lifecycle: lifecycle));
      await tester.pumpAndSettle();
      await openSettingsAndToggle(tester);

      await tester.tap(find.text('主页'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('放弃改动'));
      await tester.pumpAndSettle();

      final ProviderContainer container = ProviderScope.containerOf(
        tester.element(find.byType(DsShell)),
      );
      expect(container.read(navProvider), ShellTab.home, reason: '放弃之后就放行');
      expect(container.read(settingsProvider).seedEnabled, isFalse);
      expect(lifecycle.applied, 0);
    });

    testWidgets('「保存并生效」→ 切页成功、真的落盘 + 生效一次', (WidgetTester tester) async {
      _sizeTo(tester, const Size(1600, 3000));
      final _RecordingLifecycle lifecycle = _RecordingLifecycle();
      await tester.pumpWidget(harness(const DsShell(), lifecycle: lifecycle));
      await tester.pumpAndSettle();
      await openSettingsAndToggle(tester);

      await tester.tap(find.text('主页'));
      await tester.pumpAndSettle();
      // 对话框里的那颗（底部保存条被遮挡，但文字一样；用 AlertDialog 里的那个找）。
      await tester.tap(
        find.descendant(of: find.byType(AlertDialog), matching: find.text('保存并生效')),
      );
      await tester.pumpAndSettle();

      final ProviderContainer container = ProviderScope.containerOf(
        tester.element(find.byType(DsShell)),
      );
      expect(container.read(navProvider), ShellTab.home);
      expect(container.read(settingsProvider).seedEnabled, isTrue, reason: '选了保存就要落盘');
      expect(lifecycle.applied, 1, reason: '而且生效恰好一次');
    });
  });
}

/// 只记「生效被调用了几次」的生命周期端口替身（小面板的「重启边车」用它）。
class _RecordingLifecycle implements LifecyclePort {
  int applied = 0;

  /// 每次调用带的那份设置（第二十三轮：队列页「一起下载 N 条」改的就是它）。
  final List<AppSettings> payloads = <AppSettings>[];

  @override
  Future<void> applySettings(AppSettings settings) async {
    applied++;
    payloads.add(settings);
  }
}
