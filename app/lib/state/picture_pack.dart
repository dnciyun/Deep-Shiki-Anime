/// 画面调节扩展包（`picture-pack`）的宿主侧运行时：扫盘 → 渲染 → 落缓存 → 挂给播放器。
///
/// 为什么需要这一层（而不是像 `shader-pack` 那样直接变成超分方案）：
/// 本机 libmpv **不认 `//!PARAM`**（实测 `Unrecognized command 'PARAM'!`），没有运行时
/// 滑杆这回事。所以"调一个数"必须是：拿扩展包里的模板 → 按当前取值渲染成一份 `.glsl`
/// → 落盘 → 把**那个文件**挂到 `glsl-shaders`。这条链有三个必须由宿主决定的事：
///
/// 1. **生成物写哪儿**：不能写回扩展目录 —— 升级是整目录替换（旧目录进回收站），
///    卸载是整目录删，运行时产物写进去必丢；所以写 `<数据根>/dsanima/cache/picture/`，
///    与封面缓存同一个"可删缓存"语义。
/// 2. **怎么和超分方案共存**：画面调节是**叠在超分之上**的一层，与用户选的方案正交
///    （也可以在「关超分」时单独生效）。挂载走 `Anime4kController.setExtraChain`
///    —— 它是唯一下发 `glsl-shaders` 的地方，谁都不能绕过它各发一条。
/// 3. **什么时候重渲染**：取值变了、换了包、换了预设都要重来一次；同样的版本 + 同样的
///    取值得到同一个文件名（`core.pictureCacheKey`），滑回原值直接复用缓存。
///
/// 判据与 `extension_schemes.dart` 同一套（宁可不显示，也不显示一个点不动的项）：
/// 启用中、清单合法、类型是 `picture-pack`、模板文件真的在盘上、模板能渲染出文本。
library;

import 'dart:convert';
import 'dart:io';

import 'package:dsanima_core/dsanima_core.dart' as core;
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:shikiin/shikiin.dart';

import '../domain/app_version.dart';
import 'extension_schemes.dart' show kExtensionsDirName, kExtensionsStateFileName;

/// 生成物缓存目录：`<数据根>/dsanima/cache/picture`（与封面缓存同层，可随时清）。
Directory pictureCacheDirOf(Directory supportDir) => Directory(
      p.join(supportDir.path, 'dsanima', 'cache', 'picture'),
    );

/// 一个可用的画面调节包（清单解析通过 + 模板在盘上 + 模板能渲染）。
@immutable
class PicturePack {
  const PicturePack({
    required this.id,
    required this.name,
    required this.version,
    required this.spec,
    required this.template,
    required this.dir,
  });

  final String id;
  final String name;
  final String version;

  /// 清单里的参数/预设声明。
  final core.PictureSpec spec;

  /// 模板 GLSL 正文（含 `@key@` 占位符）。
  final String template;

  /// 扩展自己的目录（只用于诊断/界面说明，生成物**不写这里**）。
  final Directory dir;

  /// 默认取值（= 每个参数的 default）。**中性值**：不做任何调整就是"原样"，
  /// 「重置」回到这里（用户 2026-10-18：「默认为初始参数，不是清晰预设」）。
  Map<String, double> get defaults => spec.defaults;

  /// 有没有可调的滑杆。
  bool get hasParams => spec.params.isNotEmpty;

  /// 有没有预设。
  bool get hasPresets => spec.presets.isNotEmpty;

  @override
  String toString() => 'PicturePack($id $name v$version)';
}

/// 扫一遍扩展目录，返回**现在就能用**的画面调节包（顺序按目录名，稳定可测）。
///
/// 永不抛：扫不出来最多是"设置里没有画面调节这一项"，绝不能让它拖垮播放窗口
/// （原因写进 `debugPrint`，不吞掉）。
Future<List<PicturePack>> loadPicturePacks(
  Directory supportDir, {
  Map<String, Set<String>> hiddenPresets = const <String, Set<String>>{},
}) async {
  try {
    return _load(supportDir, hiddenPresets);
  } catch (error, stack) {
    debugPrint('[picture] 扫描画面调节包失败（只影响画面调节，超分照常）：$error\n$stack');
    return const <PicturePack>[];
  }
}

List<PicturePack> _load(
  Directory supportDir,
  Map<String, Set<String>> hiddenPresets,
) {
  final Directory root = Directory(p.join(supportDir.path, kExtensionsDirName));
  if (!root.existsSync()) return const <PicturePack>[];

  final Map<String, bool> enabled = _readEnabledSync(root);
  final List<Directory> dirs = <Directory>[
    for (final FileSystemEntity entity in root.listSync(followLinks: false))
      if (entity is Directory && !p.basename(entity.path).startsWith('.')) entity,
  ]..sort((Directory a, Directory b) => a.path.compareTo(b.path));

  final List<PicturePack> packs = <PicturePack>[];
  for (final Directory dir in dirs) {
    final String id = p.basename(dir.path);
    if (enabled[id] == false) continue;
    final PicturePack? pack = _packOf(dir, id, hiddenPresets[id] ?? const <String>{});
    if (pack != null) packs.add(pack);
  }
  return List<PicturePack>.unmodifiable(packs);
}

/// 同步读 `state.json` 的 enabled（扫描本身是同步的，这里不为了异步而异步）。
///
/// 与 [readExtensionsEnabledFlags] 的语义保持一致：读不出来 = 当"全启用"
/// （目录里有真实文件，只是限制读不到）。
Map<String, bool> _readEnabledSync(Directory root) {
  final File file = File(p.join(root.path, kExtensionsStateFileName));
  if (!file.existsSync()) return <String, bool>{};
  try {
    final Object? json = jsonDecode(file.readAsStringSync());
    if (json is! Map) return <String, bool>{};
    final Object? extensions = json['extensions'];
    if (extensions is! Map) return <String, bool>{};
    return <String, bool>{
      for (final MapEntry<Object?, Object?> entry in extensions.entries)
        if (entry.value is Map && (entry.value as Map)['enabled'] is bool)
          '${entry.key}': (entry.value as Map)['enabled'] as bool,
    };
  } catch (error) {
    debugPrint('[picture] state.json 读不出来（按"全部启用"处理）：$error');
    return <String, bool>{};
  }
}

PicturePack? _packOf(Directory dir, String id, Set<String> hiddenPresetIds) {
  final File manifestFile = File(p.join(dir.path, 'manifest.json'));
  if (!manifestFile.existsSync()) return null;
  final Object? json;
  try {
    json = jsonDecode(manifestFile.readAsStringSync());
  } catch (error) {
    debugPrint('[picture] 跳过 $id：manifest.json 不是合法 JSON（$error）');
    return null;
  }
  final core.ManifestParseResult parsed =
      core.parseExtensionManifest(json, currentAppVersion: kAppVersion.toString());
  if (!parsed.ok) {
    debugPrint('[picture] 跳过 $id：清单不合法（${parsed.issues.join('；')}）');
    return null;
  }
  final core.ExtensionManifest manifest = parsed.manifest!;
  if (manifest.id != id) {
    debugPrint('[picture] 跳过 $id：目录名与清单 id「${manifest.id}」不一致');
    return null;
  }
  final core.PictureSpec? parsedSpec = manifest.picture;
  if (manifest.kind != core.ExtensionKind.picturePack || parsedSpec == null) {
    debugPrint('[picture] 跳过 $id：类型「${manifest.kind}」不是画面调节包');
    return null;
  }
  // 用户关掉的预设（扩展页 →「设置」）在这里就摘掉：菜单不列它、控制器也不会把它
  // 当"第一个预设"去套。过滤得越早，后面每一层都不用知道这件事。
  final core.PictureSpec spec = parsedSpec.withoutPresets(hiddenPresetIds);

  final File templateFile = File(p.join(dir.path, spec.template));
  if (!templateFile.existsSync()) {
    debugPrint('[picture] 跳过 $id：模板文件不存在（${spec.template}）');
    return null;
  }
  final String template;
  try {
    template = templateFile.readAsStringSync();
  } catch (error) {
    debugPrint('[picture] 跳过 $id：模板读不出来（$error）');
    return null;
  }
  // 先空跑一次渲染：模板里有未声明占位符的包直接不列出来（装上却点不动更糟）。
  final List<core.ParsedTemplateIssue> issues = <core.ParsedTemplateIssue>[];
  final String? probe = core.renderPictureShader(
    template: template,
    spec: spec,
    values: spec.defaults,
    issues: issues,
  );
  if (probe == null) {
    debugPrint('[picture] 跳过 $id：模板渲染不出来（${issues.join('；')}）');
    return null;
  }

  return PicturePack(
    id: manifest.id,
    name: manifest.name,
    version: manifest.version,
    spec: spec,
    template: template,
    dir: dir,
  );
}

/// 按取值把模板渲染成最终 GLSL；模板有问题时返回 null（原因写进 [debugPrint]）。
String? renderPackShader(
  PicturePack pack,
  Map<String, double> values, {
  bool quiet = false,
}) {
  final List<core.ParsedTemplateIssue> issues = <core.ParsedTemplateIssue>[];
  final String? text = core.renderPictureShader(
    template: pack.template,
    spec: pack.spec,
    values: values,
    issues: issues,
  );
  // "声明了但模板没用"只是提醒，不阻止渲染（text 仍非 null）；
  // 真正的错（模板里出现未声明的占位符）会让 text 为 null。
  if (text == null) {
    if (!quiet) debugPrint('[picture] ${pack.id} 渲染失败（${issues.join('；')}）');
    return null;
  }
  for (final core.ParsedTemplateIssue issue in issues) {
    if (!quiet) debugPrint('[picture] ${pack.id}: $issue');
  }
  return text;
}

/// 确保"这份取值"的 GLSL 已经在缓存目录里，返回它的**绝对路径**。
///
/// 文件名由 `core.pictureCacheKey` 决定（扩展 id + 版本 + 排序后的取值）；
/// 已经存在就直接复用 —— 拖滑杆来回滑不会把缓存目录堆满。
Future<String?> ensureRenderedShader({
  required PicturePack pack,
  required Map<String, double> values,
  required Directory cacheDir,
  bool quiet = false,
}) async {
  final Map<String, double> resolved = pack.spec.normalizeValues(values);
  final String key = core.pictureCacheKey(
    extensionId: pack.id,
    extensionVersion: pack.version,
    values: resolved,
  );
  final String fileName =
      core.pictureCacheFileName(extensionId: pack.id, cacheKey: key);
  final File file = File(p.join(cacheDir.path, fileName));
  if (file.existsSync()) return file.path;

  final String? text = renderPackShader(pack, resolved, quiet: quiet);
  if (text == null) return null;
  try {
    cacheDir.createSync(recursive: true);
    // 原子写：先写 .tmp 再 rename。mpv 是**另一个进程**在读这个文件，
    // 半截文件会被它当成坏 shader 静默跳过（画面不变、日志里也没有）。
    final File tmp = File('${file.path}.tmp');
    await tmp.writeAsString(text, flush: true);
    await tmp.rename(file.path);
  } catch (error) {
    if (!quiet) debugPrint('[picture] 写缓存失败（$error）：${file.path}');
    return null;
  }
  return file.path;
}

/// 「画面调节」当前的取值与选择。
///
/// 这一片 json 就是 `<数据根>/dsanima/picture-settings.json` 的全部内容
/// （写盘在 `picture_settings_io.dart`，读它的是播放子窗口开窗那一步）：
/// 关掉播放窗口 / 重启程序之后，画面上还是上次调好的样子。
@immutable
class PictureSettings {
  const PictureSettings({
    this.packId,
    this.presetId,
    this.values = const <String, double>{},
  });

  /// 当前包 id（null = 没开画面调节）。
  final String? packId;

  /// 当前预设 id（null = 手调/没有预设）。
  final String? presetId;

  /// 参数取值（只存与默认不同的项也可以，但存全量更好排错）。
  final Map<String, double> values;

  static const PictureSettings off = PictureSettings();

  bool get isOff => packId == null;

  PictureSettings copyWith({
    String? packId,
    String? presetId,
    Map<String, double>? values,
    bool clearPack = false,
    bool clearPreset = false,
  }) =>
      PictureSettings(
        packId: clearPack ? null : (packId ?? this.packId),
        presetId: clearPreset ? null : (presetId ?? this.presetId),
        values: values ?? this.values,
      );

  Map<String, Object?> toJson() => <String, Object?>{
        if (packId != null) 'pack': packId,
        if (presetId != null) 'preset': presetId,
        if (values.isNotEmpty)
          'values': <String, Object?>{
            for (final MapEntry<String, double> e in values.entries) e.key: e.value,
          },
      };

  /// 从 json 读；**任何一项不合法都不抛**（旧版本/手改文件只该退化，不该让播放器起不来）。
  static PictureSettings fromJson(Object? json) {
    if (json is! Map) return off;
    final Object? pack = json['pack'];
    final Object? preset = json['preset'];
    final Object? rawValues = json['values'];
    final Map<String, double> values = <String, double>{};
    if (rawValues is Map) {
      for (final MapEntry<Object?, Object?> e in rawValues.entries) {
        final Object? v = e.value;
        if (v is num) values['${e.key}'] = v.toDouble();
      }
    }
    return PictureSettings(
      packId: pack is String && pack.isNotEmpty ? pack : null,
      presetId: preset is String && preset.isNotEmpty ? preset : null,
      values: Map<String, double>.unmodifiable(values),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is PictureSettings &&
      other.packId == packId &&
      other.presetId == presetId &&
      mapEquals(other.values, values);

  @override
  int get hashCode => Object.hash(packId, presetId, values.length);

  @override
  String toString() => 'PictureSettings(pack=$packId preset=$presetId '
      'values=$values)';
}

/// 画面调节的运行时状态机：选包/选预设/改滑杆 → 重渲染 → 挂给 [Anime4kController]。
///
/// 它不是 provider 本身（挂在哪一层由接线处决定），但**所有下发都在这里**：
/// 调用方只管改状态、然后 `await apply()`；失败时回到"什么都不挂"，绝不假装生效。
class PictureController extends ChangeNotifier {
  PictureController({
    required Anime4kController player,
    required Directory shaderCacheDir,
    List<PicturePack> packs = const <PicturePack>[],
    PictureSettings settings = PictureSettings.off,
    this.onChanged,
  })  : _anime4k = player,
        _cacheDir = shaderCacheDir,
        _packs = List<PicturePack>.unmodifiable(packs),
        _settings = _normalize(settings, packs),
        _values = _valuesFor(_normalize(settings, packs), packs);

  final Anime4kController _anime4k;
  final Directory _cacheDir;

  /// 状态被"落定"之后的通知（宿主用它写 `<数据根>/dsanima/picture-settings.json`）。
  ///
  /// 为什么是回调而不是在这里直接读写文件：这个类已经要在测试里被几十次构造，
  /// 让它碰磁盘就得每次造临时目录、还要防并发；写盘是**装配点**的事，这里只负责
  /// "什么时候该存"（每次真正下发之后）。回调自己不许抛（本类会吞掉，见 [_persist]）。
  final Future<void> Function(PictureSettings settings)? onChanged;

  List<PicturePack> _packs;
  PictureSettings _settings;

  /// 当前的完整取值（= 包默认值 + 设置里覆盖的项，已夹到区间内）。
  Map<String, double> _values = const <String, double>{};

  List<PicturePack> get packs => _packs;

  PictureSettings get settings => _settings;

  Map<String, double> get values => _values;

  bool get isOff => _settings.isOff;

  PicturePack? get currentPack {
    final String? id = _settings.packId;
    if (id == null) return null;
    for (final PicturePack pack in _packs) {
      if (pack.id == id) return pack;
    }
    return null;
  }

  /// 换清单（装/卸扩展之后调）。当前选中的包没了 → 回关并把叠加链清掉。
  ///
  /// 这是**异步**的：清链要下发。返回 true 表示发生了回退（界面要提示）。
  Future<bool> setPacks(List<PicturePack> packs) async {
    _packs = List<PicturePack>.unmodifiable(packs);
    final PictureSettings next = _normalize(_settings, _packs);
    final bool reset = next.isOff && !_settings.isOff;
    if (next != _settings || reset) {
      _settings = next;
      _values = _valuesOf(next);
      notifyListeners();
      await apply();
    }
    return reset;
  }

  /// 选一个包（[presetId] 为空 = 用它的默认值/第一个预设）。
  Future<void> selectPack(String packId, {String? presetId}) async {
    final PicturePack? pack = _packOf(packId);
    if (pack == null) return;
    final core.PicturePreset? preset = presetId == null
        ? (pack.hasPresets ? pack.spec.presets.first : null)
        : _presetOf(pack, presetId);
    final Map<String, double> base = preset == null
        ? pack.spec.defaults
        : pack.spec.valuesOf(preset);
    await applySettings(PictureSettings(
      packId: pack.id,
      presetId: preset?.id,
      values: base,
    ));
  }

  /// 套预设（同一包内的档位）。
  Future<void> applyPreset(String presetId) async {
    final PicturePack? pack = currentPack;
    if (pack == null) return;
    final core.PicturePreset? preset = _presetOf(pack, presetId);
    if (preset == null) return;
    await applySettings(PictureSettings(
      packId: pack.id,
      presetId: preset.id,
      values: pack.spec.valuesOf(preset),
    ));
  }

  /// 把一份设置**一次性**落到"状态 + 取值 + 渲染 + 挂链"。
  ///
  /// 这是播放窗口唯一的下发入口：`selectPack` / `applyPreset` / `turnOff` 全部收敛到它
  /// 上面（spec §6：不新增第二套下发路径）。播放窗口收到主窗口的 `pictureChanged` 时
  /// 读出来的也是 `PictureSettings`，走同一个函数 —— 于是"页面调的"和"右键调的"落在
  /// 同一条链上，不会出现两种行为。
  ///
  /// **永久不抛**：调用方是跨窗口消息处理器与界面动作，任何一次失败都只该"什么都不挂"
  /// （画面回到只有超分），绝不能让播放窗口崩掉。
  Future<void> applySettings(PictureSettings next) async {
    try {
      // 包没了 / 参数变了：一律按当前清单对齐（与 `setPacks` 同一套 `_normalize`）。
      _settings = _normalize(next, _packs);
      _values = _valuesOf(_settings);
      notifyListeners();
      await apply();
    } catch (error, stack) {
      debugPrint('[picture] 应用画面设置失败（这次算了，画面回到只有超分）：$error\n$stack');
    }
  }

  /// 改一个滑杆（夹值 + 量化在 `PictureParam.clampValue` 里，界面不用自己算）。
  ///
  /// 只改状态：拖滑杆时由调用方决定何时 [apply]（每帧重渲染+重挂不现实，
  /// 松手/防抖后再调）。返回值是真正生效的值（可能被夹过）。
  double setValue(String key, double value) {
    // 面板在「关」状态下也能拖：第一次拖就把第一个包选起来（值取默认再被这次覆盖），
    // 否则用户会遇到"滑杆能拖但没反应"——正是这类交互最让人困惑的形态。
    if (currentPack == null && _packs.isNotEmpty) {
      _settings = PictureSettings(
        packId: _packs.first.id,
        values: _packs.first.spec.defaults,
      );
      _values = _valuesOf(_settings);
    }
    final PicturePack? pack = currentPack;
    final core.PictureParam? param = pack?.spec.paramByKey(key);
    if (pack == null || param == null) return value;
    final double clamped = param.clampValue(value);
    final Map<String, double> next = <String, double>{..._settings.values, key: clamped};
    // 手调之后就不再算"某个预设"了（预设是一组固定取值，改一项就不再是它）。
    _settings = PictureSettings(packId: pack.id, values: next);
    _values = _valuesOf(_settings);
    notifyListeners();
    return clamped;
  }

  /// 把当前取值渲染成文件并挂上去。任何时候都不该抛（坏模板 = 回落到不挂）。
  ///
  /// 成功或失败都算"这一次定下来了"：两种结果都会 [onChanged]（写盘）。失败时存下来的
  /// 仍是用户**想要**的取值 —— 模板坏了是包的问题，下次开窗重试渲染才对；存成"关"
  /// 等于把用户调好的东西静默丢掉。
  Future<void> apply() async {
    final PicturePack? pack = currentPack;
    if (pack == null) {
      await clear();
      await _persist();
      return;
    }
    final String? path = await ensureRenderedShader(
      pack: pack,
      values: _settings.values,
      cacheDir: _cacheDir,
    );
    if (path == null) {
      // 渲染失败：宁可什么都不挂（画面回到"只有超分"），也不挂半截东西。
      await clear();
      await _persist();
      return;
    }
    _anime4k.setExtraChain(<String>[path]);
    await _anime4k.reapply();
    await _persist();
  }

  /// 关掉画面调节：清叠加链并重下发（超分方案保持不动）。
  Future<void> clear() async {
    _anime4k.setExtraChain(const <String>[]);
    await _anime4k.reapply();
  }

  /// 关掉画面调节**并且**把状态回到 off（界面上的「关」）。
  ///
  /// 与另外两条一样收敛到 [applySettings]：`apply()` 在没有当前包时会清链，
  /// 所以"关"= 一份空的设置 + 一次下发 + 一次落盘。
  Future<void> turnOff() => applySettings(PictureSettings.off);

  /// 把当前设置交给宿主（写盘）。回调失败只记日志 —— 存不下来不该让画面调节崩掉。
  Future<void> _persist() async {
    final Future<void> Function(PictureSettings settings)? callback = onChanged;
    if (callback == null) return;
    try {
      await callback(_settings);
    } catch (error) {
      debugPrint('[picture] 画面设置没存下来（这次算了）：$error');
    }
  }

  PicturePack? _packOf(String id) {
    for (final PicturePack pack in _packs) {
      if (pack.id == id) return pack;
    }
    return null;
  }

  core.PicturePreset? _presetOf(PicturePack pack, String id) {
    for (final core.PicturePreset preset in pack.spec.presets) {
      if (preset.id == id) return preset;
    }
    return null;
  }

  Map<String, double> _valuesOf(PictureSettings settings) {
    final PicturePack? pack = currentPackFor(settings.packId);
    if (pack == null) return const <String, double>{};
    return pack.spec.normalizeValues(settings.values);
  }

  /// 按 id 找包（[currentPack] 用的是当前 settings，这里允许传别的 id）。
  PicturePack? currentPackFor(String? id) {
    if (id == null) return null;
    return _packOf(id);
  }

  /// 构造期用：按设置算出完整取值（构造器初始化列表里不能调实例方法）。
  static Map<String, double> _valuesFor(
    PictureSettings settings,
    List<PicturePack> packs,
  ) {
    final String? id = settings.packId;
    if (id == null) return const <String, double>{};
    for (final PicturePack pack in packs) {
      if (pack.id == id) return pack.spec.normalizeValues(settings.values);
    }
    return const <String, double>{};
  }

  /// 把一份可能过期的设置对齐到当前清单：包没了 → off；参数少了/多了 → 用默认值补。
  static PictureSettings _normalize(
    PictureSettings settings,
    List<PicturePack> packs,
  ) {
    if (settings.isOff) return settings;
    PicturePack? pack;
    for (final PicturePack candidate in packs) {
      if (candidate.id == settings.packId) {
        pack = candidate;
        break;
      }
    }
    if (pack == null) return PictureSettings.off;
    return PictureSettings(
      packId: pack.id,
      presetId: settings.presetId,
      values: pack.spec.normalizeValues(settings.values),
    );
  }
}
