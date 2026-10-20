/// `state/local_library.dart` 的控制器测试（假扫描器 / 假选择器 / 内存 KV）。
///
/// 这一层是"页面上的那份状态"的全部来源，钉住四件事：
/// * 文件夹增删会**立刻落盘**（重启还在），重复添加要说出来；
/// * 单个文件夹扫描失败**不拖累**其它文件夹（盘掉线时页面别整页空）；
/// * 进度按**真实路径**记（播放器回推的是 `file:` URI）；
/// * 移除文件夹时，那一棵树下的进度一起清掉（不然进度表会为看不见的文件一直占位）。
library;

import 'package:dsanima/domain/local_media.dart';
import 'package:dsanima/domain/ports.dart';
import 'package:dsanima/state/infra.dart';
import 'package:dsanima/state/local_library.dart';
import 'package:dsanima_core/sources/kv.dart' show InMemoryKeyValueStore;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// 假扫描器：按文件夹路径给结果；可以指定某个文件夹抛异常。
class _FakeScanner implements LocalMediaScannerPort {
  _FakeScanner({this.files = const <String, List<String>>{}, Set<String>? broken})
    : broken = broken ?? <String>{};

  /// 文件夹 → 该文件夹下（递归后的）文件绝对路径清单。
  final Map<String, List<String>> files;
  final Set<String> broken;
  final List<String> scanned = <String>[];

  @override
  bool get isSupported => true;

  @override
  Future<List<LocalFileStat>> scan(String folder) async {
    scanned.add(folder);
    if (broken.contains(folder)) {
      throw LocalScanException('读不了这个文件夹：$folder');
    }
    return <LocalFileStat>[
      for (final String path in files[folder] ?? const <String>[]) LocalFileStat(path: path, sizeBytes: 1000),
    ];
  }
}

/// 假选择器：返回预先设好的路径（null = 用户取消）。
class _FakePicker implements PickerPort {
  _FakePicker(this.next);

  String? next;
  int calls = 0;

  @override
  Future<String?> pickDirectory({String? title}) async {
    calls++;
    return next;
  }

  @override
  Future<String?> pickFile({String? title, List<String> extensions = const <String>[]}) async => null;
}

String _dir(String name) => p.join('F:', 'Anime', name);

class _Harness {
  _Harness({Map<String, Object?> seed = const <String, Object?>{}, this.folders = const <String>[]})
    : store = InMemoryKeyValueStore(<String, Object?>{
        ...seed,
        if (folders.isNotEmpty) kLocalFoldersKey: folders,
      }) {
    container = ProviderContainer(
      overrides: [
        keyValueStoreProvider.overrideWithValue(store),
        localMediaScannerProvider.overrideWithValue(scanner),
        pickerPortProvider.overrideWithValue(picker),
      ],
    );
    addTearDown(container.dispose);
  }

  final InMemoryKeyValueStore store;
  final List<String> folders;
  final _FakeScanner scanner = _FakeScanner(
    files: <String, List<String>>{
      _dir('Root'): <String>[
        p.join(_dir('Root'), 'Show', 'Show - 01.mkv'),
        p.join(_dir('Root'), 'Show', 'Show - 02.mkv'),
      ],
    },
  );
  final _FakePicker picker = _FakePicker(null);
  late final ProviderContainer container;

  LocalLibraryController get controller => container.read(localLibraryProvider.notifier);
  LocalLibraryState get state => container.read(localLibraryProvider);
}

void main() {
  test('启动只读文件夹清单，不自动扫（扫描由进页面触发）', () {
    final _Harness h = _Harness(folders: <String>[_dir('Root')]);
    expect(h.state.folders, <String>[_dir('Root')]);
    expect(h.state.loaded, isFalse);
    expect(h.scanner.scanned, isEmpty, reason: '没人进页面就不该扫盘');
  });

  test('ensureLoaded：扫一遍并整理出视频与分段', () async {
    final _Harness h = _Harness(folders: <String>[_dir('Root')]);
    await h.controller.ensureLoaded();
    expect(h.state.loaded, isTrue);
    expect(h.state.scanning, isFalse);
    expect(h.state.videoCount, 2);
    expect(h.state.groups.single.label, p.join('Show'));
    expect(h.state.groups.single.videos.map((LocalVideo v) => v.episode), <int?>[1, 2]);
    expect(h.scanner.scanned, <String>[_dir('Root')]);
  });

  test('ensureLoaded 只扫一次（再次进页面不重复扫盘）', () async {
    final _Harness h = _Harness(folders: <String>[_dir('Root')]);
    await h.controller.ensureLoaded();
    await h.controller.ensureLoaded();
    expect(h.scanner.scanned.length, 1);
  });

  test('没有文件夹时 ensureLoaded 不扫盘', () async {
    final _Harness h = _Harness();
    await h.controller.ensureLoaded();
    expect(h.state.loaded, isTrue);
    expect(h.scanner.scanned, isEmpty);
  });

  test('添加文件夹：落盘 + 立刻扫', () async {
    final _Harness h = _Harness();
    h.picker.next = _dir('Root');
    final String? added = await h.controller.addFolder();
    expect(added, _dir('Root'));
    expect(h.state.folders, <String>[_dir('Root')]);
    expect(h.store.get(kLocalFoldersKey), <String>[_dir('Root')]);
    expect(h.state.videoCount, 2);
  });

  test('重复添加（大小写不同）不进去，并给出提示', () async {
    final _Harness h = _Harness(folders: <String>[_dir('Root')]);
    h.picker.next = _dir('root');
    final String? added = await h.controller.addFolder();
    expect(added, isNull);
    expect(h.state.folders.length, 1);
    expect(h.state.error, contains('已经加过了'));
  });

  test('手动输入路径：加进来 + 落盘 + 立刻扫', () async {
    final _Harness h = _Harness();
    final String? added = await h.controller.addFolderPath('  ${_dir('Root')}  ');
    expect(added, _dir('Root'), reason: '首尾空白要去掉');
    expect(h.state.folders, <String>[_dir('Root')]);
    expect(h.store.get(kLocalFoldersKey), <String>[_dir('Root')]);
    expect(h.state.videoCount, 2);
  });

  test('手动输入路径：空串直接忽略；重复（大小写不同）报错不进去', () async {
    final _Harness h = _Harness(folders: <String>[_dir('Root')]);
    expect(await h.controller.addFolderPath('   '), isNull);
    expect(h.state.error, isNull, reason: '空串是"什么都没做"，不是错误');
    expect(await h.controller.addFolderPath(_dir('root')), isNull);
    expect(h.state.folders.length, 1);
    expect(h.state.error, contains('已经加过了'));
  });

  test('取消选择 = 什么都不做（不报错、不落盘）', () async {
    final _Harness h = _Harness();
    h.picker.next = null;
    expect(await h.controller.addFolder(), isNull);
    expect(h.state.folders, isEmpty);
    expect(h.state.error, isNull);
    expect(h.store.get(kLocalFoldersKey), isNull);
  });

  test('一个文件夹扫失败不影响别的文件夹', () async {
    final _Harness h = _Harness(folders: <String>[_dir('Broken'), _dir('Root')]);
    h.scanner.broken.add(_dir('Broken'));
    await h.controller.refresh();
    expect(h.state.failedFolders, 1);
    expect(h.state.videoCount, 2, reason: '好文件夹照常列出来');
    final LocalScanResult broken = h.state.results[_dir('Broken')]!;
    expect(broken.ok, isFalse);
    expect(broken.error, contains('读不了这个文件夹'));
    expect(h.state.groups.length, 1);
  });

  test('移除文件夹：列表 / KV / 进度一起清掉（磁盘文件不动）', () async {
    final String under = p.join(_dir('Root'), 'Show', 'Show - 01.mkv');
    final _Harness h = _Harness(
      folders: <String>[_dir('Root')],
      seed: <String, Object?>{
        kLocalProgressKey: <String, Object?>{
          under: <String, Object?>{'positionMs': 60000, 'durationMs': 1440000},
          p.join('F:', 'Other', 'x.mkv'): <String, Object?>{'positionMs': 70000},
        },
      },
    );
    expect(h.state.progress.length, 2);
    await h.controller.removeFolder(_dir('Root'));
    expect(h.state.folders, isEmpty);
    expect(h.store.get(kLocalFoldersKey), isEmpty);
    expect(h.state.progress.keys, <String>[p.join('F:', 'Other', 'x.mkv')],
        reason: '被移除文件夹下的进度要一起清掉，别的保留');
  });

  test('记进度：file: URI 归一成真实路径；<5 秒不记；看完清掉', () async {
    final _Harness h = _Harness();
    final String path = p.join('F:', 'Anime', 'Root', 'Show', 'Show - 01.mkv');
    await h.controller.recordProgress(
      localFileUriText(path),
      positionMs: 3000,
      durationMs: 1440000,
    );
    expect(h.state.progress, isEmpty, reason: '点开看一眼就关，不该留下进度');

    await h.controller.recordProgress(localFileUriText(path), positionMs: 60000, durationMs: 1440000);
    expect(h.state.progress[path]!.positionMs, 60000);
    expect(h.state.resumeMsOf(path), 60000);
    expect(h.store.get(kLocalProgressKey), isNotNull);

    await h.controller.recordProgress(localFileUriText(path), positionMs: 1400000, durationMs: 1440000);
    expect(h.state.progress, isEmpty, reason: '90% 以上算看完 → 清掉');
    expect(h.state.resumeMsOf(path), isNull);
  });

  test('忘掉某一条进度', () async {
    final String path = p.join('F:', 'Anime', 'Root', 'Show', 'Show - 01.mkv');
    final _Harness h = _Harness(
      seed: <String, Object?>{
        kLocalProgressKey: <String, Object?>{
          path: <String, Object?>{'positionMs': 60000},
        },
      },
    );
    expect(h.state.progress.length, 1);
    await h.controller.forgetProgress(path);
    expect(h.state.progress, isEmpty);
    expect(h.store.get(kLocalProgressKey), isEmpty);
  });

  test('视频列表按文件夹顺序、再按集号排', () async {
    final String a = _dir('A');
    final _Harness h = _Harness(folders: <String>[a]);
    h.scanner.files[a] = <String>[
      p.join(a, 'Show', 'Show - 02.mkv'),
      p.join(a, 'Show', 'Show - 01.mkv'),
      p.join(a, 'Alt', 'Alt - 01.mkv'),
    ];
    await h.controller.refresh();
    expect(h.state.videos.map((LocalVideo v) => p.basename(v.path)),
        <String>['Alt - 01.mkv', 'Show - 01.mkv', 'Show - 02.mkv']);
    expect(h.state.videosInFolder(p.join(a, 'Show')).length, 2);
  });
}
