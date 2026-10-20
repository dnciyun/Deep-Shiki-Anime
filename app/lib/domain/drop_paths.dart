/// 拖进窗口的文件怎么分流：视频 → 播；`.torrent` → 确认后入队；其它 → 说一句。
///
/// 单独抽成纯函数（不碰 UI/IO）的原因：分流规则是"拖错东西会怎样"的全部依据
/// （拖一堆子目录、拖 .mkv+.torrent 混合、拖 .nfo），这些都能用纯测试钉死，
/// 而真正的拖放通道（`desktop_drop`）在组件测试里造不出来。
library;

import 'package:flutter/foundation.dart';

import 'local_media.dart' show isLocalVideoPath;

/// 一个被拖入文件的归类。
enum DroppedKind {
  /// 认得的视频扩展名（`local_media.dart` 那一张表，与「本地」页同一个口径）。
  video,

  /// `.torrent` 种子文件。
  torrent,

  /// 其它（图片、字幕、压缩包、文件夹……）—— 不处理，但要告诉用户为什么。
  other,
}

/// 一次拖放里各类文件的清单（保持拖动时的原始顺序）。
@immutable
class DroppedPaths {
  const DroppedPaths({
    this.videos = const <String>[],
    this.torrents = const <String>[],
    this.others = const <String>[],
  });

  final List<String> videos;
  final List<String> torrents;
  final List<String> others;

  bool get isEmpty => videos.isEmpty && torrents.isEmpty && others.isEmpty;

  int get length => videos.length + torrents.length + others.length;

  @override
  String toString() => 'DroppedPaths(videos: $videos, torrents: $torrents, others: $others)';
}

/// 单个文件归类（扩展名判断，大小写不敏感）。
DroppedKind droppedKindOf(String path) {
  final String lower = path.trim().toLowerCase();
  if (lower.isEmpty) return DroppedKind.other;
  if (lower.endsWith('.torrent')) return DroppedKind.torrent;
  if (isLocalVideoPath(lower)) return DroppedKind.video;
  return DroppedKind.other;
}

/// 把一次拖放的路径分成三类。
DroppedPaths partitionDroppedPaths(Iterable<String> paths) {
  final List<String> videos = <String>[];
  final List<String> torrents = <String>[];
  final List<String> others = <String>[];
  for (final String raw in paths) {
    final String path = raw.trim();
    if (path.isEmpty) continue;
    switch (droppedKindOf(path)) {
      case DroppedKind.video:
        videos.add(path);
      case DroppedKind.torrent:
        torrents.add(path);
      case DroppedKind.other:
        others.add(path);
    }
  }
  return DroppedPaths(videos: videos, torrents: torrents, others: others);
}
