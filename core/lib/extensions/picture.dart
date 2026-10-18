/// 「画面调节」扩展包（`kind: "picture-pack"`）的模型、解析与 GLSL 生成 —— 纯逻辑。
///
/// 为什么需要新类型：内置的画面调节（锐度/线条/对比/饱和/亮度/gamma/暗部/色温）
/// 决定只做 **纯扩展包**（用户 2026-10-18 定的口径），而 mpv 这份 libmpv
/// **不认 `//!PARAM`**（实测日志 `Unrecognized command 'PARAM'!`），
/// 所以没有运行时滑杆这回事 —— 任何"调一个数值"都必须**重新生成一份 .glsl 文本**
/// 再重新挂 `glsl-shaders`。
///
/// 这个文件只负责"纯"的那一半：
///
/// 1. 解析清单里的 `payload.picture`（参数声明 + 预设），判据和 `manifest.dart` 同一套；
/// 2. 把扩展包里的**模板 GLSL**（含 `@key@` 占位符）按用户取值渲染成最终文本；
/// 3. 给渲染结果一个确定性的缓存键（同样的参数永远得到同一个文件名，
///    避免每拖动一次滑杆就在缓存目录里堆一个新文件）。
///
/// 不碰磁盘：写文件、挂载、崩溃守卫都在宿主（`app`/`ShikiiN`）那一侧。
///
/// ## 模板约定
///
/// ```glsl
/// #define SHARPEN @sharpen@
/// #define LINE    @line@
/// ```
///
/// 占位符是 `@key@`（key 必须是 params 里声明过的）；渲染时替换成**固定 4 位小数**
/// 的十进制文本（`0.4500`）—— 不用 `toString()`，因为它会写出 `1e-7` 这种 GLSL 不吃的指数形式。
///
/// 模板里出现未声明的 `@xxx@` 直接判错：那是拼错参数名，装上之后只会得到一份
/// 语法正确但语义不对的 shader（比装不上更难查）。
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'manifest.dart';
import 'package_guard.dart';

/// 「画面调节」扩展包的 kind。
///
/// 和 `shader-pack` 的区别：`shader-pack` 是**一组固定的 .glsl**（按顺序挂上去就完事）；
/// `picture-pack` 是**一份带占位符的模板 + 参数声明**，宿主按当前取值现场渲染。
const String kPicturePackKind = 'picture-pack';

/// 参数名判据：小写字母开头，之后小写字母/数字/下划线，最长 32。
///
/// 它就是模板里 `@name@` 的名字，也是持久化时的 json 键 —— 不允许大写/短横线，
/// 免得"清单里叫 a-b、模板里写 @a_b@"这种只有人眼能发现的错位。
final RegExp _kParamKeyPattern = RegExp(r'^[a-z][a-z0-9_]{0,31}$');

/// 预设 id 判据（扩展内唯一，不进全局命名空间，所以比扩展 id 短一点）。
final RegExp _kPresetIdPattern = RegExp(r'^[a-z0-9][a-z0-9._-]{0,31}$');

/// 参数上限：四组滑块一共十来个，32 已经非常宽松。
const int kPictureMaxParams = 32;

/// 预设上限。
const int kPictureMaxPresets = 32;

/// 一个可调的数值参数（界面上一个滑杆）。
class PictureParam {
  const PictureParam({
    required this.key,
    required this.label,
    required this.min,
    required this.max,
    required this.step,
    required this.defaultValue,
    this.group = '',
    this.unit = '',
  });

  /// 模板里的占位符名（`@key@`），也是持久化键。
  final String key;

  /// 界面上的中文名（「锐度」「线条强化」…）。
  final String label;

  /// 下限 / 上限 / 步长（滑块用；[step] 只影响界面手感，渲染时会夹到 [[min], [max]]）。
  final double min;
  final double max;
  final double step;

  /// 默认值（必须在 [[min], [max]] 内）。
  final double defaultValue;

  /// 分组名（「锐度与线条」「对比与饱和」「亮度与暗部」「色温与色调」），空串 = 不分组。
  final String group;

  /// 单位后缀（`%` / `K` / 空串），纯显示用。
  final String unit;

  /// 把任意取值夹到合法区间并按 [step] 量化 —— 界面、持久化、渲染三处**用同一个函数**，
  /// 否则会出现"界面显示 0.7、存下来 0.7000000000000001、渲染成 0.7000"的不一致。
  double clampValue(double value) {
    if (value.isNaN) return defaultValue;
    final double clamped = value < min ? min : (value > max ? max : value);
    if (step <= 0) return clamped;
    final double snapped = (clamped / step).roundToDouble() * step;
    // 量化后再夹一次：0.1 步长下 3.0000000000000004 这种要收回 3.0。
    final double result = snapped < min ? min : (snapped > max ? max : snapped);
    return _roundTo(result, _stepDecimals);
  }

  /// [step] 的小数位数（0.05 → 2），用于把量化结果收敛到人类可读的十进制。
  int get _stepDecimals {
    final String text = step.toString();
    final int dot = text.indexOf('.');
    if (dot < 0) return 0;
    final String frac = text.substring(dot + 1);
    if (frac == '0') return 0;
    return frac.length;
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'key': key,
        'label': label,
        'min': min,
        'max': max,
        'step': step,
        'default': defaultValue,
        if (group.isNotEmpty) 'group': group,
        if (unit.isNotEmpty) 'unit': unit,
      };

  @override
  String toString() => 'PictureParam($key $label [$min..$max] step=$step '
      'default=$defaultValue)';
}

/// 一个预设：一组参数取值 + （可选）建议绑定的超分方案。
///
/// 「预设 = 画面参数 + 超分方案」是用户定的口径：预设不只调画质，也决定用哪套超分
/// （包括「关超分」——很多片源用 Anime4K 反而更软，这已经在实测里验证过）。
/// [upscaleSchemeId] 为空 = 保持用户当前选的超分方案不动。
class PicturePreset {
  const PicturePreset({
    required this.id,
    required this.name,
    required this.values,
    this.upscaleSchemeId,
    this.description = '',
  });

  final String id;
  final String name;

  /// 参数名 → 取值（**只写想覆盖的参数**，没写的用 [PictureParam.defaultValue]）。
  final Map<String, double> values;

  /// 建议绑定的超分方案 id（`null` = 不动用户的当前选择）。
  final String? upscaleSchemeId;

  final String description;

  Map<String, Object?> toJson() => <String, Object?>{
        'id': id,
        'name': name,
        'values': values,
        if (upscaleSchemeId != null) 'upscale': upscaleSchemeId,
        if (description.isNotEmpty) 'description': description,
      };

  @override
  String toString() => 'PicturePreset($id $name $values upscale=$upscaleSchemeId)';
}

/// `payload.picture` 解析通过后的全部内容。
class PictureSpec {
  const PictureSpec({
    required this.template,
    required this.params,
    required this.presets,
    this.chainHint = '',
  });

  /// 模板 GLSL 相对扩展根的路径（如 `shaders/picture.glsl`）。
  final String template;

  /// 参数声明，**保持清单里的顺序**（界面按这个顺序摆滑杆）。
  final List<PictureParam> params;

  /// 预设，保持清单顺序。
  final List<PicturePreset> presets;

  /// 一句话提示（界面上参数区顶部显示，可空）。
  final String chainHint;

  bool get isEmpty => params.isEmpty && presets.isEmpty;

  /// 去掉用户关掉的预设，其余原样（不可变，返回新对象）。
  ///
  /// 为什么在这里就过滤掉、而不是菜单里再藏一遍：「关掉的预设」是**用户设置**
  /// （`ExtensionUserSettings.hiddenPresets`），一处过滤、整条链路自然一致 ——
  /// 菜单不列它、`selectPack` 也不会把它当成"第一个预设"去套。过滤得越早，
  /// 后面（宿主 adapter / 播放器菜单 / 控制器）就都不必知道这件事。
  PictureSpec withoutPresets(Set<String> presetIds) {
    if (presetIds.isEmpty) return this;
    final List<PicturePreset> kept = <PicturePreset>[
      for (final PicturePreset preset in presets)
        if (!presetIds.contains(preset.id)) preset,
    ];
    if (kept.length == presets.length) return this;
    return PictureSpec(
      template: template,
      params: params,
      presets: List<PicturePreset>.unmodifiable(kept),
      chainHint: chainHint,
    );
  }

  PictureParam? paramByKey(String key) {
    for (final PictureParam param in params) {
      if (param.key == key) return param;
    }
    return null;
  }

  /// 每个参数的默认取值（= 一份完整取值表）。
  Map<String, double> get defaults => <String, double>{
        for (final PictureParam param in params) param.key: param.defaultValue,
      };

  /// 预设 → 完整取值表：先铺默认值，再覆盖预设里写到的键，并逐个夹到区间内。
  ///
  /// 夹值这一步不是防御性编程：扩展作者写 `1.2` 而参数上限是 `1.0` 时，
  /// 界面会显示 1.0、渲染也必须用 1.0，否则"看着一样、画面不一样"。
  Map<String, double> valuesOf(PicturePreset preset) {
    final Map<String, double> out = defaults;
    for (final MapEntry<String, double> e in preset.values.entries) {
      final PictureParam? param = paramByKey(e.key);
      if (param != null) out[param.key] = param.clampValue(e.value);
    }
    return out;
  }

  /// 把一份取值表补齐/夹好（未知键丢弃），保证渲染与界面用的是同一份数。
  Map<String, double> normalizeValues(Map<String, double> values) {
    final Map<String, double> out = defaults;
    for (final PictureParam param in params) {
      final double? raw = values[param.key];
      if (raw != null) out[param.key] = param.clampValue(raw);
    }
    return out;
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'template': template,
        'params': <Object?>[for (final PictureParam p in params) p.toJson()],
        'presets': <Object?>[for (final PicturePreset p in presets) p.toJson()],
        if (chainHint.isNotEmpty) 'hint': chainHint,
      };
}

/// 解析 `payload.picture`。判据与 `manifest.dart` 一致：**看不懂就说看不懂**。
///
/// [files] 是本清单声明的落盘文件表，用来确认模板真的在包里（否则装上后
/// "宿主读不到模板"只会在切换预设时才炸）。
PictureSpec? parsePictureSpec(
  Object? raw, {
  required List<ExtensionFile> files,
  required List<ManifestIssue> issues,
  required List<ManifestIssue> warnings,
}) {
  if (raw is! Map) {
    issues.add(const ManifestIssue('payload.picture', 'payload.picture 必须是对象'));
    return null;
  }
  final Map<String, Object?> map = <String, Object?>{
    for (final MapEntry<Object?, Object?> e in raw.entries) '${e.key}': e.value,
  };

  // ── template ────────────────────────────────────────────────────────────
  final String template = '${map['template'] ?? ''}'.trim();
  if (template.isEmpty) {
    issues.add(const ManifestIssue(
      'payload.picture.template',
      '缺少 template（包内那份带 @key@ 占位符的 .glsl 路径）',
    ));
  } else {
    final String? unsafe = unsafeRelativePathReason(template);
    if (unsafe != null) {
      issues.add(ManifestIssue(
        'payload.picture.template',
        '模板路径「$template」不可用：$unsafe',
      ));
    } else if (!template.toLowerCase().endsWith('.glsl')) {
      warnings.add(ManifestIssue(
        'payload.picture.template',
        '「$template」不是 .glsl 结尾（确认它是 mpv 能吃的 GLSL shader）',
      ));
    }
    final Set<String> declared = files
        .map((ExtensionFile f) => f.path.toLowerCase())
        .toSet();
    if (!declared.contains(template.toLowerCase())) {
      issues.add(ManifestIssue(
        'payload.picture.template',
        '模板「$template」没有列在 files 里（要带 size/sha256 才能校验）',
      ));
    }
  }

  // ── params ──────────────────────────────────────────────────────────────
  final List<PictureParam> params = <PictureParam>[];
  final Map<String, PictureParam> byKey = <String, PictureParam>{};
  final Object? rawParams = map['params'];
  if (rawParams != null && rawParams is! List) {
    issues.add(const ManifestIssue('payload.picture.params', 'params 必须是数组'));
  } else if (rawParams is List) {
    if (rawParams.length > kPictureMaxParams) {
      issues.add(ManifestIssue(
        'payload.picture.params',
        '参数太多（上限 $kPictureMaxParams 个）',
      ));
    }
    for (int i = 0; i < rawParams.length; i++) {
      final Object? item = rawParams[i];
      final String field = 'payload.picture.params[$i]';
      if (item is! Map) {
        issues.add(ManifestIssue(field, '不是对象（要有 key/label/min/max/default）'));
        continue;
      }
      final Map<String, Object?> p = <String, Object?>{
        for (final MapEntry<Object?, Object?> e in item.entries) '${e.key}': e.value,
      };
      final PictureParam? param = _parseParam(p, field: field, issues: issues);
      if (param == null) continue;
      if (byKey.containsKey(param.key)) {
        issues.add(ManifestIssue('$field.key', '参数名「${param.key}」重复'));
        continue;
      }
      byKey[param.key] = param;
      params.add(param);
    }
  }

  // ── presets ─────────────────────────────────────────────────────────────
  final List<PicturePreset> presets = <PicturePreset>[];
  final Set<String> presetIds = <String>{};
  final Object? rawPresets = map['presets'];
  if (rawPresets != null && rawPresets is! List) {
    issues.add(const ManifestIssue('payload.picture.presets', 'presets 必须是数组'));
  } else if (rawPresets is List) {
    if (rawPresets.length > kPictureMaxPresets) {
      issues.add(ManifestIssue(
        'payload.picture.presets',
        '预设太多（上限 $kPictureMaxPresets 个）',
      ));
    }
    for (int i = 0; i < rawPresets.length; i++) {
      final Object? item = rawPresets[i];
      final String field = 'payload.picture.presets[$i]';
      if (item is! Map) {
        issues.add(ManifestIssue(field, '不是对象（要有 id/name/values）'));
        continue;
      }
      final Map<String, Object?> p = <String, Object?>{
        for (final MapEntry<Object?, Object?> e in item.entries) '${e.key}': e.value,
      };
      final PicturePreset? preset = _parsePreset(
        p,
        field: field,
        params: byKey,
        issues: issues,
      );
      if (preset == null) continue;
      if (!presetIds.add(preset.id)) {
        issues.add(ManifestIssue('$field.id', '预设 id「${preset.id}」重复'));
        continue;
      }
      presets.add(preset);
    }
  }

  if (params.isEmpty && presets.isEmpty && issues.isEmpty) {
    issues.add(const ManifestIssue(
      'payload.picture',
      'params 和 presets 都是空的：这个画面调节包没有任何可调项',
    ));
  }

  final String hint = '${map['hint'] ?? ''}'.trim();

  if (issues.isNotEmpty) return null;
  return PictureSpec(
    template: template,
    params: List<PictureParam>.unmodifiable(params),
    presets: List<PicturePreset>.unmodifiable(presets),
    chainHint: hint,
  );
}

PictureParam? _parseParam(
  Map<String, Object?> p, {
  required String field,
  required List<ManifestIssue> issues,
}) {
  final String key = '${p['key'] ?? ''}'.trim();
  if (key.isEmpty) {
    issues.add(ManifestIssue('$field.key', '缺少 key（模板里写 @key@）'));
    return null;
  }
  if (!_kParamKeyPattern.hasMatch(key)) {
    issues.add(ManifestIssue(
      '$field.key',
      '参数名「$key」不合规：小写字母开头，只能用 a-z 0-9 _，最长 32',
    ));
    return null;
  }
  final String label = '${p['label'] ?? ''}'.trim();
  if (label.isEmpty) {
    issues.add(ManifestIssue('$field.label', '缺少 label（界面上的中文名）'));
    return null;
  }
  final double? min = _readDouble(p['min']);
  final double? max = _readDouble(p['max']);
  final double? step = _readDouble(p['step']);
  final double? defaultValue = _readDouble(p['default']);
  if (min == null) {
    issues.add(ManifestIssue('$field.min', 'min 要写数字'));
    return null;
  }
  if (max == null) {
    issues.add(ManifestIssue('$field.max', 'max 要写数字'));
    return null;
  }
  if (max <= min) {
    issues.add(ManifestIssue('$field.max', 'max（$max）必须大于 min（$min）'));
    return null;
  }
  if (max - min > 10000) {
    issues.add(ManifestIssue('$field.max', '区间太大了（上限 10000），滑块没法用'));
    return null;
  }
  final double resolvedStep = step ?? ((max - min) / 100);
  if (resolvedStep <= 0 || resolvedStep > max - min) {
    issues.add(ManifestIssue('$field.step', 'step（$resolvedStep）必须大于 0 且不超过区间'));
    return null;
  }
  final double resolvedDefault = defaultValue ?? min;
  if (resolvedDefault < min || resolvedDefault > max) {
    issues.add(ManifestIssue(
      '$field.default',
      'default（$resolvedDefault）不在 [$min, $max] 里',
    ));
    return null;
  }
  return PictureParam(
    key: key,
    label: label,
    min: min,
    max: max,
    step: resolvedStep,
    defaultValue: resolvedDefault,
    group: '${p['group'] ?? ''}'.trim(),
    unit: '${p['unit'] ?? ''}'.trim(),
  );
}

PicturePreset? _parsePreset(
  Map<String, Object?> p, {
  required String field,
  required Map<String, PictureParam> params,
  required List<ManifestIssue> issues,
}) {
  final String id = '${p['id'] ?? ''}'.trim();
  if (id.isEmpty) {
    issues.add(ManifestIssue('$field.id', '缺少 id'));
    return null;
  }
  if (!_kPresetIdPattern.hasMatch(id)) {
    issues.add(ManifestIssue(
      '$field.id',
      '预设 id「$id」不合规：小写字母/数字开头，只能用 a-z 0-9 . _ -，最长 32',
    ));
    return null;
  }
  final String name = '${p['name'] ?? ''}'.trim();
  if (name.isEmpty) {
    issues.add(ManifestIssue('$field.name', '缺少 name（界面上的预设名）'));
    return null;
  }
  final Object? rawValues = p['values'];
  final Map<String, double> values = <String, double>{};
  if (rawValues != null && rawValues is! Map) {
    issues.add(ManifestIssue('$field.values', 'values 必须是对象（参数名 → 数值）'));
    return null;
  }
  if (rawValues is Map) {
    for (final MapEntry<Object?, Object?> e in rawValues.entries) {
      final String key = '${e.key}';
      if (!params.containsKey(key)) {
        issues.add(ManifestIssue(
          '$field.values.$key',
          '参数「$key」没有在 params 里声明',
        ));
        return null;
      }
      final double? value = _readDouble(e.value);
      if (value == null) {
        issues.add(ManifestIssue('$field.values.$key', '取值要写数字'));
        return null;
      }
      values[key] = value;
    }
  }
  final String? upscale = '${p['upscale'] ?? ''}'.trim().isEmpty
      ? null
      : '${p['upscale']}'.trim();
  return PicturePreset(
    id: id,
    name: name,
    values: Map<String, double>.unmodifiable(values),
    upscaleSchemeId: upscale,
    description: '${p['description'] ?? ''}'.trim(),
  );
}

/// 渲染一份模板：把 `@key@` 换成固定 4 位小数的数值。
///
/// 返回 `null` 表示模板**不可用**（缺参数 / 占了没声明的键），原因写进 [issues]。
/// 这条判据是"装了但画面不对"的唯一防线：占位符拼错时 GLSL 依然语法正确
/// （`#define X ` 后面是空），只是行为不对，靠 mpv 的日志根本发现不了。
String? renderPictureShader({
  required String template,
  required PictureSpec spec,
  required Map<String, double> values,
  List<ParsedTemplateIssue>? issues,
}) {
  final Map<String, double> resolved = spec.normalizeValues(values);
  final List<ParsedTemplateIssue> found = <ParsedTemplateIssue>[];
  final Set<String> seen = <String>{};

  final String out = template.replaceAllMapped(
    RegExp(r'@([a-z][a-z0-9_]{0,31})@'),
    (Match m) {
      final String key = m.group(1)!;
      final double? value = resolved[key];
      if (value == null) {
        found.add(ParsedTemplateIssue(key, '模板里的 @$key@ 没有在 params 里声明'));
        return m.group(0)!;
      }
      seen.add(key);
      return value.toStringAsFixed(4);
    },
  );

  if (issues != null) {
    issues.addAll(found);
    // 声明了却没在模板里出现：能跑，但作者大概是拼错了 —— 提醒。
    for (final PictureParam param in spec.params) {
      if (!seen.contains(param.key)) {
        issues.add(ParsedTemplateIssue(
          param.key,
          '参数「${param.key}」声明了但模板里没有 @${param.key}@',
        ));
      }
    }
  }
  return found.isEmpty ? out : null;
}

/// 渲染期发现的一条模板问题（和清单期的 [ManifestIssue] 分开：这里已经装上了，
/// 问题出在"包里的模板"和"清单声明"对不上）。
class ParsedTemplateIssue {
  const ParsedTemplateIssue(this.key, this.message);

  final String key;
  final String message;

  @override
  String toString() => '$key: $message';
}

/// 渲染结果的缓存键：**同样的扩展版本 + 同样的取值 ⇒ 同样的键**。
///
/// 为什么不是随机名：每拖一次滑杆就写一个新 .glsl，一晚上能堆出几千个文件；
/// 有了确定性键，宿主可以直接"先看存在不"再写，滑回原值时还复用旧文件。
/// 取值先按 key 排序再喂哈希，所以 `{a,b}` 与 `{b,a}` 得到同一个键。
String pictureCacheKey({
  required String extensionId,
  required String extensionVersion,
  required Map<String, double> values,
}) {
  final List<String> keys = values.keys.toList()..sort();
  final String payload = <String>[
    extensionId,
    extensionVersion,
    for (final String k in keys) '$k=${values[k]!.toStringAsFixed(4)}',
  ].join('|');
  final String hex = sha256.convert(utf8.encode(payload)).toString();
  return hex.substring(0, 16);
}

/// 一份生成结果的**落盘文件名**（`<键>.glsl`）。
///
/// 带扩展 id 是为了在同一个缓存目录里肉眼能分辨来源；键里已经含 id，所以不会撞。
String pictureCacheFileName({
  required String extensionId,
  required String cacheKey,
}) =>
    '${extensionId}_$cacheKey.glsl';

double? _readDouble(Object? value) {
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value.trim());
  return null;
}

double _roundTo(double value, int decimals) {
  if (decimals <= 0) return value.roundToDouble();
  final double factor = _pow10(decimals);
  return (value * factor).roundToDouble() / factor;
}

double _pow10(int n) {
  double out = 1;
  for (int i = 0; i < n; i++) {
    out *= 10;
  }
  return out;
}
