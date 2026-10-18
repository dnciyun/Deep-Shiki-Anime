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
  }) : _controller = source;

  final PictureController _controller;

  /// 数据根（`reload()` 要重新扫扩展目录 + 读用户设置）。null = 不重扫（测试/装配缺失）。
  final Directory? supportDir;

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
      for (final PicturePack pack in _controller.packs)
        for (final core.PicturePreset preset in pack.spec.presets)
          PicturePresetInfo(
            id: pictureCompositePresetId(pack.id, preset.id),
            name: multi ? '${pack.name} · ${preset.name}' : preset.name,
          ),
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
    if (_controller.currentPack?.id != parsed.packId) {
      await _controller.selectPack(parsed.packId, presetId: parsed.presetId);
      return;
    }
    await _controller.applyPreset(parsed.presetId);
  }

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
    } catch (error) {
      debugPrint('[picture] 重扫画面调节包失败（菜单保持旧清单）：$error');
    }
  }
}
