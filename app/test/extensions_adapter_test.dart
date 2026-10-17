/// 扩展安装适配器（`state/extensions_adapter.dart`）的真 IO 测试。
///
/// 用户定的规矩（1.1.0 M3/T14）：**装不上就是装不上、取消是真的取消、卸载进回收站**。
/// 这里用**真 zip**（`archive` 的 ZipEncoder 造的字节）+ **假 HTTP**（自写 `http.BaseClient`）
/// + 临时目录，把契约 6 条逐条钉住；一个字节都不联网、不动用户目录、不真删任何东西
///（回收站走注入的假实现）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:dsanima_core/dsanima_core.dart' as core;
import 'package:dsanima/domain/extensions.dart';
import 'package:dsanima/domain/reveal_in_explorer.dart';
import 'package:dsanima/state/extensions_adapter.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

// ─────────────────────────────────────────────────────────────────────────────
// 夹具
// ─────────────────────────────────────────────────────────────────────────────

/// 固定时钟：目录名后缀与 `installedAt` 因此可断言。
DateTime _fixedNow() => DateTime(2026, 10, 17, 12, 0, 0);

String _sha(List<int> bytes) => sha256.convert(bytes).toString();

/// 一个扩展包的内容（清单 + 要落盘的文件）。
class _Fixture {
  _Fixture(this.manifest, this.files);

  final Map<String, Object?> manifest;
  final Map<String, List<int>> files;

  /// 按清单与文件造一个**真 zip**。
  List<int> zip({Map<String, List<int>> extras = const <String, List<int>>{}}) =>
      _zipBytes(manifest: manifest, files: <String, List<int>>{...files, ...extras});
}

/// 造 [Fixture]。
///
/// [wrongShaFor]：把某个文件的 sha256 写成假的（测"逐文件校验失败"）。
/// [minAppVersion]：测"需要更高版本才能装"。
/// [dropFiles]：清单里声明了但 zip 里不提供（测缺文件；本轮只被守卫的
/// `missing-file` 拦住）。
_Fixture _fixture({
  String id = 'demo-pack',
  String name = '演示包',
  String version = '1.0.0',
  String kind = 'data-pack',
  String? minAppVersion,
  String? wrongShaFor,
  Map<String, List<int>>? files,
}) {
  final Map<String, List<int>> payload = files ??
      <String, List<int>>{
        'data/note.txt': utf8.encode('hello dsanima'),
      };
  final List<Object?> manifestFiles = <Object?>[
    for (final MapEntry<String, List<int>> entry in payload.entries)
      <String, Object?>{
        'path': entry.key,
        'size': entry.value.length,
        'sha256': entry.key == wrongShaFor ? 'f' * 64 : _sha(entry.value),
      },
  ];
  final Map<String, Object?> manifest = <String, Object?>{
    'schema': 1,
    'id': id,
    'name': name,
    'version': version,
    'kind': kind,
    'description': '测试用扩展',
    'minAppVersion': ?minAppVersion,
    'files': manifestFiles,
    if (kind == 'shader-pack')
      'payload': <String, Object?>{
        'shader': <String, Object?>{
          'dir': 'shaders',
          'files': <String>[for (final String path in payload.keys) p.basename(path)],
        },
      },
  };
  return _Fixture(manifest, payload);
}

/// 造 zip 字节（`manifest.json` 必须在根目录）。
List<int> _zipBytes({
  required Map<String, Object?> manifest,
  required Map<String, List<int>> files,
}) {
  final Archive archive = Archive();
  archive.add(ArchiveFile.string('manifest.json', jsonEncode(manifest)));
  for (final MapEntry<String, List<int>> entry in files.entries) {
    archive.add(ArchiveFile.bytes(entry.key, entry.value));
  }
  return ZipEncoder().encodeBytes(archive);
}

/// 只装若干文件、**没有** manifest.json 的 zip（测"缺清单"）。
List<int> _zipWithoutManifest(Map<String, List<int>> files) {
  final Archive archive = Archive();
  for (final MapEntry<String, List<int>> entry in files.entries) {
    archive.add(ArchiveFile.bytes(entry.key, entry.value));
  }
  return ZipEncoder().encodeBytes(archive);
}

/// 假 HTTP：记录请求，按注入的回调作答（测试里一个字节都不出网）。
class _FakeClient extends http.BaseClient {
  _FakeClient(this._handler);

  final Future<http.StreamedResponse> Function(http.BaseRequest request) _handler;
  final List<Uri> requests = <Uri>[];
  bool closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    requests.add(request.url);
    return _handler(request);
  }

  @override
  void close() {
    closed = true;
    super.close();
  }
}

/// 假回收站：**只记录并删除临时目录**，绝不碰真实回收站。
class _RecordingTrash {
  final List<List<String>> calls = <List<String>>[];
  bool fail = false;

  Future<void> call(List<String> paths) async {
    calls.add(List<String>.of(paths));
    if (fail) throw StateError('回收站不可用（测试注入）');
    for (final String path in paths) {
      final Directory dir = Directory(path);
      if (dir.existsSync()) dir.deleteSync(recursive: true);
      final File file = File(path);
      if (file.existsSync()) file.deleteSync();
    }
  }

  List<String> get flattened => <String>[for (final List<String> c in calls) ...c];
}

/// 每个用例一份：临时目录 + 一个按 [reply] 作答的适配器。
class _Harness {
  _Harness(
    this.root, {
    required this.reply,
    DateTime Function()? now,
    Future<int?> Function(String path)? freeBytes,
    RevealInExplorer? openDir,
    _RecordingTrash? trash,
  }) : trash = trash ?? _RecordingTrash() {
    adapter = ExtensionsAdapter(
      root: root,
      clientFactory: () => _FakeClient(reply),
      trash: this.trash.call,
      openDir: openDir ??
          (String path) async {
        opened.add(path);
      },
      now: now ?? _fixedNow,
      // 默认给 1TB：磁盘检查不拦正常用例；要测"空间不足"就显式传小值。
      freeBytes: freeBytes ?? ((String path) async => 1 << 40),
    );
  }

  final Directory root;
  final _RecordingTrash trash;
  final List<String> opened = <String>[];
  final Future<http.StreamedResponse> Function(http.BaseRequest request) reply;
  late final ExtensionsAdapter adapter;

  File file(String path) => File(p.join(root.path, path));

  Directory dir(String path) => Directory(p.join(root.path, path));

  Map<String, Object?> readState() =>
      jsonDecode(file(kExtensionsStateFileName).readAsStringSync()) as Map<String, Object?>;

  Map<String, Object?> entries() =>
      (readState()['extensions'] as Map<String, Object?>).cast<String, Object?>();

  /// one entry of state.json（不存在时返回空 map，断言会给出可读失败信息）。
  Map<String, Object?> entry(String id) =>
      (entries()[id] as Map<String, Object?>?) ?? const <String, Object?>{};
}

// ─────────────────────────────────────────────────────────────────────────────
// 小工具
// ─────────────────────────────────────────────────────────────────────────────

Directory _tempDir(String prefix) {
  final Directory dir = Directory.systemTemp.createTempSync(prefix);
  addTearDown(() => _removeDir(dir));
  return dir;
}

void _removeDir(Directory dir) {
  try {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  } catch (_) {
    // 临时目录删不掉不该让用例变红。
  }
}

List<String> _childNames(Directory dir) {
  if (!dir.existsSync()) return const <String>[];
  return dir.listSync().map((FileSystemEntity e) => p.basename(e.path)).toList();
}

/// 一次下载响应；[chunkSize] > 0 时切成多块（测"逐块取消/进度"）。
http.StreamedResponse _zipResponse(List<int> bytes, {int chunkSize = 0}) {
  if (chunkSize <= 0) {
    return http.StreamedResponse(
      Stream<List<int>>.value(bytes),
      200,
      contentLength: bytes.length,
    );
  }
  final List<List<int>> chunks = <List<int>>[];
  for (int i = 0; i < bytes.length; i += chunkSize) {
    chunks.add(bytes.sublist(i, (i + chunkSize).clamp(0, bytes.length)));
  }
  return http.StreamedResponse(
    Stream<List<int>>.fromIterable(chunks),
    200,
    contentLength: bytes.length,
  );
}

/// 在线安装请求（sha256/size 默认按真实 zip 填，测"整体校验"）。
ExtensionInstallRequest _urlRequest(
  List<int> zip, {
  String? sha256,
  int? size,
  String url = 'https://ext.example.com/pkg.zip',
}) =>
    ExtensionInstallRequest(
      url: Uri.parse(url),
      sha256: sha256 ?? _sha(zip),
      size: size ?? zip.length,
      label: '演示包',
    );

/// 本地 zip 安装请求。
ExtensionInstallRequest _localRequest(String path) =>
    ExtensionInstallRequest(localPath: path);

/// 写一个本地 zip 文件（放临时目录，模拟用户选中的文件）。
String _writeZipFile(Directory dir, List<int> bytes, {String name = 'pkg.zip'}) {
  final File file = File(p.join(dir.path, name));
  file.writeAsBytesSync(bytes, flush: true);
  return file.path;
}

void main() {
  // ── 契约 1/2：安装成功 ──────────────────────────────────────────────────────
  test('安装成功：下载→校验→解压→原子就位，state.json 记录完整', () async {
    final Directory root = _tempDir('dsanima_ext_ok_');
    final _Fixture fixture = _fixture();
    final List<int> zip = fixture.zip();
    final _Harness harness = _Harness(
      root,
      reply: (http.BaseRequest request) async => _zipResponse(zip, chunkSize: 32),
    );

    final List<ExtensionProgress> progress = <ExtensionProgress>[];
    final InstalledExtension installed = await harness.adapter.install(
      _urlRequest(zip),
      onProgress: progress.add,
    );

    expect(installed.id, 'demo-pack');
    expect(installed.name, '演示包');
    expect(installed.manifest.version, '1.0.0');
    expect(installed.enabled, isTrue);
    expect(installed.origin, ExtensionOrigin.url);
    expect(installed.sourceUrl, 'https://ext.example.com/pkg.zip');
    expect(installed.installedAt, _fixedNow());
    expect(installed.bytes, greaterThan(0));
    expect(installed.usable, isFalse, reason: 'data-pack 本版本不接运行时（装上≠能用）');

    // 文件真的落在正式目录里
    expect(harness.file('demo-pack/manifest.json').existsSync(), isTrue);
    expect(
      harness.file('demo-pack/data/note.txt').readAsStringSync(),
      'hello dsanima',
    );

    // state.json 记录完整
    expect(harness.readState()['schema'], kExtensionsStateSchema);
    final Map<String, Object?> entry =
        (harness.entries()['demo-pack'] as Map<String, Object?>);
    expect(entry['enabled'], isTrue);
    expect(entry['origin'], 'url');
    expect(entry['sourceUrl'], 'https://ext.example.com/pkg.zip');
    expect((entry['manifest'] as Map<String, Object?>)['version'], '1.0.0');

    // 临时目录与半截文件都清干净（契约 1/3）
    expect(_childNames(harness.dir(kExtensionsStagingDirName)), isEmpty);
    expect(_childNames(harness.dir(kExtensionsDownloadsDirName)), isEmpty);
    expect(_childNames(harness.dir(kExtensionsTrashDirName)), isEmpty);

    // 进度：单调不减，最后一条到顶
    expect(progress, isNotEmpty);
    for (int i = 1; i < progress.length; i++) {
      expect(progress[i].received, greaterThanOrEqualTo(progress[i - 1].received));
    }
    expect(progress.last.received, zip.length);
    expect(progress.last.total, zip.length);
    expect(progress.last.fraction, 1.0);
  });

  test('本地 zip：origin=localZip、无 sourceUrl，仍走完整校验', () async {
    final Directory root = _tempDir('dsanima_ext_local_');
    final Directory src = _tempDir('dsanima_ext_src_');
    final _Fixture fixture = _fixture(id: 'local-pack');
    final List<int> zip = fixture.zip();
    final String path = _writeZipFile(src, zip);
    final _Harness harness = _Harness(
      root,
      reply: (http.BaseRequest request) async =>
          fail('本地安装不该发请求：${request.url}'),
    );

    final InstalledExtension installed = await harness.adapter.install(_localRequest(path));
    expect(installed.id, 'local-pack');
    expect(installed.origin, ExtensionOrigin.localZip);
    expect(installed.sourceUrl, isNull);
    expect(harness.file('local-pack/data/note.txt').existsSync(), isTrue);
    expect(_childNames(harness.dir(kExtensionsStagingDirName)), isEmpty);
  });

  test('shader-pack 装好后 usable=true，files 与 payload.shader 都对得上', () async {
    final Directory root = _tempDir('dsanima_ext_shader_');
    final _Fixture fixture = _fixture(
      id: 'shader-pack',
      kind: 'shader-pack',
      files: <String, List<int>>{
        'shaders/Anime4K_Clamp_Highlights.glsl': utf8.encode('// glsl one'),
        'shaders/Anime4K_Restore_CNN.glsl': utf8.encode('// glsl two'),
      },
    );
    final List<int> zip = fixture.zip();
    final _Harness harness = _Harness(
      root,
      reply: (http.BaseRequest request) async => _zipResponse(zip),
    );
    final InstalledExtension installed = await harness.adapter.install(_urlRequest(zip));
    expect(installed.usable, isTrue);
    expect(installed.manifest.shader?.rootRelativePaths, <String>[
      'shaders/Anime4K_Clamp_Highlights.glsl',
      'shaders/Anime4K_Restore_CNN.glsl',
    ]);
    expect(
      harness.file('shader-pack/shaders/Anime4K_Restore_CNN.glsl').existsSync(),
      isTrue,
    );
  });

  // ── 契约 2：清单 / 包体校验 ────────────────────────────────────────────────
  test('zip 缺 manifest.json：拒绝，正式目录无半成品', () async {
    final Directory root = _tempDir('dsanima_ext_nomanifest_');
    final List<int> zip = _zipWithoutManifest(<String, List<int>>{
      'data/note.txt': utf8.encode('hello'),
    });
    final _Harness harness = _Harness(
      root,
      reply: (http.BaseRequest request) async => _zipResponse(zip),
    );

    await expectLater(
      harness.adapter.install(_urlRequest(zip)),
      throwsA(isA<ExtensionFailure>().having(
        (ExtensionFailure error) => error.message,
        'message',
        contains('manifest.json'),
      )),
    );
    expect(harness.dir('demo-pack').existsSync(), isFalse);
    expect(_childNames(harness.dir(kExtensionsStagingDirName)), isEmpty);
    expect(harness.file(kExtensionsStateFileName).existsSync(), isFalse,
        reason: '失败不该写 state.json');
  });

  test('zip 根本不是 zip：拒绝并说清楚（下载到 HTML 的常见情况）', () async {
    final Directory root = _tempDir('dsanima_ext_notzip_');
    final List<int> notZip = utf8.encode('<html>404 Not Found</html>');
    final _Harness harness = _Harness(
      root,
      reply: (http.BaseRequest request) async => _zipResponse(notZip),
    );
    await expectLater(
      harness.adapter.install(_urlRequest(notZip)),
      throwsA(isA<ExtensionFailure>().having(
        (ExtensionFailure error) => error.message,
        'message',
        anyOf(contains('zip'), contains('空')),
      )),
    );
    expect(harness.dir('demo-pack').existsSync(), isFalse);
  });

  test('清单非法（缺 files）：拒绝，报的是清单问题', () async {
    final Directory root = _tempDir('dsanima_ext_badmanifest_');
    final List<int> zip = _zipBytes(
      manifest: <String, Object?>{
        'schema': 1,
        'id': 'demo-pack',
        'name': '演示包',
        'version': '1.0.0',
        'kind': 'data-pack',
      },
      files: <String, List<int>>{'data/note.txt': utf8.encode('hi')},
    );
    final _Harness harness = _Harness(
      root,
      reply: (http.BaseRequest request) async => _zipResponse(zip),
    );
    await expectLater(
      harness.adapter.install(_urlRequest(zip)),
      throwsA(isA<ExtensionFailure>().having(
        (ExtensionFailure error) => error.message,
        'message',
        contains('清单不合法'),
      )),
    );
    expect(harness.dir('demo-pack').existsSync(), isFalse);
  });

  test('minAppVersion 高于当前版本：拒绝（装上也用不了）', () async {
    final Directory root = _tempDir('dsanima_ext_minver_');
    final _Fixture fixture = _fixture(minAppVersion: '99.0.0');
    final List<int> zip = fixture.zip();
    final _Harness harness = _Harness(
      root,
      reply: (http.BaseRequest request) async => _zipResponse(zip),
    );
    await expectLater(
      harness.adapter.install(_urlRequest(zip)),
      // 面向用户的文案必须是"要更高版本"，不是字段名（`minAppVersion` 是清单里的键，
      // 用户看不懂；字段名只在 core 的 issue.field 里给日志用）。
      throwsA(isA<ExtensionFailure>()
          .having(
            (ExtensionFailure error) => error.message,
            'message',
            contains('需要 DSAnima 99.0.0'),
          )
          .having((ExtensionFailure error) => error.hint, 'hint', isNotNull)),
    );
    expect(harness.dir('demo-pack').existsSync(), isFalse);
  });

  test('夹带文件（清单没声明的文件）：拒绝，一个字节都不解压', () async {
    final Directory root = _tempDir('dsanima_ext_smuggle_');
    final _Fixture fixture = _fixture();
    final List<int> zip = fixture.zip(extras: <String, List<int>>{
      'payload/evil.exe': utf8.encode('MZ fake binary'),
    });
    final _Harness harness = _Harness(
      root,
      reply: (http.BaseRequest request) async => _zipResponse(zip),
    );
    await expectLater(
      harness.adapter.install(_urlRequest(zip)),
      throwsA(isA<ExtensionFailure>().having(
        (ExtensionFailure error) => error.message,
        'message',
        contains('不安全'),
      )),
    );
    expect(harness.dir('demo-pack').existsSync(), isFalse);
    expect(harness.file('demo-pack/payload/evil.exe').existsSync(), isFalse);
    expect(_childNames(harness.dir(kExtensionsStagingDirName)), isEmpty);
  });

  test('zip 整体 sha256 不符：拒绝且不留 .part', () async {
    final Directory root = _tempDir('dsanima_ext_zipsah_');
    final _Fixture fixture = _fixture();
    final List<int> zip = fixture.zip();
    final _Harness harness = _Harness(
      root,
      reply: (http.BaseRequest request) async => _zipResponse(zip, chunkSize: 16),
    );
    await expectLater(
      harness.adapter.install(_urlRequest(zip, sha256: 'f' * 64)),
      throwsA(isA<ExtensionFailure>().having(
        (ExtensionFailure error) => error.message,
        'message',
        contains('sha256'),
      )),
    );
    expect(harness.dir('demo-pack').existsSync(), isFalse);
    expect(_childNames(harness.dir(kExtensionsDownloadsDirName)), isEmpty,
        reason: '校验失败必须删掉 .part');
  });

  test('逐文件 sha256 不符：拒绝（包能被 zip 解开，但内容对不上清单）', () async {
    final Directory root = _tempDir('dsanima_ext_filesah_');
    final _Fixture fixture = _fixture(wrongShaFor: 'data/note.txt');
    final List<int> zip = fixture.zip();
    final _Harness harness = _Harness(
      root,
      reply: (http.BaseRequest request) async => _zipResponse(zip),
    );
    await expectLater(
      harness.adapter.install(_urlRequest(zip)),
      throwsA(isA<ExtensionFailure>().having(
        (ExtensionFailure error) => error.message,
        'message',
        contains('校验失败'),
      )),
    );
    expect(harness.dir('demo-pack').existsSync(), isFalse);
    expect(_childNames(harness.dir(kExtensionsStagingDirName)), isEmpty);
  });

  // ── 契约 3：取消 ───────────────────────────────────────────────────────────
  test('取消（在 onProgress 里点取消）：抛 ExtensionInstallCancelled，.part/.staging 清空', () async {
    final Directory root = _tempDir('dsanima_ext_cancel_');
    final _Fixture fixture = _fixture();
    final List<int> zip = fixture.zip();
    final _Harness harness = _Harness(
      root,
      reply: (http.BaseRequest request) async => _zipResponse(zip, chunkSize: 8),
    );

    bool cancelled = false;
    int cancelPolls = 0;
    int progressCalls = 0;
    await expectLater(
      harness.adapter.install(
        _urlRequest(zip),
        onProgress: (ExtensionProgress progress) {
          progressCalls++;
          cancelled = true; // 第一块下完就点取消
        },
        isCancelled: () {
          cancelPolls++;
          return cancelled;
        },
      ),
      throwsA(isA<ExtensionInstallCancelled>()),
    );

    expect(progressCalls, greaterThan(0));
    expect(cancelPolls, greaterThan(1), reason: '每个 chunk 都要问一次取消');
    expect(harness.dir('demo-pack').existsSync(), isFalse, reason: '正式目录不许有半成品');
    expect(_childNames(harness.dir(kExtensionsDownloadsDirName)), isEmpty);
    expect(_childNames(harness.dir(kExtensionsStagingDirName)), isEmpty);
    expect(harness.file(kExtensionsStateFileName).existsSync(), isFalse);
  });

  test('取消后可以立刻重装成功（临时文件没留痕）', () async {
    final Directory root = _tempDir('dsanima_ext_retry_');
    final _Fixture fixture = _fixture();
    final List<int> zip = fixture.zip();
    bool cancelled = false;
    final _Harness harness = _Harness(
      root,
      reply: (http.BaseRequest request) async => _zipResponse(zip, chunkSize: 8),
    );
    await expectLater(
      harness.adapter.install(
        _urlRequest(zip),
        onProgress: (ExtensionProgress progress) => cancelled = true,
        isCancelled: () => cancelled,
      ),
      throwsA(isA<ExtensionInstallCancelled>()),
    );
    cancelled = false;
    final InstalledExtension installed = await harness.adapter.install(_urlRequest(zip));
    expect(installed.id, 'demo-pack');
    expect(harness.file('demo-pack/data/note.txt').existsSync(), isTrue);
  });

  // ── 升级 / 卸载 / 启用 ─────────────────────────────────────────────────────
  test('升级：保留原来的 enabled=false，旧版本进回收站，新内容生效', () async {
    final Directory root = _tempDir('dsanima_ext_upgrade_');
    final List<int> zipV1 = _fixture(version: '1.0.0').zip();
    final _Harness harness = _Harness(
      root,
      reply: (http.BaseRequest request) async => _zipResponse(zipV1),
    );
    await harness.adapter.install(_urlRequest(zipV1));
    await harness.adapter.setEnabled('demo-pack', false);

    final List<int> zipV2 = _fixture(
      version: '2.0.0',
      files: <String, List<int>>{'data/note.txt': utf8.encode('v2 content')},
    ).zip();
    final _Harness harness2 = _Harness(
      root,
      reply: (http.BaseRequest request) async => _zipResponse(zipV2),
      trash: harness.trash,
    );
    final InstalledExtension upgraded = await harness2.adapter.install(_urlRequest(zipV2));

    expect(upgraded.manifest.version, '2.0.0');
    expect(upgraded.enabled, isFalse, reason: '用户禁用过的包升级后不该自己变启用');
    expect(harness.file('demo-pack/data/note.txt').readAsStringSync(), 'v2 content');
    // 旧版本走的是注入的回收站，传的是 .trash/ 里的路径
    expect(harness.trash.calls, hasLength(1));
    expect(harness.trash.flattened.single, contains(kExtensionsTrashDirName));
    expect(_childNames(harness.dir(kExtensionsTrashDirName)), isEmpty,
        reason: '假回收站成功后旧目录不该还留在 .trash');
    // 落盘的 enabled 也是 false
    expect(harness.entry('demo-pack')['enabled'], isFalse);
    expect((await harness2.adapter.scan()).single.enabled, isFalse);
  });

  test('卸载：目录交给回收站、state.json 去条目；重复卸载静默成功', () async {
    final Directory root = _tempDir('dsanima_ext_remove_');
    final List<int> zip = _fixture().zip();
    final _Harness harness = _Harness(
      root,
      reply: (http.BaseRequest request) async => _zipResponse(zip),
    );
    await harness.adapter.install(_urlRequest(zip));
    expect(harness.dir('demo-pack').existsSync(), isTrue);

    await harness.adapter.remove('demo-pack');
    expect(harness.trash.flattened.single, p.join(root.path, 'demo-pack'));
    expect(harness.dir('demo-pack').existsSync(), isFalse);
    expect(harness.entries(), isEmpty);
    expect(await harness.adapter.scan(), isEmpty);

    // 重复点卸载 / 卸载不存在的 id：静默成功（界面不该报错）
    await harness.adapter.remove('demo-pack');
    await harness.adapter.remove('never-installed');
    expect(harness.trash.calls, hasLength(1));
  });

  test('卸载时回收站失败：抛 ExtensionFailure，目录与记录都还在', () async {
    final Directory root = _tempDir('dsanima_ext_trashfail_');
    final List<int> zip = _fixture().zip();
    final _Harness harness = _Harness(
      root,
      reply: (http.BaseRequest request) async => _zipResponse(zip),
    );
    await harness.adapter.install(_urlRequest(zip));
    harness.trash.fail = true;

    await expectLater(
      harness.adapter.remove('demo-pack'),
      throwsA(isA<ExtensionFailure>().having(
        (ExtensionFailure error) => error.message,
        'message',
        contains('回收站'),
      )),
    );
    expect(harness.dir('demo-pack').existsSync(), isTrue, reason: '失败必须保留目录');
    expect(harness.entries().keys, contains('demo-pack'), reason: '记录也不能先删');
  });

  test('setEnabled 立即写盘，且 scan 读到的是新值', () async {
    final Directory root = _tempDir('dsanima_ext_enable_');
    final List<int> zip = _fixture().zip();
    final _Harness harness = _Harness(
      root,
      reply: (http.BaseRequest request) async => _zipResponse(zip),
    );
    await harness.adapter.install(_urlRequest(zip));
    await harness.adapter.setEnabled('demo-pack', false);
    expect(harness.entry('demo-pack')['enabled'], isFalse);
    expect((await harness.adapter.scan()).single.enabled, isFalse);
    await harness.adapter.setEnabled('demo-pack', true);
    expect((await harness.adapter.scan()).single.enabled, isTrue);
  });

  // ── 契约 5：状态以磁盘为准 ─────────────────────────────────────────────────
  test('坏 state.json：当空并备份，scan 从目录重建（不丢已装扩展）', () async {
    final Directory root = _tempDir('dsanima_ext_corrupt_');
    final _Fixture fixture = _fixture();
    final Directory installed = Directory(p.join(root.path, 'demo-pack'))
      ..createSync(recursive: true);
    File(p.join(installed.path, 'manifest.json'))
        .writeAsStringSync(jsonEncode(fixture.manifest));
    for (final MapEntry<String, List<int>> entry in fixture.files.entries) {
      final File target = File(p.joinAll(<String>[installed.path, ...entry.key.split('/')]));
      target.parent.createSync(recursive: true);
      target.writeAsBytesSync(entry.value);
    }
    final File state = File(p.join(root.path, kExtensionsStateFileName))
      ..writeAsStringSync('{ 这不是 JSON');

    final _Harness harness = _Harness(
      root,
      reply: (http.BaseRequest request) async => fail('scan 不该发请求'),
    );
    final List<InstalledExtension> list = await harness.adapter.scan();

    expect(list, hasLength(1));
    expect(list.single.id, 'demo-pack');
    expect(list.single.enabled, isTrue, reason: '没有记录时按磁盘补一条 enabled=true');
    expect(list.single.origin, ExtensionOrigin.localZip);

    // 坏文件被备份（内容是原样字节），新的 state.json 是合法 JSON
    final List<String> names = _childNames(root);
    final String backup = names.firstWhere(
      (String name) => name.startsWith('$kExtensionsStateFileName.corrupt'),
      orElse: () => fail('没有备份坏 state.json（实际：$names）'),
    );
    expect(File(p.join(root.path, backup)).readAsStringSync(), '{ 这不是 JSON');
    expect(harness.entries().keys, <String>['demo-pack']);
    expect(state.existsSync(), isTrue);
  });

  test('state.json 缺失：目录在就补一条 enabled=true 并回写', () async {
    final Directory root = _tempDir('dsanima_ext_orphan_');
    final _Fixture fixture = _fixture();
    final Directory installed = Directory(p.join(root.path, 'demo-pack'))
      ..createSync(recursive: true);
    File(p.join(installed.path, 'manifest.json'))
        .writeAsStringSync(jsonEncode(fixture.manifest));
    final _Harness harness = _Harness(
      root,
      reply: (http.BaseRequest request) async => fail('scan 不该发请求'),
    );

    final List<InstalledExtension> list = await harness.adapter.scan();
    expect(list.single.enabled, isTrue);
    expect(harness.entry('demo-pack')['enabled'], isTrue);
    // 注：清单里声明的 files 不在盘上（这里是手造的"半截目录"），scan 仍会列出它 ——
    // 它列的是"目录里有合法清单"，完整性由安装流程保证。
  });

  test('目录被手动删掉后 scan 对账：条目作废并回写 state.json', () async {
    final Directory root = _tempDir('dsanima_ext_gone_');
    final List<int> zip = _fixture().zip();
    final _Harness harness = _Harness(
      root,
      reply: (http.BaseRequest request) async => _zipResponse(zip),
    );
    await harness.adapter.install(_urlRequest(zip));
    expect(harness.entries().keys, <String>['demo-pack']);

    Directory(p.join(root.path, 'demo-pack')).deleteSync(recursive: true);
    final List<InstalledExtension> list = await harness.adapter.scan();
    expect(list, isEmpty);
    expect(harness.entries(), isEmpty, reason: '失联条目必须从 state.json 里作废');
    expect(harness.readState()['schema'], kExtensionsStateSchema, reason: '仍是合法 state.json');
  });

  test('state.json 原子写：不留 .tmp，失败安装不改已有记录', () async {
    final Directory root = _tempDir('dsanima_ext_atomic_');
    final List<int> zip = _fixture().zip();
    final _Harness harness = _Harness(
      root,
      reply: (http.BaseRequest request) async => _zipResponse(zip),
    );
    await harness.adapter.install(_urlRequest(zip));
    await harness.adapter.setEnabled('demo-pack', false);

    expect(harness.file('$kExtensionsStateFileName.tmp').existsSync(), isFalse,
        reason: '原子写必须 rename 完，不留临时文件');
    expect(harness.entry('demo-pack')['enabled'], isFalse);

    final String before = harness.file(kExtensionsStateFileName).readAsStringSync();
    final List<int> badZip = _fixture(
      version: '3.0.0',
      wrongShaFor: 'data/note.txt',
    ).zip();
    await expectLater(
      harness.adapter.install(_urlRequest(badZip)),
      throwsA(isA<ExtensionFailure>()),
    );
    final String after = harness.file(kExtensionsStateFileName).readAsStringSync();
    expect(jsonDecode(after), jsonDecode(before), reason: '失败安装不许动已有 state.json');
    expect(harness.dir('demo-pack').existsSync(), isTrue);
  });

  // ── 磁盘余量 ───────────────────────────────────────────────────────────────
  test('磁盘空间不足：解压前就拒绝，不留半成品', () async {
    final Directory root = _tempDir('dsanima_ext_full_');
    final List<int> zip = _fixture().zip();
    final _Harness harness = _Harness(
      root,
      reply: (http.BaseRequest request) async => _zipResponse(zip),
      freeBytes: (String path) async => 1024, // 只剩 1KB
    );
    await expectLater(
      harness.adapter.install(_urlRequest(zip)),
      throwsA(isA<ExtensionFailure>().having(
        (ExtensionFailure error) => error.message,
        'message',
        contains('磁盘空间不足'),
      )),
    );
    expect(harness.dir('demo-pack').existsSync(), isFalse);
    expect(_childNames(harness.dir(kExtensionsStagingDirName)), isEmpty);
    expect(_childNames(harness.dir(kExtensionsDownloadsDirName)), isEmpty);
  });

  // ── 在线目录 / 打开目录 ────────────────────────────────────────────────────
  test('fetchCatalog：解析目录、把相对 url 补全成绝对地址', () async {
    final Directory root = _tempDir('dsanima_ext_catalog_');
    final _Fixture fixture = _fixture();
    final Map<String, Object?> catalog = <String, Object?>{
      'schema': 1,
      'extensions': <Object?>[
        <String, Object?>{
          'url': 'pkg.zip',
          'size': 123,
          'sha256': 'a' * 64,
          'manifest': fixture.manifest,
        },
      ],
    };
    final List<int> body = utf8.encode(jsonEncode(catalog));
    final _Harness harness = _Harness(
      root,
      reply: (http.BaseRequest request) async =>
          http.StreamedResponse(Stream<List<int>>.value(body), 200, contentLength: body.length),
    );

    final List<core.CatalogEntry> entries =
        await harness.adapter.fetchCatalog(Uri.parse('https://ext.example.com/catalog.json'));
    expect(entries, hasLength(1));
    expect(entries.single.manifest.id, 'demo-pack');
    expect(entries.single.url.toString(), 'https://ext.example.com/pkg.zip');
    expect(entries.single.sha256, 'a' * 64);
    expect(entries.single.size, 123);
  });

  test('fetchCatalog：目录全是坏条目 → ExtensionFailure（不返回空目录装成"没有扩展"）', () async {
    final Directory root = _tempDir('dsanima_ext_catalogbad_');
    final List<int> body = utf8.encode(jsonEncode(<String, Object?>{
      'schema': 1,
      'extensions': <Object?>[
        <String, Object?>{'url': 'http://evil.example.com/x.zip'},
      ],
    }));
    final _Harness harness = _Harness(
      root,
      reply: (http.BaseRequest request) async =>
          http.StreamedResponse(Stream<List<int>>.value(body), 200, contentLength: body.length),
    );
    await expectLater(
      harness.adapter.fetchCatalog(Uri.parse('https://ext.example.com/catalog.json')),
      throwsA(isA<ExtensionFailure>()),
    );
  });

  test('openDirectory：建出目录并交给注入的 reveal', () async {
    final Directory root = Directory(p.join(_tempDir('dsanima_ext_open_').path, 'extensions'));
    addTearDown(() => _removeDir(root));
    final _Harness harness = _Harness(
      root,
      reply: (http.BaseRequest request) async => fail('openDirectory 不该发请求'),
    );
    expect(root.existsSync(), isFalse);
    await harness.adapter.openDirectory();
    expect(harness.opened.single, root.path);
    expect(root.existsSync(), isTrue);
  });

  test('安全护栏：http 非回环地址下载直接拒绝（不发请求）', () async {
    final Directory root = _tempDir('dsanima_ext_http_');
    final List<int> zip = _fixture().zip();
    final _Harness harness = _Harness(
      root,
      reply: (http.BaseRequest request) async => fail('不安全地址不该发请求'),
    );
    await expectLater(
      harness.adapter.install(_urlRequest(zip, url: 'http://ext.example.com/pkg.zip')),
      throwsA(isA<ExtensionFailure>()),
    );
    expect(harness.dir('demo-pack').existsSync(), isFalse);
  });

  // ── scan 的整体形态 ────────────────────────────────────────────────────────
  test('scan：装好之后返回的文件字节数与目录占用一致', () async {
    final Directory root = _tempDir('dsanima_ext_scan_');
    final _Fixture fixture = _fixture();
    final List<int> zip = fixture.zip();
    final _Harness harness = _Harness(
      root,
      reply: (http.BaseRequest request) async => _zipResponse(zip),
    );
    final InstalledExtension installed = await harness.adapter.install(_urlRequest(zip));

    int onDisk = 0;
    for (final FileSystemEntity entity
        in Directory(p.join(root.path, 'demo-pack')).listSync(recursive: true)) {
      if (entity is File) onDisk += entity.lengthSync();
    }
    expect(installed.bytes, onDisk);
    expect((await harness.adapter.scan()).single.bytes, onDisk);
  });
}
