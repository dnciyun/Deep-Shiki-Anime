import 'anime4k_preset.dart';
import 'subtitle_style.dart';
import 'upscale_scheme.dart';

/// 全局偏好（契约 §3）。键仍是 `'app_settings'`。
///
/// 保留：volume / subtitleStyle / anime4kPreset / upscaleSchemeId / rememberPosition / rate（=1，只读）。
/// 已删：autoSkip / controlBarFloatingOverride / endAction / controlBarExtras /
/// volumeBoostEnabled / anime4kCustomChain —— [fromMap] 对旧数据里的这些字段
/// **静默忽略**，不让老用户的数据抛异常。
class AppSettings {
  double volume;

  /// 播放倍速：固定 1.0（倍速功能已删，字段只为兼容旧数据结构而只读保留）。
  final double rate;

  bool rememberPosition;
  SubtitleStyle subtitleStyle;

  /// Anime4K 超分档位（全局记忆）。默认 off。
  Anime4kPreset anime4kPreset;

  /// 超分方案 id（`anime4k` = 内置 Anime4K；其他 = mpv 缩放器 / 已安装 GLSL 包）。
  ///
  /// 2026-10-17 新增（用户「模型我想多试试其他的」）：旧数据没有这个字段 →
  /// 走默认 `anime4k`，与旧行为（只看 anime4kPreset）完全一致。
  String upscaleSchemeId;

  AppSettings({
    this.volume = 100,
    this.rate = 1.0,
    this.rememberPosition = true,
    this.subtitleStyle = const SubtitleStyle(),
    this.anime4kPreset = Anime4kPreset.off,
    this.upscaleSchemeId = kAnime4kSchemeId,
  });

  Map<String, Object?> toMap() => {
        'volume': volume,
        'rate': rate,
        'rememberPosition': rememberPosition,
        'subtitleStyle': subtitleStyle.toMap(),
        'anime4kPreset': anime4kPreset.name,
        'upscaleSchemeId': upscaleSchemeId,
      };

  factory AppSettings.fromMap(Map? m) => AppSettings(
        volume: (m?['volume'] as num?)?.toDouble() ?? 100,
        rate: (m?['rate'] as num?)?.toDouble() ?? 1.0,
        rememberPosition: (m?['rememberPosition'] as bool?) ?? true,
        subtitleStyle: SubtitleStyle.fromMap(m?['subtitleStyle'] as Map?),
        anime4kPreset:
            Anime4kPreset.values.asNameMap()[m?['anime4kPreset']] ?? Anime4kPreset.off,
        upscaleSchemeId: _schemeId(m?['upscaleSchemeId']),
      );

  /// 未知/空 → 内置 Anime4K（不抛、不崩；扩展被卸载后旧值也能安全落地）。
  static String _schemeId(Object? raw) {
    if (raw is! String) return kAnime4kSchemeId;
    final String id = raw.trim();
    return id.isEmpty ? kAnime4kSchemeId : id;
  }
}
