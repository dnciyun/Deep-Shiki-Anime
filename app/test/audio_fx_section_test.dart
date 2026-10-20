/// 扩展页「音效」区的 widget 测试：不联网、不碰播放窗口。
library;

import 'package:dsanima/theme/tokens.dart';
import 'package:dsanima/ui/audio_fx_section.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shikiin/shikiin.dart' as shikiin;

const List<shikiin.AudioFxPreset> _presets = <shikiin.AudioFxPreset>[
  shikiin.AudioFxPreset(
    id: 'audio-a/vocal',
    name: '人声增强',
    description: '对白靠前',
    bands: <String, double>{'b2k': 3, 'b63': -1},
    preamp: 0,
  ),
  shikiin.AudioFxPreset(id: 'audio-a/bass', name: '低音增强', bands: <String, double>{'b63': 5}),
];

Widget _host({
  shikiin.AudioFxState state = const shikiin.AudioFxState(),
  ValueChanged<shikiin.AudioFxState>? onChange,
}) =>
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: AudioFxSection(
            tokens: DsTokens.whiteInk,
            presets: _presets,
            state: state,
            onChange: onChange ?? (_) {},
          ),
        ),
      ),
    );

void main() {
  testWidgets('默认原声：显示档位与两个强度行，曲线画 10 个点', (tester) async {
    await tester.pumpWidget(_host());
    await tester.pumpAndSettle();

    expect(find.text('音效'), findsOneWidget);
    expect(find.text('人声增强'), findsOneWidget);
    expect(find.text('低音增强'), findsOneWidget);
    expect(find.text('对白压缩'), findsOneWidget);
    expect(find.text('音量均衡'), findsOneWidget);

    final CustomPaint paint = tester.widget<CustomPaint>(
      find.byWidgetPredicate(
        (Widget w) => w is CustomPaint && w.painter is AudioFxCurvePainter,
      ),
    );
    final AudioFxCurvePainter painter = paint.painter! as AudioFxCurvePainter;
    expect(painter.bands.length, 10);
  });

  testWidgets('点「人声增强」→ onChange 收到 enabled + 该档 id', (tester) async {
    shikiin.AudioFxState? got;
    await tester.pumpWidget(_host(onChange: (shikiin.AudioFxState s) => got = s));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('audio-fx-preset-audio-a/vocal')));
    expect(got, isNotNull);
    expect(got!.enabled, isTrue);
    expect(got!.presetId, 'audio-a/vocal');
  });

  testWidgets('点「原声」→ 关掉并清掉档位', (tester) async {
    shikiin.AudioFxState? got;
    await tester.pumpWidget(_host(
      state: const shikiin.AudioFxState(enabled: true, presetId: 'audio-a/vocal'),
      onChange: (shikiin.AudioFxState s) => got = s,
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('audio-fx-off')));
    expect(got!.enabled, isFalse);
    expect(got!.presetId, isNull);
  });

  testWidgets('两个强度各自四档，点击回传 0..3', (tester) async {
    shikiin.AudioFxState? got;
    await tester.pumpWidget(_host(onChange: (shikiin.AudioFxState s) => got = s));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('audio-fx-level-compression-2')));
    expect(got!.compression, 2);
    await tester.tap(find.byKey(const ValueKey<String>('audio-fx-level-loudness-3')));
    expect(got!.loudness, 3);
  });

  // ── 总强度（页面上的连续力度，spec §4.1）────────────────────────────────────

  testWidgets('有档位时出现「总强度」滑块，显示当前百分比', (tester) async {
    await tester.pumpWidget(_host(
      state: const shikiin.AudioFxState(enabled: true, presetId: 'audio-a/vocal'),
    ));
    await tester.pumpAndSettle();

    expect(find.text('总强度'), findsOneWidget);
    final Slider slider = tester.widget<Slider>(
      find.byKey(const ValueKey<String>('audio-fx-intensity')),
    );
    expect(slider.min, 0);
    expect(slider.max, 100);
    expect(slider.divisions, 20);
    // 老状态（没有 intensity 字段）默认 100%，不许一进来就是 0。
    expect(slider.value, 100);
    expect(find.text('100%'), findsOneWidget);
  });

  testWidgets('拖到中间 → 回传的 intensity 落在 45–55（连续值，不是只有四档）', (tester) async {
    shikiin.AudioFxState? got;
    await tester.pumpWidget(_host(
      state: const shikiin.AudioFxState(enabled: true, presetId: 'audio-a/vocal'),
      onChange: (shikiin.AudioFxState s) => got = s,
    ));
    await tester.pumpAndSettle();

    final Finder slider = find.byKey(const ValueKey<String>('audio-fx-intensity'));
    // 点滑块正中间 = 50%。不用 drag：那要按轨道像素算偏移，换个主题高度就飘。
    await tester.tapAt(tester.getCenter(slider));
    await tester.pump();

    expect(got, isNotNull);
    expect(got!.intensity, inInclusiveRange(45, 55));
    // 改强度不该顺手改掉总开关或当前档（那是两件事）。
    expect(got!.enabled, isTrue);
    expect(got!.presetId, 'audio-a/vocal');
  });

  testWidgets('点「原声」→ 关掉但仍保留 intensity（强度不是开关键）', (tester) async {
    shikiin.AudioFxState? got;
    await tester.pumpWidget(_host(
      state: const shikiin.AudioFxState(
        enabled: true,
        presetId: 'audio-a/vocal',
        intensity: 40,
      ),
      onChange: (shikiin.AudioFxState s) => got = s,
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('audio-fx-off')));
    expect(got!.enabled, isFalse);
    expect(got!.presetId, isNull);
    expect(got!.intensity, 40);
  });

  testWidgets('曲线跟着强度缩：0% 时画出来的 10 个点全在 0 dB', (tester) async {
    await tester.pumpWidget(_host(
      state: const shikiin.AudioFxState(
        enabled: true,
        presetId: 'audio-a/vocal',
        intensity: 0,
      ),
    ));
    await tester.pumpAndSettle();

    final CustomPaint paint = tester.widget<CustomPaint>(
      find.byWidgetPredicate(
        (Widget w) => w is CustomPaint && w.painter is AudioFxCurvePainter,
      ),
    );
    final AudioFxCurvePainter painter = paint.painter! as AudioFxCurvePainter;
    // 档位本身有 b2k +3 / b63 -1：0% 时曲线必须是平的，否则界面在撒谎。
    expect(painter.bands.values.every((double v) => v == 0), isTrue);
  });
}
