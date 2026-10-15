import 'package:flutter/foundation.dart';

/// 宿主请求播放器播放的一项媒体。
///
/// 播放器的原生入口只认「本地存在的视频文件路径」（[fromLaunchFile]），
/// 但作为内嵌库被宿主使用时（DSAnima 边下边播），媒体是 **HTTP 串流 URL**：
/// libmpv 可以直接吃 `http://127.0.0.1:<port>/torrents/…/stream?token=…`。
///
/// 两者用同一类型表达，宿主通过 [PlayerRequestNotifier] 投递。
@immutable
class PlayerRequest {
  /// media_kit `Media()` 接受的 URI：本地绝对路径，或 http(s):// URL。
  final String uri;

  /// 展示用标题（播放列表/控制栏）。空则回退文件名/主机名。
  final String title;

  /// 起点（续播）。null = 从头。
  final Duration? startAt;

  /// 外挂字幕绝对路径（宿主已经把字幕下到同目录时直接挂上）。null = 没有。
  final String? subtitlePath;

  /// 同一 uri 重复投递时的去重标记；宿主可自增以强制重新打开。
  final int nonce;

  const PlayerRequest({
    required this.uri,
    required this.title,
    this.startAt,
    this.subtitlePath,
    this.nonce = 0,
  });

  /// 是否为网流（HTTP/HTTPS）。网流的续播、缩略图等策略与本地文件不同。
  bool get isNetworkStream =>
      uri.startsWith('http://') || uri.startsWith('https://');

  /// 从命令行文件路径构造（保持既有「shikiin.exe "<视频>" 启动即播」行为）。
  ///
  /// [nonce]：同一个文件**再打开一次**也要算新请求（`PlayerRequestNotifier.request`
  /// 对完全相同的 uri+startAt+nonce 会去重）—— 接收端每次自增它。
  static PlayerRequest? fromLaunchFile(String path, {int nonce = 0}) {
    if (path.trim().isEmpty) return null;
    final name = path.split(RegExp(r'[\\/]')).last;
    final dot = name.lastIndexOf('.');
    final title = dot > 0 ? name.substring(0, dot) : name;
    return PlayerRequest(uri: path, title: title, nonce: nonce);
  }

  @override
  bool operator ==(Object other) =>
      other is PlayerRequest &&
      other.uri == uri &&
      other.startAt == startAt &&
      other.nonce == nonce;

  @override
  int get hashCode => Object.hash(uri, startAt, nonce);

  @override
  String toString() => 'PlayerRequest($uri, title: $title, nonce: $nonce)';
}

/// 宿主投递播放请求的通道。
///
/// 默认 null（无请求）。宿主 App 用 `overrideWithValue`/`overrideWith` 注入一个
/// 实例，之后任何 [set] 都会被播放器外壳消费并立即播放。
class PlayerRequestNotifier extends ValueNotifier<PlayerRequest?> {
  PlayerRequestNotifier([super.value]);

  /// 请求播放 [request]；与当前相同的 uri 也允许（nonce 变化即视为新请求）。
  void request(PlayerRequest request) {
    final cur = value;
    if (cur != null &&
        cur.uri == request.uri &&
        cur.startAt == request.startAt &&
        cur.nonce == request.nonce) {
      return; // 完全相同的请求不重复触发
    }
    value = request;
  }
}
