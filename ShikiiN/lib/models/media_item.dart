import 'package:flutter/foundation.dart';

@immutable
class MediaItem {
  final String path;        // 绝对路径；网流场景存 URL 文本
  final String title;       // 文件名（无扩展名）

  /// 宿主投递用的完整串流地址（带 token），只有宿主能构造。
  ///
  /// 网流场景 [path] 也存 URL 文本，但引擎的 per-file 地址是
  /// `streamUrl(torrentId, fileIndex)`，只有宿主拿得到；宿主构造
  /// [EpisodeGroup] 时把每集的 `streamUrl` 填好，播放器点上一集/下一集时把它
  /// 交回 `playerRequestProvider.request(...)`，仍走宿主那条唯一开播链路。
  final Uri? streamUrl;

  /// 宿主解析出来的**真实集号**（null = 宿主没解析出来）。
  ///
  /// 播放器的播放列表拿它显示集数：用户 2026-10-11「播放列表太小了看不到集数了」——
  /// 用列表下标当集号会在缺集时撒谎（列表里只有 8/9/10 时下标 1 会被显示成"第 2 集"）。
  /// 播放器**不自己解析标题**（同一集不能两处显示不一样），宿主给什么就显示什么。
  final int? episode;

  const MediaItem({
    required this.path,
    required this.title,
    this.streamUrl,
    this.episode,
  });

  // 既有语义（勿改）：同一路径即同一项；streamUrl 不参与比较。
  @override
  bool operator ==(Object other) => other is MediaItem && other.path == path;
  @override
  int get hashCode => path.hashCode;
}
