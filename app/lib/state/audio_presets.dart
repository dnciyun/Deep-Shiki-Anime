/// 音效面（`player.audio`）的 consumer：扩展包 → 播放器认识的一组音效档。
///
/// 一条链：`scanGenericPacks()` 扫出通用包 → 本类只挑 `payload.surface ==
/// 'player.audio'` 的包 → 把每个预设的 `values`（已按面 schema 校验/归一化）翻成
/// `shikiin.AudioFxPreset` → 回调交给播放窗口（写 notifier，右键菜单/设置面板读它）。
///
/// 两条不撒谎的口径（与字幕面同源）：
/// * **未知面/空包的包一个都不喂**：播放器不认识的面不冒充能用；
/// * **缺项按默认值**：10 段缺的按 0、`preamp` 缺省 -3、`crossfeed` 缺省 0 ——
///   与「不写就是不动这一路」的口径一致。
library;

import 'package:dsanima_core/dsanima_core.dart' as core;
import 'package:shikiin/shikiin.dart' as shikiin;

import '../domain/extension_consumers.dart';
import 'generic_packs.dart';

/// 音效面的 surface id（core 注册表里同一个字符串）。
const String kAudioSurfaceId = 'player.audio';

class AudioPresetConsumer implements ExtensionConsumer {
  AudioPresetConsumer({required this.onChanged});

  /// 每次「重新应用」后的完整档位清单（宿主把它写进播放窗口的 notifier）。
  final void Function(List<shikiin.AudioFxPreset>) onChanged;

  final List<String> _notes = <String>[];
  int _presetCount = 0;
  int _packCount = 0;

  /// 非致命问题的说明（诊断用；不影响档位本身）。
  List<String> get notes => List<String>.unmodifiable(_notes);

  /// 当前面有几个档位（日志/自检用）。
  int get presetCount => _presetCount;

  /// 一句话摘要（日志用）：`N 个音效档（来自 M 个包）`。
  String get summary => '$_presetCount 个音效档（来自 $_packCount 个包）';

  @override
  String get surface => kAudioSurfaceId;

  @override
  Future<void> setPacks(List<GenericPack> packs) async {
    _notes.clear();
    _presetCount = 0;
    _packCount = 0;

    final List<GenericPack> mine = packs
        .where((GenericPack pack) =>
            pack.payload.surface == surface && pack.payload.presets.isNotEmpty)
        .toList()
      ..sort((GenericPack a, GenericPack b) => a.id.compareTo(b.id));

    final List<shikiin.AudioFxPreset> presets = <shikiin.AudioFxPreset>[];
    for (final GenericPack pack in mine) {
      for (final core.GenericPreset preset in pack.payload.presets) {
        presets.add(audioFxPresetFromValues(
          // 包 id 参与拼装：同一个面装两个包时预设 id 不互相覆盖。
          id: '${pack.id}/${preset.id}',
          name: preset.name,
          description: preset.description,
          packId: pack.id,
          packName: pack.name,
          values: preset.values,
        ));
      }
    }
    _presetCount = presets.length;
    _packCount = mine.length;
    if (presets.isEmpty) {
      _notes.add('没有可用音效档：确认包是 audio-pack，且面写的是 player.audio');
    }
    onChanged(List<shikiin.AudioFxPreset>.unmodifiable(presets));
  }

  @override
  Future<void> revert() async {
    _notes.clear();
    _presetCount = 0;
    _packCount = 0;
    onChanged(const <shikiin.AudioFxPreset>[]);
  }

  @override
  String describe(GenericPack pack) => '${pack.payload.presets.length} 档音效';
}

/// 预设的 `values`（已按面 schema 归一化）→ `AudioFxPreset`。
///
/// 缺项一律回落默认值；数值原样带走，边界由播放器在拼链时再夹一次
/// （core 已在安装阶段拒掉越界值，这里防的是「旧包/手改的 state」）。
shikiin.AudioFxPreset audioFxPresetFromValues({
  required String id,
  required String name,
  String description = '',
  String packId = '',
  String packName = '',
  required Map<String, Object?> values,
}) {
  final Map<String, double> bands = <String, double>{};
  for (final String band in shikiin.kAudioFxBands) {
    final Object? raw = values[band];
    bands[band] = raw is num ? raw.toDouble() : 0;
  }
  final Object? preamp = values['preamp'];
  final Object? crossfeed = values['crossfeed'];
  return shikiin.AudioFxPreset(
    id: id,
    name: name,
    description: description,
    packId: packId,
    packName: packName,
    bands: Map<String, double>.unmodifiable(bands),
    preamp: preamp is num ? preamp.toDouble() : 0,
    crossfeed: crossfeed is num ? crossfeed.toDouble() : 0,
  );
}
