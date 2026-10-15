import 'package:flutter/services.dart' show LogicalKeyboardKey;

import 'player_action.dart';

/// 写死的键位表（契约 §6，不再可重绑）。
///
/// 直接用 [LogicalKeyboardKey] 比较，不经过任何「keyLabel/debugName」字符串
/// 转换——历史上有过 release 下 debugName 为 null 导致空格/方向键匹配失败的
/// 真实 bug，这里从根上避免。
/// （LogicalKeyboardKey 重写了 `==`，故这张表只能是 `final` 不能是 `const`。）
final Map<LogicalKeyboardKey, PlayerAction> kPlayerKeymap = {
  LogicalKeyboardKey.space: PlayerAction.playPause,
  LogicalKeyboardKey.arrowLeft: PlayerAction.seekBackward,
  LogicalKeyboardKey.arrowRight: PlayerAction.seekForward,
  LogicalKeyboardKey.arrowUp: PlayerAction.volumeUp,
  LogicalKeyboardKey.arrowDown: PlayerAction.volumeDown,
  LogicalKeyboardKey.keyM: PlayerAction.toggleMute,
  LogicalKeyboardKey.keyF: PlayerAction.toggleFullscreen,
  LogicalKeyboardKey.escape: PlayerAction.exitFullscreen,
  LogicalKeyboardKey.tab: PlayerAction.toggleStats,
};

/// 可长按连发的动作（自管 `Timer.periodic`，不依赖 OS 重复事件）。
const Set<PlayerAction> kHoldableActions = {
  PlayerAction.seekForward,
  PlayerAction.seekBackward,
  PlayerAction.volumeUp,
  PlayerAction.volumeDown,
};

/// 单击快进/快退步长（秒）。
const int kSeekStepSeconds = 5;

/// 单击音量步长。
const double kVolumeStep = 5;

// —— 长按连续触发的节奏/加速参数（原 hold_repeat.dart，逐值搬移）——

/// 长按重复定时器的间隔（毫秒）。
const int kHoldTickMs = 110;

/// 按下到进入「连续」的初始延迟（毫秒），区分单击与长按。
const int kHoldStartDelayMs = 350;

/// seek：每个 tick 的基础步长（秒）。
const double kSeekStepBaseSeconds = 0.6;

/// seek：每个 tick 的步长上限（秒）——封顶速度 = 上限/tick。
const double kSeekStepMaxSeconds = 6.0;

/// seek：每按住 1 秒，步长增加多少秒（线性加速）。
const double kSeekAccelPerSecond = 1.2;

/// 音量：每个 tick 的步长（无加速，匀速）。
const double kVolumeStepPerTick = 2.0;

/// 给定「已按住毫秒数」返回本 tick 的 seek 步长（秒），线性加速并封顶。
double seekStepSeconds(int heldMs) {
  final step = kSeekStepBaseSeconds + kSeekAccelPerSecond * (heldMs / 1000.0);
  return step > kSeekStepMaxSeconds ? kSeekStepMaxSeconds : step;
}
