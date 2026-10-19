/// 一个字幕样式预设 —— 宿主从通用扩展包（`preset-pack` / `player.subtitle` 面）
/// 扫出来交给播放器的**已解析**模型。
///
/// 播放器不认识扩展清单格式（那是 `dsanima_core` 的事），只认这个：名字 + 说明 +
/// 一份现成的 [SubtitleStyle]。应用预设 = 把它交给既有的 `onSubtitleStyle` 链路
/// （下发 mpv/Flutter 字幕层 + 写盘都由宿主负责）。
library;

import 'subtitle_style.dart';

class SubtitlePreset {
  const SubtitlePreset({
    required this.id,
    required this.name,
    this.description = '',
    required this.style,
    this.packId = '',
    this.packName = '',
  });

  /// 预设 id（面内唯一；宿主会拼成 `<包 id>/<预设 id>` 做分组/排错）。
  final String id;

  /// 菜单上显示的名字。
  final String name;

  /// 一句话说明（悬停提示 / 扩展页用）。
  final String description;

  /// 来自哪个扩展包（id / 展示名）——多包同面时面板按包名分组，用户分得清来源。
  final String packId;
  final String packName;

  /// 现成的字幕样式（值已按面的 schema 校验/归一化过）。
  final SubtitleStyle style;

  @override
  String toString() => 'SubtitlePreset($id $name)';
}
