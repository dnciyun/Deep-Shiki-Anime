import 'package:flutter_test/flutter_test.dart';
import 'package:shikiin/models/audio_fx.dart';

AudioFxPreset _preset({
  Map<String, double>? bands,
  double preamp = -3,
  double crossfeed = 0,
}) =>
    AudioFxPreset(
      id: 'p',
      name: '测试档',
      bands: bands ?? const <String, double>{},
      preamp: preamp,
      crossfeed: crossfeed,
    );

Map<String, double> _zeros() =>
    <String, double>{for (final String band in kAudioFxBands) band: 0};

void main() {
  group('audioFxFilterSpec', () {
    test('全零档仍是合法链：10 个 g=0 + 预增益 + 限幅，不等于空串', () {
      final String spec = audioFxFilterSpec(_preset(bands: _zeros()));
      expect(spec, startsWith('lavfi=['));
      for (final String band in kAudioFxBands) {
        final int freq = kAudioFxBandFrequencies[band]!;
        expect(
          spec,
          contains('equalizer=f=$freq:width_type=o:width=1:g=0'),
          reason: '$band 少了',
        );
      }
      expect(spec, contains('volume=-3dB'));
      expect(spec, endsWith('alimiter=limit=0.97]'));
    });

    test('单段 +12 出现在对应频点上', () {
      final Map<String, double> bands = _zeros()..['b2k'] = 12;
      final String spec = audioFxFilterSpec(_preset(bands: bands));
      expect(spec, contains('equalizer=f=2000:width_type=o:width=1:g=12'));
      expect(spec, contains('equalizer=f=1000:width_type=o:width=1:g=0'));
    });

    test('preamp = 0 时不下发 volume（预增益吃掉抬升是历史事故）', () {
      final String spec = audioFxFilterSpec(_preset(bands: _zeros(), preamp: 0));
      expect(spec, isNot(contains('volume=')));
      final String withPreamp = audioFxFilterSpec(_preset(bands: _zeros(), preamp: -3));
      expect(withPreamp, contains('volume=-3dB'));
    });

    test('crossfeed = 0 不出现，> 0 出现且顺序在限幅之前', () {
      final Map<String, double> bands = _zeros();
      expect(audioFxFilterSpec(_preset(bands: bands)), isNot(contains('crossfeed')));
      final String on =
          audioFxFilterSpec(_preset(bands: bands, crossfeed: 0.35));
      expect(on, contains('crossfeed=strength=0.35:range=0.5:slope=0.5'));
      expect(on.indexOf('crossfeed'), lessThan(on.indexOf('alimiter')));
    });

    test('压缩三档互不相同，0 = 不出现', () {
      final AudioFxPreset p = _preset(bands: _zeros());
      expect(audioFxFilterSpec(p, compression: 0), isNot(contains('acompressor')));
      final String c1 = audioFxFilterSpec(p, compression: 1);
      final String c2 = audioFxFilterSpec(p, compression: 2);
      final String c3 = audioFxFilterSpec(p, compression: 3);
      expect(<String>{c1, c2, c3}.length, 3);
      expect(c1, contains('acompressor=threshold=0.1:ratio=2'));
      expect(c3, contains('ratio=4'));
    });

    test('音量均衡三档互不相同，0 = 不出现', () {
      final AudioFxPreset p = _preset(bands: _zeros());
      expect(audioFxFilterSpec(p, loudness: 0), isNot(contains('dynaudnorm')));
      final String l1 = audioFxFilterSpec(p, loudness: 1);
      final String l2 = audioFxFilterSpec(p, loudness: 2);
      final String l3 = audioFxFilterSpec(p, loudness: 3);
      expect(<String>{l1, l2, l3}.length, 3);
      expect(l3, contains('maxgain=11'));
    });

    test('顺序：EQ → 预增益 → 空间感 → 压缩 → 均衡 → 限幅', () {
      final String spec = audioFxFilterSpec(
        _preset(bands: _zeros(), crossfeed: 0.5),
        compression: 1,
        loudness: 1,
      );
      final List<String> order = <String>[
        'equalizer=f=16000',
        'volume=',
        'crossfeed=',
        'acompressor=',
        'dynaudnorm=',
        'alimiter=',
      ];
      int last = -1;
      for (final String token in order) {
        final int at = spec.indexOf(token);
        expect(at, greaterThan(last), reason: '$token 顺序不对');
        last = at;
      }
    });

    test('越界数值被夹到边界', () {
      final Map<String, double> bands = _zeros()..['b31'] = 99;
      final String spec = audioFxFilterSpec(
        _preset(bands: bands, preamp: 99, crossfeed: 9),
      );
      expect(spec, contains('equalizer=f=31:width_type=o:width=1:g=12'));
      expect(spec, contains('volume=6dB'));
      expect(spec, contains('crossfeed=strength=1:'));
      final String low = audioFxFilterSpec(
        _preset(bands: _zeros()..['b63'] = -99, preamp: -99),
      );
      expect(low, contains('equalizer=f=63:width_type=o:width=1:g=-12'));
      expect(low, contains('volume=-12dB'));
    });

    test('preset 为 null → 空串（原声由调用方清空 af）', () {
      expect(audioFxFilterSpec(null), '');
    });

    // ── 总强度（intensity，页面上的「总强度」滑块）────────────────────────────
    //
    // 语义（spec §4.1）：只缩放 10 段 EQ 的增益，**预增益不缩**。
    // 预增益一起缩就是 2026-10-19 那个「改的音效没效果，都是把声音变小了」的事故。

    test('不传 intensity 与传中性点 50 是同一条链（老调用方行为不变）', () {
      final Map<String, double> bands = _zeros()
        ..['b250'] = 6
        ..['b2k'] = -6;
      final AudioFxPreset p =
          _preset(bands: bands, preamp: -3, crossfeed: 0.35);
      expect(
        audioFxFilterSpec(p),
        audioFxFilterSpec(p, intensity: kAudioFxIntensityNeutral),
      );
      expect(audioFxIntensityScale(kAudioFxIntensityNeutral), 1.0);
    });

    test('中性点 50%：就是包里的原值（-6 仍是 -6），预增益原样', () {
      final Map<String, double> bands = _zeros()..['b500'] = -6;
      final String spec = audioFxFilterSpec(
        _preset(bands: bands, preamp: -3),
        intensity: kAudioFxIntensityNeutral,
      );
      expect(spec, contains('equalizer=f=500:width_type=o:width=1:g=-6'));
      expect(spec, contains('volume=-3dB'));
    });

    test('25%：原值的一半（-6 变 -3），预增益仍不缩', () {
      final Map<String, double> bands = _zeros()..['b500'] = -6;
      final String spec = audioFxFilterSpec(
        _preset(bands: bands, preamp: -3),
        intensity: 25,
      );
      expect(spec, contains('equalizer=f=500:width_type=o:width=1:g=-3'));
      // 预增益不参与缩放：否则拉低强度时音量也跟着掉，「强度」会变成音量旋钮。
      expect(spec, contains('volume=-3dB'));
    });

    test('100%：原值两倍（-6 变 -12）—— 「拉大效果更明显」', () {
      final Map<String, double> bands = _zeros()..['b500'] = -6;
      final String spec = audioFxFilterSpec(
        _preset(bands: bands, preamp: -3),
        intensity: kAudioFxIntensityMax,
      );
      expect(spec, contains('equalizer=f=500:width_type=o:width=1:g=-12'));
      expect(spec, contains('volume=-3dB'));
    });

    test('100% 时超过 ±12 dB 的频段按 ±12 夹（equalizer 有界，越界会整条链没声）', () {
      final Map<String, double> bands = _zeros()
        ..['b8k'] = 9
        ..['b31'] = 12;
      final String spec = audioFxFilterSpec(
        _preset(bands: bands),
        intensity: kAudioFxIntensityMax,
      );
      expect(spec, contains('equalizer=f=8000:width_type=o:width=1:g=12'));
      expect(spec, contains('equalizer=f=31:width_type=o:width=1:g=12'));
    });

    test('0%：EQ 全部平直（0 dB），但压缩/均衡/限幅仍在 —— 不是静音', () {
      final Map<String, double> bands = _zeros()..['b2k'] = 9;
      final String spec = audioFxFilterSpec(
        _preset(bands: bands),
        compression: 2,
        loudness: 1,
        intensity: 0,
      );
      for (final String band in kAudioFxBands) {
        final int freq = kAudioFxBandFrequencies[band]!;
        expect(
          spec,
          contains('equalizer=f=$freq:width_type=o:width=1:g=0'),
          reason: '$band 在 0% 时不是 0 dB',
        );
      }
      expect(spec, contains('acompressor='));
      expect(spec, contains('dynaudnorm='));
      expect(spec, endsWith('alimiter=limit=0.97]'));
    });

    test('intensity 越界被夹到 0 / 100（滑块之外的来源也不会拼出怪链）', () {
      final Map<String, double> bands = _zeros()..['b2k'] = 4;
      // 250 → 夹到 100 → 两倍 → 8。
      expect(
        audioFxFilterSpec(_preset(bands: bands), intensity: 250),
        contains('equalizer=f=2000:width_type=o:width=1:g=8'),
      );
      expect(
        audioFxFilterSpec(_preset(bands: bands), intensity: -5),
        contains('equalizer=f=2000:width_type=o:width=1:g=0'),
      );
    });

    test('缺项按 0 处理，不抛', () {
      final String spec = audioFxFilterSpec(_preset(bands: <String, double>{'b1k': 3}));
      expect(spec, contains('equalizer=f=31:width_type=o:width=1:g=0'));
      expect(spec, contains('equalizer=f=1000:width_type=o:width=1:g=3'));
    });
  });

  group('audioFxFiltersCommand', () {
    test('有链 → set af <链>；空串 → set af 空', () {
      expect(audioFxFiltersCommand('lavfi=[alimiter=limit=0.97]'),
          <String>['set', 'af', 'lavfi=[alimiter=limit=0.97]']);
      expect(audioFxFiltersCommand(''), <String>['set', 'af', '']);
    });
  });

  group('AudioFxSelection', () {
    test('null = 原声；按 presetId 判等', () {
      expect(const AudioFxSelection.off().isOff, isTrue);
      expect(const AudioFxSelection('a/b').isOff, isFalse);
      expect(const AudioFxSelection('a/b'), const AudioFxSelection('a/b'));
      expect(const AudioFxSelection('a/b'), isNot(const AudioFxSelection('a/c')));
    });
  });

  group('audioFxActiveSpec', () {
    final AudioFxPreset p = _preset(bands: <String, double>{'b2k': 6});
    final List<AudioFxPreset> presets = <AudioFxPreset>[p];

    test('关着 → 空串（原声）', () {
      expect(
        audioFxActiveSpec(presets: presets, state: const AudioFxState(presetId: 'p')),
        '',
      );
    });

    test('开着但档位不存在（包被卸了）→ 空串', () {
      expect(
        audioFxActiveSpec(
          presets: presets,
          state: const AudioFxState(enabled: true, presetId: 'gone'),
        ),
        '',
      );
      expect(
        audioFxActiveSpec(presets: const <AudioFxPreset>[], state: const AudioFxState(enabled: true, presetId: 'p')),
        '',
      );
    });

    test('开着且档位在 → 链里带上该档和两个全局强度', () {
      final String spec = audioFxActiveSpec(
        presets: presets,
        state: const AudioFxState(
          enabled: true,
          presetId: 'p',
          compression: 2,
          loudness: 1,
        ),
      );
      expect(spec, contains('equalizer=f=2000:width_type=o:width=1:g=6'));
      expect(spec, contains('acompressor='));
      expect(spec, contains('dynaudnorm='));
      expect(spec, endsWith('alimiter=limit=0.97]'));
    });

    test('AudioFxState.copyWith 能清掉档位', () {
      const AudioFxState s = AudioFxState(enabled: true, presetId: 'a');
      expect(s.copyWith().presetId, 'a');
      expect(s.copyWith(clearPreset: true).presetId, isNull);
      expect(s.copyWith(enabled: false).enabled, isFalse);
    });

    test('状态里的 intensity 会透传到链上（页面改的强度必须真的落到 af）', () {
      // 档位本身是 b2k +6 dB：50（中性点）= 原值 6，100 = 两倍 12。
      expect(
        audioFxActiveSpec(
          presets: presets,
          state: const AudioFxState(
            enabled: true,
            presetId: 'p',
            intensity: kAudioFxIntensityNeutral,
          ),
        ),
        contains('equalizer=f=2000:width_type=o:width=1:g=6'),
      );
      expect(
        audioFxActiveSpec(
          presets: presets,
          state: const AudioFxState(
            enabled: true,
            presetId: 'p',
            intensity: kAudioFxIntensityMax,
          ),
        ),
        contains('equalizer=f=2000:width_type=o:width=1:g=12'),
      );
    });
  });

  group('AudioFxState.intensity', () {
    test('缺省 = 中性点 50（= 包里的原值，不会因为多了这个字段就变调）', () {
      expect(const AudioFxState().intensity, kAudioFxIntensityNeutral);
      expect(kAudioFxIntensityNeutral, 50);
    });

    test('toJson 带上 intensity 与尺度版本（跨窗口传值靠它）', () {
      expect(const AudioFxState(intensity: 40).toJson()['intensity'], 40);
      expect(const AudioFxState().toJson()['intensity'], kAudioFxIntensityNeutral);
      expect(const AudioFxState().toJson()['intensityScheme'], kAudioFxIntensityScheme);
    });

    test('老文件（没有 intensityScheme）= 旧尺度，折半换算才"听感不变"', () {
      // 旧尺度里 100 = 原值 → 新尺度 50；旧 40 = 变淡到 40% → 新 20。
      expect(AudioFxState.fromJson(<String, Object?>{'intensity': 100}).intensity, 50);
      expect(AudioFxState.fromJson(<String, Object?>{'intensity': 40}).intensity, 20);
      expect(AudioFxState.fromJson(<String, Object?>{'intensity': 0}).intensity, 0);
    });

    test('新文件（intensityScheme 够新）按原样读，不再换算', () {
      expect(
        AudioFxState.fromJson(<String, Object?>{
          'intensity': 80,
          'intensityScheme': kAudioFxIntensityScheme,
        }).intensity,
        80,
      );
      // 比当前版本还新的尺度：当作已换算，别自作聪明再除一次。
      expect(
        AudioFxState.fromJson(<String, Object?>{
          'intensity': 80,
          'intensityScheme': kAudioFxIntensityScheme + 1,
        }).intensity,
        80,
      );
    });

    test('fromJson：缺字段 = 中性点 50；带尺度版本的 42 原样认；越界夹到 0/100', () {
      expect(AudioFxState.fromJson(<String, Object?>{}).intensity, kAudioFxIntensityNeutral);
      expect(
        AudioFxState.fromJson(<String, Object?>{
          'intensity': 42,
          'intensityScheme': kAudioFxIntensityScheme,
        }).intensity,
        42,
      );
      expect(
        AudioFxState.fromJson(<String, Object?>{
          'intensity': 250,
          'intensityScheme': kAudioFxIntensityScheme,
        }).intensity,
        100,
      );
      expect(
        AudioFxState.fromJson(<String, Object?>{
          'intensity': -5,
          'intensityScheme': kAudioFxIntensityScheme,
        }).intensity,
        0,
      );
    });

    test('copyWith 不传 intensity = 保持（右键切档不许把强度冲回中性点）', () {
      const AudioFxState s = AudioFxState(intensity: 40);
      expect(s.copyWith(compression: 2).intensity, 40);
      expect(s.copyWith(enabled: true, presetId: 'x').intensity, 40);
      expect(s.copyWith(intensity: 80).intensity, 80);
    });

    test('强度参与判等：只差 intensity 的两个状态不相等', () {
      expect(const AudioFxState(intensity: 40), const AudioFxState(intensity: 40));
      expect(
        const AudioFxState(intensity: 40),
        isNot(const AudioFxState(intensity: 41)),
      );
    });
  });
}
