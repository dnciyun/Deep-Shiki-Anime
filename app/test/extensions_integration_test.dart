/// 端到端：真 zip → 真安装 → 真扫盘 → 播放器超分方案（1.1.0 M3/T14+T17 的接缝）。
///
/// 这一条测试的意义是把两段各自单测过的东西接起来看：
/// `ExtensionsAdapter`（下载/校验/原子替换）装出来的目录，`loadExtensionUpscaleSchemes`
/// 能不能翻成 shikiin 的方案、禁用/卸载之后会不会立刻消失。单测各自绿不代表接缝绿。
library;

import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:dsanima_core/dsanima_core.dart' as core;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:shikiin/shikiin.dart';
import 'package:dsanima/domain/extensions.dart';
import 'package:dsanima/state/extension_schemes.dart';
import 'package:dsanima/state/extensions_adapter.dart';
import 'package:dsanima/state/generic_packs.dart';
import 'package:dsanima/state/subtitle_presets.dart';

/// 测试里任何一次网络请求都算失败（本地 zip 安装不该联网）。
class _NoNetworkClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    throw StateError('测试不该发网络请求：${request.method} ${request.url}');
  }
}

String _sha256Hex(List<int> bytes) => sha256.convert(bytes).toString();

/// 造一个最小可安装的 shader-pack zip（与 `tool/package_extension.ps1` 同一格式）。
File _buildZip(
  Directory dir, {
  required String id,
  required String name,
  String shaderSource = '//!DESC 测试 shader\n//!HOOK MAIN\n',
}) {
  final List<int> shaderBytes = utf8.encode(shaderSource);
  final Map<String, Object?> manifest = <String, Object?>{
    'schema': 1,
    'id': id,
    'name': name,
    'version': '1.0.0',
    'kind': 'shader-pack',
    'description': '端到端测试用的最小包',
    'license': 'MIT',
    'files': <Object?>[
      <String, Object?>{
        'path': 'shaders/a.glsl',
        'size': shaderBytes.length,
        'sha256': _sha256Hex(shaderBytes),
      },
    ],
    'payload': <String, Object?>{
      'shader': <String, Object?>{
        'dir': 'shaders',
        'files': <String>['a.glsl'],
        'pipeline': 'glsl-shaders',
      },
    },
  };
  final List<int> manifestBytes = utf8.encode(jsonEncode(manifest));

  final Archive archive = Archive();
  // 顺序照打包脚本：manifest.json 在最前，其余按清单顺序。
  archive.addFile(ArchiveFile('manifest.json', manifestBytes.length, manifestBytes));
  archive.addFile(ArchiveFile('shaders/a.glsl', shaderBytes.length, shaderBytes));

  final List<int> zipBytes = ZipEncoder().encode(archive);
  final File file = File(p.join(dir.path, '$id.zip'));
  file.writeAsBytesSync(zipBytes);
  return file;
}

void main() {
  test('compute 着色器的超分包 → 拒装并说清原因（GLES 跑不了 compute）', () async {
    // 依据：mpv 在 GLES 上无条件关 compute（sr-models-bench §3），CuNNy/ArtCNN 每个
    // pass 都是 //!COMPUTE。不闸的话体验是「装成功 → 菜单里能选 → 播不出来」。
    final Directory tmp = Directory.systemTemp.createTempSync('dsanima-ext-compute-');
    addTearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });
    final Directory support = Directory(p.join(tmp.path, 'data'))..createSync(recursive: true);
    final File zip = _buildZip(
      tmp,
      id: 'compute-pack',
      name: 'CuNNy 风格包',
      shaderSource: '//!DESC CuNNy\n//!HOOK LUMA\n//!COMPUTE 16 16 8 8\n',
    );

    final ExtensionsAdapter adapter = ExtensionsAdapter(
      root: Directory(p.join(support.path, kExtensionsDirName)),
      clientFactory: () => _NoNetworkClient(),
      trash: (List<String> paths) async {},
      openDir: (String path) async {},
      freeBytes: (String path) async => 10 * 1024 * 1024 * 1024,
    );

    await expectLater(
      adapter.install(ExtensionInstallRequest(localPath: zip.path)),
      throwsA(
        isA<ExtensionFailure>()
            .having((ExtensionFailure f) => f.message, 'message', contains('compute'))
            .having((ExtensionFailure f) => f.hint, 'hint', contains('ANGLE')),
      ),
    );
    // 拒装 = 什么都没留下：不许出现半个目录，也不许在超分菜单里留下一个点不动的项。
    expect(
      Directory(p.join(support.path, kExtensionsDirName, 'compute-pack')).existsSync(),
      isFalse,
    );
    expect(await loadExtensionUpscaleSchemes(support), isEmpty);
  });

  test('装 → 方案出现 → 禁用 → 方案消失 → 再启用 → 再出现 → 卸载 → 目录没了', () async {
    final Directory tmp = Directory.systemTemp.createTempSync('dsanima-ext-e2e-');
    addTearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });
    final Directory support = Directory(p.join(tmp.path, 'data'))..createSync(recursive: true);
    final File zip = _buildZip(tmp, id: 'e2e-pack', name: '端到端包');

    final List<List<String>> trashed = <List<String>>[];
    final ExtensionsAdapter adapter = ExtensionsAdapter(
      root: Directory(p.join(support.path, kExtensionsDirName)),
      clientFactory: () => _NoNetworkClient(),
      // 仿真 Windows 回收站：真的把目录挪走（否则"卸载后目录还在"是测试自己的假象）。
      trash: (List<String> paths) async {
        trashed.add(paths);
        for (final String path in paths) {
          final Directory dir = Directory(path);
          if (dir.existsSync()) dir.deleteSync(recursive: true);
        }
      },
      openDir: (String path) async {},
      freeBytes: (String path) async => 10 * 1024 * 1024 * 1024,
    );
    addTearDown(() {});

    // ① 安装（本地 zip：不联网，sha256 由清单逐文件校验）
    final InstalledExtension installed = await adapter.install(
      ExtensionInstallRequest(localPath: zip.path),
    );
    expect(installed.id, 'e2e-pack');
    expect(installed.enabled, isTrue);
    expect(installed.usable, isTrue, reason: 'shader-pack + shader 描述齐 = 能用');
    expect(installed.origin, ExtensionOrigin.localZip);

    // ② 装好的目录结构：manifest.json 在根、shader 在清单目录里
    final Directory extDir = Directory(p.join(support.path, kExtensionsDirName, 'e2e-pack'));
    expect(File(p.join(extDir.path, 'manifest.json')).existsSync(), isTrue);
    expect(File(p.join(extDir.path, 'shaders', 'a.glsl')).existsSync(), isTrue);
    // 临时区必须干净（不许留 .staging / .downloads 半成品）
    expect(Directory(p.join(support.path, kExtensionsDirName, '.staging')).listSync(), isEmpty);

    // ③ 扫盘 → 播放器方案
    final List<UpscaleScheme> schemes = await loadExtensionUpscaleSchemes(support);
    expect(schemes.map((UpscaleScheme s) => s.id), <String>['e2e-pack']);
    final UpscaleScheme scheme = schemes.single;
    expect(scheme.files, <String>['a.glsl']);
    expect(scheme.dir, p.join(extDir.path, 'shaders'));
    expect(scheme.note, contains('MIT'));
    // 与内置合并后：内置两张在前，扩展在后（菜单顺序）
    final List<UpscaleScheme> merged = <UpscaleScheme>[
      ...builtinUpscaleSchemes(),
      ...schemes,
    ];
    expect(merged.map((UpscaleScheme s) => s.id), <String>[
      kAnime4kSchemeId,
      'anime4k-ultra',
      'e2e-pack',
    ]);
    // 选中它：胶囊与还原都认
    const UpscaleSelection selection = UpscaleSelection(schemeId: 'e2e-pack');
    expect(selection.label(merged), '超分 端到端包');
    expect(
      UpscaleSelection.fromSettings(schemeId: 'e2e-pack', schemes: merged).schemeId,
      'e2e-pack',
    );

    // ④ 禁用 → 方案消失，但文件还在
    await adapter.setEnabled('e2e-pack', false);
    expect(await loadExtensionUpscaleSchemes(support), isEmpty);
    expect(File(p.join(extDir.path, 'shaders', 'a.glsl')).existsSync(), isTrue);
    final List<InstalledExtension> afterDisable = await adapter.scan();
    expect(afterDisable.single.enabled, isFalse);

    // ⑤ 再启用 → 又出现
    await adapter.setEnabled('e2e-pack', true);
    expect(
      (await loadExtensionUpscaleSchemes(support)).map((UpscaleScheme s) => s.id),
      <String>['e2e-pack'],
    );

    // ⑥ 卸载 → 目录进回收站（注入的 trash 收到），方案消失
    await adapter.remove('e2e-pack');
    expect(trashed, hasLength(1), reason: '删除必须可恢复：走回收站而不是永久删');
    expect(trashed.single.single, extDir.path, reason: '交给回收站的必须是那个目录本身');
    expect(extDir.existsSync(), isFalse);
    expect(await loadExtensionUpscaleSchemes(support), isEmpty);
    expect(await adapter.scan(), isEmpty);
  });

  test('包体被改过（sha256 不符）→ 安装失败且正式目录没有残留', () async {
    final Directory tmp = Directory.systemTemp.createTempSync('dsanima-ext-e2e-bad-');
    addTearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });
    final Directory support = Directory(p.join(tmp.path, 'data'))..createSync(recursive: true);
    final File zip = _buildZip(tmp, id: 'bad-pack', name: '坏包');

    // 把 zip 里的 shader 内容换掉（重新打包但清单仍写旧 sha256）→ 逐文件校验必须失败。
    final Archive archive = ZipDecoder().decodeBytes(zip.readAsBytesSync());
    final Archive tampered = Archive();
    for (final ArchiveFile file in archive.files) {
      final List<int> bytes = file.content as List<int>;
      tampered.addFile(ArchiveFile(
        file.name,
        file.name == 'shaders/a.glsl' ? bytes.length + 4 : bytes.length,
        file.name == 'shaders/a.glsl'
            ? <int>[...bytes, 0x2f, 0x2f, 0x20, 0x20]
            : bytes,
      ));
    }
    final File badZip = File(p.join(tmp.path, 'bad.zip'))
      ..writeAsBytesSync(ZipEncoder().encode(tampered));

    final ExtensionsAdapter adapter = ExtensionsAdapter(
      root: Directory(p.join(support.path, kExtensionsDirName)),
      clientFactory: () => _NoNetworkClient(),
      trash: (List<String> paths) async {},
      openDir: (String path) async {},
      freeBytes: (String path) async => 10 * 1024 * 1024 * 1024,
    );

    await expectLater(
      adapter.install(ExtensionInstallRequest(localPath: badZip.path)),
      throwsA(isA<ExtensionFailure>()),
    );
    final Directory root = Directory(p.join(support.path, kExtensionsDirName));
    expect(Directory(p.join(root.path, 'bad-pack')).existsSync(), isFalse,
        reason: '校验失败不许留下正式目录');
    expect(Directory(p.join(root.path, '.staging')).listSync(), isEmpty,
        reason: '失败要清掉临时解压目录');
    expect(await adapter.scan(), isEmpty);
    // 顺便确认清单解析器本身的行为与 adapter 的拒绝理由一致
    expect(
      core.unsafeExtensionUrlReason(Uri.parse('http://127.0.0.1/x.zip')),
      isNull,
    );
  });

  // 用户 2026-10-19：「导入失败了那个包」。示例字幕包只有 manifest.json（`files: []`），
  // 这条把用户真走的那条路补上：真 zip → 真安装器 → 真扫盘 → 字幕预设成型。
  // 缺了这段，单测各自绿也可能在「装」这一层把通用包拒掉。
  test('通用预设包（files 为空）→ 真装 → 扫盘 → 字幕预设可用', () async {
    final Directory tmp = Directory.systemTemp.createTempSync('dsanima-ext-e2e-generic-');
    addTearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });
    final Directory support = Directory(p.join(tmp.path, 'data'))..createSync(recursive: true);

    // 与 `tool/build_extensions_catalog.py` 打出来的示例包同形。
    final Map<String, Object?> manifest = <String, Object?>{
      'schema': 1,
      'id': 'subtitle-demo',
      'name': '演示字幕',
      'version': '1.0.0',
      'kind': 'preset-pack',
      'description': '端到端测试用的字幕预设包',
      'license': 'MIT',
      'minAppVersion': '1.0.0',
      'files': <Object?>[],
      'payload': <String, Object?>{
        'surface': 'player.subtitle',
        'surfaceSchema': 1,
        'presets': <Object?>[
          <String, Object?>{
            'id': 'cinema',
            'name': '影院大字',
            'values': <String, Object?>{
              'scale': 1.6,
              'pos': 88,
              'borderSize': 3.2,
              'color': '#FFFFFFFF',
              'borderColor': '#FF000000',
              'bold': true,
            },
          },
          <String, Object?>{
            'id': 'yellow',
            'name': '黄字',
            'values': <String, Object?>{
              'scale': 1.2,
              'pos': 96,
              'color': '#FFFFD400',
            },
          },
        ],
      },
    };
    final List<int> manifestBytes = utf8.encode(jsonEncode(manifest));
    final Archive archive = Archive()
      ..addFile(ArchiveFile('manifest.json', manifestBytes.length, manifestBytes));
    final File zip = File(p.join(tmp.path, 'subtitle-demo.zip'))
      ..writeAsBytesSync(ZipEncoder().encode(archive));

    final ExtensionsAdapter adapter = ExtensionsAdapter(
      root: Directory(p.join(support.path, kExtensionsDirName)),
      clientFactory: () => _NoNetworkClient(),
      trash: (List<String> paths) async {},
      openDir: (String path) async {},
      freeBytes: (String path) async => 10 * 1024 * 1024 * 1024,
    );

    final InstalledExtension installed =
        await adapter.install(ExtensionInstallRequest(localPath: zip.path));
    expect(installed.id, 'subtitle-demo');
    expect(installed.enabled, isTrue);
    expect(installed.usable, isTrue, reason: 'preset-pack + 认识的面 = 能用');
    expect(
      File(p.join(support.path, kExtensionsDirName, 'subtitle-demo', 'manifest.json')).existsSync(),
      isTrue,
    );

    // 扫盘 → consumer 拿到两个预设（按包分组需要的 id / packName 也在）。
    final List<GenericPack> packs = await scanGenericPacks(support);
    expect(packs.map((GenericPack pack) => pack.id), <String>['subtitle-demo']);
    final List<SubtitlePreset> captured = <SubtitlePreset>[];
    final SubtitlePresetConsumer consumer =
        SubtitlePresetConsumer(onChanged: captured.addAll);
    await consumer.setPacks(packs);
    expect(consumer.presetCount, 2);
    expect(
      captured.map((SubtitlePreset preset) => preset.id),
      <String>['subtitle-demo/cinema', 'subtitle-demo/yellow'],
    );
    expect(captured.first.packId, 'subtitle-demo');
    expect(captured.first.packName, '演示字幕');
    expect(captured.first.style.scale, 1.6);
    expect(captured.first.style.color, '#FFFFFFFF');
  });
}
