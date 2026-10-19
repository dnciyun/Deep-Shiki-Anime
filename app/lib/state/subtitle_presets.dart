/// 字幕面（`player.subtitle`）的 consumer：通用扩展包 → 播放器认识的字幕预设。
///
/// 一条链：`scanGenericPacks()` 扫出通用包 → 本类只挑 `payload.surface ==
/// 'player.subtitle'` 的包 → 注册 `assets` 里的字体（`FontLoader`）→ 把每个预设的
/// `values` 映射成 `shikiin.SubtitleStyle` → 回调交给播放窗口（写 notifier，设置面板读它）。
///
/// 两条不撒谎的口径：
/// * **字体加载失败不挡预设**：字体是锦上添花，失败只记 notes（界面/diag 能说清）；
/// * **未知 surface 的包一个都不喂**：播放器不认识的面不冒充能用。
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:dsanima_core/dsanima_core.dart' as core;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show FontLoader;
import 'package:path/path.dart' as p;
import 'package:shikiin/shikiin.dart' as shikiin;

import '../domain/extension_consumers.dart';
import 'generic_packs.dart';

/// 字幕面的 surface id（core 注册表里同一个字符串）。
const String kSubtitleSurfaceId = 'player.subtitle';

class SubtitlePresetConsumer implements ExtensionConsumer {
  SubtitlePresetConsumer({required this.onChanged});

  /// 每次「重新应用」后的完整预设清单（宿主把它写进播放窗口的 notifier）。
  final void Function(List<shikiin.SubtitlePreset>) onChanged;

  final List<String> _notes = <String>[];
  int _presetCount = 0;
  int _fontCount = 0;

  /// 字体加载失败等非致命问题的说明（诊断用；不影响预设）。
  List<String> get notes => List<String>.unmodifiable(_notes);

  /// 当前面有几个预设（日志/自检用）。
  int get presetCount => _presetCount;

  /// 一句话摘要（日志用）：`N 个字幕预设（M 个字体已加载）`。
  String get summary => '$_presetCount 个字幕预设（$_fontCount 个字体已加载）';

  @override
  String get surface => kSubtitleSurfaceId;

  @override
  Future<void> setPacks(List<GenericPack> packs) async {
    _notes.clear();
    _presetCount = 0;
    _fontCount = 0;

    final List<GenericPack> mine = packs
        .where((GenericPack pack) => pack.payload.surface == surface)
        .toList()
      ..sort((GenericPack a, GenericPack b) => a.id.compareTo(b.id));

    final List<shikiin.SubtitlePreset> presets = <shikiin.SubtitlePreset>[];
    for (final GenericPack pack in mine) {
      await _loadFonts(pack);
      for (final core.GenericPreset preset in pack.payload.presets) {
        presets.add(shikiin.SubtitlePreset(
          // 包 id 参与拼装：同一个面装两个包时预设 id 不互相覆盖。
          id: '${pack.id}/${preset.id}',
          name: preset.name,
          description: preset.description,
          style: subtitleStyleFromPresetValues(preset.values),
        ));
      }
    }
    _presetCount = presets.length;
    onChanged(List<shikiin.SubtitlePreset>.unmodifiable(presets));
  }

  @override
  Future<void> revert() async {
    _notes.clear();
    _presetCount = 0;
    _fontCount = 0;
    onChanged(const <shikiin.SubtitlePreset>[]);
  }

  @override
  String describe(GenericPack pack) {
    final int fonts =
        pack.payload.assets.where((core.GenericAsset a) => a.role == 'font').length;
    return '${pack.payload.presets.length} 个字幕预设（$fonts 个字体资产）';
  }

  /// 把包里的字体注册进当前引擎。
  ///
  /// 播放窗口是独立 Flutter 引擎：字体要在这里 `FontLoader` 注册，注册之后
  /// `SubtitleStyle.font` 写的 family 才解析得到。任何失败只进 notes。
  Future<void> _loadFonts(GenericPack pack) async {
    for (final core.GenericAsset asset in pack.payload.assets) {
      if (asset.role != 'font') continue;
      final File file = File(p.join(pack.dir.path, asset.path));
      try {
        final Uint8List bytes = await file.readAsBytes();
        final FontLoader loader = FontLoader(asset.family)
          ..addFont(Future<ByteData>.value(ByteData.sublistView(bytes)));
        await loader.load();
        _fontCount++;
      } catch (error) {
        _notes.add('字体「${asset.family}」没加载上（${asset.path}）：$error');
      }
    }
  }
}

/// 预设的 `values`（已按面 schema 归一化）→ `SubtitleStyle`。
///
/// 缺项一律回落到 `const SubtitleStyle()` 的默认值 —— 与「默认为初始参数」的
/// 既有口径一致；颜色已在 core 归一化成 `#AARRGGBB`。
shikiin.SubtitleStyle subtitleStyleFromPresetValues(Map<String, Object?> values) {
  const shikiin.SubtitleStyle base = shikiin.SubtitleStyle();
  return shikiin.SubtitleStyle(
    font: _stringOr(values, 'font', base.font),
    bold: _boolOr(values, 'bold', base.bold),
    italic: _boolOr(values, 'italic', base.italic),
    scale: _doubleOr(values, 'scale', base.scale),
    pos: _intOr(values, 'pos', base.pos),
    color: _stringOr(values, 'color', base.color),
    borderColor: _stringOr(values, 'borderColor', base.borderColor),
    borderSize: _doubleOr(values, 'borderSize', base.borderSize),
    shadowColor: _stringOr(values, 'shadowColor', base.shadowColor),
    shadowOffset: _doubleOr(values, 'shadowOffset', base.shadowOffset),
    backColor: values['backColor'] is String
        ? values['backColor'] as String
        : base.backColor,
  );
}

String _stringOr(Map<String, Object?> values, String key, String fallback) {
  final Object? value = values[key];
  return value is String && value.isNotEmpty ? value : fallback;
}

bool _boolOr(Map<String, Object?> values, String key, bool fallback) {
  final Object? value = values[key];
  return value is bool ? value : fallback;
}

double _doubleOr(Map<String, Object?> values, String key, double fallback) {
  final Object? value = values[key];
  return value is num ? value.toDouble() : fallback;
}

int _intOr(Map<String, Object?> values, String key, int fallback) {
  final Object? value = values[key];
  return value is num ? value.toInt() : fallback;
}
