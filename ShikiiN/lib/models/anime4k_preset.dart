/// Anime4K 超分档位（契约 §1/§5）：只留三档 + 关。
/// 简化档是单模式的语义别名：light=Mode A Fast, standard=Mode A HQ, ultra=A+A。
enum Anime4kPreset {
  off,
  light,
  standard,
  ultra;

  String get label => switch (this) {
        Anime4kPreset.off => '关',
        Anime4kPreset.light => '轻量',
        Anime4kPreset.standard => '标准',
        Anime4kPreset.ultra => '极致',
      };

  /// 小字注释：效果说明（右键菜单副标题）。
  String get hint => switch (this) {
        Anime4kPreset.off => '不处理，原画输出',
        Anime4kPreset.light => '性能优先，轻度增强',
        Anime4kPreset.standard => '均衡，推荐日常用',
        Anime4kPreset.ultra => '最强还原，最锐(吃显卡)',
      };

  /// 三档（不含 off），顺序即「关 → 轻 → 标 → 极 → 关」的循环顺序。
  static const List<Anime4kPreset> simpleTiers = [light, standard, ultra];

  /// 控制栏超分胶囊：循环切下一档（关→轻→标→极→关）。
  Anime4kPreset get cycled {
    final all = [Anime4kPreset.off, ...simpleTiers];
    return all[(all.indexOf(this) + 1) % all.length];
  }
}

// —— shader 文件名常量（必须与 assets/shaders/anime4k/ 下文件一致）——
const _clamp = 'Anime4K_Clamp_Highlights.glsl';
const _restoreVL = 'Anime4K_Restore_CNN_VL.glsl';
const _restoreM = 'Anime4K_Restore_CNN_M.glsl';
const _restoreSoftVL = 'Anime4K_Restore_CNN_Soft_VL.glsl';
const _restoreSoftM = 'Anime4K_Restore_CNN_Soft_M.glsl';
const _upVL = 'Anime4K_Upscale_CNN_x2_VL.glsl';
const _upM = 'Anime4K_Upscale_CNN_x2_M.glsl';
const _upS = 'Anime4K_Upscale_CNN_x2_S.glsl';
const _denoiseVL = 'Anime4K_Upscale_Denoise_CNN_x2_VL.glsl';
const _denoiseS = 'Anime4K_Upscale_Denoise_CNN_x2_S.glsl';
const _downX2 = 'Anime4K_AutoDownscalePre_x2.glsl';
const _downX4 = 'Anime4K_AutoDownscalePre_x4.glsl';

/// 所有打包的 shader 文件清单（解包用 + 校验链引用合法）。
/// **逐字保持不变**：`app/test/anime4k_assets_test.dart` 与解包逻辑都依赖它。
const List<String> kAnime4kShaderFiles = [
  _clamp, _restoreVL, _restoreM, _restoreSoftVL, _restoreSoftM,
  _upVL, _upM, _upS, _denoiseVL, _denoiseS, _downX2, _downX4,
];

/// 档位 → shader 文件链（按官方 v4 推荐顺序）。off 返回空。
List<String> anime4kShaderChain(Anime4kPreset p) {
  switch (p) {
    case Anime4kPreset.off:
      return const [];
    case Anime4kPreset.light:
      return const [_clamp, _restoreM, _upM, _downX2, _downX4, _upS];
    case Anime4kPreset.standard:
      return const [_clamp, _restoreVL, _upVL, _downX2, _downX4, _upM];
    // 官方 v4.0.1 的 Mode A+A：第二遍 Restore 用 M 档（x4 之后），
    // **不是**把 VL 用两次 —— 官方明确说同一 shader 重复挂会出 bug 且白掉性能。
    case Anime4kPreset.ultra:
      return const [_clamp, _restoreVL, _upVL, _downX2, _downX4, _restoreM, _upM];
  }
}
