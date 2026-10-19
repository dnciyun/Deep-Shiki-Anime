/// 设置面板的「字幕样式预设」区：点一个预设 = 调一次 `onSubtitleStyle`。
///
/// 守的是「预设能看见但点不动 / 点了没反应」这一类问题 —— 宿主把扩展包里的
/// 预设交进来之后，这里必须把 `SubtitleStyle` 原样交回（写盘/下发由宿主负责）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shikiin/shikiin.dart';
import 'package:shikiin/widgets/settings_panel.dart';

void main() {
  testWidgets('点预设按钮 → 回调拿到预设样式', (WidgetTester tester) async {
    SubtitleStyle? applied;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SettingsPanel(
          tokens: ThemeTokens.fallback,
          volume: 50,
          onVolume: (double _) {},
          subtitleStyle: const SubtitleStyle(),
          onSubtitleStyle: (SubtitleStyle s) => applied = s,
          presets: const <SubtitlePreset>[
            SubtitlePreset(
              id: 'cinema',
              name: '影院大字',
              style: SubtitleStyle(scale: 1.6),
            ),
          ],
        ),
      ),
    ));

    await tester.tap(find.byKey(const ValueKey<String>('subtitle-preset-cinema')));
    await tester.pump();

    expect(applied, isNotNull);
    expect(applied!.scale, 1.6);
  });

  testWidgets('没有预设时不显示预设区（不留一个空标题）', (WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SettingsPanel(
          tokens: ThemeTokens.fallback,
          volume: 50,
          onVolume: (double _) {},
          subtitleStyle: const SubtitleStyle(),
          onSubtitleStyle: (SubtitleStyle _) {},
        ),
      ),
    ));

    expect(find.text('样式预设'), findsNothing);
  });
}
