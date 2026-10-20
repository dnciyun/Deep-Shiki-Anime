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
    this.preamp = 0,
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
///
/// [intensity]（0–100，100 = 包里的原值）：只按比例缩放 10 段 EQ 的增益。
/// **预增益不参与缩放** —— 那正是 2026-10-19「改的音效没效果，都是把声音变小了」
/// 那个事故的形状；这里再跟着缩一次，用户把强度从 100% 拖到 60% 就会听到
/// 音效没变多少、音量先掉下去，旋钮的语义就退化成"音量"了。
String audioFxFilterSpec(
  AudioFxPreset? preset, {
  int compression = 0,
  int loudness = 0,
  int intensity = 100,
}) {
  if (preset == null) return '';
  // 夹一次再除：滑杆之外的来源（老配置手改、跨窗口传值）也可能给出 250 / -5，
  // 让越界值在这里停下，比在链里拼出 g=52.5 再由 mpv 报错要稳。
  final double scale = intensity.clamp(0, 100) / 100;
  final List<String> parts = <String>[];
  for (final String band in kAudioFxBands) {
    final int freq = kAudioFxBandFrequencies[band]!;
    final double gain = _clamp(preset.bands[band] ?? 0, kAudioFxBandMin, kAudioFxBandMax);
    // 只缩 EQ：0% 时 EQ 平直（0 dB）但压缩 / 均衡 / 限幅照旧，所以"0%"不是静音。
    // 同时缩放仍落在 ±12 dB 内，不需要二次夹值。
    parts.add('equalizer=f=$freq:width_type=o:width=1:g=${_num(gain * scale)}');
  }
  final double preamp = _clamp(preset.preamp, kAudioFxPreampMin, kAudioFxPreampMax);
  // 0 dB 不写 `volume`：链短一条、也避免「预增益吃掉抬升」那种听感事故
  // （用户 2026-10-19：「改的音效没效果，都是把声音变小了」——根因就是这里有 -3.5dB）。
  if (preamp != 0) parts.add('volume=${_num(preamp)}dB');
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

// ── 状态（总开关 / 当前档 / 两个全局强度）─────────────────────────────────────

/// 音效的五项状态：总开关、当前档 id、对白压缩强度、音量均衡强度、总强度。
///
/// 全局一档（用户 2026-10-19 决定）：不是每部番各自记，切一次全局生效。
class AudioFxState {
  const AudioFxState({
    this.enabled = false,
    this.presetId,
    this.compression = 0,
    this.loudness = 0,
    this.intensity = 100,
  });

  final bool enabled;
  final String? presetId;
  final int compression;
  final int loudness;

  /// 总强度 0–100（100 = 包里的原值，只缩 EQ、不缩预增益；0 = EQ 平直但压缩照旧）。
  ///
  /// 默认 100 而不是 0：老的 `audio-fx.json` 没有这个字段时读成 100，
  /// 否则升级一次所有人的音效都会"突然变小"（spec Review Focus 第 5 条）。
  final int intensity;

  AudioFxState copyWith({
    bool? enabled,
    String? presetId,
    int? compression,
    int? loudness,
    int? intensity,
    bool clearPreset = false,
  }) =>
      AudioFxState(
        enabled: enabled ?? this.enabled,
        presetId: clearPreset ? null : (presetId ?? this.presetId),
        compression: compression ?? this.compression,
        loudness: loudness ?? this.loudness,
        // 不传 = 保持：播放窗口右键切档走的是 copyWith，强度是主窗口页面上的设置，
        // 切一档就把它冲回 100% 会让"页面调的"和"右键切的"互相打架。
        intensity: intensity ?? this.intensity,
      );

  @override
  bool operator ==(Object other) =>
      other is AudioFxState &&
      other.enabled == enabled &&
      other.presetId == presetId &&
      other.compression == compression &&
      other.loudness == loudness &&
      other.intensity == intensity;

  @override
  int get hashCode => Object.hash(enabled, presetId, compression, loudness, intensity);

  @override
  String toString() =>
      'AudioFxState(enabled=$enabled, preset=$presetId, compression=$compression, '
      'loudness=$loudness, intensity=$intensity)';

  /// 跨窗口传值用（主窗口 → 播放窗口走 args / method channel，都是纯 JSON）。
  Map<String, Object?> toJson() => <String, Object?>{
        'enabled': enabled,
        if (presetId != null) 'presetId': presetId,
        'compression': compression,
        'loudness': loudness,
        'intensity': intensity,
      };

  static AudioFxState fromJson(Object? raw) {
    if (raw is! Map) return const AudioFxState();
    final Object? enabled = raw['enabled'];
    final Object? presetId = raw['presetId'];
    final Object? compression = raw['compression'];
    final Object? loudness = raw['loudness'];
    final Object? intensity = raw['intensity'];
    return AudioFxState(
      enabled: enabled is bool && enabled,
      presetId: presetId is String && presetId.isNotEmpty ? presetId : null,
      compression: compression is int ? compression.clamp(0, 3) : 0,
      loudness: loudness is int ? loudness.clamp(0, 3) : 0,
      // 缺字段 ⇒ 100（老配置语义不变）；越界 ⇒ 夹到 0–100 而不是丢掉整份设置。
      intensity: intensity is num ? intensity.round().clamp(0, 100) : 100,
    );
  }
}

/// 按状态挑出当前该下发的 `af` 串：关着 / 档位不存在 → 空串（原声）。
String audioFxActiveSpec({
  required List<AudioFxPreset> presets,
  required AudioFxState state,
}) {
  if (!state.enabled) return '';
  AudioFxPreset? preset;
  for (final AudioFxPreset candidate in presets) {
    if (candidate.id == state.presetId) {
      preset = candidate;
      break;
    }
  }
  if (preset == null) return '';
  return audioFxFilterSpec(
    preset,
    compression: state.compression,
    loudness: state.loudness,
    // 总强度是**状态的一部分**：调用方（页面 / 播放器）不该各自记得再传一次，
    // 少传一处就会变成"页面显示 40%，实际按 100% 放"。
    intensity: state.intensity,
  );
}

// ── 持久化键（播放器 store；宿主 bootstrap 读写）──────────────────────────────

const String kAudioFxEnabledStoreKey = 'audio-fx-enabled';
const String kAudioFxPresetStoreKey = 'audio-fx-preset';
const String kAudioFxCompressionStoreKey = 'audio-fx-compression';
const String kAudioFxLoudnessStoreKey = 'audio-fx-loudness';

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
