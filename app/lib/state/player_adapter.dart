/// 播放器端口：把宿主的播放请求送到**弹出播放窗口**。
///
/// 架构（决策 B26/B28 + 用户 2026-10-10 的硬要求「只做弹出窗口，不要其他任何地方播放」）：
/// * 主窗口**不挂任何播放面**，也**不 new mpv**；它只负责解析出可播的串流地址，
///   然后让 [PlayerWindowService] 开窗/复用窗口并投递这一条请求。
/// * 子窗口是独立 Flutter 引擎（独立 isolate），自己在里面 `bootstrapPlayer()`；
///   播放面 `shikiin.PlayerSurface` 只在子窗口里常驻挂载（契约 §5 的约束因此落在子窗口）。
///
/// 所以宿主侧这一层从「往 `PlayerRequestNotifier` 里塞一条请求」变成了
/// 「跨窗口投递」：宿主的 [PlaybackController] 链路（入队/加种/记最近/续播）**一行没改**。
///
/// 外观（token）与剧集分组（上一集/下一集）也要一起带过去：子窗口读不到主窗口的
/// provider 容器，只能由主窗口把值推过去（见 [PlayerWindowService.pushArgs]）。
library;

import 'dart:async';

import '../domain/episode_group.dart';
import '../domain/models.dart';
import '../domain/ports.dart';
import '../theme/tokens.dart';
import 'player_window.dart';

class PlayerWindowPort implements PlayerPort {
  PlayerWindowPort({
    required this.service,
    required this.readTokens,
    this.readWakeChromeAtCenter,
    this.readAudioFx,
  });

  final PlayerWindowService service;

  /// 读宿主当前外观。用回调而不是 `Ref`：端口只在「投递一条请求」的那一刻取快照，
  /// 不需要参与重建（装配根传 `ref.read` 进来）。
  final DsTokens Function() readTokens;

  /// 读「画面正中也唤起两条栏」的当前设置（第二十七轮）。
  ///
  /// 与 [readTokens] 同一套：只在投递请求那一刻取快照；设置页改了之后正在开的窗口
  /// 由 `app.dart` 的 `pushArgs` 现场推。null = 组件测试/内嵌宿主，按默认（关）处理。
  final bool Function()? readWakeChromeAtCenter;

  /// 读音效状态（扩展页里配置的那一份）。null = 组件测试，不带。
  final Map<String, Object?>? Function()? readAudioFx;

  @override
  bool get isAvailable => true;

  @override
  Future<void> open(PlayerRequest request, {EpisodeGrouping? episodeGroup}) async {
    await service.open(PlayerWindowArgs(
      streamUrl: request.streamUrl.toString(),
      title: request.title,
      startAtMs: request.startAt?.inMilliseconds,
      subtitlePath: request.subtitlePath,
      tokens: encodeTokens(readTokens()),
      episodeGroup: encodeEpisodeGroup(episodeGroup),
      wakeChromeAtCenter: readWakeChromeAtCenter?.call(),
      audioFx: readAudioFx?.call(),
    ));
  }

  @override
  Future<void> playOrPause() => service.send(kMethodPlayOrPause);

  @override
  Future<void> seek(Duration position) =>
      service.send(kMethodSeek, position.inMilliseconds);

  /// 停止：**不关窗**。播放面必须常驻挂载（契约 §5），关掉再开等于每次重新造 mpv；
  /// 这里让子窗口停下并记住进度，窗口留着（主窗口的播放状态由调用方清）。
  @override
  Future<void> stop() => service.send(kMethodStop);

  /// 子窗口是另一个 isolate，播放完成/位置/错误这些信号都留在它那边
  /// （`autoPlayNext` 因此改由子窗口自己按分组推进），主窗口这一侧没有信号源。
  @override
  Stream<PlaybackSignal> get signals => const Stream<PlaybackSignal>.empty();

  @override
  Future<void> dispose() async {}
}
