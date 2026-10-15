import 'anime4k_preset.dart';
import 'subtitle_style.dart';

/// 全局偏好（契约 §3）。键仍是 `'app_settings'`。
///
/// 保留：volume / subtitleStyle / anime4kPreset / rememberPosition / rate（=1，只读）。
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

  AppSettings({
    this.volume = 100,
    this.rate = 1.0,
    this.rememberPosition = true,
    this.subtitleStyle = const SubtitleStyle(),
    this.anime4kPreset = Anime4kPreset.off,
  });

  Map<String, Object?> toMap() => {
        'volume': volume,
        'rate': rate,
        'rememberPosition': rememberPosition,
        'subtitleStyle': subtitleStyle.toMap(),
        'anime4kPreset': anime4kPreset.name,
      };

  factory AppSettings.fromMap(Map? m) => AppSettings(
        volume: (m?['volume'] as num?)?.toDouble() ?? 100,
        rate: (m?['rate'] as num?)?.toDouble() ?? 1.0,
        rememberPosition: (m?['rememberPosition'] as bool?) ?? true,
        subtitleStyle: SubtitleStyle.fromMap(m?['subtitleStyle'] as Map?),
        anime4kPreset:
            Anime4kPreset.values.asNameMap()[m?['anime4kPreset']] ?? Anime4kPreset.off,
      );
}
