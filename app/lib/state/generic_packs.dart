/// 通用扩展包（`preset-pack` / `list-pack`）的**共享扫描器**。
///
/// 为什么单独一个文件：`extension_schemes.dart`（超分）与 `picture_pack.dart`（画面调节）
/// 各自抄了一份「扫目录 → 读 enabled → 解析清单 → 筛 kind → 查文件在盘」，
/// 每加一个数据面再抄一遍。通用包从这一层开始**共用扫描**，各面只实现自己的 consumer。
///
/// 三条判据与现有两处扫描一致（宁可不显示，也不显示一个点不动的包）：
/// 1. `state.json` 里 `enabled == false` 的不算；
/// 2. 清单必须解析通过、目录名必须等于 `manifest.id`、必须带通用载荷；
/// 3. 清单声明的每个文件都必须**真的在盘上**。
/// 未知 surface 照常返回（`surface == null`）：扩展页要把「本版本不接这个面」说清楚，
/// 而不是让用户以为包坏了。
library;

import 'dart:convert';
import 'dart:io';

import 'package:dsanima_core/dsanima_core.dart' as core;
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../domain/app_version.dart';
import 'extension_schemes.dart' show kExtensionsDirName, readExtensionsEnabledFlags;

/// 一份「扫出来、现在就能交给某个面消费」的通用包。
class GenericPack {
  const GenericPack({
    required this.manifest,
    required this.payload,
    required this.dir,
    required this.surface,
  });

  final core.ExtensionManifest manifest;
  final core.GenericPayload payload;
  final Directory dir;

  /// core 认识的面对应；null = 本版本不接这个面。
  final core.ExtensionSurface? surface;

  String get id => manifest.id;
  String get name => manifest.name;
}

/// 扫一遍扩展目录，返回全部通用包（按名字排序；永不抛）。
Future<List<GenericPack>> scanGenericPacks(Directory supportDir) async {
  try {
    return await _scan(supportDir);
  } catch (error, stack) {
    debugPrint('[extensions] 扫描通用包失败（只影响通用面，其它照常）：$error\n$stack');
    return const <GenericPack>[];
  }
}

Future<List<GenericPack>> _scan(Directory supportDir) async {
  final Directory root = Directory(p.join(supportDir.path, kExtensionsDirName));
  if (!root.existsSync()) return const <GenericPack>[];
  final Map<String, bool> enabled = await readExtensionsEnabledFlags(root);
  final List<Directory> dirs = <Directory>[
    for (final FileSystemEntity entity in root.listSync(followLinks: false))
      if (entity is Directory && !p.basename(entity.path).startsWith('.')) entity,
  ]..sort((Directory a, Directory b) => a.path.compareTo(b.path));

  final List<GenericPack> packs = <GenericPack>[];
  for (final Directory dir in dirs) {
    final String id = p.basename(dir.path);
    if (enabled[id] == false) continue;
    final GenericPack? pack = _packOf(dir, id);
    if (pack != null) packs.add(pack);
  }
  packs.sort((GenericPack a, GenericPack b) =>
      a.manifest.name.toLowerCase().compareTo(b.manifest.name.toLowerCase()));
  return List<GenericPack>.unmodifiable(packs);
}

GenericPack? _packOf(Directory dir, String id) {
  final File manifestFile = File(p.join(dir.path, 'manifest.json'));
  if (!manifestFile.existsSync()) {
    debugPrint('[extensions] 跳过 $id：目录里没有 manifest.json');
    return null;
  }
  final Object? json;
  try {
    json = jsonDecode(manifestFile.readAsStringSync());
  } catch (error) {
    debugPrint('[extensions] 跳过 $id：manifest.json 不是合法 JSON（$error）');
    return null;
  }
  final core.ManifestParseResult parsed =
      core.parseExtensionManifest(json, currentAppVersion: kAppVersion.toString());
  if (!parsed.ok) {
    debugPrint('[extensions] 跳过 $id：清单不合法（${parsed.issues.join('；')}）');
    return null;
  }
  final core.ExtensionManifest manifest = parsed.manifest!;
  if (manifest.id != id) {
    debugPrint('[extensions] 跳过 $id：目录名与清单 id「${manifest.id}」不一致');
    return null;
  }
  final core.GenericPayload? payload = manifest.generic;
  if (payload == null) {
    // 非通用 kind（shader/picture/data…）由各自的扫描管，这里不重复收集。
    return null;
  }
  for (final core.ExtensionFile file in manifest.files) {
    if (!File(p.join(dir.path, file.path)).existsSync()) {
      debugPrint('[extensions] 跳过 $id：声明的文件缺失（${file.path}）');
      return null;
    }
  }
  return GenericPack(
    manifest: manifest,
    payload: payload,
    dir: dir,
    surface: core.extensionSurfaceOf(payload.surface),
  );
}

/// 按 `payload.surface` 分组（组内按名字排序）；消费方只拿自己那一组。
Map<String, List<GenericPack>> groupGenericPacksBySurface(List<GenericPack> packs) {
  final Map<String, List<GenericPack>> grouped = <String, List<GenericPack>>{};
  for (final GenericPack pack in packs) {
    (grouped[pack.payload.surface] ??= <GenericPack>[]).add(pack);
  }
  for (final String surface in grouped.keys.toList(growable: false)) {
    final List<GenericPack> list = grouped[surface]!;
    list.sort((GenericPack a, GenericPack b) =>
        a.manifest.name.toLowerCase().compareTo(b.manifest.name.toLowerCase()));
    grouped[surface] = List<GenericPack>.unmodifiable(list);
  }
  return Map<String, List<GenericPack>>.unmodifiable(grouped);
}
