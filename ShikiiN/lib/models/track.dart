import 'package:flutter/foundation.dart';

enum TrackKind { audio, subtitle }

@immutable
class TrackInfo {
  /// 轨道 id（契约 §2 的 `activeAudioId` / `setAudioTrackById(int?)` 都是 int）。
  /// 由 media_kit 的字符串 id 解析，解析不出（非数字）时为 -1。
  final int id;
  final TrackKind kind;
  final String label;       // 展示名（语言/标题/编号）
  const TrackInfo({required this.id, required this.kind, required this.label});
}
