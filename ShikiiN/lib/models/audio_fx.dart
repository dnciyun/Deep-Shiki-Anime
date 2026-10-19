/// 音效档位（扩展包 `audio-pack` / 面 `player.audio`）在播放器里的模型与 `af` 链构造。
///
/// 边界：包只给**有界数值**（10 段增益 ±12 dB、`preamp` -12~+6、`crossfeed` 0~1），
/// 链由播放器拼 —— 包写不进任意 lavfi。理由见 `docs/specs/2026-10-19-dsanima-audio-packs-design.md` §5。
///
/// 失败模式（探针实测）：`set af` 对写错的滤镜**也返回成功**，真正失败发生在滤镜
/// 初始化（`Audio filter initialized failed`，输出 0 字节 = 完全没声音）。所以链只能
/// 由这里拼、由单测钉死，运行期还要回读 + 降级（见 `PlayerController.applyAudioFx`）。
library;

/// 10 段频点（固定 ISO，键名与包里的 `values` 字段一一对应）。
const List<String> kAudioFxBands = <String>[
  'b31',
  'b63',
  'b125',
  'b250',
  'b500',
  'b1k',
  'b2k',
  'b4k',
  'b8k',
  'b16k',
];

/// 键名 → 频率（Hz）。EQ 用 `equalizer` 的峰值滤波器，`width_type=o` 每段一个倍频程。
const Map<String, int> kAudioFxBandFrequencies = <String, int>{
  'b31': 31,
  'b63': 63,
  'b125': 125,
  'b250': 250,
  'b500': 500,
  'b1k': 1000,
  'b2k': 2000,
  'b4k': 4000,
  'b8k': 8000,
  'b16k': 16000,
};

const double kAudioFxBandMin = -12;
const double kAudioFxBandMax = 12;
const double kAudioFxPreampMin = -12;
const double kAudioFxPreampMax = 6;

/// 压缩三档（0 = 关）。数值是起点，耳测后可调；调完必须改单测。
const List<String> _kCompressors = <String>[
  '',
  'acompressor=threshold=0.1:ratio=2:attack=20:release=250:makeup=1',
  'acompressor=threshold=0.07:ratio=3:attack=15:release=200:makeup=1.2',
  'acompressor=threshold=0.05:ratio=4:attack=10:release=150:makeup=1.4',
];

/// 音量均衡三档（0 = 关）。`dynaudnorm` 随动，不要求两遍扫描。
const List<String> _kLoudness = <String>[
  '',
  'dynaudnorm=framelen=250:maxgain=7:peak=0.9',
  'dynaudnorm=framelen=200:maxgain=9:peak=0.95',
  'dynaudnorm=framelen=150:maxgain=11:peak=0.97',
];

/// 保护限幅：**永远最后**，任何一档都爆不了音（不可关）。
const String _kLimiter = 'alimiter=limit=0.97';

/// 一个音效档位 —— 宿主从扩展包扫出来交给播放器的**已解析**模型。
class AudioFxPreset {
  const AudioFxPreset({
    required this.id,
    required this.name,
    this.description = '',
    this.packId = '',
    this.packName = '',
    this.bands = const <String, double>{},
    this.preamp = -3,
    this.crossfeed = 0,
  });

  /// 预设 id（面内唯一；宿主会拼成 `<包 id>/<预设 id>`）。
  final String id;

  /// 菜单/面板上显示的名字。
  final String name;

  /// 一句话说明。
  final String description;

  /// 来自哪个扩展包（多包同面时面板按包名分组）。
  final String packId;
  final String packName;

  /// 10 段增益（dB）；缺项按 0 处理。
  final Map<String, double> bands;

  /// 预增益（dB），默认 -3 留余量。
  final double preamp;

  /// 交叉馈电强度；0 = 不启用。
  final double crossfeed;

  @override
  String toString() => 'AudioFxPreset($id $name)';
}

/// 右键菜单里「音效」当前选中的是哪一项；`presetId == null` = 原声。
class AudioFxSelection {
  const AudioFxSelection(this.presetId);
  const AudioFxSelection.off() : presetId = null;

  final String? presetId;

  bool get isOff => presetId == null;

  @override
  bool operator ==(Object other) =>
      other is AudioFxSelection && other.presetId == presetId;

  @override
  int get hashCode => presetId.hashCode;
}

/// 拼 mpv `af` 属性的值；`preset == null` → 空串（原声，调用方负责清空）。
///
/// 形如：
/// `lavfi=[equalizer=f=31:width_type=o:width=1:g=-2,…,volume=-3.5dB,alimiter=limit=0.97]`
String audioFxFilterSpec(
  AudioFxPreset? preset, {
  int compression = 0,
  int loudness = 0,
}) {
  if (preset == null) return '';
  final List<String> parts = <String>[];
  for (final String band in kAudioFxBands) {
    final int freq = kAudioFxBandFrequencies[band]!;
    final double gain = _clamp(preset.bands[band] ?? 0, kAudioFxBandMin, kAudioFxBandMax);
    parts.add('equalizer=f=$freq:width_type=o:width=1:g=${_num(gain)}');
  }
  final double preamp = _clamp(preset.preamp, kAudioFxPreampMin, kAudioFxPreampMax);
  parts.add('volume=${_num(preamp)}dB');
  final double crossfeed = _clamp(preset.crossfeed, 0, 1);
  if (crossfeed > 0) {
    parts.add('crossfeed=strength=${_num(crossfeed)}:range=0.5:slope=0.5');
  }
  final String compressor = _level(_kCompressors, compression);
  if (compressor.isNotEmpty) parts.add(compressor);
  final String loudnessFilter = _level(_kLoudness, loudness);
  if (loudnessFilter.isNotEmpty) parts.add(loudnessFilter);
  parts.add(_kLimiter);
  return 'lavfi=[${parts.join(',')}]';
}

/// 下发/清空 `af` 的 mpv 命令（空串 = 清空 = 原声）。
///
/// 提成纯函数是为了离线测：`set af` 一旦把「空串」和「链」写反，表现是
/// 「关了音效却还有/开了没反应」而不是报错，真机很难定位。
List<String> audioFxFiltersCommand(String spec) => <String>['set', 'af', spec];

String _level(List<String> levels, int level) {
  if (level <= 0) return '';
  final int index = level >= levels.length ? levels.length - 1 : level;
  return levels[index];
}

double _clamp(double value, double min, double max) {
  if (value.isNaN) return min > 0 ? min : 0;
  if (value < min) return min;
  if (value > max) return max;
  return value;
}

/// 整数值输出成 `-3` / `12` / `0.35`（不带多余的 `.0`）。
String _num(double value) {
  if (value == value.roundToDouble()) return value.toStringAsFixed(0);
  return value.toStringAsFixed(2).replaceFirst(RegExp(r'0+$'), '');
}
