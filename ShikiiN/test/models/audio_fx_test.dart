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
  });
}
