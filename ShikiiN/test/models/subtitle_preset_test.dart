/// `SubtitlePreset`：宿主从通用扩展包（`preset-pack` / `player.subtitle` 面）
/// 交给播放器的字幕样式预设。播放器只认这个模型，不认识扩展清单格式。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:shikiin/shikiin.dart';

void main() {
  test('预设携带完整 SubtitleStyle 与说明', () {
    const SubtitlePreset preset = SubtitlePreset(
      id: 'cinema',
      name: '影院大字',
      description: '白字黑边',
      style: SubtitleStyle(scale: 1.6, pos: 88),
    );
    expect(preset.id, 'cinema');
    expect(preset.name, '影院大字');
    expect(preset.description, '白字黑边');
    expect(preset.style.scale, 1.6);
    expect(preset.style.pos, 88);
  });
}
