/// 通用扩展载荷（`preset-pack` / `list-pack`）的模型、surface 注册表与解析 —— **纯逻辑，不碰磁盘**。
///
/// 为什么要有这一层：每加一种「数据面」（字幕样式、主题外观、片单、追番清单、RSS 源…）
/// 就发明一套 `payload.xxx` + 一份扫描/校验/文案，代价会随面数线性上涨。通用包把
/// 「数据面」收敛成 core 里的白名单（[ExtensionSurface]）：扩展只声明 `surface` 与
/// 预设/列表数据，宿主为每个面实现一个 consumer。新加一个面只写 schema + consumer，
/// 不再改清单格式、安装器或扩展页文案。
///
/// ## 契约（改格式必须同时改 `docs/specs/2026-10-19-dsanima-generic-packs-design.md`）
///
/// ```json
/// {
///   "kind": "preset-pack",
///   "payload": {
///     "surface": "player.subtitle",
///     "surfaceSchema": 1,
///     "assets": [{"path": "fonts/a.ttf", "role": "font", "family": "字体 A"}],
///     "presets": [{"id": "cinema", "name": "影院", "values": {"scale": 1.6, "color": "#FFFFFF"}}]
///   }
/// }
/// ```
///
/// 三条判据（与 `manifest.dart` 同一套口径）：
/// * **拼错就说拼错**：未知字段/值类型/越界/颜色格式一律进 issues，不静默忽略；
/// * **不认识 ≠ 拒装**：未知 surface 只 warning（可装、无运行时，宿主还不认识这个面）；
/// * **格式版本要说清**：`surfaceSchema` 必须正好等于宿主认识的那个版本，否则拒装。
library;

import 'issues.dart';
import 'url_safety.dart';

/// `preset-pack`：命名预设，喂给某个面。
const String kPresetPackKind = 'preset-pack';

/// `list-pack`：数据列表，喂给某个面。
const String kListPackKind = 'list-pack';

/// `audio-pack`：音效档位。载荷与 [kPresetPackKind] **完全同构**，单独一个 kind
/// 只为扩展页叫得准（「音效包」而不是「预设包」），不为多一套解析。
///
/// 为什么不是 `preset-pack` 换个面就完事：kind 决定界面文案与可用性判断，
/// 用户装完看到「预设包」会以为装错了东西。
const String kAudioPackKind = 'audio-pack';

/// 播放器字幕样式面（第一个落地的通用面）。
const String kPlayerSubtitleSurfaceId = 'player.subtitle';

/// 播放器音效面（`audio-pack` 必须绑这个面）。
const String kPlayerAudioSurfaceId = 'player.audio';

/// 通用包的默认上限（面自己声明了就用面的）。
const int kGenericMaxPresets = 32;
const int kGenericMaxLists = 8;
const int kGenericMaxItems = 200;
const int kGenericMaxAssets = 16;

/// 一个面字段的取值类型。
enum SurfaceValueType { boolean, integer, number, string, color, url }

/// 这个面吃哪种载荷。
enum SurfacePayloadKind { preset, list }

/// 面里的一个值字段（预设包的 `values` 键 / 列表包的条目键）的判据。
class SurfaceField {
  const SurfaceField({
    required this.key,
    required this.type,
    this.required = false,
    this.min,
    this.max,
    this.enumValues,
  });

  final String key;
  final SurfaceValueType type;
  final bool required;
  final num? min;
  final num? max;
  final List<String>? enumValues;
}

/// 一个「面」：宿主已经实现了消费能力的一类数据入口。
///
/// 白名单硬编码在 core，**不能**由数据动态注册 —— 未知 surface 只 warning、没有运行时。
class ExtensionSurface {
  const ExtensionSurface({
    required this.id,
    required this.payloadKind,
    required this.schema,
    required this.label,
    required this.hostHint,
    required this.hostWindow,
    this.fields = const <SurfaceField>[],
    this.itemFields = const <SurfaceField>[],
    this.maxPresets = kGenericMaxPresets,
    this.maxLists = kGenericMaxLists,
    this.maxItems = kGenericMaxItems,
    this.maxAssets = kGenericMaxAssets,
  });

  /// 面 id（`player.subtitle`）。
  final String id;

  /// 吃预设还是列表。
  final SurfacePayloadKind payloadKind;

  /// 这个面的值格式版本（`surfaceSchema` 必须等于它）。
  final int schema;

  /// 扩展页/提示用的中文名。
  final String label;

  /// 装完在哪儿用（一句话，扩展页原样显示）。
  final String hostHint;

  /// 在哪个宿主窗口消费：`player` / `main`（接线与提示用）。
  final String hostWindow;

  /// `preset-pack` 的 `values` 字段判据。
  final List<SurfaceField> fields;

  /// `list-pack` 的条目字段判据。
  final List<SurfaceField> itemFields;

  final int maxPresets;
  final int maxLists;
  final int maxItems;
  final int maxAssets;
}

/// 本版本认识的「面」。首版只有播放器字幕样式（主题/片单/追番清单/RSS 源在后续版本各自补）。
const List<ExtensionSurface> kExtensionSurfaces = <ExtensionSurface>[
  ExtensionSurface(
    id: kPlayerSubtitleSurfaceId,
    payloadKind: SurfacePayloadKind.preset,
    schema: 1,
    label: '播放器字幕样式',
    hostHint: '装完在播放器设置 →「字幕样式」里选预设',
    hostWindow: 'player',
    fields: <SurfaceField>[
      SurfaceField(key: 'scale', type: SurfaceValueType.number, min: 0.5, max: 2.5),
      SurfaceField(key: 'pos', type: SurfaceValueType.integer, min: 0, max: 150),
      SurfaceField(key: 'borderSize', type: SurfaceValueType.number, min: 0, max: 6),
      SurfaceField(key: 'borderColor', type: SurfaceValueType.color),
      SurfaceField(key: 'color', type: SurfaceValueType.color),
      SurfaceField(key: 'shadowColor', type: SurfaceValueType.color),
      SurfaceField(key: 'shadowOffset', type: SurfaceValueType.number, min: 0, max: 6),
      SurfaceField(key: 'backColor', type: SurfaceValueType.color),
      SurfaceField(key: 'bold', type: SurfaceValueType.boolean),
      SurfaceField(key: 'italic', type: SurfaceValueType.boolean),
      SurfaceField(key: 'font', type: SurfaceValueType.string),
    ],
  ),
  // 音效面（`audio-pack`）：10 段固定 ISO 增益 + 预增益 + 交叉馈电强度。
  // 全部是**有界数字**，宿主据此拼 `af` 链 —— 包写不进任意 lavfi（理由见
  // `docs/specs/2026-10-19-dsanima-audio-packs-design.md` §3.5、§5）。
  ExtensionSurface(
    id: kPlayerAudioSurfaceId,
    payloadKind: SurfacePayloadKind.preset,
    schema: 1,
    label: '播放器音效',
    hostHint: '装完在播放器设置 →「音效」里选档，右键菜单也能切',
    hostWindow: 'player',
    maxPresets: 12,
    maxAssets: 0,
    fields: <SurfaceField>[
      SurfaceField(key: 'b31', type: SurfaceValueType.number, min: -12, max: 12),
      SurfaceField(key: 'b63', type: SurfaceValueType.number, min: -12, max: 12),
      SurfaceField(key: 'b125', type: SurfaceValueType.number, min: -12, max: 12),
      SurfaceField(key: 'b250', type: SurfaceValueType.number, min: -12, max: 12),
      SurfaceField(key: 'b500', type: SurfaceValueType.number, min: -12, max: 12),
      SurfaceField(key: 'b1k', type: SurfaceValueType.number, min: -12, max: 12),
      SurfaceField(key: 'b2k', type: SurfaceValueType.number, min: -12, max: 12),
      SurfaceField(key: 'b4k', type: SurfaceValueType.number, min: -12, max: 12),
      SurfaceField(key: 'b8k', type: SurfaceValueType.number, min: -12, max: 12),
      SurfaceField(key: 'b16k', type: SurfaceValueType.number, min: -12, max: 12),
      SurfaceField(key: 'preamp', type: SurfaceValueType.number, min: -12, max: 6),
      SurfaceField(key: 'crossfeed', type: SurfaceValueType.number, min: 0, max: 1),
    ],
  ),
];

/// 按 id 找默认注册表里的面；没有 = null（调用方按「本版本不接」处理）。
ExtensionSurface? extensionSurfaceOf(String id) => _surfaceOf(kExtensionSurfaces, id);

ExtensionSurface? _surfaceOf(List<ExtensionSurface> surfaces, String id) {
  for (final ExtensionSurface surface in surfaces) {
    if (surface.id == id) return surface;
  }
  return null;
}

/// 通用包里的一个资源文件（首版只支持字体）。
class GenericAsset {
  const GenericAsset({required this.path, required this.role, required this.family});

  /// 相对扩展根的正斜杠路径（必须在 `files[]` 里）。
  final String path;

  /// 资源角色；本版本只认 `font`。
  final String role;

  /// 字体族名（`FontLoader` 注册时用）。
  final String family;
}

/// 一个命名预设：`values` 已经按面的 schema 归一化过（颜色 → `#AARRGGBB` 等）。
class GenericPreset {
  const GenericPreset({
    required this.id,
    required this.name,
    this.description = '',
    required this.values,
  });

  final String id;
  final String name;
  final String description;
  final Map<String, Object?> values;
}

/// 一个列表：`items` 已经按面的 schema 归一化过。
class GenericList {
  const GenericList({
    required this.id,
    required this.name,
    this.description = '',
    required this.items,
  });

  final String id;
  final String name;
  final String description;
  final List<Map<String, Object?>> items;
}

/// 解析通过的通用载荷。
class GenericPayload {
  const GenericPayload({
    required this.surface,
    required this.surfaceSchema,
    this.assets = const <GenericAsset>[],
    this.presets = const <GenericPreset>[],
    this.lists = const <GenericList>[],
  });

  final String surface;
  final int surfaceSchema;
  final List<GenericAsset> assets;
  final List<GenericPreset> presets;
  final List<GenericList> lists;
}

/// 一次通用载荷解析的结果。[payload] 非 null 且 issues 为空才算能装。
class GenericPayloadParseResult {
  const GenericPayloadParseResult({
    this.payload,
    this.issues = const <ManifestIssue>[],
    this.warnings = const <ManifestIssue>[],
  });

  final GenericPayload? payload;
  final List<ManifestIssue> issues;
  final List<ManifestIssue> warnings;
}

const Set<String> _kPayloadKeys = <String>{
  'surface',
  'surfaceSchema',
  'assets',
  'presets',
  'lists',
};

final RegExp _kGenericIdPattern = RegExp(r'^[a-z0-9][a-z0-9._-]{0,31}$');

/// 把 `#RGB` / `#RRGGBB` / `#AARRGGBB` 归一化成大写 `#AARRGGBB`；坏值返回 null。
String? normalizeExtensionColor(String raw) {
  var text = raw.trim();
  if (text.startsWith('#')) text = text.substring(1);
  if (text.isEmpty) return null;
  if (!RegExp(r'^[0-9a-fA-F]+$').hasMatch(text)) return null;
  if (text.length == 6) text = 'FF$text';
  if (text.length != 8) return null;
  return '#${text.toUpperCase()}';
}

/// 解析 `preset-pack` / `list-pack` 的 `payload`。
///
/// [declaredPathsLower] 是清单 `files[]` 的小写路径集合：`assets[].path` 必须在这里
/// （资源文件也要被包守卫校验、被安装器落盘）。
GenericPayloadParseResult parseGenericPayload(
  String kind,
  Object? rawPayload, {
  required Set<String> declaredPathsLower,
  List<ExtensionSurface> surfaces = kExtensionSurfaces,
}) {
  final List<ManifestIssue> issues = <ManifestIssue>[];
  final List<ManifestIssue> warnings = <ManifestIssue>[];

  if (kind != kPresetPackKind &&
      kind != kListPackKind &&
      kind != kAudioPackKind) {
    issues.add(ManifestIssue(
      'kind',
      '「$kind」不是通用包类型（只认 $kPresetPackKind / $kListPackKind / $kAudioPackKind）',
    ));
    return GenericPayloadParseResult(issues: issues);
  }

  if (rawPayload is! Map) {
    issues.add(const ManifestIssue(
      'payload',
      'payload 必须是对象（surface + surfaceSchema + presets/lists）',
    ));
    return GenericPayloadParseResult(issues: issues);
  }
  final Map<String, Object?> payload = <String, Object?>{
    for (final MapEntry<Object?, Object?> e in rawPayload.entries) '${e.key}': e.value,
  };
  for (final String key in payload.keys) {
    if (!_kPayloadKeys.contains(key)) {
      issues.add(ManifestIssue(
        'payload.$key',
        'payload 里不认识「$key」（拼错了吗？通用包只认 surface / surfaceSchema / assets / presets / lists）',
      ));
    }
  }

  // ── surface / surfaceSchema ──────────────────────────────────────────────
  final String surfaceId = _readString(payload['surface'])?.trim() ?? '';
  ExtensionSurface? surface;
  if (surfaceId.isEmpty) {
    issues.add(const ManifestIssue('payload.surface', '缺少 surface（这个包喂给哪个面）'));
  } else {
    surface = _surfaceOf(surfaces, surfaceId);
    if (surface == null) {
      warnings.add(ManifestIssue(
        'payload.surface',
        '面「$surfaceId」本版本不认识：可以安装，但不会有运行时效果',
      ));
    }
  }

  int? schema;
  final Object? rawSchema = payload['surfaceSchema'];
  if (rawSchema is num && rawSchema == rawSchema.toInt()) {
    schema = rawSchema.toInt();
    if (surface != null && schema != surface.schema) {
      issues.add(ManifestIssue(
        'payload.surfaceSchema',
        '面「${surface.id}」的格式版本是 ${surface.schema}，这个包写的是 $schema（换一份包或更新 DSAnima）',
      ));
    }
  } else {
    issues.add(const ManifestIssue(
      'payload.surfaceSchema',
      '缺少 surfaceSchema（正整数，本版本都是 1）',
    ));
  }

  final bool isPreset = kind == kPresetPackKind || kind == kAudioPackKind;

  if (surface != null &&
      surface.payloadKind !=
          (isPreset ? SurfacePayloadKind.preset : SurfacePayloadKind.list)) {
    issues.add(ManifestIssue(
      'payload.surface',
      '面「${surface.id}」吃的是${surface.payloadKind == SurfacePayloadKind.preset ? '预设' : '列表'}，'
          '这个包的 kind 是 $kind（写反了？）',
    ));
  }

  // ── assets（只有 preset-pack 允许，首版只支持字体）──────────────────────
  final List<GenericAsset> assets = <GenericAsset>[];
  final Object? rawAssets = payload['assets'];
  if (rawAssets != null) {
    if (!isPreset) {
      issues.add(const ManifestIssue(
        'payload.assets',
        '只有 preset-pack 能用 assets（列表包不带字体资产）',
      ));
    } else {
      _parseAssets(
        rawAssets,
        declaredPathsLower: declaredPathsLower,
        maxAssets: surface?.maxAssets ?? kGenericMaxAssets,
        issues: issues,
        out: assets,
      );
    }
  }

  // ── presets / lists ──────────────────────────────────────────────────────
  final List<GenericPreset> presets = <GenericPreset>[];
  final List<GenericList> lists = <GenericList>[];
  if (isPreset) {
    if (payload['lists'] != null) {
      issues.add(const ManifestIssue(
        'payload.lists',
        'preset-pack 不能用 lists（预设包只给 presets）',
      ));
    }
    _parsePresets(
      payload['presets'],
      surface: surface,
      maxPresets: surface?.maxPresets ?? kGenericMaxPresets,
      issues: issues,
      out: presets,
    );
  } else {
    if (payload['presets'] != null) {
      issues.add(const ManifestIssue(
        'payload.presets',
        'list-pack 不能用 presets（列表包只给 lists）',
      ));
    }
    _parseLists(
      payload['lists'],
      surface: surface,
      maxLists: surface?.maxLists ?? kGenericMaxLists,
      maxItems: surface?.maxItems ?? kGenericMaxItems,
      issues: issues,
      out: lists,
    );
  }

  if (issues.isNotEmpty || schema == null) {
    return GenericPayloadParseResult(issues: issues, warnings: warnings);
  }
  return GenericPayloadParseResult(
    payload: GenericPayload(
      surface: surfaceId,
      surfaceSchema: schema,
      assets: List<GenericAsset>.unmodifiable(assets),
      presets: List<GenericPreset>.unmodifiable(presets),
      lists: List<GenericList>.unmodifiable(lists),
    ),
    warnings: warnings,
  );
}

void _parseAssets(
  Object? raw, {
  required Set<String> declaredPathsLower,
  required int maxAssets,
  required List<ManifestIssue> issues,
  required List<GenericAsset> out,
}) {
  if (raw is! List) {
    issues.add(const ManifestIssue('payload.assets', 'assets 必须是数组'));
    return;
  }
  if (raw.length > maxAssets) {
    issues.add(ManifestIssue('payload.assets', 'assets 太多（上限 $maxAssets 个）'));
    return;
  }
  for (int i = 0; i < raw.length; i++) {
    final String field = 'payload.assets[$i]';
    final Object? item = raw[i];
    if (item is! Map) {
      issues.add(ManifestIssue(field, '不是对象（要有 path / role / family）'));
      continue;
    }
    final Map<String, Object?> map = <String, Object?>{
      for (final MapEntry<Object?, Object?> e in item.entries) '${e.key}': e.value,
    };
    final String path = _readString(map['path'])?.trim() ?? '';
    if (path.isEmpty) {
      issues.add(ManifestIssue('$field.path', '缺少 path'));
      continue;
    }
    if (!declaredPathsLower.contains(path.toLowerCase())) {
      issues.add(ManifestIssue(
        '$field.path',
        '「$path」没有列在 files[] 里（asset 也必须是包内文件）',
      ));
      continue;
    }
    final String role = _readString(map['role'])?.trim() ?? '';
    if (role != 'font') {
      issues.add(ManifestIssue(
        '$field.role',
        '本版本只支持 role=font（字体资产），收到「$role」',
      ));
      continue;
    }
    final String lower = path.toLowerCase();
    if (!lower.endsWith('.ttf') && !lower.endsWith('.otf')) {
      issues.add(ManifestIssue('$field.path', '字体资产只收 .ttf / .otf（$path）'));
      continue;
    }
    final String family = _readString(map['family'])?.trim() ?? '';
    if (family.isEmpty || family.length > 64) {
      issues.add(ManifestIssue(
        '$field.family',
        'family 必填，1~64 字符（字体族名，注册后给 sub-font 用）',
      ));
      continue;
    }
    out.add(GenericAsset(path: path, role: role, family: family));
  }
}

void _parsePresets(
  Object? raw, {
  required ExtensionSurface? surface,
  required int maxPresets,
  required List<ManifestIssue> issues,
  required List<GenericPreset> out,
}) {
  if (raw is! List) {
    issues.add(ManifestIssue(
      'payload.presets',
      'presets 必须是数组（1~$maxPresets 个）',
    ));
    return;
  }
  if (raw.isEmpty) {
    issues.add(const ManifestIssue('payload.presets', 'presets 不能为空：预设包至少要有一个预设'));
    return;
  }
  if (raw.length > maxPresets) {
    issues.add(ManifestIssue('payload.presets', 'presets 太多（上限 $maxPresets 个）'));
    return;
  }
  final Set<String> seenIds = <String>{};
  for (int i = 0; i < raw.length; i++) {
    final String field = 'payload.presets[$i]';
    final Object? item = raw[i];
    if (item is! Map) {
      issues.add(ManifestIssue(field, '不是对象（要有 id / name / values）'));
      continue;
    }
    final Map<String, Object?> map = <String, Object?>{
      for (final MapEntry<Object?, Object?> e in item.entries) '${e.key}': e.value,
    };
    final String id = _readString(map['id'])?.trim() ?? '';
    if (!_kGenericIdPattern.hasMatch(id)) {
      issues.add(ManifestIssue(
        '$field.id',
        'id「$id」不合规：小写字母/数字与 . _ -，以字母或数字开头，1~32 字符',
      ));
      continue;
    }
    if (!seenIds.add(id)) {
      issues.add(ManifestIssue('$field.id', '预设 id「$id」重复'));
      continue;
    }
    final String name = _readString(map['name'])?.trim() ?? '';
    if (name.isEmpty || name.length > 40) {
      issues.add(ManifestIssue('$field.name', 'name 必填，1~40 字符'));
      continue;
    }
    final String description = _readString(map['description'])?.trim() ?? '';
    if (description.length > 200) {
      issues.add(ManifestIssue('$field.description', 'description 太长（≤200 字符）'));
      continue;
    }
    final Object? rawValues = map['values'];
    if (rawValues is! Map) {
      issues.add(ManifestIssue('$field.values', 'values 必须是对象（面字段 → 取值）'));
      continue;
    }
    final Map<String, Object?> values = <String, Object?>{};
    bool ok = true;
    for (final MapEntry<Object?, Object?> entry in rawValues.entries) {
      final String key = '${entry.key}'.trim();
      final String valueField = '$field.values.$key';
      final SurfaceField? spec = surface == null ? null : _fieldOf(surface.fields, key);
      if (surface != null && spec == null) {
        issues.add(ManifestIssue(
          valueField,
          '面「${surface.id}」没有「$key」这个字段（拼错了吗）',
        ));
        ok = false;
        continue;
      }
      if (spec == null) {
        // 未知面：宿主还不认识它，只保留形状（值原样带走）。
        values[key] = entry.value;
        continue;
      }
      final _ValueResult result = _normalizeValue(spec, entry.value);
      if (result.reason != null) {
        issues.add(ManifestIssue(valueField, result.reason!));
        ok = false;
        continue;
      }
      values[key] = result.value;
    }
    if (surface != null) {
      for (final SurfaceField spec in surface.fields) {
        if (spec.required && !values.containsKey(spec.key)) {
          issues.add(ManifestIssue('$field.values.${spec.key}', '这个面要求这个字段必填'));
          ok = false;
        }
      }
    }
    if (!ok) continue;
    out.add(GenericPreset(
      id: id,
      name: name,
      description: description,
      values: Map<String, Object?>.unmodifiable(values),
    ));
  }
}

void _parseLists(
  Object? raw, {
  required ExtensionSurface? surface,
  required int maxLists,
  required int maxItems,
  required List<ManifestIssue> issues,
  required List<GenericList> out,
}) {
  if (raw is! List) {
    issues.add(ManifestIssue(
      'payload.lists',
      'lists 必须是数组（1~$maxLists 个）',
    ));
    return;
  }
  if (raw.isEmpty) {
    issues.add(const ManifestIssue('payload.lists', 'lists 不能为空：列表包至少要有一个列表'));
    return;
  }
  if (raw.length > maxLists) {
    issues.add(ManifestIssue('payload.lists', 'lists 太多（上限 $maxLists 个）'));
    return;
  }
  final Set<String> seenIds = <String>{};
  for (int i = 0; i < raw.length; i++) {
    final String field = 'payload.lists[$i]';
    final Object? item = raw[i];
    if (item is! Map) {
      issues.add(ManifestIssue(field, '不是对象（要有 id / name / items）'));
      continue;
    }
    final Map<String, Object?> map = <String, Object?>{
      for (final MapEntry<Object?, Object?> e in item.entries) '${e.key}': e.value,
    };
    final String id = _readString(map['id'])?.trim() ?? '';
    if (!_kGenericIdPattern.hasMatch(id)) {
      issues.add(ManifestIssue(
        '$field.id',
        'id「$id」不合规：小写字母/数字与 . _ -，以字母或数字开头，1~32 字符',
      ));
      continue;
    }
    if (!seenIds.add(id)) {
      issues.add(ManifestIssue('$field.id', '列表 id「$id」重复'));
      continue;
    }
    final String name = _readString(map['name'])?.trim() ?? '';
    if (name.isEmpty || name.length > 40) {
      issues.add(ManifestIssue('$field.name', 'name 必填，1~40 字符'));
      continue;
    }
    final String description = _readString(map['description'])?.trim() ?? '';
    if (description.length > 200) {
      issues.add(ManifestIssue('$field.description', 'description 太长（≤200 字符）'));
      continue;
    }
    final Object? rawItems = map['items'];
    if (rawItems is! List) {
      issues.add(ManifestIssue('$field.items', 'items 必须是数组（1~$maxItems 条）'));
      continue;
    }
    if (rawItems.isEmpty) {
      issues.add(ManifestIssue('$field.items', 'items 不能为空'));
      continue;
    }
    if (rawItems.length > maxItems) {
      issues.add(ManifestIssue('$field.items', 'items 太多（上限 $maxItems 条）'));
      continue;
    }
    final List<Map<String, Object?>> items = <Map<String, Object?>>[];
    bool ok = true;
    for (int j = 0; j < rawItems.length; j++) {
      final String itemField = '$field.items[$j]';
      final Object? rawItem = rawItems[j];
      if (rawItem is! Map) {
        issues.add(ManifestIssue(itemField, '不是对象'));
        ok = false;
        continue;
      }
      final Map<String, Object?> itemMap = <String, Object?>{
        for (final MapEntry<Object?, Object?> e in rawItem.entries) '${e.key}': e.value,
      };
      final Map<String, Object?> normalized = <String, Object?>{};
      for (final MapEntry<String, Object?> entry in itemMap.entries) {
        final SurfaceField? spec =
            surface == null ? null : _fieldOf(surface.itemFields, entry.key);
        if (surface != null && spec == null) {
          issues.add(ManifestIssue(
            '$itemField.${entry.key}',
            '面「${surface.id}」的条目没有「${entry.key}」这个字段（拼错了吗）',
          ));
          ok = false;
          continue;
        }
        if (spec == null) {
          normalized[entry.key] = entry.value;
          continue;
        }
        final _ValueResult result = _normalizeValue(spec, entry.value);
        if (result.reason != null) {
          issues.add(ManifestIssue('$itemField.${entry.key}', result.reason!));
          ok = false;
          continue;
        }
        normalized[entry.key] = result.value;
      }
      if (surface != null) {
        for (final SurfaceField spec in surface.itemFields) {
          if (spec.required && !normalized.containsKey(spec.key)) {
            issues.add(ManifestIssue('$itemField.${spec.key}', '这个面的条目要求这个字段必填'));
            ok = false;
          }
        }
      }
      items.add(Map<String, Object?>.unmodifiable(normalized));
    }
    if (!ok) continue;
    out.add(GenericList(
      id: id,
      name: name,
      description: description,
      items: List<Map<String, Object?>>.unmodifiable(items),
    ));
  }
}

SurfaceField? _fieldOf(List<SurfaceField> fields, String key) {
  for (final SurfaceField field in fields) {
    if (field.key == key) return field;
  }
  return null;
}

/// 值校验结果：要么带 [value]，要么带 [reason]。
class _ValueResult {
  const _ValueResult.ok(this.value) : reason = null;
  const _ValueResult.fail(this.reason) : value = null;

  final Object? value;
  final String? reason;
}

_ValueResult _normalizeValue(SurfaceField field, Object? raw) {
  switch (field.type) {
    case SurfaceValueType.boolean:
      if (raw is! bool) return const _ValueResult.fail('要写 true / false');
      return _ValueResult.ok(raw);
    case SurfaceValueType.integer:
      if (raw is! num || raw != raw.toInt()) {
        return const _ValueResult.fail('要写整数');
      }
      final int value = raw.toInt();
      final String? range = _rangeReason(field, value);
      if (range != null) return _ValueResult.fail(range);
      return _ValueResult.ok(value);
    case SurfaceValueType.number:
      if (raw is! num) return const _ValueResult.fail('要写数字');
      final double value = raw.toDouble();
      final String? range = _rangeReason(field, value);
      if (range != null) return _ValueResult.fail(range);
      return _ValueResult.ok(value);
    case SurfaceValueType.string:
      if (raw is! String) return const _ValueResult.fail('要写字符串');
      if (raw.length > 64) return const _ValueResult.fail('太长了（≤64 字符）');
      return _ValueResult.ok(raw);
    case SurfaceValueType.color:
      if (raw is! String) {
        return const _ValueResult.fail('要写 #RRGGBB 或 #AARRGGBB');
      }
      final String? color = normalizeExtensionColor(raw);
      if (color == null) {
        return const _ValueResult.fail('颜色要写 #RRGGBB 或 #AARRGGBB');
      }
      return _ValueResult.ok(color);
    case SurfaceValueType.url:
      if (raw is! String) return const _ValueResult.fail('要写 https:// 地址');
      final String? why = unsafeExtensionUrlReason(Uri.tryParse(raw));
      if (why != null) return _ValueResult.fail(why);
      return _ValueResult.ok(raw);
  }
}

String? _rangeReason(SurfaceField field, num value) {
  final num? min = field.min;
  final num? max = field.max;
  if (min == null && max == null) return null;
  if (min != null && value < min) return '不能小于 $min';
  if (max != null && value > max) return '不能大于 $max';
  final List<String>? allowed = field.enumValues;
  if (allowed != null && !allowed.contains('$value')) {
    return '只能是 ${allowed.join(' / ')}';
  }
  return null;
}

String? _readString(Object? value) => value is String ? value : null;
