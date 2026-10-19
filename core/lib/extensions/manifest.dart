/// 扩展清单（`manifest.json`）与目录（`catalog.json`）的解析 —— **纯逻辑，不碰磁盘**。
///
/// 为什么在 `dsanima_core` 而不是宿主 UI 里：和 `update/` 同一个理由 ——
/// 「这份 json 能不能装」全是判据，一份代码、`core/test` 里离线钉死。
/// 宿主只负责把结论翻成界面状态（`app/lib/state/extensions.dart`），
/// 真正的下载/解压/原子替换在 `app/lib/state/extensions_adapter.dart`。
///
/// ## 契约（改格式必须同时改 `docs/specs/2026-10-17-dsanima-extension-format.md`）
///
/// `manifest.json`（**必须在 zip 根目录**，大小写敏感）：
/// ```json
/// {
///   "schema": 1,
///   "id": "anime4k-modeb",
///   "name": "Anime4K Mode B（保守）",
///   "version": "1.0.0",
///   "kind": "shader-pack",
///   "description": "…",
///   "author": "…",
///   "license": "MIT",
///   "homepage": "https://…",
///   "minAppVersion": "1.1.0",
///   "files": [
///     {"path": "shaders/Anime4K_Clamp_Highlights.glsl", "size": 2107, "sha256": "…"}
///   ],
///   "payload": {
///     "shader": {"dir": "shaders", "files": ["Anime4K_Clamp_Highlights.glsl"], "pipeline": "glsl-shaders"}
///   }
/// }
/// ```
///
/// `catalog.json`（在线目录，可选；直链 zip 不需要它）：
/// ```json
/// {"schema": 1, "extensions": [{"url": "cunny-1.0.0.zip", "size": 123, "sha256": "…", "manifest": {…}}]}
/// ```
/// `url` 可以是**相对 catalog.json 的绝对/相对地址**，解析时按 base 补全。
///
/// ## 三条"不撒谎"的判据
/// * **看不懂就说看不懂**：任何字段不合法都进 [ManifestParseResult.issues]，不去猜；
/// * **不认识 ≠ 非法**：[ExtensionManifest.kind] 允许未来新类型（装得上、宿主说"暂不支持"），
///   但 `shader-pack` 必须带完整的 shader 描述，否则它装上也用不了 —— 直接拒；
/// * **装之前先把话说清**：本应用版本低于 `minAppVersion` 时**拒绝安装**，
///   因为老宿主可能不认识新字段，装进去只会静默不生效。
library;

import '../update/version.dart';
import 'generic.dart';
import 'issues.dart';
import 'package_guard.dart';
import 'picture.dart';
import 'url_safety.dart';

export 'issues.dart';
export 'url_safety.dart';

/// 已知扩展类型 → 界面上的中文名。
///
/// 只列**本版本有行为**的类型：`shader-pack` 会出现在超分方案里；
/// `data-pack` 只做安装/管理（1.1.0 不接运行时，UI 必须如实说）。
/// 未来加类型只在 [labels] 里加一项，解析逻辑不用改（未知类型按"不支持"处理）。
class ExtensionKind {
  const ExtensionKind._();

  /// 一组 GLSL 文件，按 `glsl-shaders` 顺序挂载（实时超分方案）。
  static const String shaderPack = 'shader-pack';

  /// 纯数据包：文件会被校验并落在扩展目录里，但本版本不接运行时。
  static const String dataPack = 'data-pack';

  /// 「画面调节」包：一份带 `@key@` 占位符的模板 + 参数声明 + 预设，
  /// 宿主按用户取值现场渲染成 .glsl 再挂载（见 `picture.dart`）。
  static const String picturePack = kPicturePackKind;

  /// 通用「预设包」：命名预设喂给某个面（见 `generic.dart` 的 surface 白名单）。
  static const String presetPack = kPresetPackKind;

  /// 通用「列表包」：数据列表喂给某个面（见 `generic.dart` 的 surface 白名单）。
  static const String listPack = kListPackKind;

  static const Map<String, String> labels = <String, String>{
    shaderPack: '着色器包',
    dataPack: '数据包',
    picturePack: '画面调节包',
    presetPack: '预设包',
    listPack: '列表包',
  };

  static bool isKnown(String kind) => labels.containsKey(kind);

  static String labelOf(String kind) => labels[kind] ?? '未知类型（$kind）';
}

/// 宿主认识的唯一 shader 管线。另一条渲染管线（`vo=gpu-next` 的 compute）**不在**
/// 1.1.0 的通路里 —— 清单里写别的值直接在解析阶段拒掉，避免"装上了但一播就黑屏"。
const String kGlslShadersPipeline = 'glsl-shaders';

/// 扩展 id 白名单：小写字母/数字开头，之后允许 `.`/`_`/`-`，总长 2~64。
///
/// 它同时是 `extensions/<id>/` 的目录名，所以不能有路径分隔符、不能是 `.`/`..`、
/// 不能是 Windows 保留名（这些由 [unsafeRelativePathReason] 的同一套规则兜底）。
final RegExp _kExtensionIdPattern = RegExp(r'^[a-z0-9][a-z0-9._-]{1,63}$');

/// **不能当扩展 id** 的名字：与内置超分方案 id 撞车（装上会被内置的顶掉，
/// 用户看到"装了但列表里还是内置那个"——比装不上更让人困惑）。
const Set<String> kReservedExtensionIds = <String>{
  'anime4k',
  'anime4k-ultra',
};

/// 扩展里的一个文件：路径（相对扩展根）+ 字节数 + sha256。
///
/// 三者缺一不可：`size` 让"解压到一半"能被发现，`sha256` 让"内容被换过"能被发现。
class ExtensionFile {
  const ExtensionFile({required this.path, required this.size, required this.sha256});

  /// 相对扩展根的正斜杠路径（如 `shaders/a.glsl`）。
  final String path;

  /// 解压后的字节数（zip 头里的 uncompressed size 必须等于它）。
  final int size;

  /// 小写十六进制 sha256（64 字符）。
  final String sha256;

  Map<String, Object?> toJson() => <String, Object?>{
        'path': path,
        'size': size,
        'sha256': sha256,
      };
}

/// `payload.shader`：一组按顺序挂载的 GLSL。
class ExtensionShaderSpec {
  const ExtensionShaderSpec({
    required this.files,
    this.dir = '',
    this.pipeline = kGlslShadersPipeline,
  });

  /// 扩展根下放 shader 的目录（空串 = 扩展根）。
  final String dir;

  /// [dir] 下的文件名，**按挂载顺序**（mpv 的 `glsl-shaders` 是有序链）。
  final List<String> files;

  /// 管线类型；本版本只认 [kGlslShadersPipeline]。
  final String pipeline;

  /// 换算成"相对扩展根"的路径（与 [ExtensionManifest.files] 的 `path` 同口径）。
  List<String> get rootRelativePaths => <String>[
        for (final String file in files) dir.isEmpty ? file : '$dir/$file',
      ];

  Map<String, Object?> toJson() => <String, Object?>{
        'dir': dir,
        'files': files,
        'pipeline': pipeline,
      };
}

/// 解析通过的扩展清单。
class ExtensionManifest {
  const ExtensionManifest({
    required this.schema,
    required this.id,
    required this.name,
    required this.version,
    required this.kind,
    required this.files,
    required this.raw,
    this.description = '',
    this.author,
    this.license,
    this.homepage,
    this.minAppVersion,
    this.shader,
    this.picture,
    this.generic,
  });

  /// 清单格式版本；本版本只认 1。
  final int schema;

  /// 扩展 id（= 目录名 = 超分方案 id）。
  final String id;

  /// 界面上的名字。
  final String name;

  /// 扩展自己的版本号（`1.0.0`）。
  final String version;

  /// 类型（见 [ExtensionKind]）。可能是**未来**的类型。
  final String kind;

  /// 一句话说明（界面列表里显示）。
  final String description;

  final String? author;
  final String? license;
  final String? homepage;

  /// 运行所需的最低宿主版本；null = 不限制。
  final String? minAppVersion;

  /// 要落盘的全部文件（含 shader；**不含** `manifest.json` 自己）。
  final List<ExtensionFile> files;

  /// `shader-pack` 必需的 shader 描述；其他类型为 null。
  final ExtensionShaderSpec? shader;

  /// `picture-pack` 必需的画面调节描述（模板 + 参数 + 预设）；其他类型为 null。
  final PictureSpec? picture;

  /// `preset-pack` / `list-pack` 解析出的通用载荷；其他类型为 null。
  final GenericPayload? generic;

  /// 原始 json（**原样**存进 `state.json`，宿主新增字段时不用改这套模型，
  /// 也不存在 `toJson` 漂移）。
  final Map<String, Object?> raw;

  /// 宿主是否认识这个类型（不认识也能装，只是没有运行时行为）。
  bool get isKnownKind => ExtensionKind.isKnown(kind);

  /// 装上之后能不能真的用起来：`shader-pack` 要看 shader 描述，
  /// `picture-pack` 要看画面调节描述，通用包要看宿主认不认识它声明的面；
  /// 其余类型装上也没有运行时行为。
  bool get isUsable {
    if (kind == ExtensionKind.shaderPack) return shader != null;
    if (kind == ExtensionKind.picturePack) return picture != null;
    if (kind == ExtensionKind.presetPack || kind == ExtensionKind.listPack) {
      final GenericPayload? payload = generic;
      return payload != null && extensionSurfaceOf(payload.surface) != null;
    }
    return false;
  }

  /// `path → ExtensionFile`（大小写不敏感：Windows 文件系统不区分）。
  Map<String, ExtensionFile> get filesByPath => <String, ExtensionFile>{
        for (final ExtensionFile file in files) file.path.toLowerCase(): file,
      };

  /// 重算后的原始 json（写 `state.json` 用）。
  Map<String, Object?> toJson() => raw;
}

// （`ManifestIssue` 定义在 `issues.dart`；本文件顶部 `export 'issues.dart';` 保持旧导入可用。）

/// 一次清单解析的结果。[ok] 为 true 才能装。
class ManifestParseResult {
  const ManifestParseResult({
    this.manifest,
    this.issues = const <ManifestIssue>[],
    this.warnings = const <ManifestIssue>[],
  });

  final ExtensionManifest? manifest;

  /// 致命问题：有任何一条都不许装。
  final List<ManifestIssue> issues;

  /// 提醒：能装，但界面/日志要说明。
  final List<ManifestIssue> warnings;

  bool get ok => manifest != null && issues.isEmpty;
}

/// 目录（`catalog.json`）里的一条：清单 + 从哪儿下。
class CatalogEntry {
  const CatalogEntry({
    required this.manifest,
    required this.url,
    this.size,
    this.sha256,
  });

  final ExtensionManifest manifest;

  /// 下载地址（已按 catalog.json 的地址补全为绝对地址）。
  final Uri url;

  /// 期望的 zip 字节数（null = 不校验长度，只校验 sha256）。
  final int? size;

  /// 期望的 zip sha256（null = 不校验哈希 —— 界面要如实标出来）。
  final String? sha256;
}

/// 一次目录解析的结果。
class CatalogParseResult {
  const CatalogParseResult({
    this.entries = const <CatalogEntry>[],
    this.issues = const <ManifestIssue>[],
    this.warnings = const <ManifestIssue>[],
  });

  /// 能用的条目（解析失败的条目不进来，问题在 [issues] 里逐条说明）。
  final List<CatalogEntry> entries;

  /// 致命问题：坏条目 / 整个目录看不懂。
  final List<ManifestIssue> issues;

  final List<ManifestIssue> warnings;

  bool get ok => issues.isEmpty;
}

// （`unsafeExtensionUrlReason` 定义在 `url_safety.dart`；本文件顶部 `export` 保持旧导入可用。）

/// 解析一份 `manifest.json`。
///
/// [currentAppVersion] 传宿主当前版本（如 `1.0.3`）；传 null 则跳过兼容性检查
/// （打包工具自己校验时用）。
ManifestParseResult parseExtensionManifest(
  Object? json, {
  String? currentAppVersion,
}) {
  final List<ManifestIssue> issues = <ManifestIssue>[];
  final List<ManifestIssue> warnings = <ManifestIssue>[];

  if (json is! Map) {
    return const ManifestParseResult(
      issues: <ManifestIssue>[
        ManifestIssue('manifest', '清单不是一个 JSON 对象（顶层必须是 {…}）'),
      ],
    );
  }
  final Map<String, Object?> map = <String, Object?>{
    for (final MapEntry<Object?, Object?> e in json.entries) '${e.key}': e.value,
  };

  // ── schema ──────────────────────────────────────────────────────────────
  int schema = 1;
  final Object? rawSchema = map['schema'];
  if (rawSchema != null) {
    // 只认**值正好是 1** 的数字（1 与 1.0 都行）。`1.5` 不许被 `toInt()` 抹成 1 ——
    // 那等于"看不懂的格式版本当能看懂"，将来加字段时老宿主会静默按新语义装。
    if (rawSchema is num && rawSchema == 1) {
      schema = 1;
    } else {
      issues.add(ManifestIssue(
        'schema',
        '清单格式版本「$rawSchema」不认识（本版本只认 1），请更新 DSAnima 或换一份扩展',
      ));
    }
  }

  // ── id / name / version / kind ──────────────────────────────────────────
  final String id = _readString(map['id'])?.trim() ?? '';
  if (id.isEmpty) {
    issues.add(const ManifestIssue('id', '缺少扩展 id（小写字母/数字/.-_，2~64 字符）'));
  } else if (!_kExtensionIdPattern.hasMatch(id)) {
    issues.add(ManifestIssue(
      'id',
      'id「$id」不合规：只能用小写字母/数字和 . _ -，必须以字母或数字开头，2~64 字符',
    ));
  } else if (kReservedExtensionIds.contains(id)) {
    issues.add(ManifestIssue('id', 'id「$id」与内置超分方案重名，请换一个'));
  } else {
    // id 同时是 `extensions/<id>/` 的目录名，所以必须过**同一套** Windows 路径判据：
    // 保留设备名（nul/con）、尾点/尾空格这些在大小写不敏感的 NTFS 上会变成另一个目录名，
    // 让"清单里的 id"和"落盘的目录名"对不上（下一轮读不回来）。
    final String? unsafeId = unsafeRelativePathReason(id);
    if (unsafeId != null) {
      issues.add(ManifestIssue('id', 'id「$id」不能当目录名：$unsafeId'));
    }
  }

  final String name = _readString(map['name'])?.trim() ?? '';
  if (name.isEmpty) {
    issues.add(const ManifestIssue('name', '缺少 name（界面上显示的名字）'));
  } else if (name.length > 80) {
    issues.add(const ManifestIssue('name', 'name 太长（不超过 80 字符，界面放不下）'));
  }

  final String version = _readString(map['version'])?.trim() ?? '';
  if (version.isEmpty) {
    issues.add(const ManifestIssue('version', '缺少 version（如 1.0.0）'));
  } else if (AppVersion.tryParse(version) == null) {
    issues.add(ManifestIssue('version', 'version「$version」不是版本号（要像 1.0.0）'));
  }

  final String kind = _readString(map['kind'])?.trim() ?? '';
  if (kind.isEmpty) {
    issues.add(const ManifestIssue('kind', '缺少 kind（shader-pack / data-pack）'));
  } else if (!RegExp(r'^[a-z][a-z0-9-]{1,31}$').hasMatch(kind)) {
    issues.add(ManifestIssue('kind', 'kind「$kind」不是合法类型名（小写字母开头的短横线命名）'));
  } else if (!ExtensionKind.isKnown(kind)) {
    warnings.add(ManifestIssue(
      'kind',
      '类型「$kind」本版本不认识：可以安装和管理，但不会有运行时效果',
    ));
  }

  // ── 兼容性 ──────────────────────────────────────────────────────────────
  final String? minAppVersion = _readString(map['minAppVersion'])?.trim();
  if (minAppVersion != null && minAppVersion.isNotEmpty) {
    final AppVersion? required = AppVersion.tryParse(minAppVersion);
    if (required == null) {
      issues.add(ManifestIssue(
        'minAppVersion',
        'minAppVersion「$minAppVersion」不是版本号（要像 1.1.0）',
      ));
    } else if (currentAppVersion != null) {
      final AppVersion? current = AppVersion.tryParse(currentAppVersion);
      if (current != null && current.compareTo(required) < 0) {
        issues.add(ManifestIssue(
          'minAppVersion',
          '这个扩展需要 DSAnima $minAppVersion 或更高（当前 $currentAppVersion），装上也用不了',
        ));
      }
    }
  }

  // 通用包必须写 minAppVersion：老宿主不认识这两个 kind，装上也只会"没有运行时效果"。
  if ((kind == ExtensionKind.presetPack || kind == ExtensionKind.listPack) &&
      (minAppVersion == null || minAppVersion.isEmpty)) {
    issues.add(const ManifestIssue(
      'minAppVersion',
      '通用包必须写 minAppVersion（如 1.1.0）：老宿主不认识这种类型，装上也用不了',
    ));
  }

  // ── files ───────────────────────────────────────────────────────────────
  final List<ExtensionFile> files = <ExtensionFile>[];
  final Set<String> seenPaths = <String>{};
  final Object? rawFiles = map['files'];
  if (rawFiles is! List) {
    issues.add(const ManifestIssue('files', '缺少 files 列表（每个要落盘的文件 + 大小 + sha256）'));
  } else if (rawFiles.isEmpty &&
      kind != ExtensionKind.presetPack &&
      kind != ExtensionKind.listPack) {
    issues.add(const ManifestIssue('files', 'files 是空的：扩展至少要有一个文件'));
  } else if (rawFiles.length > kPackageMaxEntries) {
    issues.add(ManifestIssue('files', '文件太多（上限 $kPackageMaxEntries 个）'));
  } else {
    for (int i = 0; i < rawFiles.length; i++) {
      final Object? item = rawFiles[i];
      final String field = 'files[$i]';
      if (item is! Map) {
        issues.add(ManifestIssue(field, '不是对象（要有 path/size/sha256）'));
        continue;
      }
      final Map<String, Object?> file = <String, Object?>{
        for (final MapEntry<Object?, Object?> e in item.entries) '${e.key}': e.value,
      };
      final String path = _readString(file['path'])?.trim() ?? '';
      if (path.isEmpty) {
        issues.add(ManifestIssue('$field.path', '缺少 path'));
        continue;
      }
      final String? unsafe = unsafeRelativePathReason(path);
      if (unsafe != null) {
        issues.add(ManifestIssue('$field.path', '路径「$path」不可用：$unsafe'));
        continue;
      }
      final String lower = path.toLowerCase();
      if (lower == 'manifest.json') {
        issues.add(ManifestIssue('$field.path', 'files 里不要再列 manifest.json（它由 zip 自带）'));
        continue;
      }
      if (!seenPaths.add(lower)) {
        issues.add(ManifestIssue('$field.path', '路径「$path」重复（Windows 不区分大小写）'));
        continue;
      }
      final Object? rawSize = file['size'];
      if (rawSize is! num || rawSize < 0 || rawSize != rawSize.toInt()) {
        issues.add(ManifestIssue('$field.size', 'size 要写非负整数（解压后的字节数）'));
        continue;
      }
      final int size = rawSize.toInt();
      if (size > kPackageMaxEntryBytes) {
        issues.add(ManifestIssue(
          '$field.size',
          '单个文件 $size 字节，超过上限 $kPackageMaxEntryBytes',
        ));
        continue;
      }
      final String sha = (_readString(file['sha256']) ?? '').trim().toLowerCase();
      if (!_kSha256Pattern.hasMatch(sha)) {
        issues.add(ManifestIssue('$field.sha256', 'sha256 要写 64 位十六进制'));
        continue;
      }
      files.add(ExtensionFile(path: path, size: size, sha256: sha));
    }
  }

  // ── payload.shader ──────────────────────────────────────────────────────
  ExtensionShaderSpec? shader;
  final Object? rawPayload = map['payload'];
  Map<String, Object?>? payloadMap;
  if (rawPayload != null) {
    if (rawPayload is Map) {
      payloadMap = <String, Object?>{
        for (final MapEntry<Object?, Object?> e in rawPayload.entries) '${e.key}': e.value,
      };
    } else {
      issues.add(const ManifestIssue('payload', 'payload 必须是对象'));
    }
  }
  final Object? rawShader = payloadMap?['shader'];
  final bool shaderApplies = kind.isEmpty || kind == ExtensionKind.shaderPack;
  if (rawShader != null && shaderApplies) {
    shader = _parseShaderSpec(rawShader, files: files, issues: issues, warnings: warnings);
  } else if (rawShader != null && !shaderApplies) {
    warnings.add(ManifestIssue(
      'payload.shader',
      '类型「$kind」不使用 payload.shader，已忽略（着色器只在 shader-pack 里生效）',
    ));
  } else if (kind == ExtensionKind.shaderPack) {
    issues.add(const ManifestIssue(
      'payload.shader',
      'shader-pack 必须带 payload.shader（dir + 按顺序的 files）',
    ));
  }

  // ── payload.picture ─────────────────────────────────────────────────────
  PictureSpec? picture;
  final Object? rawPicture = payloadMap?['picture'];
  final bool pictureApplies = kind.isEmpty || kind == ExtensionKind.picturePack;
  if (rawPicture != null && pictureApplies) {
    picture = parsePictureSpec(
      rawPicture,
      files: files,
      issues: issues,
      warnings: warnings,
    );
  } else if (rawPicture != null && !pictureApplies) {
    warnings.add(ManifestIssue(
      'payload.picture',
      '类型「$kind」不使用 payload.picture，已忽略（画面调节只在 picture-pack 里生效）',
    ));
  } else if (kind == ExtensionKind.picturePack) {
    issues.add(const ManifestIssue(
      'payload.picture',
      'picture-pack 必须带 payload.picture（template + params/presets）',
    ));
  }

  // ── payload.preset / payload.list（通用包）───────────────────────────────
  GenericPayload? generic;
  final bool genericKind = kind == ExtensionKind.presetPack || kind == ExtensionKind.listPack;
  if (genericKind) {
    if (rawPayload == null) {
      issues.add(const ManifestIssue(
        'payload',
        '通用包必须带 payload（surface + surfaceSchema + presets/lists）',
      ));
    } else if (payloadMap != null) {
      final GenericPayloadParseResult parsed = parseGenericPayload(
        kind,
        rawPayload,
        declaredPathsLower: <String>{
          for (final ExtensionFile file in files) file.path.toLowerCase(),
        },
      );
      generic = parsed.payload;
      issues.addAll(parsed.issues);
      warnings.addAll(parsed.warnings);
    }
  } else {
    for (final String key in <String>['surface', 'presets', 'lists']) {
      if (payloadMap?.containsKey(key) ?? false) {
        warnings.add(ManifestIssue(
          'payload.$key',
          '类型「$kind」不使用通用载荷（$key 已忽略；通用载荷只在 '
              '$kPresetPackKind / $kListPackKind 里生效）',
        ));
      }
    }
  }

  // ── 可选元信息 ───────────────────────────────────────────────────────────
  final String? homepage = _readString(map['homepage'])?.trim();
  if (homepage != null && homepage.isNotEmpty) {
    final Uri? uri = Uri.tryParse(homepage);
    if (uri == null || !uri.hasScheme) {
      warnings.add(ManifestIssue('homepage', 'homepage「$homepage」不是网址，界面只当文本显示'));
    }
  }

  if (issues.isNotEmpty) {
    return ManifestParseResult(issues: issues, warnings: warnings);
  }

  return ManifestParseResult(
    manifest: ExtensionManifest(
      schema: schema,
      id: id,
      name: name,
      version: version,
      kind: kind,
      description: _readString(map['description'])?.trim() ?? '',
      author: _readString(map['author'])?.trim(),
      license: _readString(map['license'])?.trim(),
      homepage: homepage,
      minAppVersion: (minAppVersion == null || minAppVersion.isEmpty) ? null : minAppVersion,
      files: List<ExtensionFile>.unmodifiable(files),
      shader: shader,
      picture: picture,
      generic: generic,
      raw: map,
    ),
    warnings: warnings,
  );
}

/// 解析一份 `catalog.json`。
///
/// 单条坏条目**不影响**其他条目：问题进 [CatalogParseResult.issues]，好条目照常可用。
CatalogParseResult parseExtensionCatalog(
  Object? json, {
  required Uri baseUrl,
  String? currentAppVersion,
}) {
  final List<CatalogEntry> entries = <CatalogEntry>[];
  final List<ManifestIssue> issues = <ManifestIssue>[];
  final List<ManifestIssue> warnings = <ManifestIssue>[];

  if (json is! Map) {
    return const CatalogParseResult(
      issues: <ManifestIssue>[
        ManifestIssue('catalog', '目录不是一个 JSON 对象（顶层必须是 {…}）'),
      ],
    );
  }
  final Map<String, Object?> map = <String, Object?>{
    for (final MapEntry<Object?, Object?> e in json.entries) '${e.key}': e.value,
  };
  final Object? rawSchema = map['schema'];
  if (rawSchema != null && rawSchema is! num) {
    issues.add(const ManifestIssue('schema', 'schema 要写数字（本版本是 1）'));
  } else if (rawSchema is num && rawSchema.toInt() != 1) {
    issues.add(ManifestIssue('schema', '目录格式版本「$rawSchema」不认识（本版本只认 1）'));
  }

  final Object? rawList = map['extensions'];
  if (rawList is! List) {
    issues.add(const ManifestIssue('extensions', '缺少 extensions 列表'));
    return CatalogParseResult(issues: issues, warnings: warnings);
  }
  for (int i = 0; i < rawList.length; i++) {
    final Object? item = rawList[i];
    final String field = 'extensions[$i]';
    if (item is! Map) {
      issues.add(ManifestIssue(field, '不是对象'));
      continue;
    }
    final Map<String, Object?> entry = <String, Object?>{
      for (final MapEntry<Object?, Object?> e in item.entries) '${e.key}': e.value,
    };
    final ManifestParseResult parsed =
        parseExtensionManifest(entry['manifest'], currentAppVersion: currentAppVersion);
    warnings.addAll(<ManifestIssue>[
      for (final ManifestIssue w in parsed.warnings) ManifestIssue('$field.${w.field}', w.message),
    ]);
    if (!parsed.ok) {
      for (final ManifestIssue issue in parsed.issues) {
        issues.add(ManifestIssue('$field.${issue.field}', issue.message));
      }
      continue;
    }
    final String rawUrl = _readString(entry['url'])?.trim() ?? '';
    if (rawUrl.isEmpty) {
      issues.add(ManifestIssue('$field.url', '缺少下载地址'));
      continue;
    }
    final Uri? resolved = Uri.tryParse(rawUrl);
    final Uri? url = resolved == null ? null : baseUrl.resolveUri(resolved);
    final String? unsafe = unsafeExtensionUrlReason(url);
    if (unsafe != null) {
      issues.add(ManifestIssue('$field.url', '下载地址「$rawUrl」不可用：$unsafe'));
      continue;
    }
    final Object? rawSize = entry['size'];
    int? size;
    if (rawSize != null) {
      if (rawSize is num && rawSize >= 0 && rawSize == rawSize.toInt()) {
        size = rawSize.toInt();
      } else {
        warnings.add(ManifestIssue('$field.size', 'size 不是非负整数，忽略'));
      }
    }
    final String sha = (_readString(entry['sha256']) ?? '').trim().toLowerCase();
    final String? sha256 = _kSha256Pattern.hasMatch(sha) ? sha : null;
    if (sha.isNotEmpty && sha256 == null) {
      warnings.add(ManifestIssue('$field.sha256', 'sha256 不是 64 位十六进制，忽略（只按大小校验）'));
    }
    entries.add(CatalogEntry(manifest: parsed.manifest!, url: url!, size: size, sha256: sha256));
  }
  return CatalogParseResult(entries: entries, issues: issues, warnings: warnings);
}

// ── 内部 ────────────────────────────────────────────────────────────────────

/// 64 位十六进制（sha256）。
final RegExp _kSha256Pattern = RegExp(r'^[0-9a-f]{64}$');

String? _readString(Object? value) {
  if (value is String) return value;
  if (value is num || value is bool) return '$value';
  return null;
}

/// 一个扩展包里**必须且只允许**出现的文件条目（相对包根）。
///
/// = `manifest.json` + 清单里声明的所有 files。[checkExtensionPackage] 用它判断
/// "夹带"（多一个）与"缺文件"（少一个）。
Set<String> expectedPackageFiles(ExtensionManifest manifest) => <String>{
      'manifest.json',
      for (final ExtensionFile file in manifest.files) file.path,
    };

ExtensionShaderSpec? _parseShaderSpec(
  Object? raw,
  {required List<ExtensionFile> files,
   required List<ManifestIssue> issues,
   required List<ManifestIssue> warnings}) {
  if (raw is! Map) {
    issues.add(const ManifestIssue('payload.shader', 'payload.shader 必须是对象'));
    return null;
  }
  final Map<String, Object?> map = <String, Object?>{
    for (final MapEntry<Object?, Object?> e in raw.entries) '${e.key}': e.value,
  };
  final String dir = _readString(map['dir'])?.trim() ?? '';
  if (dir.isNotEmpty) {
    final String? unsafe = unsafeRelativePathReason(dir);
    if (unsafe != null) {
      issues.add(ManifestIssue('payload.shader.dir', '目录「$dir」不可用：$unsafe'));
      return null;
    }
  }
  final Object? rawFiles = map['files'];
  if (rawFiles is! List || rawFiles.isEmpty) {
    issues.add(const ManifestIssue(
      'payload.shader.files',
      'shader 文件列表为空（按挂载顺序列文件名）',
    ));
    return null;
  }
  final List<String> names = <String>[];
  final Set<String> lowered = <String>{};
  for (int i = 0; i < rawFiles.length; i++) {
    final String name = _readString(rawFiles[i])?.trim() ?? '';
    final String field = 'payload.shader.files[$i]';
    if (name.isEmpty) {
      issues.add(ManifestIssue(field, '文件名是空的'));
      continue;
    }
    if (name.contains('/') || name.contains(r'\')) {
      issues.add(ManifestIssue(field, '这里只写「$dir 下的文件名」，不要带目录：$name'));
      continue;
    }
    if (unsafeRelativePathReason(name) != null) {
      issues.add(ManifestIssue(field, '文件名不可用：$name'));
      continue;
    }
    if (!lowered.add(name.toLowerCase())) {
      issues.add(ManifestIssue(field, '文件名重复：$name'));
      continue;
    }
    names.add(name);
  }
  if (issues.isNotEmpty) return null;

  final String pipeline = (_readString(map['pipeline'])?.trim().isEmpty ?? true)
      ? kGlslShadersPipeline
      : _readString(map['pipeline'])!.trim();
  if (pipeline != kGlslShadersPipeline) {
    issues.add(ManifestIssue(
      'payload.shader.pipeline',
      '管线「$pipeline」本版本不支持（只认 $kGlslShadersPipeline）',
    ));
    return null;
  }

  // 每个 shader 文件都必须出现在 files 里，否则"装上后 glsl-shaders 指向不存在的文件"。
  final Set<String> declared = files.map((ExtensionFile f) => f.path.toLowerCase()).toSet();
  for (final String name in names) {
    final String relative = dir.isEmpty ? name : '$dir/$name';
    if (!declared.contains(relative.toLowerCase())) {
      issues.add(ManifestIssue(
        'payload.shader.files',
        '文件「$relative」没有列在 files 里（要带 size/sha256 才能校验）',
      ));
    }
    if (!name.toLowerCase().endsWith('.glsl')) {
      warnings.add(ManifestIssue(
        'payload.shader.files',
        '「$name」不是 .glsl 结尾（确认它是 mpv 能吃的 GLSL shader）',
      ));
    }
  }
  if (issues.isNotEmpty) return null;

  return ExtensionShaderSpec(
    dir: dir,
    files: List<String>.unmodifiable(names),
    pipeline: pipeline,
  );
}
