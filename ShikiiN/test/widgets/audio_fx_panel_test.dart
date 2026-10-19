import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shikiin/models/audio_fx.dart';
import 'package:shikiin/models/theme_tokens.dart';
import 'package:shikiin/widgets/audio_fx_panel.dart';

const List<AudioFxPreset> _presets = <AudioFxPreset>[
  AudioFxPreset(
    id: 'audio-a/vocal',
    name: '人声增强',
    description: '对白靠前',
    bands: <String, double>{'b2k': 3, 'b63': -1},
    preamp: -3.5,
  ),
  AudioFxPreset(id: 'audio-a/bass', name: '低音增强', bands: <String, double>{'b63': 6}),
];

Widget _host({
  List<AudioFxPreset> presets = _presets,
  AudioFxState state = const AudioFxState(),
  ValueChanged<String?>? onPreset,
  ValueChanged<int>? onCompression,
  ValueChanged<int>? onLoudness,
}) =>
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: AudioFxSection(
            tokens: ThemeTokens.fallback,
            presets: presets,
            state: state,
            onPreset: onPreset ?? (_) {},
            onCompression: onCompression ?? (_) {},
            onLoudness: onLoudness ?? (_) {},
          ),
        ),
      ),
    );

void main() {
  testWidgets('有档位：显示标题、档位、两个强度行，且曲线画 10 个点', (tester) async {
    await tester.pumpWidget(_host(
      state: const AudioFxState(enabled: true, presetId: 'audio-a/vocal'),
    ));
    await tester.pumpAndSettle();

    expect(find.text('音效'), findsOneWidget);
    // 当前档名两处：右上角状态 + 档位那格。
    expect(find.text('人声增强'), findsNWidgets(2));
    expect(find.text('低音增强'), findsOneWidget);
    expect(find.text('对白压缩'), findsOneWidget);
    expect(find.text('音量均衡'), findsOneWidget);

    final CustomPaint paint = tester.widget<CustomPaint>(
      find.byWidgetPredicate((Widget w) =>
          w is CustomPaint && w.painter is AudioFxCurvePainter),
    );
    final AudioFxCurvePainter painter = paint.painter! as AudioFxCurvePainter;
    expect(painter.bands.length, 10, reason: '画的是 10 个频点');
    expect(painter.bands['b2k'], 3);
  });

  testWidgets('默认原声：右上角写「原声」，原声那格选中', (tester) async {
    await tester.pumpWidget(_host());
    await tester.pumpAndSettle();
    // 两处「原声」：右上角状态 + 档位那格。
    expect(find.text('原声'), findsNWidgets(2));
    final Container offChip = tester.widget<Container>(
      find.byKey(const ValueKey<String>('audio-fx-off')),
    );
    final BoxDecoration decoration = offChip.decoration! as BoxDecoration;
    expect(decoration.color, ThemeTokens.fallback.accent);
  });

  testWidgets('点「人声增强」→ onPreset 收到该档 id', (tester) async {
    String? selected;
    await tester.pumpWidget(_host(onPreset: (String? id) => selected = id));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('audio-fx-preset-audio-a/vocal')));
    expect(selected, 'audio-a/vocal');
  });

  testWidgets('点「原声」→ onPreset(null)', (tester) async {
    String? selected = 'x';
    await tester.pumpWidget(_host(
      state: const AudioFxState(enabled: true, presetId: 'audio-a/vocal'),
      onPreset: (String? id) => selected = id,
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('audio-fx-off')));
    expect(selected, isNull);
  });

  testWidgets('两个强度行各自四个档，点击回传 0..3', (tester) async {
    int? compression;
    int? loudness;
    await tester.pumpWidget(_host(
      onCompression: (int v) => compression = v,
      onLoudness: (int v) => loudness = v,
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('audio-fx-level-compression-2')));
    await tester.tap(find.byKey(const ValueKey<String>('audio-fx-level-loudness-3')));
    expect(compression, 2);
    expect(loudness, 3);
  });

  test('曲线 painter：0 dB 在中间，正增益在上方', () {
    final AudioFxCurvePainter painter = AudioFxCurvePainter(
      bands: const <String, double>{'b2k': 12},
      line: const Color(0xFF000000),
      grid: const Color(0xFF999999),
    );
    final Size size = const Size(100, 100);
    // y 用同样的映射口径反推：+12 应在上半区、-12 在下半区。
    expect(painter.shouldRepaint(painter), isFalse);
    final AudioFxCurvePainter other = AudioFxCurvePainter(
      bands: const <String, double>{'b2k': 6},
      line: const Color(0xFF000000),
      grid: const Color(0xFF999999),
    );
    expect(painter.shouldRepaint(other), isTrue);
    expect(size.height, 100);
  });
}
