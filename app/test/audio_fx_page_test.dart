/// 「音效」页的 widget 测试（spec §4 / 计划 Task 3 步骤 4）。
///
/// 三件事必须钉住：
/// * 数据来自 `packAvailabilityProvider.audioPresets`（不自己扫盘）；
/// * 任何改动都**落 `audioFxSettingsProvider` + 推给播放窗口一次**（方案 A：文件是唯一真相）；
/// * 没扫到档位时是空态，不许崩（深链/老配置仍能进这一页）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:dsanima/state/audio_fx_settings.dart';
import 'package:dsanima/state/packs_available.dart';
import 'package:dsanima/state/player_window.dart';
import 'package:dsanima/state/providers.dart'
    show ShellTab, navProvider, playerWindowServiceProvider;
import 'package:dsanima/ui/audio_fx_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shikiin/shikiin.dart' as shikiin;

const List<shikiin.AudioFxPreset> _presets = <shikiin.AudioFxPreset>[
  shikiin.AudioFxPreset(
    id: 'audio-a/vocal',
    name: '人声增强',
    description: '对白靠前',
    packId: 'audio-a',
    packName: '音效包A',
    bands: <String, double>{'b2k': 3, 'b63': -1},
    preamp: 0,
  ),
  shikiin.AudioFxPreset(
    id: 'audio-a/bass',
    name: '低音增强',
    packId: 'audio-a',
    packName: '音效包A',
    bands: <String, double>{'b63': 5},
  ),
];

/// 固定可用性：这一页读的就是它，不走真实扫盘（扫盘由 Task 1 的
/// `packs_available_test.dart` 钉）。
class _FixedAvailability extends PackAvailabilityController {
  _FixedAvailability(this.value);

  final PackAvailability value;

  @override
  PackAvailability build() => value;
}

/// 记录「推给播放窗口」的窗口服务替身（`sendAudioFx` 是普通方法，直接覆盖）。
class _RecordingWindow extends PlayerWindowService {
  final List<Map<String, Object?>> sentAudioFx = <Map<String, Object?>>[];

  @override
  Future<void> sendAudioFx(Map<String, Object?> state) async =>
      sentAudioFx.add(state);
}

void main() {
  late ProviderContainer container;
  late _RecordingWindow window;

  /// 装一棵只含这一页的树（1400×1000：900 高以下的宽度不够时会 RenderFlex overflow，
  /// 与拖放确认框那一轮的教训一致）。
  Future<void> pumpPage(
    WidgetTester tester, {
    PackAvailability availability =
        const PackAvailability(audioPresets: _presets),
  }) async {
    window = _RecordingWindow();
    container = ProviderContainer(
      overrides: [
        packAvailabilityProvider.overrideWith(() => _FixedAvailability(availability)),
        playerWindowServiceProvider.overrideWithValue(window),
      ],
    );
    addTearDown(container.dispose);

    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: Scaffold(body: AudioFxPage())),
      ),
    );
    await tester.pumpAndSettle();
  }

  group('音效页', () {
    testWidgets('装上音效包 → 档位、总强度、包名行都在；强度默认 50%（中性点）',
        (WidgetTester tester) async {
      await pumpPage(tester);

      expect(find.text('音效'), findsWidgets, reason: '页头与区块内标题都可以叫音效');
      expect(find.text('人声增强'), findsOneWidget);
      expect(find.text('低音增强'), findsOneWidget);
      expect(find.text('总强度'), findsOneWidget);
      expect(find.text('对白压缩'), findsOneWidget);
      expect(find.text('音量均衡'), findsOneWidget);
      // 页头那行把"这些档是谁给的"和"去哪卸"合成一句。
      expect(find.text('音效包A · 去扩展页管理'), findsOneWidget);
      expect(
        tester
            .widget<Slider>(find.byKey(const ValueKey<String>('audio-fx-intensity')))
            .value,
        shikiin.kAudioFxIntensityNeutral,
        reason: '老配置没有 intensity 字段 ⇒ 中性点 50%（= 包里原值），不许一进来就变调',
      );
      expect(find.byKey(dsAudioFxEmptyKey), findsNothing);
    });

    testWidgets('点某档 → 落进 provider（enabled + presetId）并推给播放窗口一次',
        (WidgetTester tester) async {
      await pumpPage(tester);

      await tester.tap(
        find.byKey(const ValueKey<String>('audio-fx-preset-audio-a/vocal')),
      );
      await tester.pump();

      final shikiin.AudioFxState state = container.read(audioFxSettingsProvider);
      expect(state.enabled, isTrue);
      expect(state.presetId, 'audio-a/vocal');
      expect(window.sentAudioFx.length, 1, reason: '一次改动只推一条');
      expect(window.sentAudioFx.single['presetId'], 'audio-a/vocal');
      expect(window.sentAudioFx.single['enabled'], true);
      expect(window.sentAudioFx.single['intensity'], shikiin.kAudioFxIntensityNeutral);
    });

    testWidgets('拖总强度到 3/4 处 → provider 与推送里都是连续值，不是四档',
        (WidgetTester tester) async {
      await pumpPage(tester);

      final Finder slider = find.byKey(const ValueKey<String>('audio-fx-intensity'));
      // 默认就是中性点 50%，点正中间等于"没变"（Slider 不会回调），所以点 3/4 处。
      final Rect rect = tester.getRect(slider);
      await tester.tapAt(Offset(rect.left + rect.width * 0.75, rect.center.dy));
      await tester.pump();

      final int intensity = container.read(audioFxSettingsProvider).intensity;
      expect(intensity, inInclusiveRange(65, 85));
      expect(window.sentAudioFx.single['intensity'], intensity);
      // 只改强度：档位与开关原样（强度不是开关键）。
      expect(window.sentAudioFx.single['enabled'], isFalse);
    });

    testWidgets('「去扩展页管理」→ 导航切到扩展页', (WidgetTester tester) async {
      await pumpPage(tester);
      container.read(navProvider.notifier).select(ShellTab.home);

      await tester.tap(find.byKey(dsAudioFxManageKey));
      await tester.pump();

      expect(container.read(navProvider), ShellTab.extensions);
    });

    testWidgets('没扫到音效档 → 空态文案，不渲染滑块与曲线，不崩',
        (WidgetTester tester) async {
      await pumpPage(tester, availability: PackAvailability.none);

      expect(find.byKey(dsAudioFxEmptyKey), findsOneWidget);
      expect(find.text('总强度'), findsNothing);
      expect(find.byType(Slider), findsNothing);
      // 包名行还在（"去扩展页管理"是空态下唯一的出口）。
      expect(find.byKey(dsAudioFxManageKey), findsOneWidget);
      expect(find.text('去扩展页管理'), findsOneWidget);
    });
  });

  group('audio-fx.json（文件是唯一真相）', () {
    test('往返：intensity 真的写进文件、读回来还在', () async {
      final Directory dir = await Directory.systemTemp.createTemp('ds-anima-audio-fx-');
      addTearDown(() async {
        if (await dir.exists()) await dir.delete(recursive: true);
      });

      await saveAudioFxState(
        dir,
        const shikiin.AudioFxState(
          enabled: true,
          presetId: 'audio-a/vocal',
          compression: 1,
          loudness: 2,
          intensity: 35,
        ),
      );

      final Object? raw = jsonDecode(await audioFxSettingsFileOf(dir).readAsString());
      expect((raw! as Map<String, Object?>)['intensity'], 35);

      final shikiin.AudioFxState back = await loadAudioFxState(dir);
      expect(back.intensity, 35);
      expect(back.presetId, 'audio-a/vocal');
      expect(back.compression, 1);
    });
  });
}
