/// 可切换的超分**方案**（scheme）。
///
/// 用户 2026-10-17：「模型我想多试试其他的，只使用可以实时播放的，默认自带的是
/// anime4k」—— 于是把「超分」从「Anime4K 三档」扩成「方案 + 档位」：
///
/// * [UpscaleSchemeKind.anime4kChain]：内置 Anime4K，档位 = 轻/标/极（默认内置）；
/// * [UpscaleSchemeKind.mpvScaler]：mpv 自带缩放器，零下载、必实时（只改属性不挂 shader）；
/// * [UpscaleSchemeKind.glslPack]：第三方 GLSL 包（由扩展框架安装，目录 + 文件链）。
///
/// **只收实时方案**：VapourSynth / ONNX / Real-ESRGAN / waifu2x 这类逐帧神经网络
/// 不在此列（包里没有那些运行时，也做不到实时播放）。
library;

import 'anime4k_preset.dart';

/// 超分方案的实现类型。
enum UpscaleSchemeKind {
  /// 内置 Anime4K 的 shader 链（12 个 .glsl，按档位组链）。
  anime4kChain,

  /// mpv 内置缩放器：改 `scale` 等属性，不挂 shader、不下载任何文件。
  mpvScaler,

  /// 第三方 GLSL 包：目录 + 文件链（由扩展框架安装到 `models/`）。
  glslPack,
}

/// 方案里的一档。[files] 只有 shader 类方案用；mpvScaler 留空。
class UpscaleTier {
  final String id;
  final String label;
  final List<String> files;

  const UpscaleTier({required this.id, required this.label, this.files = const []});
}

/// 一套可实时播放的超分方案。
class UpscaleScheme {
  /// 稳定 id（也用于设置持久化；扩展包 id 由扩展清单给）。
  final String id;

  /// 菜单里的全名（如 `mpv · EWA Lanczos Sharp`）。
  final String name;

  /// 控制栏胶囊里的短名（如 `EWA锐`）。
  final String shortName;

  final UpscaleSchemeKind kind;

  /// shader 类方案的档位；mpvScaler 只有一档 `on`。
  final List<UpscaleTier> tiers;

  /// mpvScaler 要下发的属性（如 `{'scale': 'ewa_lanczossharp'}`）。
  final Map<String, String> properties;

  /// shader 目录（glslPack 用；anime4k 由启动流程注入 shaderDir）。
  final String? dir;

  /// 界面上的小字说明。
  final String? note;

  const UpscaleScheme({
    required this.id,
    required this.name,
    required this.shortName,
    required this.kind,
    this.tiers = const [],
    this.properties = const {},
    this.dir,
    this.note,
  });

  bool get isAnime4k => kind == UpscaleSchemeKind.anime4kChain;

  bool get usesShaders =>
      kind == UpscaleSchemeKind.anime4kChain || kind == UpscaleSchemeKind.glslPack;

  UpscaleTier? tierOf(String id) {
    for (final tier in tiers) {
      if (tier.id == id) return tier;
    }
    return null;
  }
}

/// 内置 Anime4K 方案的 id（也是「关」所在的方案：preset=off 即关）。
const String kAnime4kSchemeId = 'anime4k';

/// 内置 Anime4K 方案：档位就是 [Anime4kPreset.simpleTiers]，链走 `anime4kShaderChain`。
UpscaleScheme anime4kScheme() => UpscaleScheme(
      id: kAnime4kSchemeId,
      name: 'Anime4K',
      shortName: 'A4K',
      kind: UpscaleSchemeKind.anime4kChain,
      tiers: [
        for (final Anime4kPreset p in Anime4kPreset.simpleTiers)
          UpscaleTier(id: p.name, label: p.label, files: anime4kShaderChain(p)),
      ],
      note: '内置 · 实时（吃 GPU）',
    );

/// 内置方案清单：Anime4K（默认）+ mpv 自带缩放器（零下载、必实时）。
///
/// ⚠️ mpv 缩放器只改 `scale`（放大算法），不动 dscale/色彩管理；
/// 离开该方案时会把原值（启动时读到的）写回去 —— 见 Anime4kController。
List<UpscaleScheme> builtinUpscaleSchemes() => <UpscaleScheme>[
      anime4kScheme(),
      const UpscaleScheme(
        id: 'mpv-ewa-lanczossharp',
        name: 'mpv · EWA Lanczos Sharp',
        shortName: 'EWA锐',
        kind: UpscaleSchemeKind.mpvScaler,
        tiers: [UpscaleTier(id: 'on', label: '开')],
        properties: {'scale': 'ewa_lanczossharp'},
        note: '实时 · 只改 mpv 放大算法（更锐）',
      ),
      const UpscaleScheme(
        id: 'mpv-ewa-lanczos',
        name: 'mpv · EWA Lanczos',
        shortName: 'EWA',
        kind: UpscaleSchemeKind.mpvScaler,
        tiers: [UpscaleTier(id: 'on', label: '开')],
        properties: {'scale': 'ewa_lanczos'},
        note: '实时 · 只改 mpv 放大算法（均衡）',
      ),
      const UpscaleScheme(
        id: 'mpv-spline36',
        name: 'mpv · Spline36',
        shortName: 'Spline36',
        kind: UpscaleSchemeKind.mpvScaler,
        tiers: [UpscaleTier(id: 'on', label: '开')],
        properties: {'scale': 'spline36'},
        note: '实时 · 只改 mpv 放大算法（省性能）',
      ),
      const UpscaleScheme(
        id: 'mpv-bicubic',
        name: 'mpv · Bicubic',
        shortName: 'Bicubic',
        kind: UpscaleSchemeKind.mpvScaler,
        tiers: [UpscaleTier(id: 'on', label: '开')],
        properties: {'scale': 'bicubic'},
        note: '实时 · 只改 mpv 放大算法（最轻）',
      ),
    ];

/// 当前选中的方案 + Anime4K 档位。
///
/// 只有 Anime4K 用 [preset]；其他方案是「单档开/关」，`preset` 仅用于回切时恢复。
class UpscaleSelection {
  final String schemeId;
  final Anime4kPreset preset;

  const UpscaleSelection({
    this.schemeId = kAnime4kSchemeId,
    this.preset = Anime4kPreset.off,
  });

  /// 关（= Anime4K 方案 + off，兼容旧数据的语义）。
  static const UpscaleSelection off = UpscaleSelection();

  bool get isOff => schemeId == kAnime4kSchemeId && preset == Anime4kPreset.off;

  bool get isAnime4k => schemeId == kAnime4kSchemeId;

  /// 从持久化字段还原。未知方案回退 Anime4K（不抛、不崩，与旧字段兼容）。
  static UpscaleSelection fromSettings({
    String? schemeId,
    String? presetName,
    List<UpscaleScheme>? schemes,
  }) {
    final String id = (schemeId ?? '').trim().isEmpty ? kAnime4kSchemeId : schemeId!.trim();
    final Anime4kPreset preset =
        Anime4kPreset.values.asNameMap()[presetName] ?? Anime4kPreset.off;
    if (schemes != null && !schemes.any((UpscaleScheme s) => s.id == id)) {
      return UpscaleSelection(preset: preset);
    }
    return UpscaleSelection(schemeId: id, preset: preset);
  }

  /// 找到当前方案；找不到（例如扩展被卸载）回退 Anime4K。
  UpscaleScheme resolve(List<UpscaleScheme> schemes) {
    for (final UpscaleScheme scheme in schemes) {
      if (scheme.id == schemeId) return scheme;
    }
    for (final UpscaleScheme scheme in schemes) {
      if (scheme.isAnime4k) return scheme;
    }
    return anime4kScheme();
  }

  /// 控制栏胶囊文案：`超分 关 / 超分 标 / 超分 EWA锐`。
  String label(List<UpscaleScheme> schemes) {
    if (isOff) return '超分 关';
    final UpscaleScheme scheme = resolve(schemes);
    if (scheme.isAnime4k) {
      final String tier = switch (preset) {
        Anime4kPreset.off => '关',
        Anime4kPreset.light => '轻',
        Anime4kPreset.standard => '标',
        Anime4kPreset.ultra => '极',
      };
      return '超分 $tier';
    }
    return '超分 ${scheme.shortName}';
  }

  /// 胶囊点击的循环顺序：关 → Anime4K 轻/标/极 → 各 mpv 方案 → 关。
  static List<UpscaleSelection> cycleOrder(List<UpscaleScheme> schemes) => <UpscaleSelection>[
        off,
        for (final Anime4kPreset p in Anime4kPreset.simpleTiers) UpscaleSelection(preset: p),
        for (final UpscaleScheme s in schemes)
          if (!s.isAnime4k) UpscaleSelection(schemeId: s.id),
      ];

  UpscaleSelection cycle(List<UpscaleScheme> schemes) {
    final List<UpscaleSelection> order = cycleOrder(schemes);
    final int index = order.indexWhere(
      (UpscaleSelection s) => s.schemeId == schemeId && s.preset == preset,
    );
    if (index < 0) return off;
    return order[(index + 1) % order.length];
  }

  @override
  bool operator ==(Object other) =>
      other is UpscaleSelection && other.schemeId == schemeId && other.preset == preset;

  @override
  int get hashCode => Object.hash(schemeId, preset);
}
