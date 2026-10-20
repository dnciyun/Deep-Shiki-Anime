/// `PictureMenu`（shikiin 侧接口）的宿主实现：把 `PictureController` 翻译成播放器
/// 右键菜单/滑杆面板能直接用的只读视图。
///
/// 为什么分成"接口在 shikiin、实现在 app"：shikiin 不认识 `dsanima_core` 的扩展清单
/// 格式（`PictureSpec`/模板渲染/缓存键都在宿主），它只需要"有哪些包/预设、当前值多少、
/// 改完调谁"。这条分界和 `extraSchemes` 完全一致 —— 翻译层留在宿主。
library;

import 'dart:io';

import 'package:dsanima_core/dsanima_core.dart' as core;
import 'package:flutter/foundation.dart';
import 'package:shikiin/shikiin.dart';

import '../domain/picture_combo.dart';
import 'extension_settings.dart';
import 'picture_pack.dart';

/// 把「包 id / 预设 id」拼成菜单里唯一的组合 id。
String pictureCompositePresetId(String packId, String presetId) => '$packId/$presetId';

/// 拆组合 id；格式不对返回 null（菜单里的值是宿主自己造的，但别假设它一定对）。
({String packId, String presetId})? parsePictureCompositeId(String id) {
  final int slash = id.indexOf('/');
  if (slash <= 0 || slash >= id.length - 1) return null;
  return (packId: id.substring(0, slash), presetId: id.substring(slash + 1));
}

class PictureMenuAdapter implements PictureMenu {
  PictureMenuAdapter({
    required PictureController source,
    this.supportDir,
    Map<String, List<PictureCombo>>? combos,
  })  : _controller = source,
        _combos = combos ?? const <String, List<PictureCombo>>{};

  final PictureController _controller;

  /// 数据根（`reload()` 要重新扫扩展目录 + 读用户设置）。null = 不重扫（测试/装配缺失）。
  final Directory? supportDir;

  /// 「我的组合」（按包分组）。播放窗口在收到 `pictureChanged` 时重新读盘并
  /// [setCombos] —— 主窗口里刚存的组合要能立刻出现在右键菜单里。
  Map<String, List<PictureCombo>> _combos;

  /// 换一批组合（不重扫包：组合文件与扩展目录是两件事）。
  void setCombos(Map<String, List<PictureCombo>> combos) => _combos = combos;

  /// 菜单/面板绑定的包：优先当前选中的，没选中（关着）就用第一个。
  PicturePack? get _pack {
    final PicturePack? current = _controller.currentPack;
    if (current != null) return current;
    return _controller.packs.isEmpty ? null : _controller.packs.first;
  }

  @override
  String get packName => _pack?.name ?? '';

  @override
  List<PictureParamInfo> get params {
    final PicturePack? pack = _pack;
    if (pack == null) return const <PictureParamInfo>[];
    return <PictureParamInfo>[
      for (final core.PictureParam p in pack.spec.params)
        PictureParamInfo(
          key: p.key,
          label: p.label,
          min: p.min,
          max: p.max,
          step: p.step,
          defaultValue: p.defaultValue,
          group: p.group,
          unit: p.unit,
        ),
    ];
  }

  @override
  List<PicturePresetInfo> get presets {
    // 多包才拼包名（菜单里只放名称，说明文字放扩展页）：单包时六档预设各带一次
    // 「清晰增强 · 」前缀纯属噪音。
    final bool multi = _controller.packs.length > 1;
    return <PicturePresetInfo>[
      for (final PicturePack pack in _controller.packs) ...<PicturePresetInfo>[
        for (final core.PicturePreset preset in pack.spec.presets)
          PicturePresetInfo(
            id: pictureCompositePresetId(pack.id, preset.id),
            name: multi ? '${pack.name} · ${preset.name}' : preset.name,
          ),
        // 用户自己存的组合紧跟在**它那个包**的预设后面：菜单是一层扁平列表，
        // 靠「我的 · 」前缀做分组（spec §6：不改 shikiin 的菜单接口、不加子菜单层级）。
        for (final PictureCombo combo in _combos[pack.id] ?? const <PictureCombo>[])
          PicturePresetInfo(
            id: pictureComboIdOf(pack.id, combo.id),
            name: multi ? '${pack.name} · 我的 · ${combo.name}' : '我的 · ${combo.name}',
          ),
      ],
    ];
  }

  @override
  String? get activePresetId {
    final PicturePack? pack = _controller.currentPack;
    final String? presetId = _controller.settings.presetId;
    if (pack == null || presetId == null) return null;
    return pictureCompositePresetId(pack.id, presetId);
  }

  @override
  bool get isOff => _controller.isOff;

  @override
  double valueOf(String key) {
    final PicturePack? pack = _pack;
    final double? value = _controller.values[key];
    if (value != null) return value;
    return pack?.spec.paramByKey(key)?.defaultValue ?? 0;
  }

  @override
  Future<void> turnOff() => _controller.turnOff();

  @override
  Future<void> selectPreset(String? presetId) async {
    if (presetId == null) return _controller.turnOff();
    final ({String packId, String presetId})? parsed =
        parsePictureCompositeId(presetId);
    if (parsed == null) return;
    // 自定义组合（`<包>/custom:<组合>`）：不是包自带预设，取值得去 combos 里找。
    if (parsed.presetId.startsWith(kPictureComboPrefix)) {
      await _selectCombo(parsed.packId, parsed.presetId.substring(kPictureComboPrefix.length));
      return;
    }
    if (_controller.currentPack?.id != parsed.packId) {
      await _controller.selectPack(parsed.packId, presetId: parsed.presetId);
      return;
    }
    await _controller.applyPreset(parsed.presetId);
  }

  /// 套一个「我的组合」。
  ///
  /// 组合可能已经被主窗口删掉（菜单是上一次打开时建的）：那时**什么都不做**，
  /// 既不能猜一套取值、也不能当成"关"（用户只是想套一个已经没了的搭配）。
  Future<void> _selectCombo(String packId, String comboId) async {
    PictureCombo? combo;
    for (final PictureCombo candidate in _combos[packId] ?? const <PictureCombo>[]) {
      if (candidate.id == comboId) {
        combo = candidate;
        break;
      }
    }
    if (combo == null) return;
    final PicturePack? pack = _controller.currentPackFor(packId);
    if (pack == null) return;
    // 走 `applySettings` 而不是 `selectPack`：后者会套上"第一个预设"，把组合的取值盖掉。
    // `presetId` 记成 `custom:<id>`，菜单/面板才知道现在亮着的是这一套组合。
    await _controller.applySettings(PictureSettings(
      packId: pack.id,
      presetId: '$kPictureComboPrefix$comboId',
      values: pack.spec.normalizeValues(combo.values),
    ));
  }

  /// 把一份设置直接下发（播放窗口收到 `pictureChanged` 时用）。
  ///
  /// 为什么不塞进 [reload]：那条会重扫扩展目录（装/卸包才需要），而这里只是"取值变了"，
  /// 重扫是没有必要的开销，还会把正在播的那一帧重挂两次。
  Future<void> applySettings(PictureSettings next) => _controller.applySettings(next);

  @override
  Future<void> selectPack(String packId, {String? presetId}) =>
      _controller.selectPack(packId, presetId: presetId);

  @override
  void setValue(String key, double value) {
    _controller.setValue(key, value);
  }

  @override
  Future<void> applyValues() => _controller.apply();

  /// 重扫：重新读用户设置（关掉的预设）与扩展目录，把包清单换进去。
  ///
  /// 语义与开播放窗口那次扫描**完全一致**（同一个 `loadPicturePacks` + 同一份设置文件），
  /// 所以"重开窗口"和"点通知让窗口重扫"得到的是一份结果。
  /// **永不抛**：扫不出来最坏是菜单保持旧清单，不能把播放窗口弄崩。
  @override
  Future<void> reload() async {
    final Directory? dir = supportDir;
    if (dir == null) return;
    try {
      final core.ExtensionUserSettings settings = await loadExtensionUserSettings(dir);
      final List<PicturePack> packs =
          await loadPicturePacks(dir, hiddenPresets: settings.hiddenPresets);
      await _controller.setPacks(packs);
      // `setPacks` 只在"设置变了"的时候才重下发；而**包换了版本**（清单里同 id、
      // version 变了）时设置可以完全一样 —— 那种情况它不会 apply，播放器就一直挂着
      // 旧版本渲染出来的那份 shader（缓存文件名带版本号）。扩展变更本来就该"以新为准"，
      // 这里无条件再下发一次：没有包时 `apply()` 自己会清链，正好覆盖卸载。
      await _controller.apply();
    } catch (error) {
      debugPrint('[picture] 重扫画面调节包失败（菜单保持旧清单）：$error');
    }
  }
}
