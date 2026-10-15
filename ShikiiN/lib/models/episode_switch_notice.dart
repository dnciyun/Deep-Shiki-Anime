import 'package:flutter/foundation.dart';

/// 宿主推给播放面的一条「切集结果」（第三十八轮）。
///
/// 用户原话：「优化反馈，点击下一集或上一集都没实质性反馈」。跨种子的播放列表里，
/// 其它集**还没进引擎** —— 点下去要等「补磁力 → `addMagnet` 等元数据」，慢的时候
/// 几十秒到两分钟，而这段时间播放窗口里什么都不发生（用户看到的就是"点了没反应"）。
/// 所以这一轮的反馈分两半：
/// * 点下去那一刻由播放面自己亮「正在切到《X》…」（本地状态，见 `PlayerSurface`
///   的 `_beginEpisodeSwitch`）—— 它不需要宿主配合，点击立刻有反馈；
/// * 失败时由**宿主**把原因推过来（就是这条）：播放面把它顶在画面上，而不是只写在
///   主窗口那条横幅里 —— 那条横幅被播放窗口盖住，等于没说。
///
/// 宿主侧对应 `app/lib/state/player_window.dart` 的 `kMethodSwitchFailed`。
@immutable
class EpisodeSwitchNotice {
  const EpisodeSwitchNotice({required this.message, this.hint});

  /// 一句话说清为什么没切成（例：`没有可播放的磁力链`）。
  final String message;

  /// 「怎么办」（可空）。有就跟着显示，没有就不显示。
  final String? hint;

  @override
  bool operator ==(Object other) =>
      other is EpisodeSwitchNotice && other.message == message && other.hint == hint;

  @override
  int get hashCode => Object.hash(message, hint);

  @override
  String toString() => 'EpisodeSwitchNotice($message${hint == null ? '' : '｜$hint'})';
}
