/// 已安装的 shader 扩展 → 播放器的超分方案（1.1.0 M3/T17 的"联通"半步）。
///
/// 为什么单独一个文件：这是**跨模块翻译**——左边是扩展目录（`<数据根>/extensions/<id>/`
/// + `state.json`，宿主的格式），右边是 shikiin 的 [UpscaleScheme]（播放器只认这个）。
/// 翻译放在宿主、不放进 shikiin：shikiin 不该认识 `dsanima_core` 的清单格式，
/// 它的 `bootstrapPlayer(extraSchemes:)` 只收现成的方案对象。
///
/// 谁调用：
/// * 主窗口启动/设置页（列"有哪些可用方案"）；
/// * **播放子窗口**每次 `bootstrapPlayer` 之前（子窗口是独立引擎，有自己的扫描，
///   见 `main.dart` 的 `_runPlayerWindow`）——窗口**每次打开**都重新扫；
/// * **已经打开的播放窗口**：主窗口在扩展页装/卸/启停成功后经窗口通道发
///   `kMethodExtensionsChanged`，子窗口收到就调 [refreshExtensionSchemes] 重扫
///   （1.1.0 第六十四轮，用户实测"删了扩展菜单里还留着"之后补的）。所以没有"必须重启"
///   这一步；窗口没开时下次开窗扫描兜底。
///
/// 三条判据（宁可不显示，也不显示一个点不动的方案）：
/// 1. 必须 `enabled == true`（禁用 = 不参与运行时）；
/// 2. 必须是 `shader-pack` 且清单解析通过（类型/版本兼容）；
/// 3. shader 目录与清单里列的每个文件都必须**真的在盘上** —— 用户手删了文件时，
///    这里就跳过（播放器那边挂一条指向不存在文件的 `glsl-shaders` 只会静默不生效）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:dsanima_core/dsanima_core.dart' as core;
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:shikiin/shikiin.dart';

import '../domain/app_version.dart';

/// 扩展根目录名（`<数据根>/extensions`，与 `state/extensions_adapter.dart` 同一出处）。
const String kExtensionsDirName = 'extensions';

/// 扩展状态文件名。
const String kExtensionsStateFileName = 'state.json';

/// 扫一遍扩展目录，返回**可以立刻挂上去**的外部超分方案。
///
/// 永不抛异常：扩展扫不出来最多是"没有额外方案"，绝不能因此让播放窗口起不来
/// （问题写进 `debugPrint`，不吞掉原因）。
Future<List<UpscaleScheme>> loadExtensionUpscaleSchemes(Directory supportDir) async {
  try {
    return await _load(supportDir);
  } catch (error, stack) {
    debugPrint('[extensions] 扫描超分方案失败（只影响扩展方案，内置方案照常）：$error\n$stack');
    return const <UpscaleScheme>[];
  }
}

Future<List<UpscaleScheme>> _load(Directory supportDir) async {
  final Directory root = Directory(p.join(supportDir.path, kExtensionsDirName));
  if (!root.existsSync()) return const <UpscaleScheme>[];

  final Map<String, bool> enabled = await _readEnabledFlags(root);
  final List<UpscaleScheme> schemes = <UpscaleScheme>[];

  for (final FileSystemEntity entity in root.listSync(followLinks: false)) {
    if (entity is! Directory) continue;
    final String id = p.basename(entity.path);
    // `.staging` / `.trash` / `.downloads` 之类的内部目录永远不是扩展。
    if (id.startsWith('.')) continue;
    if (enabled[id] == false) continue;
    final UpscaleScheme? scheme = _schemeOf(Directory(entity.path), id);
    if (scheme != null) schemes.add(scheme);
  }

  schemes.sort((UpscaleScheme a, UpscaleScheme b) =>
      a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  return List<UpscaleScheme>.unmodifiable(schemes);
}

/// 读 `state.json` 里每个扩展的 `enabled`；读不出来就当"全启用"。
///
/// 为什么不因为 state.json 坏了就整体放弃：目录里的文件是真实的，用户手抄一份扩展进来
/// （或者 adapter 写盘被打断）时，能用的方案应当照常出现；启用状态只是**限制**，
/// 拿不到限制时按默认（启用）处理，符合"目录存在即安装"的直觉。
Future<Map<String, bool>> _readEnabledFlags(Directory root) async {
  final File stateFile = File(p.join(root.path, kExtensionsStateFileName));
  if (!stateFile.existsSync()) return <String, bool>{};
  try {
    final Object? json = jsonDecode(await stateFile.readAsString());
    if (json is! Map) return <String, bool>{};
    final Object? extensions = json['extensions'];
    if (extensions is! Map) return <String, bool>{};
    return <String, bool>{
      for (final MapEntry<Object?, Object?> entry in extensions.entries)
        if (entry.value is Map && (entry.value as Map)['enabled'] is bool)
          '${entry.key}': (entry.value as Map)['enabled'] as bool,
    };
  } catch (error) {
    debugPrint('[extensions] state.json 读不出来（按"全部启用"处理）：$error');
    return <String, bool>{};
  }
}

/// 单个扩展目录 → 方案；任何一条判据不过就返回 null（调用方只 debugPrint 原因）。
UpscaleScheme? _schemeOf(Directory dir, String id) {
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
  final core.ExtensionShaderSpec? shader = manifest.shader;
  if (!manifest.isUsable || shader == null) {
    debugPrint('[extensions] 跳过 $id：类型「${manifest.kind}」本版本不接运行时');
    return null;
  }

  final String shaderDir = shader.dir.isEmpty
      ? dir.path
      : p.join(dir.path, shader.dir);
  if (!Directory(shaderDir).existsSync()) {
    debugPrint('[extensions] 跳过 $id：shader 目录不存在（$shaderDir）');
    return null;
  }
  for (final String file in shader.files) {
    if (!File(p.join(shaderDir, file)).existsSync()) {
      debugPrint('[extensions] 跳过 $id：shader 文件缺失（$file）');
      return null;
    }
  }

  return UpscaleScheme(
    id: manifest.id,
    name: manifest.name,
    shortName: _shortNameOf(manifest),
    kind: UpscaleSchemeKind.glslPack,
    files: shader.files,
    dir: shaderDir,
    note: _noteOf(manifest),
  );
}

/// 一次「扩展变更 → 播放器方案清单」的热重载结果（给调用方记日志/写测试用）。
@immutable
class ExtensionSchemeRefresh {
  const ExtensionSchemeRefresh({
    required this.schemes,
    required this.selection,
    required this.selectionReset,
  });

  /// 重扫之后播放器现在拿到的完整清单（内置 + 扩展）。
  final List<UpscaleScheme> schemes;

  /// 重扫之后的选中项（正常情况下与重扫前一样）。
  final UpscaleSelection selection;

  /// true = 之前选的那套扩展**已经被卸载/禁用**，已回退到内置 Anime4K（档位沿用上次）。
  ///
  /// 为什么回退到"内置 Anime4K + 原档位"而不是直接关：这与**下次启动**的行为一致
  /// —— 设置里存的 schemeId 找不到时，`UpscaleSelection.fromSettings` 就是回退
  /// Anime4K 并保留 `anime4kPreset`。两处口径一样，用户不会遇到"热更新后是关、
  /// 重启后又变成标准"这种自相矛盾。
  final bool selectionReset;
}

/// 扩展目录变化后，把新的方案清单灌进**正在运行的播放器**（1.1.0 第六十四轮）。
///
/// 调用点：播放子窗口收到 [kMethodExtensionsChanged] 之后（主窗口在扩展页装/卸/启停
/// 成功时发）。做三件事，一件都不能少：
/// 1. 重扫扩展目录（[loadExtensionUpscaleSchemes]：只收 enabled + 文件真在盘上的）；
/// 2. 换掉控制器的清单（内置在前，扩展在后）；
/// 3. 如果用户**正选着**的那套扩展已经没了，立刻回退（否则播放器还挂着一条指向
///    不存在文件的 `glsl-shaders`，画面不变、菜单里却还写着它 —— 正是用户报的那个）。
Future<ExtensionSchemeRefresh> refreshExtensionSchemes({
  required Anime4kController controller,
  required Directory supportDir,
}) async {
  final List<UpscaleScheme> extra = await loadExtensionUpscaleSchemes(supportDir);
  final List<UpscaleScheme> merged = mergedUpscaleSchemes(extra: extra);
  final UpscaleSelection before = controller.selection;
  final bool gone = !before.isOff && !merged.any((UpscaleScheme s) => s.id == before.schemeId);
  final UpscaleSelection next =
      gone ? UpscaleSelection(preset: before.preset) : before;
  controller.setSchemes(merged);
  if (gone) {
    // `setSelection` 会立刻下发（清掉旧链 / 挂上新方案），并把状态推给播放面。
    await controller.setSelection(next);
  }
  return ExtensionSchemeRefresh(schemes: merged, selection: next, selectionReset: gone);
}

/// 控制栏胶囊里的短名：名字够短就用名字，否则截断（胶囊只有一行的宽度）。
String _shortNameOf(core.ExtensionManifest manifest) {
  final String name = manifest.name.trim();
  if (name.isEmpty) return manifest.id;
  if (name.length <= 8) return name;
  return '${name.substring(0, 7)}…';
}

/// 菜单里的小字：说清它从哪来、什么版本、什么许可（LGPL 包要能一眼看到）。
String _noteOf(core.ExtensionManifest manifest) {
  final StringBuffer note = StringBuffer('扩展 · v${manifest.version}');
  final String? license = manifest.license?.trim();
  if (license != null && license.isNotEmpty) note.write(' · $license');
  return note.toString();
}
