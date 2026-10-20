/// 「本地」页的 widget 测试：**不碰磁盘、不起引擎**。
///
/// 假扫描器 + 假选择器 + 假播放端口，钉住用户看到的东西：
/// * 一个文件夹都没有 → 空态 + 「选择文件夹」那一个下一步动作；
/// * 有文件夹有视频 → 页头统计、文件夹那行、按目录分段、行内"看到 12:34"；
/// * 点「继续播放」→ 走 `playLocal`（请求是 `file:` URI，起点 = 记下的进度）；
/// * 扫失败的文件夹 → 那一行红字写明原因，别的行照常；
/// * 点「移除」先确认，并且文案说明"磁盘上一个文件都不动"。
library;

import 'package:dsanima/domain/local_media.dart';
import 'package:dsanima/domain/models.dart';
import 'package:dsanima/domain/ports.dart';
import 'package:dsanima/state/infra.dart';
import 'package:dsanima/state/local_library.dart';
import 'package:dsanima/state/providers.dart' show playerPortProvider;
import 'package:dsanima/theme/app_theme.dart';
import 'package:dsanima/ui/local_page.dart';
import 'package:dsanima_core/sources/kv.dart' show InMemoryKeyValueStore;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

final String _root = p.join('F:', 'Anime');
final String _dir = p.join(_root, 'Show');
final String _ep1 = p.join(_dir, 'Show - 01.mkv');
final String _ep2 = p.join(_dir, 'Show - 02.mkv');
final String _sub1 = p.join(_dir, 'Show - 01.ass');

class _FakeScanner implements LocalMediaScannerPort {
  _FakeScanner({this.files = const <String, List<String>>{}, Set<String>? broken})
    : broken = broken ?? <String>{};

  final Map<String, List<String>> files;
  final Set<String> broken;

  @override
  bool get isSupported => true;

  @override
  Future<List<LocalFileStat>> scan(String folder) async {
    if (broken.contains(folder)) throw LocalScanException('读不了这个文件夹：$folder');
    return <LocalFileStat>[
      for (final String path in files[folder] ?? const <String>[]) LocalFileStat(path: path, sizeBytes: 1000000),
    ];
  }
}

class _FakePicker implements PickerPort {
  _FakePicker(this.next);

  String? next;

  @override
  Future<String?> pickDirectory({String? title}) async => next;

  @override
  Future<String?> pickFile({String? title, List<String> extensions = const <String>[]}) async => null;
}

class _PlayerPort implements PlayerPort {
  final List<PlayerRequest> opened = <PlayerRequest>[];

  @override
  bool get isAvailable => true;

  @override
  Future<void> open(PlayerRequest request, {dynamic episodeGroup}) async => opened.add(request);

  @override
  Future<void> playOrPause() async {}
  @override
  Future<void> seek(Duration position) async {}
  @override
  Future<void> stop() async {}
  @override
  Stream<PlaybackSignal> get signals => const Stream<PlaybackSignal>.empty();
  @override
  Future<void> dispose() async {}
}

class _Harness {
  _Harness({
    List<String> folders = const <String>[],
    Map<String, Object?> progress = const <String, Object?>{},
    List<String>? files,
    Set<String>? broken,
    String? picked,
  }) : store = InMemoryKeyValueStore(<String, Object?>{
          if (folders.isNotEmpty) kLocalFoldersKey: folders,
          if (progress.isNotEmpty) kLocalProgressKey: progress,
        }) {
    scanner = _FakeScanner(
      files: <String, List<String>>{
        _root: files ?? <String>[_ep1, _ep2, _sub1],
      },
      broken: broken,
    );
    picker = _FakePicker(picked);
  }

  final InMemoryKeyValueStore store;
  late final _FakeScanner scanner;
  late final _FakePicker picker;
  final _PlayerPort player = _PlayerPort();
  late final ProviderContainer container;

  /// 只在需要读容器状态（是否真的起了播）时用；widget 测试本身不需要它。
  void build() {
    container = ProviderContainer(
      overrides: [
        keyValueStoreProvider.overrideWithValue(store),
        localMediaScannerProvider.overrideWithValue(scanner),
        pickerPortProvider.overrideWithValue(picker),
        playerPortProvider.overrideWithValue(player),
      ],
    );
    addTearDown(container.dispose);
  }

  Widget app() => ProviderScope(
    overrides: [
      keyValueStoreProvider.overrideWithValue(store),
      localMediaScannerProvider.overrideWithValue(scanner),
      pickerPortProvider.overrideWithValue(picker),
      playerPortProvider.overrideWithValue(player),
    ],
    child: MaterialApp(theme: buildDsanimaTheme(), home: const Scaffold(body: LocalPage())),
  );
}

void main() {
  testWidgets('没有文件夹：空态 + 「选择文件夹」', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final _Harness h = _Harness();
    await tester.pumpWidget(h.app());
    await tester.pumpAndSettle();

    expect(find.text('还没有添加文件夹'), findsOneWidget);
    expect(find.text('0 个文件夹 · 0 个视频'), findsOneWidget);
    expect(find.byKey(dsLocalAddFolderKey), findsOneWidget);
    expect(find.text('选择文件夹'), findsWidgets, reason: '空态里也要有下一步动作');
  });

  testWidgets('添加文件夹：选完立刻扫出来并按目录分段', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final _Harness h = _Harness(picked: _root);
    await tester.pumpWidget(h.app());
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(dsLocalAddFolderKey));
    await tester.pumpAndSettle();

    expect(find.textContaining('1 个文件夹'), findsOneWidget, reason: '统计要更新：1 个文件夹');
    expect(find.textContaining('2 个视频'), findsWidgets);
    expect(find.byKey(dsLocalFolderRowKey(_root)), findsOneWidget);
    expect(find.text('Show'), findsOneWidget, reason: '子目录成一整段（段标题是相对路径）');
    expect(find.byKey(dsLocalVideoRowKey(_ep1)), findsOneWidget);
    expect(find.byKey(dsLocalVideoRowKey(_ep2)), findsOneWidget);
    expect(find.text('字幕'), findsOneWidget, reason: '配到同名字幕的那一行要有标记');
  });

  testWidgets('点「继续播放」：走 playLocal，起点 = 记下的进度', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final _Harness h = _Harness(
      folders: <String>[_root],
      progress: <String, Object?>{
        _ep1: <String, Object?>{'positionMs': 90000, 'durationMs': 1440000},
      },
    );
    await tester.pumpWidget(h.app());
    await tester.pumpAndSettle();

    expect(find.text('继续播放'), findsOneWidget);
    expect(find.textContaining('看到 01:30 / 24:00'), findsOneWidget);

    await tester.tap(find.text('继续播放'));
    await tester.pumpAndSettle();

    expect(h.player.opened.length, 1);
    final PlayerRequest req = h.player.opened.single;
    expect(req.streamUrl.toString(), localFileUriText(_ep1));
    expect(req.startAt, const Duration(milliseconds: 90000));
  });

  testWidgets('扫失败的文件夹：那一行红字说明原因，别的行照常', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final String offline = p.join('F:', 'Offline');
    final _Harness h = _Harness(folders: <String>[offline, _root], broken: <String>{offline});
    await tester.pumpWidget(h.app());
    await tester.pumpAndSettle();

    expect(find.textContaining('读不了这个文件夹'), findsOneWidget);
    expect(find.byKey(dsLocalVideoRowKey(_ep1)), findsOneWidget, reason: '好文件夹照常列出来');
    expect(find.textContaining('1 个文件夹读不了'), findsOneWidget);
  });

  testWidgets('移除文件夹：先确认，文案说明不删文件', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final _Harness h = _Harness(folders: <String>[_root]);
    await tester.pumpWidget(h.app());
    await tester.pumpAndSettle();

    await tester.tap(find.descendant(
      of: find.byKey(dsLocalFolderRowKey(_root)),
      matching: find.byIcon(Icons.remove_circle_outline),
    ));
    await tester.pumpAndSettle();

    expect(find.text('不再显示这个文件夹？'), findsOneWidget);
    expect(find.textContaining('磁盘上的文件一个都不动'), findsOneWidget);

    await tester.tap(find.text('移除'));
    await tester.pumpAndSettle();

    expect(find.text('还没有添加文件夹'), findsOneWidget);
    expect(h.store.get(kLocalFoldersKey), isEmpty);
  });

  testWidgets('一个视频都没有：空态说明认得的格式', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final _Harness h = _Harness(folders: <String>[_root], files: <String>[]);
    await tester.pumpWidget(h.app());
    await tester.pumpAndSettle();

    expect(find.text('这些文件夹里没找到视频'), findsOneWidget);
    expect(find.textContaining('mkv'), findsWidgets);
  });
}
