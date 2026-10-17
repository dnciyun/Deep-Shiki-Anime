/// 可切换的超分**方案**（scheme）。
///
/// 用户 2026-10-17 两句话定了这版边界：
/// *「模型我想多试试其他的，只使用可以实时播放的，默认自带的是 anime4k」；
///  *「去除内置的mpv这套，按1做，另一条渲染管线的就是扩展干的」。
///
/// 于是内置只保留**当前渲染管线（media_kit `vo=libmpv` + ANGLE/GLES）里真能跑的
/// fragment GLSL**：
///
/// * [UpscaleSchemeKind.anime4kChain]：内置 Anime4K，档位 = 轻/标/极（默认）；
/// * [UpscaleSchemeKind.glslPack]：一组打包的 GLSL 文件，按顺序挂到
///   `glsl-shaders`。随包内置 ACNet / ARNet / Anime4K-Ultra / FSR 1.0；
///   将来扩展框架装的第三方包也是这个类型（目录由 [UpscaleScheme.dir] 指定）。
///
/// 明确**不做**的两件事：
/// 1. mpv 自带缩放器（改 `scale` 属性那套）已按用户要求整套移除；
/// 2. 需要另一条渲染管线的方案（gpu-next 的 compute 着色器 ArtCNN、ONNX 推理
///    如 AnimeJaNai）不进内置 —— 归扩展（资源包）管，见 1.1.0 计划 M3。
///
/// **只收实时方案**：VapourSynth / ONNX / Real-ESRGAN / waifu2x 这类逐帧神经网络
/// 不在此列（包里没有那些运行时，也做不到实时播放）。
library;

import 'anime4k_preset.dart';

/// 超分方案的实现类型。
enum UpscaleSchemeKind {
  /// 内置 Anime4K 的 shader 链（12 个 .glsl，按档位组链）。
  anime4kChain,

  /// 一组打包的 GLSL（内置 ACNet/ARNet/Anime4K-Ultra/FSR，或扩展装的包）。
  glslPack,
}

/// 方案里的一档。只有 [UpscaleSchemeKind.anime4kChain] 用（轻/标/极）。
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

  /// 菜单里的全名（如 `ACNet · 中性`）。
  final String name;

  /// 控制栏胶囊里的短名（如 `ACNet`）。
  final String shortName;

  final UpscaleSchemeKind kind;

  /// Anime4K 的档位；glslPack 方案只有一档（用 [files]）。
  final List<UpscaleTier> tiers;

  /// glslPack 要按顺序挂载的文件名（相对 [dir] 或启动注入的 shader 目录）。
  final List<String> files;

  /// shader 目录；null = 用启动流程注入的 Anime4K 解包目录（内置包都是这种）。
  final String? dir;

  /// 界面上的小字说明。
  final String? note;

  /// 低于这个放大比例时方案会静默跳过（shader 自带 `//!WHEN` 门槛）。
  ///
  /// * ACNet/ARNet：1.2（上游 `//!WHEN` 要求 OUTPUT/LUMA > 1.2）；
  /// * FSR 1.0：1.0（我们已放宽到 ≥1.0，所以只有降采样时才跳过）；
  /// * null：任何尺寸都生效（Anime4K-Ultra、RCAS）。
  ///
  /// 控制器据此在「没放大」时弹一句 mpv OSD 说明，而不是让人以为坏了。
  final double? upscaleOnlyAbove;

  const UpscaleScheme({
    required this.id,
    required this.name,
    required this.shortName,
    required this.kind,
    this.tiers = const [],
    this.files = const [],
    this.dir,
    this.note,
    this.upscaleOnlyAbove,
  });

  bool get isAnime4k => kind == UpscaleSchemeKind.anime4kChain;

  UpscaleTier? tierOf(String id) {
    for (final tier in tiers) {
      if (tier.id == id) return tier;
    }
    return null;
  }
}

/// 内置 Anime4K 方案的 id（也是「关」所在的方案：preset=off 即关）。
const String kAnime4kSchemeId = 'anime4k';

// —— 随包内置的第三方 shader 文件名（必须与 assets/shaders/anime4k/ 下一致）——
// 全部 MIT，来源与许可见 `THIRD_PARTY_NOTICES.txt`。
const String kAcnetShader = 'acnet_f8b8.glsl';
const String kAcnetHdnShader = 'acnet_f8b8_hdn.glsl';
const String kArnetShader = 'arnet_f8b16.glsl';
const String kAnime4kUltraShader = 'Anime4K-Ultra_DbL.glsl';
const String kFsrShader = 'FSR.glsl';
const String kRcasShader = 'RCAS.glsl';

/// 随包内置的 GLSL 包文件清单（解包用；与 Anime4K 的 12 个一起落同一个目录）。
const List<String> kBundledPackShaderFiles = [
  kAcnetShader,
  kAcnetHdnShader,
  kArnetShader,
  kAnime4kUltraShader,
  kFsrShader,
  kRcasShader,
];

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

/// 内置方案清单：Anime4K（默认）+ 6 个随包 GLSL 方案（MIT，实时）。
///
/// 注：ACNet/ARNet/FSR 是**放大**用 shader，自身按 `//!WHEN` 只在放大比例足够时
/// 生效（ACNet/ARNet >1.2x；FSR 我们放宽到 >=1.0x，1:1 也有 RCAS 锐化）；
/// 窗口比片源小时它们会跳过 —— 控制器会弹一句 mpv OSD 说明。
/// Anime4K-Ultra 在原画分辨率上做线条/去模糊、RCAS 是独立锐化，任何尺寸都有变化。
List<UpscaleScheme> builtinUpscaleSchemes() => <UpscaleScheme>[
      anime4kScheme(),
      const UpscaleScheme(
        id: 'acnet',
        name: 'ACNet · 中性',
        shortName: 'ACNet',
        kind: UpscaleSchemeKind.glslPack,
        files: [kAcnetShader],
        upscaleOnlyAbove: 1.2,
        note: 'MIT · 实时 · 中性放大（更接近原画，放大 >1.2x 才生效）',
      ),
      const UpscaleScheme(
        id: 'acnet-hdn',
        name: 'ACNet · 去噪',
        shortName: 'ACNet去噪',
        kind: UpscaleSchemeKind.glslPack,
        files: [kAcnetHdnShader],
        upscaleOnlyAbove: 1.2,
        note: 'MIT · 实时 · 去噪放大（低码率 WEB 源更干净，放大 >1.2x 才生效）',
      ),
      const UpscaleScheme(
        id: 'arnet',
        name: 'ARNet · 线条',
        shortName: 'ARNet',
        kind: UpscaleSchemeKind.glslPack,
        files: [kArnetShader],
        upscaleOnlyAbove: 1.2,
        note: 'MIT · 实时 · 线条/细节最强，计算量也最大（放大 >1.2x 才生效）',
      ),
      const UpscaleScheme(
        id: 'anime4k-ultra',
        name: 'Anime4K-Ultra · 保颗粒',
        shortName: 'A4K-U',
        kind: UpscaleSchemeKind.glslPack,
        files: [kAnime4kUltraShader],
        note: 'MIT · 实时 · 保留颗粒/纹理，线条更利，比原版 Anime4K 轻',
      ),
      const UpscaleScheme(
        id: 'fsr',
        name: 'FSR 1.0 · EASU+RCAS',
        shortName: 'FSR',
        kind: UpscaleSchemeKind.glslPack,
        files: [kFsrShader],
        upscaleOnlyAbove: 1.0,
        note: 'MIT · 实时 · AMD FSR 1.0：EASU 放大 + RCAS 锐化（1:1 或放大时都有锐化，最省）',
      ),
      const UpscaleScheme(
        id: 'rcas',
        name: '锐化 · RCAS',
        shortName: 'RCAS',
        kind: UpscaleSchemeKind.glslPack,
        files: [kRcasShader],
        note: 'MIT · 实时 · 只锐化不放大：窗口比片源小/1:1 都有变化（看不到变化时先用它）',
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

  /// 控制栏胶囊文案：`超分 关 / 超分 标 / 超分 ACNet`。
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

  /// 胶囊点击的循环顺序：关 → Anime4K 轻/标/极 → 各随包方案 → 关。
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
