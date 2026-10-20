/// 「已完成」页（组件级）：按番名分卡、封面走 bangumi、播放/打开文件夹/移除/删文件。
///
/// 为什么要有这一层：纯函数（`completed_test.dart`）只能证明"归组和删除流程是对的"，
/// 证明不了**页面有没有把它们接上** —— 比如「删文件」是不是真的走了
/// `deleteFiles: false` + 回收站（而不是引擎那条永久删除）、点封面能不能换。
///
/// 全程离线：引擎/队列/资源管理器/回收站/bangumi 全部是替身；**回收站替身只记录
/// 路径**，绝不真的动用户机器的回收站（真调用由 `recycle_bin_live_probe.dart` 在
/// 临时文件上单独跑）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:dsanima/domain/bangumi.dart';
import 'package:dsanima/domain/completed.dart';
import 'package:dsanima/domain/models.dart';
import 'package:dsanima/domain/ports.dart';
import 'package:dsanima/state/bangumi_meta.dart';
import 'package:dsanima/state/providers.dart';
import 'package:dsanima/theme/app_theme.dart';
import 'package:dsanima/ui/completed_page.dart';
import 'package:dsanima/ui/widgets/neo.dart';
import 'package:dsanima_core/sources/kv.dart' show InMemoryKeyValueStore;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

// ─────────────────────────────────────────────────────────────────────────────
// 替身
// ─────────────────────────────────────────────────────────────────────────────

/// 假引擎：`watch()` 一次性给出这批已下完的 torrent。
class _FakeEngine implements EnginePort {
  _FakeEngine(this.torrents);

  final List<EngineTorrentView> torrents;

  @override
  Future<EngineHealthView> health() async => const EngineHealthView(ok: true, version: '0.1.0');

  @override
  Future<List<EngineTorrentView>> list() async => torrents;

  @override
  Stream<List<EngineTorrentView>> watch() => Stream<List<EngineTorrentView>>.value(torrents);

  @override
  Uri? streamUrl(int id, int fileIndex) =>
      Uri.parse('http://127.0.0.1:1/torrents/$id/files/$fileIndex/stream?token=t');

  @override
  Future<EngineTorrentView> addMagnet(String magnet,
          {String? name, List<int>? onlyFiles, bool startPaused = false, String? subFolder}) async =>
      throw const PortUnavailableException('测试替身：不加种');

  @override
  Future<void> pause(int id) async {}

  @override
  Future<void> resume(int id) async {}

  @override
  Future<void> remove(int id, {bool deleteFiles = false}) async {}
}

/// 假队列：记下每一次移除（尤其是 `deleteFiles` 这一位）。
class _FakeQueue implements QueuePort {
  final List<String> calls = <String>[];

  @override
  Future<String?> removeByEngine(int engineId, {bool deleteFiles = true}) async {
    calls.add('removeByEngine:$engineId:deleteFiles=$deleteFiles');
    return null;
  }

  @override
  Stream<List<QueueJobView>> watchJobs() => const Stream<List<QueueJobView>>.empty();

  @override
  Future<QueueJobView> enqueuePlayNow(SourceItemView item,
          {List<SourceItemView> upNext = const <SourceItemView>[],
          List<SourceItemView> preheat = const <SourceItemView>[]}) async =>
      throw const PortUnavailableException('测试替身');

  @override
  Future<QueueJobView> enqueueDownload(SourceItemView item, {List<int>? onlyFiles}) async =>
      throw const PortUnavailableException('测试替身');

  @override
  Future<void> attachToSubsRule(SourceItemView item) async {}

  @override
  Future<void> pauseJob(String jobId) async {}

  @override
  Future<void> resumeJob(String jobId) async {}

  @override
  Future<String?> removeJob(String jobId, {bool deleteFiles = false}) async => null;

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

/// 假封面缓存：**永远不给文件**（测试绝不联网下图），于是走占位/真图两条路里的占位。
class _NullCoverCache implements CoverCachePort {
  final List<String> asked = <String>[];

  @override
  Future<File?> fileFor(String url, {String? referer}) async {
    asked.add(url);
    return null;
  }

  /// 内存索引里也没有（第三十七轮加的同步那条路）：与 [fileFor] 一致，永远"本地没有"。
  @override
  File? cachedNow(String url) => null;
}

/// 假资源管理器：只记路径。
class _RecordingReveal {
  final List<String> paths = <String>[];

  Future<void> call(String path) async => paths.add(path);
}

/// 假回收站：只记路径，**绝不真删**。
class _RecordingRecycle {
  final List<List<String>> batches = <List<String>>[];

  Future<int> call(List<String> paths) async {
    batches.add(paths);
    return paths.length;
  }

  List<String> get all => <String>[for (final List<String> b in batches) ...b];
}

/// 假 bangumi：`/search/subject/<q>` 返回给定的候选。
BangumiMetaService _fakeBangumi(List<Map<String, Object?>> results) {
  final http.Client client = MockClient((http.Request request) async {
    if (request.url.path.contains('/search/subject/')) {
      return http.Response(
        jsonEncode(<String, Object?>{'results': results}),
        200,
        headers: <String, String>{'content-type': 'application/json; charset=utf-8'},
      );
    }
    return http.Response('{}', 404);
  });
  return BangumiMetaService(
    store: InMemoryKeyValueStore(),
    client: BangumiClient(client: client, minInterval: Duration.zero),
  );
}

Map<String, Object?> _subject(int id, String nameCn) => <String, Object?>{
      'id': id,
      'name': 'Name $id',
      'name_cn': nameCn,
      'date': '2026-10-01',
      'eps': 12,
      'images': <String, String>{'grid': 'https://lain.bgm.tv/grid/$id.jpg'},
    };

// ─────────────────────────────────────────────────────────────────────────────
// 夹具
// ─────────────────────────────────────────────────────────────────────────────

String _vcb(int ep) =>
    '[hyakuhuyu&VCB-Studio] Re Zero kara Hajimeru Isekai Seikatsu 3rd Season '
    '[$ep][Ma10p_1080p][x265_flac_aac].CHS.mp4';

EngineTorrentView _torrent({
  required int id,
  required String name,
  required String fileName,
  required String folder,
  int bytes = 1000,
}) =>
    EngineTorrentView(
      id: id,
      name: name,
      finished: true,
      progress: 1,
      totalBytes: bytes,
      outputFolder: folder,
      files: <EngineFileView>[
        EngineFileView(index: 0, path: fileName, length: bytes, isVideo: true, complete: true),
      ],
    );

/// 切到「列表」摆法（第二十四轮之前的形态）。
///
/// 默认是封面卡网格，所以凡是要验「展开 N 集 / 卡片级按钮」的用例都得先切过来。
Future<void> _useListView(WidgetTester tester) async {
  await tester.tap(find.text(CompletedView.list.label));
  await tester.pumpAndSettle();
}

/// 在某个控件上点**右键**（第二十五轮：卡片右键菜单）。
Future<void> _rightClick(WidgetTester tester, Finder finder) async {
  final Offset at = tester.getCenter(finder);
  final TestGesture gesture = await tester.createGesture(
    kind: PointerDeviceKind.mouse,
    buttons: kSecondaryButton,
  );
  await gesture.addPointer(location: Offset.zero);
  addTearDown(gesture.removePointer);
  await tester.pump();
  await gesture.moveTo(at);
  await tester.pump();
  await gesture.down(at);
  await gesture.up();
  await tester.pumpAndSettle();
}

void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('dsanima_completed_page_');
  });
  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  /// 造一屏：3 集 Re Zero（同一张卡）+ 1 部别的番。
  Widget harness({
    required List<EngineTorrentView> torrents,
    _FakeQueue? queue,
    _RecordingReveal? reveal,
    _RecordingRecycle? recycle,
    _NullCoverCache? covers,
    List<Map<String, Object?>> bangumi = const <Map<String, Object?>>[],
  }) {
    return ProviderScope(
      overrides: [
        keyValueStoreProvider.overrideWithValue(
          InMemoryKeyValueStore(<String, Object?>{
            SettingsController.storageKey: AppSettings(
              firstRunCompleted: true,
              downloadDir: dir.path,
            ).toJson(),
          }),
        ),
        enginePortProvider.overrideWithValue(_FakeEngine(torrents)),
        queuePortProvider.overrideWithValue(queue ?? _FakeQueue()),
        coverCacheProvider.overrideWithValue(covers ?? _NullCoverCache()),
        bangumiMetaProvider.overrideWithValue(_fakeBangumi(bangumi)),
        revealInExplorerProvider.overrideWithValue((reveal ?? _RecordingReveal()).call),
        recycleBinProvider.overrideWithValue((recycle ?? _RecordingRecycle()).call),
      ],
      child: MaterialApp(
        theme: buildDsanimaTheme(),
        home: const Scaffold(body: CompletedPage()),
      ),
    );
  }

  testWidgets('默认 = 封面卡网格：一部番一张卡；点卡片打开 → 一集一行（像文件夹）；返回回到网格', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1500, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(harness(torrents: <EngineTorrentView>[
      _torrent(id: 1, name: _vcb(51), fileName: 'a.mp4', folder: dir.path),
      _torrent(id: 2, name: _vcb(52), fileName: 'b.mp4', folder: dir.path),
      _torrent(id: 3, name: _vcb(53), fileName: 'c.mp4', folder: dir.path),
    ]));
    await tester.pumpAndSettle();

    // 一部番一张卡：番名正好是用户要的那句（方括号里的组名/集号/画质全没了）。
    expect(find.text('Re Zero kara Hajimeru Isekai Seikatsu 3rd Season'), findsOneWidget);
    expect(find.textContaining('已完成 1 部'), findsOneWidget);
    // 网格卡上是「N 集 · 体积」，不是列表摆法那句「3 集（51–53）」。
    expect(find.textContaining('3 集 · '), findsOneWidget);
    // 没点开之前看不到每一集的原始名字（带 `[51]` 的完整文件名）。
    expect(find.textContaining('[51]'), findsNothing);
    // 摆法开关：默认停在「封面卡」。
    expect(find.text(CompletedView.grid.label), findsOneWidget);
    expect(find.text(CompletedView.list.label), findsOneWidget);

    // 点卡片 = 打开这一部番（跟文件夹一样：一集一行）。
    await tester.tap(find.text('Re Zero kara Hajimeru Isekai Seikatsu 3rd Season'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(NeoButton, '返回'), findsOneWidget);
    expect(find.textContaining('[51]'), findsOneWidget);
    expect(find.textContaining('[52]'), findsOneWidget);
    expect(find.textContaining('[53]'), findsOneWidget);
    expect(find.text('51'), findsOneWidget);
    expect(find.text('53'), findsOneWidget);
    // 文件夹面板标题：路径 + 集数。
    expect(find.textContaining(dir.path), findsWidgets);
    expect(find.text('3 集'), findsOneWidget);
    // 每一集的四个动作都在（加上顶部那颗「播放首集」）。
    expect(find.widgetWithText(NeoButton, '播放'), findsNWidgets(3));
    expect(find.widgetWithText(NeoButton, '移除'), findsNWidgets(3));
    expect(find.widgetWithText(NeoButton, '删文件'), findsNWidgets(3));

    // 返回 → 回到封面卡那一屏。
    await tester.tap(find.widgetWithText(NeoButton, '返回'));
    await tester.pumpAndSettle();
    expect(find.textContaining('[51]'), findsNothing);
    expect(find.widgetWithText(NeoButton, '返回'), findsNothing);
  });

  testWidgets('摆法开关：切到「列表」= 以前那种一行一张宽卡 + 「展开 N 集」', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1500, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(harness(torrents: <EngineTorrentView>[
      _torrent(id: 1, name: _vcb(51), fileName: 'a.mp4', folder: dir.path),
      _torrent(id: 2, name: _vcb(52), fileName: 'b.mp4', folder: dir.path),
      _torrent(id: 3, name: _vcb(53), fileName: 'c.mp4', folder: dir.path),
    ]));
    await tester.pumpAndSettle();

    await _useListView(tester);
    expect(find.textContaining('3 集（51–53）'), findsOneWidget);
    expect(find.widgetWithText(NeoButton, '展开 3 集'), findsOneWidget);
    expect(find.textContaining('3 集 · '), findsNothing, reason: '列表摆法没有网格卡上那句');

    // 在列表里展开仍然是一集一行 + 四个动作。
    await tester.tap(find.widgetWithText(NeoButton, '展开 3 集'));
    await tester.pumpAndSettle();
    expect(find.textContaining('[51]'), findsOneWidget);
    expect(find.widgetWithText(NeoButton, '删文件'), findsNWidgets(3));
  });

  testWidgets('封面：默认第一个结果；点封面 = 打开这一部番；右键才能换封面（选第二条 → 手选标记）',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1500, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final ProviderContainer container = ProviderContainer(
      overrides: [
        keyValueStoreProvider.overrideWithValue(
          InMemoryKeyValueStore(<String, Object?>{
            SettingsController.storageKey:
                const AppSettings(firstRunCompleted: true, downloadDir: 'F:\\Anime').toJson(),
          }),
        ),
        enginePortProvider.overrideWithValue(_FakeEngine(<EngineTorrentView>[
          _torrent(id: 1, name: _vcb(51), fileName: 'a.mp4', folder: r'F:\Anime'),
        ])),
        queuePortProvider.overrideWithValue(_FakeQueue()),
        coverCacheProvider.overrideWithValue(_NullCoverCache()),
        bangumiMetaProvider.overrideWithValue(_fakeBangumi(<Map<String, Object?>>[
          _subject(1, 'Re:从零开始的异世界生活 第三季'),
          _subject(2, '别的东西'),
        ])),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildDsanimaTheme(),
          home: const Scaffold(body: CompletedPage()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 默认 = 第一个结果。
    final String key = container.read(completedGroupsProvider).single.key;
    expect(container.read(completedCoverProvider).subjectOf(key)?.id, 1);

    // ① 「鼠标放上去不要显示文字」：封面外面**不再**套 Tooltip（第二十五轮）。
    expect(
      find.ancestor(of: find.byKey(dsCompletedCoverKey), matching: find.byType(Tooltip)),
      findsNothing,
      reason: '封面上悬停不该冒字（用户第二十五轮）',
    );

    // ② 「点封面不要是换封面」：点封面 = 卡片自己的 onTap = 打开这一部番。
    await tester.tap(find.byKey(dsCompletedCoverKey));
    await tester.pumpAndSettle();
    expect(find.textContaining('换封面'), findsNothing, reason: '点封面不再弹换封面对话框');
    expect(find.widgetWithText(NeoButton, '返回'), findsOneWidget, reason: '点封面 = 打开这一部番');
    await tester.tap(find.widgetWithText(NeoButton, '返回'));
    await tester.pumpAndSettle();

    // ③ 右键卡片 → 换封面（三项菜单：换封面 / 从列表移除 / 删除文件）。
    await _rightClick(tester, find.byKey(dsCompletedCoverKey));
    expect(find.text('更换封面'), findsOneWidget);
    expect(find.text('从列表移除（文件留着）'), findsOneWidget);
    expect(find.text('删除文件（移进回收站）'), findsOneWidget);

    await tester.tap(find.text('更换封面'));
    await tester.pumpAndSettle();
    expect(find.textContaining('换封面'), findsOneWidget, reason: '对话框标题「换封面：…」');
    expect(find.text('Re:从零开始的异世界生活 第三季'), findsWidgets);
    expect(find.text('别的东西'), findsWidgets);

    await tester.tap(find.text('别的东西').last);
    await tester.pumpAndSettle();
    expect(container.read(completedCoverProvider).subjectOf(key)?.id, 2,
        reason: '手选之后用用户点的那条');
    expect(container.read(completedCoverProvider).isPicked(key), isTrue);
    expect(find.text('已选'), findsOneWidget);
  });

  testWidgets('右键菜单：「从列表移除」走 deleteFiles=false（文件留着，绝不碰回收站）', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1500, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final _FakeQueue queue = _FakeQueue();
    final _RecordingRecycle recycle = _RecordingRecycle();
    await tester.pumpWidget(harness(
      torrents: <EngineTorrentView>[
        _torrent(id: 5, name: _vcb(51), fileName: 'a.mp4', folder: dir.path),
      ],
      queue: queue,
      recycle: recycle,
    ));
    await tester.pumpAndSettle();

    await _rightClick(tester, find.byKey(dsCompletedCoverKey));
    await tester.tap(find.text('从列表移除（文件留着）'));
    await tester.pumpAndSettle();
    expect(find.text('从列表移除这个任务？'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, '移除任务'));
    await tester.pumpAndSettle();

    expect(queue.calls, <String>['removeByEngine:5:deleteFiles=false']);
    expect(recycle.batches, isEmpty, reason: '「移除」不删文件');
  });

  testWidgets('右键菜单：「删除文件」走回收站（确认后 移除任务 + 回收站，路径绝对）', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1500, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    File('${dir.path}\\ep01.mp4').writeAsStringSync('x');
    final _FakeQueue queue = _FakeQueue();
    final _RecordingRecycle recycle = _RecordingRecycle();
    await tester.pumpWidget(harness(
      torrents: <EngineTorrentView>[
        _torrent(id: 9, name: _vcb(51), fileName: 'ep01.mp4', folder: dir.path),
      ],
      queue: queue,
      recycle: recycle,
    ));
    await tester.pumpAndSettle();

    await _rightClick(tester, find.byKey(dsCompletedCoverKey));
    await tester.tap(find.text('删除文件（移进回收站）'));
    await tester.pumpAndSettle();
    expect(find.text('删除文件到回收站？'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, '删到回收站'));
    await tester.pumpAndSettle();

    expect(queue.calls, <String>['removeByEngine:9:deleteFiles=false'],
        reason: '引擎那条删除绝不能带 deleteFiles=true（那是永久删除）');
    expect(recycle.all, <String>['${dir.path}\\ep01.mp4']);
  });

  testWidgets('页头那行说明文字整行删掉（用户第二十五轮：「去除文字一部一番一张卡这一行」）',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1500, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(harness(torrents: <EngineTorrentView>[
      _torrent(id: 1, name: _vcb(51), fileName: 'a.mp4', folder: dir.path),
    ]));
    await tester.pumpAndSettle();

    for (final String gone in <String>['一部番一张卡', '按番名分类', '点封面可以自己挑']) {
      expect(find.textContaining(gone), findsNothing, reason: '「$gone」这一行已经删掉');
    }
    // 摆法开关还在（两种摆法都能切）。
    expect(find.text(CompletedView.grid.label), findsOneWidget);
    expect(find.text(CompletedView.list.label), findsOneWidget);
  });

  testWidgets('展开：每一集给「播放 / 打开文件夹 / 移除 / 删文件」，集号在行首', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(2000, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(harness(torrents: <EngineTorrentView>[
      _torrent(id: 1, name: _vcb(51), fileName: 'a.mp4', folder: dir.path),
      _torrent(id: 2, name: _vcb(52), fileName: 'b.mp4', folder: dir.path),
    ]));
    await tester.pumpAndSettle();

    await _useListView(tester);
    await tester.tap(find.widgetWithText(NeoButton, '展开 2 集'));
    await tester.pumpAndSettle();

    // 每一集那一行显示的是它的**原始名字**（VCB 那种一等集一个种子 = 文件名），
    // 于是「只搜名字」清洗过的那句只出现在卡片标题上（findsOneWidget 那一条断言的正是它）。
    expect(find.textContaining('[51]'), findsOneWidget);
    expect(find.textContaining('[52]'), findsOneWidget);
    expect(find.text('51'), findsOneWidget);
    expect(find.text('52'), findsOneWidget);
    // 每一集的四个动作（卡片级还有一个「播放首集 / 打开文件夹」）。
    expect(find.widgetWithText(NeoButton, '播放'), findsNWidgets(2));
    expect(find.widgetWithText(NeoButton, '打开文件夹'), findsNWidgets(3));
    expect(find.widgetWithText(NeoButton, '移除'), findsNWidgets(2));
    expect(find.widgetWithText(NeoButton, '删文件'), findsNWidgets(2));
  });

  testWidgets('打开文件夹：用**绝对路径**（引擎给的 path 是相对的）', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1500, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final _RecordingReveal reveal = _RecordingReveal();
    await tester.pumpWidget(harness(
      torrents: <EngineTorrentView>[
        _torrent(id: 1, name: _vcb(51), fileName: 'ep01.mp4', folder: dir.path),
      ],
      reveal: reveal,
    ));
    await tester.pumpAndSettle();

    await _useListView(tester);
    await tester.tap(find.widgetWithText(NeoButton, '打开文件夹').first);
    await tester.pumpAndSettle();

    expect(reveal.paths, <String>['${dir.path}\\ep01.mp4'],
        reason: '必须是 outputFolder + 文件名 的绝对路径，不能拿引擎那个相对 path 直接用');
  });

  testWidgets('引擎没给 outputFolder（路径会退化成相对路径）→ 绝不交给资源管理器，改说清原因',
      (WidgetTester tester) async {
    // 第十七轮真机缺陷：把**相对路径**丢给资源管理器，它会按自己的默认目录开窗
    //（用户看到的是「跳到了文档文件夹」）。
    tester.view.physicalSize = const Size(1500, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final _RecordingReveal reveal = _RecordingReveal();
    await tester.pumpWidget(harness(
      torrents: <EngineTorrentView>[
        _torrent(id: 1, name: _vcb(51), fileName: 'ep01.mp4', folder: ''),
      ],
      reveal: reveal,
    ));
    await tester.pumpAndSettle();

    await _useListView(tester);
    await tester.tap(find.widgetWithText(NeoButton, '打开文件夹').first);
    await tester.pumpAndSettle();

    expect(reveal.paths, isEmpty, reason: '相对路径一律不打开（那正是"跳到别的地方"的根源）');
    expect(find.textContaining('没能定位到这个文件'), findsOneWidget);
  });

  testWidgets('移除任务：deleteFiles=false（文件留着），绝不碰回收站', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(2000, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final _FakeQueue queue = _FakeQueue();
    final _RecordingRecycle recycle = _RecordingRecycle();
    await tester.pumpWidget(harness(
      torrents: <EngineTorrentView>[
        _torrent(id: 5, name: _vcb(51), fileName: 'a.mp4', folder: dir.path),
        _torrent(id: 6, name: _vcb(52), fileName: 'b.mp4', folder: dir.path),
      ],
      queue: queue,
      recycle: recycle,
    ));
    await tester.pumpAndSettle();

    await _useListView(tester);
    await tester.tap(find.widgetWithText(NeoButton, '展开 2 集'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(NeoButton, '移除').first);
    await tester.pumpAndSettle();
    expect(find.text('从列表移除这个任务？'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, '移除任务'));
    await tester.pumpAndSettle();

    expect(queue.calls, <String>['removeByEngine:5:deleteFiles=false']);
    expect(recycle.batches, isEmpty, reason: '「移除」不删文件');
  });

  testWidgets('删文件：确认后走「移除任务(deleteFiles=false) + 回收站」，且路径是绝对的', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(2000, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    // 真文件：走一遍"存在性"判定（missing 才不会误报）。
    File('${dir.path}\\ep01.mp4').writeAsStringSync('x');

    final _FakeQueue queue = _FakeQueue();
    final _RecordingRecycle recycle = _RecordingRecycle();
    await tester.pumpWidget(harness(
      torrents: <EngineTorrentView>[
        _torrent(id: 9, name: _vcb(51), fileName: 'ep01.mp4', folder: dir.path),
      ],
      queue: queue,
      recycle: recycle,
    ));
    await tester.pumpAndSettle();

    await _useListView(tester);
    await tester.tap(find.widgetWithText(NeoButton, '展开 1 集'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(NeoButton, '删文件'));
    await tester.pumpAndSettle();

    expect(find.text('删除文件到回收站？'), findsOneWidget);
    expect(find.textContaining('可以还原'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, '删到回收站'));
    await tester.pumpAndSettle();

    expect(queue.calls, <String>['removeByEngine:9:deleteFiles=false'],
        reason: '引擎那条删除绝不能带 deleteFiles=true（那是永久删除）');
    expect(recycle.all, <String>['${dir.path}\\ep01.mp4']);
    expect(find.textContaining('已进回收站'), findsOneWidget);
  });
}
