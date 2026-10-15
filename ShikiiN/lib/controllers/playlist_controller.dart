import 'package:flutter/foundation.dart';

import '../models/media_item.dart';

/// 当前剧集所在的**那一组**（契约 §9）。
///
/// 宿主注入：同目录同名不同集 / 队列内同订阅的其它集。播放器**不自己扫盘**——
/// "在哪播的在哪搜" 的规则由宿主负责，宿主构造好 [items] 与 [currentIndex] 后
/// override `episodeGroupProvider`。
///
/// 网流场景每集的 [MediaItem.streamUrl] 由宿主填好（引擎的 per-file 地址只有宿主
/// 拿得到）；播放器点上一集/下一集时不自己 open，而是把它交回
/// `playerRequestProvider.request(...)`，仍走宿主那条唯一开播链路。
@immutable
class EpisodeGroup {
  final List<MediaItem> items;

  /// 当前正在播的那一集在 [items] 里的下标。
  final int currentIndex;

  const EpisodeGroup({required this.items, this.currentIndex = 0});

  bool get isEmpty => items.isEmpty;
  bool get isNotEmpty => items.isNotEmpty;

  /// 有没有上一集/下一集（用于决定按钮是否显示：契约 §9 要求隐藏而非禁用）。
  bool get hasPrevious => currentIndex > 0 && currentIndex < items.length;
  bool get hasNext => currentIndex >= 0 && currentIndex + 1 < items.length;

  MediaItem? get previous =>
      hasPrevious ? items[currentIndex - 1] : null;

  MediaItem? get next => hasNext ? items[currentIndex + 1] : null;

  EpisodeGroup copyWith({List<MediaItem>? items, int? currentIndex}) =>
      EpisodeGroup(
        items: items ?? this.items,
        currentIndex: currentIndex ?? this.currentIndex,
      );
}
