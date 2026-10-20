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
    expect(slider.min, shikiin.kAudioFxIntensityMin);
    expect(slider.max, shikiin.kAudioFxIntensityMax);
    expect(slider.divisions, 20);
    // 默认 = 中性点 50%（= 包里的原值）。2026-10-20 用户：「当前100的强度移动到50，
    // 默认强度在50，拉大效果更明显」—— 滑块两头都有余量，中点才是"不动"。
    expect(slider.value, shikiin.kAudioFxIntensityNeutral);
    expect(slider.value, 50);
    expect(find.text('50%'), findsOneWidget);
  });

  testWidgets('拖到四分之三 → 回传的 intensity 落在 65–85（连续值，不是只有四档）', (tester) async {
    shikiin.AudioFxState? got;
    await tester.pumpWidget(_host(
      state: const shikiin.AudioFxState(enabled: true, presetId: 'audio-a/vocal'),
      onChange: (shikiin.AudioFxState s) => got = s,
    ));
    await tester.pumpAndSettle();

    final Finder slider = find.byKey(const ValueKey<String>('audio-fx-intensity'));
    // 点 3/4 处 ≈ 75%。**不能点正中间**：默认就是中性点 50，值没变 Slider 不会回调
    // （`onChanged` 只在值真的变了时触发），那样断言的是"没变化"而不是"能连续调"。
    // 也不用 drag：那要按轨道像素算偏移，换个主题高度就飘。
    final Rect rect = tester.getRect(slider);
    await tester.tapAt(Offset(rect.left + rect.width * 0.75, rect.center.dy));
    await tester.pump();

    expect(got, isNotNull);
    expect(got!.intensity, inInclusiveRange(65, 85));
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

  testWidgets('曲线用同一个缩放函数：50% = 原值、100% = 两倍', (tester) async {
    Future<AudioFxCurvePainter> painterAt(int intensity) async {
      await tester.pumpWidget(_host(
        state: shikiin.AudioFxState(
          enabled: true,
          presetId: 'audio-a/vocal',
          intensity: intensity,
        ),
      ));
      await tester.pumpAndSettle();
      final CustomPaint paint = tester.widget<CustomPaint>(
        find.byWidgetPredicate(
          (Widget w) => w is CustomPaint && w.painter is AudioFxCurvePainter,
        ),
      );
      return paint.painter! as AudioFxCurvePainter;
    }

    // 档位：b2k +3 / b63 -1。
    final AudioFxCurvePainter neutral = await painterAt(shikiin.kAudioFxIntensityNeutral);
    expect(neutral.bands['b2k'], 3);
    expect(neutral.bands['b63'], -1);

    // 100% = 原值两倍：曲线必须跟着变猛，否则"拉大更明显"只发生在耳朵里。
    final AudioFxCurvePainter max = await painterAt(shikiin.kAudioFxIntensityMax);
    expect(max.bands['b2k'], 6);
    expect(max.bands['b63'], -2);
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
