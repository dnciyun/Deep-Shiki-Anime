/// 可切换的超分**方案**（scheme）。
///
/// 用户 2026-10-17 的最终结论（三轮真机反馈后）：
/// 「效果微乎其微，去除掉吧，仅保留anime4k包括u」——内置只留
/// **Anime4K 三档**（默认）与 **Anime4K-Ultra**。
///
/// 被用户真机否掉、已整套删除的：
/// * mpv 自带缩放器（改 `scale` 属性那套）；
/// * ACNet 中性 / 去噪、ARNet 线条、FSR 1.0、RCAS 锐化（放大闸门 + 效果不达预期）。
///
/// 仍保留的两条实现通路：
/// * [UpscaleSchemeKind.anime4kChain]：内置 Anime4K 三档（轻/标/极）；
/// * [UpscaleSchemeKind.glslPack]：一组 GLSL 文件按顺序挂到 `glsl-shaders`
///   （内置 Anime4K-Ultra；将来扩展框架装的第三方包也走这条，目录由
///   [UpscaleScheme.dir] 指定）。
///
/// **另一条渲染管线**（gpu-next 的 compute 着色器 ArtCNN、ONNX 推理如
/// AnimeJaNai）不进内置 —— 归扩展（资源包）管，见 1.1.0 计划 M3。
library;

import 'anime4k_preset.dart';

/// 超分方案的实现类型。
enum UpscaleSchemeKind {
  /// 内置 Anime4K 的 shader 链（12 个 .glsl，按档位组链）。
  anime4kChain,

  /// 一组打包的 GLSL（内置 Anime4K-Ultra，或扩展装的包）。
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

  /// 菜单里的全名（如 `Anime4K-Ultra · 保颗粒`）。
  final String name;

  /// 控制栏胶囊里的短名（如 `A4K-U`）。
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

  const UpscaleScheme({
    required this.id,
    required this.name,
    required this.shortName,
    required this.kind,
    this.tiers = const [],
    this.files = const [],
    this.dir,
    this.note,
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

/// 内置 Anime4K-Ultra 方案的 id。
const String kAnime4kUltraSchemeId = 'anime4k-ultra';

// —— 随包内置的第三方 shader 文件名（必须与 assets/shaders/anime4k/ 下一致）——
// MIT，来源与许可见 `THIRD_PARTY_NOTICES.txt`。
const String kAnime4kUltraShader = 'Anime4K-Ultra_DbL.glsl';

/// 随包内置的 GLSL 包文件清单（解包用；与 Anime4K 的 12 个一起落同一个目录）。
const List<String> kBundledPackShaderFiles = [
  kAnime4kUltraShader,
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

/// 内置 Anime4K-Ultra 方案：单文件，原画分辨率上做线条/去模糊，任何尺寸都有变化。
UpscaleScheme anime4kUltraScheme() => const UpscaleScheme(
      id: kAnime4kUltraSchemeId,
      name: 'Anime4K-Ultra · 保颗粒',
      shortName: 'A4K-U',
      kind: UpscaleSchemeKind.glslPack,
      files: [kAnime4kUltraShader],
      note: 'MIT · 实时 · 保留颗粒/纹理，线条更利，比原版 Anime4K 轻',
    );

/// 内置方案清单：Anime4K（默认）+ Anime4K-Ultra。
List<UpscaleScheme> builtinUpscaleSchemes() => <UpscaleScheme>[
      anime4kScheme(),
      anime4kUltraScheme(),
    ];

/// 内置方案 + 宿主从「扩展」目录扫出来的外部方案（1.1.0 M3/T17）。
///
/// 去重规则：**[extra] 里 id 与内置撞车的一律丢掉**（内置是安全底线：用户点一下「超分」
/// 不能因为一个装坏的扩展变成不知道挂什么 shader 的状态）。正常路径下撞不了 ——
/// 扩展清单的 id 白名单已经把 `anime4k` / `anime4k-ultra` 列为保留字（core 的
/// `kReservedExtensionIds`），这里是第二道保险。
///
/// 顺序：内置在前（菜单里 Anime4K 永远在最上面），扩展按 [extra] 给的顺序排在后面。
List<UpscaleScheme> mergedUpscaleSchemes({
  List<UpscaleScheme> extra = const <UpscaleScheme>[],
}) {
  final List<UpscaleScheme> builtin = builtinUpscaleSchemes();
  if (extra.isEmpty) return builtin;
  final Set<String> builtinIds = <String>{
    for (final UpscaleScheme scheme in builtin) scheme.id,
  };
  return <UpscaleScheme>[
    ...builtin,
    for (final UpscaleScheme scheme in extra)
      if (!builtinIds.contains(scheme.id) && scheme.files.isNotEmpty) scheme,
  ];
}

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

  /// 控制栏胶囊文案：`超分 关 / 超分 标 / 超分 A4K-U`。
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

  /// 胶囊点击的循环顺序：关 → Anime4K 轻/标/极 → 其他方案 → 关。
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
